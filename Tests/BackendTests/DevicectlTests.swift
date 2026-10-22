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
        #expect(display == DisplayInfo(widthPixels: 1284, heightPixels: 2778, scale: 3))
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

    @Test func listAppsIncludesSystemAppsOnRequest() async throws {
        runner.on("device info apps", stdout: try fixtureString("devicectl-apps-developer.json"))
        _ = try await backend.listApps(udid: "PHONE", includeSystem: true)
        _ = try await backend.listApps(udid: "PHONE", includeSystem: false)
        #expect(runner.calls.map { $0.arguments.contains("--include-all-apps") } == [true, false])
    }
}
