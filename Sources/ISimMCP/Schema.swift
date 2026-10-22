import MCP

/// Small builders for tool input JSON Schemas.
enum Schema {
    static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    /// Same as `object`, plus the optional `device` parameter every device tool has.
    static func deviceObject(_ properties: [String: Value] = [:], required: [String] = []) -> Value {
        object(properties.merging(["device": device]) { current, _ in current }, required: required)
    }

    static let device = string(
        "Device UDID or name. Default: the active device (set_active_device), otherwise the only booted simulator or connected iPhone.")

    static func string(_ description: String, enum values: [String]? = nil) -> Value {
        var schema: [String: Value] = ["type": "string", "description": .string(description)]
        if let values { schema["enum"] = .array(values.map { .string($0) }) }
        return .object(schema)
    }

    static func bool(_ description: String, default value: Bool) -> Value {
        ["type": "boolean", "description": .string(description), "default": .bool(value)]
    }

    static func integer(_ description: String, default value: Int? = nil, minimum: Int? = nil, maximum: Int? = nil) -> Value {
        var schema: [String: Value] = ["type": "integer", "description": .string(description)]
        if let value { schema["default"] = .int(value) }
        if let minimum { schema["minimum"] = .int(minimum) }
        if let maximum { schema["maximum"] = .int(maximum) }
        return .object(schema)
    }

    static func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> Value {
        var schema: [String: Value] = ["type": "number", "description": .string(description)]
        if let minimum { schema["minimum"] = .double(minimum) }
        if let maximum { schema["maximum"] = .double(maximum) }
        return .object(schema)
    }

    /// A boolean without a default: omitting it means "leave as is".
    static func optionalBool(_ description: String) -> Value {
        ["type": "boolean", "description": .string(description)]
    }

    static func array(of items: Value, _ description: String, minItems: Int? = nil) -> Value {
        var schema: [String: Value] = ["type": "array", "items": items, "description": .string(description)]
        if let minItems { schema["minItems"] = .int(minItems) }
        return .object(schema)
    }

    /// An element of the frontmost app's accessibility tree, as describe_ui shows it.
    static func selector(_ description: String) -> Value {
        [
            "type": "object",
            "description": .string(description),
            "properties": [
                "identifier": ["type": "string", "description": "Accessibility identifier, exact (id=… in describe_ui)."],
                "label": ["type": "string", "description": "Accessibility label, whole text, case-insensitive."],
                "label_contains": ["type": "string", "description": "Part of the label, case-insensitive."],
                "value": ["type": "string", "description": "Value, e.g. a text field's text or on/off for a switch."],
                "role": ["type": "string", "description": "Role as describe_ui shows it: button, text, text_field, switch, cell, …"],
                "index": ["type": "integer", "minimum": 0, "description": "Which match to take when several match, 0-based in reading order."],
            ],
            "additionalProperties": false,
        ]
    }

    static func point(_ description: String) -> Value {
        [
            "type": "object",
            "description": .string(description),
            "properties": ["x": ["type": "number"], "y": ["type": "number"]],
            "required": ["x", "y"],
            "additionalProperties": false,
        ]
    }

    static func stringArray(_ description: String) -> Value {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }

    static func stringMap(_ description: String) -> Value {
        ["type": "object", "additionalProperties": ["type": "string"], "description": .string(description)]
    }
}
