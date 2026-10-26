import APNsBackend
import DeviceCore
import Foundation
import MCP

/// The device environment: appearance, permissions, location, status bar, biometrics, pasteboard, push, locale, iCloud.
enum SystemTools {
    static let all: [ToolDefinition] = [
        configureUI, setPermission, setLocation, simulateRoute, overrideStatusBar, biometrics, setPasteboard, getPasteboard, sendPush,
        setLocale, iCloudSync,
    ]

    // MARK: Appearance

    static let configureUI = ToolDefinition(
        name: "configure_ui",
        toolset: .system,
        description: """
            Light/dark appearance, Dynamic Type text size, Increase Contrast and Reduce Motion. \
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
            Grant, revoke or reset an app's privacy permission without the system prompt. \
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
            Simulate the GPS location, or pass clear: true to go back to the real one (this also stops simulate_route). \
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
            Move the simulated location along waypoints, or run a built-in scenario (City Run, City Bicycle Ride, Freeway Drive, Apple). \
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
            Override the status bar for clean screenshots: preset=screenshot gives 9:41, full battery and full signal. \
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
            Face ID / Touch ID on a simulator: enable (enroll) or disable it, or answer the biometric prompt the app is showing \
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

    enum PushMode: String, CaseIterable {
        /// simctl delivers a simulated push straight to the app.
        case local
        /// A real push through Apple's servers to a device token.
        case apns
    }

    static let sendPush = ToolDefinition(
        name: "send_push",
        toolset: .system,
        description: """
            Send a push notification. mode=local (default on simulators) delivers a simulated push straight to a simulator app: \
            no APNs, certificate or token needed, regular pushes up to 4 KB. mode=apns (default on iPhones) sends a real push \
            through Apple's servers to the app's device_token, on iPhones and simulators alike, including background, VoIP and \
            Live Activity pushes; it needs the server started with an APNs key. The app must be allowed to show notifications.
            """,
        inputSchema: Schema.deviceObject([
            "bundle_id": Schema.string("Bundle identifier of the app."),
            "payload": ["type": "object", "description": .string(#"Payload with an "aps" dictionary, e.g. {"aps": {"alert": {"title": "Hi", "body": "Text"}, "badge": 1}}."#)],
            "payload_path": Schema.string("JSON file with the payload, instead of `payload`."),
            "mode": Schema.string("local: simulated delivery on a simulator; apns: through Apple's servers.", enum: PushMode.allCases.map(\.rawValue)),
            "device_token": Schema.string("apns: the hex device token the app got from didRegisterForRemoteNotificationsWithDeviceToken."),
            "push_type": Schema.string("apns: the apns-push-type. Default alert.", enum: APNsPushType.allCases.map(\.rawValue)),
            "priority": Schema.integer("apns: 10 delivers at once, 5 when convenient (required for background). Default by push_type.", minimum: 1, maximum: 10),
            "collapse_id": Schema.string("apns: notifications with the same id replace each other."),
            "environment": Schema.string("apns: sandbox for development builds and simulators, production for TestFlight and App Store builds.",
                                         enum: APNsEnvironment.allCases.map(\.rawValue)),
        ], required: ["bundle_id"]),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        let bundleId = try arguments.requiredString("bundle_id")
        var mode = try arguments.choice("mode", as: PushMode.self)
        let pushType = try arguments.choice("push_type", default: APNsPushType.alert)
        // A real push needs no device here: the token addresses it.
        var device: Device?
        if mode != .apns {
            device = try await context.session.resolveReady(try arguments.device)
            if mode == nil { mode = device!.kind == .simulator ? .local : .apns }
        }
        let payload = try pushPayload(arguments, requireAPS: mode == .local || pushType != .voip,
                                      maxBytes: mode == .apns ? pushType.maxPayloadBytes : maxPushPayloadBytes)

        if mode == .apns {
            guard let apns = context.apns else {
                throw ISimError.invalidArgument("mode=apns needs an APNs auth key: restart the server with --apns-key-path, --apns-key-id and "
                    + "--team-id (or ISIM_APNS_KEY_PATH, ISIM_APNS_KEY_ID, ISIM_TEAM_ID)."
                    + (device?.kind == .simulator ? " On a simulator, mode=local needs no key." : ""))
            }
            guard let token = try arguments.string("device_token").flatMap({ $0.isEmpty ? nil : $0 }) else {
                throw ISimError.invalidArgument("mode=apns needs `device_token`: the app gets it from didRegisterForRemoteNotificationsWithDeviceToken; "
                    + "debug builds often log it.")
            }
            let environment = try arguments.choice("environment", default: APNsEnvironment.sandbox)
            let notification = APNsNotification(
                deviceToken: token, bundleId: bundleId, pushType: pushType, priority: try arguments.int("priority"),
                collapseID: try arguments.string("collapse_id").flatMap { $0.isEmpty ? nil : $0 }, payload: payload)
            let id = try await apns.send(notification, environment: environment)
            return .text("APNs (\(environment.rawValue)) accepted the \(pushType.rawValue) push to \(bundleId): apns-id \(id). "
                + "Delivery happens when the device is reachable; acceptance does not mean the app showed it.")
        }

        let sender = try context.router.backend(.push, for: device!, as: (any PushSending).self)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("isim-push-\(UUID().uuidString).json")
        try payload.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await sender.sendPush(udid: device!.udid, bundleId: bundleId, payloadPath: file.path)
        return .text("Sent a push notification to \(bundleId) on \"\(device!.name)\".")
    }

    static let maxPushPayloadBytes = 4096

    /// The payload as JSON: from `payload` (an object, or a JSON string) or `payload_path`. Checks what simctl or APNs would reject.
    static func pushPayload(_ arguments: ToolArguments, requireAPS: Bool = true, maxBytes: Int = maxPushPayloadBytes) throws(ISimError) -> Data {
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
        guard !requireAPS || object["aps"] is [String: Any] else {
            throw .invalidArgument(#"The payload needs an "aps" dictionary, e.g. {"aps": {"alert": "Hello"}}."#)
        }
        guard data.count <= maxBytes else {
            throw .invalidArgument("The payload is \(data.count) bytes; pushes are limited to \(maxBytes).")
        }
        return data
    }

    // MARK: Locale

    static let setLocale = ToolDefinition(
        name: "set_locale",
        toolset: .system,
        description: """
            Language and region of a simulator. `language` (de, de-DE, pt-BR) becomes the first preferred language; `region` \
            (DE) sets the region format together with the language. The simulator reboots (a few seconds) so the system UI \
            switches too; launch the app again afterwards. Without parameters, shows the current settings. Simulators only.
            """,
        inputSchema: Schema.deviceObject([
            "language": Schema.string("Language code, optionally with a region: de, de-DE, zh-Hans, pt-BR."),
            "region": Schema.string("Region code for formats (dates, numbers, currency), e.g. DE. Default: the language's region, if it has one."),
            "languages": Schema.stringArray("The whole list of preferred languages instead of `language`."),
        ]),
        annotations: .idempotent
    ) { arguments, context in
        try context.requireXcode()
        let language = try arguments.string("language").flatMap { $0.isEmpty ? nil : $0 }
        let region = try arguments.string("region").flatMap { $0.isEmpty ? nil : $0.uppercased() }
        let list = try arguments.stringArray("languages")
        let device = try await context.session.resolveReady(try arguments.device)
        let backend = try context.router.backend(.locale, for: device, as: (any LocaleConfiguring).self)
        let current = try await backend.locale(udid: device.udid)
        guard language != nil || region != nil || !list.isEmpty else {
            return .text("\"\(device.name)\": " + describe(current))
        }
        let (languages, locale) = localeChange(current: current, language: language, region: region, languages: list)
        try await backend.setLocale(udid: device.udid, languages: languages, locale: locale)
        // Restarting only SpringBoard after a language change leaves apps' accessibility unreadable until a reboot.
        try await context.router.backend(.reboot, for: device, as: (any DeviceRebooting).self).reboot(udid: device.udid, wait: true)
        await context.accessibility.forget(device.udid)
        await context.accessibility.prepare(device)
        let updated = try await backend.locale(udid: device.udid)
        return .text("\"\(device.name)\": " + describe(updated) + ". The simulator rebooted; launch the app with launch_app to see it.")
    }

    /// What to write: the language first in the list, and a region format from the region or the language's own region.
    static func localeChange(current: DeviceLocale, language: String?, region: String?, languages: [String]) -> (languages: [String]?, locale: String?) {
        var newLanguages: [String]?
        if !languages.isEmpty {
            newLanguages = languages
        } else if let language {
            newLanguages = [language] + current.languages.filter { $0.caseInsensitiveCompare(language) != .orderedSame }
        }
        let first = newLanguages?.first ?? current.languages.first ?? "en"
        // "zh-Hans-CN" → language "zh-Hans", region "CN"; "de-DE" → "de", "DE".
        var parts = first.split(separator: "-").map(String.init)
        var ownRegion: String?
        if parts.count > 1, let last = parts.last, last.count == 2 || last.allSatisfy(\.isNumber) {
            ownRegion = last.uppercased()
            parts.removeLast()
        }
        let code = parts.joined(separator: "-")
        let locale: String? = if let region = region ?? ownRegion {
            "\(code)_\(region)"
        } else if newLanguages != nil, let currentRegion = current.locale?.split(separator: "_").last, current.locale?.contains("_") == true {
            "\(code)_\(currentRegion)"
        } else {
            nil
        }
        return (newLanguages, locale)
    }

    static func describe(_ locale: DeviceLocale) -> String {
        "languages " + (locale.languages.isEmpty ? "not set" : locale.languages.joined(separator: ", ")) + ", region format " + (locale.locale ?? "not set")
    }

    static let iCloudSync = ToolDefinition(
        name: "icloud_sync",
        toolset: .system,
        description: "Make a simulator sync with iCloud now (CloudKit, iCloud Drive), instead of waiting for it. Needs an Apple Account signed in on the simulator. Simulators only.",
        inputSchema: Schema.deviceObject(),
        annotations: .idempotent
    ) { arguments, context in
        try context.requireXcode()
        let device = try await context.session.resolveReady(try arguments.device)
        try await context.router.backend(.iCloudSync, for: device, as: (any ICloudSyncing).self).syncICloud(udid: device.udid)
        return .text("Started an iCloud sync on \"\(device.name)\".")
    }
}
