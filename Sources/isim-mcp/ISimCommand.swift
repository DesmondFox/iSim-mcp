import APNsBackend
import ArgumentParser
import DeviceCore
import Foundation
import ISimMCP
import LockdownBackend
import Logging

@main
struct ISimCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "isim-mcp",
        abstract: "MCP server for iOS simulators and physical iPhones/iPads (stdio transport).",
        version: ISimServer.version
    )

    /// `device-log` is plumbing for the logs tools: dispatched here so the server's usage text stays as it is.
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == DeviceLogCommand.configuration.commandName {
            DeviceLogCommand.main(Array(arguments.dropFirst()))
        } else {
            await main(arguments)
        }
    }

    @Option(help: "Comma-separated toolsets to enable, or `all`. core is always on. Available: \(Toolset.allCases.map(\.rawValue).joined(separator: ", ")).")
    var toolsets: String = Toolset.defaults.sorted().map(\.rawValue).joined(separator: ",")

    @Option(help: "Log level for stderr: trace, debug, info, notice, warning, error, critical.")
    var logLevel: Logger.Level = .info

    @Option(help: "Apple development team ID that signs the UI agent for iPhones (default: ISIM_TEAM_ID, the team used last, or the only team in Xcode).")
    var teamId: String?

    @Option(help: "APNs auth key (.p8) for send_push mode=apns (default: ISIM_APNS_KEY_PATH). Needs --apns-key-id and a team ID.")
    var apnsKeyPath: String?

    @Option(help: "Key ID of the APNs auth key (default: ISIM_APNS_KEY_ID).")
    var apnsKeyId: String?

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
        let environment = ProcessInfo.processInfo.environment
        let team = teamId ?? environment["ISIM_TEAM_ID"]
        let apns = APNsCredentials.from(
            keyPath: apnsKeyPath ?? environment["ISIM_APNS_KEY_PATH"], keyID: apnsKeyId ?? environment["ISIM_APNS_KEY_ID"], teamID: team)
        let logger = Logger(label: "isim-mcp")
        if apns == nil && (apnsKeyPath ?? environment["ISIM_APNS_KEY_PATH"]) != nil {
            logger.warning("APNs key given without a key ID or team ID; send_push mode=apns stays off.")
        }
        try await ISimServer.run(toolsets: enabled, teamID: team, apns: apns, logger: logger)
    }
}

/// What start_log_capture and query_logs run for an iPhone: the device talk happens in this child process.
struct DeviceLogCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device-log",
        abstract: "Stream an iPhone's unified log to stdout, or download its log archive (used by the logs tools)."
    )

    @Option(help: "The iPhone's UDID.")
    var udid: String

    @Option(help: "An app: entries of its process (--executable) or of its bundle id as subsystem.")
    var bundleId: String?

    @Option(help: "The app's executable name; defaults to the bundle id.")
    var executable: String?

    @Option(help: "Entries of the process with this executable name.")
    var process: String?

    @Option(help: "Entries of this os_log subsystem.")
    var subsystem: String?

    @Option(help: "An NSPredicate as `log` takes it.")
    var predicate: String?

    @Option(help: "Lowest level to include: default, info or debug.")
    var level: String = "debug"

    @Option(help: "Instead of streaming, unpack the log archive into this directory (a .logarchive for `log show`).")
    var archive: String?

    @Option(help: "With --archive: seconds back the archive has to reach.")
    var last: Int = 300

    func run() throws {
        // A stream's reader may go away; the write then fails instead of killing the process.
        signal(SIGPIPE, SIG_IGN)
        do {
            if let archive {
                try DeviceLog.archive(udid: udid, last: TimeInterval(last), into: URL(fileURLWithPath: archive))
                return
            }
            guard let level = LogFilter.Level(rawValue: level) else { throw ValidationError("--level must be default, info or debug.") }
            var filter = LogFilter(process: process, subsystem: subsystem, predicate: predicate, level: level)
            if let bundleId { filter.app = (bundleId, executable ?? bundleId) }
            try DeviceLog.stream(udid: udid, filter: filter, to: .standardOutput)
        } catch let error as LockdownError {
            FileHandle.standardError.write(Data("isim-mcp: \(error)\n".utf8))
            throw ExitCode.failure
        }
    }
}

extension Logger.Level: @retroactive ExpressibleByArgument {}
