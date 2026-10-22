import Foundation

/// A key press with modifiers held, as USB HID keyboard usages (page 0x07).
public struct KeyStroke: Sendable, Equatable {
    public var usage: UInt32
    public var modifiers: [KeyModifier]

    public init(usage: UInt32, modifiers: [KeyModifier] = []) {
        self.usage = usage
        self.modifiers = modifiers
    }
}

public enum KeyModifier: String, Sendable, CaseIterable {
    case command
    case shift
    case option
    case control

    /// Left-hand modifier keys.
    public var usage: UInt32 {
        switch self {
        case .control: 0xE0
        case .shift: 0xE1
        case .option: 0xE2
        case .command: 0xE3
        }
    }
}

public enum HardwareButton: String, Sendable, CaseIterable {
    case home
    case lock
    case side
    case siri
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"
}

/// A US keyboard: what the simulator's HID keyboard can type.
public enum HIDKeyboard {
    /// Keys `press_key` accepts by name.
    public static let namedKeys: [String: UInt32] = [
        "return": 0x28, "enter": 0x28, "escape": 0x29, "delete": 0x2A, "backspace": 0x2A, "tab": 0x2B, "space": 0x2C,
        "forward_delete": 0x4C, "home": 0x4A, "end": 0x4D, "page_up": 0x4B, "page_down": 0x4E,
        "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52,
        "f1": 0x3A, "f2": 0x3B, "f3": 0x3C, "f4": 0x3D, "f5": 0x3E, "f6": 0x3F,
        "f7": 0x40, "f8": 0x41, "f9": 0x42, "f10": 0x43, "f11": 0x44, "f12": 0x45,
    ]

    private static let unshifted: [Character: UInt32] = [
        " ": 0x2C, "-": 0x2D, "=": 0x2E, "[": 0x2F, "]": 0x30, "\\": 0x31, ";": 0x33, "'": 0x34, "`": 0x35,
        ",": 0x36, ".": 0x37, "/": 0x38, "\n": 0x28, "\t": 0x2B,
    ]

    private static let shifted: [Character: UInt32] = [
        "!": 0x1E, "@": 0x1F, "#": 0x20, "$": 0x21, "%": 0x22, "^": 0x23, "&": 0x24, "*": 0x25, "(": 0x26, ")": 0x27,
        "_": 0x2D, "+": 0x2E, "{": 0x2F, "}": 0x30, "|": 0x31, ":": 0x33, "\"": 0x34, "~": 0x35, "<": 0x36, ">": 0x37, "?": 0x38,
    ]

    /// The stroke that types `character`, or nil when the US layout has no key for it.
    public static func stroke(for character: Character) -> KeyStroke? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            // "\r\n" is one Character.
            return character == "\r\n" ? KeyStroke(usage: 0x28) : nil
        }
        switch scalar.value {
        case 0x61...0x7A: return KeyStroke(usage: 0x04 + scalar.value - 0x61)
        case 0x41...0x5A: return KeyStroke(usage: 0x04 + scalar.value - 0x41, modifiers: [.shift])
        case 0x31...0x39: return KeyStroke(usage: 0x1E + scalar.value - 0x31)
        case 0x30: return KeyStroke(usage: 0x27)
        case 0x0D: return KeyStroke(usage: 0x28)
        default: break
        }
        if let usage = unshifted[character] { return KeyStroke(usage: usage) }
        if let usage = shifted[character] { return KeyStroke(usage: usage, modifiers: [.shift]) }
        return nil
    }

    /// Strokes for the whole text, or the first character without a key.
    public static func strokes(for text: String) -> Result<[KeyStroke], UntypableCharacter> {
        var strokes: [KeyStroke] = []
        for character in text {
            guard let stroke = stroke(for: character) else { return .failure(UntypableCharacter(character: character)) }
            strokes.append(stroke)
        }
        return .success(strokes)
    }

    /// A key by name (`return`, `left`, `f5`) or a single character (`a`, `/`).
    public static func usage(forKey key: String) -> KeyStroke? {
        let name = key.lowercased()
        if let usage = namedKeys[name] { return KeyStroke(usage: usage) }
        if key.count == 1, let stroke = stroke(for: key.first!) { return stroke }
        return nil
    }

    public struct UntypableCharacter: Error, Equatable {
        public var character: Character
    }
}
