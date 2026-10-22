import DeviceCore
import Foundation
import MCP

/// The device environment: appearance, permissions, location, status bar, biometrics, pasteboard, push.
enum SystemTools {
    static let all: [ToolDefinition] = [
        configureUI, setPermission, setLocation, simulateRoute, overrideStatusBar, biometrics, setPasteboard, getPasteboard, sendPush,
    ]

    // MARK: Appearance

    static let configureUI = ToolDefinition(
        name: "configure_ui",
        toolset: .system,
        description: """
            Light/dark appearance, Dynamic Type text size, Increase Contrast and Reduce Motion. \\
            Omitted settings stay as they are; with no parameters, returns the current values. Works on simulators and iPhones.
            """,
        inputSchema: Schema.deviceObject([
            "appearance": Schema.string("Interface style.", enum: InterfaceStyle.allCases.map(\.rawValue)),
            "content_size": Schema.string("Dynamic Type size; accessibility-* sizes switch on Larger Accessibility Sizes.",
                                          enum: ContentSize.allCases.map(\.rawValue)),
            "increase_contrast": Schema.optionalBool("Increase Contrast on or off."),
            "reduce_motion": Schema.optionalBool("Reduce Motion on or off (fewer animations, steadier screenshots)."),
        ]),
        annotations: .idempotent
    ) { arguments, context in
        try context.requireXcode()
        let changes = AppearanceSettings(
            style: try arguments.choice("appearance", as: InterfaceStyle.self),
            contentSize: try arguments.choice("content_size", as: ContentSize.self),
            increaseContrast: try arguments.optionalBool("increase_contrast"),
            reduceMotion: try arguments.optionalBool("reduce_motion")
        )
        let device = try await context.session.resolveReady(try arguments.device)
        let backend = try context.router.backend(.appearance, for: device, as: (any AppearanceConfiguring).self)
        if changes.isEmpty {
            return .text("\"\(device.name)\": " + describe(try await backend.appearance(udid: device.udid)))
        }
        let settings = try await backend.setAppearance(udid: device.udid, changes)
        return .text("Updated \"\(device.name)\": " + describe(settings))
    }

    /// "dark appearance, text size extra-large, Increase Contrast on, Reduce Motion off"
    static func describe(_ settings: AppearanceSettings) -> String {
        func onOff(_ value: Bool?) -> String { value.map { $0 ? "on" : "off" } ?? "unknown" }
        return [
            "\(settings.style?.rawValue ?? "unknown") appearance",
            "text size \(settings.contentSize?.rawValue ?? "unknown")",
            "Increase Contrast \(onOff(settings.increaseContrast))",
            "Reduce Motion \(onOff(settings.reduceMotion))",
        ].joined(separator: ", ")
    }

    // MARK: Permissions

    static let setPermission = ToolDefinition(
        name: "set_permission",
        toolset: .system,
        description: """
            Grant, revoke or reset an app's privacy permission without the system prompt. \\
            iOS may terminate the app when its permission changes. Simulators only.
            """,
        inputSchema: Schema.deviceObject([
            "action": Schema.string("grant, revoke, or reset (the app will ask again).", enum: PermissionAction.allCases.map(\.rawValue)),
            "service": Schema.string("Protected resource; `all` applies to every one.", enum: PermissionService.allCases.map(\.rawValue)),
            "bundle_id": Schema.string("App bundle identifier. Required for grant and revoke; without it, reset applies to all apps."),
        ], required: ["action", "service"]),
        annotations: .idempotent
    ) { arguments, context in
        try context.requireXcode()
        guard let action = try arguments.choice("action", as: PermissionAction.self) else {
            throw ISimError.invalidArgument("`action` is required: grant, revoke or reset.")
        }
        guard let service = try arguments.choice("service", as: PermissionService.self) else {
            throw ISimError.invalidArgument("`service` is required: " + PermissionService.allCases.map(\.rawValue).joined(separator: ", ") + ".")
        }
        let bundleId = try arguments.string("bundle_id").flatMap { $0.isEmpty ? nil : $0 }
        if bundleId == nil && action != .reset {
            throw ISimError.invalidArgument("`bundle_id` is required to \(action.rawValue) a permission.")
        }
        let device = try await context.session.resolveReady(try arguments.device)
        try await context.router.backend(.permissions, for: device, as: (any PermissionManaging).self)
            .setPermission(udid: device.udid, action: action, service: service, bundleId: bundleId)

        let target = bundleId ?? "all apps"
        let what = service == .all ? "all permissions" : "\(service.rawValue) access"
        let text = switch action {
        case .grant: "Granted \(what) to \(target) on \"\(device.name)\"."
        case .revoke: "Revoked \(what) from \(target) on \"\(device.name)\"."
        case .reset: "Reset \(what) for \(target) on \"\(device.name)\": the app will ask again."
        }
        return .text(text)
    }

    // MARK: Location

    static let setLocation = ToolDefinition(
        name: "set_location",
        toolset: .system,
        description: """
            Simulate the GPS location, or pass clear: true to go back to the real one (this also stops simulate_route). \\
            Works on simulators and iPhones.
            """,
        inputSchema: Schema.deviceObject([
            "latitude": Schema.number("Latitude in degrees, e.g. 55.7558.", minimum: -90, maximum: 90),
            "longitude": Schema.number("Longitude in degrees, e.g. 37.6173.", minimum: -180, maximum: 180),
            "clear": Schema.bool("Stop simulating the location.", default: false),
        ]),
        annotations: .idempotent
    ) { arguments, context in
        try context.requireXcode()
        let clear = try arguments.bool("clear", default: false)
        let latitude = try arguments.double("latitude")
        let longitude = try arguments.double("longitude")
        let device = try await context.session.resolveReady(try arguments.device)
        let backend = try context.router.backend(.location, for: device, as: (any LocationSimulating).self)
        if clear {
            try await backend.clearLocation(udid: device.udid)
            return .text("Stopped simulating the location of \"\(device.name)\".")
        }
        guard let latitude, let longitude else {
            throw ISimError.invalidArgument("Pass `latitude` and `longitude`, or clear: true.")
        }
        let coordinate = Coordinate(latitude: latitude, longitude: longitude)
        guard coordinate.isValid else {
            throw ISimError.invalidArgument("Latitude must be within -90…90 and longitude within -180…180.")
        }
        try await backend.setLocation(udid: device.udid, coordinate)
        return .text("Location of \"\(device.name)\" is now \(latitude), \(longitude).")
    }

    static let simulateRoute = ToolDefinition(
        name: "simulate_route",
        toolset: .system,
        description: """
            Move the simulated location along waypoints, or run a built-in scenario (City Run, City Bicycle Ride, Freeway Drive, Apple). \\
            Returns right away; the movement goes on until set_location with clear: true. Works on simulators and iPhones.
            """,
        inputSchema: Schema.deviceObject([
            "waypoints": Schema.array(
                of: Schema.object([
                    "latitude": Schema.number("Latitude in degrees.", minimum: -90, maximum: 90),
                    "longitude": Schema.number("Longitude in degrees.", minimum: -180, maximum: 180),
                ], required: ["latitude", "longitude"]),
                "Points of the route, at least two.", minItems: 2),
            "scenario": Schema.string("Built-in scenario instead of waypoints."),
            "speed": Schema.number("Speed along the waypoints in m/s. Default: 10 (36 km/h).", minimum: 0.1),
        ]),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        let waypoints = try coordinates(arguments.values["waypoints"])
        let scenario = try arguments.string("scenario").flatMap { $0.isEmpty ? nil : $0 }
        guard waypoints.isEmpty != (scenario == nil) else {
            throw ISimError.invalidArgument("Pass either `waypoints` or `scenario`.")
        }
        let speed = try arguments.double("speed") ?? 10
        guard speed > 0 else { throw ISimError.invalidArgument("`speed` must be positive.") }

        let device = try await context.session.resolveReady(try arguments.device)
        let backend = try context.router.backend(.location, for: device, as: (any LocationSimulating).self)
        if let scenario {
            let available = try await backend.locationScenarios(udid: device.udid)
            guard let name = available.first(where: { $0.caseInsensitiveCompare(scenario) == .orderedSame }) else {
                throw ISimError.invalidArgument("Unknown scenario \"\(scenario)\". Available: " + available.joined(separator: ", ") + ".")
            }
            try await backend.runLocationScenario(udid: device.udid, name: name)
            return .text("Running the \"\(name)\" scenario on \"\(device.name)\". Stop it with set_location(clear: true).")
        }
        guard waypoints.count >= 2 else { throw ISimError.invalidArgument("`waypoints` needs at least two points.") }
        try await backend.simulateRoute(udid: device.udid, waypoints: waypoints, speed: speed)
        return .text("\"\(device.name)\" is moving through \(waypoints.count) waypoints at \(ScreenTools.format(speed)) m/s. "
            + "Stop it with set_location(clear: true).")
    }

    /// `[{latitude, longitude}, …]` → coordinates.
    static func coordinates(_ value: Value?) throws(ISimError) -> [Coordinate] {
        guard let value, value != .null else { return [] }
        guard case .array(let items) = value else { throw .invalidArgument("`waypoints` must be an array of {latitude, longitude}.") }
        var result: [Coordinate] = []
        for (index, item) in items.enumerated() {
            let point = ToolArguments(item.objectValue ?? [:])
            guard let latitude = try point.double("latitude"), let longitude = try point.double("longitude") else {
                throw .invalidArgument("`waypoints[\(index)]` must have numeric latitude and longitude.")
            }
            let coordinate = Coordinate(latitude: latitude, longitude: longitude)
            guard coordinate.isValid else { throw .invalidArgument("`waypoints[\(index)]` is outside -90…90 / -180…180.") }
            result.append(coordinate)
        }
        return result
    }

    // MARK: Status bar

    static let overrideStatusBar = ToolDefinition(
        name: "override_status_bar",
        toolset: .system,
        description: """
            Override the status bar for clean screenshots: preset=screenshot gives 9:41, full battery and full signal. \\
            Single fields change only those indicators; overrides stay until clear: true. Simulators only.
            """,
        inputSchema: Schema.deviceObject([
            "preset": Schema.string("Ready-made set of indicators, applied before the single fields.", enum: StatusBarPreset.allCases.map(\.rawValue)),
            "time": Schema.string("Time text, e.g. \"9:41\"."),
            "battery_level": Schema.integer("Battery percentage.", minimum: 0, maximum: 100),
            "battery_state": Schema.string("Battery state.", enum: StatusBarOverride.batteryStates),
            "cellular_mode": Schema.string("Cellular connection; notSupported hides it.", enum: StatusBarOverride.cellularModes),
            "cellular_bars": Schema.integer("Cellular signal bars (sets cellular_mode to active). Default with active: full.",
                                            minimum: StatusBarOverride.cellularBarsRange.lowerBound, maximum: StatusBarOverride.cellularBarsRange.upperBound),
            "wifi_mode": Schema.string("Wi-Fi connection.", enum: StatusBarOverride.wifiModes),
            "wifi_bars": Schema.integer("Wi-Fi signal bars (sets wifi_mode to active). Default with active: full.",
                                        minimum: StatusBarOverride.wifiBarsRange.lowerBound, maximum: StatusBarOverride.wifiBarsRange.upperBound),
            "data_network": Schema.string("Network type shown next to the bars when Wi-Fi is off.", enum: StatusBarOverride.dataNetworks),
            "clear": Schema.bool("Remove all overrides.", default: false),
        ]),
        annotations: .idempotent
    ) { arguments, context in
        try context.requireXcode()
        let clear = try arguments.bool("clear", default: false)
        let preset = try arguments.choice("preset", as: StatusBarPreset.self)
        let override = StatusBarOverride(
            time: try arguments.string("time").flatMap { $0.isEmpty ? nil : $0 },
            dataNetwork: try arguments.choice("data_network", from: StatusBarOverride.dataNetworks),
            wifiMode: try arguments.choice("wifi_mode", from: StatusBarOverride.wifiModes),
            wifiBars: try optionalInt(arguments, "wifi_bars", range: StatusBarOverride.wifiBarsRange),
            cellularMode: try arguments.choice("cellular_mode", from: StatusBarOverride.cellularModes),
            cellularBars: try optionalInt(arguments, "cellular_bars", range: StatusBarOverride.cellularBarsRange),
            batteryState: try arguments.choice("battery_state", from: StatusBarOverride.batteryStates),
            batteryLevel: try optionalInt(arguments, "battery_level", range: 0...100)
        )
        guard clear || preset != nil || !override.isEmpty else {
            throw ISimError.invalidArgument("Pass a preset, at least one indicator, or clear: true.")
        }
        let device = try await context.session.resolveReady(try arguments.device)
        let backend = try context.router.backend(.statusBar, for: device, as: (any StatusBarOverriding).self)
        if clear {
            try await backend.clearStatusBar(udid: device.udid)
            return .text("Status bar of \"\(device.name)\" shows real values again.")
        }
        if let preset { try await backend.applyStatusBarPreset(udid: device.udid, preset) }
        if !override.isEmpty { try await backend.overrideStatusBar(udid: device.udid, override) }
        let current = try await backend.statusBar(udid: device.udid)
        return .text("Status bar of \"\(device.name)\": " + describe(current))
    }

    private static func optionalInt(_ arguments: ToolArguments, _ key: String, range: ClosedRange<Int>) throws(ISimError) -> Int? {
        guard let value = try arguments.int(key) else { return nil }
        guard range.contains(value) else {
            throw .invalidArgument("`\(key)` must be between \(range.lowerBound) and \(range.upperBound), got \(value).")
        }
        return value
    }

    /// "time 9:41, battery 100% charged, Wi-Fi 3 bars, cellular 4 bars LTE"
    static func describe(_ bar: StatusBarOverride) -> String {
        func connection(_ name: String, mode: String?, bars: Int?) -> String? {
            switch mode {
            case nil: return bars.map { "\(name) \($0) bars" }
            case "active": return "\(name) " + (bars.map { "\($0) bars" } ?? "on")
            case "notSupported": return "\(name) hidden"
            case let mode?: return "\(name) \(mode)"
            }
        }
        var parts: [String] = []
        if let time = bar.time { parts.append("time \(time)") }
        if bar.batteryLevel != nil || bar.batteryState != nil {
            parts.append("battery " + [bar.batteryLevel.map { "\($0)%" }, bar.batteryState].compactMap(\.self).joined(separator: " "))
        }
        if let wifi = connection("Wi-Fi", mode: bar.wifiMode, bars: bar.wifiBars) { parts.append(wifi) }
        if let cellular = connection("cellular", mode: bar.cellularMode, bars: bar.cellularBars) { parts.append(cellular) }
        if let network = bar.dataNetwork { parts.append("network \(network)") }
        return parts.isEmpty ? "no overrides" : parts.joined(separator: ", ")
    }

    // MARK: Biometrics

    enum BiometricAction: String, CaseIterable {
        case status
        case enable
        case disable
        case match
        case nonmatch
    }

    static let biometrics = ToolDefinition(
        name: "biometrics",
        toolset: .system,
        description: """
            Face ID / Touch ID on a simulator: enable (enroll) or disable it, or answer the biometric prompt the app is showing \\
            with a matching (match) or non-matching (nonmatch) face or finger. Simulators only.
            """,
        inputSchema: Schema.deviceObject([
            "action": Schema.string("status shows whether biometrics are enrolled.", enum: BiometricAction.allCases.map(\.rawValue)),
        ], required: ["action"]),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        guard let action = try arguments.choice("action", as: BiometricAction.self) else {
            throw ISimError.invalidArgument("`action` is required: " + BiometricAction.allCases.map(\.rawValue).joined(separator: ", ") + ".")
        }
        let device = try await context.session.resolveReady(try arguments.device)
        let backend = try context.router.backend(.biometrics, for: device, as: (any BiometricsSimulating).self)
        switch action {
        case .status:
            return .text("\"\(device.name)\": " + describe(try await backend.biometricEnrollment(udid: device.udid)))
        case .enable, .disable:
            let enrollment = try await backend.setBiometricEnrollment(udid: device.udid, enrolled: action == .enable)
            return .text("\"\(device.name)\": " + describe(enrollment))
        case .match, .nonmatch:
            // devicectl reports success even when nothing is enrolled and the event goes nowhere.
            let enrollment = try await backend.biometricEnrollment(udid: device.udid)
            guard enrollment.contains(where: \.enrolled) else {
                throw ISimError.invalidArgument("\(biometricName(enrollment)) is not enrolled on \"\(device.name)\". "
                    + "Call biometrics with action=enable first, then trigger the prompt in the app.")
            }
            try await backend.simulateBiometricMatch(udid: device.udid, success: action == .match)
            return .text("Simulated a \(action == .match ? "matching" : "non-matching") \(biometricName(enrollment)) on \"\(device.name)\".")
        }
    }

    private static func biometricName(_ enrollment: [BiometricEnrollment]) -> String {
        enrollment.first?.type ?? "Biometrics"
    }

    static func describe(_ enrollment: [BiometricEnrollment]) -> String {
        guard !enrollment.isEmpty else { return "no biometric hardware" }
        return enrollment.map { "\($0.type) \($0.enrolled ? "enrolled" : "not enrolled")" }.joined(separator: ", ")
    }

    // MARK: Pasteboard

    static let setPasteboard = ToolDefinition(
        name: "set_pasteboard",
        toolset: .system,
        description: "Put text on the device's pasteboard (clipboard). On an iPhone this replaces the owner's clipboard.",
        inputSchema: Schema.deviceObject([
            "text": Schema.string("Text to copy; any language and emoji."),
        ], required: ["text"]),
        annotations: .idempotent
    ) { arguments, context in
        try context.requireXcode()
        guard let text = try arguments.string("text") else { throw ISimError.invalidArgument("`text` is required.") }
        let device = try await context.session.resolveReady(try arguments.device)
        try await context.router.backend(.pasteboard, for: device, as: (any PasteboardAccessing).self)
            .copyToPasteboard(udid: device.udid, text: text)
        return .text("Copied \(text.count) character(s) to the pasteboard of \"\(device.name)\".")
    }

    /// Longer pasteboard text is cut to keep the response small.
    static let pasteboardLimit = 20_000

    static let getPasteboard = ToolDefinition(
        name: "get_pasteboard",
        toolset: .system,
        description: "Read the text on the device's pasteboard (clipboard).",
        inputSchema: Schema.deviceObject(),
        annotations: .readOnly
    ) { arguments, context in
        try context.requireXcode()
        let device = try await context.session.resolveReady(try arguments.device)
        guard let text = try await context.router.backend(.pasteboard, for: device, as: (any PasteboardAccessing).self)
            .pasteboardText(udid: device.udid)
        else {
            return .text("The pasteboard of \"\(device.name)\" holds no text.")
        }
        guard text.count > pasteboardLimit else { return .text(text) }
        return .text(String(text.prefix(pasteboardLimit)) + "\n… [cut: \(text.count) characters in total]")
    }

    // MARK: Push

    static let sendPush = ToolDefinition(
        name: "send_push",
        toolset: .system,
        description: """
            Deliver a simulated remote push notification to an app on a simulator: no APNs, certificate or device token needed. \\
            Regular alert/badge/sound/background pushes up to 4 KB; not VoIP. The app must be allowed to show notifications. Simulators only.
            """,
        inputSchema: Schema.deviceObject([
            "bundle_id": Schema.string("Bundle identifier of the app."),
            "payload": ["type": "object", "description": .string(#"Payload with an "aps" dictionary, e.g. {"aps": {"alert": {"title": "Hi", "body": "Text"}, "badge": 1}}."#)],
            "payload_path": Schema.string("JSON file with the payload, instead of `payload`."),
        ], required: ["bundle_id"]),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        let bundleId = try arguments.requiredString("bundle_id")
        let payload = try pushPayload(arguments)
        let device = try await context.session.resolveReady(try arguments.device)
        let sender = try context.router.backend(.push, for: device, as: (any PushSending).self)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("isim-push-\(UUID().uuidString).json")
        try payload.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await sender.sendPush(udid: device.udid, bundleId: bundleId, payloadPath: file.path)
        return .text("Sent a push notification to \(bundleId) on \"\(device.name)\".")
    }

    static let maxPushPayloadBytes = 4096

    /// The payload as JSON: from `payload` (an object, or a JSON string) or `payload_path`. Checks what simctl would reject.
    static func pushPayload(_ arguments: ToolArguments) throws(ISimError) -> Data {
        let path = try arguments.string("payload_path").flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
        let data: Data
        switch (arguments.values["payload"], path) {
        case (nil, nil), (.null?, nil):
            throw .invalidArgument("Pass `payload` or `payload_path`.")
        case (let value?, nil) where value != .null:
            if case .string(let text) = value {
                data = Data(text.utf8)
            } else {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                guard let encoded = try? encoder.encode(value) else { throw .invalidArgument("`payload` cannot be encoded as JSON.") }
                data = encoded
            }
        case (nil, let path?), (.null?, let path?):
            guard let contents = FileManager.default.contents(atPath: path) else { throw .invalidArgument("File not found: \(path)") }
            data = contents
        default:
            throw .invalidArgument("Pass either `payload` or `payload_path`, not both.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .invalidArgument("The payload must be a JSON object.")
        }
        guard object["aps"] is [String: Any] else {
            throw .invalidArgument(#"The payload needs an "aps" dictionary, e.g. {"aps": {"alert": "Hello"}}."#)
        }
        guard data.count <= maxPushPayloadBytes else {
            throw .invalidArgument("The payload is \(data.count) bytes; simulated pushes are limited to \(maxPushPayloadBytes).")
        }
        return data
    }
}
