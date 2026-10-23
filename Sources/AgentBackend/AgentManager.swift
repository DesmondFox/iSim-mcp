import DeviceCore
import Foundation
import ProcessKit

/// Builds, starts, finds and stops the on-device agent (ISimAgent): one per device, living as long as the
/// server. The agent is a UI test that never finishes, run by `xcodebuild test-without-building`, serving
/// XCUITest over HTTP.
public actor AgentManager {
    /// Bumped with the agent's `Agent.protocolVersion`; an agent of another version is replaced.
    static let protocolVersion = 1
    /// The agent's port on an iPhone. Not 8100, which WebDriverAgent takes.
    public static let devicePort: UInt16 = 22087
    /// Installing the runner on a device for the first time takes the longest.
    static let startTimeout: Duration = .seconds(120)

    public struct Running: Sendable {
        public var device: Device
        public var endpoint: AgentEndpoint
        public var team: String?
        public var fingerprint: String
        public var startedAt: Date
        /// The xcodebuild running the agent; nil for an agent an earlier server left running, which this one adopted.
        var process: (any BackgroundProcess)?
        public var log: URL?
    }

    public struct StartReport: Sendable {
        public var running: Running
        /// The agent had to be built (first use, changed sources, new Xcode, expired profile).
        public var built: Bool
        /// An agent already running was taken over.
        public var reused: Bool
        public var seconds: Double
    }

    private let runner: any ProcessRunning
    private let launcher: any BackgroundLaunching
    private let xcode: XcodeEnvironment?
    private let paths: AgentPaths?
    private let defaultTeam: String?
    private let lockState: @Sendable (String) async -> Bool?
    public nonisolated let routing = AgentRouting()

    private var agents: [String: Running] = [:]
    private var starts: [String: Task<StartReport, any Error>] = [:]
    /// Why the agent of a device stopped on its own, for the next error.
    private var exits: [String: String] = [:]

    /// `defaultTeam`: `--team-id` or `ISIM_TEAM_ID`. `lockState`: whether an iPhone is locked (nil: unknown).
    public init(
        runner: any ProcessRunning,
        launcher: any BackgroundLaunching,
        xcode: XcodeEnvironment?,
        paths: AgentPaths?,
        defaultTeam: String?,
        lockState: @escaping @Sendable (String) async -> Bool?
    ) {
        self.runner = runner
        self.launcher = launcher
        self.xcode = xcode
        self.paths = paths
        self.defaultTeam = defaultTeam.flatMap { $0.isEmpty ? nil : $0 }
        self.lockState = lockState
    }

    public var sourceDirectory: URL? { paths?.source }

    public func running(_ udid: String) -> Running? {
        agents[udid]
    }

    /// Why the device's last agent stopped without being asked, if it did.
    public func lastExit(_ udid: String) -> String? {
        exits[udid]
    }

    /// The agent's client, starting the agent first when it is not running (the first UI tool on an iPhone).
    public func client(for device: Device) async throws -> AgentClient {
        if let running = agents[device.udid] { return AgentClient(endpoint: running.endpoint) }
        return AgentClient(endpoint: try await start(device, team: nil, rebuild: false).running.endpoint)
    }

    /// The agent stopped answering: the next request starts a new one.
    public func forget(_ udid: String) {
        agents[udid] = nil
    }

    public func start(_ device: Device, team: String?, rebuild: Bool) async throws -> StartReport {
        if let pending = starts[device.udid] { return try await pending.value }
        let requested = team.flatMap { $0.isEmpty ? nil : $0 }
        if !rebuild, let running = agents[device.udid], requested == nil || requested == running.team,
           (try? await Self.status(running.endpoint)) != nil {
            return StartReport(running: running, built: false, reused: true, seconds: 0)
        }
        let task = Task { try await self.launch(device, team: requested, rebuild: rebuild) }
        starts[device.udid] = task
        defer { starts[device.udid] = nil }
        return try await task.value
    }

    /// Stops the device's agent. On a simulator, UI tools go back to SimBridge.
    @discardableResult
    public func stop(_ device: Device) async -> Bool {
        routing.setAgent(false, for: device.udid)
        if let running = agents.removeValue(forKey: device.udid) {
            await stop(running)
            return true
        }
        // An agent an earlier server left on the iPhone.
        let endpoint = AgentEndpoint.device(udid: device.udid, port: Self.devicePort)
        if device.kind == .physical, (try? await Self.status(endpoint)) != nil {
            _ = try? await AgentClient(endpoint: endpoint).request("POST", "/stop", timeout: .seconds(5))
            return true
        }
        return false
    }

    /// When the server exits.
    public func stopAll() async {
        let all = agents.values
        agents = [:]
        for running in all { await stop(running) }
    }

    // MARK: Starting

    private func launch(_ device: Device, team requested: String?, rebuild: Bool) async throws -> StartReport {
        let clock = ContinuousClock()
        let started = clock.now
        func elapsed() -> Double { (clock.now - started).inSeconds }
        guard let xcode else { throw ISimError.xcodeUnavailable("The UI agent is built with Xcode, which was not found.") }
        guard let paths else {
            throw ISimError.notFound("The UI agent's Xcode project was not found. Set ISIM_AGENT_SOURCE to the Agent directory "
                + "of the iSim-mcp repository, or install with `make install`, which copies it to ~/.local/share/isim-mcp/Agent.")
        }
        if let previous = agents.removeValue(forKey: device.udid) { await stop(previous) }
        exits[device.udid] = nil

        let builder = AgentBuilder(runner: runner, paths: paths, xcode: xcode)
        let fingerprint = try builder.fingerprint()
        let target: AgentTarget
        let endpoint: AgentEndpoint
        switch device.kind {
        case .simulator:
            target = .simulator
            endpoint = .local(port: try Self.freePort())
        case .physical:
            if await lockState(device.udid) == true {
                throw ISimError.invalidArgument("\"\(device.name)\" is locked. Unlock it and keep it unlocked while UI tools run.")
            }
            let team = try await resolveTeam(requested)
            target = .device(team: team)
            endpoint = .device(udid: device.udid, port: Self.devicePort)
            if let status = try? await Self.status(endpoint) {
                if !rebuild, status.fingerprint == fingerprint, status.version == Self.protocolVersion {
                    let running = Running(device: device, endpoint: endpoint, team: team, fingerprint: fingerprint, startedAt: Date())
                    agents[device.udid] = running
                    saveTeam(team)
                    return StartReport(running: running, built: false, reused: true, seconds: elapsed())
                }
                // Another build of the agent, left by an earlier server.
                _ = try? await AgentClient(endpoint: endpoint).request("POST", "/stop", timeout: .seconds(5))
                try await Task.sleep(for: .seconds(1))
            }
        }

        var product = rebuild ? nil : builder.existingProduct(target, fingerprint: fingerprint)
        if let existing = product, device.kind == .physical, !(await builder.isProvisioned(existing, for: device.udid)) {
            product = nil
        }
        let built = product == nil
        if product == nil {
            let destination = device.kind == .simulator ? "generic/platform=iOS Simulator" : "id=\(device.udid)"
            product = try await builder.build(target, destination: destination, fingerprint: fingerprint)
        }
        let running = try await run(product!, device: device, directory: builder.directory(target), endpoint: endpoint, team: target)
        if case .device(let team) = target { saveTeam(team) }
        agents[device.udid] = running
        if device.kind == .simulator { routing.setAgent(true, for: device.udid) }
        return StartReport(running: running, built: built, reused: false, seconds: elapsed())
    }

    private func run(_ product: AgentBuilder.Product, device: Device, directory: URL, endpoint: AgentEndpoint, team: AgentTarget) async throws -> Running {
        let logs = directory.appendingPathComponent("logs", isDirectory: true)
        let results = directory.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent("\(device.udid).log")
        let result = results.appendingPathComponent("\(device.udid).xcresult")
        try? FileManager.default.removeItem(at: result)

        let port = switch endpoint {
        case .local(let port), .device(_, let port): port
        }
        let process = try launcher.launch(
            "/usr/bin/xcodebuild",
            ["test-without-building", "-xctestrun", product.xctestrun.path, "-destination", "id=\(device.udid)",
             "-resultBundlePath", result.path, "-collect-test-diagnostics", "never"],
            // xcodebuild hands TEST_RUNNER_-prefixed variables to the test runner without the prefix.
            environment: ["TEST_RUNNER_ISIM_AGENT_PORT": "\(port)", "TEST_RUNNER_ISIM_AGENT_BUILD": product.fingerprint],
            log: log)

        let clock = ContinuousClock()
        let deadline = clock.now + Self.startTimeout
        while true {
            if let status = try? await Self.status(endpoint), status.fingerprint == product.fingerprint { break }
            if !process.isRunning || clock.now >= deadline {
                let timedOut = process.isRunning
                process.terminate()
                let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                let reason = AgentFailure.explainStart(text)
                    ?? (timedOut ? "it did not answer within \(Int(Self.startTimeout.inSeconds)) s." : "it stopped before it answered.")
                throw ISimError.commandFailed(command: "xcodebuild test-without-building (UI agent)", message: reason + " Log: \(log.path)")
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        let teamID: String? = if case .device(let id) = team { id } else { nil }
        let running = Running(
            device: device, endpoint: endpoint, team: teamID, fingerprint: product.fingerprint, startedAt: Date(), process: process, log: log)
        Task { [weak self] in
            _ = await process.waitForExit()
            await self?.exited(device.udid, process: process, log: log)
        }
        return running
    }

    private func exited(_ udid: String, process: any BackgroundProcess, log: URL) {
        guard let running = agents[udid], running.process === process else { return }
        agents[udid] = nil
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        exits[udid] = AgentFailure.explainStart(text) ?? "The UI agent stopped (log: \(log.path))."
    }

    private func stop(_ running: Running) async {
        _ = try? await AgentClient(endpoint: running.endpoint).request("POST", "/stop", timeout: .seconds(5))
        guard let process = running.process else { return }
        for _ in 0..<20 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(500))
        }
        if process.isRunning { process.terminate() }
    }

    // MARK: Team

    private var savedTeamFile: URL? { paths?.cache.appendingPathComponent("team") }

    private func saveTeam(_ team: String) {
        guard let file = savedTeamFile else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(team.utf8).write(to: file)
    }

    /// The team that signs the agent: asked for, the server's default, the one used last, or the only team
    /// signed in to Xcode.
    public func resolveTeam(_ requested: String?) async throws -> String {
        if let requested { return requested }
        if let defaultTeam { return defaultTeam }
        if let file = savedTeamFile, let saved = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            return saved
        }
        let teams = await DevelopmentTeam.xcodeTeams(runner: runner)
        switch teams.count {
        case 0:
            throw ISimError.notFound("No development team to sign the UI agent with. Sign in to Xcode → Settings → Accounts "
                + "with an Apple ID (a free one works: its Personal Team signs the agent), or pass team_id to ui_agent.")
        case 1:
            return teams[0].id
        default:
            let list = teams.map { "\($0.id) (\($0.name)\($0.isPersonal ? "; its profiles last 7 days" : ""))" }
            throw ISimError.invalidArgument("Several development teams can sign the UI agent. Call ui_agent with action=start "
                + "and team_id set to one of: \(list.joined(separator: ", ")). The choice is remembered.")
        }
    }

    // MARK: Helpers

    struct Status: Sendable {
        var version: Int
        var fingerprint: String
    }

    static func status(_ endpoint: AgentEndpoint) async throws -> Status {
        let data = try await AgentClient(endpoint: endpoint).request("GET", "/status", timeout: .seconds(3))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return Status(version: json["version"] as? Int ?? 0, fingerprint: json["build"] as? String ?? "")
    }

    /// A port nothing on this Mac listens on, for an agent in a simulator.
    static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw ISimError.commandFailed(command: "bind", message: String(cString: strerror(errno))) }
        return UInt16(bigEndian: address.sin_port)
    }
}

/// Simulators whose UI tools go to the agent rather than SimBridge: those `ui_agent start` was called for.
/// The router reads it synchronously.
public final class AgentRouting: @unchecked Sendable {
    private let lock = NSLock()
    private var simulators: Set<String> = []

    public init() {}

    public func usesAgent(_ udid: String) -> Bool {
        lock.withLock { simulators.contains(udid) }
    }

    func setAgent(_ on: Bool, for udid: String) {
        lock.withLock {
            if on { simulators.insert(udid) } else { simulators.remove(udid) }
        }
    }
}
