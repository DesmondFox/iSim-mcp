import AgentBackend
import DeviceCore
import Foundation
import Logging
import MCP
import ProcessKit

public enum ISimServer {
    public static let name = "isim-mcp"
    public static let version = "0.1.0"

    static let instructions = """
        Controls iOS simulators and physical iPhones/iPads connected to this Mac.
        Device selection: every device tool takes an optional `device` (UDID or name); without it the active device \
        (set_active_device) or the only booted simulator / connected iPhone is used.
        Typical flow: list_devices → boot_device (simulator) → install_app → launch_app → screenshot.
        Preparing screenshots: configure_ui (appearance), override_status_bar (preset=screenshot), set_location, \
        set_permission — these are in the `system` toolset.
        Driving an app: describe_ui shows the screen's elements; tap, type_text and swipe take an `element` \
        selector (identifier or label from describe_ui) or coordinates; wait_for waits for the next screen; \
        handle_system_alert answers permission prompts. On an iPhone these go through an XCUITest agent that the first \
        UI tool builds and starts (ui_agent shows it); keep the iPhone unlocked.
        Coordinates for UI tools are in points; screenshot reports how image pixels map to points.
        If anything fails, call doctor.
        """

    public static func allTools() -> [ToolDefinition] {
        CoreTools.all + AgentTools.all + DeviceTools.all + AppTools.all + ScreenTools.all + UITools.all + SystemTools.all
    }

    public static func makeRegistry(toolsets: Set<Toolset>) -> ToolRegistry {
        ToolRegistry(definitions: allTools(), enabledToolsets: toolsets)
    }

    /// `teamID` signs the UI agent for iPhones.
    public static func makeContext(teamID: String? = nil) -> ToolContext {
        let xcode = Result { () throws(ISimError) in try XcodeEnvironment.detect() }
        let runner = ProcessRunner(baseEnvironment: (try? xcode.get())?.childEnvironment ?? [:])
        return ToolContext(runner: runner, xcode: xcode, teamID: teamID)
    }

    /// Serves MCP over stdio until the client closes the connection. UI agents started meanwhile stop with it.
    public static func run(toolsets: Set<Toolset>, teamID: String?, logger: Logger) async throws {
        let registry = makeRegistry(toolsets: toolsets)
        let context = makeContext(teamID: teamID)
        let signals = stopAgentsOnSignals(context.agent)
        defer { signals.forEach { $0.cancel() } }
        switch context.xcode {
        case .success(let xcode):
            logger.info("Using Xcode \(xcode.version) at \(xcode.developerDir)")
        case .failure(let error):
            logger.warning("\(error.description)")
        }
        logger.info("Toolsets: \(registry.enabledToolsets.sorted().map(\.rawValue).joined(separator: ",")); \(registry.tools.count) tools")

        let server = Server(
            name: name,
            version: version,
            title: "iSim MCP",
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: registry.tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            let clock = ContinuousClock()
            let start = clock.now
            let result = try await registry.call(params.name, arguments: params.arguments, context: context)
            let elapsed = String(format: "%.2f", (clock.now - start).inSeconds)
            logger.debug("\(params.name) finished in \(elapsed) s\(result.isError == true ? " with error" : "")")
            return result
        }

        try await server.start(transport: StdioTransport(logger: logger))
        await server.waitUntilCompleted()
        await context.agent.stopAll()
    }

    /// A client that ends the server with SIGTERM or SIGINT would leave agents running on devices.
    private static func stopAgentsOnSignals(_ agent: AgentManager) -> [any DispatchSourceSignal] {
        [SIGTERM, SIGINT].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                Task {
                    await agent.stopAll()
                    exit(128 + number)
                }
            }
            source.resume()
            return source
        }
    }
}
