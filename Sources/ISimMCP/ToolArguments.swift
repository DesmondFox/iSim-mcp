import DeviceCore
import Foundation
import MCP

/// Typed access to `tools/call` arguments with error messages that name the bad parameter.
/// Lenient about clients that send numbers and booleans as strings.
public struct ToolArguments: Sendable {
    public let values: [String: Value]

    public init(_ values: [String: Value]) {
        self.values = values
    }

    public func string(_ key: String) throws(ISimError) -> String? {
        switch values[key] {
        case nil, .null?: return nil
        case .string(let value)?: return value
        case .int(let value)?: return String(value)
        case .double(let value)?: return String(value)
        default: throw .invalidArgument("`\(key)` must be a string.")
        }
    }

    public func requiredString(_ key: String) throws(ISimError) -> String {
        guard let value = try string(key), !value.isEmpty else {
            throw .invalidArgument("`\(key)` is required.")
        }
        return value
    }

    public func bool(_ key: String, default defaultValue: Bool) throws(ISimError) -> Bool {
        switch values[key] {
        case nil, .null?: return defaultValue
        case .bool(let value)?: return value
        case .string(let value)? where ["true", "false"].contains(value.lowercased()): return value.lowercased() == "true"
        case .int(let value)? where value == 0 || value == 1: return value == 1
        default: throw .invalidArgument("`\(key)` must be true or false.")
        }
    }

    public func int(_ key: String) throws(ISimError) -> Int? {
        switch values[key] {
        case nil, .null?: return nil
        case .int(let value)?: return value
        case .double(let value)? where value.rounded() == value: return Int(value)
        case .string(let value)? where Int(value) != nil: return Int(value)
        default: throw .invalidArgument("`\(key)` must be an integer.")
        }
    }

    public func int(_ key: String, default defaultValue: Int, range: ClosedRange<Int>) throws(ISimError) -> Int {
        let value = try int(key) ?? defaultValue
        guard range.contains(value) else {
            throw .invalidArgument("`\(key)` must be between \(range.lowerBound) and \(range.upperBound), got \(value).")
        }
        return value
    }

    public func double(_ key: String) throws(ISimError) -> Double? {
        switch values[key] {
        case nil, .null?: return nil
        case .int(let value)?: return Double(value)
        case .double(let value)?: return value
        case .string(let value)? where Double(value) != nil: return Double(value)
        default: throw .invalidArgument("`\(key)` must be a number.")
        }
    }

    public func stringArray(_ key: String) throws(ISimError) -> [String] {
        switch values[key] {
        case nil, .null?: return []
        case .array(let items)?:
            var result: [String] = []
            for item in items {
                guard case .string(let string) = item else { throw .invalidArgument("`\(key)` must be an array of strings.") }
                result.append(string)
            }
            return result
        default: throw .invalidArgument("`\(key)` must be an array of strings.")
        }
    }

    public func stringMap(_ key: String) throws(ISimError) -> [String: String] {
        switch values[key] {
        case nil, .null?: return [:]
        case .object(let object)?:
            var result: [String: String] = [:]
            for (name, value) in object {
                switch value {
                case .string(let string): result[name] = string
                case .int(let number): result[name] = String(number)
                case .bool(let flag): result[name] = String(flag)
                default: throw .invalidArgument("`\(key).\(name)` must be a string.")
                }
            }
            return result
        default: throw .invalidArgument("`\(key)` must be an object with string values.")
        }
    }

    /// Value of an enum-like string parameter, matched case-insensitively.
    public func choice<T: RawRepresentable & CaseIterable>(_ key: String, default defaultValue: T) throws(ISimError) -> T where T.RawValue == String {
        try choice(key) ?? defaultValue
    }

    public func choice<T: RawRepresentable & CaseIterable>(_ key: String, as type: T.Type = T.self) throws(ISimError) -> T? where T.RawValue == String {
        guard let raw = try choice(key, from: T.allCases.map(\.rawValue)) else { return nil }
        return T(rawValue: raw)
    }

    /// One of `values`, matched case-insensitively and returned as spelled in `values`.
    public func choice(_ key: String, from values: [String]) throws(ISimError) -> String? {
        guard let raw = try string(key) else { return nil }
        guard let value = values.first(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) else {
            throw .invalidArgument("`\(key)` must be one of: " + values.joined(separator: ", ") + ".")
        }
        return value
    }

    /// An optional boolean: nil when the parameter is absent.
    public func optionalBool(_ key: String) throws(ISimError) -> Bool? {
        values[key] == nil || values[key] == .null ? nil : try bool(key, default: false)
    }

    /// The common optional `device` parameter.
    public var device: String? {
        get throws(ISimError) { try string("device") }
    }
}
