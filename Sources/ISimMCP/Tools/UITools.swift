import CoreGraphics
import DeviceCore
import Foundation
import MCP
import SimBridgeBackend

/// Input and UI inspection. Simulators go through SimBridge, iPhones through the on-device UI agent.
enum UITools {
    static let all: [ToolDefinition] = [
        describeUI, findElements, describePoint, tap, swipe, typeText, pressKey, pressButton, waitFor, handleSystemAlert, setOrientation,
    ]

    static let elementDescription = """
        Element to act on, matched against the accessibility tree that describe_ui shows; waits up to 3 s for it to appear. \
        Prefer `identifier`; `label` must equal the whole label.
        """

    // MARK: Inspection

    static let describeUI = ToolDefinition(
        name: "describe_ui",
        toolset: .ui,
        description: """
            The UI of the frontmost app from its accessibility tree, one line per element: role, label, value, identifier and \
            frame in points, e.g. `[button] "Log In" id=loginButton (166,512 70×34)`. Cheaper and more exact than a screenshot \
            for reading text and finding what to tap; use its labels and identifiers in `element` selectors. \
            A system alert appears as SpringBoard's UI. format=json returns the whole tree with containers.
            """,
        inputSchema: Schema.deviceObject([
            "format": Schema.string("compact: a line per element on screen; json: the full nested tree.", enum: ["compact", "json"]),
            "interactive_only": Schema.bool("Only elements that can be tapped, typed into or adjusted.", default: false),
            "max_depth": Schema.integer("How many levels below the app to read; default all.", minimum: 0),
        ]),
        annotations: .readOnly
    ) { arguments, context in
        try context.requireXcode()
        let json = try arguments.choice("format", from: ["compact", "json"]) == "json"
        let interactiveOnly = try arguments.bool("interactive_only", default: false)
        let maxDepth = try arguments.int("max_depth")
        if let maxDepth, maxDepth < 0 { throw ISimError.invalidArgument("`max_depth` must be 0 or more.") }
        let device = try await context.session.resolveReady(try arguments.device)
        let root = try await context.screen(device, for: .describeUI, maxDepth: maxDepth)

        if json { return .text(UIElementFormatter.json(root)) }
        let listing = UIElementFormatter.compact(root, interactiveOnly: interactiveOnly, screen: root.frame)
        var lines = [UIQuery.title(of: root) + ", \(listing.lines.count) element(s):"] + listing.lines
        if SystemAlert.find(in: root) != nil {
            lines.insert("A system alert is shown: use handle_system_alert to answer it.", at: 1)
        }
        if listing.offscreen > 0 { lines.append("\(listing.offscreen) more element(s) off screen; swipe to bring them in.") }
        if root.flattened.contains(where: \.isTruncated) && maxDepth == nil {
            lines.append("The tree was cut at \(SimBridgeBackend.maxElements) elements.")
        }
        return .text(lines.joined(separator: "\n"))
    }

    static let findElements = ToolDefinition(
        name: "find_elements",
        toolset: .ui,
        description: "Find elements of the frontmost app by selector. Returns each match with its frame and center point in points.",
        inputSchema: Schema.deviceObject([
            "element": Schema.selector("What to look for."),
            "limit": Schema.integer("At most this many matches.", default: 20, minimum: 1, maximum: 200),
        ], required: ["element"]),
        annotations: .readOnly
    ) { arguments, context in
        try context.requireXcode()
        guard let selector = try arguments.selector("element") else { throw ISimError.invalidArgument("`element` is required.") }
        let limit = try arguments.int("limit", default: 20, range: 1...200)
        let device = try await context.session.resolveReady(try arguments.device)
        let root = try await context.screen(device, for: .findElements)
        var matches = root.descendants(matching: selector)
        if let index = selector.index { matches = index < matches.count ? [matches[index]] : [] }
        guard !matches.isEmpty else {
            return .text("No element matches \(selector)." + UIQuery.similar(to: selector, in: root))
        }
        var lines = ["\(matches.count) element(s) match \(selector):"]
        for (index, element) in matches.prefix(limit).enumerated() {
            var line = "\(index). " + UIElementFormatter.line(element) + " center " + UIElementFormatter.point(element.center)
            if !UIQuery.isOnScreen(element, screen: root) { line += " off screen" }
            lines.append(line)
        }
        if matches.count > limit { lines.append("… \(matches.count - limit) more") }
        return .text(lines.joined(separator: "\n"))
    }

    static let describePoint = ToolDefinition(
        name: "describe_point",
        toolset: .ui,
        description: "The element at a point (in points), e.g. to check what a tap at coordinates from a screenshot would hit.",
        inputSchema: Schema.deviceObject([
            "x": Schema.number("X in points."),
            "y": Schema.number("Y in points."),
        ], required: ["x", "y"]),
        annotations: .readOnly
    ) { arguments, context in
        try context.requireXcode()
        guard let x = try arguments.double("x"), let y = try arguments.double("y") else {
            throw ISimError.invalidArgument("`x` and `y` are required.")
        }
        let device = try await context.session.resolveReady(try arguments.device)
        let provider = try context.router.backend(.describePoint, for: device, as: (any AccessibilityProviding).self)
        await context.accessibility.prepare(device)
        let point = CGPoint(x: x, y: y)
        guard let element = try await provider.element(udid: device.udid, at: point) else {
            return .text("No element at \(UIElementFormatter.point(point)).")
        }
        return .text(UIElementFormatter.line(element))
    }

    // MARK: Touch

    static let tap = ToolDefinition(
        name: "tap",
        toolset: .ui,
        description: """
            Tap an element or a point. With `element`, taps the center of the one element that matches. \
            count=2 double-taps; duration_ms of 500 or more is a long press. Coordinates are points, as in describe_ui; \
            to tap something seen on a screenshot, convert pixels with the factor screenshot reports.
            """,
        inputSchema: Schema.deviceObject([
            "element": Schema.selector(elementDescription),
            "x": Schema.number("X in points (instead of element)."),
            "y": Schema.number("Y in points (instead of element)."),
            "count": Schema.integer("Taps in a row.", default: 1, minimum: 1, maximum: 3),
            "duration_ms": Schema.integer("How long each touch lasts.", default: 60, minimum: 10, maximum: 10_000),
        ]),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        let count = try arguments.int("count", default: 1, range: 1...3)
        let hold = Duration.milliseconds(try arguments.int("duration_ms", default: 60, range: 10...10_000))
        let device = try await context.session.resolveReady(try arguments.device)
        let input = try context.router.backend(.tap, for: device, as: (any InputInjecting).self)
        let target = try await target(arguments, device: device, context: context, capability: .tap)
        try await input.tap(udid: device.udid, at: target.point, count: count, hold: hold)
        let action = count == 2 ? "Double-tapped" : count == 3 ? "Triple-tapped" : hold >= .milliseconds(500) ? "Long-pressed" : "Tapped"
        return .text("\(action) \(target.description).")
    }

    static let swipe = ToolDefinition(
        name: "swipe",
        toolset: .ui,
        description: """
            Swipe between two points, or in a direction across the screen or an element. `direction` is where the finger moves: \
            swipe up to scroll down to later content, right to go back in a navigation stack (from the left edge). \
            Scroll views keep moving a little after the finger lifts.
            """,
        inputSchema: Schema.deviceObject([
            "from": Schema.point("Start point in points."),
            "to": Schema.point("End point in points."),
            "direction": Schema.string("Finger movement (instead of from/to).", enum: ["up", "down", "left", "right"]),
            "element": Schema.selector("With direction: swipe across this element instead of the whole screen."),
            "distance": Schema.number("With direction: share of the screen or element to cover, 0.1–1. Default 0.5.", minimum: 0.1, maximum: 1),
            "duration_ms": Schema.integer("Duration of the movement; shorter flings further.", default: 300, minimum: 50, maximum: 10_000),
        ]),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        let duration = Duration.milliseconds(try arguments.int("duration_ms", default: 300, range: 50...10_000))
        let device = try await context.session.resolveReady(try arguments.device)
        let input = try context.router.backend(.swipe, for: device, as: (any InputInjecting).self)

        let start: CGPoint, end: CGPoint, area: String
        if let from = try arguments.point("from"), let to = try arguments.point("to") {
            (start, end, area) = (from, to, "")
        } else if let direction = try arguments.choice("direction", from: ["up", "down", "left", "right"]) {
            let distance = min(max(try arguments.double("distance") ?? 0.5, 0.1), 1)
            let frame: CGRect
            if let selector = try arguments.selector("element") {
                let (element, screen) = try await context.element(selector, on: device, for: .swipe)
                frame = element.frame.intersection(screen.frame.isEmpty ? element.frame : screen.frame)
                area = " across " + UIElementFormatter.line(element)
            } else {
                frame = try await context.screen(device, for: .swipe, maxDepth: 0).frame
                area = ""
            }
            (start, end) = swipeLine(in: frame, direction: direction, distance: distance)
        } else {
            throw ISimError.invalidArgument("Pass `from` and `to`, or `direction`.")
        }
        try await input.swipe(udid: device.udid, from: start, to: end, duration: duration)
        return .text("Swiped from \(UIElementFormatter.point(start)) to \(UIElementFormatter.point(end))\(area).")
    }

    /// A line through the center of `frame` covering `distance` of it, along the finger's direction.
    static func swipeLine(in frame: CGRect, direction: String, distance: Double) -> (CGPoint, CGPoint) {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let dx = frame.width * distance / 2
        let dy = frame.height * distance / 2
        switch direction {
        case "up": return (CGPoint(x: center.x, y: center.y + dy), CGPoint(x: center.x, y: center.y - dy))
        case "down": return (CGPoint(x: center.x, y: center.y - dy), CGPoint(x: center.x, y: center.y + dy))
        case "left": return (CGPoint(x: center.x + dx, y: center.y), CGPoint(x: center.x - dx, y: center.y))
        default: return (CGPoint(x: center.x - dx, y: center.y), CGPoint(x: center.x + dx, y: center.y))
        }
    }

    /// From the trailing edge of a switch row to the middle of the switch control (51 pt wide, 16 pt row inset).
    static let switchInset: CGFloat = 32

    /// Where a tap goes: an element's center or explicit coordinates.
    struct Target {
        var point: CGPoint
        var description: String
    }

    static func target(_ arguments: ToolArguments, device: Device, context: ToolContext, capability: Capability) async throws -> Target {
        let selector = try arguments.selector("element")
        let x = try arguments.double("x")
        let y = try arguments.double("y")
        if let selector {
            guard x == nil && y == nil else { throw ISimError.invalidArgument("Pass either `element` or `x`/`y`, not both.") }
            let (element, screen) = try await context.element(selector, on: device, for: capability)
            guard UIQuery.isOnScreen(element, screen: screen) else {
                throw ISimError.invalidArgument("\(UIElementFormatter.line(element)) is off screen; swipe to bring it in first.")
            }
            // The visible part of a partly hidden element.
            let visible = screen.frame.isEmpty ? element.frame : element.frame.intersection(screen.frame)
            var point = CGPoint(x: visible.midX, y: visible.midY)
            // A switch's frame spans its whole row, but only the control at the trailing end flips it.
            if element.role == "switch" && visible.width > 100 {
                point.x = visible.maxX - switchInset
            }
            var description = UIElementFormatter.line(element) + " at " + UIElementFormatter.point(point)
            if !element.isEnabled { description += " (the element is disabled, so it may not react)" }
            return Target(point: point, description: description)
        }
        guard let x, let y else { throw ISimError.invalidArgument("Pass `element`, or both `x` and `y` in points.") }
        let point = CGPoint(x: x, y: y)
        return Target(point: point, description: "at " + UIElementFormatter.point(point))
    }

    // MARK: Keyboard and buttons

    enum TypingMethod: String, CaseIterable {
        case auto
        case hid
        case paste
    }

    static let typeText = ToolDefinition(
        name: "type_text",
        toolset: .ui,
        description: """
            Type text into the focused field, or into `element` after tapping it. hid presses keys of a US keyboard \
            (Latin letters, digits, punctuation) on a simulator, while an iPhone's UI agent types any language this way; \
            paste puts the text on the pasteboard and presses Cmd+V, and pastes from the edit menu (long press, Paste) \
            when Cmd+V leaves the field unchanged, as in Flutter apps; auto picks hid when it can. \
            clear=true selects all and deletes first; submit=true presses Return.
            """,
        inputSchema: Schema.deviceObject([
            "text": Schema.string("Text to type."),
            "element": Schema.selector("Field to tap first. Default: the field that has focus."),
            "method": Schema.string("How to enter the text.", enum: TypingMethod.allCases.map(\.rawValue)),
            "clear": Schema.bool("Select all and delete before typing.", default: false),
            "submit": Schema.bool("Press Return afterwards.", default: false),
        ], required: ["text"]),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        guard let text = try arguments.string("text") else { throw ISimError.invalidArgument("`text` is required.") }
        var method = try arguments.choice("method", default: TypingMethod.auto)
        let clear = try arguments.bool("clear", default: false)
        let submit = try arguments.bool("submit", default: false)
        let device = try await context.session.resolveReady(try arguments.device)
        let input = try context.router.backend(.typeText, for: device, as: (any InputInjecting).self)
        // The UI agent types any script itself.
        let typist = input as? any TextTyping

        var strokes: [KeyStroke] = []
        switch (method, HIDKeyboard.strokes(for: text)) {
        case (.paste, _): break
        case (_, _) where typist != nil: method = .hid
        case (_, .success(let typed)): strokes = typed; method = .hid
        case (.auto, .failure): method = .paste
        case (.hid, .failure(let failure)):
            throw ISimError.invalidArgument("\"\(failure.character)\" has no key on a US keyboard; use method=paste (or auto).")
        }

        var notes: [String] = []
        var tapped: CGPoint?
        if try arguments.selector("element") != nil {
            let target = try await target(arguments, device: device, context: context, capability: .typeText)
            try await input.tap(udid: device.udid, at: target.point, count: 1, hold: .milliseconds(60))
            // The field takes focus and the keyboard attaches.
            try await Task.sleep(for: .milliseconds(400))
            notes.append("tapped " + target.description)
            tapped = target.point
        }
        // The screen before typing: what the fields held, to tell whether the text arrived.
        var before = await readScreen(device, context)
        if clear {
            let field = before.flatMap { TextFields.target(in: $0, tappedAt: tapped) }
            // The deletion shows a moment later; an empty field has nothing to wait for.
            let wait = field?.value?.isEmpty == false ? arrivalTimeout : .zero
            try await selectAllAndDelete(udid: device.udid, input: input, pause: clearPause)
            if let screen = before {
                before = try await waitForArrival(from: screen, device: device, context: context, wait: wait).screen
            }
            if let field, let screen = before,
               TextFields.clearMissed(before: field.value, after: TextFields.field(at: field.center, in: screen)?.value) {
                try await selectAllAndDelete(udid: device.udid, input: input, pause: clearPause * 3)
                before = try await waitForArrival(from: screen, device: device, context: context, wait: wait).screen
            }
        }
        if method == .paste {
            try await context.router.backend(.pasteboard, for: device, as: (any PasteboardAccessing).self)
                .copyToPasteboard(udid: device.udid, text: text)
            try await input.pressKeys(udid: device.udid, [KeyStroke(usage: 0x19, modifiers: [.command])])
            notes.append("the text is left on the pasteboard")
        } else if let typist {
            try await typist.typeText(udid: device.udid, text)
        } else {
            try await input.pressKeys(udid: device.udid, strokes)
        }

        // Where the text went, read before Return can leave the screen, once the app has taken all of it in.
        var arrival = Arrival()
        var menuTried = false
        if let before {
            arrival = try await waitForArrival(from: before, device: device, context: context, wait: arrivalTimeout)
            if method == .paste, arrival.field == nil, let screen = arrival.screen, let alert = SystemAlert.find(in: screen) {
                // iOS asks before an app reads the pasteboard itself (Flutter on iPhones); allowing it pastes.
                return .text("Pressed Cmd+V, and a system alert asks first: " + alert.summary
                    + "\nAnswer it with handle_system_alert (accept lets the paste through).")
            }
            if method == .paste, arrival.field == nil, let field = TextFields.target(in: before, tappedAt: tapped) {
                menuTried = true
                if try await pasteFromMenu(into: field, before: before, device: device, input: input, context: context) {
                    arrival = try await waitForArrival(from: before, device: device, context: context, wait: arrivalTimeout)
                    if arrival.field != nil { notes.append("Cmd+V left the field unchanged, so pasted from the edit menu") }
                }
            }
        }
        if submit { try await input.pressKeys(udid: device.udid, [KeyStroke(usage: 0x28)]) }

        var result = "Typed \(text.count) character(s) with \(method == .hid ? "the keyboard" : "paste")"
            + (submit ? " and pressed Return" : "") + (notes.isEmpty ? "." : " (" + notes.joined(separator: "; ") + ").")
        // What the field shows now, so a dropped or autocorrected character is visible.
        if let screen = arrival.screen {
            if let focused = TextFields.focused(in: screen) {
                result += "\nFocused: " + UIElementFormatter.line(focused)
            } else if let field = arrival.field {
                result += "\nField: " + UIElementFormatter.line(field)
            } else if method == .paste {
                result += menuTried
                    ? "\nNeither Cmd+V nor the edit menu's Paste changed a field, so the text may have gone nowhere."
                    : "\nCmd+V changed no field: pass `element` so type_text can paste from the edit menu instead."
            } else {
                result += "\nNo field changed and none reports keyboard focus, so the text may have gone nowhere: "
                    + "pass `element` or tap a field first."
            }
        }
        return .text(result)
    }

    /// How long select-all may take to apply before Delete: Flutter applies it asynchronously.
    static let clearPause = Duration.milliseconds(250)
    /// How long typed, pasted or deleted text may take to show in the field. Flutter shows it a few frames later.
    static let arrivalTimeout = Duration.seconds(1)

    /// The screen after typing, and the input whose value changed if one did.
    struct Arrival {
        var screen: UIElement?
        var field: UIElement?
    }

    /// The screen, or nil when it cannot be read: the checks around typing never fail the typing itself.
    static func readScreen(_ device: Device, _ context: ToolContext) async -> UIElement? {
        try? await context.screen(device, for: .typeText, patience: .zero)
    }

    /// Reads the screen until an input differs from `before` and reads the same twice in a row, for up to `wait`:
    /// Flutter shows typed keys a few at a time.
    static func waitForArrival(from before: UIElement, device: Device, context: ToolContext, wait: Duration) async throws -> Arrival {
        let clock = ContinuousClock()
        let deadline = clock.now + wait
        var arrival = Arrival()
        while true {
            if let screen = await readScreen(device, context) {
                let previous = arrival.field
                arrival = Arrival(screen: screen, field: TextFields.changed(from: before, to: screen))
                if let field = arrival.field, let previous, previous.frame.isClose(to: field.frame), previous.value == field.value {
                    return arrival
                }
            }
            if clock.now >= deadline { return arrival }
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    static func selectAllAndDelete(udid: String, input: any InputInjecting, pause: Duration) async throws {
        try await input.pressKeys(udid: udid, [KeyStroke(usage: 0x04, modifiers: [.command])])
        try await Task.sleep(for: pause)
        try await input.pressKeys(udid: udid, [KeyStroke(usage: 0x2A)])
    }

    /// Long-presses the field and taps Paste in the edit menu that comes up. For apps that handle Cmd+V by reading
    /// the pasteboard themselves, which iOS refuses without asking (Flutter); the menu's Paste is UIKit's own and
    /// needs no permission. The text goes where the long press puts the cursor. False when no Paste item came up.
    static func pasteFromMenu(
        into field: UIElement, before: UIElement, device: Device, input: any InputInjecting, context: ToolContext
    ) async throws -> Bool {
        try await input.tap(udid: device.udid, at: field.center, count: 1, hold: .milliseconds(800))
        let paste = ElementSelector(label: "Paste")
        let existing = before.descendants(matching: paste)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while true {
            let items = await readScreen(device, context)?.descendants(matching: paste) ?? []
            if let item = items.first(where: { item in !existing.contains { $0.frame.isClose(to: item.frame) } }) {
                try await input.tap(udid: device.udid, at: item.center, count: 1, hold: .milliseconds(60))
                return true
            }
            if clock.now >= deadline { return false }
            try await Task.sleep(for: pollInterval)
        }
    }

    static let pressKey = ToolDefinition(
        name: "press_key",
        toolset: .ui,
        description: """
            Press a key on the hardware keyboard, optionally with modifiers: return, delete, tab, escape, space, arrows \
            (up/down/left/right), home, end, page_up, page_down, forward_delete, f1–f12, or a single character. \
            E.g. key=a modifiers=[command] selects all.
            """,
        inputSchema: Schema.deviceObject([
            "key": Schema.string("Key name or a single character."),
            "hid_usage": Schema.integer("USB HID keyboard usage (page 7) instead of key, e.g. 40 for Return.", minimum: 1, maximum: 0xFFFF),
            "modifiers": ["type": "array", "items": ["type": "string", "enum": .array(KeyModifier.allCases.map { .string($0.rawValue) })],
                          "description": "Modifier keys held during the press."],
            "repeat": Schema.integer("Press this many times.", default: 1, minimum: 1, maximum: 100),
        ]),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        var stroke: KeyStroke
        if let key = try arguments.string("key"), !key.isEmpty {
            guard let named = HIDKeyboard.usage(forKey: key) else {
                throw ISimError.invalidArgument("Unknown key \"\(key)\". Use a single character or one of: "
                    + HIDKeyboard.namedKeys.keys.sorted().joined(separator: ", ") + ".")
            }
            stroke = named
        } else if let usage = try arguments.int("hid_usage") {
            stroke = KeyStroke(usage: UInt32(clamping: usage))
        } else {
            throw ISimError.invalidArgument("Pass `key` or `hid_usage`.")
        }
        for name in try arguments.stringArray("modifiers") {
            guard let modifier = KeyModifier(rawValue: name.lowercased()) else {
                throw ISimError.invalidArgument("Unknown modifier \"\(name)\". Use: command, shift, option, control.")
            }
            if !stroke.modifiers.contains(modifier) { stroke.modifiers.append(modifier) }
        }
        let count = try arguments.int("repeat", default: 1, range: 1...100)
        let device = try await context.session.resolveReady(try arguments.device)
        try await context.router.backend(.pressKey, for: device, as: (any InputInjecting).self)
            .pressKeys(udid: device.udid, Array(repeating: stroke, count: count))
        let name = (stroke.modifiers.map(\.rawValue) + [try arguments.string("key") ?? String(format: "usage 0x%02X", stroke.usage)])
            .joined(separator: "+")
        return .text("Pressed \(name)" + (count > 1 ? " \(count) times." : "."))
    }

    static let pressButton = ToolDefinition(
        name: "press_button",
        toolset: .ui,
        description: "Press a hardware button: home (go to the home screen), lock, side, siri, volume_up, volume_down.",
        inputSchema: Schema.deviceObject([
            "button": Schema.string("Button to press.", enum: HardwareButton.allCases.map(\.rawValue)),
            "duration_ms": Schema.integer("How long to hold it; a long side press brings up Siri.", default: 100, minimum: 10, maximum: 10_000),
        ], required: ["button"]),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        guard let button = try arguments.choice("button", as: HardwareButton.self) else {
            throw ISimError.invalidArgument("`button` is required: " + HardwareButton.allCases.map(\.rawValue).joined(separator: ", ") + ".")
        }
        let hold = Duration.milliseconds(try arguments.int("duration_ms", default: 100, range: 10...10_000))
        let device = try await context.session.resolveReady(try arguments.device)
        try await context.router.backend(.pressButton, for: device, as: (any InputInjecting).self)
            .pressButton(udid: device.udid, button, hold: hold)
        return .text("Pressed \(button.rawValue) on \"\(device.name)\".")
    }

    // MARK: Waiting and alerts

    enum WaitCondition: String, CaseIterable {
        case exists
        case gone
        case screenStable = "screen_stable"
    }

    static let pollInterval = Duration.milliseconds(250)

    static let waitFor = ToolDefinition(
        name: "wait_for",
        toolset: .ui,
        description: """
            Wait until an element appears (exists), disappears (gone), or the screen stops changing (screen_stable: \
            the UI tree is the same for stable_ms). Use after a tap that starts a transition or loads data.
            """,
        inputSchema: Schema.deviceObject([
            "condition": Schema.string("What to wait for.", enum: WaitCondition.allCases.map(\.rawValue)),
            "element": Schema.selector("Element for exists and gone."),
            "timeout_ms": Schema.integer("Give up after this long.", default: 5000, minimum: 100, maximum: 120_000),
            "stable_ms": Schema.integer("For screen_stable: how long nothing may change.", default: 600, minimum: 200, maximum: 10_000),
        ], required: ["condition"]),
        annotations: .readOnly
    ) { arguments, context in
        try context.requireXcode()
        guard let condition = try arguments.choice("condition", as: WaitCondition.self) else {
            throw ISimError.invalidArgument("`condition` is required: exists, gone or screen_stable.")
        }
        let selector = try arguments.selector("element")
        if condition != .screenStable && selector == nil {
            throw ISimError.invalidArgument("`element` is required for \(condition.rawValue).")
        }
        let timeout = Duration.milliseconds(try arguments.int("timeout_ms", default: 5000, range: 100...120_000))
        let stable = Duration.milliseconds(try arguments.int("stable_ms", default: 600, range: 200...10_000))
        let device = try await context.session.resolveReady(try arguments.device)
        let provider = try context.router.backend(.waitFor, for: device, as: (any AccessibilityProviding).self)
        await context.accessibility.prepare(device)

        let clock = ContinuousClock()
        let start = clock.now
        var last: UIElement?
        var lastLines: [String]?
        var unchangedSince = start
        while true {
            // An app that is starting has an empty tree for a moment: that is just "not there yet".
            let tree = try? await provider.uiTree(udid: device.udid, maxDepth: nil)
            let elapsed = String(format: "%.1f s", (clock.now - start).inSeconds)
            if let tree, !tree.isEmptyApplication {
                last = tree
                switch condition {
                case .exists:
                    if let match = tree.descendants(matching: selector!).dropFirst(selector!.index ?? 0).first {
                        return .text("Found after \(elapsed): " + UIElementFormatter.line(match))
                    }
                case .gone:
                    if tree.descendants(matching: selector!).count <= (selector!.index ?? 0) {
                        return .text("Gone after \(elapsed): nothing matches \(selector!).")
                    }
                case .screenStable:
                    let lines = UIElementFormatter.compact(tree, interactiveOnly: false, screen: tree.frame).lines
                    if lines != lastLines {
                        lastLines = lines
                        unchangedSince = clock.now
                    } else if clock.now - unchangedSince >= stable {
                        return .text("Screen stable after \(elapsed).")
                    }
                }
            }
            if clock.now - start >= timeout { break }
            try await Task.sleep(for: pollInterval)
        }

        let seconds = String(format: "%.1f s", timeout.inSeconds)
        var message = switch condition {
        case .exists: "Timed out after \(seconds): nothing matches \(selector!)."
        case .gone: "Timed out after \(seconds): \(selector!) is still there."
        case .screenStable: "Timed out after \(seconds): the screen kept changing."
        }
        if let last {
            let listing = UIElementFormatter.compact(last, interactiveOnly: false, screen: last.frame)
            message += "\nScreen now: " + UIQuery.title(of: last) + "\n" + listing.lines.prefix(40).joined(separator: "\n")
        }
        return .error(message)
    }

    enum AlertAction: String, CaseIterable {
        case read
        case accept
        case deny
        case tap
    }

    static let handleSystemAlert = ToolDefinition(
        name: "handle_system_alert",
        toolset: .ui,
        description: """
            Read or answer a system alert, such as a permission prompt (notifications, location, photos, tracking). \
            accept taps the allowing button ("Allow While Using App", "Allow", "OK"), deny the refusing one ("Don't Allow"), \
            tap the button named by button_label. Waits up to timeout_ms for an alert to appear. \
            On iPhones it also answers alerts and sheets inside apps (e.g. "Save Password?"); on simulators, \
            use tap with the button's label for those.
            """,
        inputSchema: Schema.deviceObject([
            "action": Schema.string("What to do.", enum: AlertAction.allCases.map(\.rawValue)),
            "button_label": Schema.string("For tap: the button's label."),
            "timeout_ms": Schema.integer("How long to wait for an alert to appear.", default: 2000, minimum: 0, maximum: 60_000),
        ], required: ["action"]),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        guard let action = try arguments.choice("action", as: AlertAction.self) else {
            throw ISimError.invalidArgument("`action` is required: read, accept, deny or tap.")
        }
        let buttonLabel = try arguments.string("button_label")
        if action == .tap && (buttonLabel ?? "").isEmpty {
            throw ISimError.invalidArgument("`button_label` is required for tap.")
        }
        let timeout = Duration.milliseconds(try arguments.int("timeout_ms", default: 2000, range: 0...60_000))
        let device = try await context.session.resolveReady(try arguments.device)

        guard let alert = try await waitForAlert(device, context: context, timeout: timeout) else {
            let message = "No system alert is shown on \"\(device.name)\"."
            return action == .read ? .text(message) : .error(message + " For an alert inside the app, use tap with the button's label.")
        }
        if action == .read { return .text("System alert: " + alert.summary) }

        let input = try context.router.backend(.systemAlert, for: device, as: (any InputInjecting).self)
        // An alert ignores touches while it animates in, and its frames do not show that. It may have just appeared.
        try await Task.sleep(for: alertSettleTime)
        var button: UIElement?
        for _ in 1...2 {
            switch action {
            case .tap:
                guard let match = alert.buttons.first(where: { ElementSelector.equal($0.label, buttonLabel!) }) else {
                    throw ISimError.notFound("The alert has no button \"\(buttonLabel!)\". " + alert.summary)
                }
                button = match
            default:
                guard let choice = alert.button(accepting: action == .accept) else {
                    throw ISimError.notFound("Cannot tell which button would \(action.rawValue). Use action=tap with a label. " + alert.summary)
                }
                button = choice
            }
            try await input.tap(udid: device.udid, at: button!.center, count: 1, hold: .milliseconds(60))

            // The tap counts once the alert is gone or replaced; a tap the alert ignored is repeated once.
            let clock = ContinuousClock()
            let deadline = clock.now + .milliseconds(1500)
            var current: SystemAlert? = alert
            while clock.now < deadline {
                try await Task.sleep(for: pollInterval)
                current = try await currentAlert(device, context: context)
                if current != alert { break }
            }
            if current != alert {
                var result = "Tapped \"\(button!.label ?? "?")\" in the alert" + (alert.title.map { ": \($0)" } ?? ".")
                // Apps often ask for several permissions in a row.
                if let next = current { result += "\nAnother alert is shown: " + next.summary }
                return .text(result)
            }
        }
        return .error("Tapped \"\(button?.label ?? "?")\" twice, but the alert is still shown: " + alert.summary)
    }

    /// How long an alert may still be animating in after it shows up in the UI tree.
    static let alertSettleTime = Duration.milliseconds(500)

    static func waitForAlert(_ device: Device, context: ToolContext, timeout: Duration) async throws -> SystemAlert? {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            if let alert = try await currentAlert(device, context: context) { return alert }
            if clock.now >= deadline { return nil }
            try await Task.sleep(for: pollInterval)
        }
    }

    static func currentAlert(_ device: Device, context: ToolContext) async throws -> SystemAlert? {
        SystemAlert.find(in: try await context.screen(device, for: .systemAlert))
    }

    // MARK: Orientation

    static let setOrientation = ToolDefinition(
        name: "set_orientation",
        toolset: .ui,
        description: "Rotate the device. Apps that support the orientation rotate their interface; an iPhone with rotation lock on stays as it is.",
        inputSchema: Schema.deviceObject([
            "orientation": Schema.string("New orientation.", enum: DeviceOrientation.allCases.map(\.rawValue)),
        ], required: ["orientation"]),
        annotations: .idempotent
    ) { arguments, context in
        try context.requireXcode()
        guard let orientation = try arguments.choice("orientation", as: DeviceOrientation.self) else {
            throw ISimError.invalidArgument("`orientation` is required.")
        }
        let device = try await context.session.resolveReady(try arguments.device)
        let state = try await context.router.backend(.orientation, for: device, as: (any OrientationControlling).self)
            .setOrientation(udid: device.udid, orientation)
        return .text("\"\(device.name)\": " + describe(state))
    }

    /// "Orientation: landscapeLeft (lying face up), rotation lock on"
    static func describe(_ state: OrientationState) -> String {
        var text = "Orientation: \(state.orientation?.rawValue ?? "unknown")"
        if let physical = state.physical, physical != "unknown" { text += " (device lies \(physical == "faceUp" ? "face up" : physical == "faceDown" ? "face down" : physical))" }
        if state.isLocked { text += ", rotation lock on" }
        return text
    }
}
