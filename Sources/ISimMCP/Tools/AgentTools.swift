import AgentBackend
import DeviceCore
import Foundation
import MCP

/// The on-device UI agent (Agent/): an XCUITest runner that serves the UI tools on iPhones.
enum AgentTools {
    static let all: [ToolDefinition] = [uiAgent]

    enum Action: String, CaseIterable {
        case status
        case start
        case stop
    }

    static let uiAgent = ToolDefinition(
        name: "ui_agent",
        toolset: .core,
        description: """
            The UI agent: an XCUITest runner on the device that serves describe_ui, tap, type_text and the other UI tools \
            on iPhones. The first UI tool builds and starts it (about 10 s, plus up to a minute to build the first time). \
            status shows it; start starts it ahead of time, with team_id choosing the development team that signs it \
            and rebuild=true building it anew; stop ends it. On a simulator, start moves its UI tools from the built-in \
            simulator bridge to the agent (a fallback if the bridge breaks) and stop moves them back.
            """,
        inputSchema: Schema.deviceObject([
            "action": Schema.string("What to do; default status.", enum: Action.allCases.map(\.rawValue)),
            "team_id": Schema.string("Apple development team ID that signs the agent for iPhones, e.g. AB12CD34EF; remembered."),
            "rebuild": Schema.bool("Build the agent again before starting it.", default: false),
        ]),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        let action = try arguments.choice("action", default: Action.status)
        let team = try arguments.string("team_id")?.trimmingCharacters(in: .whitespaces)
        let rebuild = try arguments.bool("rebuild", default: false)
        let device = try await context.session.resolveReady(try arguments.device)
        let agent = context.agent

        switch action {
        case .status:
            return .text(await status(device, context: context))
        case .start:
            let report = try await agent.start(device, team: team, rebuild: rebuild)
            let seconds = String(format: "%.0f s", report.seconds)
            var text = report.reused
                ? "The UI agent is running on \"\(device.name)\"" + (report.seconds > 0 ? " (taken over from an earlier session)." : ".")
                : "Started the UI agent on \"\(device.name)\" in \(seconds)" + (report.built ? ", building it first." : ".")
            if let team = report.running.team { text += " Signed by team \(team)." }
            if device.kind == .simulator { text += " UI tools on this simulator now go through the agent; ui_agent stop moves them back." }
            return .text(text)
        case .stop:
            let stopped = await agent.stop(device)
            var text = stopped ? "Stopped the UI agent on \"\(device.name)\"." : "No UI agent was running on \"\(device.name)\"."
            if device.kind == .simulator { text += " UI tools on this simulator use the built-in simulator bridge." }
            return .text(text)
        }
    }

    static func status(_ device: Device, context: ToolContext) async -> String {
        let agent = context.agent
        var lines: [String] = []
        if let running = await agent.running(device.udid) {
            let minutes = Int(-running.startedAt.timeIntervalSinceNow / 60)
            lines.append("UI agent on \"\(device.name)\": running for \(minutes) min at \(running.endpoint), build \(running.fingerprint)"
                + (running.team.map { ", team \($0)" } ?? "") + ".")
            if let log = running.log { lines.append("Log: \(log.path)") }
        } else {
            lines.append("UI agent on \"\(device.name)\": not running" + (device.kind == .physical ? "; the first UI tool starts it." : "."))
            if let exit = await agent.lastExit(device.udid) { lines.append("It last stopped on its own: \(exit)") }
        }
        if device.kind == .simulator {
            lines.append(agent.routing.usesAgent(device.udid)
                ? "UI tools on this simulator go through the agent."
                : "UI tools on this simulator use the built-in simulator bridge; ui_agent start switches them to the agent.")
        } else {
            do {
                lines.append("Signing team: \(try await agent.resolveTeam(nil)).")
            } catch {
                lines.append("Signing team: \(error)")
            }
        }
        lines.append(await agent.sourceDirectory.map { "Agent project: \($0.path)" }
            ?? "The agent's Xcode project was not found: set ISIM_AGENT_SOURCE or reinstall with make install.")
        return lines.joined(separator: "\n")
    }
}
