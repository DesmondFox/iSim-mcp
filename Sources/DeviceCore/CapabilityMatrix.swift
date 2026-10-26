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
    case tap
    case swipe
    case typeText
    case pressKey
    case pressButton
    case describeUI
    case describePoint
    case findElements
    case waitFor
    case systemAlert
    case touchPath
    case multiTouch
    case shake
    case clone
    case rename
    case memoryWarning
    case recording
    case logStream
    case queryLogs
    case consoleCapture
    case crashReports
    case containerFiles
    case userDefaults
    case writeUserDefaults
    case keychain
    case locale
    case iCloudSync
    case darwinNotification
    case spawn

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
        case .tap: "tap"
        case .swipe: "swipe"
        case .typeText: "type_text"
        case .pressKey: "press_key"
        case .pressButton: "press_button"
        case .describeUI: "describe_ui"
        case .describePoint: "describe_point"
        case .findElements: "find_elements"
        case .waitFor: "wait_for"
        case .systemAlert: "handle_system_alert"
        case .touchPath: "touch_path"
        case .multiTouch: "multi_touch"
        case .shake: "shake"
        case .clone: "clone_device"
        case .rename: "rename_device"
        case .memoryWarning: "send_memory_warning"
        case .recording: "start_recording"
        case .logStream: "start_log_capture"
        case .queryLogs: "query_logs"
        case .consoleCapture: "launch_app(capture_output)"
        case .crashReports: "list_crash_reports"
        case .containerFiles: "list_container_files"
        case .userDefaults: "read_user_defaults"
        case .writeUserDefaults: "write_user_defaults"
        case .keychain: "keychain"
        case .locale: "set_locale"
        case .iCloudSync: "icloud_sync"
        case .darwinNotification: "post_darwin_notification"
        case .spawn: "spawn_process"
        }
    }
}

/// Where an operation is executed.
public enum BackendID: String, Sendable, CaseIterable {
    case simctl
    case devicectl
    /// Private CoreSimulator APIs: HID input through dtuhidd, accessibility through AXPTranslator.
    case simbridge
    /// The XCUITest agent running on the device (ISimAgent).
    case agent
    /// lockdownd services on an iPhone, reached through usbmuxd with this Mac's pair record (os_trace_relay).
    case lockdown
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
        // mode=apns goes to Apple's servers from the Mac and needs no device backend.
        .push: Entry(simulator: .simctl, physical: nil, hint: "An iPhone receives pushes only through APNs: use mode=apns with the app's device token."),
        .tap: uiEntry,
        .swipe: uiEntry,
        .typeText: uiEntry,
        .pressKey: uiEntry,
        .pressButton: uiEntry,
        .describeUI: uiEntry,
        .describePoint: uiEntry,
        .findElements: uiEntry,
        .waitFor: uiEntry,
        .systemAlert: uiEntry,
        .touchPath: uiEntry,
        .multiTouch: uiEntry,
        .shake: Entry(simulator: .simctl, physical: nil, hint: "iOS offers no way to simulate a shake on a physical device."),
        .clone: Entry(simulator: .simctl, physical: nil, hint: "Only simulators can be cloned."),
        .rename: Entry(simulator: .simctl, physical: .devicectl),
        // devicectl reports success on a simulator, but the app gets nothing; CoreSimulator's own call works.
        .memoryWarning: Entry(simulator: .simbridge, physical: .devicectl),
        .recording: Entry(simulator: .simctl, physical: nil, hint: "iPhones do not offer screen recording to developer tools (no Screen Recording capability); take screenshots instead."),
        // `log collect --device-udid` needs root; os_trace_relay, Console.app's source, does not.
        .logStream: Entry(simulator: .simctl, physical: .lockdown),
        .queryLogs: Entry(simulator: .simctl, physical: .lockdown),
        .consoleCapture: Entry(simulator: .simctl, physical: .devicectl),
        // Simulator apps are Mac processes: their reports are in ~/Library/Logs/DiagnosticReports.
        .crashReports: Entry(simulator: .simctl, physical: .devicectl),
        // A simulator's containers are folders on this Mac; devicectl has no List Files capability for simulators.
        .containerFiles: Entry(simulator: .simctl, physical: .devicectl),
        .userDefaults: Entry(simulator: .simctl, physical: .devicectl),
        .writeUserDefaults: Entry(simulator: .simctl, physical: nil, hint: "An iPhone app's preferences cannot be changed from the Mac. To override a default for one run, launch the app with args [\"-key\", \"value\"]."),
        .keychain: Entry(simulator: .simctl, physical: nil, hint: "Certificates go onto an iPhone as a configuration profile, installed by its owner in Settings."),
        .locale: Entry(simulator: .simctl, physical: nil, hint: "Change the language in the iPhone's Settings, or try one in the app with launch_app args [\"-AppleLanguages\", \"(de)\", \"-AppleLocale\", \"de_DE\"]."),
        .iCloudSync: Entry(simulator: .simctl, physical: nil, hint: "An iPhone syncs iCloud on its own."),
        // devicectl has no Post Darwin Notification capability for simulators; notifyutil inside the simulator posts them.
        .darwinNotification: Entry(simulator: .simctl, physical: .devicectl),
        .spawn: Entry(simulator: .simctl, physical: nil, hint: "Arbitrary executables cannot be started on an iPhone."),
    ])

    /// Input and UI inspection: SimBridge on simulators, the on-device XCUITest agent on iPhones.
    private static let uiEntry = Entry(simulator: .simbridge, physical: .agent)

    /// What the agent serves; on a simulator it takes these over from SimBridge once started there (ui_agent).
    public static let agentCapabilities: Set<Capability> = [
        .tap, .swipe, .typeText, .pressKey, .pressButton, .describeUI, .describePoint, .findElements, .waitFor, .systemAlert,
        .touchPath, .multiTouch,
    ]
}
