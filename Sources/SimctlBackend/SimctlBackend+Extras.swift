import DeviceCore
import Foundation
import ProcessKit

// Simulator-only operations of phase 5: cloning, recording, logs, crash reports, app data, keychain, locale.

extension SimctlBackend: DeviceCloning, DeviceRenaming, ScreenRecording, LogStreaming, LogQuerying, ConsoleLaunching,
    CrashReportProviding, ContainerFileAccessing, UserDefaultsReading, UserDefaultsWriting, KeychainManaging, LocaleConfiguring,
    ICloudSyncing, ShakeSimulating, DarwinNotificationPosting, ProcessSpawning
{
    // MARK: Devices

    public func clone(udid: String, name: String) async throws -> String {
        let result = try await simctl(["clone", udid, name], timeout: .seconds(300))
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func rename(udid: String, name: String) async throws {
        try await simctl(["rename", udid, name])
    }

    // MARK: Recording

    /// simctl writes a QuickTime movie whatever the extension.
    public var videoFileExtension: String { "mov" }

    public func recordingCommand(udid: String, path: String, codec: VideoCodec) -> BackgroundCommand {
        BackgroundCommand(
            executable: xcrun, arguments: ["simctl", "io", udid, "recordVideo", "--codec=\(codec.rawValue)", "--force", path],
            readyMarker: "Recording started")
    }

    // MARK: Logs

    /// What `log` and simctl print besides entries: a warning about the simulator's user, the filter, the column header,
    /// the stream ending.
    static let logNoise = ["getpwuid_r did not find", "Filtering the log data", "Timestamp ", "Child process terminated with signal"]

    /// Printed into every app's stderr while accessibility is on in a simulator.
    static let consoleNoise = [#"objc\[\d+\]: Class \S+ is implemented in both "#, "Child process terminated with signal"]

    public func logStreamCommand(udid: String, filter: LogFilter) -> BackgroundCommand {
        BackgroundCommand(
            executable: xcrun,
            arguments: ["simctl", "spawn", udid, "log", "stream", "--style", "compact", "--level", filter.level.rawValue]
                + (filter.predicateString.map { ["--predicate", $0] } ?? []),
            noise: Self.logNoise)
    }

    public func queryLogs(udid: String, filter: LogFilter, last: Duration) async throws -> [String] {
        var arguments = ["spawn", udid, "log", "show", "--style", "compact", "--last", "\(max(1, Int(last.inSeconds.rounded(.up))))s"]
        // `log show` leaves out info and debug entries unless asked.
        if filter.level != .default { arguments.append("--info") }
        if filter.level == .debug { arguments.append("--debug") }
        if let predicate = filter.predicateString { arguments += ["--predicate", predicate] }
        let result = try await simctl(arguments, timeout: .seconds(180))
        return result.stdoutString.split(separator: "\n").map(String.init)
            .filter { line in !line.isEmpty && !Self.logNoise.contains { line.hasPrefix($0) } }
    }

    /// The executable of an installed app: log entries name processes by it.
    public func executableName(udid: String, bundleId: String) async throws -> String {
        let result = try await runner.run(xcrun, ["simctl", "appinfo", udid, bundleId], timeout: defaultTimeout)
        if result.stderrString.contains("No application record found") { throw Self.notInstalled(bundleId) }
        guard result.succeeded else { throw Self.failure(["appinfo"], result) }
        guard
            let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any],
            let executable = plist["CFBundleExecutable"] as? String
        else { throw Self.notInstalled(bundleId) }
        return executable
    }

    /// `--console-pty`: through a terminal the app flushes every line of stdout, through a pipe only when its buffer fills.
    public func consoleCommand(udid: String, bundleId: String, options: LaunchOptions) -> BackgroundCommand {
        var arguments = ["simctl", "launch", "--console-pty"]
        if options.terminateExisting { arguments.append("--terminate-running-process") }
        if options.startStopped { arguments.append("--wait-for-debugger") }
        arguments += [udid, bundleId] + options.arguments
        let environment = Dictionary(uniqueKeysWithValues: options.environment.map { ("SIMCTL_CHILD_\($0.key)", $0.value) })
        // simctl's own "<bundle id>: <pid>" line reaches the output only when simctl exits: its stdout is a file.
        let ownLine = "\(NSRegularExpression.escapedPattern(for: bundleId)): \\d+$"
        return BackgroundCommand(executable: xcrun, arguments: arguments, environment: environment, noise: [ownLine] + Self.consoleNoise)
    }

    // MARK: Crash reports

    /// Reports of this simulator's processes among the Mac's: iOS-simulator platform, path inside the device.
    public func crashReports(udid: String) async throws -> [CrashReportEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: diagnosticReports, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        var entries: [CrashReportEntry] = []
        for file in files where file.pathExtension == "ips" {
            guard let head = Self.head(of: file), head.body.contains(udid) else { continue }
            let header = head.header
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            entries.append(CrashReportEntry(
                name: file.lastPathComponent, date: date,
                process: header["app_name"] as? String ?? header["name"] as? String,
                bundleId: header["bundleID"] as? String,
                kind: CrashReportEntry.kind(bugType: header["bug_type"] as? String, name: file.lastPathComponent)))
        }
        return entries.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    public func crashReport(udid: String, name: String) async throws -> Data {
        let file = diagnosticReports.appendingPathComponent(name)
        guard !name.contains("/"), let data = FileManager.default.contents(atPath: file.path),
              Self.head(of: file)?.body.contains(udid) == true
        else {
            throw ISimError.notFound("No crash report \"\(name)\" of this simulator. Use list_crash_reports to see its reports.")
        }
        return data
    }

    /// The header line and the start of the body, enough to tell whose report it is.
    private static func head(of file: URL) -> (header: [String: Any], body: String)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_384), let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let header = try? JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any],
              (header["platform"] as? Int).map({ $0 == 7 }) ?? true
        else { return nil }
        return (header, String(decoding: data[newline...], as: UTF8.self))
    }

    // MARK: Container files

    func containerRoot(udid: String, bundleId: String, container: AppContainer) async throws -> URL {
        let name = switch container {
        case .data: "data"
        case .group(let identifier): identifier
        }
        return URL(fileURLWithPath: try await containerPath(udid: udid, bundleId: bundleId, container: name), isDirectory: true)
    }

    public func listFiles(udid: String, bundleId: String, container: AppContainer, subpath: String, depth: Int) async throws -> [ContainerFile] {
        let root = try await containerRoot(udid: udid, bundleId: bundleId, container: container)
        let relative = try ContainerPath.normalize(subpath)
        let start = relative.isEmpty ? root : root.appendingPathComponent(relative)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: start.path, isDirectory: &isDirectory) else {
            throw ISimError.notFound("\(relative.isEmpty ? "The container" : "\"\(relative)\"") does not exist in the \(container) of \(bundleId).")
        }
        guard isDirectory.boolValue else { return [Self.containerFile(start, path: relative)] }
        return Self.enumerate(start, as: relative, depth: depth)
    }

    private static let fileKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]

    private static func containerFile(_ url: URL, path: String) -> ContainerFile {
        let values = try? url.resourceValues(forKeys: Set(fileKeys))
        return ContainerFile(path: path, isDirectory: values?.isDirectory ?? false, size: values?.fileSize, modified: values?.contentModificationDate)
    }

    /// Entries under `start` down to `depth` levels, named `relative`/… .
    private static func enumerate(_ start: URL, as relative: String, depth: Int) -> [ContainerFile] {
        guard let enumerator = FileManager.default.enumerator(at: start, includingPropertiesForKeys: fileKeys) else { return [] }
        var files: [ContainerFile] = []
        let prefix = start.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            if enumerator.level >= depth { enumerator.skipDescendants() }
            let inside = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            files.append(containerFile(url, path: relative.isEmpty ? inside : relative + "/" + inside))
        }
        return files.sorted { $0.path < $1.path }
    }

    public func readFile(udid: String, bundleId: String, container: AppContainer, path: String, to destination: URL) async throws {
        let file = try await containerRoot(udid: udid, bundleId: bundleId, container: container).appendingPathComponent(try ContainerPath.normalize(path))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
            throw ISimError.notFound("\"\(path)\" does not exist in the \(container) of \(bundleId). Use list_container_files to see its files.")
        }
        guard !isDirectory.boolValue else { throw ISimError.invalidArgument("\"\(path)\" is a directory; list it with list_container_files.") }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: file, to: destination)
    }

    public func writeFile(udid: String, bundleId: String, container: AppContainer, path: String, from source: URL) async throws {
        let relative = try ContainerPath.normalize(path)
        guard !relative.isEmpty else { throw ISimError.invalidArgument("`path` must name a file inside the container.") }
        let file = try await containerRoot(udid: udid, bundleId: bundleId, container: container).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.copyItem(at: source, to: file)
    }

    // MARK: User defaults

    /// The preferences file without its extension, which is how `defaults` takes a domain outside the simulator's home.
    /// Going through `defaults` inside the simulator keeps cfprefsd, and so the running app, in the loop.
    func preferencesDomain(udid: String, bundleId: String, suite: String?) async throws -> String {
        let domain = suite ?? bundleId
        let container: AppContainer = domain.hasPrefix("group.") ? .group(domain) : .data
        let root = try await containerRoot(udid: udid, bundleId: bundleId, container: container)
        return root.appendingPathComponent("Library/Preferences/\(domain)").path
    }

    public func userDefaults(udid: String, bundleId: String, suite: String?) async throws -> Data {
        let domain = try await preferencesDomain(udid: udid, bundleId: bundleId, suite: suite)
        return try await simctl(["spawn", udid, "defaults", "export", domain, "-"]).stdout
    }

    public func writeUserDefault(udid: String, bundleId: String, suite: String?, key: String, value: String?) async throws {
        let domain = try await preferencesDomain(udid: udid, bundleId: bundleId, suite: suite)
        guard let value else {
            let result = try await runner.run(xcrun, ["simctl", "spawn", udid, "defaults", "delete", domain, key], timeout: defaultTimeout)
            guard result.succeeded else {
                throw ISimError.notFound("\(bundleId) has no default \"\(key)\"\(suite.map { " in suite \($0)" } ?? "").")
            }
            return
        }
        try await simctl(["spawn", udid, "defaults", "write", domain, key, value])
    }

    // MARK: Keychain

    public func addCertificate(udid: String, path: String, trustedRoot: Bool) async throws {
        try await simctl(["keychain", udid, trustedRoot ? "add-root-cert" : "add-cert", path])
    }

    public func resetKeychain(udid: String) async throws {
        try await simctl(["keychain", udid, "reset"])
    }

    // MARK: Locale

    public func locale(udid: String) async throws -> DeviceLocale {
        let data = try await simctl(["spawn", udid, "defaults", "export", "-g", "-"]).stdout
        let global = (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]) ?? [:]
        return DeviceLocale(languages: global["AppleLanguages"] as? [String] ?? [], locale: global["AppleLocale"] as? String)
    }

    /// Only writes the preferences: the system UI picks them up after a reboot.
    public func setLocale(udid: String, languages: [String]?, locale: String?) async throws {
        if let languages { try await simctl(["spawn", udid, "defaults", "write", "-g", "AppleLanguages", "-array"] + languages) }
        if let locale { try await simctl(["spawn", udid, "defaults", "write", "-g", "AppleLocale", "-string", locale]) }
    }

    // MARK: System

    public func syncICloud(udid: String) async throws {
        try await simctl(["icloud_sync", udid], timeout: .seconds(120))
    }

    /// What the Simulator app's Shake Gesture did: UIKit inside the simulator turns this notification into a shake event.
    public func shake(udid: String) async throws {
        try await postDarwinNotification(udid: udid, name: "com.apple.UIKit.SimulatorShake")
    }

    public func postDarwinNotification(udid: String, name: String) async throws {
        try await simctl(["spawn", udid, "notifyutil", "-p", name])
    }

    public func spawn(udid: String, executable: String, arguments: [String], timeout: Duration) async throws -> ProcessResult {
        try await runner.run(xcrun, ["simctl", "spawn", udid, executable] + arguments, timeout: timeout)
    }
}
