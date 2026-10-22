import DeviceCore
import Foundation
import ProcessKit

/// Operations through `xcrun devicectl` (JSON output). Works for physical devices and simulators.
public struct DevicectlBackend: DeviceListing, AppManaging, ScreenCapturing, DisplayInfoProviding {
    private let runner: any ProcessRunning
    private let defaultTimeout: Duration

    public init(runner: any ProcessRunning, defaultTimeout: Duration = .seconds(60)) {
        self.runner = runner
        self.defaultTimeout = defaultTimeout
    }

    // MARK: Devices

    /// Physical iOS devices only; simulators come from simctl, which also sees unavailable ones.
    public func listDevices() async throws -> [Device] {
        let json = try await devicectl(["list", "devices"])
        return try DevicectlParser.physicalDevices(from: json)
    }

    /// true when the device needs a passcode to unlock right now.
    public func isLocked(udid: String) async throws -> Bool {
        let json = try await devicectl(["device", "info", "lockState", "--device", udid])
        return json["passcodeRequired"] as? Bool ?? false
    }

    // MARK: Apps

    public func listApps(udid: String, includeSystem: Bool) async throws -> [InstalledApp] {
        var arguments = ["device", "info", "apps", "--device", udid]
        if includeSystem { arguments.append("--include-all-apps") }
        let json = try await devicectl(arguments)
        return try DevicectlParser.apps(from: json)
    }

    public func install(udid: String, path: String) async throws {
        try await devicectl(["device", "install", "app", "--device", udid, path], timeout: .seconds(600))
    }

    public func uninstall(udid: String, bundleId: String) async throws {
        try await devicectl(["device", "uninstall", "app", "--device", udid, bundleId], timeout: .seconds(120))
    }

    public func launch(udid: String, bundleId: String, options: LaunchOptions) async throws -> Int? {
        var arguments = ["device", "process", "launch", "--device", udid]
        if options.terminateExisting { arguments.append("--terminate-existing") }
        if options.startStopped { arguments.append("--start-stopped") }
        if !options.environment.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: options.environment, options: [.sortedKeys])
            arguments += ["--environment-variables", String(decoding: data, as: UTF8.self)]
        }
        arguments.append(bundleId)
        if !options.arguments.isEmpty { arguments += ["--"] + options.arguments }
        let json = try await devicectl(arguments)
        return DevicectlParser.launchedPID(from: json)
    }

    /// devicectl terminates by pid only: find the app's main process by its bundle URL.
    public func terminate(udid: String, bundleId: String) async throws -> TerminateOutcome {
        let appsJSON = try await devicectl(["device", "info", "apps", "--device", udid, "--include-default-apps", "--bundle-id", bundleId])
        guard let appURL = try DevicectlParser.apps(from: appsJSON).first?.path else {
            throw ISimError.notFound("\(bundleId) is not installed on the device. Use list_apps to see installed apps.")
        }
        let processesJSON = try await devicectl(["device", "info", "processes", "--device", udid])
        guard let pid = try DevicectlParser.mainProcessPID(appURL: appURL, processesJSON: processesJSON) else {
            return .notRunning
        }
        try await devicectl(["device", "process", "terminate", "--device", udid, "--pid", String(pid)])
        return .terminated(pid: pid)
    }

    public func openURL(udid: String, url: String) async throws {
        try await devicectl(["device", "process", "openURL", "--device", udid, url])
    }

    // MARK: Screen

    public func screenshot(udid: String, to path: String) async throws {
        try await devicectl(["device", "capture", "screenshot", "--device", udid, "--destination", path])
    }

    public func displayInfo(udid: String) async throws -> DisplayInfo {
        let json = try await devicectl(["device", "info", "displays", "--device", udid])
        return try DevicectlParser.mainDisplay(from: json)
    }

    // MARK: Helpers

    /// Runs devicectl with `--json-output -` and returns the `result` object.
    /// The JSON is on stdout even on failure, so errors come from it rather than from stderr.
    @discardableResult
    private func devicectl(_ arguments: [String], timeout: Duration? = nil) async throws -> [String: Any] {
        // Global options go before the subcommand so they are never taken for app arguments after `--`.
        let result = try await runner.run("/usr/bin/xcrun", ["devicectl", "--quiet", "--json-output", "-"] + arguments, timeout: timeout ?? defaultTimeout)
        return try DevicectlParser.result(from: result, command: "devicectl " + arguments.prefix(3).joined(separator: " "))
    }
}
