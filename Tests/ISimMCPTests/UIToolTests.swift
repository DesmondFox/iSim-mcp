import CoreGraphics
import DeviceCore
import Foundation
@testable import ISimMCP
import MCP
import TestSupport
import Testing

/// SimBridge stand-in: serves screens in order, moving to the next after every tap (and every key press with
/// `advancingOnKeys`), and records input.
final class FakeUI: InputInjecting, AccessibilityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var screens: [UIElement]
    private let advancingOnKeys: Bool
    private(set) var taps: [CGPoint] = []
    private(set) var holds: [Duration] = []
    private(set) var swipes: [(CGPoint, CGPoint)] = []
    private(set) var strokes: [KeyStroke] = []
    private(set) var buttons: [HardwareButton] = []

    init(_ screens: UIElement..., advancingOnKeys: Bool = false) {
        self.screens = screens
        self.advancingOnKeys = advancingOnKeys
    }

    func tap(udid: String, at point: CGPoint, count: Int, hold: Duration) async throws {
        lock.withLock {
            taps.append(point)
            holds.append(hold)
            if screens.count > 1 { screens.removeFirst() }
        }
    }

    func swipe(udid: String, from start: CGPoint, to end: CGPoint, duration: Duration) async throws {
        lock.withLock { swipes.append((start, end)) }
    }

    func pressKeys(udid: String, _ strokes: [KeyStroke]) async throws {
        lock.withLock {
            self.strokes += strokes
            if advancingOnKeys && screens.count > 1 { screens.removeFirst() }
        }
    }

    func pressButton(udid: String, _ button: HardwareButton, hold: Duration) async throws {
        lock.withLock { buttons.append(button) }
    }

    func uiTree(udid: String, maxDepth: Int?) async throws -> UIElement {
        lock.withLock { screens[0] }
    }

    func element(udid: String, at point: CGPoint) async throws -> UIElement? {
        lock.withLock { screens[0].flattened.dropFirst().last { $0.frame.contains(point) } }
    }
}

private func app(_ label: String?, pid: Int = 42, _ children: UIElement...) -> UIElement {
    UIElement(role: "application", label: label, frame: CGRect(x: 0, y: 0, width: 402, height: 874), pid: pid, children: children)
}

private func node(_ role: String, _ label: String? = nil, value: String? = nil, id: String? = nil, _ frame: CGRect, focused: Bool = false) -> UIElement {
    UIElement(role: role, label: label, value: value, identifier: id, frame: frame, isFocused: focused)
}

private let loginScreen = app("iSim Test",
    node("text_field", value: "Username", id: "username", CGRect(x: 24, y: 412, width: 354, height: 34)),
    node("button", "Log In", id: "loginButton", CGRect(x: 166, y: 512, width: 70, height: 34)),
    node("button", "Item 1", id: "item-1", CGRect(x: 16, y: 422, width: 370, height: 52)),
    node("button", "Item 2", id: "item-2", CGRect(x: 16, y: 474, width: 370, height: 52)),
    node("switch", "Favorite", value: "0", id: "favorite", CGRect(x: 16, y: 220, width: 370, height: 52)),
    node("button", "Item 40", id: "item-40", CGRect(x: 16, y: 900, width: 370, height: 52)))

/// A Flutter sign-up step: the field's label is its hint, gone once it has a value, and nothing reports focus.
private let emailFrame = CGRect(x: 16, y: 226, width: 370, height: 56)

private func flutterForm(email: String?, _ more: UIElement...) -> UIElement {
    app("BZZR", [
        node("text_field", email == nil ? "Email" : nil, value: email, emailFrame),
        node("text_field", "Password", CGRect(x: 42, y: 312, width: 285, height: 28)),
    ] + more)
}

private func app(_ label: String?, _ children: [UIElement]) -> UIElement {
    UIElement(role: "application", label: label, frame: CGRect(x: 0, y: 0, width: 402, height: 874), pid: 42, children: children)
}

private let notificationAlert = app(nil, pid: 7,
    node("text", "“iSim Test” Would Like to Send You Notifications", CGRect(x: 71, y: 366, width: 260, height: 42)),
    node("button", "Don’t Allow", CGRect(x: 57, y: 494, width: 140, height: 48)),
    node("button", "Allow", CGRect(x: 205, y: 494, width: 140, height: 48)))

struct UIToolTests {
    let runner = ScriptedRunner()

    init() {
        runner.on("simctl list devices", stdout: """
            {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
              {"udid": "SIM-1", "name": "iPhone 16 Pro", "state": "Booted", "isAvailable": true,
               "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"}
            ]}}
            """)
        runner.on("list devices", stdout: """
            {"info": {"outcome": "success"}, "result": {"devices": [
              {"hardwareProperties": {"reality": "physical", "platform": "iOS", "udid": "PHONE-1", "marketingName": "iPhone 14 Plus"},
               "deviceProperties": {"name": "Test iPhone", "osVersionNumber": "27.0.1", "developerModeStatus": "enabled"},
               "connectionProperties": {"transportType": "wired", "tunnelState": "connected"}}
            ]}}
            """)
        runner.on("defaults read com.apple.Accessibility ApplicationAccessibilityEnabled", stdout: "1\n")
    }

    private func call(_ name: String, _ arguments: [String: Value], ui: FakeUI) async throws -> CallTool.Result {
        let context = ToolContext(
            runner: runner, xcode: .success(XcodeEnvironment(developerDir: "/Xcode.app/Contents/Developer", version: "27.1", build: nil)),
            uiBackend: ui)
        return try await ISimServer.makeRegistry(toolsets: Set(Toolset.allCases))
            .call(name, arguments: arguments.merging(["device": "SIM-1"]) { current, _ in current }, context: context)
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined(separator: "\n")
    }

    @Test func describeUIListsElementsOnScreen() async throws {
        let result = try await call("describe_ui", [:], ui: FakeUI(loginScreen))
        #expect(text(result) == """
            "iSim Test" (pid 42), 402×874 pt, 5 element(s):
            [text_field] value="Username" id=username (24,412 354×34)
            [button] "Log In" id=loginButton (166,512 70×34)
            [button] "Item 1" id=item-1 (16,422 370×52)
            [button] "Item 2" id=item-2 (16,474 370×52)
            [switch] "Favorite" off id=favorite (16,220 370×52)
            1 more element(s) off screen; swipe to bring them in.
            """)
    }

    @Test func describeUIPointsAtSystemAlerts() async throws {
        let result = try await call("describe_ui", [:], ui: FakeUI(notificationAlert))
        #expect(text(result).hasPrefix("SpringBoard: home screen or system UI (pid 7), 402×874 pt, 3 element(s):\nA system alert is shown"))
    }

    @Test func tapsTheCenterOfTheMatchingElement() async throws {
        let ui = FakeUI(loginScreen)
        let result = try await call("tap", ["element": ["identifier": "loginButton"]], ui: ui)
        #expect(text(result) == "Tapped [button] \"Log In\" id=loginButton (166,512 70×34) at (201,529).")
        #expect(ui.taps == [CGPoint(x: 201, y: 529)])
    }

    @Test func tapsASwitchAtItsControl() async throws {
        let ui = FakeUI(loginScreen)
        _ = try await call("tap", ["element": ["label": "favorite"]], ui: ui)
        #expect(ui.taps == [CGPoint(x: 386 - UITools.switchInset, y: 246)])
    }

    @Test func ambiguousSelectorListsTheMatches() async throws {
        let ui = FakeUI(loginScreen)
        let result = try await call("tap", ["element": ["label_contains": "item"]], ui: ui)
        #expect(result.isError == true)
        #expect(text(result).hasPrefix("3 elements match label containing \"item\"; add `index` or a narrower field:\n  0: [button] \"Item 1\""))
        let indexed = try await call("tap", ["element": ["label_contains": "item", "index": 1]], ui: ui)
        #expect(text(indexed).hasPrefix("Tapped [button] \"Item 2\""))
    }

    @Test func missingElementSuggestsSimilarOnes() async throws {
        let result = try await call("tap", ["element": ["label": "Username"]], ui: FakeUI(loginScreen))
        #expect(result.isError == true)
        #expect(text(result) == """
            No element matches label "Username". Similar elements:
              [text_field] value="Username" id=username (24,412 354×34)
            """)
    }

    @Test func offscreenElementsAreNotTapped() async throws {
        let ui = FakeUI(loginScreen)
        let result = try await call("tap", ["element": ["identifier": "item-40"]], ui: ui)
        #expect(text(result).hasSuffix("is off screen; swipe to bring it in first."))
        #expect(ui.taps.isEmpty)
    }

    @Test func iPhonesAreRefusedBeforeAnythingRuns() async throws {
        let ui = FakeUI(loginScreen)
        let result = try await call("tap", ["device": "PHONE-1", "x": 10, "y": 10], ui: ui)
        #expect(text(result).hasPrefix("tap is not available on physical devices."))
        #expect(ui.taps.isEmpty)
    }

    @Test func typesASCIIWithTheKeyboardAndReportsTheField() async throws {
        let typed = app("iSim Test", node("text_field", value: "ab", id: "username", CGRect(x: 24, y: 412, width: 354, height: 34), focused: true))
        let ui = FakeUI(loginScreen, typed)
        let result = try await call("type_text", ["text": "aB", "element": ["identifier": "username"], "clear": true, "submit": false], ui: ui)
        #expect(ui.taps == [CGPoint(x: 201, y: 429)])
        #expect(ui.strokes == [
            KeyStroke(usage: 0x04, modifiers: [.command]), KeyStroke(usage: 0x2A),
            KeyStroke(usage: 0x04), KeyStroke(usage: 0x05, modifiers: [.shift]),
        ])
        #expect(text(result).hasSuffix("\nFocused: [text_field] value=\"ab\" id=username (24,412 354×34) focused"))
    }

    @Test func pastesTextTheKeyboardCannotType() async throws {
        runner.on("device pasteboard copy", stdout: #"{"info":{"outcome":"success"},"result":{}}"#)
        let pasted = app("iSim Test", node("text_field", value: "Привет", id: "username", CGRect(x: 24, y: 412, width: 354, height: 34), focused: true))
        let ui = FakeUI(loginScreen, pasted, advancingOnKeys: true)
        let result = try await call("type_text", ["text": "Привет", "submit": true], ui: ui)
        #expect(runner.calls.contains { $0.commandLine.contains("device pasteboard copy --device SIM-1") })
        #expect(ui.strokes == [KeyStroke(usage: 0x19, modifiers: [.command]), KeyStroke(usage: 0x28)])
        #expect(ui.taps.isEmpty)
        #expect(text(result).hasPrefix("Typed 6 character(s) with paste and pressed Return (the text is left on the pasteboard).\nFocused:"))

        let refused = try await call("type_text", ["text": "Привет", "method": "hid"], ui: ui)
        #expect(text(refused) == "\"П\" has no key on a US keyboard; use method=paste (or auto).")
    }

    @Test func pastesFromTheEditMenuWhenCommandVChangesNothing() async throws {
        runner.on("device pasteboard copy", stdout: #"{"info":{"outcome":"success"},"result":{}}"#)
        let menu = flutterForm(email: nil,
            node("text", "Paste", CGRect(x: 166, y: 283, width: 70, height: 44)),
            node("text", "Select All", CGRect(x: 237, y: 283, width: 96, height: 44)))
        // Field lookup, tap on the field, long press, tap on Paste. Cmd+V changes nothing, as in Flutter.
        let ui = FakeUI(flutterForm(email: nil), flutterForm(email: nil), menu, flutterForm(email: "Привет"))
        let result = try await call("type_text", ["text": "Привет", "element": ["label": "Email"]], ui: ui)
        #expect(ui.strokes == [KeyStroke(usage: 0x19, modifiers: [.command])])
        #expect(ui.taps == [CGPoint(x: 201, y: 254), CGPoint(x: 201, y: 254), CGPoint(x: 201, y: 305)])
        #expect(ui.holds == [.milliseconds(60), .milliseconds(800), .milliseconds(60)])
        #expect(text(result).contains("Cmd+V left the field unchanged, so pasted from the edit menu"))
        #expect(text(result).hasSuffix("\nField: [text_field] value=\"Привет\" (16,226 370×56)"))
    }

    @Test func retriesAClearThatLostTheRaceWithSelectAll() async throws {
        // Every tap and key press shows the next screen: the first Delete lands before select-all and takes one character.
        let ui = FakeUI(
            flutterForm(email: "abc"), flutterForm(email: "abc"),
            flutterForm(email: "abc"), flutterForm(email: "ab"),
            flutterForm(email: "ab"), flutterForm(email: nil),
            flutterForm(email: "xy"),
            advancingOnKeys: true)
        let result = try await call("type_text", ["text": "xy", "element": ["role": "text_field", "index": 0], "clear": true], ui: ui)
        let selectAll = KeyStroke(usage: 0x04, modifiers: [.command]), delete = KeyStroke(usage: 0x2A)
        #expect(ui.strokes == [selectAll, delete, selectAll, delete, KeyStroke(usage: 0x1B), KeyStroke(usage: 0x1C)])
        #expect(text(result).hasSuffix("\nField: [text_field] value=\"xy\" (16,226 370×56)"))
    }

    @Test func reportsTheFieldThatChangedWhenNothingHasFocus() async throws {
        let ui = FakeUI(flutterForm(email: nil), flutterForm(email: nil), flutterForm(email: "ab"), advancingOnKeys: true)
        let typed = try await call("type_text", ["text": "ab", "element": ["label": "Email"]], ui: ui)
        #expect(text(typed).hasSuffix("\nField: [text_field] value=\"ab\" (16,226 370×56)"))

        let lost = try await call("type_text", ["text": "ab"], ui: FakeUI(flutterForm(email: nil)))
        #expect(text(lost).hasSuffix("\nNo field changed and none reports keyboard focus, so the text may have gone nowhere: "
            + "pass `element` or tap a field first."))
    }

    @Test func picksTheOnlyInteractiveElementAmongMatchesWithOneFrame() async throws {
        let email = CGRect(x: 16, y: 432, width: 370, height: 56)
        let screen = app("BZZR", [
            node("button", "Continue with Email", email),
            node("image", "Continue with Email", email.offsetBy(dx: 0, dy: 0.4)),
            node("text", "Sign in", CGRect(x: 101, y: 266, width: 200, height: 32)),
            node("button", "Sign in", CGRect(x: 261, y: 768, width: 74, height: 32)),
        ])
        let ui = FakeUI(screen)
        let tapped = try await call("tap", ["element": ["label": "Continue with Email"]], ui: ui)
        #expect(text(tapped) == "Tapped [button] \"Continue with Email\" (16,432 370×56) at (201,460).")
        // Different frames: the title and the button are different things.
        let ambiguous = try await call("tap", ["element": ["label": "Sign in"]], ui: ui)
        #expect(text(ambiguous).hasPrefix("2 elements match label \"Sign in\""))
    }

    @Test func swipesAcrossTheScreenInTheFingersDirection() async throws {
        let ui = FakeUI(loginScreen)
        let result = try await call("swipe", ["direction": "up"], ui: ui)
        #expect(text(result) == "Swiped from (201,656) to (201,219).")
        #expect(ui.swipes.first?.0 == CGPoint(x: 201, y: 655.5))
    }

    @Test func pressesKeysWithModifiers() async throws {
        let ui = FakeUI(loginScreen)
        let result = try await call("press_key", ["key": "a", "modifiers": ["command"], "repeat": 2], ui: ui)
        #expect(text(result) == "Pressed command+a 2 times.")
        #expect(ui.strokes == Array(repeating: KeyStroke(usage: 0x04, modifiers: [.command]), count: 2))
    }

    @Test func waitsForAnElementToAppear() async throws {
        let ui = FakeUI(loginScreen)
        let found = try await call("wait_for", ["condition": "exists", "element": ["identifier": "item-2"]], ui: ui)
        #expect(text(found) == "Found after 0.0 s: [button] \"Item 2\" id=item-2 (16,474 370×52)")
        let missing = try await call("wait_for", ["condition": "exists", "element": ["identifier": "nope"], "timeout_ms": 300], ui: ui)
        #expect(missing.isError == true)
        #expect(text(missing).hasPrefix("Timed out after 0.3 s: nothing matches identifier \"nope\".\nScreen now: \"iSim Test\""))
    }

    @Test func acceptsASystemAlertAndConfirmsItClosed() async throws {
        let ui = FakeUI(notificationAlert, loginScreen)
        let result = try await call("handle_system_alert", ["action": "accept"], ui: ui)
        #expect(text(result) == "Tapped \"Allow\" in the alert: “iSim Test” Would Like to Send You Notifications")
        #expect(ui.taps == [CGPoint(x: 275, y: 518)])
    }

    @Test func readingWithoutAnAlertIsNotAnError() async throws {
        let result = try await call("handle_system_alert", ["action": "read", "timeout_ms": 0], ui: FakeUI(loginScreen))
        #expect(result.isError == nil)
        #expect(text(result) == "No system alert is shown on \"iPhone 16 Pro\".")
    }
}

struct SystemAlertTests {
    @Test func homeScreenIconsAreNotAnAlert() {
        let home = app(nil, node("button", "Safari", id: "Safari", CGRect(x: 123, y: 771, width: 68, height: 68)))
        #expect(SystemAlert.find(in: home) == nil)
        #expect(SystemAlert.find(in: loginScreen) == nil)
    }

    @Test func picksButtonsByLabelThenByPosition() throws {
        let location = app(nil,
            node("text", "Allow “iSim Test” to use your location?", CGRect(x: 71, y: 320, width: 260, height: 42)),
            node("button", "Allow Once", CGRect(x: 57, y: 428, width: 288, height: 48)),
            node("button", "Allow While Using App", CGRect(x: 57, y: 484, width: 288, height: 48)),
            node("button", "Don’t Allow", CGRect(x: 57, y: 540, width: 288, height: 48)))
        let alert = try #require(SystemAlert.find(in: location))
        #expect(alert.button(accepting: true)?.label == "Allow While Using App")
        #expect(alert.button(accepting: false)?.label == "Don’t Allow")

        let unknown = try #require(SystemAlert.find(in: app(nil,
            node("button", "Annuler", CGRect(x: 57, y: 494, width: 140, height: 48)),
            node("button", "Autoriser", CGRect(x: 205, y: 494, width: 140, height: 48)))))
        #expect(unknown.button(accepting: true)?.label == "Autoriser")
        #expect(unknown.button(accepting: false)?.label == "Annuler")
    }
}

struct TextFieldsTests {
    @Test func findsAFieldByFrameAfterItsLabelIsGone() throws {
        let field = try #require(TextFields.target(in: flutterForm(email: nil), tappedAt: CGPoint(x: 201, y: 254)))
        #expect(field.label == "Email")
        #expect(TextFields.field(at: field.center, in: flutterForm(email: "ab"))?.value == "ab")
        #expect(TextFields.changed(from: flutterForm(email: nil), to: flutterForm(email: "ab"))?.value == "ab")
        #expect(TextFields.changed(from: flutterForm(email: "ab"), to: flutterForm(email: "ab")) == nil)
    }

    @Test func withoutATapOrFocusOnlyALoneFieldIsTheTarget() {
        #expect(TextFields.target(in: flutterForm(email: nil), tappedAt: nil) == nil)
        #expect(TextFields.target(in: loginScreen, tappedAt: nil)?.identifier == "username")
    }

    @Test func aClearThatTookOneCharacterMissedTheSelection() {
        #expect(TextFields.clearMissed(before: "abc", after: "ab"))
        #expect(TextFields.clearMissed(before: "••••••••", after: "•••••••"))
        #expect(!TextFields.clearMissed(before: "abc", after: nil))
        // A native field shows its placeholder as the value once it is empty.
        #expect(!TextFields.clearMissed(before: "isim.test@example.com", after: "Username"))
        #expect(!TextFields.clearMissed(before: "a", after: ""))
    }
}

struct UIArgumentTests {
    @Test func selectorsRejectUnknownFieldsAndNeedAnAttribute() {
        #expect(throws: ISimError.invalidArgument("`element.text` is not a selector field. Use: identifier, label, label_contains, value, role, index.")) {
            try ToolArguments(["element": ["text": "x"]]).selector("element")
        }
        #expect(throws: ISimError.invalidArgument("`element` must name at least one of identifier, label, label_contains, value or role.")) {
            try ToolArguments(["element": ["index": 1]]).selector("element")
        }
    }

    @Test func pointsNeedBothCoordinates() throws {
        #expect(try ToolArguments(["from": ["x": 1, "y": 2.5]]).point("from") == CGPoint(x: 1, y: 2.5))
        #expect(throws: ISimError.self) { try ToolArguments(["from": ["x": 1]]).point("from") }
    }
}
