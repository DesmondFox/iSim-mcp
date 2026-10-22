import DeviceCore
import DevicectlBackend
import Foundation
import ProcessKit
import TestSupport
import Testing

private func result(_ name: String) throws -> [String: Any] {
    try DevicectlParser.result(from: ProcessResult(exitCode: 0, stdout: try fixture(name)), command: "devicectl")
}

struct DevicectlParserTests {
    @Test func listsOnlyPhysicalDevices() throws {
        let devices = try DevicectlParser.physicalDevices(from: try result("devicectl-list-devices.json"))
        #expect(devices.count == 1)
        let phone = try #require(devices.first)
        #expect(phone.udid == "00008110-0000000000000001")
        #expect(phone.name == "Test iPhone")
        #expect(phone.kind == .physical)
        #expect(phone.state == .connected)
        #expect(phone.osVersion == "27.0.1")
        #expect(phone.model == "iPhone 14 Plus")
        #expect(phone.developerMode == "enabled")
        #expect(phone.transport == "wired")
    }

    @Test func classifiesApps() throws {
        let apps = try DevicectlParser.apps(from: try result("devicectl-apps-all.json"))
        let types = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleId, $0.type) })
        #expect(types["com.example.demo"] == "user")
        #expect(types["com.apple.Preferences"] == "system")
        #expect(types["com.apple.mobilesafari"] == "system")
        #expect(apps.first?.type == "user", "user apps come first")
    }

    @Test func findsMainProcessButNotExtensions() throws {
        let processes = try result("devicectl-processes.json")
        let app = "file:///private/var/containers/Bundle/Application/A845C876-1A55-44A8-9ABC-4B5A543129B2/Runner.app/"
        #expect(try DevicectlParser.mainProcessPID(appURL: app, processesJSON: processes) == 4243)
        #expect(try DevicectlParser.mainProcessPID(appURL: "file:///Applications/Preferences.app", processesJSON: processes) == 13095)
        #expect(try DevicectlParser.mainProcessPID(appURL: "file:///Applications/Nothing.app/", processesJSON: processes) == nil)
    }

    @Test func readsMainDisplay() throws {
        let display = try DevicectlParser.mainDisplay(from: try result("devicectl-displays.json"))
        #expect(display == DisplayInfo(widthPixels: 1284, heightPixels: 2778, scale: 3, name: "LCD", uniqueId: nil, isPrimary: true))
    }

    @Test func readsScreenInfoWithDisplayIdAndOrientation() throws {
        let info = try DevicectlParser.screenInfo(from: try result("devicectl-displays-sim.json"))
        #expect(info.displays.map(\.uniqueId) == ["86FCCC67-39FD-409B-8FA8-4B37A2B5B803"])
        #expect(info.orientation == OrientationState(orientation: .portrait, physical: nil, isLocked: false))

        // A phone lying on the table: the interface stays portrait.
        let phone = try DevicectlParser.screenInfo(from: try result("devicectl-displays.json"))
        #expect(phone.orientation == OrientationState(orientation: .portrait, physical: "faceUp", isLocked: false))
    }

    @Test func readsOrientation() throws {
        #expect(DevicectlParser.orientation(from: try result("devicectl-orientation.json"))
            == OrientationState(orientation: .portrait, physical: "faceUp", isLocked: false))
        #expect(DevicectlParser.orientation(from: ["deviceOrientation": "landscapeLeft", "deviceOrientationNonFlat": "landscapeLeft"])
            == OrientationState(orientation: .landscapeLeft))
    }

    @Test func readsAppearance() throws {
        #expect(DevicectlParser.appearance(from: try result("devicectl-appearance.json"))
            == AppearanceSettings(style: .light, contentSize: .large, increaseContrast: false, reduceMotion: false))
        #expect(ContentSize(displayName: "Accessibility Extra Extra Large") == .accessibilityExtraExtraLarge)
    }

    @Test func readsStatusBarWithoutBackticks() throws {
        #expect(DevicectlParser.statusBar(from: try result("devicectl-statusbar.json")) == StatusBarOverride(
            time: "10:09", dataNetwork: "5G", wifiMode: "active", wifiBars: 1, cellularMode: "active", cellularBars: 2,
            batteryState: "charging", batteryLevel: 42))
        #expect(DevicectlParser.statusBar(from: ["deviceIdentifier": "X"]).isEmpty)
    }

    @Test func readsBiometrics() throws {
        #expect(DevicectlParser.biometrics(from: try result("devicectl-biometrics.json")) == [BiometricEnrollment(type: "Face ID", enrolled: true)])
    }

    @Test func readsAppDetailsWithContainers() throws {
        let details = try #require(try DevicectlParser.appDetails(from: try result("devicectl-app-details.json")))
        #expect(details.app.bundleId == "com.example.demo")
        #expect(details.dataContainer == "/private/var/mobile/Containers/Data/Application/559507FC-A024-4511-869E-6F42B0EC48AA")
        #expect(details.appGroups == [AppGroupContainer(
            identifier: "group.com.example.demo", path: "/private/var/mobile/Containers/Shared/AppGroup/0F0F0F0F-1111-2222-3333-444444444444")])
        #expect(details.flags == ["developer build"])
        #expect(try DevicectlParser.appDetails(from: ["apps": []]) == nil)
    }

    @Test func namesAppProcessesByBundleURL() throws {
        let apps = try DevicectlParser.apps(from: try result("devicectl-apps-developer.json"))
        let processes = DevicectlParser.processes(from: try result("devicectl-processes.json"), apps: apps)
        #expect(processes.first == RunningProcess(
            pid: 4243, name: "Runner", bundleId: "com.example.demo",
            path: "/private/var/containers/Bundle/Application/A845C876-1A55-44A8-9ABC-4B5A543129B2/Runner.app/Runner"))
        let share = try #require(processes.first { $0.pid == 4242 })
        #expect(share.bundleId == nil, "extensions are not the app")
        #expect(share.name == "Share")
        #expect(processes.dropFirst().allSatisfy { $0.bundleId == nil })
    }

    @Test func errorMessageIncludesTheInnermostCause() throws {
        let process = ProcessResult(exitCode: 1, stdout: try fixture("devicectl-statusbar-error.json"))
        #expect(throws: ISimError.commandFailed(
            command: "devicectl device simulate statusBar",
            message: "Failed to override status bar Invalid value for cellular bars: expected 0-4"
        )) {
            try DevicectlParser.result(from: process, command: "devicectl device simulate statusBar")
        }
    }

    @Test func errorWithoutDescriptionFallsBackToStderr() {
        let json = #"{"info":{"outcome":"failed"},"error":{"code":1,"domain":"ArgumentParserInternal.ValidationError","userInfo":{}}}"#
        let process = ProcessResult(exitCode: 1, stdout: Data(json.utf8), stderr: Data("ERROR: Missing expected argument\n".utf8))
        #expect(throws: ISimError.commandFailed(command: "devicectl x", message: "Missing expected argument")) {
            try DevicectlParser.result(from: process, command: "devicectl x")
        }
    }

    @Test func readsLaunchedPID() throws {
        #expect(DevicectlParser.launchedPID(from: try result("devicectl-launch.json")) == 23825)
    }

    @Test func failedOutcomeBecomesReadableError() throws {
        let process = ProcessResult(exitCode: 1, stdout: try fixture("devicectl-launch-error.json"))
        #expect(throws: ISimError.commandFailed(
            command: "devicectl device process launch",
            message: "The application failed to launch. The requested application com.does.not.exist is not installed. Provide a valid bundle identifier."
        )) {
            try DevicectlParser.result(from: process, command: "devicectl device process launch")
        }
    }

    @Test func missingJSONFallsBackToStderr() {
        let process = ProcessResult(exitCode: 64, stderr: Data("Error: Unknown option '--bogus'\n".utf8))
        #expect(throws: ISimError.commandFailed(command: "devicectl x", message: "Error: Unknown option '--bogus'")) {
            try DevicectlParser.result(from: process, command: "devicectl x")
        }
    }
}

struct DevicectlBackendTests {
    let runner = ScriptedRunner()
    var backend: DevicectlBackend { DevicectlBackend(runner: runner) }

    @Test func launchPutsJSONFlagsBeforeTheSubcommandAndAppArgumentsAfterSeparator() async throws {
        runner.on("device process launch", stdout: try fixtureString("devicectl-launch.json"))
        let options = LaunchOptions(arguments: ["--json-output", "x"], environment: ["API": "staging"], terminateExisting: true, startStopped: true)
        let pid = try await backend.launch(udid: "PHONE", bundleId: "com.example.demo", options: options)

        #expect(pid == 23825)
        #expect(runner.calls.first?.arguments == [
            "devicectl", "--quiet", "--json-output", "-",
            "device", "process", "launch", "--device", "PHONE", "--terminate-existing", "--start-stopped",
            "--environment-variables", #"{"API":"staging"}"#,
            "com.example.demo", "--", "--json-output", "x",
        ])
    }

    @Test func terminateLooksUpThePIDByBundleURL() async throws {
        runner.on("device info apps", stdout: try fixtureString("devicectl-apps-developer.json"))
        runner.on("device info processes", stdout: try fixtureString("devicectl-processes.json"))
        runner.on("device process terminate", stdout: #"{"info":{"outcome":"success"},"result":{}}"#)

        let outcome = try await backend.terminate(udid: "PHONE", bundleId: "com.example.demo")
        #expect(outcome == .terminated(pid: 4243))
        #expect(runner.calls.map(\.commandLine).last == "devicectl --quiet --json-output - device process terminate --device PHONE --pid 4243")
        #expect(runner.calls.first?.commandLine.contains("--bundle-id com.example.demo") == true)
    }

    @Test func terminateOfNotRunningApp() async throws {
        runner.on("device info apps", stdout: try fixtureString("devicectl-apps-developer.json"))
        runner.on("device info processes", stdout: #"{"info":{"outcome":"success"},"result":{"runningProcesses":[]}}"#)
        #expect(try await backend.terminate(udid: "PHONE", bundleId: "com.example.demo") == .notRunning)
        #expect(runner.calls.count == 2)
    }

    private static let success = #"{"info":{"outcome":"success"},"result":{}}"#

    private func arguments(_ index: Int = 0) -> [String] {
        Array(runner.calls[index].arguments.dropFirst(4))  // drop "devicectl --quiet --json-output -"
    }

    @Test func statusBarBarsImplyActiveModeAndActiveModeGetsFullBars() async throws {
        runner.on("statusBar override", stdout: Self.success)
        try await backend.overrideStatusBar(udid: "SIM", StatusBarOverride(wifiBars: 2, cellularMode: "active", batteryLevel: 50))
        #expect(arguments() == [
            "device", "simulate", "statusBar", "override", "--device", "SIM",
            "--wifi-mode", "active", "--wifi-strength", "2", "--cellular-mode", "active", "--cellular-strength", "4",
            "--battery-level", "50",
        ])
    }

    @Test func accessibilityTextSizeSwitchesOnLargerSizes() async throws {
        runner.on("settings appearance", stdout: Self.success)
        runner.on("info appearance", stdout: try fixtureString("devicectl-appearance.json"))
        _ = try await backend.setAppearance(udid: "SIM", AppearanceSettings(style: .dark, contentSize: .accessibilityLarge, reduceMotion: true))
        #expect(arguments() == [
            "device", "settings", "appearance", "--device", "SIM", "--mode", "dark",
            "--text-size", "accessibility-large", "--larger-accessibility-sizes", "on", "--reduce-motion", "on",
        ])
        #expect(runner.calls.count == 2, "returns the full settings read back after the change")
    }

    @Test func negativeCoordinatesAreNotTakenForOptions() async throws {
        runner.on("location coordinate", stdout: Self.success)
        try await backend.setLocation(udid: "SIM", Coordinate(latitude: 37.3349, longitude: -122.009))
        #expect(arguments().suffix(2) == ["--latitude=37.3349", "--longitude=-122.009"])
    }

    @Test func listsLocationScenarios() async throws {
        runner.on("location list", stdout: try fixtureString("devicectl-location-list.json"))
        #expect(try await backend.locationScenarios(udid: "SIM") == ["City Run", "City Bicycle Ride", "Freeway Drive", "Apple"])
    }

    @Test func routeGoesThroughARouteFile() async throws {
        runner.on("location route", stdout: Self.success)
        try await backend.simulateRoute(udid: "SIM", waypoints: [Coordinate(latitude: 1, longitude: 2), Coordinate(latitude: 3, longitude: 4)], speed: 5)
        let call = arguments()
        let index = try #require(call.firstIndex(of: "--route-file"))
        #expect(call[index + 1].hasSuffix(".json"))
        #expect(!FileManager.default.fileExists(atPath: call[index + 1]), "the temporary file is removed")
    }

    @Test func pasteboardCopyUsesAFileAndPasteKeepsStdoutForTheText() async throws {
        runner.on("pasteboard copy", stdout: Self.success)
        runner.on("pasteboard paste", stdout: "Привет 👋")
        try await backend.copyToPasteboard(udid: "SIM", text: "Привет 👋")
        #expect(arguments().prefix(6) == ["device", "pasteboard", "copy", "--device", "SIM", "--file"])

        // The scripted runner writes no JSON file, so the outcome cannot be read and the call fails clearly.
        await #expect(throws: ISimError.self) { _ = try await backend.pasteboardText(udid: "SIM") }
        let paste = runner.calls[1].arguments
        #expect(paste[2] == "--json-output" && paste[3] != "-", "paste prints the content to stdout, so JSON goes to a file")
    }

    @Test func listAppsIncludesSystemAppsOnRequest() async throws {
        runner.on("device info apps", stdout: try fixtureString("devicectl-apps-developer.json"))
        _ = try await backend.listApps(udid: "PHONE", includeSystem: true)
        _ = try await backend.listApps(udid: "PHONE", includeSystem: false)
        #expect(runner.calls.map { $0.arguments.contains("--include-all-apps") } == [true, false])
    }
}
