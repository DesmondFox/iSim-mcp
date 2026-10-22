import DeviceCore
import Foundation
import ProcessKit

/// Simulator operations through `xcrun simctl`.
public struct SimctlBackend: DeviceListing, SimulatorLifecycle, DeviceRebooting, AppManaging, AppInspecting, AppContainerLocating,
    ScreenCapturing, MediaImporting, PermissionManaging, PushSending
{
    private let runner: any ProcessRunning
    private let defaultTimeout: Duration

    public init(runner: any ProcessRunning, defaultTimeout: Duration = .seconds(60)) {
        self.runner = runner
        self.defaultTimeout = defaultTimeout
    }

    // MARK: Devices

    public func listDevices() async throws -> [Device] {
        let result = try await simctl(["list", "devices", "--json"])
        return try SimctlParser.devices(fromListJSON: result.stdout)
    }

    public func listRuntimes() async throws -> [SimRuntime] {
        let result = try await simctl(["list", "runtimes", "--json"])
        return try SimctlParser.runtimes(fromListJSON: result.stdout)
    }

    public func boot(udid: String, wait: Bool) async throws {
        let result = try await runner.run(xcrun, ["simctl", "boot", udid], timeout: defaultTimeout)
        // Booting an already booted device is not an error for us.
        if !result.succeeded && !result.stderrString.contains("current state: Booted") {
            throw Self.failure(["boot", udid], result)
        }
        if wait {
            // Blocks until SpringBoard and the data migration are done.
            try await simctl(["bootstatus", udid], timeout: .seconds(300))
        }
    }

    public func shutdown(udid: String) async throws {
        let result = try await runner.run(xcrun, ["simctl", "shutdown", udid], timeout: defaultTimeout)
        if !result.succeeded && !result.stderrString.contains("current state: Shutdown") {
            throw Self.failure(["shutdown", udid], result)
        }
    }

    public func shutdownAll() async throws {
        try await simctl(["shutdown", "all"])
    }

    /// `shutdown` + `boot`: devicectl can reboot a simulator too, but does not say when it is usable again.
    public func reboot(udid: String, wait: Bool) async throws {
        try await shutdown(udid: udid)
        try await boot(udid: udid, wait: wait)
    }

    public func erase(udid: String) async throws {
        try await simctl(["erase", udid], timeout: .seconds(120))
    }

    public func delete(udid: String) async throws {
        try await simctl(["delete", udid], timeout: .seconds(120))
    }

    /// Deletes simulators whose runtime is no longer installed.
    public func deleteUnavailable() async throws {
        try await simctl(["delete", "unavailable"], timeout: .seconds(300))
    }

    /// Returns the UDID of the new simulator.
    public func createDevice(name: String, deviceTypeId: String, runtimeId: String) async throws -> String {
        let result = try await simctl(["create", name, deviceTypeId, runtimeId])
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Apps

    public func listApps(udid: String, includeSystem: Bool) async throws -> [InstalledApp] {
        let result = try await simctl(["listapps", udid])
        let apps = try SimctlParser.apps(fromListAppsPlist: result.stdout)
        return includeSystem ? apps : apps.filter { $0.type == "user" }
    }

    public func install(udid: String, path: String) async throws {
        try await simctl(["install", udid, path], timeout: .seconds(300))
    }

    public func uninstall(udid: String, bundleId: String) async throws {
        try await simctl(["uninstall", udid, bundleId])
    }

    public func launch(udid: String, bundleId: String, options: LaunchOptions) async throws -> Int? {
        var arguments = ["launch"]
        if options.terminateExisting { arguments.append("--terminate-running-process") }
        if options.startStopped { arguments.append("--wait-for-debugger") }
        arguments += [udid, bundleId] + options.arguments
        // simctl passes SIMCTL_CHILD_* variables to the launched app without the prefix.
        let environment = Dictionary(uniqueKeysWithValues: options.environment.map { ("SIMCTL_CHILD_\($0.key)", $0.value) })
        let result = try await runner.run(xcrun, ["simctl"] + arguments, environment: environment, timeout: defaultTimeout)
        if result.stderrString.contains("FBSOpenApplicationServiceErrorDomain, code=4") {
            throw ISimError.notFound("\(bundleId) is not installed on the simulator. Use list_apps to see installed apps or install_app to install it.")
        }
        guard result.succeeded else { throw Self.failure(arguments, result) }
        return SimctlParser.pid(fromLaunchOutput: result.stdoutString)
    }

    public func terminate(udid: String, bundleId: String) async throws -> TerminateOutcome {
        let result = try await runner.run(xcrun, ["simctl", "terminate", udid, bundleId], timeout: defaultTimeout)
        if result.succeeded { return .terminated(pid: nil) }
        if result.stderrString.contains("found nothing to terminate") { return .notRunning }
        throw Self.failure(["terminate", udid, bundleId], result)
    }

    public func openURL(udid: String, url: String) async throws {
        try await simctl(["openurl", udid, url])
    }

    public func appInfo(udid: String, bundleId: String) async throws -> AppDetails {
        let result = try await runner.run(xcrun, ["simctl", "appinfo", udid, bundleId], timeout: defaultTimeout)
        if result.stderrString.contains("No application record found") {
            throw Self.notInstalled(bundleId)
        }
        guard result.succeeded else { throw Self.failure(["appinfo"], result) }
        var (details, executable) = try SimctlParser.appInfo(fromPlist: result.stdout)
        // Built-in apps carry long lists of private entitlements that say nothing about the user's app.
        if let executable, details.app.type == "user" {
            details.entitlementsJSON = await entitlementsJSON(executable: executable)
        }
        return details
    }

    /// Simulator builds keep entitlements in a `__TEXT,__entitlements` section instead of the signature.
    private func entitlementsJSON(executable: String) async -> String? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("isim-entitlements-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: output) }
        var plist: Data?
        if let result = try? await runner.run(xcrun, ["segedit", executable, "-extract", "__TEXT", "__entitlements", output.path], timeout: .seconds(20)),
           result.succeeded {
            plist = FileManager.default.contents(atPath: output.path)
        }
        if plist?.isEmpty ?? true,
           let result = try? await runner.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", executable], timeout: .seconds(20)),
           result.succeeded {
            plist = result.stdout
        }
        guard
            let plist, !plist.isEmpty,
            let object = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any], !object.isEmpty,
            JSONSerialization.isValidJSONObject(object),
            let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: json, as: UTF8.self)
    }

    /// Processes known to the simulator's launchd: apps (`UIKitApplication:<bundle id>`) and daemons.
    public func listProcesses(udid: String) async throws -> [RunningProcess] {
        let result = try await simctl(["spawn", udid, "launchctl", "list"])
        return SimctlParser.processes(fromLaunchctlList: result.stdoutString)
    }

    /// Apps load their accessibility runtime at launch only when this preference is on; without it their UI tree is empty.
    public func isApplicationAccessibilityEnabled(udid: String) async throws -> Bool {
        let result = try await runner.run(
            xcrun, ["simctl", "spawn", udid, "defaults", "read", "com.apple.Accessibility", "ApplicationAccessibilityEnabled"],
            timeout: defaultTimeout)
        // A missing key exits with 1: never set, so off.
        return result.succeeded && result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    public func enableApplicationAccessibility(udid: String) async throws {
        try await simctl(["spawn", udid, "defaults", "write", "com.apple.Accessibility", "ApplicationAccessibilityEnabled", "-bool", "true"])
    }

    public func containerPath(udid: String, bundleId: String, container: String) async throws -> String {
        let result = try await runner.run(xcrun, ["simctl", "get_app_container", udid, bundleId, container], timeout: defaultTimeout)
        if result.succeeded {
            let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, path != "(null)" else {
                throw ISimError.notFound(container == "groups"
                    ? "\(bundleId) has no app group containers."
                    : "\(bundleId) has no \(container) container.")
            }
            return path
        }
        if result.exitCode == 2 { throw Self.notInstalled(bundleId) }
        if result.stderrString.contains("Usage: simctl get_app_container") {
            throw ISimError.notFound("\(bundleId) has no app group \"\(container)\". Use container=groups to list its groups.")
        }
        throw Self.failure(["get_app_container"], result)
    }

    // MARK: Screen

    public func screenshot(udid: String, to path: String) async throws {
        try await simctl(["io", udid, "screenshot", "--type=png", path])
    }

    public func addMedia(udid: String, paths: [String]) async throws {
        try await simctl(["addmedia", udid] + paths, timeout: .seconds(300))
    }

    // MARK: System

    public func setPermission(udid: String, action: PermissionAction, service: PermissionService, bundleId: String?) async throws {
        // simctl silently accepts a bundle id that is not installed, so a typo would look like success.
        if let bundleId {
            _ = try await containerPath(udid: udid, bundleId: bundleId, container: "app")
        } else if action != .reset {
            throw ISimError.invalidArgument("`bundle_id` is required to \(action.rawValue) a permission.")
        }
        try await simctl(["privacy", udid, action.rawValue, service.rawValue] + (bundleId.map { [$0] } ?? []))
    }

    public func sendPush(udid: String, bundleId: String, payloadPath: String) async throws {
        let result = try await runner.run(xcrun, ["simctl", "push", udid, bundleId, payloadPath], timeout: defaultTimeout)
        guard result.succeeded else {
            if result.stderrString.contains("not authorized") {
                throw ISimError.commandFailed(
                    command: "simctl push",
                    message: "iOS refused the notification for \(bundleId). The app needs the Push Notifications capability "
                        + "and must have been allowed to show notifications (launch it and accept the prompt).")
            }
            throw Self.failure(["push"], result)
        }
    }

    // MARK: Helpers

    private let xcrun = "/usr/bin/xcrun"

    @discardableResult
    private func simctl(_ arguments: [String], timeout: Duration? = nil) async throws -> ProcessResult {
        let result = try await runner.run(xcrun, ["simctl"] + arguments, timeout: timeout ?? defaultTimeout)
        guard result.succeeded else { throw Self.failure(arguments, result) }
        return result
    }

    static func notInstalled(_ bundleId: String) -> ISimError {
        .notFound("\(bundleId) is not installed on the simulator. Use list_apps to see installed apps.")
    }

    static func failure(_ arguments: [String], _ result: ProcessResult) -> ISimError {
        .commandFailed(command: "simctl \(arguments.first ?? "")", message: SimctlParser.errorMessage(result))
    }
}
