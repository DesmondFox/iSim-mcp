import DeviceCore
import Foundation
import MCP
import ProcessKit
import SimctlBackend

enum DeviceTools {
    static let all: [ToolDefinition] = [
        listDevices, bootDevice, shutdownDevice, rebootDevice, openSimulatorApp, listRuntimes, createDevice, eraseDevice, deleteDevice,
    ]

    static let listDevices = ToolDefinition(
        name: "list_devices",
        toolset: .devices,
        description: """
            List iOS simulators and physical iPhones/iPads with UDID, kind, state, iOS version and model. \
            The active device is marked with *. Unavailable simulators (missing runtime) are hidden unless include_unavailable is true.
            """,
        inputSchema: Schema.object([
            "kind": Schema.string("Only this kind of device.", enum: DeviceKind.allCases.map(\.rawValue)),
            "state": Schema.string("Only devices in this state; `ready` means booted or connected.",
                                   enum: ["ready", "booted", "shutdown", "connected", "disconnected"]),
            "name_contains": Schema.string("Case-insensitive substring of the device name."),
            "include_unavailable": Schema.bool("Include simulators whose runtime is missing.", default: false),
        ]),
        annotations: .readOnly
    ) { arguments, context in
        try context.requireXcode()
        let kind: DeviceKind? = try arguments.string("kind").map { raw throws(ISimError) in
            guard let kind = DeviceKind(rawValue: raw) else { throw .invalidArgument("`kind` must be simulator or physical.") }
            return kind
        }
        let state = try arguments.string("state")?.lowercased()
        let nameContains = try arguments.string("name_contains")
        let includeUnavailable = try arguments.bool("include_unavailable", default: false)

        let listing = try await context.session.listDevices()
        let active = await context.session.activeUDID
        let filtered = listing.devices.filter { device in
            (includeUnavailable || device.isAvailable)
                && (kind == nil || device.kind == kind)
                && (state == nil || (state == "ready" ? device.state.isReady : device.state.rawValue == state))
                && (nameContains == nil || device.name.localizedCaseInsensitiveContains(nameContains!))
        }
        // Running devices first: they are what the next call most likely targets.
        let devices = filtered.filter(\.state.isReady) + filtered.filter { !$0.state.isReady }

        var lines = devices.map { device in
            var fields = [device.udid, device.kind.rawValue, device.state.rawValue]
            if let os = device.osVersion { fields.append("iOS \(os)") }
            if let model = device.model, !isRedundant(model: model, name: device.name) { fields.append(model) }
            if !device.isAvailable { fields.append("unavailable") }
            if let developerMode = device.developerMode, developerMode != "enabled" { fields.append("Developer Mode \(developerMode)") }
            let marker = device.udid == active ? "* " : "  "
            return marker + device.name + " — " + fields.joined(separator: ", ")
        }
        if lines.isEmpty { lines = ["No devices match the filters."] }
        lines += listing.warnings.map { "⚠ Partial list: \($0)" }
        return .text(lines.joined(separator: "\n"))
    }

    /// "iPad Pro 11 inch M5 12GB" adds nothing to the name "iPad Pro 11-inch (M5)".
    static func isRedundant(model: String, name: String) -> Bool {
        func normalized(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let (model, name) = (normalized(model), normalized(name))
        return model.hasPrefix(name) || name.hasPrefix(model)
    }

    static let bootDevice = ToolDefinition(
        name: "boot_device",
        toolset: .devices,
        description: "Boot a simulator and wait until it is fully ready (SpringBoard up). Simulators only.",
        inputSchema: Schema.deviceObject([
            "wait": Schema.bool("Wait for the boot to finish.", default: true),
            "open_simulator_app": Schema.bool("Also open Xcode's device window (DeviceHub) to watch the screen.", default: false),
        ]),
        annotations: .idempotent
    ) { arguments, context in
        try context.requireXcode()
        // Booting needs an explicit target: automatic selection only finds devices that are already running.
        let query = try arguments.device
        let activeUDID = await context.session.activeUDID
        guard query != nil || activeUDID != nil else {
            throw ISimError.invalidArgument("Pass `device` (simulator name or UDID) to boot. Use list_devices to see simulators.")
        }
        let device = try await context.session.resolve(query)
        let lifecycle = try context.router.backend(.boot, for: device, as: (any SimulatorLifecycle).self)

        let wait = try arguments.bool("wait", default: true)
        let openApp = try arguments.bool("open_simulator_app", default: false)
        let clock = ContinuousClock()
        let start = clock.now
        let wasBooted = device.state == .booted
        if !wasBooted {
            try await lifecycle.boot(udid: device.udid, wait: wait)
        }
        if wait || wasBooted {
            // Before any app starts, so UI tools can read every app on this simulator.
            await context.accessibility.prepare(device)
        }
        if openApp {
            _ = try? await context.runner.run("/usr/bin/open", ["-b", "com.apple.dt.Devices"], timeout: .seconds(15))
        }

        if wasBooted { return .text("\(device.summary) is already booted.") }
        let seconds = String(format: "%.1f s", (clock.now - start).inSeconds)
        return .text("Booted \"\(device.name)\" (\(device.udid)) in \(seconds)" + (wait ? "." : "; not waiting for SpringBoard."))
    }

    static let shutdownDevice = ToolDefinition(
        name: "shutdown_device",
        toolset: .devices,
        description: "Shut down a simulator, or all simulators with `all: true`. Simulators only.",
        inputSchema: Schema.deviceObject([
            "all": Schema.bool("Shut down every booted simulator.", default: false),
        ]),
        annotations: .idempotent
    ) { arguments, context in
        try context.requireXcode()
        if try arguments.bool("all", default: false) {
            try await context.simctl.shutdownAll()
            return .text("All simulators are shut down.")
        }
        let device = try await context.session.resolve(try arguments.device)
        let lifecycle = try context.router.backend(.shutdown, for: device, as: (any SimulatorLifecycle).self)
        if device.state == .shutdown { return .text("\(device.summary) is already shut down.") }
        try await lifecycle.shutdown(udid: device.udid)
        return .text("Shut down \"\(device.name)\" (\(device.udid)).")
    }

    static let rebootDevice = ToolDefinition(
        name: "reboot_device",
        toolset: .devices,
        description: """
            Reboot a simulator or an iPhone. A simulator is ready again when the call returns. \
            An iPhone stays locked after a restart until someone enters its passcode.
            """,
        inputSchema: Schema.deviceObject([
            "wait": Schema.bool("Wait until the device is back (for an iPhone, only when it is connected by cable).", default: true),
        ]),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        let device = try await context.session.resolveReady(try arguments.device)
        let backend = try context.router.backend(.reboot, for: device, as: (any DeviceRebooting).self)
        // devicectl can only wait for a device on a cable.
        let wait = try arguments.bool("wait", default: true) && (device.kind == .simulator || device.transport == "wired")

        let clock = ContinuousClock()
        let start = clock.now
        try await backend.reboot(udid: device.udid, wait: wait)
        let seconds = String(format: "%.1f s", (clock.now - start).inSeconds)
        switch device.kind {
        case .simulator:
            return .text("Rebooted \"\(device.name)\" in \(seconds)" + (wait ? "." : "; not waiting for SpringBoard."))
        case .physical:
            return .text("Rebooted \"\(device.name)\"" + (wait ? " in \(seconds)" : "; it takes a minute to come back")
                + ". Unlock it with the passcode before using screen and UI tools.")
        }
    }

    static let openSimulatorApp = ToolDefinition(
        name: "open_simulator_app",
        toolset: .devices,
        description: """
            Open Xcode's device window (DeviceHub, which replaced Simulator.app in Xcode 27) on a device, so a person can watch \
            its screen. A shut-down simulator is booted first.
            """,
        inputSchema: Schema.object([
            "device": Schema.string("Simulator or iPhone to show (UDID or name). Without it, DeviceHub opens as it was."),
        ]),
        annotations: .idempotent
    ) { arguments, context in
        try context.requireXcode()
        var device: Device?
        var booted = false
        if let query = try arguments.device {
            let resolved = try await context.session.resolve(query)
            if resolved.kind == .simulator && resolved.state != .booted {
                try await context.router.backend(.boot, for: resolved, as: (any SimulatorLifecycle).self).boot(udid: resolved.udid, wait: true)
                booted = true
            }
            device = resolved
        }
        let target = device.map { [$0.deviceHubURL] } ?? ["-b", "com.apple.dt.Devices"]
        let result = try await context.runner.run("/usr/bin/open", target, timeout: .seconds(15))
        guard result.succeeded else {
            throw ISimError.commandFailed(command: "open " + target.joined(separator: " "), message: result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let device else { return .text("Opened DeviceHub.") }
        return .text("Opened DeviceHub on \"\(device.name)\"" + (booted ? " after booting it." : "."))
    }

    static let listRuntimes = ToolDefinition(
        name: "list_runtimes",
        toolset: .devices,
        description: "List installed iOS simulator runtimes and the device types each supports: the values create_device accepts.",
        inputSchema: Schema.object([
            "include_device_types": Schema.bool("Also list supported device types.", default: true),
        ]),
        annotations: .readOnly
    ) { arguments, context in
        try context.requireXcode()
        let runtimes = try await context.simctl.listRuntimes()
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        guard !runtimes.isEmpty else {
            return .text("No iOS simulator runtimes are installed. Install one in Xcode → Settings → Components.")
        }
        var lines = runtimes.map { runtime in
            runtime.isAvailable
                ? "\(runtime.name) — \(runtime.identifier)" + (runtime.buildversion.map { " (build \($0))" } ?? "")
                : "⚠ \(runtime.name) — unavailable: \(runtime.availabilityError ?? "unknown reason")"
        }
        if try arguments.bool("include_device_types", default: true) {
            lines += describeDeviceTypes(runtimes.filter(\.isAvailable))
        }
        return .text(lines.joined(separator: "\n"))
    }

    /// Runtimes usually support the same device types, so identical lists are printed once.
    static func describeDeviceTypes(_ runtimes: [SimRuntime]) -> [String] {
        var groups: [(runtimes: [String], types: [SimDeviceType])] = []
        for runtime in runtimes {
            let types = runtime.supportedDeviceTypes ?? []
            if let index = groups.firstIndex(where: { $0.types == types }) {
                groups[index].runtimes.append(runtime.name)
            } else {
                groups.append(([runtime.name], types))
            }
        }
        var lines: [String] = []
        for group in groups where !group.types.isEmpty {
            lines.append("")
            lines.append("Device types for \(group.runtimes.joined(separator: ", ")):")
            let families = Dictionary(grouping: group.types) { $0.productFamily ?? "Other" }
            for family in families.keys.sorted(by: { (familyOrder($0), $0) < (familyOrder($1), $1) }) {
                lines.append("  \(family): " + families[family]!.map(\.name).joined(separator: ", "))
            }
        }
        return lines
    }

    private static func familyOrder(_ family: String) -> Int {
        ["iPhone": 0, "iPad": 1][family] ?? 2
    }

    static let createDevice = ToolDefinition(
        name: "create_device",
        toolset: .devices,
        description: "Create a new simulator. list_runtimes shows the device types and runtimes.",
        inputSchema: Schema.object([
            "device_type": Schema.string("Device type name or identifier, e.g. \"iPhone 16 Pro\"."),
            "runtime": Schema.string("Runtime: \"iOS 27.1\", \"27.1\" or an identifier. Default: the newest runtime that supports the device type."),
            "name": Schema.string("Name of the new simulator. Default: the device type name."),
            "boot": Schema.bool("Boot it right away and wait until it is ready.", default: false),
        ], required: ["device_type"]),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        let typeQuery = try arguments.requiredString("device_type")
        let runtimeQuery = try arguments.string("runtime")
        let runtimes = try await context.simctl.listRuntimes()
            .filter(\.isAvailable)
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        let (runtime, deviceType) = try resolveDeviceType(typeQuery, runtime: runtimeQuery, in: runtimes)

        let name = try arguments.string("name").flatMap { $0.isEmpty ? nil : $0 } ?? deviceType.name
        let existing = try? await context.session.listDevices().devices
        let udid = try await context.simctl.createDevice(name: name, deviceTypeId: deviceType.identifier, runtimeId: runtime.identifier)
        var text = "Created \"\(name)\" (\(udid)): \(deviceType.name), \(runtime.name)."
        if try arguments.bool("boot", default: false) {
            try await context.simctl.boot(udid: udid, wait: true)
            text += " It is booted."
        } else {
            text += " Boot it with boot_device."
        }
        if existing?.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) == true {
            text += " Another simulator has the same name: pass the UDID to other tools."
        }
        return .text(text)
    }

    /// Finds the device type among the runtime's supported types; without a runtime, takes the newest one supporting it.
    static func resolveDeviceType(_ typeQuery: String, runtime runtimeQuery: String?, in runtimes: [SimRuntime]) throws(ISimError) -> (SimRuntime, SimDeviceType) {
        func matches(_ type: SimDeviceType) -> Bool {
            type.name.caseInsensitiveCompare(typeQuery) == .orderedSame || type.identifier.caseInsensitiveCompare(typeQuery) == .orderedSame
        }
        var candidates = runtimes
        if let runtimeQuery {
            // "iOS 27.1", "iOS27.1", "27.1" or the identifier.
            let compact = runtimeQuery.replacingOccurrences(of: " ", with: "").lowercased()
            candidates = runtimes.filter {
                $0.identifier.lowercased() == compact || $0.name.replacingOccurrences(of: " ", with: "").lowercased() == compact
                    || $0.version == runtimeQuery
            }
            guard !candidates.isEmpty else {
                throw .invalidArgument("No available runtime matches \"\(runtimeQuery)\". Installed: "
                    + (runtimes.isEmpty ? "none" : runtimes.map(\.name).joined(separator: ", ")) + ".")
            }
        }
        for runtime in candidates {
            if let type = runtime.supportedDeviceTypes?.first(where: matches) { return (runtime, type) }
        }
        var supported: [String] = []
        for name in candidates.flatMap({ $0.supportedDeviceTypes ?? [] }).map(\.name) where !supported.contains(name) {
            supported.append(name)
        }
        throw .invalidArgument("Unknown device type \"\(typeQuery)\"" + (runtimeQuery != nil ? " for \(candidates[0].name)" : "")
            + (supported.isEmpty ? "." : ". Available: " + supported.joined(separator: ", ") + "."))
    }

    static let eraseDevice = ToolDefinition(
        name: "erase_device",
        toolset: .devices,
        description: """
            Erase a simulator: remove all apps, data and settings, as after a fresh install. \
            A booted simulator is shut down, erased and booted again. Simulators only.
            """,
        inputSchema: Schema.deviceObject([:], required: ["device"]),
        annotations: .destructive
    ) { arguments, context in
        try context.requireXcode()
        let device = try await context.session.resolve(try arguments.requiredString("device"))
        let lifecycle = try context.router.backend(.erase, for: device, as: (any SimulatorLifecycle).self)
        let wasRunning = device.state != .shutdown
        if wasRunning { try await lifecycle.shutdown(udid: device.udid) }
        try await lifecycle.erase(udid: device.udid)
        await context.accessibility.forget(device.udid)
        if wasRunning {
            try await lifecycle.boot(udid: device.udid, wait: true)
            await context.accessibility.prepare(device)
        }
        return .text("Erased \"\(device.name)\" (\(device.udid))" + (wasRunning ? " and booted it again." : "."))
    }

    static let deleteDevice = ToolDefinition(
        name: "delete_device",
        toolset: .devices,
        description: "Delete a simulator, or with unavailable_only all simulators whose runtime is no longer installed. Simulators only.",
        inputSchema: Schema.object([
            "device": Schema.string("Simulator UDID or name to delete."),
            "unavailable_only": Schema.bool("Instead of one simulator, delete every simulator whose runtime is missing.", default: false),
        ]),
        annotations: .destructive
    ) { arguments, context in
        try context.requireXcode()
        if try arguments.bool("unavailable_only", default: false) {
            let unavailable = try await context.simctl.listDevices().filter { !$0.isAvailable }
            guard !unavailable.isEmpty else { return .text("There are no unavailable simulators.") }
            try await context.simctl.deleteUnavailable()
            return .text("Deleted \(unavailable.count) unavailable simulator(s): " + unavailable.map { "\($0.name) (iOS \($0.osVersion ?? "?"))" }.joined(separator: ", "))
        }
        guard let query = try arguments.device else {
            throw ISimError.invalidArgument("Pass `device` (simulator name or UDID), or unavailable_only: true.")
        }
        let device = try await context.session.resolve(query)
        let lifecycle = try context.router.backend(.delete, for: device, as: (any SimulatorLifecycle).self)
        try await lifecycle.delete(udid: device.udid)
        if await context.session.activeUDID == device.udid { await context.session.clearActive() }
        return .text("Deleted \"\(device.name)\" (\(device.udid)).")
    }
}
