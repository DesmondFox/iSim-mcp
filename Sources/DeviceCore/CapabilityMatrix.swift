import Foundation

/// An operation a tool needs from a device backend.
public enum Capability: String, Sendable, CaseIterable {
    case boot
    case shutdown
    case reboot
    case erase
    case delete
    case listApps
    case installApp
    case uninstallApp
    case launchApp
    case terminateApp
    case openURL
    case appInfo
    case listProcesses
    case appContainer
    case screenshot
    case displayInfo
    case addMedia
    case orientation
    case appearance
    case permissions
    case location
    case statusBar
    case biometrics
    case pasteboard
    case push

    /// Tool name used in error messages.
    public var toolName: String {
        switch self {
        case .boot: "boot_device"
        case .shutdown: "shutdown_device"
        case .reboot: "reboot_device"
        case .erase: "erase_device"
        case .delete: "delete_device"
        case .listApps: "list_apps"
        case .installApp: "install_app"
        case .uninstallApp: "uninstall_app"
        case .launchApp: "launch_app"
        case .terminateApp: "terminate_app"
        case .openURL: "open_url"
        case .appInfo: "get_app_info"
        case .listProcesses: "list_processes"
        case .appContainer: "get_app_container"
        case .screenshot: "screenshot"
        case .displayInfo: "get_screen_info"
        case .addMedia: "add_media"
        case .orientation: "set_orientation"
        case .appearance: "configure_ui"
        case .permissions: "set_permission"
        case .location: "set_location"
        case .statusBar: "override_status_bar"
        case .biometrics: "biometrics"
        case .pasteboard: "set_pasteboard"
        case .push: "send_push"
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
        // devicectl reboots a simulator too, but returns before it is usable; simctl can wait for SpringBoard.
        .reboot: Entry(simulator: .simctl, physical: .devicectl),
        .erase: Entry(simulator: .simctl, physical: nil, hint: "Erasing a physical device is intentionally not supported: it is likely someone's personal phone."),
        .delete: Entry(simulator: .simctl, physical: nil, hint: "To forget a physical device, unpair it in Xcode."),
        .listApps: Entry(simulator: .simctl, physical: .devicectl),
        .installApp: Entry(simulator: .simctl, physical: .devicectl),
        .uninstallApp: Entry(simulator: .simctl, physical: .devicectl),
        .launchApp: Entry(simulator: .simctl, physical: .devicectl),
        .terminateApp: Entry(simulator: .simctl, physical: .devicectl),
        .openURL: Entry(simulator: .simctl, physical: .devicectl),
        .appInfo: Entry(simulator: .simctl, physical: .devicectl),
        // devicectl lists the host's processes for a simulator, without executables; launchctl inside it knows the apps.
        .listProcesses: Entry(simulator: .simctl, physical: .devicectl),
        .appContainer: Entry(simulator: .simctl, physical: nil, hint: "An iPhone's app files are not on this Mac; get_app_info shows the container path on the device."),
        .screenshot: Entry(simulator: .simctl, physical: .devicectl),
        .displayInfo: Entry(simulator: .devicectl, physical: .devicectl),
        .addMedia: Entry(simulator: .simctl, physical: nil, hint: "Photos and contacts can only be added to a simulator's library."),
        .orientation: Entry(simulator: .devicectl, physical: .devicectl),
        .appearance: Entry(simulator: .devicectl, physical: .devicectl),
        .permissions: Entry(simulator: .simctl, physical: nil, hint: "Permissions on an iPhone can only be granted by accepting the system prompt."),
        .location: Entry(simulator: .devicectl, physical: .devicectl),
        .statusBar: Entry(simulator: .devicectl, physical: nil, hint: "iOS does not allow status bar overrides on physical devices."),
        .biometrics: Entry(simulator: .devicectl, physical: nil, hint: "Face ID and Touch ID can only be simulated on simulators."),
        .pasteboard: Entry(simulator: .devicectl, physical: .devicectl),
        .push: Entry(simulator: .simctl, physical: nil, hint: "An iPhone receives pushes only through APNs, which iSim-mcp does not support yet."),
    ])
}
