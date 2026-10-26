import Foundation
import ProcessKit

/// A command that keeps running in the background: a log stream, an app's console, a screen recording.
public struct BackgroundCommand: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    /// Regular expressions, anchored at the line start, for output lines that are the tool talking rather than
    /// the log: dropped when read.
    public var noise: [String]
    /// Printed once the command does its job (a recorder gets frames); start waits for it.
    public var readyMarker: String?

    public init(executable: String, arguments: [String], environment: [String: String] = [:], noise: [String] = [], readyMarker: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.noise = noise
        self.readyMarker = readyMarker
    }
}

/// Long-running commands with an id the tools pass around: log captures, app consoles, screen recordings.
/// Output goes to a file per job and is read from a cursor (a byte offset), so nothing is lost between reads
/// and the whole log stays on disk. All jobs stop when the server exits.
public actor JobManager {
    public enum Kind: String, Sendable {
        case log
        case console
        case recording

        var prefix: String {
            switch self {
            case .log: "log"
            case .console: "console"
            case .recording: "rec"
            }
        }
    }

    public struct Job: Sendable {
        public var id: String
        public var kind: Kind
        public var udid: String
        public var deviceName: String
        /// What is captured, e.g. "unified log of dev.example.app".
        public var title: String
        /// The command's output.
        public var log: URL
        /// The file the job produces besides its output: a recording's video.
        public var product: URL?
        public var startedAt: Date
        public var endedAt: Date?
        public var exitStatus: Int32?
        /// Ended because `stop` was called, not on its own.
        public var wasStopped = false
        public var isRunning: Bool { exitStatus == nil }
        fileprivate var process: any BackgroundProcess
        fileprivate var noise: NSRegularExpression?
        /// Where the command's output starts, after the launcher's command line.
        fileprivate var outputStart: UInt64
        /// Where a read without a cursor continues.
        fileprivate var readOffset: UInt64
    }

    /// One read: lines after the cursor and the cursor to continue from.
    public struct Chunk: Sendable, Equatable {
        public var lines: [String]
        public var cursor: UInt64
        /// Lines passed over because they did not match `grep`.
        public var skipped: Int
        /// Unread output remains after `cursor`.
        public var hasMore: Bool
    }

    private let launcher: any BackgroundLaunching
    private let directory: URL
    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private var counter = 0

    public init(launcher: any BackgroundLaunching, directory: URL = JobManager.defaultDirectory) {
        self.launcher = launcher
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("iSim-mcp/jobs", isDirectory: true)
    }

    // MARK: Starting

    /// Starts the command. With a `readyMarker`, returns once the output shows it, failing if the command
    /// exits first or `readyTimeout` passes.
    public func start(
        _ kind: Kind, command: BackgroundCommand, device: Device, title: String, product: URL? = nil, readyTimeout: Duration = .seconds(15)
    ) async throws -> Job {
        counter += 1
        let id = "\(kind.prefix)-\(counter)"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let log = directory.appendingPathComponent("\(id)-\(formatter.string(from: Date())).log")
        let process = try launcher.launch(command.executable, command.arguments, environment: command.environment, log: log)
        // The launcher writes the command line first; reads start after it.
        let header = FileManager.default.contents(atPath: log.path).flatMap { $0.firstIndex(of: UInt8(ascii: "\n")) }.map { UInt64($0 + 1) } ?? 0
        jobs[id] = Job(
            id: id, kind: kind, udid: device.udid, deviceName: device.name, title: title, log: log, product: product,
            startedAt: Date(), process: process, noise: Self.noisePattern(command.noise), outputStart: header, readOffset: header)
        order.append(id)
        Task { [weak self] in
            let status = await process.waitForExit()
            await self?.exited(id, status: status)
        }

        if let marker = command.readyMarker {
            let clock = ContinuousClock()
            let deadline = clock.now + readyTimeout
            while !(output(of: log, after: header).contains(marker)) {
                if !process.isRunning || jobs[id]?.exitStatus != nil {
                    throw ISimError.commandFailed(command: title, message: Self.lastLines(of: log, skipping: header) ?? "it exited right away")
                }
                guard clock.now < deadline else {
                    _ = await stop(id)
                    throw ISimError.commandFailed(command: title, message: "it did not start within \(Int(readyTimeout.inSeconds)) s. "
                        + (Self.lastLines(of: log, skipping: header) ?? ""))
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        return jobs[id]!
    }

    private func exited(_ id: String, status: Int32) {
        jobs[id]?.exitStatus = status
        jobs[id]?.endedAt = Date()
    }

    // MARK: Looking up

    public func job(_ id: String) throws(ISimError) -> Job {
        guard let job = jobs[id] else {
            throw .notFound("No job \"\(id)\". " + (order.isEmpty ? "No jobs were started in this session." : "Jobs: " + order.joined(separator: ", ") + "."))
        }
        return job
    }

    /// All jobs of the session, oldest first.
    public func all() -> [Job] {
        order.compactMap { jobs[$0] }
    }

    // MARK: Reading

    /// Up to `maxLines` lines after `cursor` (by default where the last read ended), only those containing `grep`
    /// (case-insensitive) if given. An unfinished last line waits for the next read while the job runs.
    public func read(_ id: String, cursor: UInt64? = nil, maxLines: Int, grep: String? = nil) throws -> Chunk {
        let job = try job(id)
        let start = max(cursor ?? job.readOffset, job.outputStart)
        guard let handle = FileHandle(forReadingAtPath: job.log.path) else {
            throw ISimError.notFound("The output of \(id) is gone: \(job.log.path)")
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard start < size else { return Chunk(lines: [], cursor: start, skipped: 0, hasMore: false) }
        try handle.seek(toOffset: start)
        // A bounded slice: a busy log can hold far more than one answer shows.
        let data = try handle.read(upToCount: Self.readLimit) ?? Data()

        var lines: [String] = []
        var skipped = 0
        var consumed = 0
        var lineStart = 0
        var hasMore = false
        let reachedEnd = start + UInt64(data.count) >= size
        while lineStart < data.count {
            let newline = data[lineStart...].firstIndex(of: UInt8(ascii: "\n"))
            guard newline != nil || (reachedEnd && !job.isRunning) else { break }
            let lineEnd = newline ?? data.count
            let next = newline.map { $0 + 1 } ?? data.count
            let line = String(decoding: data[lineStart..<lineEnd], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if !line.isEmpty, !(job.noise?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil) {
                if let grep, !line.localizedCaseInsensitiveContains(grep) {
                    skipped += 1
                } else {
                    if lines.count == maxLines {
                        hasMore = true
                        break
                    }
                    lines.append(line)
                }
            }
            consumed = next
            lineStart = next
        }
        let newCursor = start + UInt64(consumed)
        // Past the slice there is more; an unfinished last line is not "more" until it ends.
        if !reachedEnd { hasMore = true }
        jobs[id]?.readOffset = newCursor
        return Chunk(lines: lines, cursor: newCursor, skipped: skipped, hasMore: hasMore)
    }

    static let readLimit = 4 << 20

    // MARK: Stopping

    /// Stops the job and waits for it to exit: a recording gets SIGINT and time to finish its file,
    /// anything else SIGTERM. A finished job is returned as it is.
    @discardableResult
    public func stop(_ id: String, timeout: Duration = .seconds(30)) async -> Job? {
        guard let job = jobs[id] else { return nil }
        guard job.isRunning else { return job }
        jobs[id]?.wasStopped = true
        if job.kind == .recording { job.process.interrupt() } else { job.process.terminate() }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while jobs[id]?.exitStatus == nil && job.process.isRunning && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if job.process.isRunning { job.process.terminate() }
        if jobs[id]?.exitStatus == nil {
            var status: Int32 = -1
            if !job.process.isRunning { status = await job.process.waitForExit() }
            jobs[id]?.exitStatus = status
            jobs[id]?.endedAt = Date()
        }
        return jobs[id]
    }

    /// Stops every running job: recordings first get the chance to finish their files.
    public func stopAll() async {
        await withTaskGroup(of: Void.self) { group in
            for id in order where jobs[id]?.isRunning == true {
                group.addTask { await self.stop(id, timeout: .seconds(10)) }
            }
        }
    }

    // MARK: Helpers

    /// One expression for all noise patterns: `^(?:a|b)`.
    static func noisePattern(_ patterns: [String]) -> NSRegularExpression? {
        guard !patterns.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: "^(?:" + patterns.map { "(?:\($0))" }.joined(separator: "|") + ")")
    }

    /// The command's output after the launcher's command line, which may quote the marker itself.
    private func output(of log: URL, after header: UInt64) -> String {
        FileManager.default.contents(atPath: log.path).map { String(decoding: $0.dropFirst(Int(header)), as: UTF8.self) } ?? ""
    }

    /// The last few lines of a job's output, for an error message.
    static func lastLines(of log: URL, skipping header: UInt64, count: Int = 5) -> String? {
        guard let data = FileManager.default.contents(atPath: log.path), UInt64(data.count) > header else { return nil }
        let lines = String(decoding: data.dropFirst(Int(header)), as: UTF8.self).split(separator: "\n").suffix(count)
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}
