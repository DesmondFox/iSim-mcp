import DeviceCore

/// Tool groups that can be switched on with `--toolsets`, so clients don't load 70 tools into context.
public enum Toolset: String, Sendable, CaseIterable, Comparable {
    case core
    case devices
    case apps
    case screen
    case ui
    case system
    case data
    case logs
    case build
    case advanced

    public static let defaults: Set<Toolset> = [.core, .devices, .apps, .screen, .ui]

    /// Parses "devices,apps" or "all". `core` is always on.
    public static func parse(_ list: String) throws(ISimError) -> Set<Toolset> {
        var result: Set<Toolset> = [.core]
        for name in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !name.isEmpty {
            if name == "all" {
                result.formUnion(allCases)
            } else if let toolset = Toolset(rawValue: name) {
                result.insert(toolset)
            } else {
                throw .invalidArgument("Unknown toolset \"\(name)\". Available: all, " + allCases.map(\.rawValue).joined(separator: ", "))
            }
        }
        return result
    }

    public static func < (lhs: Toolset, rhs: Toolset) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}
