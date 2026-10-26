import Foundation

// Logs and crash reports: what the `logs` tools filter, list and parse.

/// Which unified log entries to capture or query; the parts are combined with AND.
public struct LogFilter: Sendable, Equatable {
    public enum Level: String, Sendable, CaseIterable {
        case `default`
        case info
        case debug
    }

    /// An app: entries of its process (by executable name) or of its subsystem (its bundle id).
    public var app: (bundleId: String, executable: String)?
    public var process: String?
    public var subsystem: String?
    /// A raw NSPredicate, as `log stream --predicate` takes it.
    public var predicate: String?
    public var level: Level

    public init(app: (bundleId: String, executable: String)? = nil, process: String? = nil, subsystem: String? = nil, predicate: String? = nil, level: Level = .debug) {
        self.app = app
        self.process = process
        self.subsystem = subsystem
        self.predicate = predicate
        self.level = level
    }

    public var isEmpty: Bool { app == nil && process == nil && subsystem == nil && predicate == nil }

    /// The NSPredicate for `log stream` and `log show`, nil without conditions.
    public var predicateString: String? {
        var clauses: [String] = []
        if let app { clauses.append("(process == \(quote(app.executable)) OR subsystem == \(quote(app.bundleId)))") }
        if let process { clauses.append("process == \(quote(process))") }
        if let subsystem { clauses.append("subsystem == \(quote(subsystem))") }
        if let predicate { clauses.append("(\(predicate))") }
        return clauses.isEmpty ? nil : clauses.joined(separator: " AND ")
    }

    private func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func == (lhs: LogFilter, rhs: LogFilter) -> Bool {
        lhs.predicateString == rhs.predicateString && lhs.level == rhs.level
    }
}

/// A diagnostic report as the device lists it.
public struct CrashReportEntry: Sendable, Equatable {
    /// File name, e.g. "ISimTestApp-2026-10-23-123148.ips"; get_crash_report takes it.
    public var name: String
    public var date: Date?
    public var process: String?
    public var bundleId: String?
    public var kind: Kind

    public enum Kind: String, Sendable {
        case crash
        /// The system killed processes to free memory (JetsamEvent).
        case jetsam
        /// A process used too much CPU, disk writes or wakeups.
        case resource
        case stackshot
        case other
    }

    public init(name: String, date: Date?, process: String?, bundleId: String?, kind: Kind) {
        self.name = name
        self.date = date
        self.process = process
        self.bundleId = bundleId
        self.kind = kind
    }

    /// From the report's `bug_type`, or its file name when the contents are not at hand (iPhones list names only).
    public static func kind(bugType: String?, name: String) -> Kind {
        switch bugType {
        case "109", "309": return .crash
        case "298": return .jetsam
        case "288", "385": return .stackshot
        case "145", "202", "142": return .resource
        case .some: return .other
        case nil: break
        }
        if name.hasPrefix("JetsamEvent") { return .jetsam }
        if name.hasPrefix("stacks") { return .stackshot }
        if name.contains("_resource") { return .resource }
        return processName(fromFileName: name) == nil ? .other : .crash
    }

    /// "ISimTestApp-2026-10-23-123148.ips" or "…-123148.0002.ips" → "ISimTestApp".
    public static func processName(fromFileName name: String) -> String? {
        let pattern = #"^(.+?)-\d{4}-\d{2}-\d{2}-\d{6}(\.\d+)?\.ips$"#
        guard let match = name.range(of: pattern, options: .regularExpression) else { return nil }
        let base = String(name[match])
        guard let dash = base.range(of: #"-\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { return nil }
        return String(base[..<dash.lowerBound])
    }
}

/// The parts of an .ips crash report that explain a crash: header line + JSON body (iOS 15 and later).
public struct CrashReport: Sendable, Equatable {
    public struct Frame: Sendable, Equatable {
        public var image: String?
        public var symbol: String?
        /// Bytes into the symbol, or into the image when there is no symbol.
        public var offset: Int?

        public init(image: String?, symbol: String?, offset: Int?) {
            self.image = image
            self.symbol = symbol
            self.offset = offset
        }
    }

    public var process: String?
    public var bundleId: String?
    public var version: String?
    public var captureTime: String?
    public var os: String?
    public var bugType: String?
    /// "EXC_BREAKPOINT (SIGTRAP), codes 0x1, 0x1c16c415c"
    public var exception: String?
    /// "SIGNAL 5 Trace/BPT trap: 5"
    public var termination: String?
    /// What the crashing code said: Swift runtime errors, NSException reasons.
    public var applicationSpecific: [String]
    public var crashedThread: Int?
    /// Name or dispatch queue of the crashed thread.
    public var crashedThreadName: String?
    public var frames: [Frame]
    /// Where an Objective-C exception was thrown.
    public var exceptionBacktrace: [Frame]

    public var isCrash: Bool { exception != nil || !frames.isEmpty }

    public static func parse(_ data: Data) throws(ISimError) -> CrashReport {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = lines.first,
              let header = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any]
        else { throw .invalidArgument("Not an .ips report: the first line is not JSON.") }
        let body = lines.count > 1
            ? (try? JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]) ?? [:]
            : [:]

        let bundle = body["bundleInfo"] as? [String: Any] ?? [:]
        var report = CrashReport(
            process: body["procName"] as? String ?? header["app_name"] as? String ?? header["name"] as? String,
            bundleId: bundle["CFBundleIdentifier"] as? String ?? header["bundleID"] as? String,
            version: version(short: bundle["CFBundleShortVersionString"] ?? header["app_version"], build: bundle["CFBundleVersion"] ?? header["build_version"]),
            captureTime: body["captureTime"] as? String ?? header["timestamp"] as? String,
            os: header["os_version"] as? String,
            bugType: header["bug_type"] as? String,
            applicationSpecific: [],
            frames: [],
            exceptionBacktrace: []
        )

        if let exception = body["exception"] as? [String: Any], let type = exception["type"] as? String {
            var text = type
            if let signal = exception["signal"] as? String { text += " (\(signal))" }
            if let subtype = exception["subtype"] as? String { text += ", \(subtype)" }
            if let codes = exception["codes"] as? String { text += ", codes \(codes)" }
            report.exception = text
        }
        if let termination = body["termination"] as? [String: Any] {
            var parts = [termination["namespace"] as? String, (termination["code"] as? NSNumber).map { "\($0)" }].compactMap(\.self)
            if let indicator = termination["indicator"] as? String { parts.append(indicator) }
            if let reasons = termination["reasons"] as? [String] { parts += reasons }
            report.termination = parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        if let asi = body["asi"] as? [String: Any] {
            report.applicationSpecific = asi.keys.sorted().flatMap { asi[$0] as? [String] ?? [] }
        }

        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? ($0["path"] as? String).map { ($0 as NSString).lastPathComponent } }
        func frames(_ list: Any?) -> [Frame] {
            (list as? [[String: Any]] ?? []).map { frame in
                let image = (frame["imageIndex"] as? Int).flatMap { $0 < images.count ? images[$0] : nil }
                let symbol = frame["symbol"] as? String
                return Frame(image: image, symbol: symbol, offset: (symbol != nil ? frame["symbolLocation"] : frame["imageOffset"]) as? Int)
            }
        }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let crashed = body["faultingThread"] as? Int ?? threads.firstIndex { $0["triggered"] as? Bool == true }
        if let crashed, crashed < threads.count {
            report.crashedThread = crashed
            report.crashedThreadName = threads[crashed]["name"] as? String ?? threads[crashed]["queue"] as? String
            report.frames = frames(threads[crashed]["frames"])
        }
        report.exceptionBacktrace = frames(body["lastExceptionBacktrace"])
        return report
    }

    private static func version(short: Any?, build: Any?) -> String? {
        guard let short = short as? String else { return build as? String }
        guard let build = build as? String, build != short else { return short }
        return "\(short) (\(build))"
    }
}
