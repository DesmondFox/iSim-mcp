import Foundation

/// Errors shown to the MCP client. Every message says what went wrong and, where possible, what to call next.
public enum ISimError: Error, CustomStringConvertible, Equatable {
    case deviceNotFound(query: String, available: [Device])
    case ambiguousDevice(query: String, matches: [Device])
    case noDeviceSelected(running: [Device])
    case activeDeviceGone(udid: String)
    case deviceNotReady(Device)
    case unsupported(Capability, kind: DeviceKind, hint: String?)
    case invalidArgument(String)
    case commandFailed(command: String, message: String)
    case xcodeUnavailable(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .deviceNotFound(let query, let available):
            "No device matches \"\(query)\". " + Self.listing(available, emptyText: "No devices found.")
        case .ambiguousDevice(let query, let matches):
            "Several devices are named \"\(query)\". Pass a UDID instead:\n"
                + matches.map { "  \($0.summary)" }.joined(separator: "\n")
        case .noDeviceSelected(let running):
            if running.isEmpty {
                "No booted simulator or connected device. Call boot_device or connect an iPhone, "
                    + "or pass `device` explicitly. Use list_devices to see all devices."
            } else {
                "Several devices are running; pass `device` or call set_active_device:\n"
                    + running.map { "  \($0.summary)" }.joined(separator: "\n")
            }
        case .activeDeviceGone(let udid):
            "The active device \(udid) is no longer available. Call set_active_device or pass `device`."
        case .deviceNotReady(let device):
            switch device.kind {
            case .simulator: "Device \(device.summary) is not booted. Call boot_device first."
            case .physical: "Device \(device.summary) is not connected. Connect it by USB or make sure it is on the same network and unlocked."
            }
        case .unsupported(let capability, let kind, let hint):
            "\(capability.toolName) is not available on \(kind == .physical ? "physical devices" : "simulators")."
                + (hint.map { " \($0)" } ?? "")
        case .invalidArgument(let message):
            message
        case .commandFailed(let command, let message):
            "`\(command)` failed: \(message)"
        case .xcodeUnavailable(let message):
            message
        case .notFound(let message):
            message
        }
    }

    private static func listing(_ devices: [Device], emptyText: String) -> String {
        guard !devices.isEmpty else { return emptyText }
        return "Available devices:\n" + devices.map { "  \($0.summary)" }.joined(separator: "\n")
    }
}
