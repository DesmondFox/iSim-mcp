import DeviceCore
import Foundation

/// com.apple.os_trace_relay, the lockdown service behind Console.app's device log. Requests use lockdown's
/// framing; the reply is 0x01, a big-endian length and a plist with `Status`. After that StartActivity sends
/// entries as 0x02, a little-endian length and the entry, and CreateArchive sends a tar of a .logarchive in
/// pieces, 0x03, a little-endian length and the bytes, until the device closes the connection.
enum OSTraceRelay {
    static let service = "com.apple.os_trace_relay"

    /// Every process (pid -1) and every kind of message; filtering happens on the Mac.
    static var startActivity: [String: Any] { ["Request": "StartActivity", "MessageFilter": 65535, "Pid": -1, "StreamFlags": 60] }

    /// The archive keeps whole trace files: entries from well before `start` come along, and the
    /// shared cache's format strings (~200 MB) always do.
    static func createArchive(since start: Date) -> [String: Any] {
        ["Request": "CreateArchive", "StartTime": Int(start.timeIntervalSince1970)]
    }

    static func readReply(from stream: some ByteStream) throws {
        let head = try stream.read(exactly: 5)
        guard head[head.startIndex] == 1 else { throw LockdownError("os_trace_relay sent an unexpected reply.") }
        let length = head.dropFirst().withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard length < 1 << 20,
              let reply = try? PropertyListSerialization.propertyList(from: try stream.read(exactly: Int(length)), format: nil) as? [String: Any]
        else { throw LockdownError("os_trace_relay sent a malformed reply.") }
        guard reply["Status"] as? String == "RequestSuccessful" else {
            throw LockdownError("os_trace_relay refused the request: \(reply["Status"] ?? reply).")
        }
    }

    /// The next frame's payload, or nil once the device has closed the connection.
    static func readFrame(from stream: some ByteStream, marker: UInt8) throws -> Data? {
        guard let first = try stream.read(upTo: 1).first else { return nil }
        guard first == marker else { throw LockdownError("os_trace_relay sent an unexpected frame (\(first)).") }
        let length = try stream.read(exactly: 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard length < 64 << 20 else { throw LockdownError("os_trace_relay sent a malformed frame.") }
        return try stream.read(exactly: Int(length))
    }
}

/// One entry of os_trace_relay's stream, its message already formatted (private arguments as `<private>`).
public struct OSTraceEntry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case activity
        case log
        case other(UInt8)
    }

    public enum Level: Sendable, Equatable {
        case `default`, info, debug, error, fault
        case other(UInt8)

        init(_ raw: UInt8) {
            self = switch raw {
            case 0: .default
            case 1: .info
            case 2: .debug
            case 0x10: .error
            case 0x11: .fault
            default: .other(raw)
            }
        }

        /// As `log` predicates name it (`logType == "error"`).
        public var name: String {
            switch self {
            case .default: "default"
            case .info: "info"
            case .debug: "debug"
            case .error: "error"
            case .fault: "fault"
            case .other(let raw): "\(raw)"
            }
        }
    }

    public var kind: Kind
    public var level: Level
    public var pid: Int32
    public var threadID: UInt64
    public var date: Date
    public var processPath: String
    /// The library or executable that logged it.
    public var senderPath: String
    public var message: String
    public var subsystem: String?
    public var category: String?

    public var process: String { (processPath as NSString).lastPathComponent }
    public var sender: String { (senderPath as NSString).lastPathComponent }

    // Byte offsets in an entry, found by looking at the stream (pymobiledevice3 reads the same):
    //   9 pid (u32)   55 seconds (u32)   63 microseconds (u32)   67 kind (2 activity, 4 log)   68 level
    //   83 thread id (u64)   107 sender path size (u16)   109 message size (u16)
    //   117 subsystem size (u32)   121 category size (u32), present on log entries only
    //   129 the process path up to a NUL, then sender path, message, subsystem and category, each with its NUL.
    public init(_ data: Data) throws {
        let bytes = [UInt8](data)
        let malformed = LockdownError("os_trace_relay sent a malformed entry.")
        guard bytes.count > 129 else { throw malformed }
        func integer<T: FixedWidthInteger>(_ offset: Int, as _: T.Type) -> T {
            bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self).littleEndian }
        }
        kind = switch bytes[67] {
        case 2: .activity
        case 4: .log
        default: .other(bytes[67])
        }
        level = Level(bytes[68])
        pid = integer(9, as: Int32.self)
        threadID = integer(83, as: UInt64.self)
        date = Date(timeIntervalSince1970: Double(integer(55, as: UInt32.self)) + Double(integer(63, as: UInt32.self)) / 1_000_000)

        guard let processEnd = bytes[129...].firstIndex(of: 0) else { throw malformed }
        processPath = String(decoding: bytes[129..<processEnd], as: UTF8.self)
        var offset = processEnd + 1
        func string(_ size: Int) throws -> String {
            guard size >= 0, offset + size <= bytes.count else { throw malformed }
            defer { offset += size }
            let field = bytes[offset..<offset + size]
            return String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
        }
        senderPath = try string(Int(integer(107, as: UInt16.self)))
        message = try string(Int(integer(109, as: UInt16.self)))
        // Activities reuse the size fields for something else: trust them only when they account for the rest.
        let subsystemSize = Int(integer(117, as: UInt32.self))
        let categorySize = Int(integer(121, as: UInt32.self))
        if subsystemSize > 0, bytes.count - offset == subsystemSize + categorySize {
            subsystem = try string(subsystemSize)
            category = try string(categorySize)
        }
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// As `log stream --style compact` prints it, so iPhone and simulator captures read alike:
    /// `2026-10-26 16:36:08.107 E  SpringBoard[8681:4a5132] [com.apple.CoreBrightness:default] message`.
    public var compactLine: String {
        let type = switch (kind, level) {
        case (.activity, _): "A "
        case (_, .default): "Df"
        case (_, .info): "I "
        case (_, .debug): "Db"
        case (_, .error): "E "
        case (_, .fault): "F "
        case (_, .other): "? "
        }
        let source = subsystem.map { "[\($0):\(category ?? "")] " } ?? (senderPath.isEmpty ? "" : "(\(sender)) ")
        return "\(Self.timestamp.string(from: date)) \(type) \(process)[\(pid):\(String(threadID, radix: 16))] \(source)\(message)"
    }

    /// What a `log` predicate can ask about, under `log`'s field names (and the older eventMessage and messageType).
    public var predicateFields: [String: Any] {
        var fields: [String: Any] = [
            "composedMessage": message, "eventMessage": message,
            "process": process, "processImagePath": processPath, "processIdentifier": Int(pid),
            "sender": sender, "senderImagePath": senderPath,
            "logType": level.name, "messageType": level.name,
            "threadIdentifier": threadID, "date": date,
            "type": kind == .activity ? "activityCreateEvent" : "logEvent",
        ]
        fields["eventType"] = fields["type"]
        if let subsystem { fields["subsystem"] = subsystem }
        if let category { fields["category"] = category }
        return fields
    }

    /// Whether `log stream --level` would show it: default shows default, error and fault; info adds info
    /// entries and activities; debug shows everything.
    public func passes(_ level: LogFilter.Level) -> Bool {
        switch level {
        case .debug: true
        case .info: self.level != .debug
        case .default: kind != .activity && ![.info, .debug].contains(self.level)
        }
    }
}
