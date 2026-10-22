import DeviceCore
import Foundation
import MCP

/// Input and UI inspection. Phase 2 has only rotation; taps, typing and the accessibility tree come with SimBridge and the agent.
enum UITools {
    static let all: [ToolDefinition] = [setOrientation]

    static let setOrientation = ToolDefinition(
        name: "set_orientation",
        toolset: .ui,
        description: "Rotate the device. Apps that support the orientation rotate their interface; an iPhone with rotation lock on stays as it is.",
        inputSchema: Schema.deviceObject([
            "orientation": Schema.string("New orientation.", enum: DeviceOrientation.allCases.map(\.rawValue)),
        ], required: ["orientation"]),
        annotations: .idempotent
    ) { arguments, context in
        try context.requireXcode()
        guard let orientation = try arguments.choice("orientation", as: DeviceOrientation.self) else {
            throw ISimError.invalidArgument("`orientation` is required.")
        }
        let device = try await context.session.resolveReady(try arguments.device)
        let state = try await context.router.backend(.orientation, for: device, as: (any OrientationControlling).self)
            .setOrientation(udid: device.udid, orientation)
        return .text("\"\(device.name)\": " + describe(state))
    }

    /// "Orientation: landscapeLeft (lying face up), rotation lock on"
    static func describe(_ state: OrientationState) -> String {
        var text = "Orientation: \(state.orientation?.rawValue ?? "unknown")"
        if let physical = state.physical, physical != "unknown" { text += " (device lies \(physical == "faceUp" ? "face up" : physical == "faceDown" ? "face down" : physical))" }
        if state.isLocked { text += ", rotation lock on" }
        return text
    }
}
