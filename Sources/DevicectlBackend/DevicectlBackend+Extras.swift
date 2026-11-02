import DeviceCore
import Foundation
import ProcessKit

// Phase 5 operations on physical devices: renaming, memory warnings, the app console, crash reports, app data.

extension DevicectlBackend: DeviceRenaming, MemoryWarningSending, ConsoleLaunching, CrashReportProviding, ContainerFileAccessing,
    UserDefaultsReading, DarwinNotificationPosting
{
    public func rename(udid: String, name: String) async throws {
        try await devicectl(["device", "rename", "--device", udid, "--name", name])
    }

    public func sendMemoryWarning(udid: String, pid: Int?) async throws {
        guard let pid else { throw ISimError.invalidArgument("A memory warning on a physical device goes to one process: pass its pid or bundle_id.") }
        do {
            try await devicectl(["device", "process", "sendMemoryWarning", "--device", udid, "--pid", String(pid)])
        } catch let ISimError.commandFailed(command, message) where message.contains("NSPOSIXErrorDomain error 2") {
            // Seen with Xcode 27.1 and iOS 27.0.1 for a running development build; simulators take the warning.
            throw ISimError.commandFailed(command: command, message: "the device refused the memory warning for pid \(pid) "
                + "(\(message)). devicectl fails this way on some iOS versions; simulators get memory warnings reliably.")
        }
    }

    /// `--quiet` leaves only the app's own output; `--console` does not allow JSON on stdout, which the app's output takes.
    public func consoleCommand(udid: String, bundleId: String, options: LaunchOptions) -> BackgroundCommand {
        var arguments = ["devicectl", "--quiet", "device", "process", "launch", "--console", "--device", udid]
        if options.terminateExisting { arguments.append("--terminate-existing") }
        if options.startStopped { arguments.append("--start-stopped") }
        if !options.environment.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: options.environment, options: [.sortedKeys]) {
            arguments += ["--environment-variables", String(decoding: data, as: UTF8.self)]
        }
        arguments.append(bundleId)
        if !options.arguments.isEmpty { arguments += ["--"] + options.arguments }
        return BackgroundCommand(executable: "/usr/bin/xcrun", arguments: arguments, noise: ["Child process terminated with signal"])
    }

    // MARK: Crash reports

    /// The device's diagnostic reports by name; reading one means copying it to the Mac.
    public func crashReports(udid: String) async throws -> [CrashReportEntry] {
        let json = try await devicectl(["device", "info", "files", "--device", udid, "--domain-type", "systemCrashLogs"], timeout: .seconds(120))
        return DevicectlParser.files(from: json, under: "")
            .filter { !$0.isDirectory && $0.path.hasSuffix(".ips") }
            .map { file in
                let name = file.path
                let fileName = (name as NSString).lastPathComponent
                return CrashReportEntry(
                    name: name, date: file.modified, process: CrashReportEntry.processName(fromFileName: fileName),
                    bundleId: nil, kind: CrashReportEntry.kind(bugType: nil, name: fileName))
            }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    public func crashReport(udid: String, name: String) async throws -> Data {
        guard !name.split(separator: "/").contains("..") else { throw ISimError.invalidArgument("Invalid report name \(name).") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("isim-crash-\(UUID().uuidString).ips")
        defer { try? FileManager.default.removeItem(at: file) }
        try await devicectl([
            "device", "copy", "from", "--device", udid, "--domain-type", "systemCrashLogs", "--source", name, "--destination", file.path,
        ], timeout: .seconds(120))
        guard let data = FileManager.default.contents(atPath: file.path) else {
            throw ISimError.notFound("No crash report \"\(name)\" on the device. Use list_crash_reports to see its reports.")
        }
        return data
    }

    // MARK: Container files

    /// Containers of development builds only: iOS lets devicectl into apps signed with get-task-allow.
    private func domain(_ bundleId: String, _ container: AppContainer) -> [String] {
        switch container {
        case .data: ["--domain-type", "appDataContainer", "--domain-identifier", bundleId]
        case .group(let identifier): ["--domain-type", "appGroupDataContainer", "--domain-identifier", identifier]
        }
    }

    public func listFiles(udid: String, bundleId: String, container: AppContainer, subpath: String, depth: Int) async throws -> [ContainerFile] {
        let relative = try ContainerPath.normalize(subpath)
        var arguments = ["device", "info", "files", "--device", udid] + domain(bundleId, container)
        if !relative.isEmpty { arguments += ["--subdirectory", relative] }
        if depth <= 1 { arguments.append("--no-recurse") }
        let json = try await devicectl(arguments, timeout: .seconds(120))
        // devicectl names entries relative to the subdirectory.
        return DevicectlParser.files(from: json, under: relative)
            .filter { file in
                let inside = relative.isEmpty ? file.path : String(file.path.dropFirst(relative.count + 1))
                return inside.split(separator: "/").count <= depth
            }
            .sorted { $0.path < $1.path }
    }

    public func readFile(udid: String, bundleId: String, container: AppContainer, path: String, to destination: URL) async throws {
        let relative = try ContainerPath.normalize(path)
        try? FileManager.default.removeItem(at: destination)
        try await devicectl(["device", "copy", "from", "--device", udid] + domain(bundleId, container)
            + ["--source", relative, "--destination", destination.path], timeout: .seconds(300))
    }

    public func writeFile(udid: String, bundleId: String, container: AppContainer, path: String, from source: URL) async throws {
        let relative = try ContainerPath.normalize(path)
        guard !relative.isEmpty else { throw ISimError.invalidArgument("`path` must name a file inside the container.") }
        try await devicectl(["device", "copy", "to", "--device", udid] + domain(bundleId, container)
            + ["--source", source.path, "--destination", relative], timeout: .seconds(300))
    }

    /// The preferences file as cfprefsd last wrote it; a value the app set a moment ago may not be on disk yet.
    public func userDefaults(udid: String, bundleId: String, suite: String?) async throws -> Data {
        let domain = suite ?? bundleId
        let container: AppContainer = domain.hasPrefix("group.") ? .group(domain) : .data
        let path = ContainerPath.preferences(domain: domain)
        let existing = try await listFiles(udid: udid, bundleId: bundleId, container: container, subpath: "Library/Preferences", depth: 1)
        guard existing.contains(where: { $0.path == path }) else {
            return try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("isim-defaults-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: file) }
        try await readFile(udid: udid, bundleId: bundleId, container: container, path: path, to: file)
        guard let data = FileManager.default.contents(atPath: file.path) else {
            throw ISimError.commandFailed(command: "devicectl device copy from", message: "no file was copied")
        }
        return data
    }

    public func postDarwinNotification(udid: String, name: String) async throws {
        try await devicectl(["device", "notification", "post", "--device", udid, "--name", name])
    }
}
