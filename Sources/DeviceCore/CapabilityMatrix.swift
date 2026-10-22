import Foundation

/// An operation a tool needs from a device backend.
public enum Capability: String, Sendable, CaseIterable {
    case boot
    case shutdown
    case listApps
    case installApp
    case uninstallApp
    case launchApp
    case terminateApp
    case openURL
    case screenshot
    case displayInfo

    /// Tool name used in error messages.
    public var toolName: String {
        switch self {
        case .boot: "boot_device"
        case .shutdown: "shutdown_device"
        case .listApps: "list_apps"
        case .installApp: "install_app"
        case .uninstallApp: "uninstall_app"
        case .launchApp: "launch_app"
        case .terminateApp: "terminate_app"
        case .openURL: "open_url"
        case .screenshot: "screenshot"
        case .displayInfo: "get_screen_info"
        }
    }
}

/// Where an operation is executed.
public enum BackendID: String, Sendable, CaseIterable {
    case simctl
    case devicectl
}

/// Which backend serves which capability on which kind of device (PLAN.md, section 5).
public struct CapabilityMatrix: Sendable {
    public struct Entry: Sendable {
        public var simulator: BackendID?
        public var physical: BackendID?
        /// Shown when the capability is missing on a device kind.
        public var hint: String?
    }

    private var entries: [Capability: Entry]

    public init(entries: [Capability: Entry]) {
        self.entries = entries
    }

    public func backend(for capability: Capability, on kind: DeviceKind) throws(ISimError) -> BackendID {
        let entry = entries[capability]
        let backend = switch kind {
        case .simulator: entry?.simulator
        case .physical: entry?.physical
        }
        guard let backend else { throw .unsupported(capability, kind: kind, hint: entry?.hint) }
        return backend
    }

    public static let standard = CapabilityMatrix(entries: [
        .boot: Entry(simulator: .simctl, physical: nil, hint: "Physical devices are always on: connect and unlock the iPhone."),
        .shutdown: Entry(simulator: .simctl, physical: nil, hint: "Physical devices cannot be shut down remotely."),
        .listApps: Entry(simulator: .simctl, physical: .devicectl),
        .installApp: Entry(simulator: .simctl, physical: .devicectl),
        .uninstallApp: Entry(simulator: .simctl, physical: .devicectl),
        .launchApp: Entry(simulator: .simctl, physical: .devicectl),
        .terminateApp: Entry(simulator: .simctl, physical: .devicectl),
        .openURL: Entry(simulator: .simctl, physical: .devicectl),
        .screenshot: Entry(simulator: .simctl, physical: .devicectl),
        .displayInfo: Entry(simulator: .devicectl, physical: .devicectl),
    ])
}
