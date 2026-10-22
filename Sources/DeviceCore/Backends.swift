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

public protocol ScreenCapturing: Sendable {
    /// Writes a full-resolution PNG of the main display to `path`.
    func screenshot(udid: String, to path: String) async throws
}

public protocol DisplayInfoProviding: Sendable {
    func displayInfo(udid: String) async throws -> DisplayInfo
}
