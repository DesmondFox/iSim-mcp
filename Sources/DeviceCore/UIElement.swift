import CoreGraphics
import Foundation

/// A node of the accessibility tree of the screen. Frames are in points, in the interface orientation:
/// the same coordinates as screenshots and the UI tools take.
public struct UIElement: Sendable, Equatable {
    /// Short role: button, text, text_field, switch, … (see `UIRole`).
    public var role: String
    public var label: String?
    public var value: String?
    public var identifier: String?
    public var frame: CGRect
    public var isEnabled: Bool
    public var isFocused: Bool
    public var isSelected: Bool
    public var pid: Int?
    public var children: [UIElement]
    /// Children were not read because of a depth or size limit.
    public var isTruncated: Bool

    public init(
        role: String,
        label: String? = nil,
        value: String? = nil,
        identifier: String? = nil,
        frame: CGRect = .zero,
        isEnabled: Bool = true,
        isFocused: Bool = false,
        isSelected: Bool = false,
        pid: Int? = nil,
        children: [UIElement] = [],
        isTruncated: Bool = false
    ) {
        self.role = role
        self.label = label
        self.value = value
        self.identifier = identifier
        self.frame = frame
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.isSelected = isSelected
        self.pid = pid
        self.children = children
        self.isTruncated = isTruncated
    }

    public var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    public var isInteractive: Bool { UIRole.interactive.contains(role) }

    /// The element and all its descendants, depth first: the order VoiceOver reads them.
    public var flattened: [UIElement] {
        var result: [UIElement] = []
        func visit(_ element: UIElement) {
            result.append(element)
            element.children.forEach(visit)
        }
        visit(self)
        return result
    }

    /// Descendants that match, in reading order.
    public func descendants(matching selector: ElementSelector) -> [UIElement] {
        flattened.dropFirst().filter(selector.matches)
    }

    /// Where the software keyboard is, when it is up: from its top row of keys to the bottom of the screen.
    /// Found by the identifiers of its special keys; the letter rows above them are added while they adjoin.
    public var keyboardFrame: CGRect? {
        let buttons = flattened.filter { $0.role == "button" && $0.frame.height > 0 }
        let special = buttons.filter { Self.keyboardKeyIdentifiers.contains($0.identifier ?? "") }
        guard special.count >= 3, var top = special.map(\.frame.minY).min() else { return nil }
        let keys = buttons.filter { Self.keyboardKeyIdentifiers.contains($0.identifier ?? "") || ($0.label?.count ?? 0) == 1 }
        while let row = keys.first(where: { $0.frame.minY < top - 1 && abs($0.frame.maxY - top) <= 2 }) {
            top = row.frame.minY
        }
        let bottom = max(frame.maxY, special.map(\.frame.maxY).max() ?? 0)
        return CGRect(x: frame.minX, y: top, width: max(frame.width, 1), height: bottom - top)
    }

    /// Identifiers of the iOS keyboard's special keys.
    static let keyboardKeyIdentifiers: Set<String> = ["shift", "delete", "more", "emoji", "space", "Return", "dictation"]

    /// An application root with no frame and no children: the app has not loaded its accessibility runtime.
    public var isEmptyApplication: Bool {
        role == UIRole.application && children.isEmpty && frame.width == 0 && frame.height == 0
    }

    /// The value as people read it: switches are on or off.
    public var displayValue: String? {
        guard let value else { return nil }
        if role == "switch" || role == "checkbox" {
            if value == "1" { return "on" }
            if value == "0" { return "off" }
        }
        return value
    }
}

/// Role names shared by all backends.
public enum UIRole {
    public static let application = "application"

    /// Roles a person can tap, type into or adjust.
    public static let interactive: Set<String> = [
        "button", "link", "text_field", "secure_text_field", "search_field", "text_view", "switch", "checkbox", "slider",
        "stepper", "tab", "radio_button", "popup_button", "menu_button", "menu_item", "combo_box", "segmented_control",
        "picker", "key", "cell",
    ]
}

/// Picks elements by their accessibility attributes. Text comparisons ignore case and treat typographic
/// apostrophes and quotes as plain ones ("Don’t Allow" matches "Don't allow").
public struct ElementSelector: Sendable, Equatable, CustomStringConvertible {
    public var identifier: String?
    public var label: String?
    public var labelContains: String?
    public var value: String?
    public var role: String?
    /// Which of several matches to take, 0-based in reading order.
    public var index: Int?

    public init(
        identifier: String? = nil,
        label: String? = nil,
        labelContains: String? = nil,
        value: String? = nil,
        role: String? = nil,
        index: Int? = nil
    ) {
        self.identifier = identifier
        self.label = label
        self.labelContains = labelContains
        self.value = value
        self.role = role
        self.index = index
    }

    /// No attribute to match on (`index` alone does not select anything).
    public var isEmpty: Bool {
        identifier == nil && label == nil && labelContains == nil && value == nil && role == nil
    }

    public func matches(_ element: UIElement) -> Bool {
        if let identifier, element.identifier != identifier { return false }
        if let label, !Self.equal(element.label, label) { return false }
        if let labelContains {
            guard let elementLabel = element.label, Self.normalize(elementLabel).contains(Self.normalize(labelContains)) else { return false }
        }
        if let value, !Self.equal(element.value, value) && !Self.equal(element.displayValue, value) { return false }
        if let role, Self.normalize(role) != element.role { return false }
        return true
    }

    /// `identifier "loginButton", role button`
    public var description: String {
        var parts: [String] = []
        if let identifier { parts.append("identifier \"\(identifier)\"") }
        if let label { parts.append("label \"\(label)\"") }
        if let labelContains { parts.append("label containing \"\(labelContains)\"") }
        if let value { parts.append("value \"\(value)\"") }
        if let role { parts.append("role \(role)") }
        if let index { parts.append("index \(index)") }
        return parts.joined(separator: ", ")
    }

    /// Equal under the selector's comparison rules.
    public static func equal(_ text: String?, _ expected: String) -> Bool {
        guard let text else { return false }
        return normalize(text) == normalize(expected)
    }

    public static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "[’‘ʼ]", with: "'", options: .regularExpression)
            .replacingOccurrences(of: "[“”]", with: "\"", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

/// Text renderings of UI trees for tool results.
public enum UIElementFormatter {
    /// `[button] "Log In" id=loginButton (166,512 70×34)`, flags appended: `disabled`, `focused`, `selected`.
    public static func line(_ element: UIElement) -> String {
        var line = "[\(element.role)]"
        if let label = element.label { line += " " + quoted(label) }
        if let shown = element.displayValue, shown != element.label {
            // Switch states read "on"/"off" without the value= prefix.
            line += shown == element.value ? " value=" + quoted(shown) : " " + shown
        }
        if let identifier = element.identifier, identifier != element.label { line += " id=\(identifier)" }
        line += " " + frame(element.frame)
        if !element.isEnabled { line += " disabled" }
        if element.isFocused { line += " focused" }
        if element.isSelected { line += " selected" }
        return line
    }

    /// `(16,700 343×50)`
    public static func frame(_ rect: CGRect) -> String {
        "(\(number(rect.minX)),\(number(rect.minY)) \(number(rect.width))×\(number(rect.height)))"
    }

    /// `(201,529)`
    public static func point(_ point: CGPoint) -> String {
        "(\(number(point.x)),\(number(point.y)))"
    }

    /// Whole points: finer than a finger and than what screenshots show.
    public static func number(_ value: CGFloat) -> String {
        String(Int(value.rounded()))
    }

    public struct Listing: Sendable, Equatable {
        public var lines: [String]
        /// Elements left out because they lie entirely outside the screen.
        public var offscreen: Int
    }

    /// One line per element that says something: it has a label, value or identifier, or can be used.
    /// Empty containers and zero-size elements are skipped; elements outside `screen` are only counted.
    /// The software keyboard's keys become a single `[keyboard]` line.
    public static func compact(_ root: UIElement, interactiveOnly: Bool, screen: CGRect) -> Listing {
        var lines: [String] = []
        var offscreen = 0
        let keyboard = root.keyboardFrame
        for element in root.flattened.dropFirst() {
            let meaningful = element.isInteractive || element.label != nil || element.value != nil || element.identifier != nil
            guard meaningful, !interactiveOnly || element.isInteractive else { continue }
            guard element.frame.width > 0 || element.frame.height > 0 else { continue }
            guard screen.isEmpty || element.frame.intersects(screen) else {
                offscreen += 1
                continue
            }
            // Anything starting inside the keyboard is a key or hidden behind it.
            if let keyboard, element.frame.minY >= keyboard.minY - 1 { continue }
            lines.append(line(element))
        }
        if let keyboard { lines.append("[keyboard] software keyboard \(frame(keyboard)): type with type_text, keys with press_key") }
        return Listing(lines: lines, offscreen: offscreen)
    }

    /// The tree as compact JSON: keys in a fixed order, frames as [x, y, width, height],
    /// nil fields and false flags left out.
    public static func json(_ element: UIElement) -> String {
        var fields = ["\"role\":" + jsonString(element.role)]
        if let label = element.label { fields.append("\"label\":" + jsonString(label)) }
        if let value = element.value { fields.append("\"value\":" + jsonString(value)) }
        if let identifier = element.identifier { fields.append("\"identifier\":" + jsonString(identifier)) }
        let rect = [element.frame.minX, element.frame.minY, element.frame.width, element.frame.height].map(number)
        fields.append("\"frame\":[" + rect.joined(separator: ",") + "]")
        if !element.isEnabled { fields.append("\"enabled\":false") }
        if element.isFocused { fields.append("\"focused\":true") }
        if element.isSelected { fields.append("\"selected\":true") }
        if element.isTruncated { fields.append("\"truncated\":true") }
        if !element.children.isEmpty { fields.append("\"children\":[" + element.children.map(json).joined(separator: ",") + "]") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private static func jsonString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func quoted(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return "\"" + (flat.count > 200 ? String(flat.prefix(200)) + "…" : flat) + "\""
    }
}
