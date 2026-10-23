import CryptoKit
import DeviceCore
import Foundation
import ProcessKit

/// Where the agent's Xcode project lives and where its builds are cached.
public struct AgentPaths: Sendable {
    /// The directory with ISimAgent.xcodeproj.
    public var source: URL
    /// `~/Library/Application Support/iSim-mcp/agent`: a directory per team (and `simulator`) with
    /// DerivedData, the build fingerprint and logs.
    public var cache: URL

    public init(source: URL, cache: URL) {
        self.source = source
        self.cache = cache
    }

    public static var defaultCache: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iSim-mcp/agent", isDirectory: true)
    }

    /// `ISIM_AGENT_SOURCE`, then `share/isim-mcp/Agent` next to the installed binary (`make install`),
    /// then the repository this binary was built from.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> AgentPaths? {
        var candidates: [URL] = []
        if let path = environment["ISIM_AGENT_SOURCE"], !path.isEmpty { candidates.append(URL(fileURLWithPath: path)) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        candidates.append(executable.deletingLastPathComponent().appendingPathComponent("../share/isim-mcp/Agent").standardized)
        // Sources/AgentBackend/AgentBuild.swift → the repository's Agent/.
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Agent").standardized)
        let source = candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("ISimAgent.xcodeproj").path) }
        return source.map { AgentPaths(source: $0, cache: defaultCache) }
    }
}

/// A development team that can sign the agent for iPhones.
public struct DevelopmentTeam: Sendable, Equatable, CustomStringConvertible {
    public var id: String
    public var name: String
    public var isPersonal: Bool

    public init(id: String, name: String, isPersonal: Bool) {
        self.id = id
        self.name = name
        self.isPersonal = isPersonal
    }

    public var description: String { "\(id) (\(name))" }

    /// The teams of the accounts signed in to Xcode (Settings → Accounts).
    static func xcodeTeams(runner: any ProcessRunning) async -> [DevelopmentTeam] {
        guard let result = try? await runner.run("/usr/bin/defaults", ["export", "com.apple.dt.Xcode", "-"], timeout: .seconds(10)),
              result.succeeded
        else { return [] }
        return parseXcodeTeams(result.stdout)
    }

    static func parseXcodeTeams(_ plist: Data) -> [DevelopmentTeam] {
        guard let preferences = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let accounts = preferences["IDEProvisioningTeamByIdentifier"] as? [String: Any]
        else { return [] }
        var teams: [DevelopmentTeam] = []
        for case let list as [[String: Any]] in accounts.values {
            for entry in list {
                guard let id = entry["teamID"] as? String, !teams.contains(where: { $0.id == id }) else { continue }
                let personal = (entry["isFreeProvisioningTeam"] as? Bool) ?? (entry["isFreeProvisioningTeam"] as? Int == 1)
                teams.append(DevelopmentTeam(id: id, name: entry["teamName"] as? String ?? id, isPersonal: personal))
            }
        }
        return teams.sorted { $0.id < $1.id }
    }
}

/// What a build is for: simulators (ad-hoc signed, no team) or iPhones signed by a team.
enum AgentTarget: Sendable, Equatable {
    case simulator
    case device(team: String)

    /// The cache subdirectory.
    var key: String {
        switch self {
        case .simulator: "simulator"
        case .device(let team): team
        }
    }

    var platform: String {
        switch self {
        case .simulator: "iphonesimulator"
        case .device: "iphoneos"
        }
    }
}

/// Builds the agent with `xcodebuild build-for-testing` and finds the result again.
struct AgentBuilder: Sendable {
    let runner: any ProcessRunning
    let paths: AgentPaths
    let xcode: XcodeEnvironment

    struct Product: Sendable {
        var xctestrun: URL
        /// The UI-test runner app, which carries the provisioning profile on iPhones.
        var runnerApp: URL
        var fingerprint: String
    }

    func directory(_ target: AgentTarget) -> URL {
        paths.cache.appendingPathComponent(target.key, isDirectory: true)
    }

    private func derivedData(_ target: AgentTarget) -> URL {
        directory(target).appendingPathComponent("DerivedData", isDirectory: true)
    }

    /// Changes with any file of the agent's project and with the Xcode build: a running agent of another
    /// fingerprint is replaced, a cached build of another fingerprint is rebuilt.
    func fingerprint() throws -> String {
        var hash = SHA256()
        hash.update(data: Data("\(xcode.version) \(xcode.build ?? "")\n".utf8))
        let root = paths.source.standardizedFileURL.path
        let files = FileManager.default.enumerator(at: paths.source, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .filter { !$0.path.contains("/xcuserdata/") && $0.lastPathComponent != ".DS_Store" }
            .sorted { $0.path < $1.path } ?? []
        for file in files {
            hash.update(data: Data(file.standardizedFileURL.path.dropFirst(root.count).utf8))
            hash.update(data: try Data(contentsOf: file))
        }
        return hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The cached build if it was made from these sources with this Xcode.
    func existingProduct(_ target: AgentTarget, fingerprint: String) -> Product? {
        let stamp = directory(target).appendingPathComponent("fingerprint")
        guard (try? String(contentsOf: stamp, encoding: .utf8)) == fingerprint else { return nil }
        return product(target, fingerprint: fingerprint)
    }

    private func product(_ target: AgentTarget, fingerprint: String) -> Product? {
        let products = derivedData(target).appendingPathComponent("Build/Products", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? []
        guard let xctestrun = files.first(where: { $0.pathExtension == "xctestrun" && $0.lastPathComponent.contains(target.platform) }) else {
            return nil
        }
        let runnerApp = products.appendingPathComponent("Debug-\(target.platform)/ISimAgentRunner-Runner.app")
        return Product(xctestrun: xctestrun, runnerApp: runnerApp, fingerprint: fingerprint)
    }

    /// `destination`: `id=<udid>` for an iPhone, so automatic signing registers it in the team's profile.
    func build(_ target: AgentTarget, destination: String, fingerprint: String) async throws -> Product {
        let directory = directory(target)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = directory.appendingPathComponent("fingerprint")
        try? FileManager.default.removeItem(at: stamp)
        var arguments = [
            "build-for-testing", "-project", paths.source.appendingPathComponent("ISimAgent.xcodeproj").path,
            "-scheme", "ISimAgent", "-destination", destination, "-derivedDataPath", derivedData(target).path,
        ]
        switch target {
        case .simulator: arguments.append("ISIM_AGENT_ID=simulator")
        case .device(let team): arguments += ["-allowProvisioningUpdates", "DEVELOPMENT_TEAM=\(team)"]
        }
        let result = try await runner.run("/usr/bin/xcodebuild", arguments, timeout: .seconds(900))
        let log = result.stdoutString + result.stderrString
        try? Data(log.utf8).write(to: directory.appendingPathComponent("build.log"))
        guard result.succeeded, let product = product(target, fingerprint: fingerprint) else {
            throw ISimError.commandFailed(
                command: "xcodebuild build-for-testing (UI agent)",
                message: AgentFailure.explainBuild(log, target: target) + " Full log: \(directory.appendingPathComponent("build.log").path)")
        }
        try Data(fingerprint.utf8).write(to: stamp)
        return product
    }

    /// Whether the build's provisioning profile lets it run on this iPhone: the device is in it and it has not
    /// expired (a Personal Team's profiles last 7 days).
    func isProvisioned(_ product: Product, for udid: String) async -> Bool {
        let profile = product.runnerApp.appendingPathComponent("embedded.mobileprovision")
        guard let result = try? await runner.run("/usr/bin/security", ["cms", "-D", "-i", profile.path], timeout: .seconds(10)),
              result.succeeded,
              let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any]
        else { return false }
        return Self.profile(plist, allows: udid, at: Date())
    }

    static func profile(_ plist: [String: Any], allows udid: String, at date: Date) -> Bool {
        if let expiration = plist["ExpirationDate"] as? Date, expiration < date.addingTimeInterval(3600) { return false }
        if plist["ProvisionsAllDevices"] as? Bool == true { return true }
        let devices = plist["ProvisionedDevices"] as? [String] ?? []
        return devices.contains { $0.caseInsensitiveCompare(udid) == .orderedSame }
    }
}

/// Turns xcodebuild's output into what the user should do.
enum AgentFailure {
    static func explainBuild(_ log: String, target: AgentTarget) -> String {
        let team = if case .device(let team) = target { team } else { "" }
        if log.contains("No Account for Team") || log.contains("No Accounts") || log.contains("requires a development team") {
            return "Xcode has no signed-in account for team \(team): add the Apple ID in Xcode → Settings → Accounts, "
                + "or pass another team_id to ui_agent."
        }
        if log.contains("No signing certificate") || log.contains("No profiles for") {
            return "Xcode could not create a signing certificate or profile for team \(team). Open Xcode → Settings → Accounts, "
                + "select the team and click Download Manual Profiles, or check the team's certificate limit."
        }
        if log.contains("Failed Registering Bundle Identifier") || log.contains("cannot be registered to your development team") {
            return "The agent's bundle identifier cannot be registered for team \(team)."
        }
        return "Building the UI agent failed: " + errorLines(log)
    }

    /// Why `xcodebuild test-without-building` stopped before the agent answered.
    static func explainStart(_ log: String) -> String? {
        if log.contains("Developer App Certificate is not trusted") || log.contains("not trusted") && log.contains("certificate") {
            return "The iPhone does not trust the developer certificate the agent is signed with. On the iPhone open "
                + "Settings → General → VPN & Device Management, tap the Apple Development certificate and trust it, "
                + "then call ui_agent start again."
        }
        if log.localizedCaseInsensitiveContains("UI Automation") {
            return "UI automation is off on the iPhone: turn on Settings → Developer → Enable UI Automation, then try again."
        }
        if log.contains("is locked") || log.contains("DeviceLocked") || log.contains("passcode") {
            return "The iPhone is locked: unlock it and keep it unlocked while UI tools run."
        }
        if log.contains("Developer Mode") && log.localizedCaseInsensitiveContains("disabled") {
            return "Developer Mode is off: enable it in Settings → Privacy & Security → Developer Mode."
        }
        let errors = errorLines(log)
        return errors.isEmpty ? nil : errors
    }

    /// The lines that say what went wrong, at most five.
    static func errorLines(_ log: String) -> String {
        let lines = log.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let errors = lines.filter {
            ($0.contains("error:") || $0.hasPrefix("Error") || $0.contains("** TEST") && $0.contains("FAILED") || $0.contains("Underlying Error"))
                && !$0.contains("IDESchemeActionSDKRecord") && !$0.contains("DiagnoseError")
        }
        return Array(NSOrderedSet(array: errors).array as? [String] ?? errors).prefix(5).joined(separator: " ")
    }
}
