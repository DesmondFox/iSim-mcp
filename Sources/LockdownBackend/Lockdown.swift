import Foundation
import Security

/// The pairing of this Mac with an iPhone, as usbmuxd keeps it: what opens a TLS session with lockdownd.
struct PairRecord {
    var hostID: String
    var systemBUID: String
    /// DER.
    var hostCertificate: Data
    /// PKCS#1 DER, as SecKeyCreateWithData takes RSA keys.
    var hostPrivateKey: Data

    init(plist data: Data) throws {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let hostID = plist["HostID"] as? String, let systemBUID = plist["SystemBUID"] as? String,
            let certificate = plist["HostCertificate"] as? Data, let key = plist["HostPrivateKey"] as? Data
        else { throw LockdownError("The pair record is incomplete; unpair the iPhone in Xcode and pair it again.") }
        self.hostID = hostID
        self.systemBUID = systemBUID
        hostCertificate = try DER.fromPEM(certificate)
        let keyDER = try DER.fromPEM(key)
        // `BEGIN RSA PRIVATE KEY` is PKCS#1 already; `BEGIN PRIVATE KEY` wraps it in PKCS#8.
        hostPrivateKey = String(decoding: key.prefix(40), as: UTF8.self).contains("RSA PRIVATE KEY") ? keyDER : try DER.pkcs1(fromPKCS8: keyDER)
    }

    /// The host certificate with its key, kept in memory: nothing goes into a keychain.
    func identity() throws -> SecIdentity {
        guard let certificate = SecCertificateCreateWithData(nil, hostCertificate as CFData) else {
            throw LockdownError("The pair record's host certificate does not parse.")
        }
        var error: Unmanaged<CFError>?
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary
        guard let key = SecKeyCreateWithData(hostPrivateKey as CFData, attributes, &error) else {
            throw LockdownError("The pair record's host key does not load: \(error.map { "\($0.takeRetainedValue())" } ?? "unknown error").")
        }
        // Security.framework's SecIdentityCreate: public API only builds identities from keychain items.
        typealias IdentityCreate = @convention(c) (CFAllocator?, SecCertificate, SecKey) -> Unmanaged<SecIdentity>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecIdentityCreate"),
              let identity = unsafeBitCast(symbol, to: IdentityCreate.self)(nil, certificate, key)?.takeRetainedValue()
        else { throw LockdownError("Security.framework no longer offers SecIdentityCreate; iPhone logs need an update of iSim-mcp.") }
        return identity
    }
}

/// Just enough DER for pair records.
enum DER {
    /// The bytes of a PEM block.
    static func fromPEM(_ pem: Data) throws -> Data {
        let base64 = String(decoding: pem, as: UTF8.self).split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: base64), !data.isEmpty else { throw LockdownError("The pair record holds a malformed PEM block.") }
        return data
    }

    /// PKCS#8 PrivateKeyInfo is SEQUENCE { INTEGER version, SEQUENCE algorithm, OCTET STRING privateKey },
    /// and for RSA privateKey is the PKCS#1 key.
    static func pkcs1(fromPKCS8 der: Data) throws -> Data {
        let der = Data(der)
        var offset = 0
        let info = try element(der, at: &offset, tag: 0x30)
        offset = info.lowerBound
        _ = try element(der, at: &offset, tag: 0x02)
        _ = try element(der, at: &offset, tag: 0x30)
        return der.subdata(in: try element(der, at: &offset, tag: 0x04))
    }

    /// The contents of the element at `offset`, which moves past it.
    static func element(_ der: Data, at offset: inout Int, tag: UInt8) throws -> Range<Int> {
        let malformed = LockdownError("The pair record's host key is not an RSA key in PKCS#8.")
        guard offset + 2 <= der.count, der[offset] == tag else { throw malformed }
        var length = Int(der[offset + 1])
        offset += 2
        if length & 0x80 != 0 {
            let bytes = length & 0x7f
            guard bytes <= 4, offset + bytes <= der.count else { throw malformed }
            length = der[offset..<offset + bytes].reduce(0) { $0 << 8 | Int($1) }
            offset += bytes
        }
        guard offset + length <= der.count else { throw malformed }
        defer { offset += length }
        return offset..<offset + length
    }
}

/// TLS over a connected socket, from wherever the conversation is: lockdownd switches after StartSession,
/// services from their first byte. The Mac authenticates with the pair record's host certificate; the
/// device's self-signed certificate is not checked (the pair record already is the trust).
final class TLSStream: ByteStream {
    private let socket: DeviceSocket
    private let input: InputStream
    private let output: OutputStream

    init(over socket: DeviceSocket, identity: SecIdentity) throws {
        self.socket = socket
        var read: Unmanaged<CFReadStream>?
        var write: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocket(nil, socket.fd, &read, &write)
        guard let read, let write else { throw LockdownError("Cannot start TLS with the iPhone.") }
        input = read.takeRetainedValue() as InputStream
        output = write.takeRetainedValue() as OutputStream
        let settings: [String: Any] = [
            kCFStreamSSLCertificates as String: [identity],
            kCFStreamSSLValidatesCertificateChain as String: false,
            kCFStreamSSLIsServer as String: false,
        ]
        for stream in [input, output] as [Stream] {
            stream.setProperty(settings, forKey: Stream.PropertyKey(kCFStreamPropertySSLSettings as String))
            stream.setProperty(false, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))
            stream.open()
        }
    }

    deinit {
        input.close()
        output.close()
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = output.write(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self) + offset, maxLength: buffer.count - offset)
                guard written > 0 else { throw failure(output.streamError) }
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
        let count = input.read(&buffer, maxLength: maxLength)
        if count < 0 { throw failure(input.streamError) }
        return Data(buffer.prefix(count))
    }

    private func failure(_ error: (any Error)?) -> LockdownError {
        let nsError = error as NSError?
        // errSSL… codes: the handshake itself failed, which means lockdownd did not accept the pair record.
        if let code = nsError?.code, (-9900 ... -9800).contains(code) {
            return LockdownError("TLS with the iPhone failed (\(code)): its pairing with this Mac may be stale. "
                + "Unplug it, plug it in, unlock it and tap Trust if asked.")
        }
        return LockdownError("The connection to the iPhone broke: \(nsError?.localizedDescription ?? "closed").")
    }
}

/// lockdownd, port 62078 on every iPhone: requests and replies are a 4-byte big-endian length and an XML
/// plist. After StartSession it talks TLS, and StartService opens a port for one service. Services use the
/// same framing for their requests.
final class LockdownClient {
    static let port: UInt16 = 62078

    let device: USBMux.DeviceEntry
    private let socket: DeviceSocket
    private var stream: any ByteStream
    private let pairRecord: PairRecord
    private let identity: SecIdentity

    init(udid: String) throws {
        device = try USBMux.device(for: udid, in: try USBMux.devices())
        pairRecord = try PairRecord(plist: try USBMux.pairRecord(for: device))
        identity = try pairRecord.identity()
        socket = try USBMux.connect(to: device, port: Self.port)
        stream = socket
    }

    static func message(_ plist: [String: Any]) throws -> Data {
        let body = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) } + body
    }

    static func readMessage(from stream: some ByteStream) throws -> [String: Any] {
        let length = try stream.read(exactly: 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard length < 16 << 20 else { throw LockdownError("The iPhone sent a malformed reply.") }
        guard let plist = try? PropertyListSerialization.propertyList(from: try stream.read(exactly: Int(length)), format: nil) as? [String: Any] else {
            throw LockdownError("The iPhone sent a malformed reply.")
        }
        return plist
    }

    /// One request and its reply; lockdownd's `Error` becomes a LockdownError with a hint.
    func request(_ name: String, _ fields: [String: Any] = [:]) throws -> [String: Any] {
        try stream.write(try Self.message(fields.merging(["Label": "isim-mcp", "Request": name]) { $1 }))
        let reply = try Self.readMessage(from: stream)
        if let error = reply["Error"] as? String { throw Self.failure(error, request: name) }
        return reply
    }

    func value(_ key: String) throws -> Any? {
        try request("GetValue", ["Key": key])["Value"]
    }

    /// Authenticates with the pair record; from here on lockdownd talks TLS.
    func startSession() throws {
        let reply = try request("StartSession", ["HostID": pairRecord.hostID, "SystemBUID": pairRecord.systemBUID])
        if reply["EnableSessionSSL"] as? Bool == true {
            stream = try TLSStream(over: socket, identity: identity)
        }
    }

    /// A connection to the service, in TLS when the service asks for it. Needs a session.
    func startService(_ name: String) throws -> any ByteStream {
        let reply = try request("StartService", ["Service": name])
        guard let port = reply["Port"] as? Int, let port16 = UInt16(exactly: port) else {
            throw LockdownError("lockdownd did not start \(name).")
        }
        let socket = try USBMux.connect(to: device, port: port16)
        socket.setTimeout(nil)
        return reply["EnableServiceSSL"] as? Bool == true ? try TLSStream(over: socket, identity: identity) : socket
    }

    func close() {
        socket.close()
    }

    static func failure(_ error: String, request: String) -> LockdownError {
        let hint = switch error {
        case "PasswordProtected": "Unlock the iPhone."
        case "InvalidHostID", "InvalidPairRecord", "PairingDialogResponsePending":
            "This Mac's pairing is not accepted: unplug the iPhone, plug it in, unlock it and tap Trust."
        case "InvalidService", "ServiceProhibited": "The iPhone refuses this service; Developer Mode may be off."
        default: "Unplug the iPhone and plug it in again."
        }
        return LockdownError("lockdownd refused \(request): \(error). \(hint)")
    }
}
