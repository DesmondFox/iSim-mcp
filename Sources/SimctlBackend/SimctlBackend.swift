import DeviceCore
import Foundation
import ProcessKit

/// Simulator operations through `xcrun simctl`.
public struct SimctlBackend: DeviceListing, SimulatorLifecycle, AppManaging, ScreenCapturing {
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

    // MARK: Screen

    public func screenshot(udid: String, to path: String) async throws {
        try await simctl(["io", udid, "screenshot", "--type=png", path])
    }

    // MARK: Helpers

    private let xcrun = "/usr/bin/xcrun"

    @discardableResult
    private func simctl(_ arguments: [String], timeout: Duration? = nil) async throws -> ProcessResult {
        let result = try await runner.run(xcrun, ["simctl"] + arguments, timeout: timeout ?? defaultTimeout)
        guard result.succeeded else { throw Self.failure(arguments, result) }
        return result
    }

    static func failure(_ arguments: [String], _ result: ProcessResult) -> ISimError {
        .commandFailed(command: "simctl \(arguments.first ?? "")", message: SimctlParser.errorMessage(result))
    }
}
