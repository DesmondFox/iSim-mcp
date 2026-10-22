import DeviceCore
import Foundation
import ProcessKit

/// Parsing of `simctl` output. Separate from the backend so it is tested on fixtures.
public enum SimctlParser {
    private struct DeviceList: Decodable {
        struct Entry: Decodable {
            var udid: String
            var name: String
            var state: String
            var isAvailable: Bool?
            var deviceTypeIdentifier: String?
        }

        var devices: [String: [Entry]]
    }

    /// `simctl list devices --json` → iOS simulators, sorted by runtime (newest first), then name.
    public static func devices(fromListJSON data: Data) throws -> [Device] {
        let list: DeviceList
        do {
            list = try JSONDecoder().decode(DeviceList.self, from: data)
        } catch {
            throw ISimError.commandFailed(command: "simctl list devices --json", message: "unexpected output: \(error)")
        }

        var devices: [Device] = []
        for (runtimeId, entries) in list.devices {
            guard let osVersion = iOSVersion(fromRuntime: runtimeId) else { continue }
            for entry in entries {
                devices.append(Device(
                    udid: entry.udid,
                    name: entry.name,
                    kind: .simulator,
                    state: state(entry.state),
                    osVersion: osVersion,
                    model: entry.deviceTypeIdentifier.map(modelName(fromDeviceType:)),
                    isAvailable: entry.isAvailable ?? true
                ))
            }
        }
        return devices.sorted {
            let order = ($0.osVersion ?? "").compare($1.osVersion ?? "", options: .numeric)
            return order == .orderedSame ? $0.name < $1.name : order == .orderedDescending
        }
    }

    /// `simctl list runtimes --json` → iOS runtimes.
    public static func runtimes(fromListJSON data: Data) throws -> [SimRuntime] {
        struct List: Decodable { var runtimes: [SimRuntime] }
        do {
            return try JSONDecoder().decode(List.self, from: data).runtimes.filter { $0.platform == "iOS" }
        } catch {
            throw ISimError.commandFailed(command: "simctl list runtimes --json", message: "unexpected output: \(error)")
        }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-0" → "27.0"; nil for other platforms.
    static func iOSVersion(fromRuntime runtimeId: String) -> String? {
        let prefix = "com.apple.CoreSimulator.SimRuntime.iOS-"
        guard runtimeId.hasPrefix(prefix) else { return nil }
        return runtimeId.dropFirst(prefix.count).replacingOccurrences(of: "-", with: ".")
    }

    /// "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro" → "iPhone 16 Pro"
    static func modelName(fromDeviceType identifier: String) -> String {
        let tail = identifier.split(separator: ".").last.map(String.init) ?? identifier
        return tail.replacingOccurrences(of: "-", with: " ")
    }

    static func state(_ raw: String) -> DeviceState {
        switch raw {
        case "Booted": .booted
        case "Booting": .booting
        case "Shutting Down": .shuttingDown
        case "Creating": .creating
        default: .shutdown
        }
    }

    /// `simctl listapps <udid>` prints an OpenStep plist keyed by bundle id.
    public static func apps(fromListAppsPlist data: Data) throws -> [InstalledApp] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]] else {
            throw ISimError.commandFailed(command: "simctl listapps", message: "unexpected output")
        }
        return plist.map { bundleId, info in
            InstalledApp(
                bundleId: bundleId,
                name: (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String,
                version: info["CFBundleShortVersionString"] as? String,
                build: info["CFBundleVersion"] as? String,
                type: (info["ApplicationType"] as? String) == "User" ? "user" : "system",
                path: info["Path"] as? String
            )
        }
        .sorted { ($0.type == "user" ? 0 : 1, $0.bundleId) < ($1.type == "user" ? 0 : 1, $1.bundleId) }
    }

    /// `simctl appinfo` prints an OpenStep plist; returns the details and the path of the main executable.
    public static func appInfo(fromPlist data: Data) throws -> (details: AppDetails, executable: String?) {
        guard
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let bundleId = info["CFBundleIdentifier"] as? String
        else {
            throw ISimError.commandFailed(command: "simctl appinfo", message: "unexpected output")
        }
        let path = info["Path"] as? String
        let app = InstalledApp(
            bundleId: bundleId,
            name: (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String,
            version: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String,
            type: (info["ApplicationType"] as? String) == "User" ? "user" : "system",
            path: path
        )
        let groups = (info["GroupContainers"] as? [String: String] ?? [:])
            .map { AppGroupContainer(identifier: $0.key, path: filePath($0.value)) }
            .sorted { $0.identifier < $1.identifier }
        // OpenStep plists keep numbers as strings.
        func flag(_ key: String) -> Bool { (info[key] as? String) == "1" || (info[key] as? Bool) == true }
        var flags: [String] = []
        if flag("IsDeveloperApp") { flags.append("developer build") }
        if flag("IsAppClip") { flags.append("app clip") }
        if flag("IsHidden") { flags.append("hidden") }
        let details = AppDetails(
            app: app,
            dataContainer: (info["DataContainer"] as? String).map(filePath),
            appGroups: groups,
            entitlementsJSON: nil,
            flags: flags
        )
        let executable = (info["CFBundleExecutable"] as? String).flatMap { name in path.map { "\($0)/\(name)" } }
        return (details, executable)
    }

    /// "file:///Users/me/Library/…/Data/Application/ABC/" → "/Users/me/Library/…/Data/Application/ABC"
    static func filePath(_ value: String) -> String {
        guard value.hasPrefix("file://"), let url = URL(string: value) else { return value }
        return url.path
    }

    /// `launchctl list` inside a simulator: "PID\tStatus\tLabel" rows; apps are `UIKitApplication:<bundle id>[…]`.
    /// Jobs that are not running ("-" instead of a pid) are skipped. Apps come first.
    public static func processes(fromLaunchctlList output: String) -> [RunningProcess] {
        var seen = Set<Int>()
        var processes: [RunningProcess] = []
        for line in output.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard columns.count == 3, let pid = Int(columns[0]), seen.insert(pid).inserted else { continue }
            let label = columns[2]
            let prefix = "UIKitApplication:"
            if label.hasPrefix(prefix) {
                let bundleId = String(label.dropFirst(prefix.count).prefix { $0 != "[" })
                processes.append(RunningProcess(pid: pid, name: bundleId, bundleId: bundleId, path: nil))
            } else {
                processes.append(RunningProcess(pid: pid, name: label, bundleId: nil, path: nil))
            }
        }
        return processes.sorted { ($0.bundleId == nil ? 1 : 0, $0.name.lowercased()) < ($1.bundleId == nil ? 1 : 0, $1.name.lowercased()) }
    }

    /// "com.apple.mobilesafari: 23860" → 23860
    public static func pid(fromLaunchOutput output: String) -> Int? {
        output.split(separator: "\n").last
            .flatMap { $0.split(separator: ":").last }
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// The most useful part of simctl's error output: the first line plus the underlying reason.
    public static func errorMessage(_ result: ProcessResult) -> String {
        let lines = result.stderrString
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Underlying error") && !$0.hasPrefix("An error was encountered") }
        var unique: [String] = []
        for line in lines where !unique.contains(line) { unique.append(line) }
        let text = unique.prefix(3).joined(separator: " ")
        return text.isEmpty ? "exit code \(result.exitCode)" : text
    }
}
