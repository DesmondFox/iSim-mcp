import DeviceCore
import Foundation
import ProcessKit
import SimctlBackend
import TestSupport
import Testing

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func fixtureString(_ name: String) throws -> String {
    String(decoding: try fixture(name), as: UTF8.self)
}

struct SimctlParserTests {
    @Test func parsesIOSSimulatorsOnly() throws {
        let devices = try SimctlParser.devices(fromListJSON: try fixture("simctl-list-devices.json"))
        #expect(!devices.contains { $0.name.contains("Watch") })
        #expect(devices.allSatisfy { $0.kind == .simulator })

        let booted = try #require(devices.first { $0.udid == "8D408511-219C-42B6-98FB-C0ED9F56836F" })
        #expect(booted.name == "iPhone 16 Pro")
        #expect(booted.state == .booted)
        #expect(booted.osVersion == "27.0")
        #expect(booted.model == "iPhone 16 Pro")

        let unavailable = try #require(devices.first { $0.udid == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" })
        #expect(!unavailable.isAvailable)
        #expect(unavailable.osVersion == "26.0")
    }

    @Test func sortsNewestRuntimeFirst() throws {
        let devices = try SimctlParser.devices(fromListJSON: try fixture("simctl-list-devices.json"))
        let versions = devices.compactMap(\.osVersion)
        #expect(versions == versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending })
    }

    @Test func parsesRuntimes() throws {
        let runtimes = try SimctlParser.runtimes(fromListJSON: try fixture("simctl-list-runtimes.json"))
        #expect(runtimes.map(\.name) == ["iOS 27.0", "iOS 27.1"])
        #expect(runtimes.allSatisfy { $0.isAvailable })
    }

    @Test func parsesOpenStepListApps() throws {
        let apps = try SimctlParser.apps(fromListAppsPlist: try fixture("simctl-listapps.plist"))
        let user = apps.filter { $0.type == "user" }
        #expect(user.map(\.bundleId).contains("com.example.demo"))
        #expect(apps.first?.type == "user", "user apps come first")

        let demo = try #require(user.first { $0.bundleId == "com.example.demo" })
        #expect(demo.name == "Demo (staging)")
        #expect(demo.version == "1.0.32")
        #expect(demo.build == "29")
        #expect(demo.path?.hasSuffix("Runner.app") == true)

        let settings = try #require(apps.first { $0.bundleId == "com.apple.Preferences" })
        #expect(settings.type == "system")
    }

    @Test func parsesLaunchPID() {
        #expect(SimctlParser.pid(fromLaunchOutput: "com.apple.mobilesafari: 23860\n") == 23860)
        #expect(SimctlParser.pid(fromLaunchOutput: "") == nil)
    }

    @Test func condensesErrorOutput() {
        let stderr = """
            An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):
            Simulator device failed to terminate com.apple.mobilesafari.
            found nothing to terminate
            Underlying error (domain=NSPOSIXErrorDomain, code=3):
            \tThe request to terminate "com.apple.mobilesafari" failed. found nothing to terminate
            \tfound nothing to terminate
            """
        let message = SimctlParser.errorMessage(ProcessResult(exitCode: 3, stderr: Data(stderr.utf8)))
        #expect(message == "Simulator device failed to terminate com.apple.mobilesafari. found nothing to terminate The request to terminate \"com.apple.mobilesafari\" failed. found nothing to terminate")
    }
}

struct SimctlBackendTests {
    let runner = ScriptedRunner()
    var backend: SimctlBackend { SimctlBackend(runner: runner) }

    @Test func launchPassesEnvironmentWithSimctlChildPrefix() async throws {
        runner.on("simctl launch", stdout: "com.example.demo: 4242\n")
        let options = LaunchOptions(arguments: ["-Flag", "YES"], environment: ["API": "staging"], terminateExisting: true)
        let pid = try await backend.launch(udid: "SIM", bundleId: "com.example.demo", options: options)

        #expect(pid == 4242)
        let call = try #require(runner.calls.first)
        #expect(call.executable == "/usr/bin/xcrun")
        #expect(call.arguments == ["simctl", "launch", "--terminate-running-process", "SIM", "com.example.demo", "-Flag", "YES"])
        #expect(call.environment == ["SIMCTL_CHILD_API": "staging"])
    }

    @Test func launchOfMissingAppSaysItIsNotInstalled() async throws {
        runner.on("simctl launch", exitCode: 4, stderr: "An error was encountered processing the command (domain=FBSOpenApplicationServiceErrorDomain, code=4):\n")
        let error = await #expect(throws: ISimError.self) {
            try await backend.launch(udid: "SIM", bundleId: "com.missing", options: LaunchOptions())
        }
        #expect(error?.description.contains("com.missing is not installed") == true)
    }

    @Test func bootingABootedDeviceIsFine() async throws {
        runner.on("simctl boot", exitCode: 149, stderr: "Unable to boot device in current state: Booted")
        try await backend.boot(udid: "SIM", wait: false)
        #expect(runner.calls.map(\.commandLine) == ["simctl boot SIM"])
    }

    @Test func bootWaitsWithBootstatus() async throws {
        runner.on("simctl boot")
        runner.on("simctl bootstatus")
        try await backend.boot(udid: "SIM", wait: true)
        #expect(runner.calls.map(\.commandLine) == ["simctl boot SIM", "simctl bootstatus SIM"])
    }

    @Test func terminateOfNotRunningAppIsNotAnError() async throws {
        runner.on("simctl terminate", exitCode: 3, stderr: "found nothing to terminate")
        #expect(try await backend.terminate(udid: "SIM", bundleId: "com.example.demo") == .notRunning)
    }

    @Test func failuresNameTheSubcommand() async throws {
        runner.on("simctl openurl", exitCode: 1, stderr: "Simulator device failed to open bad://url.\n")
        await #expect(throws: ISimError.commandFailed(command: "simctl openurl", message: "Simulator device failed to open bad://url.")) {
            try await backend.openURL(udid: "SIM", url: "bad://url")
        }
    }

    @Test func listAppsFiltersSystemApps() async throws {
        runner.on("simctl listapps", stdout: try fixtureString("simctl-listapps.plist"))
        let apps = try await backend.listApps(udid: "SIM", includeSystem: false)
        #expect(!apps.isEmpty)
        #expect(apps.allSatisfy { $0.type == "user" })
    }
}
