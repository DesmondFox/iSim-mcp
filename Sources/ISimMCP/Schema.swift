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

    static func stringArray(_ description: String) -> Value {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }

    static func stringMap(_ description: String) -> Value {
        ["type": "object", "additionalProperties": ["type": "string"], "description": .string(description)]
    }
}
