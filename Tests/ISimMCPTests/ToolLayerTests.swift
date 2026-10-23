import CoreGraphics
import DeviceCore
import Foundation
import ImageIO
@testable import ISimMCP
import MCP
import SimctlBackend
import TestSupport
import Testing
import UniformTypeIdentifiers

struct ToolsetTests {
    @Test func coreIsAlwaysOn() throws {
        #expect(try Toolset.parse("apps") == [.core, .apps])
        #expect(try Toolset.parse("") == [.core])
    }

    @Test func allEnablesEverything() throws {
        #expect(try Toolset.parse("all") == Set(Toolset.allCases))
    }

    @Test func unknownToolsetIsRejected() {
        #expect(throws: ISimError.self) { try Toolset.parse("apps,bogus") }
    }
}

struct ToolArgumentsTests {
    @Test func acceptsLenientScalars() throws {
        let arguments = ToolArguments(["a": "true", "b": 1, "c": "42", "d": .double(7), "e": .null])
        #expect(try arguments.bool("a", default: false))
        #expect(try arguments.bool("b", default: false))
        #expect(try arguments.int("c") == 42)
        #expect(try arguments.int("d") == 7)
        #expect(try arguments.string("e") == nil)
        #expect(try arguments.bool("missing", default: true))
    }

    @Test func rejectsWrongTypesNamingTheParameter() {
        let arguments = ToolArguments(["flag": "maybe", "list": ["x", 1], "env": ["A": ["nested"]], "n": "x"])
        #expect(throws: ISimError.invalidArgument("`flag` must be true or false.")) { try arguments.bool("flag", default: false) }
        #expect(throws: ISimError.invalidArgument("`list` must be an array of strings.")) { try arguments.stringArray("list") }
        #expect(throws: ISimError.invalidArgument("`env.A` must be a string.")) { try arguments.stringMap("env") }
        #expect(throws: ISimError.invalidArgument("`n` must be an integer.")) { try arguments.int("n") }
        #expect(throws: ISimError.invalidArgument("`missing` is required.")) { try arguments.requiredString("missing") }
    }

    @Test func choicesAreCaseInsensitive() throws {
        let arguments = ToolArguments(["orientation": "LANDSCAPELEFT", "network": "5g", "flag": .null])
        #expect(try arguments.choice("orientation", as: DeviceOrientation.self) == .landscapeLeft)
        #expect(try arguments.choice("network", from: StatusBarOverride.dataNetworks) == "5G")
        #expect(try arguments.optionalBool("flag") == nil)
        #expect(try arguments.optionalBool("missing") == nil)
    }

    @Test func checksRangesAndChoices() {
        let arguments = ToolArguments(["quality": 0, "format": "gif"])
        #expect(throws: ISimError.invalidArgument("`quality` must be between 1 and 100, got 0.")) {
            try arguments.int("quality", default: 80, range: 1...100)
        }
        #expect(throws: ISimError.invalidArgument("`format` must be one of: jpeg, png.")) {
            try arguments.choice("format", default: ImageFormat.jpeg)
        }
    }
}

struct ToolRegistryTests {
    let runner = ScriptedRunner()

    var context: ToolContext {
        ToolContext(runner: runner, xcode: .success(XcodeEnvironment(developerDir: "/Xcode.app/Contents/Developer", version: "27.1", build: nil)))
    }

    init() {
        runner.on("simctl list devices", stdout: """
            {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
              {"udid": "SIM-1", "name": "iPhone 16 Pro", "state": "Booted", "isAvailable": true,
               "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"},
              {"udid": "SIM-2", "name": "iPad Pro 11-inch (M5)", "state": "Shutdown", "isAvailable": true,
               "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB"}
            ]}}
            """)
        runner.on("list devices", stdout: """
            {"info": {"outcome": "success"}, "result": {"devices": [
              {"hardwareProperties": {"reality": "physical", "platform": "iOS", "udid": "PHONE-1", "marketingName": "iPhone 14 Plus"},
               "deviceProperties": {"name": "Test iPhone", "osVersionNumber": "27.0.1", "developerModeStatus": "enabled"},
               "connectionProperties": {"transportType": "wired", "tunnelState": "connected"}}
            ]}}
            """)
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined(separator: "\n")
    }

    @Test func listsOnlyEnabledToolsets() {
        let registry = ISimServer.makeRegistry(toolsets: [.core, .apps])
        let names = registry.tools.map(\.name)
        #expect(names.contains("doctor"))
        #expect(names.contains("launch_app"))
        #expect(!names.contains("screenshot"))
    }

    @Test func defaultToolsetsExposeCoreDevicesAppsScreenAndUI() {
        let names = Set(ISimServer.makeRegistry(toolsets: Toolset.defaults).tools.map(\.name))
        #expect(names == [
            "doctor", "set_active_device", "ui_agent",
            "list_devices", "boot_device", "shutdown_device", "reboot_device", "open_simulator_app", "list_runtimes",
            "create_device", "erase_device", "delete_device",
            "list_apps", "get_app_info", "install_app", "uninstall_app", "launch_app", "terminate_app", "open_url",
            "list_processes", "get_app_container",
            "screenshot", "get_screen_info", "add_media",
            "describe_ui", "find_elements", "describe_point", "tap", "swipe", "type_text", "press_key", "press_button", "wait_for",
            "handle_system_alert", "set_orientation",
        ])
    }

    @Test func systemToolsetHoldsTheEnvironmentTools() {
        let registry = ISimServer.makeRegistry(toolsets: [.system])
        #expect(Set(registry.tools.map(\.name)).subtracting(["doctor", "set_active_device", "ui_agent"]) == [
            "configure_ui", "set_permission", "set_location", "simulate_route", "override_status_bar", "biometrics",
            "set_pasteboard", "get_pasteboard", "send_push",
        ])
    }

    @Test func toolNamesAreUnique() {
        let names = ISimServer.allTools().map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test func everyDeviceToolHasTheDeviceParameterAndAnnotations() throws {
        let deviceIndependent: Set = ["doctor", "list_devices", "list_runtimes", "create_device"]
        for tool in ISimServer.makeRegistry(toolsets: Set(Toolset.allCases)).tools where !deviceIndependent.contains(tool.name) {
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue, "\(tool.name)")
            #expect(properties["device"] != nil, "\(tool.name) has no device parameter")
            #expect(!tool.annotations.isEmpty, "\(tool.name) has no annotations")
        }
    }

    @Test func disabledToolExplainsHowToEnableIt() async throws {
        let registry = ISimServer.makeRegistry(toolsets: [.core])
        let result = try await registry.call("screenshot", arguments: nil, context: context)
        #expect(result.isError == true)
        #expect(text(result) == "screenshot belongs to the \"screen\" toolset, which is disabled. Restart the server with --toolsets core,screen.")
    }

    @Test func unknownToolIsAnErrorResult() async throws {
        let result = try await ISimServer.makeRegistry(toolsets: Toolset.defaults).call("nope", arguments: nil, context: context)
        #expect(result.isError == true)
    }

    @Test func listDevicesShowsRunningDevicesFirstAndMarksActive() async throws {
        let registry = ISimServer.makeRegistry(toolsets: Toolset.defaults)
        let context = self.context
        _ = try await registry.call("set_active_device", arguments: ["device": "Test iPhone"], context: context)
        let result = try await registry.call("list_devices", arguments: [:], context: context)
        #expect(result.isError == nil)
        #expect(text(result) == """
              iPhone 16 Pro — SIM-1, simulator, booted, iOS 27.0
            * Test iPhone — PHONE-1, physical, connected, iOS 27.0.1, iPhone 14 Plus
              iPad Pro 11-inch (M5) — SIM-2, simulator, shutdown, iOS 27.0
            """)
    }

    @Test func lifecycleToolsRefusePhysicalDevices() async throws {
        let result = try await ISimServer.makeRegistry(toolsets: Toolset.defaults)
            .call("boot_device", arguments: ["device": "PHONE-1"], context: context)
        #expect(result.isError == true)
        #expect(text(result).hasPrefix("boot_device is not available on physical devices."))
    }

    @Test func toolsFailClearlyWithoutSupportedXcode() async throws {
        let oldXcode = ToolContext(runner: runner, xcode: .success(XcodeEnvironment(developerDir: "/X", version: "26.4", build: nil)))
        let result = try await ISimServer.makeRegistry(toolsets: Toolset.defaults).call("list_devices", arguments: nil, context: oldXcode)
        #expect(result.isError == true)
        #expect(text(result).contains("needs Xcode 27.0 or newer"))
    }

    @Test func installRejectsSimulatorBuildForIPhone() async throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("Sim-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        try (["CFBundleIdentifier": "com.example.sim", "CFBundleSupportedPlatforms": ["iPhoneSimulator"]] as NSDictionary)
            .write(to: app.appendingPathComponent("Info.plist"))

        let result = try await ISimServer.makeRegistry(toolsets: Toolset.defaults)
            .call("install_app", arguments: ["device": "PHONE-1", "path": .string(app.path)], context: context)
        #expect(result.isError == true)
        #expect(text(result).contains("not for a physical device"))
        #expect(!runner.calls.contains { $0.commandLine.contains("install app") })
    }

    @Test func simulatorOnlyToolsRefuseIPhoneBeforeRunningAnything() async throws {
        let registry = ISimServer.makeRegistry(toolsets: [.devices, .system])
        let calls: [(String, [String: Value])] = [
            ("override_status_bar", ["preset": "screenshot"]),
            ("biometrics", ["action": "match"]),
            ("set_permission", ["action": "grant", "service": "photos", "bundle_id": "com.example.demo"]),
            ("send_push", ["bundle_id": "com.example.demo", "payload": ["aps": ["alert": "Hi"]]]),
            ("erase_device", [:]),
        ]
        for (name, arguments) in calls {
            let result = try await registry.call(name, arguments: arguments.merging(["device": "PHONE-1"]) { $1 }, context: context)
            #expect(result.isError == true, "\(name)")
            #expect(text(result).contains("not available on physical devices"), "\(name)")
        }
        #expect(runner.calls.allSatisfy { $0.commandLine.contains("list devices") }, "nothing but device listing ran")
    }

    @Test func erasingABootedSimulatorBootsItAgain() async throws {
        runner.on("simctl shutdown")
        runner.on("simctl erase")
        runner.on("simctl boot")
        runner.on("defaults read com.apple.Accessibility", stdout: "1\n")
        let result = try await ISimServer.makeRegistry(toolsets: Toolset.defaults)
            .call("erase_device", arguments: ["device": "iPhone 16 Pro"], context: context)
        #expect(text(result) == "Erased \"iPhone 16 Pro\" (SIM-1) and booted it again.")
        #expect(runner.calls.map(\.commandLine).filter { !$0.contains("list devices") } == [
            "simctl shutdown SIM-1", "simctl erase SIM-1", "simctl boot SIM-1", "simctl bootstatus SIM-1",
            // Erasing resets the accessibility preference, so it is checked again.
            "simctl spawn SIM-1 defaults read com.apple.Accessibility ApplicationAccessibilityEnabled",
        ])
    }

    @Test func destructiveDeviceToolsNeedAnExplicitDevice() async throws {
        let registry = ISimServer.makeRegistry(toolsets: Toolset.defaults)
        let erase = try await registry.call("erase_device", arguments: [:], context: context)
        #expect(text(erase) == "`device` is required.")
        let delete = try await registry.call("delete_device", arguments: [:], context: context)
        #expect(text(delete).hasPrefix("Pass `device`"))
        #expect(runner.calls.isEmpty)
    }

    @Test func deletingTheActiveDeviceClearsIt() async throws {
        runner.on("simctl delete")
        let registry = ISimServer.makeRegistry(toolsets: Toolset.defaults)
        let context = self.context
        _ = try await registry.call("set_active_device", arguments: ["device": "SIM-2"], context: context)
        let result = try await registry.call("delete_device", arguments: ["device": "SIM-2"], context: context)
        #expect(result.isError == nil)
        #expect(await context.session.activeUDID == nil)
    }

    @Test func biometricMatchWithoutEnrollmentIsRefused() async throws {
        runner.on("settings biometrics", stdout: #"{"info":{"outcome":"success"},"result":{"biometrics":[{"enabled":false,"type":"Face ID"}]}}"#)
        let result = try await ISimServer.makeRegistry(toolsets: [.system])
            .call("biometrics", arguments: ["device": "SIM-1", "action": "match"], context: context)
        #expect(result.isError == true)
        #expect(text(result).hasPrefix("Face ID is not enrolled on \"iPhone 16 Pro\". Call biometrics with action=enable first"))
        #expect(!runner.calls.contains { $0.commandLine.contains("simulate biometrics") })
    }

    @Test func configureUIWithoutParametersReadsTheCurrentValues() async throws {
        runner.on("info appearance", stdout: """
            {"info":{"outcome":"success"},"result":{"userInterfaceStyle":"dark","textSize":"Extra Large","increaseContrast":true,
             "reduceMotion":{"enabled":false}}}
            """)
        let result = try await ISimServer.makeRegistry(toolsets: [.system]).call("configure_ui", arguments: ["device": "SIM-1"], context: context)
        #expect(text(result) == "\"iPhone 16 Pro\": dark appearance, text size extra-large, Increase Contrast on, Reduce Motion off")
        #expect(!runner.calls.contains { $0.commandLine.contains("settings appearance") })
    }

    @Test func grantNeedsABundleId() async throws {
        let result = try await ISimServer.makeRegistry(toolsets: [.system])
            .call("set_permission", arguments: ["device": "SIM-1", "action": "grant", "service": "photos"], context: context)
        #expect(text(result) == "`bundle_id` is required to grant a permission.")
    }

    @Test func modelIsHiddenWhenItRepeatsTheName() {
        #expect(DeviceTools.isRedundant(model: "iPad Pro 11 inch M5 12GB", name: "iPad Pro 11-inch (M5)"))
        #expect(!DeviceTools.isRedundant(model: "iPhone 14 Plus", name: "Test iPhone"))
    }
}

struct ImageEncoderTests {
    /// A solid 1206×2622 PNG, the size of an iPhone 16 Pro screenshot.
    private func screenshotPNG() throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 1206, height: 2622, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1206, height: 2622))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func downscalesToMaxDimensionAsJPEG() throws {
        let image = try ImageEncoder.encode(try screenshotPNG(), format: .jpeg, quality: 80, maxDimension: 1024)
        #expect((image.width, image.height) == (471, 1024))
        #expect((image.sourceWidth, image.sourceHeight) == (1206, 2622))
        #expect(image.data.starts(with: [0xFF, 0xD8]))
    }

    @Test func keepsFullResolutionWithZeroMaxDimension() throws {
        let image = try ImageEncoder.encode(try screenshotPNG(), format: .png, quality: 80, maxDimension: 0)
        #expect((image.width, image.height) == (1206, 2622))
        #expect(image.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func describesPointsAndConversionFactor() throws {
        let image = EncodedImage(data: Data(), format: .jpeg, width: 471, height: 1024, sourceWidth: 1206, sourceHeight: 2622)
        #expect(ScreenTools.describe(image, scale: 3)
            == "402×874 pt (scale 3, 1206×2622 px); image 471×1024 px JPEG, 1 image px = 0.854 pt")
        #expect(ScreenTools.describe(image, scale: nil) == "1206×2622 px (point scale unknown); image 471×1024 px JPEG")
    }

    @Test func rejectsGarbage() {
        #expect(throws: ISimError.self) { try ImageEncoder.encode(Data("nope".utf8), format: .jpeg, quality: 80, maxDimension: 0) }
    }
}

struct SystemToolTests {
    @Test func pushPayloadIsValidatedBeforeSimctlSeesIt() throws {
        let object = try SystemTools.pushPayload(ToolArguments(["payload": ["aps": ["alert": "Hi", "badge": 1]]]))
        #expect(String(decoding: object, as: UTF8.self) == #"{"aps":{"alert":"Hi","badge":1}}"#)
        let string = try SystemTools.pushPayload(ToolArguments(["payload": #"{"aps":{"alert":"Hi"}}"#]))
        #expect(string.count == 22)

        #expect(throws: ISimError.invalidArgument("Pass `payload` or `payload_path`.")) { try SystemTools.pushPayload(ToolArguments([:])) }
        #expect(throws: ISimError.self) { try SystemTools.pushPayload(ToolArguments(["payload": ["alert": "no aps"]])) }
        #expect(throws: ISimError.self) { try SystemTools.pushPayload(ToolArguments(["payload": "not json"])) }
        #expect(throws: ISimError.self) {
            try SystemTools.pushPayload(ToolArguments(["payload": ["aps": ["alert": .string(String(repeating: "x", count: 5000))]]]))
        }
        #expect(throws: ISimError.self) {
            try SystemTools.pushPayload(ToolArguments(["payload": ["aps": [:]], "payload_path": "/tmp/p.json"]))
        }
    }

    @Test func waypointsNeedNumbersInRange() throws {
        let points = try SystemTools.coordinates(.array([["latitude": 55.75, "longitude": 37], ["latitude": "-33.9", "longitude": 18.4]]))
        #expect(points == [Coordinate(latitude: 55.75, longitude: 37), Coordinate(latitude: -33.9, longitude: 18.4)])
        #expect(throws: ISimError.self) { try SystemTools.coordinates(.array([["latitude": 1]])) }
        #expect(throws: ISimError.self) { try SystemTools.coordinates(.array([["latitude": 91, "longitude": 0]])) }
        #expect(try SystemTools.coordinates(nil).isEmpty)
    }

    @Test func describesStatusBar() {
        #expect(SystemTools.describe(StatusBarOverride(
            time: "9:41", dataNetwork: "LTE", wifiMode: "active", wifiBars: 3, cellularMode: "notSupported",
            batteryState: "charged", batteryLevel: 100))
            == "time 9:41, battery 100% charged, Wi-Fi 3 bars, cellular hidden, network LTE")
        #expect(SystemTools.describe(StatusBarOverride()) == "no overrides")
    }
}

struct CreateDeviceTests {
    private let runtimes: [SimRuntime] = {
        let json = """
            [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1", "name": "iOS 27.1", "version": "27.1", "isAvailable": true,
              "supportedDeviceTypes": [{"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo", "name": "iPhone Duo"}]},
             {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "name": "iOS 27.0", "version": "27.0", "isAvailable": true,
              "supportedDeviceTypes": [
                {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16e", "name": "iPhone 16e", "productFamily": "iPhone"},
                {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M4", "name": "iPad Air 11-inch (M4)", "productFamily": "iPad"}]}]
            """
        return try! JSONDecoder().decode([SimRuntime].self, from: Data(json.utf8))
    }()

    @Test func takesTheNewestRuntimeThatSupportsTheType() throws {
        let (runtime, type) = try DeviceTools.resolveDeviceType("iphone 16E", runtime: nil, in: runtimes)
        #expect(runtime.name == "iOS 27.0")
        #expect(type.identifier == "com.apple.CoreSimulator.SimDeviceType.iPhone-16e")
    }

    @Test func acceptsRuntimeSpellings() throws {
        for spelling in ["iOS 27.1", "ios27.1", "27.1", "com.apple.CoreSimulator.SimRuntime.iOS-27-1"] {
            #expect(try DeviceTools.resolveDeviceType("iPhone Duo", runtime: spelling, in: runtimes).0.version == "27.1", "\(spelling)")
        }
    }

    @Test func errorsListWhatIsAvailable() {
        #expect(throws: ISimError.invalidArgument("Unknown device type \"iPhone 16e\" for iOS 27.1. Available: iPhone Duo.")) {
            try DeviceTools.resolveDeviceType("iPhone 16e", runtime: "27.1", in: runtimes)
        }
        #expect(throws: ISimError.invalidArgument("Unknown device type \"iPhone 99\". Available: iPhone Duo, iPhone 16e, iPad Air 11-inch (M4).")) {
            try DeviceTools.resolveDeviceType("iPhone 99", runtime: nil, in: runtimes)
        }
        #expect(throws: ISimError.invalidArgument("No available runtime matches \"iOS 13\". Installed: iOS 27.1, iOS 27.0.")) {
            try DeviceTools.resolveDeviceType("iPhone 16e", runtime: "iOS 13", in: runtimes)
        }
    }

    @Test func groupsIdenticalDeviceTypeLists() {
        let lines = DeviceTools.describeDeviceTypes(runtimes)
        #expect(lines == [
            "", "Device types for iOS 27.1:", "  Other: iPhone Duo",
            "", "Device types for iOS 27.0:", "  iPhone: iPhone 16e", "  iPad: iPad Air 11-inch (M4)",
        ])
    }
}
