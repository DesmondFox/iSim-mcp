import CoreGraphics
import Foundation

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

public protocol AccessibilityProviding: Sendable {
    /// The frontmost application with its descendants; `maxDepth` nil reads every level.
    func uiTree(udid: String, maxDepth: Int?) async throws -> UIElement
    /// The deepest element at the point, without children.
    func element(udid: String, at point: CGPoint) async throws -> UIElement?
}
