import CoreGraphics
import DeviceCore
import Foundation

/// Reading the screen and finding elements for the UI tools.
extension ToolContext {
    /// The frontmost app's UI tree. An app that is still starting, or SpringBoard between an alert and the app,
    /// has no elements for a moment, so an empty tree is re-read for up to `patience`. An app that stays empty
    /// without even a frame never loaded its accessibility runtime.
    func screen(_ device: Device, for capability: Capability, maxDepth: Int? = nil, patience: Duration = .seconds(2)) async throws -> UIElement {
        let provider = try router.backend(capability, for: device, as: (any AccessibilityProviding).self)
        let justEnabled = await accessibility.prepare(device)
        let clock = ContinuousClock()
        let deadline = clock.now + (justEnabled ? .zero : patience)
        while true {
            let tree = try await provider.uiTree(udid: device.udid, maxDepth: maxDepth)
            if !tree.children.isEmpty || maxDepth == 0 && !tree.isEmptyApplication { return tree }
            if clock.now >= deadline {
                if tree.isEmptyApplication { throw Self.noAccessibility(tree, justEnabled: justEnabled) }
                return tree
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    static func noAccessibility(_ tree: UIElement, justEnabled: Bool) -> ISimError {
        let app = "The frontmost app\(tree.pid.map { " (pid \($0))" } ?? "")"
        let cause = justEnabled
            ? "Accessibility was off on this simulator when the app started; iSim-mcp has turned it on now."
            : "It may still be starting, or it was started while accessibility was off on this simulator."
        return .notFound("\(app) does not expose its UI to accessibility. \(cause) Relaunch the app with launch_app and try again. "
            + "Taps at coordinates from a screenshot work meanwhile.")
    }

    /// The one element the selector names: the only match, or the match at `index`. Right after a launch or a tap
    /// the next screen may not be up yet, so a missing element is waited for up to `patience`.
    func element(
        _ selector: ElementSelector, on device: Device, for capability: Capability, patience: Duration = .seconds(3)
    ) async throws -> (UIElement, screen: UIElement) {
        let clock = ContinuousClock()
        let deadline = clock.now + patience
        while true {
            let tree = try await screen(device, for: capability)
            if tree.descendants(matching: selector).count > (selector.index ?? 0) || clock.now >= deadline {
                return (try UIQuery.single(selector, in: tree), tree)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }
}

enum UIQuery {
    /// Fails with the candidates listed when nothing or several elements match.
    static func single(_ selector: ElementSelector, in tree: UIElement) throws(ISimError) -> UIElement {
        let matches = tree.descendants(matching: selector)
        if let index = selector.index {
            guard index < matches.count else {
                throw .notFound("No element matches \(selector): \(matches.count) element(s) match without the index."
                    + (matches.isEmpty ? similar(to: selector, in: tree) : ""))
            }
            return matches[index]
        }
        switch matches.count {
        case 0:
            throw .notFound("No element matches \(selector)." + similar(to: selector, in: tree))
        case 1:
            return matches[0]
        default:
            // A control and its own icon or text can come as separate elements, with one frame (Flutter) or inside
            // the control (a table row's label under XCUITest): the one that can be used is meant.
            let interactive = matches.filter(\.isInteractive)
            if interactive.count == 1 {
                let control = interactive[0].frame
                if matches.allSatisfy({ $0.frame.isClose(to: control) || control.insetBy(dx: -1, dy: -1).contains($0.frame) }) {
                    return interactive[0]
                }
            }
            let listed = matches.prefix(10).enumerated().map { "  \($0.offset): " + UIElementFormatter.line($0.element) }
            throw .invalidArgument("\(matches.count) elements match \(selector); add `index` or a narrower field:\n"
                + listed.joined(separator: "\n") + (matches.count > 10 ? "\n  …" : ""))
        }
    }

    /// Elements whose label, value or identifier contains the selector's text: likely what was meant.
    static func similar(to selector: ElementSelector, in tree: UIElement) -> String {
        let needles = [selector.identifier, selector.label, selector.labelContains, selector.value]
            .compactMap { $0.map(ElementSelector.normalize) }
            .filter { !$0.isEmpty }
        guard !needles.isEmpty else { return " Call describe_ui to see the screen." }
        let similar = tree.flattened.dropFirst().filter { element in
            let texts = [element.label, element.value, element.identifier].compactMap { $0.map(ElementSelector.normalize) }
            return needles.contains { needle in texts.contains { $0.contains(needle) || needle.contains($0) && $0.count > 2 } }
        }
        guard !similar.isEmpty else { return " Call describe_ui to see the screen." }
        return " Similar elements:\n" + similar.prefix(5).map { "  " + UIElementFormatter.line($0) }.joined(separator: "\n")
    }

    /// Whether any part of the element is on the screen the tree root spans.
    static func isOnScreen(_ element: UIElement, screen: UIElement) -> Bool {
        screen.frame.isEmpty || element.frame.intersects(screen.frame)
    }

    /// `"iSim Test" (pid 66752), 402×874 pt`
    static func title(of root: UIElement) -> String {
        let name = root.label.map { "\"\($0)\"" } ?? "SpringBoard: home screen or system UI"
        let size = "\(UIElementFormatter.number(root.frame.width))×\(UIElementFormatter.number(root.frame.height)) pt"
        return name + (root.pid.map { " (pid \($0))" } ?? "") + ", " + size
    }
}

/// Text inputs of a screen: how type_text finds its field again and tells whether the text arrived.
/// Fields are matched by frame, since Flutter drops a field's label (its hint) once it has a value.
enum TextFields {
    static let roles: Set<String> = ["text_field", "secure_text_field", "search_field", "text_view"]

    /// The inputs in reading order.
    static func all(in tree: UIElement) -> [UIElement] {
        tree.flattened.dropFirst().filter { roles.contains($0.role) }
    }

    /// The smallest input under the point.
    static func field(at point: CGPoint, in tree: UIElement) -> UIElement? {
        all(in: tree).filter { $0.frame.contains(point) }.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// The field type_text works on: the input under the point it tapped, else the focused element, else the only input.
    static func target(in tree: UIElement, tappedAt point: CGPoint?) -> UIElement? {
        if let point, let field = field(at: point, in: tree) { return field }
        if let focused = focused(in: tree) { return focused }
        let inputs = all(in: tree)
        return inputs.count == 1 ? inputs[0] : nil
    }

    /// The element with keyboard focus. Flutter fields never report it.
    static func focused(in tree: UIElement) -> UIElement? {
        tree.flattened.first { $0.isFocused && $0.role != UIRole.application }
    }

    /// The first input whose value is not what it was in `before`, or that was not there.
    static func changed(from before: UIElement, to after: UIElement) -> UIElement? {
        let old = all(in: before)
        return all(in: after).first { field in
            guard let previous = old.first(where: { $0.frame.isClose(to: field.frame) }) else { return true }
            return previous.value != field.value
        }
    }

    /// Delete arrived before select-all took effect, so one character went instead of all of them.
    /// Flutter applies Cmd+A asynchronously.
    static func clearMissed(before: String?, after: String?) -> Bool {
        guard let before, let after, before.count > 1 else { return false }
        return after.count == before.count - 1
    }
}

extension CGRect {
    /// The same frame within `tolerance` points: frames of one element differ by fractions between readings.
    func isClose(to other: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

/// A system alert (permission prompts and the like) as SpringBoard shows it: SpringBoard is the frontmost
/// UI and its buttons have no identifiers, unlike the icons of the home screen. On iPhones XCUITest also marks
/// alerts and sheets inside apps, such as the system's "Save Password?".
struct SystemAlert: Equatable {
    var texts: [String]
    var buttons: [UIElement]

    var title: String? { texts.first }

    static func find(in tree: UIElement) -> SystemAlert? {
        if tree.role == UIRole.application, tree.label == nil {
            let elements = tree.flattened.dropFirst()
            let buttons = elements.filter { $0.role == "button" && $0.identifier == nil && $0.label != nil }
            if !buttons.isEmpty {
                return SystemAlert(texts: elements.filter { $0.role == "text" }.compactMap(\.label), buttons: buttons)
            }
        }
        guard let dialog = tree.flattened.dropFirst().first(where: { $0.role == "alert" || $0.role == "sheet" }) else { return nil }
        let elements = dialog.flattened.dropFirst()
        let buttons = elements.filter { $0.role == "button" && $0.label != nil }
        guard !buttons.isEmpty else { return nil }
        return SystemAlert(texts: elements.filter { $0.role == "text" }.compactMap(\.label), buttons: buttons)
    }

    static let acceptLabels = [
        "Allow While Using App", "Allow", "Allow Full Access", "OK", "Continue", "Allow Paste", "Open", "Join", "Trust", "Allow Once",
    ]
    static let denyLabels = [
        "Don't Allow", "Not Now", "Cancel", "Ask App Not to Track", "Don't Allow Paste", "Close", "Later", "Deny",
    ]

    /// The button for accept or deny: a known label first, then iOS's layout (the preferred action is last).
    func button(accepting: Bool) -> UIElement? {
        let preferred = accepting ? Self.acceptLabels : Self.denyLabels
        for label in preferred {
            if let button = buttons.first(where: { ElementSelector.equal($0.label, label) }) { return button }
        }
        guard buttons.count > 1 else { return accepting ? buttons.first : nil }
        return accepting ? buttons.last : buttons.first
    }

    /// The title (iOS quotes the app name in it), the message, then the buttons.
    var summary: String {
        var text = texts.first ?? "(no title)"
        if texts.count > 1 { text += " — " + texts.dropFirst().joined(separator: " ") }
        return text + "\nButtons: " + buttons.compactMap(\.label).map { "\"\($0)\"" }.joined(separator: ", ")
    }
}
