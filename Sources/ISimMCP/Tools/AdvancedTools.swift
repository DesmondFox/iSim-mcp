import DeviceCore
import Foundation
import MCP
import ProcessKit

/// Escape hatches, off by default: the CLIs with any arguments, Darwin notifications, processes inside a simulator.
enum AdvancedTools {
    static let all: [ToolDefinition] = [simctlRaw, devicectlRaw, postDarwinNotification, spawnProcess]

    /// Output beyond this is cut to keep the answer small.
    static let outputLimit = 50_000

    static let simctlRaw = ToolDefinition(
        name: "simctl_raw",
        toolset: .advanced,
        description: """
            Run `xcrun simctl` with any arguments, for what the other tools do not cover. Arguments are passed as they are \
            (no shell); put the device UDID where simctl expects it. Can erase or delete simulators.
            """,
        inputSchema: Schema.object([
            "args": Schema.stringArray("Arguments after `simctl`, e.g. [\"ui\", \"<udid>\", \"appearance\"]."),
            "timeout_ms": Schema.integer("Kill the command after this long.", default: 60_000, minimum: 1000, maximum: 600_000),
        ], required: ["args"]),
        annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
    ) { arguments, context in
        try context.requireXcode()
        return try await raw("simctl", arguments, context: context)
    }

    static let devicectlRaw = ToolDefinition(
        name: "devicectl_raw",
        toolset: .advanced,
        description: """
            Run `xcrun devicectl` with any arguments, for simulators and iPhones. Add `--json-output -` for machine-readable \
            output. Arguments are passed as they are (no shell). On a personal iPhone, mind what the command changes.
            """,
        inputSchema: Schema.object([
            "args": Schema.stringArray("Arguments after `devicectl`, e.g. [\"device\", \"info\", \"details\", \"--device\", \"<udid>\"]."),
            "timeout_ms": Schema.integer("Kill the command after this long.", default: 60_000, minimum: 1000, maximum: 600_000),
        ], required: ["args"]),
        annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
    ) { arguments, context in
        try context.requireXcode()
        return try await raw("devicectl", arguments, context: context)
    }

    static func raw(_ tool: String, _ arguments: ToolArguments, context: ToolContext) async throws -> CallTool.Result {
        let args = try arguments.stringArray("args")
        guard !args.isEmpty else { throw ISimError.invalidArgument("`args` must list at least one argument.") }
        let timeout = Duration.milliseconds(try arguments.int("timeout_ms", default: 60_000, range: 1000...600_000))
        let result = try await context.runner.run("/usr/bin/xcrun", [tool] + args, timeout: timeout)
        return report(result, command: ([tool] + args).joined(separator: " "))
    }

    /// Exit status, stdout and stderr; a failure is an error result.
    static func report(_ result: ProcessResult, command: String) -> CallTool.Result {
        var parts = ["$ \(command)", "exit status \(result.exitCode)"]
        for (name, text) in [("stdout", result.stdoutString), ("stderr", result.stderrString)] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            parts.append("\(name):\n" + (trimmed.count > outputLimit ? String(trimmed.prefix(outputLimit)) + "\n… [cut: \(trimmed.count) characters]" : trimmed))
        }
        let text = parts.joined(separator: "\n")
        return result.succeeded ? .text(text) : .error(text)
    }

    static let postDarwinNotification = ToolDefinition(
        name: "post_darwin_notification",
        toolset: .advanced,
        description: """
            Post a Darwin notification (notify_post) on the device: a system-wide signal by name that apps observe with \
            CFNotificationCenterGetDarwinNotifyCenter, e.g. to trigger a debug action. Not a push notification.
            """,
        inputSchema: Schema.deviceObject([
            "name": Schema.string("Notification name, e.g. com.example.app.reload-config."),
        ], required: ["name"]),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        let name = try arguments.requiredString("name")
        let device = try await context.session.resolveReady(try arguments.device)
        try await context.router.backend(.darwinNotification, for: device, as: (any DarwinNotificationPosting).self)
            .postDarwinNotification(udid: device.udid, name: name)
        return .text("Posted \(name) on \"\(device.name)\".")
    }

    static let spawnProcess = ToolDefinition(
        name: "spawn_process",
        toolset: .advanced,
        description: """
            Run a command-line program inside a simulator and return its output: defaults, launchctl, notifyutil, log, \
            plutil or a binary of your own (absolute path on the Mac). Simulators only.
            """,
        inputSchema: Schema.deviceObject([
            "executable": Schema.string("Program name on the simulator's PATH, or an absolute path."),
            "args": Schema.stringArray("Its arguments."),
            "timeout_ms": Schema.integer("Kill it after this long.", default: 30_000, minimum: 1000, maximum: 600_000),
        ], required: ["executable"]),
        annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
    ) { arguments, context in
        try context.requireXcode()
        let executable = try arguments.requiredString("executable")
        let args = try arguments.stringArray("args")
        let timeout = Duration.milliseconds(try arguments.int("timeout_ms", default: 30_000, range: 1000...600_000))
        let device = try await context.session.resolveReady(try arguments.device)
        let result = try await context.router.backend(.spawn, for: device, as: (any ProcessSpawning).self)
            .spawn(udid: device.udid, executable: executable, arguments: args, timeout: timeout)
        return report(result, command: ([executable] + args).joined(separator: " "))
    }
}
