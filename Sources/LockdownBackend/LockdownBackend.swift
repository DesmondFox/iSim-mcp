import DeviceCore
import Foundation
import LogPredicate
import ProcessKit

/// The unified log of iPhones through lockdown's os_trace_relay, without root: usbmuxd hands this Mac's pair
/// record to the user, and the pair record opens a TLS session with lockdownd. usbmuxd reaches iPhones on USB;
/// one that Xcode reaches over the network goes through a CoreDevice tunnel, which usbmuxd does not use.
/// The device talk runs in `isim-mcp device-log` (DeviceLog), a child process: jobs treat it like `log stream`
/// on a simulator, and a stuck connection never blocks the server.
public struct LockdownBackend: LogStreaming, LogQuerying {
    /// The isim-mcp executable, which has the device-log subcommand.
    public let helper: String
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning, helper: String = Bundle.main.executablePath ?? "isim-mcp") {
        self.runner = runner
        self.helper = helper
    }

    public func logStreamCommand(udid: String, filter: LogFilter) -> BackgroundCommand {
        BackgroundCommand(
            executable: helper, arguments: ["device-log", "--udid", udid] + DeviceLog.arguments(for: filter),
            noise: [NSRegularExpression.escapedPattern(for: DeviceLog.readyMarker)], readyMarker: DeviceLog.readyMarker)
    }

    /// Downloads the device's log archive (about 230 MB, mostly the shared cache's format strings: ~10 s over
    /// USB) and asks `log show` about it.
    public func queryLogs(udid: String, filter: LogFilter, last: Duration) async throws -> [String] {
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("isim-mcp-\(UUID().uuidString).logarchive", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: archive) }
        let seconds = max(1, Int(last.inSeconds.rounded(.up)))
        let download = try await runner.run(
            helper, ["device-log", "--udid", udid, "--archive", archive.path, "--last", "\(seconds)"], timeout: .seconds(600))
        guard download.succeeded else {
            throw ISimError.commandFailed(command: "isim-mcp device-log --archive", message: Self.lastLine(download))
        }
        var arguments = ["show", "--archive", archive.path, "--style", "compact", "--last", "\(seconds)s"]
        // `log show` leaves out info and debug entries unless asked.
        if filter.level != .default { arguments.append("--info") }
        if filter.level == .debug { arguments.append("--debug") }
        if let predicate = filter.predicateString { arguments += ["--predicate", predicate] }
        let result = try await runner.run("/usr/bin/log", arguments, timeout: .seconds(300))
        guard result.succeeded else { throw ISimError.commandFailed(command: "log show", message: Self.lastLine(result)) }
        return result.stdoutString.split(separator: "\n").map(String.init)
            .filter { line in !line.isEmpty && !Self.showNoise.contains { line.hasPrefix($0) } }
    }

    /// `log show`'s column header and the line naming its predicate.
    static let showNoise = ["Timestamp ", "Filtering the log data"]

    private static func lastLine(_ result: ProcessResult) -> String {
        (result.stderrString + "\n" + result.stdoutString).split(separator: "\n").last.map(String.init) ?? "exit code \(result.exitCode)"
    }
}

/// What `isim-mcp device-log` does.
public enum DeviceLog {
    /// The first line of a stream, once the device sends entries: start_log_capture waits for it.
    public static let readyMarker = "isim-mcp: streaming the unified log of"

    /// The subcommand's options for a filter.
    public static func arguments(for filter: LogFilter) -> [String] {
        var arguments: [String] = []
        if let app = filter.app { arguments += ["--bundle-id", app.bundleId, "--executable", app.executable] }
        if let process = filter.process { arguments += ["--process", process] }
        if let subsystem = filter.subsystem { arguments += ["--subsystem", subsystem] }
        if let predicate = filter.predicate { arguments += ["--predicate", predicate] }
        return arguments + ["--level", filter.level.rawValue]
    }

    /// Writes the entries that pass the filter to `output` as compact lines until the device closes the
    /// stream, which is an error: a capture ends by being stopped.
    public static func stream(udid: String, filter: LogFilter, to output: FileHandle) throws {
        let matcher = try EntryMatcher(filter)
        let lockdown = try LockdownClient(udid: udid)
        defer { lockdown.close() }
        let name = (try? lockdown.value("DeviceName")) as? String ?? udid
        try lockdown.startSession()
        let relay = try lockdown.startService(OSTraceRelay.service)
        try relay.write(LockdownClient.message(OSTraceRelay.startActivity))
        try OSTraceRelay.readReply(from: relay)
        try output.write(contentsOf: Data("\(readyMarker) \"\(name)\" (\(lockdown.device.connection))\n".utf8))
        while let frame = try OSTraceRelay.readFrame(from: relay, marker: 2) {
            guard let entry = try? OSTraceEntry(frame), matcher.matches(entry) else { continue }
            try output.write(contentsOf: Data((entry.compactLine + "\n").utf8))
        }
        throw LockdownError("The iPhone closed the log stream: it was unplugged or restarted. Start the capture again.")
    }

    /// Unpacks the device's log archive, from `last` seconds ago on, into `directory`: a .logarchive for `log show`.
    public static func archive(udid: String, last: TimeInterval, into directory: URL) throws {
        let lockdown = try LockdownClient(udid: udid)
        defer { lockdown.close() }
        try lockdown.startSession()
        let relay = try lockdown.startService(OSTraceRelay.service)
        // A minute more: the iPhone's clock may differ from the Mac's.
        try relay.write(LockdownClient.message(OSTraceRelay.createArchive(since: Date().addingTimeInterval(-last - 60))))
        try OSTraceRelay.readReply(from: relay)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-x", "-C", directory.path]
        let input = Pipe()
        let errors = Pipe()
        tar.standardInput = input
        tar.standardError = errors
        try tar.run()
        do {
            while let chunk = try OSTraceRelay.readFrame(from: relay, marker: 3) {
                try input.fileHandleForWriting.write(contentsOf: chunk)
            }
        } catch {
            tar.terminate()
            throw error
        }
        try input.fileHandleForWriting.close()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw LockdownError("Unpacking the iPhone's log archive failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}

/// The filter, applied on the Mac: os_trace_relay sends every process's entries.
struct EntryMatcher {
    let level: LogFilter.Level
    let predicate: ISLogPredicate?

    init(_ filter: LogFilter) throws {
        level = filter.level
        predicate = try filter.predicateString.map { format in
            var reason: NSString?
            guard let predicate = ISLogPredicate(format: format, error: &reason) else {
                throw LockdownError("The predicate does not parse: \(reason.map { $0 as String } ?? format)")
            }
            return predicate
        }
    }

    func matches(_ entry: OSTraceEntry) -> Bool {
        entry.passes(level) && (predicate?.matches(entry.predicateFields) ?? true)
    }
}
