import CoreGraphics
import DeviceCore
import Testing

private func element(
    _ role: String, _ label: String? = nil, value: String? = nil, id: String? = nil,
    _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, enabled: Bool = true, focused: Bool = false
) -> UIElement {
    UIElement(role: role, label: label, value: value, identifier: id, frame: CGRect(x: x, y: y, width: width, height: height),
              isEnabled: enabled, isFocused: focused)
}

/// The test app's login screen as SimBridge reads it.
private let login = UIElement(role: "application", label: "iSim Test", frame: CGRect(x: 0, y: 0, width: 402, height: 874), pid: 42, children: [
    element("heading", "Welcome", 133, 356, 137, 41),
    UIElement(role: "group", frame: CGRect(x: 0, y: 0, width: 402, height: 874), children: [
        element("text_field", value: "Username", id: "username", 24, 412.3, 354, 34),
        element("secure_text_field", value: "Password", id: "password", 24, 462.3, 354, 34),
    ]),
    element("button", "Log In", id: "loginButton", 166, 512.3, 70.3, 34.3),
    element("switch", "Remember Me", value: "1", id: "remember", 16, 560, 370, 52),
    element("button", "Don’t Allow", 57, 600, 140, 48),
    element("button", "Item 40", id: "item-40", 16, 900, 370, 52),
])

struct ElementSelectorTests {
    @Test func matchesIdentifierExactly() {
        #expect(login.descendants(matching: ElementSelector(identifier: "username")).map(\.identifier) == ["username"])
        #expect(login.descendants(matching: ElementSelector(identifier: "Username")).isEmpty)
    }

    @Test func labelsIgnoreCaseAndTypographicApostrophes() {
        #expect(login.descendants(matching: ElementSelector(label: "log in")).count == 1)
        #expect(login.descendants(matching: ElementSelector(label: "Don't allow")).count == 1)
        #expect(login.descendants(matching: ElementSelector(label: "Log")).isEmpty, "label must match the whole text")
        #expect(login.descendants(matching: ElementSelector(labelContains: "LOG")).count == 1)
    }

    @Test func switchValuesMatchOnAndOff() {
        #expect(login.descendants(matching: ElementSelector(value: "on", role: "switch")).count == 1)
        #expect(login.descendants(matching: ElementSelector(value: "1")).count == 1)
        #expect(login.descendants(matching: ElementSelector(value: "off")).isEmpty)
    }

    @Test func rolesCombineWithOtherFields() {
        #expect(login.descendants(matching: ElementSelector(role: "button")).count == 3)
        #expect(login.descendants(matching: ElementSelector(label: "Log In", role: "text")).isEmpty)
    }

    @Test func describesItself() {
        #expect(ElementSelector(identifier: "a", labelContains: "b", role: "button", index: 1).description
            == "identifier \"a\", label containing \"b\", role button, index 1")
        #expect(ElementSelector(index: 2).isEmpty)
    }
}

struct UIElementFormatterTests {
    @Test func linesShowRoleLabelValueIdentifierAndWholePoints() {
        #expect(UIElementFormatter.line(login.children[2]) == "[button] \"Log In\" id=loginButton (166,512 70×34)")
        #expect(UIElementFormatter.line(login.children[1].children[0]) == "[text_field] value=\"Username\" id=username (24,412 354×34)")
        #expect(UIElementFormatter.line(login.children[3]) == "[switch] \"Remember Me\" on id=remember (16,560 370×52)")
        #expect(UIElementFormatter.line(element("button", "Fitness", id: "Fitness", 28, 88, 68, 91, enabled: false, focused: true))
            == "[button] \"Fitness\" (28,88 68×91) disabled focused")
    }

    @Test func compactListingSkipsContainersAndCountsOffscreenElements() {
        let listing = UIElementFormatter.compact(login, interactiveOnly: false, screen: login.frame)
        #expect(listing.lines.count == 6)
        #expect(!listing.lines.contains { $0.hasPrefix("[group]") })
        #expect(listing.offscreen == 1)
        let interactive = UIElementFormatter.compact(login, interactiveOnly: true, screen: login.frame)
        #expect(!interactive.lines.contains { $0.hasPrefix("[heading]") })
    }

    @Test func jsonKeepsKeyOrderAndLeavesOutDefaults() {
        let tree = UIElement(role: "application", label: "A \"quoted\" app", frame: CGRect(x: 0, y: 0, width: 402, height: 874), children: [
            element("button", "Go", id: "go", 1.4, 2.6, 30, 40, enabled: false),
        ])
        #expect(UIElementFormatter.json(tree)
            == #"{"role":"application","label":"A \"quoted\" app","frame":[0,0,402,874],"children":[{"role":"button","label":"Go","identifier":"go","frame":[1,3,30,40],"enabled":false}]}"#)
    }

    @Test func softwareKeyboardBecomesOneLine() throws {
        var keys: [UIElement] = []
        for (row, letters) in ["qwertyuiop", "asdfghjkl", "zxcvbnm"].enumerated() {
            for (column, letter) in letters.enumerated() {
                keys.append(element("button", String(letter), 5 + CGFloat(column) * 39, 597 + CGFloat(row) * 54, 39, 54))
            }
        }
        keys += [
            element("button", "shift", id: "shift", 5, 705, 51, 54),
            element("button", "delete", id: "delete", 348, 705, 52, 54),
            element("button", "numbers", id: "more", 5, 759, 49, 54),
            element("button", "space", id: "space", 103, 759, 197, 54),
            element("button", "return", id: "Return", 301, 759, 99, 54),
            element("button", "Next keyboard", value: "Русская", 8, 806, 68, 69),
        ]
        let screen = UIElement(role: "application", label: "iSim Test", frame: CGRect(x: 0, y: 0, width: 402, height: 874),
                               children: [element("text_field", value: "Username", id: "username", 24, 265, 354, 34, focused: true)] + keys)
        #expect(screen.keyboardFrame == CGRect(x: 0, y: 597, width: 402, height: 277))
        let listing = UIElementFormatter.compact(screen, interactiveOnly: false, screen: screen.frame)
        #expect(listing.lines == [
            "[text_field] value=\"Username\" id=username (24,265 354×34) focused",
            "[keyboard] software keyboard (0,597 402×277): type with type_text, keys with press_key",
        ])
        #expect(login.keyboardFrame == nil)
    }

    @Test func emptyApplicationMeansNoAccessibilityRuntime() {
        #expect(UIElement(role: "application", pid: 7).isEmptyApplication)
        #expect(!login.isEmptyApplication)
    }
}

struct HIDKeyboardTests {
    @Test func typesUSLayoutWithShift() throws {
        let strokes = try HIDKeyboard.strokes(for: "aZ1!\n").get()
        #expect(strokes == [
            KeyStroke(usage: 0x04),
            KeyStroke(usage: 0x1D, modifiers: [.shift]),
            KeyStroke(usage: 0x1E),
            KeyStroke(usage: 0x1E, modifiers: [.shift]),
            KeyStroke(usage: 0x28),
        ])
    }

    @Test func coversPunctuation() throws {
        let text = " -=[]\\;'`,./!@#$%^&*()_+{}|:\"~<>?0"
        #expect(try HIDKeyboard.strokes(for: text).get().count == text.count)
    }

    @Test func reportsTheFirstUntypableCharacter() {
        #expect(throws: HIDKeyboard.UntypableCharacter.self) { try HIDKeyboard.strokes(for: "ok Привет").get() }
        if case .failure(let failure) = HIDKeyboard.strokes(for: "ok Привет") { #expect(failure.character == "П") }
        #expect(HIDKeyboard.stroke(for: "é") == nil)
        #expect(HIDKeyboard.stroke(for: "👋") == nil)
    }

    @Test func namesKeys() {
        #expect(HIDKeyboard.usage(forKey: "Return") == KeyStroke(usage: 0x28))
        #expect(HIDKeyboard.usage(forKey: "left") == KeyStroke(usage: 0x50))
        #expect(HIDKeyboard.usage(forKey: "A") == KeyStroke(usage: 0x04, modifiers: [.shift]))
        #expect(HIDKeyboard.usage(forKey: "nope") == nil)
    }
}

struct AgentTreeFormattingTests {
    private let screen = CGRect(x: 0, y: 0, width: 428, height: 926)

    @Test func xcuiTestKeyboardIncludesItsSuggestionBar() throws {
        let root = UIElement(role: "application", label: "iSim Test", frame: screen, children: [
            element("text_field", value: "isim", id: "username", 24, 274, 380, 34),
            element("element", id: "inputView", 0, 579, 428, 347),
            element("button", "Passwords", 30, 579, 368, 44),
            UIElement(role: "keyboard", frame: CGRect(x: 0, y: 623, width: 428, height: 245), children: [element("key", "q", 4, 630, 39, 42)]),
        ])
        #expect(root.keyboardFrame == CGRect(x: 0, y: 579, width: 428, height: 347))
        #expect(UIElementFormatter.compact(root, interactiveOnly: false, screen: screen).lines == [
            "[text_field] value=\"isim\" id=username (24,274 380×34)",
            "[keyboard] software keyboard (0,579 428×347): type with type_text, keys with press_key",
        ])
    }

    @Test func aKeyboardBelowTheScreenIsNotShown() {
        let root = UIElement(role: "application", label: "Settings", frame: screen, children: [
            UIElement(role: "keyboard", frame: CGRect(x: 0, y: 970, width: 428, height: 245)),
        ])
        #expect(root.keyboardFrame == nil)
    }

    @Test func bareCellsAreLeftOut() {
        let root = UIElement(role: "application", label: "Settings", frame: screen, children: [
            element("cell", nil, 20, 153, 388, 90),
            element("button", "General", id: "com.apple.settings.general", 20, 153, 388, 90),
            element("cell", "Labelled", 20, 243, 388, 52),
        ])
        #expect(UIElementFormatter.compact(root, interactiveOnly: false, screen: screen).lines == [
            "[button] \"General\" id=com.apple.settings.general (20,153 388×90)",
            "[cell] \"Labelled\" (20,243 388×52)",
        ])
    }
}

struct HiddenElementTests {
    @Test func selectorsSkipElementsWithoutASize() {
        // A Flutter tab bar, and the label of a screen it has left, kept with an empty frame.
        let root = UIElement(role: "application", label: "BZZR", frame: CGRect(x: 0, y: 0, width: 428, height: 926), children: [
            element("text", "Podcasts", 0, 0, 0, 0),
            element("button", "Podcasts", 279, 846, 65, 54),
        ])
        #expect(root.descendants(matching: ElementSelector(label: "Podcasts")).map(\.role) == ["button"])
    }
}
