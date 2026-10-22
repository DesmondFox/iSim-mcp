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
    /// CoreDevice identifier, which DeviceHub URLs use. Equals the UDID for simulators.
    public var coreDeviceId: String?

    public init(
        udid: String,
        name: String,
        kind: DeviceKind,
        state: DeviceState,
        osVersion: String? = nil,
        model: String? = nil,
        isAvailable: Bool = true,
        developerMode: String? = nil,
        transport: String? = nil,
        coreDeviceId: String? = nil
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
        self.coreDeviceId = coreDeviceId
    }

    /// Opens Xcode's DeviceHub on this device.
    public var deviceHubURL: String {
        "devices://device/open?id=\(coreDeviceId ?? udid)"
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

/// What get_app_info shows about one app.
public struct AppDetails: Sendable, Equatable {
    public var app: InstalledApp
    /// The app's data directory: a Mac path on simulators, a path on the device for iPhones.
    public var dataContainer: String?
    public var appGroups: [AppGroupContainer]
    /// Entitlements as JSON; known for simulator builds only.
    public var entitlementsJSON: String?
    /// e.g. "developer", "removable", "app clip".
    public var flags: [String]

    public init(app: InstalledApp, dataContainer: String?, appGroups: [AppGroupContainer], entitlementsJSON: String?, flags: [String]) {
        self.app = app
        self.dataContainer = dataContainer
        self.appGroups = appGroups
        self.entitlementsJSON = entitlementsJSON
        self.flags = flags
    }
}

public struct AppGroupContainer: Sendable, Equatable {
    public var identifier: String
    public var path: String?

    public init(identifier: String, path: String?) {
        self.identifier = identifier
        self.path = path
    }
}

public struct RunningProcess: Sendable, Equatable {
    public var pid: Int
    /// Executable name, or the launchd label of a simulator daemon.
    public var name: String
    /// Set for app processes.
    public var bundleId: String?
    /// Executable path, where the backend reports it (physical devices).
    public var path: String?

    public init(pid: Int, name: String, bundleId: String?, path: String?) {
        self.pid = pid
        self.name = name
        self.bundleId = bundleId
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

/// A display of a device. Coordinates of all UI tools are in points.
public struct DisplayInfo: Codable, Sendable, Equatable {
    public var widthPixels: Int
    public var heightPixels: Int
    public var scale: Double
    /// e.g. "LCD".
    public var name: String?
    /// Pass to `screenshot(display:)` to capture this display.
    public var uniqueId: String?
    public var isPrimary: Bool

    public init(widthPixels: Int, heightPixels: Int, scale: Double, name: String? = nil, uniqueId: String? = nil, isPrimary: Bool = true) {
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.scale = scale
        self.name = name
        self.uniqueId = uniqueId
        self.isPrimary = isPrimary
    }
}

public struct ScreenInfo: Sendable, Equatable {
    public var displays: [DisplayInfo]
    public var orientation: OrientationState?

    public init(displays: [DisplayInfo], orientation: OrientationState?) {
        self.displays = displays
        self.orientation = orientation
    }
}
