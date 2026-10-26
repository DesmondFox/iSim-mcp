import Foundation

// App data the `data` tools read and write: container files and preferences.

/// Which container of an app.
public enum AppContainer: Sendable, Equatable, CustomStringConvertible {
    /// The app's own data container: Documents, Library, tmp.
    case data
    /// A shared app group container, by group identifier.
    case group(String)

    public var description: String {
        switch self {
        case .data: "data container"
        case .group(let identifier): "app group \(identifier)"
        }
    }
}

public struct ContainerFile: Sendable, Equatable {
    /// Relative to the container root, "/"-separated.
    public var path: String
    public var isDirectory: Bool
    public var size: Int?
    public var modified: Date?

    public init(path: String, isDirectory: Bool, size: Int?, modified: Date?) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }
}

public enum ContainerPath {
    /// A path inside a container, relative and without `..`: "Documents/a.txt" from "/Documents/a.txt" or "./Documents/a.txt".
    public static func normalize(_ path: String) throws(ISimError) -> String {
        let parts = path.split(separator: "/").filter { $0 != "." && !$0.isEmpty }
        guard !parts.contains("..") else {
            throw .invalidArgument("Paths must stay inside the container; \"..\" is not allowed: \(path)")
        }
        return parts.joined(separator: "/")
    }

    /// Where an app's preferences domain lives inside its container.
    public static func preferences(domain: String) -> String {
        "Library/Preferences/\(domain).plist"
    }
}

/// Conversions between property lists and what tools show or accept.
public enum PropertyList {
    /// `<integer>3</integer>`, `<dict>…</dict>`: the form `defaults write` takes for a value of any type.
    /// Accepts what JSONSerialization and PropertyListSerialization produce.
    public static func xmlElement(_ value: Any) throws(ISimError) -> String {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return number.boolValue ? "<true/>" : "<false/>"
        case let number as NSNumber:
            if CFNumberIsFloatType(number) { return "<real>\(number.doubleValue)</real>" }
            return "<integer>\(number.int64Value)</integer>"
        case let string as String:
            return "<string>\(escape(string))</string>"
        case let date as Date:
            return "<date>\(ISO8601DateFormatter().string(from: date))</date>"
        case let data as Data:
            return "<data>\(data.base64EncodedString())</data>"
        case let array as [Any]:
            var elements: [String] = []
            for item in array { elements.append(try xmlElement(item)) }
            return "<array>" + elements.joined() + "</array>"
        case let dictionary as [String: Any]:
            var entries: [String] = []
            for key in dictionary.keys.sorted() {
                entries.append("<key>\(escape(key))</key>" + (try xmlElement(dictionary[key]!)))
            }
            return "<dict>" + entries.joined() + "</dict>"
        case is NSNull:
            throw .invalidArgument("Property lists have no null; remove the key instead.")
        default:
            throw .invalidArgument("\(type(of: value)) cannot be stored in a property list.")
        }
    }

    /// A property list object as JSON: dates become ISO 8601 strings, data becomes base64 (`"<data: 12 bytes> …"`).
    public static func json(_ object: Any) -> String {
        let compatible = jsonCompatible(object)
        guard JSONSerialization.isValidJSONObject(compatible) || compatible is String || compatible is NSNumber,
              let data = try? JSONSerialization.data(
                  withJSONObject: compatible, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return "\(object)" }
        return String(decoding: data, as: UTF8.self)
    }

    static func jsonCompatible(_ object: Any) -> Any {
        switch object {
        case let date as Date: ISO8601DateFormatter().string(from: date)
        case let data as Data: "<data: \(data.count) bytes> " + data.prefix(256).base64EncodedString()
        case let array as [Any]: array.map(jsonCompatible)
        case let dictionary as [String: Any]: dictionary.mapValues(jsonCompatible)
        default: object
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
