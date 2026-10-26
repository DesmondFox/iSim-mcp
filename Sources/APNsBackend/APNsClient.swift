import CryptoKit
import DeviceCore
import Foundation

/// The provider key that signs requests to APNs. It is given to the server at startup and never appears in
/// tool parameters or results, so the AI agent does not see it.
public struct APNsCredentials: Sendable, Equatable {
    /// The .p8 file from the Apple Developer account (Keys).
    public var keyPath: String
    public var keyID: String
    public var teamID: String

    public init(keyPath: String, keyID: String, teamID: String) {
        self.keyPath = keyPath
        self.keyID = keyID
        self.teamID = teamID
    }

    /// nil unless all three are given.
    public static func from(keyPath: String?, keyID: String?, teamID: String?) -> APNsCredentials? {
        guard let keyPath, !keyPath.isEmpty, let keyID, !keyID.isEmpty, let teamID, !teamID.isEmpty else { return nil }
        return APNsCredentials(keyPath: (keyPath as NSString).expandingTildeInPath, keyID: keyID, teamID: teamID)
    }
}

public enum APNsEnvironment: String, Sendable, CaseIterable {
    /// Development builds (aps-environment development), simulators included.
    case sandbox
    /// TestFlight and App Store builds.
    case production

    var host: String {
        switch self {
        case .sandbox: "api.sandbox.push.apple.com"
        case .production: "api.push.apple.com"
        }
    }
}

public enum APNsPushType: String, Sendable, CaseIterable {
    case alert
    case background
    case voip
    case liveactivity

    /// The apns-topic for an app: VoIP and Live Activity pushes go to suffixed topics.
    func topic(for bundleId: String) -> String {
        switch self {
        case .voip: bundleId + ".voip"
        case .liveactivity: bundleId + ".push-type.liveactivity"
        case .alert, .background: bundleId
        }
    }

    /// Background pushes must be sent with priority 5.
    var defaultPriority: Int { self == .background ? 5 : 10 }

    public var maxPayloadBytes: Int { self == .voip ? 5120 : 4096 }
}

public struct APNsNotification: Sendable, Equatable {
    /// Hex, as the app gets it in didRegisterForRemoteNotificationsWithDeviceToken.
    public var deviceToken: String
    public var bundleId: String
    public var pushType: APNsPushType
    public var priority: Int?
    public var collapseID: String?
    public var payload: Data

    public init(deviceToken: String, bundleId: String, pushType: APNsPushType, priority: Int? = nil, collapseID: String? = nil, payload: Data) {
        self.deviceToken = deviceToken
        self.bundleId = bundleId
        self.pushType = pushType
        self.priority = priority
        self.collapseID = collapseID
        self.payload = payload
    }
}

/// HTTP/2 requests; URLSession negotiates HTTP/2 with APNs by itself. Replaced in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Sends pushes through Apple's servers with token-based authentication (a JWT signed with ES256).
public actor APNsClient {
    private let credentials: APNsCredentials
    private let transport: any HTTPTransport
    private var cachedToken: (value: String, issued: Date)?

    /// APNs rejects tokens older than an hour and too frequent new ones; one is reused for 50 minutes.
    static let tokenLifetime: TimeInterval = 50 * 60

    public init(credentials: APNsCredentials, transport: any HTTPTransport = URLSession.shared) {
        self.credentials = credentials
        self.transport = transport
    }

    public nonisolated var teamID: String { credentials.teamID }
    public nonisolated var keyID: String { credentials.keyID }

    /// Returns the apns-id APNs assigned to the notification.
    public func send(_ notification: APNsNotification, environment: APNsEnvironment) async throws -> String {
        let request = try request(for: notification, environment: environment, token: try token())
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw Self.failure(status: response.statusCode, body: data, notification: notification, environment: environment)
        }
        return response.value(forHTTPHeaderField: "apns-id") ?? "unknown"
    }

    func request(for notification: APNsNotification, environment: APNsEnvironment, token: String) throws(ISimError) -> URLRequest {
        let deviceToken = notification.deviceToken.lowercased().filter { !$0.isWhitespace && $0 != "<" && $0 != ">" }
        guard !deviceToken.isEmpty, deviceToken.allSatisfy(\.isHexDigit) else {
            throw .invalidArgument("`device_token` must be the hex device token the app received from APNs.")
        }
        guard notification.payload.count <= notification.pushType.maxPayloadBytes else {
            throw .invalidArgument("The payload is \(notification.payload.count) bytes; \(notification.pushType.rawValue) pushes are limited to \(notification.pushType.maxPayloadBytes).")
        }
        var request = URLRequest(url: URL(string: "https://\(environment.host)/3/device/\(deviceToken)")!)
        request.httpMethod = "POST"
        request.httpBody = notification.payload
        request.timeoutInterval = 30
        request.setValue("bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue(notification.pushType.topic(for: notification.bundleId), forHTTPHeaderField: "apns-topic")
        request.setValue(notification.pushType.rawValue, forHTTPHeaderField: "apns-push-type")
        request.setValue(String(notification.priority ?? notification.pushType.defaultPriority), forHTTPHeaderField: "apns-priority")
        if let collapseID = notification.collapseID { request.setValue(collapseID, forHTTPHeaderField: "apns-collapse-id") }
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    private func token() throws -> String {
        if let cachedToken, Date().timeIntervalSince(cachedToken.issued) < Self.tokenLifetime { return cachedToken.value }
        let key = try Self.loadKey(credentials.keyPath)
        let issued = Date()
        let token = try Self.jwt(keyID: credentials.keyID, teamID: credentials.teamID, key: key, issuedAt: issued)
        cachedToken = (token, issued)
        return token
    }

    static func loadKey(_ path: String) throws(ISimError) -> P256.Signing.PrivateKey {
        guard let pem = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw .xcodeUnavailable("Cannot read the APNs key at \(path). Restart the server with --apns-key-path pointing to the .p8 file.")
        }
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else {
            throw .xcodeUnavailable("\(path) is not an APNs auth key (.p8, \"BEGIN PRIVATE KEY\").")
        }
        return key
    }

    /// `header.claims.signature`, each base64url: ES256 over the first two with the provider key.
    static func jwt(keyID: String, teamID: String, key: P256.Signing.PrivateKey, issuedAt: Date) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID], options: [.sortedKeys])
        let claims = try JSONSerialization.data(withJSONObject: ["iss": teamID, "iat": Int(issuedAt.timeIntervalSince1970)], options: [.sortedKeys])
        let input = base64URL(header) + "." + base64URL(claims)
        let signature = try key.signature(for: Data(input.utf8))
        return input + "." + base64URL(signature.rawRepresentation)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// APNs explains a rejection with a `reason`; the common ones get a hint.
    static func failure(status: Int, body: Data, notification: APNsNotification, environment: APNsEnvironment) -> ISimError {
        let reason = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["reason"] as? String ?? "HTTP \(status)"
        let hint: String? = switch reason {
        case "BadDeviceToken":
            "The token is malformed or belongs to the other APNs environment: development builds and simulators use sandbox, TestFlight and App Store builds production."
        case "DeviceTokenNotForTopic":
            "The token was issued to another app than \(notification.bundleId)."
        case "Unregistered", "ExpiredToken":
            "The app is no longer registered for pushes with this token; launch it to get a new one."
        case "TopicDisallowed", "BadTopic":
            "The key's team may not send to \(notification.pushType.topic(for: notification.bundleId)); check the bundle id and that the key belongs to the app's team."
        case "InvalidProviderToken", "MissingProviderToken", "ExpiredProviderToken":
            "The key, key ID or team ID passed to the server do not match an active APNs key."
        case "PayloadTooLarge":
            "Shorten the payload."
        case "TooManyRequests", "TooManyProviderTokenUpdates":
            "APNs is throttling; wait a little before sending again."
        default:
            nil
        }
        return .commandFailed(command: "APNs \(environment.rawValue)", message: reason + (hint.map { ". \($0)" } ?? ""))
    }
}
