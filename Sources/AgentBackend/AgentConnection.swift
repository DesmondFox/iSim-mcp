import Foundation

/// Where an agent listens: a port on this Mac (a simulator shares the Mac's network), or a port on an iPhone,
/// reached through usbmuxd over USB or Wi-Fi.
public enum AgentEndpoint: Sendable, Equatable, CustomStringConvertible {
    case local(port: UInt16)
    case device(udid: String, port: UInt16)

    public var description: String {
        switch self {
        case .local(let port): "127.0.0.1:\(port)"
        case .device(let udid, let port): "port \(port) on \(udid) via usbmuxd"
        }
    }
}

public enum AgentConnectionError: Error, CustomStringConvertible, Equatable {
    /// Nothing listens: the agent is not running (or usbmuxd does not see the device).
    case refused(String)
    /// The connection broke or timed out mid-request: the agent may have crashed.
    case transfer(String)
    /// The agent answered with an error.
    case agent(status: Int, message: String)

    public var description: String {
        switch self {
        case .refused(let message), .transfer(let message): message
        case .agent(_, let message): "The UI agent failed: \(message)"
        }
    }
}

/// One HTTP/1.1 request per connection, as the agent serves them. Blocking sockets on a private queue.
public struct AgentClient: Sendable {
    public let endpoint: AgentEndpoint

    public init(endpoint: AgentEndpoint) {
        self.endpoint = endpoint
    }

    private static let queue = DispatchQueue(label: "isim.agent.client", attributes: .concurrent)

    /// The agent's JSON reply; `ok: false` replies throw `.agent`.
    public func request(_ method: String, _ path: String, body: Data? = nil, timeout: Duration = .seconds(30)) async throws -> Data {
        let endpoint = endpoint
        let reply: (status: Int, body: Data) = try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result { try Self.exchange(endpoint, method, path, body: body ?? Data(), timeout: timeout) })
            }
        }
        if reply.status != 200 {
            let json = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any]
            let message = json?["error"] as? String ?? String(decoding: reply.body.prefix(500), as: UTF8.self)
            throw AgentConnectionError.agent(status: reply.status, message: message)
        }
        return reply.body
    }

    private static func exchange(_ endpoint: AgentEndpoint, _ method: String, _ path: String, body: Data, timeout: Duration) throws -> (Int, Data) {
        let socket: Socket
        switch endpoint {
        case .local(let port): socket = try Socket.tcp(port: port)
        case .device(let udid, let port): socket = try USBMux.connect(udid: udid, port: port)
        }
        defer { socket.close() }
        socket.setTimeout(timeout)
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        head += "\r\n"
        do {
            try socket.write(Data(head.utf8) + body)
        } catch {
            throw AgentConnectionError.transfer("Sending \(method) \(path) to the UI agent failed: \(error)")
        }
        let response = socket.readToEnd()
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else {
            throw AgentConnectionError.transfer(response.isEmpty
                ? "The UI agent closed the connection without answering \(method) \(path) (it may have crashed or timed out)."
                : "The UI agent sent a malformed reply to \(method) \(path).")
        }
        let statusLine = String(decoding: response[..<split.lowerBound], as: UTF8.self).prefix { $0 != "\r" }
        let status = statusLine.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        return (status, Data(response[split.upperBound...]))
    }
}

/// A connected stream socket.
struct Socket {
    let fd: Int32

    static func tcp(port: UInt16) throws -> Socket {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentConnectionError.refused("socket(): \(String(cString: strerror(errno)))") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            throw AgentConnectionError.refused("Nothing listens on 127.0.0.1:\(port) (\(reason)).")
        }
        return Socket(fd: fd)
    }

    static func unix(_ path: String) throws -> Socket {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentConnectionError.refused("socket(): \(String(cString: strerror(errno)))") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(raw.count))) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            throw AgentConnectionError.refused("Cannot connect to \(path) (\(reason)).")
        }
        return Socket(fd: fd)
    }

    /// Applies to every read and write from now on.
    func setTimeout(_ timeout: Duration) {
        let seconds = max(timeout.components.seconds, 1)
        var value = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { throw AgentConnectionError.transfer(String(cString: strerror(errno))) }
                offset += written
            }
        }
    }

    func read(exactly count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            while offset < count {
                let read = Darwin.read(fd, buffer.baseAddress! + offset, count - offset)
                guard read > 0 else { throw AgentConnectionError.transfer("the connection closed early") }
                offset += read
            }
        }
        return data
    }

    /// Everything until the peer closes, or until a read times out.
    func readToEnd() -> Data {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let read = Darwin.read(fd, &chunk, chunk.count)
            if read <= 0 { break }
            data.append(chunk, count: read)
        }
        return data
    }

    func close() {
        Darwin.close(fd)
    }
}

/// usbmuxd's plist protocol (what `iproxy` speaks): after `Connect`, the socket is a TCP stream to a port
/// on the device. Works over USB and, for paired devices, over Wi-Fi.
enum USBMux {
    static let socketPath = "/var/run/usbmuxd"

    /// usbmuxd reports serial numbers without the dash; USB is preferred over the network.
    static func deviceID(for udid: String) throws -> Int {
        let socket = try Socket.unix(socketPath)
        defer { socket.close() }
        socket.setTimeout(.seconds(5))
        try send(socket, ["MessageType": "ListDevices"])
        let reply = try receive(socket)
        let wanted = udid.replacingOccurrences(of: "-", with: "").uppercased()
        let matches = (reply["DeviceList"] as? [[String: Any]] ?? []).filter { device in
            let properties = device["Properties"] as? [String: Any] ?? [:]
            return (properties["SerialNumber"] as? String ?? "").replacingOccurrences(of: "-", with: "").uppercased() == wanted
        }
        let usb = matches.first { ($0["Properties"] as? [String: Any])?["ConnectionType"] as? String == "USB" }
        guard let id = (usb ?? matches.first)?["DeviceID"] as? Int else {
            throw AgentConnectionError.refused("usbmuxd does not see \(udid): connect the iPhone by USB, or pair it for Wi-Fi in Xcode.")
        }
        return id
    }

    static func connect(udid: String, port: UInt16) throws -> Socket {
        let id = try deviceID(for: udid)
        let socket = try Socket.unix(socketPath)
        socket.setTimeout(.seconds(5))
        do {
            try send(socket, ["MessageType": "Connect", "DeviceID": id, "PortNumber": Int(port.bigEndian)])
            let reply = try receive(socket)
            guard (reply["Number"] as? Int) == 0 else {
                throw AgentConnectionError.refused("Nothing listens on port \(port) of \(udid) (usbmuxd result \(reply["Number"] ?? "?")).")
            }
        } catch {
            socket.close()
            throw error
        }
        return socket
    }

    /// A 16-byte little-endian header (total length, version 1, type 8 = plist, tag), then an XML plist.
    private static func send(_ socket: Socket, _ message: [String: Any]) throws {
        var payload = message
        payload["ClientVersionString"] = "isim-mcp"
        payload["ProgName"] = "isim-mcp"
        let body = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        var header = Data()
        for value in [UInt32(16 + body.count), 1, 8, 1] {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        try socket.write(header + body)
    }

    private static func receive(_ socket: Socket) throws -> [String: Any] {
        let header = try socket.read(exactly: 16)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard length >= 16 else { throw AgentConnectionError.transfer("malformed usbmuxd reply") }
        let body = try socket.read(exactly: Int(length) - 16)
        guard let plist = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
            throw AgentConnectionError.transfer("malformed usbmuxd reply")
        }
        return plist
    }
}
