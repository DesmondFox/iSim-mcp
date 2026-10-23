import Foundation
import Network

struct HTTPRequest {
  let method: String
  let path: String
  let query: [String: String]
  let body: Data

  var json: [String: Any] {
    (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
  }

  /// Returns nil until the buffer holds the full head and `Content-Length` bytes of body.
  static func parse(_ buffer: Data) -> HTTPRequest? {
    guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count >= 2 else { return nil }
    var contentLength = 0
    for line in lines {
      let parts = line.split(separator: ":", maxSplits: 1)
      if parts.count == 2, parts[0].lowercased() == "content-length" {
        contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
      }
    }
    let bodyStart = headEnd.upperBound
    guard buffer.count - bodyStart >= contentLength else { return nil }
    let components = URLComponents(string: String(requestLine[1]))
    var query: [String: String] = [:]
    for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
    return HTTPRequest(
      method: String(requestLine[0]),
      path: components?.path ?? String(requestLine[1]),
      query: query,
      body: buffer.subdata(in: bodyStart..<(bodyStart + contentLength)))
  }
}

struct HTTPResponse {
  var status: Int = 200
  var body: Data

  static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    return HTTPResponse(status: status, body: data)
  }

  func serialized() -> Data {
    let reason = status == 200 ? "OK" : "Error"
    var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
    out.append(body)
    return out
  }
}

/// One request per connection, handled serially: XCUITest is main-thread only anyway.
final class HTTPServer {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "isim.agent.http")
  private let handler: (HTTPRequest) -> HTTPResponse

  init(port: UInt16, handler: @escaping (HTTPRequest) -> HTTPResponse) throws {
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
    self.handler = handler
  }

  func start() {
    listener.stateUpdateHandler = { state in NSLog("ISimAgent listener: \(state)") }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { return }
      connection.start(queue: self.queue)
      self.receive(on: connection, buffer: Data())
    }
    listener.start(queue: queue)
  }

  func stop() {
    listener.cancel()
  }

  private func receive(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      var buffer = buffer
      if let data { buffer.append(data) }
      if let request = HTTPRequest.parse(buffer) {
        let response = self.handler(request)
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
      } else if isComplete || error != nil {
        connection.cancel()
      } else {
        self.receive(on: connection, buffer: buffer)
      }
    }
  }
}
