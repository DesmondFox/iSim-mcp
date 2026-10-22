import DeviceCore
import Foundation
import MCP

enum CoreTools {
    static let all: [ToolDefinition] = [doctor, setActiveDevice]

    static let doctor = ToolDefinition(
        name: "doctor",
        toolset: .core,
        description: """
            Check the environment: Xcode version, simctl/devicectl, simulator runtimes, private frameworks for UI tools, \
            connected iPhones (Developer Mode, lock state) and code signing identities. Call it first when something fails.
            """,
        inputSchema: Schema.object([:]),
        annotations: .readOnly
    ) { _, context in
        var report = DoctorReport()

        switch context.xcode {
        case .success(let xcode) where xcode.isSupported:
            report.ok("Xcode \(xcode.version)\(xcode.build.map { " (\($0))" } ?? "") at \(xcode.developerDir)")
        case .success(let xcode):
            report.fail("Xcode \(xcode.version) at \(xcode.developerDir) is too old; need \(XcodeEnvironment.minimumVersion)+. Set DEVELOPER_DIR or run `sudo xcode-select -s <Xcode.app>`.")
            return report.result
        case .failure(let error):
            report.fail(error.description)
            return report.result
        }

        do {
            let runtimes = try await context.simctl.listRuntimes()
            let available = runtimes.filter(\.isAvailable).map(\.name)
            if available.isEmpty {
                report.warn("simctl works, but no iOS simulator runtime is installed (Xcode → Settings → Components).")
            } else {
                report.ok("simctl: runtimes \(available.joined(separator: ", "))")
            }
            for runtime in runtimes where !runtime.isAvailable {
                report.warn("Runtime \(runtime.name) is unavailable: \(runtime.availabilityError ?? "unknown reason")")
            }
        } catch {
            report.fail("simctl: \(error)")
        }

        var devices: [Device] = []
        do {
            devices = try await context.devicectl.listDevices()
            report.ok("devicectl: \(devices.count) physical device(s) known")
        } catch {
            report.fail("devicectl: \(error)")
        }

        let frameworks = [
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework",
            "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework",
        ]
        let missing = frameworks.filter { !FileManager.default.fileExists(atPath: $0) }
        if missing.isEmpty {
            report.ok("Private frameworks for simulator input and accessibility are present")
        } else {
            report.warn("Missing (simulator UI tools will not work): \(missing.joined(separator: ", "))")
        }

        if let simulators = try? await context.simctl.listDevices() {
            let booted = simulators.filter { $0.state == .booted }
            report.info(booted.isEmpty
                ? "No booted simulators (boot one with boot_device)"
                : "Booted simulators: " + booted.map { "\($0.name) (iOS \($0.osVersion ?? "?"), \($0.udid))" }.joined(separator: ", "))
        }

        for device in devices {
            let label = "\(device.name) (\(device.model ?? "iPhone"), iOS \(device.osVersion ?? "?"), \(device.udid))"
            guard device.state == .connected else {
                report.info("\(label): not connected")
                continue
            }
            var problems: [String] = []
            if device.developerMode != "enabled" {
                problems.append("Developer Mode is \(device.developerMode ?? "unknown"): enable it in Settings → Privacy & Security → Developer Mode")
            }
            if let locked = try? await context.devicectl.isLocked(udid: device.udid), locked {
                problems.append("the device is locked: unlock it before using screen and UI tools")
            }
            if problems.isEmpty {
                report.ok("\(label): connected via \(device.transport ?? "unknown transport"), Developer Mode on, unlocked")
            } else {
                report.warn("\(label): " + problems.joined(separator: "; "))
            }
        }

        if let identities = try? await context.runner.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"], timeout: .seconds(10)) {
            let development = identities.stdoutString.split(separator: "\n").filter { $0.contains("\"Apple Development:") }
            if development.isEmpty {
                report.warn("No \"Apple Development\" signing identity: installing your own builds and UI tools on iPhone need one (sign in to Xcode → Settings → Accounts).")
            } else {
                report.ok("Signing: \(development.count) Apple Development identit\(development.count == 1 ? "y" : "ies")")
            }
        }

        return report.result
    }

    static let setActiveDevice = ToolDefinition(
        name: "set_active_device",
        toolset: .core,
        description: "Set the device that tools use when `device` is omitted. Pass `clear: true` to go back to automatic selection.",
        inputSchema: Schema.object([
            "device": Schema.string("Device UDID or name."),
            "clear": Schema.bool("Forget the active device.", default: false),
        ]),
        annotations: .idempotent
    ) { arguments, context in
        if try arguments.bool("clear", default: false) {
            await context.session.clearActive()
            return .text("Active device cleared; tools will use the only booted simulator or connected iPhone.")
        }
        try context.requireXcode()
        let device = try await context.session.setActive(try arguments.requiredString("device"))
        var text = "Active device: \(device.summary)"
        if !device.state.isReady {
            text += device.kind == .simulator ? ". It is not booted yet: call boot_device." : ". It is not connected right now."
        }
        return .text(text)
    }
}

/// Collects doctor lines; the result is an error only if something essential failed.
private struct DoctorReport {
    private var lines: [String] = []
    private var failures = 0
    private var warnings = 0

    mutating func ok(_ text: String) { lines.append("✓ " + text) }
    mutating func info(_ text: String) { lines.append("• " + text) }
    mutating func warn(_ text: String) { lines.append("⚠ " + text); warnings += 1 }
    mutating func fail(_ text: String) { lines.append("✗ " + text); failures += 1 }

    var result: CallTool.Result {
        let summary = failures > 0
            ? "\(failures) problem(s) must be fixed."
            : warnings > 0 ? "Ready, \(warnings) warning(s)." : "All checks passed."
        let text = (lines + ["", summary]).joined(separator: "\n")
        return failures > 0 ? .error(text) : .text(text)
    }
}
