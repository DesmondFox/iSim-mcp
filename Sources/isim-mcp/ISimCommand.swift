import ArgumentParser
import Foundation
import ISimMCP
import Logging

@main
struct ISimCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "isim-mcp",
        abstract: "MCP server for iOS simulators and physical iPhones/iPads (stdio transport).",
        version: ISimServer.version
    )

    @Option(help: "Comma-separated toolsets to enable, or `all`. core is always on. Available: \(Toolset.allCases.map(\.rawValue).joined(separator: ", ")).")
    var toolsets: String = Toolset.defaults.sorted().map(\.rawValue).joined(separator: ",")

    @Option(help: "Log level for stderr: trace, debug, info, notice, warning, error, critical.")
    var logLevel: Logger.Level = .info

    @Option(help: "Apple development team ID that signs the UI agent for iPhones (default: ISIM_TEAM_ID, the team used last, or the only team in Xcode).")
    var teamId: String?

    @Flag(help: "Print the enabled tools and exit.")
    var listTools = false

    mutating func run() async throws {
        let enabled: Set<Toolset>
        do {
            enabled = try Toolset.parse(toolsets)
        } catch {
            throw ValidationError(error.description)
        }

        if listTools {
            for tool in ISimServer.makeRegistry(toolsets: enabled).tools {
                print("\(tool.name): \(tool.description ?? "")")
            }
            return
        }

        // stdout belongs to JSON-RPC; everything else goes to stderr.
        let level = logLevel
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = level
            return handler
        }
        let team = teamId ?? ProcessInfo.processInfo.environment["ISIM_TEAM_ID"]
        try await ISimServer.run(toolsets: enabled, teamID: team, logger: Logger(label: "isim-mcp"))
    }
}

extension Logger.Level: @retroactive ExpressibleByArgument {}
