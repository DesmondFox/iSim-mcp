import CoreGraphics
import DeviceCore
import Foundation

/// The agent's replies about the UI, turned into `UIElement`s with the same roles SimBridge uses.
enum AgentTree {
    static let springboard = "com.apple.springboard"

    /// XCUIElement.ElementType names (as the agent sends them) whose short role is not their snake_case.
    private static let roles: [String: String] = [
        "Application": UIRole.application,
        "StaticText": "text",
        "Other": "element",
        "Any": "element",
        "Toggle": "switch",
        "CheckBox": "checkbox",
        "PopUpButton": "popup_button",
        "ToolbarButton": "button",
        // Home screen icons; AX on simulators calls them buttons too.
        "Icon": "button",
        "ProgressIndicator": "progress",
        "TextView": "text_view",
    ]

    static func role(_ type: String) -> String {
        roles[type] ?? snakeCase(type)
    }

    /// "SecureTextField" → "secure_text_field"
    static func snakeCase(_ name: String) -> String {
        var result = ""
        for (index, character) in name.enumerated() {
            if character.isUppercase && index > 0 { result += "_" }
            result += character.lowercased()
        }
        return result
    }

    /// A reply of `GET /tree`. SpringBoard's root loses its label, as with SimBridge: the home screen and
    /// system alerts are "no app".
    static func screen(from data: Data) throws -> UIElement {
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tree = reply["tree"] as? [String: Any]
        else { throw AgentConnectionError.transfer("The UI agent sent a tree in an unknown format.") }
        var root = element(tree)
        if reply["bundle_id"] as? String == springboard { root.label = nil }
        return root
    }

    static func element(_ node: [String: Any]) -> UIElement {
        let role = role(node["type"] as? String ?? "Other")
        let frame = (node["frame"] as? [Double]).flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
        var value = text(node["value"])
        // XCUITest reports an empty field's placeholder as its value.
        if TextInputs.roles.contains(role), value != nil, value == text(node["placeholder"]) { value = nil }
        return UIElement(
            role: role,
            label: text(node["label"]),
            value: value,
            identifier: text(node["identifier"]),
            frame: frame ?? .zero,
            isEnabled: node["enabled"] as? Bool ?? true,
            isFocused: node["focused"] as? Bool ?? false,
            isSelected: node["selected"] as? Bool ?? false,
            pid: node["pid"] as? Int,
            children: (node["children"] as? [[String: Any]] ?? []).map(element),
            isTruncated: node["truncated"] as? Bool ?? false)
    }

    /// SpringBoard labels itself " ".
    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return string
    }

    /// The element a touch at the point would reach, without children: the smallest one that says something
    /// (has a label, value or identifier, or can be used), else the deepest one.
    static func element(at point: CGPoint, in root: UIElement) -> UIElement? {
        var deepest: (element: UIElement, depth: Int)?
        var smallest: UIElement?
        func visit(_ element: UIElement, depth: Int) {
            for child in element.children where child.frame.contains(point) {
                if deepest == nil || depth > deepest!.depth { deepest = (child, depth) }
                let meaningful = child.isInteractive || child.label != nil || child.value != nil || child.identifier != nil
                if meaningful, smallest.map({ area(child) <= area($0) }) ?? true { smallest = child }
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 1)
        guard var found = smallest ?? deepest?.element else { return nil }
        found.children = []
        return found
    }

    private static func area(_ element: UIElement) -> CGFloat {
        element.frame.width * element.frame.height
    }
}

enum TextInputs {
    static let roles: Set<String> = ["text_field", "secure_text_field", "search_field", "text_view"]
}
