import CoreGraphics
import DeviceCore
import Foundation
import ImageIO
@testable import ISimMCP
import MCP
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

    @Test func defaultToolsetsExposeAllPhaseOneTools() {
        let names = Set(ISimServer.makeRegistry(toolsets: Toolset.defaults).tools.map(\.name))
        #expect(names == [
            "doctor", "set_active_device", "list_devices", "boot_device", "shutdown_device", "list_apps", "install_app",
            "uninstall_app", "launch_app", "terminate_app", "open_url", "screenshot",
        ])
    }

    @Test func everyDeviceToolHasTheDeviceParameterAndAnnotations() throws {
        let deviceIndependent: Set = ["doctor", "list_devices"]
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
