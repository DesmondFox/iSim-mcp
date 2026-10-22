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

    @Test func parsesRuntimeDeviceTypes() throws {
        let runtimes = try SimctlParser.runtimes(fromListJSON: try fixture("simctl-list-runtimes.json"))
        let types = try #require(runtimes.first?.supportedDeviceTypes)
        let iPhone = try #require(types.first { $0.name == "iPhone 16 Pro" })
        #expect(iPhone.identifier == "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro")
        #expect(iPhone.productFamily == "iPhone")
    }

    @Test func parsesAppInfo() throws {
        let (details, executable) = try SimctlParser.appInfo(fromPlist: try fixture("simctl-appinfo.plist"))
        #expect(details.app.bundleId == "com.example.demo")
        #expect(details.app.name == "Demo (staging)")
        #expect(details.app.version == "1.0.32")
        #expect(details.app.build == "29")
        #expect(details.app.type == "user")
        #expect(details.flags == ["developer build"])
        #expect(details.dataContainer?.hasSuffix("/Data/Application/FC8D0540-8971-4B30-959E-7BF2E4E7C0A5") == true)
        #expect(details.dataContainer?.hasPrefix("/Users/tester/") == true, "file URLs become paths")
        #expect(details.appGroups.map(\.identifier) == ["group.com.example.demo"])
        #expect(details.appGroups.first?.path?.hasSuffix("/AppGroup/0F0F0F0F-1111-2222-3333-444444444444") == true)
        #expect(executable?.hasSuffix("/Runner.app/Runner") == true)
    }

    @Test func parsesLaunchctlListAppsFirst() throws {
        let processes = SimctlParser.processes(fromLaunchctlList: try fixtureString("simctl-launchctl-list.txt"))
        #expect(processes.map(\.pid) == [29091, 29312, 23825, 34847, 28877], "apps by name, then daemons; jobs without a pid are skipped")
        let demo = try #require(processes.first { $0.pid == 34847 })
        #expect(demo.bundleId == "com.example.demo")
        #expect(demo.name == "com.example.demo")
        let springBoard = try #require(processes.last)
        #expect(springBoard.bundleId == nil)
        #expect(springBoard.name == "com.apple.SpringBoard")
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

    @Test func rebootIsShutdownThenBoot() async throws {
        runner.on("simctl shutdown")
        runner.on("simctl boot")
        try await backend.reboot(udid: "SIM", wait: true)
        #expect(runner.calls.map(\.commandLine) == ["simctl shutdown SIM", "simctl boot SIM", "simctl bootstatus SIM"])
    }

    @Test func createReturnsTheNewUDID() async throws {
        runner.on("simctl create", stdout: "35A20DE3-D32C-4D18-A80B-D5A3C18F847D\n")
        let udid = try await backend.createDevice(name: "Test", deviceTypeId: "com.apple.CoreSimulator.SimDeviceType.iPhone-16e",
                                                  runtimeId: "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        #expect(udid == "35A20DE3-D32C-4D18-A80B-D5A3C18F847D")
        #expect(runner.calls.first?.arguments == [
            "simctl", "create", "Test", "com.apple.CoreSimulator.SimDeviceType.iPhone-16e", "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
        ])
    }

    @Test func appInfoOfMissingAppSaysItIsNotInstalled() async throws {
        runner.on("simctl appinfo", exitCode: 3, stderr: "No application record found for that bundle identifier\n")
        let error = await #expect(throws: ISimError.self) { try await backend.appInfo(udid: "SIM", bundleId: "com.missing") }
        #expect(error?.description.hasPrefix("com.missing is not installed") == true)
    }

    @Test func appInfoReadsEntitlementsOfUserApps() async throws {
        runner.on("simctl appinfo", stdout: try fixtureString("simctl-appinfo.plist"))
        // segedit writes the section to the file named in its last argument; the scripted runner writes nothing,
        // so the backend falls back to codesign.
        runner.on("segedit", exitCode: 1)
        runner.on("--entitlements", stdout: """
            <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>\
            <key>aps-environment</key><string>development</string></dict></plist>
            """)
        let details = try await backend.appInfo(udid: "SIM", bundleId: "com.example.demo")
        #expect(details.entitlementsJSON == #"{"aps-environment":"development"}"#)
        #expect(runner.calls.last?.arguments.last?.hasSuffix("/Runner.app/Runner") == true)
    }

    @Test func containerErrorsAreSpecific() async throws {
        runner.on("get_app_container SIM com.missing", exitCode: 2, stderr: "No such file or directory\n")
        runner.on("get_app_container SIM com.example.demo group.nope", exitCode: 117, stderr: "Usage: simctl get_app_container <device>\n")
        runner.on("get_app_container SIM com.apple.Preferences data", stdout: "(null)\n")
        runner.on("get_app_container SIM com.example.demo data", stdout: "/Users/tester/Data/Application/ABC\n")

        #expect(try await backend.containerPath(udid: "SIM", bundleId: "com.example.demo", container: "data") == "/Users/tester/Data/Application/ABC")
        await #expect(throws: ISimError.notFound("com.missing is not installed on the simulator. Use list_apps to see installed apps.")) {
            try await backend.containerPath(udid: "SIM", bundleId: "com.missing", container: "app")
        }
        await #expect(throws: ISimError.notFound("com.apple.Preferences has no data container.")) {
            try await backend.containerPath(udid: "SIM", bundleId: "com.apple.Preferences", container: "data")
        }
        let error = await #expect(throws: ISimError.self) {
            try await backend.containerPath(udid: "SIM", bundleId: "com.example.demo", container: "group.nope")
        }
        #expect(error?.description.contains("Use container=groups") == true)
    }

    @Test func permissionChecksThatTheAppIsInstalled() async throws {
        runner.on("get_app_container SIM com.typo", exitCode: 2)
        await #expect(throws: ISimError.notFound("com.typo is not installed on the simulator. Use list_apps to see installed apps.")) {
            try await backend.setPermission(udid: "SIM", action: .grant, service: .photos, bundleId: "com.typo")
        }
        #expect(!runner.calls.contains { $0.commandLine.contains("privacy") })
    }

    @Test func permissionResetWithoutBundleAppliesToAllApps() async throws {
        runner.on("simctl privacy")
        try await backend.setPermission(udid: "SIM", action: .reset, service: .locationAlways, bundleId: nil)
        #expect(runner.calls.map(\.commandLine) == ["simctl privacy SIM reset location-always"])
        await #expect(throws: ISimError.self) {
            try await backend.setPermission(udid: "SIM", action: .revoke, service: .photos, bundleId: nil)
        }
    }

    @Test func pushRefusedByIOSExplainsWhy() async throws {
        runner.on("simctl push", exitCode: 211, stderr: "Repository could not save notification. Source is not authorized.\n")
        let error = await #expect(throws: ISimError.self) {
            try await backend.sendPush(udid: "SIM", bundleId: "com.example.demo", payloadPath: "/tmp/p.json")
        }
        #expect(error?.description.contains("allowed to show notifications") == true)
    }

    @Test func listAppsFiltersSystemApps() async throws {
        runner.on("simctl listapps", stdout: try fixtureString("simctl-listapps.plist"))
        let apps = try await backend.listApps(udid: "SIM", includeSystem: false)
        #expect(!apps.isEmpty)
        #expect(apps.allSatisfy { $0.type == "user" })
    }
}
