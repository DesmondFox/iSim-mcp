import DeviceCore
import Foundation
import ProcessKit

/// Operations through `xcrun devicectl` (JSON output). Works for physical devices and simulators.
public struct DevicectlBackend: DeviceListing, DeviceRebooting, AppManaging, AppInspecting, ScreenCapturing, DisplayInfoProviding,
    OrientationControlling, AppearanceConfiguring, LocationSimulating, StatusBarOverriding, BiometricsSimulating, PasteboardAccessing
{
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

    /// `wait` works only for devices connected by cable.
    public func reboot(udid: String, wait: Bool) async throws {
        try await devicectl(["device", "reboot", "--device", udid] + (wait ? ["--wait-for-device"] : []), timeout: .seconds(600))
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

    public func appInfo(udid: String, bundleId: String) async throws -> AppDetails {
        let json = try await devicectl([
            "device", "info", "apps", "--device", udid, "--include-default-apps",
            "--include-container-paths", "--include-app-group-identifiers", "--bundle-id", bundleId,
        ])
        guard let details = try DevicectlParser.appDetails(from: json) else {
            throw ISimError.notFound("\(bundleId) is not installed on the device. Use list_apps to see installed apps.")
        }
        return details
    }

    /// Running processes; app processes get their bundle id from the installed apps' bundle URLs.
    public func listProcesses(udid: String) async throws -> [RunningProcess] {
        async let processes = devicectl(["device", "info", "processes", "--device", udid])
        async let apps = devicectl(["device", "info", "apps", "--device", udid, "--include-all-apps"])
        return DevicectlParser.processes(from: try await processes, apps: try DevicectlParser.apps(from: try await apps))
    }

    // MARK: Screen

    public func screenshot(udid: String, to path: String) async throws {
        try await screenshot(udid: udid, to: path, display: nil)
    }

    /// `display`: a display's `uniqueId` from `screenInfo`; nil captures the primary display.
    public func screenshot(udid: String, to path: String, display: String?) async throws {
        try await devicectl(["device", "capture", "screenshot", "--device", udid, "--destination", path]
            + (display.map { ["--display-unique-id", $0] } ?? []))
    }

    public func displayInfo(udid: String) async throws -> DisplayInfo {
        let json = try await devicectl(["device", "info", "displays", "--device", udid])
        return try DevicectlParser.mainDisplay(from: json)
    }

    public func screenInfo(udid: String) async throws -> ScreenInfo {
        let json = try await devicectl(["device", "info", "displays", "--device", udid])
        return try DevicectlParser.screenInfo(from: json)
    }

    public func orientation(udid: String) async throws -> OrientationState {
        DevicectlParser.orientation(from: try await devicectl(["device", "orientation", "get", "--device", udid]))
    }

    public func setOrientation(udid: String, _ orientation: DeviceOrientation) async throws -> OrientationState {
        DevicectlParser.orientation(from: try await devicectl(["device", "orientation", "set", "--device", udid, orientation.rawValue]))
    }

    // MARK: Appearance

    public func appearance(udid: String) async throws -> AppearanceSettings {
        DevicectlParser.appearance(from: try await devicectl(["device", "info", "appearance", "--device", udid]))
    }

    /// Returns all settings after the change: devicectl reports back only the changed ones.
    public func setAppearance(udid: String, _ changes: AppearanceSettings) async throws -> AppearanceSettings {
        var arguments = ["device", "settings", "appearance", "--device", udid]
        if let style = changes.style { arguments += ["--mode", style.rawValue] }
        if let size = changes.contentSize {
            arguments += ["--text-size", size.rawValue]
            // devicectl refuses accessibility sizes unless this is switched on.
            if size.isAccessibility { arguments += ["--larger-accessibility-sizes", "on"] }
        }
        if let contrast = changes.increaseContrast { arguments += ["--increase-contrast", contrast ? "on" : "off"] }
        if let motion = changes.reduceMotion { arguments += ["--reduce-motion", motion ? "on" : "off"] }
        try await devicectl(arguments)
        return try await appearance(udid: udid)
    }

    // MARK: Location

    public func setLocation(udid: String, _ coordinate: Coordinate) async throws {
        // `=` keeps a negative value from being parsed as an option.
        try await devicectl([
            "device", "simulate", "location", "coordinate", "--device", udid,
            "--latitude=\(coordinate.latitude)", "--longitude=\(coordinate.longitude)",
        ])
    }

    public func clearLocation(udid: String) async throws {
        try await devicectl(["device", "simulate", "location", "clear", "--device", udid])
    }

    /// Goes through a route file: devicectl rejects `--waypoints` given on the command line.
    public func simulateRoute(udid: String, waypoints: [Coordinate], speed: Double) async throws {
        let route: [String: Any] = [
            "mode": "interval",
            "interval": 1.0,
            "speed": speed,
            "waypoints": waypoints.map { ["latitude": $0.latitude, "longitude": $0.longitude] },
        ]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("isim-route-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: route, options: [.sortedKeys]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await devicectl(["device", "simulate", "location", "route", "--device", udid, "--route-file", file.path])
    }

    public func runLocationScenario(udid: String, name: String) async throws {
        try await devicectl(["device", "simulate", "location", "scenario", "--device", udid, name])
    }

    public func locationScenarios(udid: String) async throws -> [String] {
        let json = try await devicectl(["device", "simulate", "location", "list", "--device", udid])
        return (json["availableScenarios"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    // MARK: Status bar

    public func overrideStatusBar(udid: String, _ override: StatusBarOverride) async throws {
        var arguments = ["device", "simulate", "statusBar", "override", "--device", udid]
        if let time = override.time { arguments += ["--time", time] }
        if let network = override.dataNetwork { arguments += ["--data-network", network] }
        // devicectl takes signal strength only with the active mode, and the active mode only with a strength.
        if let mode = override.wifiMode ?? (override.wifiBars != nil ? "active" : nil) {
            arguments += ["--wifi-mode", mode]
            if mode == "active" { arguments += ["--wifi-strength", String(override.wifiBars ?? StatusBarOverride.wifiBarsRange.upperBound)] }
        }
        if let mode = override.cellularMode ?? (override.cellularBars != nil ? "active" : nil) {
            arguments += ["--cellular-mode", mode]
            if mode == "active" { arguments += ["--cellular-strength", String(override.cellularBars ?? StatusBarOverride.cellularBarsRange.upperBound)] }
        }
        if let state = override.batteryState { arguments += ["--battery-state", state] }
        if let level = override.batteryLevel { arguments += ["--battery-level", String(level)] }
        try await devicectl(arguments)
    }

    public func applyStatusBarPreset(udid: String, _ preset: StatusBarPreset) async throws {
        try await devicectl(["device", "simulate", "statusBar", "preset", "--device", udid, preset.rawValue])
    }

    public func clearStatusBar(udid: String) async throws {
        try await devicectl(["device", "simulate", "statusBar", "clear", "--device", udid])
    }

    public func statusBar(udid: String) async throws -> StatusBarOverride {
        DevicectlParser.statusBar(from: try await devicectl(["device", "simulate", "statusBar", "show", "--device", udid]))
    }

    // MARK: Biometrics

    public func biometricEnrollment(udid: String) async throws -> [BiometricEnrollment] {
        DevicectlParser.biometrics(from: try await devicectl(["device", "settings", "biometrics", "--device", udid]))
    }

    public func setBiometricEnrollment(udid: String, enrolled: Bool) async throws -> [BiometricEnrollment] {
        DevicectlParser.biometrics(from: try await devicectl(["device", "settings", "biometrics", "--device", udid, enrolled ? "--enable" : "--disable"]))
    }

    public func simulateBiometricMatch(udid: String, success: Bool) async throws {
        try await devicectl(["device", "simulate", "biometrics", "--device", udid, success ? "--success" : "--failure"])
    }

    // MARK: Pasteboard

    /// Goes through a file: the runner gives children no stdin.
    public func copyToPasteboard(udid: String, text: String) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("isim-pasteboard-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await devicectl(["device", "pasteboard", "copy", "--device", udid, "--file", file.path])
    }

    /// `paste` writes the content to stdout, so its JSON goes to a file.
    public func pasteboardText(udid: String) async throws -> String? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("isim-paste-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let arguments = ["device", "pasteboard", "paste", "--device", udid]
        let result = try await runner.run("/usr/bin/xcrun", ["devicectl", "--quiet", "--json-output", file.path] + arguments, timeout: defaultTimeout)
        let json = FileManager.default.contents(atPath: file.path) ?? Data()
        _ = try DevicectlParser.result(
            from: ProcessResult(exitCode: result.exitCode, stdout: json, stderr: result.stderr),
            command: "devicectl device pasteboard paste")
        return result.stdout.isEmpty ? nil : result.stdoutString
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
