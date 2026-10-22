import Foundation

public enum DeviceKind: String, Codable, Sendable, CaseIterable {
    case simulator
    case physical
}

public enum DeviceState: String, Codable, Sendable {
    // Simulators
    case booted
    case booting
    case shutdown
    case shuttingDown = "shutting_down"
    case creating
    // Physical devices
    case connected
    case disconnected

    /// The device can run commands right now.
    public var isReady: Bool { self == .booted || self == .connected }
}

public struct Device: Codable, Sendable, Hashable {
    public var udid: String
    public var name: String
    public var kind: DeviceKind
    public var state: DeviceState
    /// e.g. "27.0".
    public var osVersion: String?
    /// e.g. "iPhone 16 Pro" or "iPhone14,8".
    public var model: String?
    /// false for simulators whose runtime is missing.
    public var isAvailable: Bool
    /// Physical only: "enabled" / "disabled".
    public var developerMode: String?
    /// Physical only: "wired", "localNetwork".
    public var transport: String?

    public init(
        udid: String,
        name: String,
        kind: DeviceKind,
        state: DeviceState,
        osVersion: String? = nil,
        model: String? = nil,
        isAvailable: Bool = true,
        developerMode: String? = nil,
        transport: String? = nil
    ) {
        self.udid = udid
        self.name = name
        self.kind = kind
        self.state = state
        self.osVersion = osVersion
        self.model = model
        self.isAvailable = isAvailable
        self.developerMode = developerMode
        self.transport = transport
    }

    /// `"iPhone 16 Pro" (8D408511-…, simulator, booted)` — used in messages.
    public var summary: String {
        "\"\(name)\" (\(udid), \(kind.rawValue), \(state.rawValue))"
    }
}

public struct InstalledApp: Codable, Sendable, Hashable {
    public var bundleId: String
    public var name: String?
    public var version: String?
    public var build: String?
    /// "user" or "system".
    public var type: String
    public var path: String?

    public init(bundleId: String, name: String?, version: String?, build: String?, type: String, path: String?) {
        self.bundleId = bundleId
        self.name = name
        self.version = version
        self.build = build
        self.type = type
        self.path = path
    }
}

public struct LaunchOptions: Sendable, Equatable {
    public var arguments: [String]
    public var environment: [String: String]
    public var terminateExisting: Bool
    public var startStopped: Bool

    public init(
        arguments: [String] = [],
        environment: [String: String] = [:],
        terminateExisting: Bool = true,
        startStopped: Bool = false
    ) {
        self.arguments = arguments
        self.environment = environment
        self.terminateExisting = terminateExisting
        self.startStopped = startStopped
    }
}

public enum TerminateOutcome: Sendable, Equatable {
    case terminated(pid: Int?)
    case notRunning
}

/// Main display of a device. Coordinates of all UI tools are in points.
public struct DisplayInfo: Codable, Sendable, Equatable {
    public var widthPixels: Int
    public var heightPixels: Int
    public var scale: Double

    public init(widthPixels: Int, heightPixels: Int, scale: Double) {
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.scale = scale
    }
}
