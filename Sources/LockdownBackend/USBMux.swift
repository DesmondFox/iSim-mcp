import Foundation

/// What went wrong talking to an iPhone's lockdown services, with what to do about it.
public struct LockdownError: Error, CustomStringConvertible, Equatable {
    public var description: String

    init(_ description: String) {
        self.description = description
    }
}

/// Bytes both ways: a plain socket, or TLS over it.
protocol ByteStream: AnyObject {
    func write(_ data: Data) throws
    /// Exactly `count` bytes; throws if the peer closes first.
    func read(exactly count: Int) throws -> Data
    /// Some bytes, at most `maxLength`; empty once the peer has closed.
    func read(upTo maxLength: Int) throws -> Data
}

/// A connected blocking stream socket: to usbmuxd, and through it to a port on an iPhone.
final class DeviceSocket: ByteStream {
    let fd: Int32
    private var isClosed = false

    init(unixPath path: String) throws {
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LockdownError("socket(): \(String(cString: strerror(errno)))") }
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
            throw LockdownError("Cannot connect to usbmuxd at \(path) (\(reason)). It comes with macOS; is this a Mac?")
        }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        close()
    }

    /// Applies to every plain read and write from now on; nil waits forever.
    func setTimeout(_ timeout: Duration?) {
        var value = timeval(tv_sec: Int(timeout?.components.seconds ?? 0), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { throw LockdownError("Writing to the iPhone failed: \(String(cString: strerror(errno))).") }
                offset += written
            }
        }
    }

    func read(exactly count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            let chunk = try read(upTo: count - data.count)
            guard !chunk.isEmpty else { throw LockdownError("The iPhone closed the connection.") }
            data += chunk
        }
        return data
    }

    func read(upTo maxLength: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let count = Darwin.read(fd, &buffer, maxLength)
        if count < 0 {
            throw LockdownError(errno == EAGAIN ? "The iPhone did not answer in time." : "Reading from the iPhone failed: \(String(cString: strerror(errno))).")
        }
        return Data(buffer.prefix(count))
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fd)
    }
}

/// usbmuxd's plist protocol: the devices it sees, their pair records, and connections to their ports.
/// It sees iPhones on USB, and on the network only those synced with Finder over Wi-Fi: Xcode's
/// "Connect via network" pairs through CoreDevice (RemotePairing), which usbmuxd does not use.
enum USBMux {
    static let socketPath = "/var/run/usbmuxd"

    struct DeviceEntry: Equatable {
        var id: Int
        /// The UDID as usbmuxd spells it; also the pair record's id.
        var serial: String
        /// "USB" or "Network".
        var connection: String
    }

    /// A 16-byte little-endian header (total length, version 1, type 8 = plist, tag), then an XML plist.
    static func packet(_ message: [String: Any], tag: UInt32 = 1) throws -> Data {
        var payload = message
        payload["ClientVersionString"] = "isim-mcp"
        payload["ProgName"] = "isim-mcp"
        let body = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        var header = Data()
        for value in [UInt32(16 + body.count), 1, 8, tag] {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        return header + body
    }

    static func readPacket(from stream: some ByteStream) throws -> [String: Any] {
        let header = try stream.read(exactly: 16)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard length >= 16, length < 16 << 20 else { throw LockdownError("usbmuxd sent a malformed reply.") }
        let body = try stream.read(exactly: Int(length) - 16)
        guard let plist = try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
            throw LockdownError("usbmuxd sent a malformed reply.")
        }
        return plist
    }

    /// One request on a fresh connection; usbmuxd answers each with one packet.
    private static func request(_ message: [String: Any]) throws -> [String: Any] {
        let socket = try DeviceSocket(unixPath: socketPath)
        defer { socket.close() }
        socket.setTimeout(.seconds(10))
        try socket.write(try packet(message))
        return try readPacket(from: socket)
    }

    static func devices() throws -> [DeviceEntry] {
        let reply = try request(["MessageType": "ListDevices"])
        return (reply["DeviceList"] as? [[String: Any]] ?? []).compactMap { device in
            let properties = device["Properties"] as? [String: Any] ?? [:]
            guard let id = device["DeviceID"] as? Int, let serial = properties["SerialNumber"] as? String else { return nil }
            return DeviceEntry(id: id, serial: serial, connection: properties["ConnectionType"] as? String ?? "?")
        }
    }

    /// The device with this UDID (usbmuxd may drop the dash); USB is preferred over the network.
    static func device(for udid: String, in devices: [DeviceEntry]) throws -> DeviceEntry {
        func normalized(_ text: String) -> String { text.replacingOccurrences(of: "-", with: "").uppercased() }
        let matches = devices.filter { normalized($0.serial) == normalized(udid) }
        guard let device = matches.first(where: { $0.connection == "USB" }) ?? matches.first else {
            throw LockdownError("usbmuxd does not see \(udid): connect the iPhone by USB. Over Wi-Fi, usbmuxd sees only iPhones "
                + "synced with Finder over Wi-Fi, not ones that Xcode reaches over the network.")
        }
        return device
    }

    /// The pairing of this Mac with the device (a binary plist); usbmuxd hands it to the user, no root needed.
    static func pairRecord(for device: DeviceEntry) throws -> Data {
        let reply = try request(["MessageType": "ReadPairRecord", "PairRecordID": device.serial])
        guard let data = reply["PairRecordData"] as? Data else {
            throw LockdownError("This Mac is not paired with \(device.serial): connect the iPhone by USB, unlock it and tap Trust.")
        }
        return data
    }

    /// A socket that is now a TCP stream to `port` on the device.
    static func connect(to device: DeviceEntry, port: UInt16) throws -> DeviceSocket {
        let socket = try DeviceSocket(unixPath: socketPath)
        socket.setTimeout(.seconds(10))
        try socket.write(try packet(["MessageType": "Connect", "DeviceID": device.id, "PortNumber": Int(port.bigEndian)]))
        let reply = try readPacket(from: socket)
        guard (reply["Number"] as? Int) == 0 else {
            socket.close()
            throw LockdownError("Cannot reach port \(port) on \(device.serial) over \(device.connection) (usbmuxd result \(reply["Number"] ?? "?")). "
                + (device.connection == "USB" ? "Unplug the iPhone and plug it in again." : "Connect the iPhone by USB."))
        }
        return socket
    }
}
