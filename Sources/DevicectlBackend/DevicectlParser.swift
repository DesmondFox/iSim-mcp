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
            // Some failures (argument validation) serialize an error without a description; stderr has a line then.
            let stderr = process.stderrString.split(separator: "\n").first.map { $0.replacingOccurrences(of: "ERROR: ", with: "") }
            throw ISimError.commandFailed(command: command, message: errorMessage(document["error"] as? [String: Any]) ?? stderr ?? "outcome \(outcome ?? "unknown")")
        }
        return document["result"] as? [String: Any] ?? [:]
    }

    /// Description, failure reason and recovery suggestion of an NSError serialized by devicectl,
    /// plus the innermost underlying error, which usually names the actual problem.
    static func errorMessage(_ error: [String: Any]?) -> String? {
        func string(_ userInfo: [String: Any], _ key: String) -> String? { (userInfo[key] as? [String: Any])?["string"] as? String }
        guard let userInfo = error?["userInfo"] as? [String: Any] else { return nil }
        var parts = ["NSLocalizedDescription", "NSLocalizedFailureReason", "NSLocalizedRecoverySuggestion"].compactMap { string(userInfo, $0) }

        var innermost: String?
        var underlying = (userInfo["NSUnderlyingError"] as? [String: Any])?["error"] as? [String: Any]
        while let current = underlying, let info = current["userInfo"] as? [String: Any] {
            innermost = string(info, "NSLocalizedDescription") ?? innermost
            underlying = (info["NSUnderlyingError"] as? [String: Any])?["error"] as? [String: Any]
        }
        if let innermost, !parts.contains(where: { $0.contains(innermost) }) { parts.append(innermost) }
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
                transport: transport,
                coreDeviceId: entry["identifier"] as? String
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
        let displays = try screenInfo(from: result).displays
        return displays.first(where: \.isPrimary) ?? displays[0]
    }

    public static func screenInfo(from result: [String: Any]) throws -> ScreenInfo {
        let displays = (result["displays"] as? [[String: Any]] ?? []).compactMap { display -> DisplayInfo? in
            guard
                let size = display["nativeSize"] as? [Int], size.count == 2,
                let scale = (display["pointScale"] as? NSNumber)?.doubleValue
            else { return nil }
            return DisplayInfo(
                widthPixels: size[0],
                heightPixels: size[1],
                scale: scale,
                name: display["name"] as? String,
                uniqueId: display["uniqueId"] as? String,
                isPrimary: display["primary"] as? Bool ?? false
            )
        }
        guard !displays.isEmpty else {
            throw ISimError.commandFailed(command: "devicectl device info displays", message: "no display information in the output")
        }
        let orientation = (result["orientation"] as? [String: Any]).map { info in
            orientationState(
                raw: info["currentDeviceOrientation"] as? String,
                nonFlat: info["currentDeviceNonFlatOrientation"] as? String,
                locked: info["currentDeviceOrientationLocked"] as? Bool)
        }
        return ScreenInfo(displays: displays, orientation: orientation)
    }

    /// Result of `orientation get` / `orientation set`.
    public static func orientation(from result: [String: Any]) -> OrientationState {
        orientationState(
            raw: result["deviceOrientation"] as? String,
            nonFlat: result["deviceOrientationNonFlat"] as? String,
            locked: result["deviceIsOrientationLocked"] as? Bool)
    }

    private static func orientationState(raw: String?, nonFlat: String?, locked: Bool?) -> OrientationState {
        let orientation = (nonFlat ?? raw).flatMap(DeviceOrientation.init(rawValue:))
        return OrientationState(
            orientation: orientation,
            physical: raw == orientation?.rawValue ? nil : raw,
            isLocked: locked ?? false)
    }

    /// Result of `info appearance`.
    public static func appearance(from result: [String: Any]) -> AppearanceSettings {
        AppearanceSettings(
            style: (result["userInterfaceStyle"] as? String).flatMap(InterfaceStyle.init(rawValue:)),
            contentSize: (result["textSize"] as? String).flatMap(ContentSize.init(displayName:)),
            increaseContrast: result["increaseContrast"] as? Bool,
            reduceMotion: (result["reduceMotion"] as? [String: Any])?["enabled"] as? Bool
        )
    }

    /// Result of `simulate statusBar show`; empty when nothing is overridden.
    public static func statusBar(from result: [String: Any]) -> StatusBarOverride {
        // devicectl wraps some values in backticks (`5G`).
        func string(_ key: String) -> String? {
            (result[key] as? String).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "`")) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        return StatusBarOverride(
            time: string("time"),
            dataNetwork: string("dataNetworkType"),
            wifiMode: string("wifiMode"),
            wifiBars: result["wifiStrength"] as? Int,
            cellularMode: string("cellularMode"),
            cellularBars: result["cellularStrength"] as? Int,
            batteryState: string("batteryState"),
            batteryLevel: result["batteryLevel"] as? Int
        )
    }

    /// Result of `settings biometrics`. A physical device reports no types: its biometrics cannot be controlled.
    public static func biometrics(from result: [String: Any]) -> [BiometricEnrollment] {
        (result["biometrics"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let type = entry["type"] as? String else { return nil }
            return BiometricEnrollment(type: type, enrolled: entry["enabled"] as? Bool ?? false)
        }
    }

    /// The first app of `info apps --include-container-paths --include-app-group-identifiers --bundle-id …`.
    public static func appDetails(from result: [String: Any]) throws -> AppDetails? {
        guard let entry = (result["apps"] as? [[String: Any]])?.first, let app = try apps(from: ["apps": [entry]]).first else {
            return nil
        }
        let paths = entry["groupContainerPaths"] as? [String: String] ?? [:]
        let groupIds = Set(entry["appGroupIdentifiers"] as? [String] ?? []).union(paths.keys)
        var flags: [String] = []
        if entry["builtByDeveloper"] as? Bool == true { flags.append("developer build") }
        if entry["appClip"] as? Bool == true { flags.append("app clip") }
        if entry["hidden"] as? Bool == true { flags.append("hidden") }
        return AppDetails(
            app: app,
            dataContainer: entry["dataContainerPath"] as? String,
            appGroups: groupIds.sorted().map { AppGroupContainer(identifier: $0, path: paths[$0]) },
            entitlementsJSON: nil,
            flags: flags
        )
    }

    /// `info processes`, with bundle ids taken from the apps whose bundle holds the executable. Apps come first.
    public static func processes(from result: [String: Any], apps: [InstalledApp]) -> [RunningProcess] {
        let bundles = apps.compactMap { app in app.path.map { (url: $0.hasSuffix("/") ? $0 : $0 + "/", bundleId: app.bundleId) } }
        let processes = (result["runningProcesses"] as? [[String: Any]] ?? []).compactMap { entry -> RunningProcess? in
            guard let pid = entry["processIdentifier"] as? Int, let executable = entry["executable"] as? String else { return nil }
            // Only the main executable sits directly in the bundle; extensions live in PlugIns/.
            let bundleId = bundles.first { executable.hasPrefix($0.url) && !executable.dropFirst($0.url.count).contains("/") }?.bundleId
            let path = URL(string: executable)?.path ?? executable
            return RunningProcess(pid: pid, name: (path as NSString).lastPathComponent, bundleId: bundleId, path: path)
        }
        return processes.sorted { ($0.bundleId == nil ? 1 : 0, $0.name.lowercased()) < ($1.bundleId == nil ? 1 : 0, $1.name.lowercased()) }
    }
}
