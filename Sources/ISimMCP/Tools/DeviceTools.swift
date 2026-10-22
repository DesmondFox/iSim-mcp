import DeviceCore
import Foundation
import MCP
import ProcessKit

enum DeviceTools {
    static let all: [ToolDefinition] = [listDevices, bootDevice, shutdownDevice]

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
}
