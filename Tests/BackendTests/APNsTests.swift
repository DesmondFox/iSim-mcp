@testable import APNsBackend
import CryptoKit
import DeviceCore
import Foundation
import Testing

/// Records requests and answers with a canned response.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    let status: Int
    let body: Data

    init(status: Int = 200, body: Data = Data()) {
        self.status = status
        self.body = body
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/2", headerFields: ["apns-id": "ABC-123"])!
        return (body, response)
    }
}

struct APNsTests {
    let key = P256.Signing.PrivateKey()

    private func client(_ transport: FakeTransport) throws -> APNsClient {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("isim-key-\(UUID().uuidString).p8")
        try key.pemRepresentation.write(to: file, atomically: true, encoding: .utf8)
        return APNsClient(credentials: APNsCredentials(keyPath: file.path, keyID: "KEY123", teamID: "TEAM456"), transport: transport)
    }

    private func decode(_ part: Substring) throws -> [String: Any] {
        var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        let data = try #require(Data(base64Encoded: base64))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func tokenIsAnES256JWTSignedWithTheKey() throws {
        let token = try APNsClient.jwt(keyID: "KEY123", teamID: "TEAM456", key: key, issuedAt: Date(timeIntervalSince1970: 1_000))
        let parts = token.split(separator: ".")
        #expect(parts.count == 3)
        #expect(try decode(parts[0]) as? [String: String] == ["alg": "ES256", "kid": "KEY123"])
        let claims = try decode(parts[1])
        #expect(claims["iss"] as? String == "TEAM456")
        #expect(claims["iat"] as? Int == 1_000)
        var signature = parts[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while signature.count % 4 != 0 { signature += "=" }
        let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: try #require(Data(base64Encoded: signature)))
        #expect(key.publicKey.isValidSignature(ecdsa, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test func sendsToTheDeviceTokenWithTheRightHeaders() async throws {
        let transport = FakeTransport()
        let apns = try client(transport)
        let id = try await apns.send(APNsNotification(
            deviceToken: "<AB CD 12>", bundleId: "dev.x", pushType: .voip, collapseID: "c1", payload: Data(#"{"k":1}"#.utf8)), environment: .sandbox)
        #expect(id == "ABC-123")
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.sandbox.push.apple.com/3/device/abcd12")
        #expect(request.value(forHTTPHeaderField: "apns-topic") == "dev.x.voip")
        #expect(request.value(forHTTPHeaderField: "apns-push-type") == "voip")
        #expect(request.value(forHTTPHeaderField: "apns-priority") == "10")
        #expect(request.value(forHTTPHeaderField: "apns-collapse-id") == "c1")
        #expect(request.value(forHTTPHeaderField: "authorization")?.hasPrefix("bearer ey") == true)
    }

    @Test func backgroundPushesGoWithPriorityFive() async throws {
        let transport = FakeTransport()
        _ = try await client(transport).send(APNsNotification(
            deviceToken: "ab", bundleId: "dev.x", pushType: .background, payload: Data(#"{"aps":{"content-available":1}}"#.utf8)), environment: .production)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "apns-priority") == "5")
        #expect(transport.requests.first?.url?.host == "api.push.apple.com")
        #expect(APNsPushType.liveactivity.topic(for: "dev.x") == "dev.x.push-type.liveactivity")
    }

    @Test func rejectionsExplainTheReason() async throws {
        let transport = FakeTransport(status: 400, body: Data(#"{"reason":"BadDeviceToken"}"#.utf8))
        await #expect {
            try await client(transport).send(APNsNotification(deviceToken: "ab", bundleId: "dev.x", pushType: .alert, payload: Data("{}".utf8)), environment: .sandbox)
        } throws: { error in
            "\(error)".contains("BadDeviceToken") && "\(error)".contains("other APNs environment")
        }
    }

    @Test func rejectsBadTokensBeforeSending() async throws {
        let transport = FakeTransport()
        await #expect(throws: ISimError.self) {
            try await client(transport).send(APNsNotification(deviceToken: "not-hex!", bundleId: "dev.x", pushType: .alert, payload: Data("{}".utf8)), environment: .sandbox)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func credentialsNeedAllThreeParts() {
        #expect(APNsCredentials.from(keyPath: "/k.p8", keyID: "K", teamID: nil) == nil)
        #expect(APNsCredentials.from(keyPath: "/k.p8", keyID: "K", teamID: "T")?.teamID == "T")
    }
}
