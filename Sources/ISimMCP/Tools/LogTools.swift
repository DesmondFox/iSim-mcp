import DeviceCore
import Foundation
import MCP

/// Logs and diagnostics: unified log captures and queries, app output, crash reports.
enum LogTools {
    static let all: [ToolDefinition] = [startLogCapture, readLogCapture, stopLogCapture, queryLogs, listCrashReports, getCrashReport]

    static let filterProperties: [String: Value] = [
        "bundle_id": Schema.string("An app: entries of its process and of its subsystem (when the subsystem is its bundle id)."),
        "process": Schema.string("Entries of the process with this executable name, e.g. SpringBoard."),
        "subsystem": Schema.string("Entries of this os_log subsystem, e.g. com.example.app.network."),
        "predicate": Schema.string(#"A raw NSPredicate as `log` takes it, e.g. eventMessage CONTAINS "error"."#),
        "level": Schema.string("Lowest level to include. Default debug.", enum: LogFilter.Level.allCases.map(\.rawValue)),
    ]

    // MARK: Capture

    static let startLogCapture = ToolDefinition(
        name: "start_log_capture",
        toolset: .logs,
        description: """
            Start capturing a simulator's unified log (os_log, Logger, NSLog) into a job; read it with read_log_capture as it \
            grows. Narrow it with bundle_id, process, subsystem or predicate (at least one). An app's print() goes to stdout, not \
            the unified log: capture that with launch_app(capture_output: true). Simulators only.
            """,
        inputSchema: Schema.deviceObject(filterProperties),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        let device = try await context.session.resolveReady(try arguments.device)
        let streamer = try context.router.backend(.logStream, for: device, as: (any LogStreaming).self)
        let (filter, what) = try await logFilter(arguments, device: device, context: context)
        let job = try await context.jobs.start(
            .log, command: streamer.logStreamCommand(udid: device.udid, filter: filter), device: device, title: "unified log of \(what)")
        return .text("Capturing the unified log of \(what) on \"\(device.name)\" (level \(filter.level.rawValue)) as job \(job.id). "
            + "Read it with read_log_capture(job_id: \"\(job.id)\"); stop it with stop_log_capture.")
    }

    /// The filter from the tool's parameters, and what it captures in words.
    static func logFilter(_ arguments: ToolArguments, device: Device, context: ToolContext) async throws -> (LogFilter, String) {
        func nonEmpty(_ key: String) throws -> String? { try arguments.string(key).flatMap { $0.isEmpty ? nil : $0 } }
        var filter = LogFilter(
            process: try nonEmpty("process"), subsystem: try nonEmpty("subsystem"), predicate: try nonEmpty("predicate"),
            level: try arguments.choice("level", default: LogFilter.Level.debug))
        var what: [String] = []
        if let bundleId = try nonEmpty("bundle_id") {
            filter.app = (bundleId, try await context.simctl.executableName(udid: device.udid, bundleId: bundleId))
            what.append(bundleId)
        }
        if let process = filter.process { what.append("process \(process)") }
        if let subsystem = filter.subsystem { what.append("subsystem \(subsystem)") }
        if filter.predicate != nil { what.append("the predicate") }
        guard !filter.isEmpty else {
            throw ISimError.invalidArgument("Pass bundle_id, process, subsystem or predicate: the whole system log runs to thousands of lines a second.")
        }
        return (filter, what.joined(separator: ", "))
    }

    static let readLogCapture = ToolDefinition(
        name: "read_log_capture",
        toolset: .logs,
        description: """
            Read new lines of a log capture or of an app's output from launch_app(capture_output: true). Each call continues \
            where the previous one stopped; pass `cursor` from an earlier answer to read from there again. grep keeps only \
            lines containing the text (case-insensitive).
            """,
        inputSchema: Schema.object([
            "job_id": Schema.string("Job id from start_log_capture or launch_app. Default: the only log or output job."),
            "cursor": Schema.integer("Read from this cursor instead of where the last read stopped; 0 is the start.", minimum: 0),
            "max_lines": Schema.integer("At most this many lines.", default: 100, minimum: 1, maximum: 2000),
            "grep": Schema.string("Only lines containing this text, case-insensitive."),
        ]),
        annotations: .readOnly
    ) { arguments, context in
        let id = try await context.jobID(arguments, kinds: [.log, .console], running: false)
        let maxLines = try arguments.int("max_lines", default: 100, range: 1...2000)
        let grep = try arguments.string("grep").flatMap { $0.isEmpty ? nil : $0 }
        let cursor = try arguments.int("cursor").map { UInt64(max(0, $0)) }
        let chunk = try await context.jobs.read(id, cursor: cursor, maxLines: maxLines, grep: grep)
        let job = try await context.jobs.job(id)

        var lines = chunk.lines
        if lines.isEmpty {
            lines.append(grep == nil ? "No new lines." : "No new lines contain \"\(grep!)\".")
        }
        var footer = "— \(JobText.describe(job)); cursor \(chunk.cursor)"
        if chunk.skipped > 0 { footer += ", \(chunk.skipped) line(s) without \"\(grep ?? "")\" passed over" }
        footer += chunk.hasMore ? "; more lines are waiting: read again." : "."
        if !job.isRunning && !chunk.hasMore { footer += " The job has ended; its whole output is in \(job.log.path)." }
        return .text((lines + [footer]).joined(separator: "\n"))
    }

    static let stopLogCapture = ToolDefinition(
        name: "stop_log_capture",
        toolset: .logs,
        description: "Stop a log capture or an app's output capture (which terminates the app). The output stays readable with read_log_capture.",
        inputSchema: Schema.object([
            "job_id": Schema.string("Job to stop. Default: the only running log or output job."),
        ]),
        annotations: .mutating
    ) { arguments, context in
        let id = try await context.jobID(arguments, kinds: [.log, .console], running: true)
        guard let job = await context.jobs.stop(id) else { throw ISimError.notFound("No job \"\(id)\".") }
        let unread = (try? await context.jobs.read(id, maxLines: 0).hasMore) == true
        var text = "Stopped " + JobText.describe(job) + "."
        if job.kind == .console { text += " The app was terminated with it." }
        text += " Output: \(job.log.path)" + (unread ? "; unread lines remain for read_log_capture." : ".")
        return .text(text)
    }

    // MARK: Query

    static let queryLogs = ToolDefinition(
        name: "query_logs",
        toolset: .logs,
        description: """
            Unified log entries of the last few minutes from a simulator, the most recent max_lines of them: what happened \
            before a crash or a failed step. Filter with bundle_id, process, subsystem or predicate. Simulators only.
            """,
        inputSchema: Schema.deviceObject(filterProperties.merging([
            "last": Schema.string("How far back: 30s, 5m, 1h. Default 5m."),
            "max_lines": Schema.integer("At most this many of the latest lines.", default: 200, minimum: 1, maximum: 5000),
            "grep": Schema.string("Only lines containing this text, case-insensitive."),
        ]) { $1 }),
        annotations: .readOnly
    ) { arguments, context in
        try context.requireXcode()
        let lastText = try arguments.string("last").flatMap { $0.isEmpty ? nil : $0 } ?? "5m"
        guard let last = DurationText.parse(lastText) else { throw ISimError.invalidArgument("`last` must look like 30s, 5m or 1h.") }
        let maxLines = try arguments.int("max_lines", default: 200, range: 1...5000)
        let grep = try arguments.string("grep").flatMap { $0.isEmpty ? nil : $0 }
        let device = try await context.session.resolveReady(try arguments.device)
        let querier = try context.router.backend(.queryLogs, for: device, as: (any LogQuerying).self)
        let (filter, what) = try await logFilter(arguments, device: device, context: context)
        var lines = try await querier.queryLogs(udid: device.udid, filter: filter, last: last)
        if let grep { lines = lines.filter { $0.localizedCaseInsensitiveContains(grep) } }
        guard !lines.isEmpty else {
            return .text("No log entries of \(what) in the last \(lastText)" + (grep.map { " contain \"\($0)\"" } ?? "") + ".")
        }
        let shown = lines.suffix(maxLines)
        let header = "\(lines.count) entr\(lines.count == 1 ? "y" : "ies") of \(what) in the last \(lastText)"
            + (lines.count > shown.count ? ", the latest \(shown.count):" : ":")
        return .text(([header] + shown).joined(separator: "\n"))
    }

    // MARK: Crash reports

    static let listCrashReports = ToolDefinition(
        name: "list_crash_reports",
        toolset: .logs,
        description: """
            Crash reports (.ips) of the device's apps, newest first; get_crash_report explains one. By default only crashes; \
            include_other adds memory (jetsam), resource and hang reports.
            """,
        inputSchema: Schema.deviceObject([
            "bundle_id": Schema.string("Only reports of this app."),
            "since": Schema.string("Only reports newer than this: 30m, 2h, 3d."),
            "include_other": Schema.bool("Also reports that are not crashes.", default: false),
            "limit": Schema.integer("At most this many reports.", default: 20, minimum: 1, maximum: 500),
        ]),
        annotations: .readOnly
    ) { arguments, context in
        try context.requireXcode()
        let bundleId = try arguments.string("bundle_id").flatMap { $0.isEmpty ? nil : $0 }
        let since = try arguments.string("since").flatMap { $0.isEmpty ? nil : $0 }
        let cutoff = try since.map { text throws(ISimError) -> Date in
            guard let duration = DurationText.parse(text) else { throw .invalidArgument("`since` must look like 30m, 2h or 3d.") }
            return Date().addingTimeInterval(-duration.inSeconds)
        }
        let includeOther = try arguments.bool("include_other", default: false)
        let limit = try arguments.int("limit", default: 20, range: 1...500)
        let device = try await context.session.resolveReady(try arguments.device)
        let provider = try context.router.backend(.crashReports, for: device, as: (any CrashReportProviding).self)

        // iPhones list reports by file name, which starts with the process name.
        var executable: String?
        if let bundleId, device.kind == .physical {
            let details = try await context.router.backend(.appInfo, for: device, as: (any AppInspecting).self).appInfo(udid: device.udid, bundleId: bundleId)
            executable = details.app.path.flatMap { URL(string: $0)?.deletingPathExtension().lastPathComponent }
        }
        let reports = try await provider.crashReports(udid: device.udid).filter { report in
            (includeOther || report.kind == .crash)
                && (cutoff == nil || (report.date ?? .distantPast) >= cutoff!)
                && (bundleId == nil || report.bundleId == bundleId || (executable != nil && report.process == executable))
        }
        guard !reports.isEmpty else {
            return .text("No \(includeOther ? "" : "crash ")reports" + (bundleId.map { " of \($0)" } ?? "") + (since.map { " in the last \($0)" } ?? "")
                + " on \"\(device.name)\".")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = reports.prefix(limit).map { report in
            var line = report.name
            let who = [report.process, report.bundleId.map { "(\($0))" }].compactMap(\.self).joined(separator: " ")
            if !who.isEmpty { line += " — \(who)" }
            if report.kind != .crash { line += ", \(report.kind.rawValue)" }
            if let date = report.date { line += ", \(formatter.string(from: date))" }
            return line
        }
        if reports.count > limit { lines.append("… \(reports.count - limit) more") }
        return .text(lines.joined(separator: "\n"))
    }

    static let getCrashReport = ToolDefinition(
        name: "get_crash_report",
        toolset: .logs,
        description: "Explain a crash report: the exception, termination reason, what the code said, and the crashed thread's stack.",
        inputSchema: Schema.deviceObject([
            "name": Schema.string("Report name from list_crash_reports, e.g. MyApp-2026-10-23-123148.ips."),
            "max_frames": Schema.integer("Stack frames to show.", default: 25, minimum: 1, maximum: 500),
            "save_path": Schema.string("Also save the whole .ips to this path on the Mac."),
        ], required: ["name"]),
        annotations: .readOnly
    ) { arguments, context in
        try context.requireXcode()
        let name = try arguments.requiredString("name")
        let maxFrames = try arguments.int("max_frames", default: 25, range: 1...500)
        let device = try await context.session.resolveReady(try arguments.device)
        let data = try await context.router.backend(.crashReports, for: device, as: (any CrashReportProviding).self)
            .crashReport(udid: device.udid, name: name)
        var lines: [String] = []
        if let savePath = try arguments.string("save_path").flatMap({ $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }) {
            let url = URL(fileURLWithPath: savePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            lines.append("Saved to \(url.path)")
        }
        let report = try CrashReport.parse(data)
        return .text((describe(report, maxFrames: maxFrames) + lines).joined(separator: "\n"))
    }

    static func describe(_ report: CrashReport, maxFrames: Int) -> [String] {
        var title = report.process ?? "Unknown process"
        let app = [report.bundleId, report.version].compactMap(\.self).joined(separator: " ")
        if !app.isEmpty { title += " (\(app))" }
        title += report.isCrash ? " crashed" : " report"
        if let time = report.captureTime { title += " at \(time)" }
        if let os = report.os { title += ", \(os)" }
        var lines = [title]
        guard report.isCrash else {
            lines.append("Not a crash report (bug type \(report.bugType ?? "unknown")); save it with save_path to read it whole.")
            return lines
        }
        if let exception = report.exception { lines.append("Exception: \(exception)") }
        if let termination = report.termination { lines.append("Termination: \(termination)") }
        for text in report.applicationSpecific { lines.append("Message: \(text)") }
        if !report.exceptionBacktrace.isEmpty {
            lines.append("Last exception backtrace:")
            lines += frames(report.exceptionBacktrace, max: maxFrames)
        }
        if let thread = report.crashedThread {
            lines.append("Crashed thread \(thread)" + (report.crashedThreadName.map { " (\($0))" } ?? "") + ":")
            lines += frames(report.frames, max: maxFrames)
        }
        return lines
    }

    /// " 1  ISimTestApp          closure #6 in LabView.body.getter + 176"
    static func frames(_ frames: [CrashReport.Frame], max: Int) -> [String] {
        let width = min(28, frames.prefix(max).map { ($0.image ?? "?").count }.max() ?? 0)
        var lines = frames.prefix(max).enumerated().map { index, frame in
            let image = (frame.image ?? "?").padding(toLength: width, withPad: " ", startingAt: 0)
            let location = frame.symbol.map { $0 + (frame.offset.map { " + \($0)" } ?? "") } ?? frame.offset.map { "+ 0x" + String($0, radix: 16) } ?? ""
            return String(format: "%3d  ", index) + image + "  " + location
        }
        if frames.count > max { lines.append("     … \(frames.count - max) more frames") }
        return lines
    }
}

/// "30s", "5m", "1h", "2d" as durations.
enum DurationText {
    static func parse(_ text: String) -> Duration? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = trimmed.last, let value = Double(trimmed.dropLast()), value > 0 else { return nil }
        let seconds: Double? = switch unit {
        case "s": value
        case "m": value * 60
        case "h": value * 3600
        case "d": value * 86400
        default: nil
        }
        return seconds.map { .milliseconds(Int64($0 * 1000)) }
    }
}
