import DeviceCore
import Foundation
import TestSupport
import Testing

struct CapabilityMatrixTests {
    @Test func simulatorAndPhysicalUseTheirBackends() throws {
        let matrix = CapabilityMatrix.standard
        #expect(try matrix.backend(for: .screenshot, on: .simulator) == .simctl)
        #expect(try matrix.backend(for: .screenshot, on: .physical) == .devicectl)
        #expect(try matrix.backend(for: .displayInfo, on: .simulator) == .devicectl)
    }

    @Test func lifecycleIsUnsupportedOnPhysicalDevicesWithAHint() {
        let error = #expect(throws: ISimError.self) {
            try CapabilityMatrix.standard.backend(for: .boot, on: .physical)
        }
        #expect(error?.description == "boot_device is not available on physical devices. Physical devices are always on: connect and unlock the iPhone.")
    }

    @Test func everyCapabilityHasAnEntry() {
        for capability in Capability.allCases {
            let simulator = try? CapabilityMatrix.standard.backend(for: capability, on: .simulator)
            let physical = try? CapabilityMatrix.standard.backend(for: capability, on: .physical)
            #expect(simulator != nil || physical != nil, "\(capability) has no backend at all")
        }
    }
}

struct XcodeEnvironmentTests {
    @Test(arguments: [("27.0", true), ("27.1", true), ("27.10", true), ("28.0", true), ("26.4", false), ("9.0", false)])
    func versionCheck(version: String, supported: Bool) {
        #expect(XcodeEnvironment(developerDir: "/X", version: version, build: nil).isSupported == supported)
    }

    @Test func readsVersionFromDeveloperDir() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FakeXcode-\(UUID().uuidString).app/Contents")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Developer"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try (["CFBundleShortVersionString": "27.1"] as NSDictionary).write(to: root.appendingPathComponent("Info.plist"))
        try (["ProductBuildVersion": "27A9275"] as NSDictionary).write(to: root.appendingPathComponent("version.plist"))

        let developerDir = root.appendingPathComponent("Developer").path
        let xcode = try XcodeEnvironment.detect(environment: ["DEVELOPER_DIR": developerDir])
        #expect(xcode == XcodeEnvironment(developerDir: developerDir, version: "27.1", build: "27A9275"))
        #expect(xcode.childEnvironment == ["DEVELOPER_DIR": developerDir])
    }

    @Test func commandLineToolsAreRejected() {
        #expect(throws: ISimError.self) {
            try XcodeEnvironment.detect(environment: ["DEVELOPER_DIR": "/Library/Developer/CommandLineTools"])
        }
    }
}

struct DeviceSessionTests {
    struct FixedSource: DeviceListing {
        var result: Result<[Device], ISimError>
        func listDevices() async throws -> [Device] { try result.get() }
    }

    let simulator = Device(udid: "SIM-1", name: "iPhone 16 Pro", kind: .simulator, state: .booted)

    @Test func failingSourceBecomesAWarning() async throws {
        let session = DeviceSession(sources: [
            FixedSource(result: .success([simulator])),
            FixedSource(result: .failure(.commandFailed(command: "devicectl list devices", message: "broken"))),
        ])
        let listing = try await session.listDevices()
        #expect(listing.devices == [simulator])
        #expect(listing.warnings == ["`devicectl list devices` failed: broken"])
    }

    @Test func allSourcesFailingIsAnError() async {
        let session = DeviceSession(sources: [FixedSource(result: .failure(.notFound("no simctl")))])
        await #expect(throws: ISimError.notFound("no simctl")) { try await session.listDevices() }
    }

    @Test func activeDeviceIsUsedUntilCleared() async throws {
        let other = Device(udid: "SIM-2", name: "iPhone 17", kind: .simulator, state: .booted)
        let session = DeviceSession(sources: [FixedSource(result: .success([simulator, other]))])
        try await session.setActive("iPhone 17")
        #expect(try await session.resolve(nil) == other)
        await session.clearActive()
        await #expect(throws: ISimError.self) { try await session.resolve(nil) }
    }

    @Test func resolveReadyRejectsShutdownSimulator() async {
        let off = Device(udid: "SIM-3", name: "Off", kind: .simulator, state: .shutdown)
        let session = DeviceSession(sources: [FixedSource(result: .success([off]))])
        await #expect(throws: ISimError.deviceNotReady(off)) { try await session.resolveReady("Off") }
    }
}

struct AppBundleInfoTests {
    @Test func readsAppBundle() async throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("Demo-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let plist: NSDictionary = [
            "CFBundleIdentifier": "com.example.demo",
            "CFBundleName": "Demo",
            "CFBundleShortVersionString": "1.2",
            "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
        ]
        try plist.write(to: app.appendingPathComponent("Info.plist"))

        let info = try await AppBundleInfo.read(path: app.path, runner: ScriptedRunner())
        #expect(info == AppBundleInfo(bundleId: "com.example.demo", name: "Demo", version: "1.2", platforms: ["iPhoneSimulator"]))
    }

    @Test func readsIPAThroughUnzip() async throws {
        let ipa = FileManager.default.temporaryDirectory.appendingPathComponent("Demo-\(UUID().uuidString).ipa")
        try Data("zip".utf8).write(to: ipa)
        defer { try? FileManager.default.removeItem(at: ipa) }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.ipa", "CFBundleSupportedPlatforms": ["iPhoneOS"]],
            format: .binary, options: 0)
        let runner = ScriptedRunner()
        runner.on("Payload/*.app/Info.plist", result: .init(exitCode: 0, stdout: plist))

        let info = try await AppBundleInfo.read(path: ipa.path, runner: runner)
        #expect(info.bundleId == "com.example.ipa")
        #expect(info.platforms == ["iPhoneOS"])
        #expect(runner.calls.first?.arguments == ["-p", ipa.path, "Payload/*.app/Info.plist"])
    }

    @Test func rejectsMissingFileAndWrongExtension() async throws {
        await #expect(throws: ISimError.self) { try await AppBundleInfo.read(path: "/nonexistent.app", runner: ScriptedRunner()) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).txt")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await #expect(throws: ISimError.self) { try await AppBundleInfo.read(path: file.path, runner: ScriptedRunner()) }
    }
}
