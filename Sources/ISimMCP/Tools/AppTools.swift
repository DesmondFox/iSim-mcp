import DeviceCore
import Foundation
import MCP

enum AppTools {
    static let all: [ToolDefinition] = [
        listApps, getAppInfo, installApp, uninstallApp, launchApp, terminateApp, openURL, listProcesses, getAppContainer,
        sendMemoryWarning,
    ]

    static let listApps = ToolDefinition(
        name: "list_apps",
        toolset: .apps,
        description: "List installed apps: bundle id, name, version (build). By default only apps you installed for development.",
        inputSchema: Schema.deviceObject([
            "include_system": Schema.bool("Also list built-in apps (and App Store apps on an iPhone).", default: false),
        ]),
        annotations: .readOnly
    ) { arguments, context in
        try context.requireXcode()
        let device = try await context.session.resolveReady(try arguments.device)
        let apps = try await context.router.backend(.listApps, for: device, as: (any AppManaging).self)
            .listApps(udid: device.udid, includeSystem: try arguments.bool("include_system", default: false))
        guard !apps.isEmpty else {
            return .text("No apps installed on \"\(device.name)\" besides built-in ones. Use include_system to list those.")
        }
        let lines = apps.map { app in
            var line = app.bundleId
            if let name = app.name { line += " — \(name)" }
            if let version = app.version { line += " \(version)" + (app.build.map { " (\($0))" } ?? "") }
            if app.type == "system" { line += " [system]" }
            return line
        }
        return .text(lines.joined(separator: "\n"))
    }

    static let installApp = ToolDefinition(
        name: "install_app",
        toolset: .apps,
        description: """
            Install an .app bundle or .ipa from the Mac. Simulators need a simulator build; \
            iPhones need a device build signed for that device.
            """,
        inputSchema: Schema.deviceObject([
            "path": Schema.string("Absolute path to the .app or .ipa on the Mac."),
        ], required: ["path"]),
        annotations: .idempotent
    ) { arguments, context in
        try context.requireXcode()
        let device = try await context.session.resolveReady(try arguments.device)
        let path = (try arguments.requiredString("path") as NSString).expandingTildeInPath
        let backend = try context.router.backend(.installApp, for: device, as: (any AppManaging).self)

        let bundle = try await AppBundleInfo.read(path: path, runner: context.runner)
        try checkPlatform(bundle, device: device)
        try await backend.install(udid: device.udid, path: path)

        let name = [bundle.name, bundle.version].compactMap(\.self).joined(separator: " ")
        return .text("Installed \(bundle.bundleId)\(name.isEmpty ? "" : " (\(name))") on \"\(device.name)\". Start it with launch_app.")
    }

    static let uninstallApp = ToolDefinition(
        name: "uninstall_app",
        toolset: .apps,
        description: "Uninstall an app and delete its data.",
        inputSchema: Schema.deviceObject([
            "bundle_id": Schema.string("Bundle identifier of the app."),
        ], required: ["bundle_id"]),
        annotations: .destructive
    ) { arguments, context in
        try context.requireXcode()
        let device = try await context.session.resolveReady(try arguments.device)
        let bundleId = try arguments.requiredString("bundle_id")
        try await context.router.backend(.uninstallApp, for: device, as: (any AppManaging).self)
            .uninstall(udid: device.udid, bundleId: bundleId)
        return .text("Uninstalled \(bundleId) from \"\(device.name)\".")
    }

    static let launchApp = ToolDefinition(
        name: "launch_app",
        toolset: .apps,
        description: """
            Launch an app. By default a running instance is terminated first, so the app starts fresh. \
            capture_output keeps the app's stdout and stderr (print, NSLog to stderr) in a job that read_log_capture reads \
            (logs toolset); stopping that job terminates the app.
            """,
        inputSchema: Schema.deviceObject([
            "bundle_id": Schema.string("Bundle identifier of the app."),
            "args": Schema.stringArray("Command-line arguments for the app (e.g. -FeatureFlag YES)."),
            "env": Schema.stringMap("Environment variables for the app."),
            "terminate_existing": Schema.bool("Terminate a running instance before launching.", default: true),
            "start_stopped": Schema.bool("Start suspended, waiting for a debugger to attach.", default: false),
            "capture_output": Schema.bool("Capture the app's stdout and stderr in a job until the app exits.", default: false),
        ], required: ["bundle_id"]),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        let device = try await context.session.resolveReady(try arguments.device)
        let bundleId = try arguments.requiredString("bundle_id")
        let options = LaunchOptions(
            arguments: try arguments.stringArray("args"),
            environment: try arguments.stringMap("env"),
            terminateExisting: try arguments.bool("terminate_existing", default: true),
            startStopped: try arguments.bool("start_stopped", default: false)
        )
        let backend = try context.router.backend(.launchApp, for: device, as: (any AppManaging).self)
        // Apps load accessibility at launch; with it on, UI tools can read this app.
        await context.accessibility.prepare(device)
        if try arguments.bool("capture_output", default: false) {
            let console = try context.router.backend(.consoleCapture, for: device, as: (any ConsoleLaunching).self)
            let job = try await context.jobs.start(
                .console, command: console.consoleCommand(udid: device.udid, bundleId: bundleId, options: options), device: device,
                title: "output of \(bundleId)")
            // A failed launch ends the command at once; a running app keeps it going.
            try await Task.sleep(for: consoleSettleTime)
            guard try await context.jobs.job(job.id).isRunning else {
                let output = try await context.jobs.read(job.id, maxLines: 20).lines
                throw ISimError.commandFailed(command: "launch_app", message: output.isEmpty ? "the launch ended right away" : output.joined(separator: " "))
            }
            let processes = try? await context.router.backend(.listProcesses, for: device, as: (any AppInspecting).self).listProcesses(udid: device.udid)
            let pid = processes?.first { $0.bundleId == bundleId }?.pid
            return .text("Launched \(bundleId)\(pid.map { " (pid \($0))" } ?? "") on \"\(device.name)\" with its stdout and stderr going to "
                + "job \(job.id). Read them with read_log_capture(job_id: \"\(job.id)\"); stop_log_capture ends the capture and terminates the app.")
        }
        let pid = try await backend.launch(udid: device.udid, bundleId: bundleId, options: options)
        return .text("Launched \(bundleId)\(pid.map { " (pid \($0))" } ?? "") on \"\(device.name)\".")
    }

    /// How long a launch with captured output may take to fail.
    static let consoleSettleTime = Duration.seconds(1)

    static let sendMemoryWarning = ToolDefinition(
        name: "send_memory_warning",
        toolset: .apps,
        description: """
            Simulate a memory warning, as when the system runs low on memory: apps get didReceiveMemoryWarning and should free \
            caches. On a simulator every app gets it; on an iPhone only the app given by bundle_id or pid.
            """,
        inputSchema: Schema.deviceObject([
            "bundle_id": Schema.string("App to warn (iPhone); its main process must be running."),
            "pid": Schema.integer("Process to warn instead of bundle_id (iPhone).", minimum: 1),
        ]),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        let bundleId = try arguments.string("bundle_id").flatMap { $0.isEmpty ? nil : $0 }
        var pid = try arguments.int("pid")
        let device = try await context.session.resolveReady(try arguments.device)
        let sender = try context.router.backend(.memoryWarning, for: device, as: (any MemoryWarningSending).self)
        guard device.kind == .physical else {
            try await sender.sendMemoryWarning(udid: device.udid, pid: nil)
            return .text("Sent a memory warning to every app on \"\(device.name)\".")
        }
        if pid == nil {
            guard let bundleId else { throw ISimError.invalidArgument("Pass `bundle_id` or `pid`: on an iPhone the warning goes to one process.") }
            let processes = try await context.router.backend(.listProcesses, for: device, as: (any AppInspecting).self).listProcesses(udid: device.udid)
            guard let process = processes.first(where: { $0.bundleId == bundleId }) else {
                throw ISimError.notFound("\(bundleId) is not running on \"\(device.name)\". Start it with launch_app first.")
            }
            pid = process.pid
        }
        try await sender.sendMemoryWarning(udid: device.udid, pid: pid)
        return .text("Sent a memory warning to \(bundleId ?? "process") (pid \(pid!)) on \"\(device.name)\".")
    }

    static let terminateApp = ToolDefinition(
        name: "terminate_app",
        toolset: .apps,
        description: "Terminate a running app.",
        inputSchema: Schema.deviceObject([
            "bundle_id": Schema.string("Bundle identifier of the app."),
        ], required: ["bundle_id"]),
        annotations: .idempotent
    ) { arguments, context in
        try context.requireXcode()
        let device = try await context.session.resolveReady(try arguments.device)
        let bundleId = try arguments.requiredString("bundle_id")
        let outcome = try await context.router.backend(.terminateApp, for: device, as: (any AppManaging).self)
            .terminate(udid: device.udid, bundleId: bundleId)
        switch outcome {
        case .terminated(let pid):
            return .text("Terminated \(bundleId)\(pid.map { " (pid \($0))" } ?? "") on \"\(device.name)\".")
        case .notRunning:
            return .text("\(bundleId) was not running on \"\(device.name)\".")
        }
    }

    static let openURL = ToolDefinition(
        name: "open_url",
        toolset: .apps,
        description: "Open a URL on the device: deep link (myapp://…), universal link or web page.",
        inputSchema: Schema.deviceObject([
            "url": Schema.string("URL with a scheme, e.g. myapp://profile/42 or https://example.com."),
        ], required: ["url"]),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        let url = try arguments.requiredString("url")
        guard let scheme = URLComponents(string: url)?.scheme, !scheme.isEmpty else {
            throw ISimError.invalidArgument("`url` must include a scheme, e.g. https://example.com or myapp://path.")
        }
        let device = try await context.session.resolveReady(try arguments.device)
        try await context.router.backend(.openURL, for: device, as: (any AppManaging).self)
            .openURL(udid: device.udid, url: url)
        return .text("Opened \(url) on \"\(device.name)\".")
    }

    static let getAppInfo = ToolDefinition(
        name: "get_app_info",
        toolset: .apps,
        description: """
            Details of an installed app: version, bundle and data container paths, app groups, \
            and entitlements (simulator builds only). On an iPhone the paths are on the device.
            """,
        inputSchema: Schema.deviceObject([
            "bundle_id": Schema.string("Bundle identifier of the app."),
        ], required: ["bundle_id"]),
        annotations: .readOnly
    ) { arguments, context in
        try context.requireXcode()
        let device = try await context.session.resolveReady(try arguments.device)
        let bundleId = try arguments.requiredString("bundle_id")
        let details = try await context.router.backend(.appInfo, for: device, as: (any AppInspecting).self)
            .appInfo(udid: device.udid, bundleId: bundleId)
        return .text(describe(details).joined(separator: "\n"))
    }

    static func describe(_ details: AppDetails) -> [String] {
        let app = details.app
        var title = app.bundleId
        if let name = app.name { title += " — \(name)" }
        if let version = app.version { title += " \(version)" + (app.build.map { " (\($0))" } ?? "") }
        title += ", " + ([app.type == "user" ? "user app" : "system app"] + details.flags).joined(separator: ", ")
        var lines = [title]
        // devicectl reports bundle URLs, simctl paths.
        if let path = app.path { lines.append("Bundle: " + (path.hasPrefix("file://") ? URL(string: path)?.path ?? path : path)) }
        if let data = details.dataContainer { lines.append("Data: \(data)") }
        for group in details.appGroups {
            lines.append("App group \(group.identifier)" + (group.path.map { ": \($0)" } ?? ""))
        }
        if let entitlements = details.entitlementsJSON { lines.append("Entitlements: \(entitlements)") }
        return lines
    }

    static let listProcesses = ToolDefinition(
        name: "list_processes",
        toolset: .apps,
        description: "List running processes with pid; app processes show their bundle id. By default only apps.",
        inputSchema: Schema.deviceObject([
            "name_contains": Schema.string("Case-insensitive substring of the name, bundle id or path."),
            "apps_only": Schema.bool("Only app processes; false adds daemons and other system processes.", default: true),
        ]),
        annotations: .readOnly
    ) { arguments, context in
        try context.requireXcode()
        let device = try await context.session.resolveReady(try arguments.device)
        let filter = try arguments.string("name_contains")
        let appsOnly = try arguments.bool("apps_only", default: true)
        let processes = try await context.router.backend(.listProcesses, for: device, as: (any AppInspecting).self)
            .listProcesses(udid: device.udid)
            .filter { process in
                (!appsOnly || process.bundleId != nil)
                    && (filter == nil || [process.name, process.bundleId, process.path].contains { $0?.localizedCaseInsensitiveContains(filter!) == true })
            }
        guard !processes.isEmpty else {
            return .text(filter == nil ? "No \(appsOnly ? "app " : "")processes are running on \"\(device.name)\"." : "No running process matches \"\(filter!)\".")
        }
        let lines = processes.map { process in
            var line = String(process.pid).padding(toLength: 7, withPad: " ", startingAt: 0) + (process.bundleId ?? process.name)
            if process.bundleId != nil && process.name != process.bundleId { line += " (\(process.name))" }
            if process.bundleId == nil, let path = process.path { line += " — \(path)" }
            return line
        }
        return .text(lines.joined(separator: "\n"))
    }

    static let getAppContainer = ToolDefinition(
        name: "get_app_container",
        toolset: .apps,
        description: "Path on this Mac to a simulator app's bundle, data container (Documents, Library, tmp) or app group container. Simulators only.",
        inputSchema: Schema.deviceObject([
            "bundle_id": Schema.string("Bundle identifier of the app."),
            "container": Schema.string("app (the .app bundle), data, groups (all app groups) or an app group identifier. Default: data."),
        ], required: ["bundle_id"]),
        annotations: .readOnly
    ) { arguments, context in
        try context.requireXcode()
        let device = try await context.session.resolveReady(try arguments.device)
        let bundleId = try arguments.requiredString("bundle_id")
        let container = try arguments.string("container").flatMap { $0.isEmpty ? nil : $0 } ?? "data"
        let path = try await context.router.backend(.appContainer, for: device, as: (any AppContainerLocating).self)
            .containerPath(udid: device.udid, bundleId: bundleId, container: container)
        return .text(path)
    }

    /// Catches the most common mistake early: a simulator build for an iPhone or vice versa.
    private static func checkPlatform(_ bundle: AppBundleInfo, device: Device) throws(ISimError) {
        guard !bundle.platforms.isEmpty else { return }
        let needed = device.kind == .simulator ? "iPhoneSimulator" : "iPhoneOS"
        guard !bundle.platforms.contains(needed) else { return }
        let builtFor = bundle.platforms.joined(separator: ", ")
        throw .invalidArgument(device.kind == .simulator
            ? "\(bundle.bundleId) is built for \(builtFor), not for the simulator. Build it with an iOS Simulator destination."
            : "\(bundle.bundleId) is built for \(builtFor), not for a physical device. Build it for 'Any iOS Device' and sign it with your team.")
    }
}
