import CoreGraphics
import Foundation
import ProcessKit

// Capabilities a backend can provide. `ToolRouter` looks a backend up via `CapabilityMatrix`
// and casts it to the protocol the tool needs.

public protocol DeviceListing: Sendable {
    func listDevices() async throws -> [Device]
}

public protocol SimulatorLifecycle: Sendable {
    /// Boots the simulator; with `wait`, returns once it has finished booting.
    func boot(udid: String, wait: Bool) async throws
    func shutdown(udid: String) async throws
    func shutdownAll() async throws
    /// Resets contents and settings; the simulator must be shut down.
    func erase(udid: String) async throws
    func delete(udid: String) async throws
}

public protocol DeviceRebooting: Sendable {
    /// With `wait`, returns once the device is usable again (where the backend can tell).
    func reboot(udid: String, wait: Bool) async throws
}

public protocol AppManaging: Sendable {
    /// `includeSystem: false` returns only apps installed by the developer.
    func listApps(udid: String, includeSystem: Bool) async throws -> [InstalledApp]
    func install(udid: String, path: String) async throws
    func uninstall(udid: String, bundleId: String) async throws
    /// Returns the pid of the launched process, if the backend reports it.
    func launch(udid: String, bundleId: String, options: LaunchOptions) async throws -> Int?
    func terminate(udid: String, bundleId: String) async throws -> TerminateOutcome
    func openURL(udid: String, url: String) async throws
}

public protocol AppInspecting: Sendable {
    func appInfo(udid: String, bundleId: String) async throws -> AppDetails
    func listProcesses(udid: String) async throws -> [RunningProcess]
}

public protocol AppContainerLocating: Sendable {
    /// `container`: "app", "data", "groups" or an app group identifier.
    func containerPath(udid: String, bundleId: String, container: String) async throws -> String
}

public protocol ScreenCapturing: Sendable {
    /// Writes a full-resolution PNG of the main display to `path`.
    func screenshot(udid: String, to path: String) async throws
}

public protocol DisplayInfoProviding: Sendable {
    func displayInfo(udid: String) async throws -> DisplayInfo
    func screenInfo(udid: String) async throws -> ScreenInfo
}

public protocol MediaImporting: Sendable {
    func addMedia(udid: String, paths: [String]) async throws
}

public protocol OrientationControlling: Sendable {
    func orientation(udid: String) async throws -> OrientationState
    func setOrientation(udid: String, _ orientation: DeviceOrientation) async throws -> OrientationState
}

public protocol AppearanceConfiguring: Sendable {
    func appearance(udid: String) async throws -> AppearanceSettings
    /// Applies the non-nil fields and returns what the device reports back.
    func setAppearance(udid: String, _ changes: AppearanceSettings) async throws -> AppearanceSettings
}

/// Whether iOS sees a hardware keyboard and so hides the software one. Typed keys reach the app either way.
public protocol HardwareKeyboardConnecting: Sendable {
    func setHardwareKeyboard(udid: String, connected: Bool) async throws
}

public protocol PermissionManaging: Sendable {
    /// `bundleId` is required for grant and revoke.
    func setPermission(udid: String, action: PermissionAction, service: PermissionService, bundleId: String?) async throws
}

public protocol LocationSimulating: Sendable {
    func setLocation(udid: String, _ coordinate: Coordinate) async throws
    func clearLocation(udid: String) async throws
    /// Starts moving along the waypoints and returns; the movement goes on until `clearLocation`.
    func simulateRoute(udid: String, waypoints: [Coordinate], speed: Double) async throws
    func runLocationScenario(udid: String, name: String) async throws
    func locationScenarios(udid: String) async throws -> [String]
}

public protocol StatusBarOverriding: Sendable {
    /// Changes only the given indicators; earlier overrides stay.
    func overrideStatusBar(udid: String, _ override: StatusBarOverride) async throws
    func applyStatusBarPreset(udid: String, _ preset: StatusBarPreset) async throws
    func clearStatusBar(udid: String) async throws
    func statusBar(udid: String) async throws -> StatusBarOverride
}

public protocol BiometricsSimulating: Sendable {
    func biometricEnrollment(udid: String) async throws -> [BiometricEnrollment]
    func setBiometricEnrollment(udid: String, enrolled: Bool) async throws -> [BiometricEnrollment]
    func simulateBiometricMatch(udid: String, success: Bool) async throws
}

public protocol PasteboardAccessing: Sendable {
    func copyToPasteboard(udid: String, text: String) async throws
    /// nil when the pasteboard holds no text.
    func pasteboardText(udid: String) async throws -> String?
}

public protocol PushSending: Sendable {
    /// `payloadPath`: a JSON file with an `aps` dictionary.
    func sendPush(udid: String, bundleId: String, payloadPath: String) async throws
}

/// Touches, keys and hardware buttons. Points are in the interface orientation, like screenshots and the UI tree.
public protocol InputInjecting: Sendable {
    /// `count` taps in a row, each held for `hold`.
    func tap(udid: String, at point: CGPoint, count: Int, hold: Duration) async throws
    func swipe(udid: String, from start: CGPoint, to end: CGPoint, duration: Duration) async throws
    /// Presses the strokes in order; the focused element receives them.
    func pressKeys(udid: String, _ strokes: [KeyStroke]) async throws
    func pressButton(udid: String, _ button: HardwareButton, hold: Duration) async throws
}

/// Typing text in any script into the focused element. The on-device agent can; a simulator's HID keyboard
/// has only US keys, so type_text pastes other text there.
public protocol TextTyping: Sendable {
    func typeText(udid: String, _ text: String) async throws
}

public protocol AccessibilityProviding: Sendable {
    /// The frontmost application with its descendants; `maxDepth` nil reads every level.
    func uiTree(udid: String, maxDepth: Int?) async throws -> UIElement
    /// The deepest element at the point, without children.
    func element(udid: String, at point: CGPoint) async throws -> UIElement?
}

// MARK: Lifecycle extras

public protocol DeviceCloning: Sendable {
    /// Copies a shut-down simulator with its apps and data; returns the UDID of the copy.
    func clone(udid: String, name: String) async throws -> String
}

public protocol DeviceRenaming: Sendable {
    func rename(udid: String, name: String) async throws
}

public protocol MemoryWarningSending: Sendable {
    /// A simulator warns all of its apps at once and ignores `pid`; a physical device warns the process `pid`.
    func sendMemoryWarning(udid: String, pid: Int?) async throws
}

// MARK: Background jobs

/// Records the screen until the recorder gets SIGINT, then finishes the file.
public protocol ScreenRecording: Sendable {
    /// Extension of the files the recorder writes, e.g. "mov".
    var videoFileExtension: String { get }
    func recordingCommand(udid: String, path: String, codec: VideoCodec) -> BackgroundCommand
}

public protocol LogStreaming: Sendable {
    /// Streams the device's log entries that pass the filter, one per line, until stopped.
    func logStreamCommand(udid: String, filter: LogFilter) -> BackgroundCommand
}

public protocol LogQuerying: Sendable {
    /// Log lines of the last `last`, oldest first.
    func queryLogs(udid: String, filter: LogFilter, last: Duration) async throws -> [String]
}

public protocol ConsoleLaunching: Sendable {
    /// Launches the app with its stdout and stderr as the command's output; the command ends with the app,
    /// and stopping the command terminates the app.
    func consoleCommand(udid: String, bundleId: String, options: LaunchOptions) -> BackgroundCommand
}

// MARK: Diagnostics

public protocol CrashReportProviding: Sendable {
    /// Diagnostic reports (.ips) of the device's processes, newest first.
    func crashReports(udid: String) async throws -> [CrashReportEntry]
    /// A report's contents; `name` as `crashReports` lists it.
    func crashReport(udid: String, name: String) async throws -> Data
}

// MARK: App data

public protocol ContainerFileAccessing: Sendable {
    /// Entries under `subpath` (relative to the container root, "" for the root), `depth` levels down
    /// (1: only the entries of `subpath`). Paths in the result are relative to the container.
    func listFiles(udid: String, bundleId: String, container: AppContainer, subpath: String, depth: Int) async throws -> [ContainerFile]
    /// Copies a file of the container to `destination` on the Mac.
    func readFile(udid: String, bundleId: String, container: AppContainer, path: String, to destination: URL) async throws
    /// Copies a file from the Mac into the container, creating directories as needed.
    func writeFile(udid: String, bundleId: String, container: AppContainer, path: String, from source: URL) async throws
}

public protocol UserDefaultsReading: Sendable {
    /// The app's preferences (`suite` nil) or a suite's, as a property list; an empty dictionary when none are set.
    func userDefaults(udid: String, bundleId: String, suite: String?) async throws -> Data
}

public protocol UserDefaultsWriting: Sendable {
    /// Sets `key` to `value` (an XML property list element such as `<integer>3</integer>`), or removes it when nil.
    /// The running app sees the change.
    func writeUserDefault(udid: String, bundleId: String, suite: String?, key: String, value: String?) async throws
}

public protocol KeychainManaging: Sendable {
    /// `trustedRoot` adds the certificate to the trusted root store, so the system trusts what it signs.
    func addCertificate(udid: String, path: String, trustedRoot: Bool) async throws
    func resetKeychain(udid: String) async throws
}

// MARK: System extras

public protocol LocaleConfiguring: Sendable {
    func locale(udid: String) async throws -> DeviceLocale
    /// Writes the non-nil fields; the device needs a reboot for the system UI to follow, apps a relaunch.
    func setLocale(udid: String, languages: [String]?, locale: String?) async throws
}

public protocol ICloudSyncing: Sendable {
    func syncICloud(udid: String) async throws
}

public protocol ShakeSimulating: Sendable {
    func shake(udid: String) async throws
}

public protocol DarwinNotificationPosting: Sendable {
    func postDarwinNotification(udid: String, name: String) async throws
}

public protocol ProcessSpawning: Sendable {
    /// Runs an executable inside the simulator and returns its output; `executable` is a name on the simulator's
    /// PATH or an absolute path.
    func spawn(udid: String, executable: String, arguments: [String], timeout: Duration) async throws -> ProcessResult
}

// MARK: Gestures

/// Touches beyond a single tap or straight swipe. Points are in the interface orientation.
public protocol GestureInjecting: Sendable {
    /// One finger: down at the first sample, moving through the others, up at the last.
    func touchPath(udid: String, _ samples: [TouchSample]) async throws
    /// Two fingers moving together, each sample placing both.
    func twoFingerPath(udid: String, _ samples: [TwoFingerSample]) async throws
}
