import CoreGraphics
import DeviceCore
import Foundation
@testable import ISimMCP
import MCP
import TestSupport
import Testing

private func screen(_ children: UIElement...) -> UIElement {
    UIElement(role: "application", label: "iSim Test", frame: CGRect(x: 0, y: 0, width: 402, height: 874), pid: 42, children: children)
}

private func row(_ id: Int, y: CGFloat) -> UIElement {
    UIElement(role: "button", label: "Item \(id)", identifier: "item-\(id)", frame: CGRect(x: 16, y: y, width: 370, height: 52))
}

struct GestureToolTests {
    let runner = ScriptedRunner()

    init() {
        runner.on("simctl list devices", stdout: """
            {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
              {"udid": "SIM-1", "name": "iPhone 16 Pro", "state": "Booted", "isAvailable": true,
               "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"}
            ]}}
            """)
        runner.on("list devices", stdout: #"{"info": {"outcome": "success"}, "result": {"devices": []}}"#)
        runner.on("defaults read com.apple.Accessibility ApplicationAccessibilityEnabled", stdout: "1\n")
    }

    private func call(_ name: String, _ arguments: [String: Value], ui: FakeUI) async throws -> CallTool.Result {
        let context = ToolContext(
            runner: runner, xcode: .success(XcodeEnvironment(developerDir: "/Xcode.app/Contents/Developer", version: "27.1", build: nil)),
            uiBackend: ui, agentPaths: nil)
        return try await ISimServer.makeRegistry(toolsets: Set(Toolset.allCases))
            .call(name, arguments: arguments.merging(["device": "SIM-1"]) { current, _ in current }, context: context)
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined(separator: "\n")
    }

    @Test func touchPathMovesAFrameAtATime() async throws {
        let ui = FakeUI(screen())
        let result = try await call("touch_path", ["points": [["x": 100, "y": 300], ["x": 100, "y": 300, "dt_ms": 800], ["x": 300, "y": 300, "dt_ms": 160]]], ui: ui)
        #expect(text(result) == "Moved a finger through 3 points in 0.96 s, from (100,300) to (300,300).")
        let samples = try #require(ui.paths.first)
        #expect(samples.first == TouchSample(CGPoint(x: 100, y: 300), at: .zero))
        #expect(samples.last == TouchSample(CGPoint(x: 300, y: 300), at: .milliseconds(960)))
        // The finger holds still for 800 ms, then moves in 10 frames.
        #expect(samples.filter { $0.point == CGPoint(x: 100, y: 300) }.count == 51)
        #expect(samples.count == 61)
    }

    @Test func touchPathNeedsTwoPoints() async throws {
        let result = try await call("touch_path", ["points": [["x": 1, "y": 2]]], ui: FakeUI(screen()))
        #expect(result.isError == true)
    }

    @Test func pinchOutSpreadsTheFingersAroundTheElement() async throws {
        let ui = FakeUI(screen(UIElement(role: "image", label: "Map", identifier: "map", frame: CGRect(x: 0, y: 200, width: 402, height: 400))))
        let result = try await call("multi_touch", ["preset": "pinch_out", "element": ["identifier": "map"]], ui: ui)
        #expect(text(result).hasPrefix("Pinched out ×2 (fingers 150 → 300 pt apart) around (201,400) over [image] \"Map\""))
        let samples = try #require(ui.twoFingerPaths.first)
        #expect(samples.first == TwoFingerSample(CGPoint(x: 126, y: 400), CGPoint(x: 276, y: 400), at: .zero))
        #expect(samples.last == TwoFingerSample(CGPoint(x: 51, y: 400), CGPoint(x: 351, y: 400), at: .milliseconds(600)))
    }

    @Test func rotateTurnsClockwise() throws {
        let samples = GestureTools.rotation(center: CGPoint(x: 200, y: 400), radius: 100, degrees: 90, duration: .milliseconds(320))
        #expect(samples.count == 21)
        #expect(samples.first?.second == CGPoint(x: 300, y: 400))
        let last = try #require(samples.last)
        // A quarter turn clockwise brings the right finger to the bottom.
        #expect(abs(last.second.x - 200) < 0.001 && abs(last.second.y - 500) < 0.001)
    }

    @Test func pinchFitsTheRoomItHas() {
        #expect(GestureTools.pinchRadii(scale: 2, radius: nil, room: 60) == (30, 60))
        #expect(GestureTools.pinchRadii(scale: 0.5, radius: nil, room: 200) == (150, 75))
        #expect(GestureTools.pinchRadii(scale: 3, radius: 100, room: 150) == (50, 150))
    }

    @Test func customTwoFingerPathsAreInterpolated() async throws {
        let ui = FakeUI(screen())
        _ = try await call("multi_touch", ["points": [
            ["x1": 100, "y1": 400, "x2": 300, "y2": 400], ["x1": 150, "y1": 400, "x2": 250, "y2": 400, "dt_ms": 32],
        ]], ui: ui)
        #expect(ui.twoFingerPaths.first?.count == 3)
        #expect(ui.twoFingerPaths.first?[1] == TwoFingerSample(CGPoint(x: 125, y: 400), CGPoint(x: 275, y: 400), at: .milliseconds(16)))
    }

    @Test func scrollsUntilTheRowIsOnScreen() async throws {
        let ui = FakeUI(screen(row(1, y: 100), row(30, y: 1400)), screen(row(20, y: 100), row(30, y: 900)), screen(row(30, y: 500)),
                        advancingOnSwipes: true)
        let result = try await call("scroll_until_visible", ["element": ["identifier": "item-30"]], ui: ui)
        #expect(text(result) == "Found after 2 swipe(s): [button] \"Item 30\" id=item-30 (16,500 370×52) center (201,526)")
        // Up through the middle of the screen, half its height.
        #expect(ui.swipes.first! == (CGPoint(x: 201, y: 655.5), CGPoint(x: 201, y: 218.5)))
    }

    @Test func scrollingStopsAtTheEnd() async throws {
        let ui = FakeUI(screen(row(1, y: 100)), advancingOnSwipes: true)
        let result = try await call("scroll_until_visible", ["element": ["identifier": "item-99"], "max_swipes": 5], ui: ui)
        #expect(result.isError == true)
        #expect(text(result).hasPrefix("No element matches identifier \"item-99\": the screen stopped changing after 1 swipe(s)"))
        #expect(ui.swipes.count == 1)
    }

    @Test func memoryWarningOnASimulatorGoesToEveryApp() async throws {
        let ui = FakeUI(screen())
        let result = try await call("send_memory_warning", ["bundle_id": "dev.x"], ui: ui)
        #expect(text(result) == "Sent a memory warning to every app on \"iPhone 16 Pro\".")
        #expect(ui.memoryWarnings == 1)
    }
}
