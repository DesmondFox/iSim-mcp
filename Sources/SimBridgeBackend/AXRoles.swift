import DeviceCore
import Foundation
import SimBridge

/// Maps the macOS accessibility roles AXPTranslator produces for iOS elements to the short `UIRole` names.
enum AXRoles {
    private static let subroles: [String: String] = [
        "AXSwitch": "switch",
        "AXSearchField": "search_field",
        "AXSecureTextField": "secure_text_field",
    ]

    private static let roles: [String: String] = [
        "AXApplication": UIRole.application,
        "AXStaticText": "text",
        "AXGenericElement": "element",
        "AXTextField": "text_field",
        "AXTextArea": "text_view",
        "AXCheckBox": "checkbox",
        "AXIncrementor": "stepper",
        "AXProgressIndicator": "progress",
        "AXBusyIndicator": "activity_indicator",
        "AXWebArea": "web_view",
        "AXScrollArea": "scroll_view",
        "AXTabGroup": "tab_bar",
        "AXPopUpButton": "popup_button",
        "AXMenuButton": "menu_button",
    ]

    static func role(_ role: String?, subrole: String?) -> String {
        if let subrole, let name = subroles[subrole] { return name }
        guard let role, !role.isEmpty else { return "element" }
        if let name = roles[role] { return name }
        return snakeCase(role.hasPrefix("AX") ? String(role.dropFirst(2)) : role)
    }

    /// "RadioButton" → "radio_button"
    static func snakeCase(_ name: String) -> String {
        var result = ""
        for (index, character) in name.enumerated() {
            if character.isUppercase && index > 0 { result += "_" }
            result += character.lowercased()
        }
        return result
    }
}

extension UIElement {
    init(_ element: SBAXElement) {
        self.init(
            role: AXRoles.role(element.role, subrole: element.subrole),
            label: Self.text(element.label),
            value: Self.text(element.value),
            identifier: Self.text(element.identifier),
            frame: element.frame,
            isEnabled: element.enabled,
            isFocused: element.focused,
            isSelected: element.selected,
            pid: element.pid > 0 ? Int(element.pid) : nil,
            children: element.children.map(UIElement.init),
            isTruncated: element.truncated
        )
    }

    /// SpringBoard labels itself " ".
    private static func text(_ string: String?) -> String? {
        guard let string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return string
    }
}
