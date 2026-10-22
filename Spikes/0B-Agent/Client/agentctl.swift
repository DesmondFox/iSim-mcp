// Host-side client for the ISimAgent spike: HTTP to the agent, tunnelled through usbmuxd for a
// physical device (the same protocol as `iproxy`), or plain TCP to localhost for a simulator.
//
// Usage: agentctl <udid|local> <METHOD> <path> [json-body]
//   agentctl 00008110-000244D21181401E GET /status
//   agentctl local POST /launch '{"bundle_id":"com.apple.Preferences"}'

import Foundation

enum ClientError: Error, CustomStringConvertible {
  case posix(String)
  case usbmux(String)
  var description: String {
    switch self {
    case .posix(let s), .usbmux(let s): return s
    }
  }
}

// MARK: - Socket helpers

func connectUnix(_ path: String) throws -> Int32 {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { throw ClientError.posix("socket: \(errno)") }
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
  }
  let ok = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
  }
  guard ok == 0 else { throw ClientError.posix("connect \(path): \(String(cString: strerror(errno)))") }
  return fd
}

func connectLocalhost(_ port: UInt16) throws -> Int32 {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  var addr = sockaddr_in()
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_port = port.bigEndian
  addr.sin_addr.s_addr = inet_addr("127.0.0.1")
  let ok = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
  }
  guard ok == 0 else { throw ClientError.posix("connect 127.0.0.1:\(port): \(String(cString: strerror(errno)))") }
  return fd
}

func writeAll(_ fd: Int32, _ data: Data) throws {
  try data.withUnsafeBytes { buf in
    var offset = 0
    while offset < buf.count {
      let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
      guard n > 0 else { throw ClientError.posix("write: \(errno)") }
      offset += n
    }
  }
}

func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
  var out = Data(count: count)
  var offset = 0
  try out.withUnsafeMutableBytes { buf in
    while offset < count {
      let n = read(fd, buf.baseAddress! + offset, count - offset)
      guard n > 0 else { throw ClientError.posix("read: unexpected EOF") }
      offset += n
    }
  }
  return out
}

func readToEnd(_ fd: Int32) -> Data {
  var out = Data()
  var chunk = [UInt8](repeating: 0, count: 65536)
  while true {
    let n = read(fd, &chunk, chunk.count)
    if n <= 0 { break }
    out.append(chunk, count: n)
  }
  return out
}

// MARK: - usbmuxd

/// usbmuxd plist protocol: a 16-byte little-endian header (length incl. header, version 1,
/// message type 8 = plist, tag) followed by an XML plist.
struct Usbmux {
  static let socketPath = "/var/run/usbmuxd"
  private static var tag: UInt32 = 0

  static func send(_ fd: Int32, _ message: [String: Any]) throws {
    var payload = message
    payload["ClientVersionString"] = "isim-mcp-spike"
    payload["ProgName"] = "agentctl"
    let body = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
    tag += 1
    var header = Data()
    for value in [UInt32(16 + body.count), 1, 8, tag] {
      withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
    }
    try writeAll(fd, header + body)
  }

  static func receive(_ fd: Int32) throws -> [String: Any] {
    let header = try readExactly(fd, 16)
    let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    let body = try readExactly(fd, Int(length) - 16)
    guard let plist = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
      throw ClientError.usbmux("malformed usbmuxd reply")
    }
    return plist
  }

  /// usbmuxd reports the UDID without the dash for newer devices.
  static func deviceID(for udid: String) throws -> Int {
    let fd = try connectUnix(socketPath)
    defer { close(fd) }
    try send(fd, ["MessageType": "ListDevices"])
    let reply = try receive(fd)
    let wanted = udid.replacingOccurrences(of: "-", with: "").uppercased()
    let devices = reply["DeviceList"] as? [[String: Any]] ?? []
    var seen: [String] = []
    for device in devices {
      let props = device["Properties"] as? [String: Any] ?? [:]
      let serial = (props["SerialNumber"] as? String ?? "").replacingOccurrences(of: "-", with: "").uppercased()
      seen.append("\(serial) (\(props["ConnectionType"] ?? "?"))")
      // Prefer USB when the device is visible over both USB and the network.
      if serial == wanted, (props["ConnectionType"] as? String) == "USB" { return device["DeviceID"] as! Int }
    }
    for device in devices {
      let props = device["Properties"] as? [String: Any] ?? [:]
      let serial = (props["SerialNumber"] as? String ?? "").replacingOccurrences(of: "-", with: "").uppercased()
      if serial == wanted { return device["DeviceID"] as! Int }
    }
    throw ClientError.usbmux("device \(udid) not attached to usbmuxd; seen: \(seen.joined(separator: ", "))")
  }

  /// Returns a socket that is now a raw TCP stream to `port` on the device.
  static func connect(udid: String, port: UInt16) throws -> Int32 {
    let id = try deviceID(for: udid)
    let fd = try connectUnix(socketPath)
    try send(fd, ["MessageType": "Connect", "DeviceID": id, "PortNumber": Int(port.bigEndian)])
    let reply = try receive(fd)
    guard (reply["Number"] as? Int) == 0 else {
      close(fd)
      throw ClientError.usbmux("Connect to device port \(port) failed: \(reply["Number"] ?? "?") (1 = refused, is the agent running?)")
    }
    return fd
  }
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 4 else {
  FileHandle.standardError.write(Data("usage: agentctl <udid|local> <METHOD> <path> [json]\n".utf8))
  exit(2)
}
let port = UInt16(ProcessInfo.processInfo.environment["ISIM_AGENT_PORT"] ?? "") ?? 8100
let body = args.count > 4 ? Data(args[4].utf8) : Data()
do {
  let started = Date()
  let fd = args[1] == "local" ? try connectLocalhost(port) : try Usbmux.connect(udid: args[1], port: port)
  defer { close(fd) }
  var request = "\(args[2]) \(args[3]) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
  if !body.isEmpty { request += "Content-Type: application/json\r\n" }
  request += "\r\n"
  try writeAll(fd, Data(request.utf8) + body)
  let response = readToEnd(fd)
  guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { throw ClientError.posix("no HTTP response") }
  let status = String(decoding: response[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
  let payload = response[split.upperBound...]
  FileHandle.standardError.write(Data("\(status) — \(Int(-started.timeIntervalSinceNow * 1000)) ms\n".utf8))
  // Pretty-print compact trees as text, everything else as JSON.
  if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], let tree = json["tree"] as? String {
    print(tree)
  } else {
    print(String(decoding: payload, as: UTF8.self))
  }
} catch {
  FileHandle.standardError.write(Data("error: \(error)\n".utf8))
  exit(1)
}
