import DeviceCore
import Foundation
import ProcessKit

/// Parsing of `devicectl --json-output` documents (jsonVersion 5, Xcode 27).
public enum DevicectlParser {
    /// Unwraps `{info: {outcome}, result, error}`; a failed outcome becomes `ISimError.commandFailed`.
    public static func result(from process: ProcessResult, command: String) throws -> [String: Any] {
        guard let document = try? JSONSerialization.jsonObject(with: process.stdout) as? [String: Any] else {
            let stderr = process.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ISimError.commandFailed(command: command, message: stderr.isEmpty ? "exit code \(process.exitCode), no JSON output" : stderr)
        }
        let outcome = (document["info"] as? [String: Any])?["outcome"] as? String
        guard outcome == "success" else {
            throw ISimError.commandFailed(command: command, message: errorMessage(document["error"] as? [String: Any]) ?? "outcome \(outcome ?? "unknown")")
        }
        return document["result"] as? [String: Any] ?? [:]
    }

    /// Description, failure reason and recovery suggestion of an NSError serialized by devicectl.
    static func errorMessage(_ error: [String: Any]?) -> String? {
        guard let userInfo = error?["userInfo"] as? [String: Any] else { return nil }
        let keys = ["NSLocalizedDescription", "NSLocalizedFailureReason", "NSLocalizedRecoverySuggestion"]
        let parts = keys.compactMap { key in (userInfo[key] as? [String: Any])?["string"] as? String }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    public static func physicalDevices(from result: [String: Any]) throws -> [Device] {
        let entries = result["devices"] as? [[String: Any]] ?? []
        return entries.compactMap { entry -> Device? in
            let hardware = entry["hardwareProperties"] as? [String: Any] ?? [:]
            let properties = entry["deviceProperties"] as? [String: Any] ?? [:]
            let connection = entry["connectionProperties"] as? [String: Any] ?? [:]
            guard
                hardware["reality"] as? String == "physical",
                hardware["platform"] as? String == "iOS",
                let udid = hardware["udid"] as? String
            else { return nil }

            // A device that is plugged in or reachable over the network has a transport.
            let transport = connection["transportType"] as? String
            let tunnel = connection["tunnelState"] as? String
            let connected = transport != nil || tunnel == "connected"
            return Device(
                udid: udid,
                name: properties["name"] as? String ?? udid,
                kind: .physical,
                state: connected ? .connected : .disconnected,
                osVersion: properties["osVersionNumber"] as? String,
                model: hardware["marketingName"] as? String ?? hardware["productType"] as? String,
                isAvailable: true,
                developerMode: properties["developerModeStatus"] as? String,
                transport: transport
            )
        }
        .sorted { $0.name < $1.name }
    }

    public static func apps(from result: [String: Any]) throws -> [InstalledApp] {
        let entries = result["apps"] as? [[String: Any]] ?? []
        return entries.compactMap { entry -> InstalledApp? in
            guard let bundleId = entry["bundleIdentifier"] as? String else { return nil }
            // Location and `removable` don't separate built-in apps on iOS 27 (Safari is removable and lives
            // in /private/var/containers), so Apple's bundle ids count as system unless built by the developer.
            let user = entry["builtByDeveloper"] as? Bool == true || !bundleId.hasPrefix("com.apple.")
            return InstalledApp(
                bundleId: bundleId,
                name: entry["name"] as? String,
                version: entry["version"] as? String,
                build: entry["bundleVersion"] as? String,
                type: user ? "user" : "system",
                path: entry["url"] as? String
            )
        }
        .sorted { ($0.type == "user" ? 0 : 1, $0.bundleId) < ($1.type == "user" ? 0 : 1, $1.bundleId) }
    }

    public static func launchedPID(from result: [String: Any]) -> Int? {
        (result["process"] as? [String: Any])?["processIdentifier"] as? Int
    }

    /// The app's main executable lives directly inside the bundle: `<appURL><Executable>`.
    /// Extensions (`<appURL>PlugIns/…`) are skipped.
    public static func mainProcessPID(appURL: String, processesJSON: [String: Any]) throws -> Int? {
        let base = appURL.hasSuffix("/") ? appURL : appURL + "/"
        let processes = processesJSON["runningProcesses"] as? [[String: Any]] ?? []
        for process in processes {
            guard let executable = process["executable"] as? String, executable.hasPrefix(base) else { continue }
            if !executable.dropFirst(base.count).contains("/") {
                return process["processIdentifier"] as? Int
            }
        }
        return nil
    }

    public static func mainDisplay(from result: [String: Any]) throws -> DisplayInfo {
        let displays = result["displays"] as? [[String: Any]] ?? []
        guard
            let display = displays.first(where: { $0["primary"] as? Bool == true }) ?? displays.first,
            let size = display["nativeSize"] as? [Int], size.count == 2,
            let scale = (display["pointScale"] as? NSNumber)?.doubleValue
        else {
            throw ISimError.commandFailed(command: "devicectl device info displays", message: "no display information in the output")
        }
        return DisplayInfo(widthPixels: size[0], heightPixels: size[1], scale: scale)
    }
}
