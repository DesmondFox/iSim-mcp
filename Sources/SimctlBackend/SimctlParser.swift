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
