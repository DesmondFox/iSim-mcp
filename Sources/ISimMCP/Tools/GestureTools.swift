import CoreGraphics
import DeviceCore
import Foundation
import MCP

/// Gestures beyond tap and swipe: free paths, two fingers, scrolling to an element, shaking. Part of the ui toolset.
enum GestureTools {
    static let all: [ToolDefinition] = [touchPath, multiTouch, scrollUntilVisible, shake]

    /// Touch samples go at the display's frame rate, so apps see a moving finger rather than jumps.
    static let frameInterval = Duration.milliseconds(16)
    static let maxGesture = Duration.seconds(60)

    // MARK: One finger

    static let touchPath = ToolDefinition(
        name: "touch_path",
        toolset: .ui,
        description: """
            Move one finger along a path of points (in points): drag and drop, drawing, sliders, custom gestures. \
            The finger touches down at the first point and lifts at the last; dt_ms is the time from the previous point. \
            Repeat a point with a dt_ms to hold still there, e.g. a long press before dragging a list row.
            """,
        inputSchema: Schema.deviceObject([
            "points": Schema.array(
                of: Schema.object([
                    "x": Schema.number("X in points."),
                    "y": Schema.number("Y in points."),
                    "dt_ms": Schema.integer("Milliseconds from the previous point (ignored on the first). Default 100.", minimum: 0, maximum: 10_000),
                ], required: ["x", "y"]),
                "The path, at least two points.", minItems: 2),
        ], required: ["points"]),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        let points = try waypoints(arguments.values["points"])
        let samples = interpolate(points)
        guard let duration = samples.last?.offset, duration <= maxGesture else {
            throw ISimError.invalidArgument("The path takes longer than \(Int(maxGesture.inSeconds)) s.")
        }
        let device = try await context.session.resolveReady(try arguments.device)
        try await context.router.backend(.touchPath, for: device, as: (any GestureInjecting).self).touchPath(udid: device.udid, samples)
        return .text("Moved a finger through \(points.count) points in \(String(format: "%.2f", duration.inSeconds)) s, from "
            + UIElementFormatter.point(points[0].point) + " to " + UIElementFormatter.point(points[points.count - 1].point) + ".")
    }

    /// `[{x, y, dt_ms}]` → points at their times from the start.
    static func waypoints(_ value: Value?) throws(ISimError) -> [TouchSample] {
        guard case .array(let items)? = value, items.count >= 2 else {
            throw .invalidArgument("`points` must list at least two {x, y, dt_ms} points.")
        }
        var samples: [TouchSample] = []
        var time = Duration.zero
        for (index, item) in items.enumerated() {
            let fields = ToolArguments(item.objectValue ?? [:])
            guard let x = try fields.double("x"), let y = try fields.double("y") else {
                throw .invalidArgument("`points[\(index)]` needs x and y in points.")
            }
            if index > 0 {
                let dt = try fields.int("dt_ms") ?? 100
                guard dt >= 0 else { throw .invalidArgument("`points[\(index)].dt_ms` must be 0 or more.") }
                time += .milliseconds(dt)
            }
            samples.append(TouchSample(CGPoint(x: x, y: y), at: time))
        }
        return samples
    }

    /// Adds a sample per display frame between the given ones, along straight lines.
    static func interpolate(_ points: [TouchSample]) -> [TouchSample] {
        guard var previous = points.first else { return [] }
        var samples = [previous]
        for point in points.dropFirst() {
            let steps = max(1, Int((point.offset - previous.offset) / frameInterval))
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                let location = CGPoint(x: previous.point.x + (point.point.x - previous.point.x) * t,
                                       y: previous.point.y + (point.point.y - previous.point.y) * t)
                samples.append(TouchSample(location, at: previous.offset + (point.offset - previous.offset) * t))
            }
            previous = point
        }
        return samples
    }

    // MARK: Two fingers

    enum Preset: String, CaseIterable {
        /// Fingers move together: zoom out.
        case pinchIn = "pinch_in"
        /// Fingers move apart: zoom in.
        case pinchOut = "pinch_out"
        case rotate
    }

    static let multiTouch = ToolDefinition(
        name: "multi_touch",
        toolset: .ui,
        description: """
            A two-finger gesture: pinch_out zooms in (fingers apart), pinch_in zooms out, rotate turns by `angle` degrees \
            (positive is clockwise), around `center` or the middle of `element`, by default the screen's middle. \
            Or give both fingers' path as points [{x1, y1, x2, y2, dt_ms}]. Simulators pass pinches but not rotation \
            to apps; rotate works on iPhones.
            """,
        inputSchema: Schema.deviceObject([
            "preset": Schema.string("Gesture to perform.", enum: Preset.allCases.map(\.rawValue)),
            "center": Schema.point("Middle point between the fingers, in points."),
            "element": Schema.selector("Perform the gesture over this element's middle instead of `center`."),
            "scale": Schema.number("Pinch: how much the distance between the fingers changes; default 2 for pinch_out, 0.5 for pinch_in.", minimum: 0.05, maximum: 20),
            "angle": Schema.number("Rotate: degrees, positive clockwise. Default 90.", minimum: -720, maximum: 720),
            "radius": Schema.number("Distance of each finger from the center at the start, in points. Default: fits the screen.", minimum: 10),
            "duration_ms": Schema.integer("Duration of the movement.", default: 600, minimum: 100, maximum: 10_000),
            "points": Schema.array(
                of: Schema.object([
                    "x1": Schema.number("First finger X."), "y1": Schema.number("First finger Y."),
                    "x2": Schema.number("Second finger X."), "y2": Schema.number("Second finger Y."),
                    "dt_ms": Schema.integer("Milliseconds from the previous sample. Default 100.", minimum: 0, maximum: 10_000),
                ], required: ["x1", "y1", "x2", "y2"]),
                "Both fingers' path instead of a preset, at least two samples.", minItems: 2),
        ]),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        let preset = try arguments.choice("preset", as: Preset.self)
        let custom = arguments.values["points"].flatMap { $0 == .null ? nil : $0 }
        guard (preset == nil) != (custom == nil) else { throw ISimError.invalidArgument("Pass either `preset` or `points`.") }
        let device = try await context.session.resolveReady(try arguments.device)
        let gestures = try context.router.backend(.multiTouch, for: device, as: (any GestureInjecting).self)
        // Checked with SwiftUI's rotation gestures through SimBridge and the UI agent alike: no angle arrives.
        if preset == .rotate && device.kind == .simulator {
            throw ISimError.invalidArgument("Rotation does not reach apps on simulators: their touch input passes two fingers on to the app, "
                + "but without a rotation angle (pinches work). Rotate on an iPhone.")
        }

        if let custom {
            let samples = try twoFingerSamples(custom)
            try await gestures.twoFingerPath(udid: device.udid, samples)
            return .text("Moved two fingers through \(samples.count) samples in \(String(format: "%.2f", samples.last!.offset.inSeconds)) s.")
        }
        let duration = Duration.milliseconds(try arguments.int("duration_ms", default: 600, range: 100...10_000))
        let screen = try await context.screen(device, for: .multiTouch, maxDepth: 0).frame
        var center = CGPoint(x: screen.midX, y: screen.midY)
        var over = ""
        if let selector = try arguments.selector("element") {
            let (element, tree) = try await context.element(selector, on: device, for: .multiTouch)
            let visible = tree.frame.isEmpty ? element.frame : element.frame.intersection(tree.frame)
            center = CGPoint(x: visible.midX, y: visible.midY)
            over = " over " + UIElementFormatter.line(element)
        } else if let point = try arguments.point("center") {
            center = point
        }
        // The fingers stay this far inside the screen.
        let room = min(center.x - screen.minX, screen.maxX - center.x) - 8
        guard room >= 20 else { throw ISimError.invalidArgument("The center \(UIElementFormatter.point(center)) is too close to the screen's side for two fingers.") }
        let radius = try arguments.double("radius")

        let samples: [TwoFingerSample]
        let summary: String
        switch preset! {
        case .pinchIn, .pinchOut:
            let scale = try arguments.double("scale") ?? (preset == .pinchOut ? 2 : 0.5)
            guard scale > 0, scale != 1 else { throw ISimError.invalidArgument("`scale` must be positive and not 1.") }
            let (start, end) = pinchRadii(scale: scale, radius: radius, room: Double(room))
            samples = pinch(center: center, from: start, to: end, duration: duration)
            summary = "Pinched \(scale > 1 ? "out" : "in") ×\(ScreenTools.format(scale)) (fingers \(Int(start * 2)) → \(Int(end * 2)) pt apart)"
        case .rotate:
            let angle = try arguments.double("angle") ?? 90
            let r = min(radius ?? 100, Double(room))
            samples = rotation(center: center, radius: r, degrees: angle, duration: duration)
            summary = "Rotated \(ScreenTools.format(angle))° (fingers \(Int(r * 2)) pt apart)"
        }
        try await gestures.twoFingerPath(udid: device.udid, samples)
        return .text(summary + " around \(UIElementFormatter.point(center))\(over) in \(String(format: "%.1f", duration.inSeconds)) s.")
    }

    /// Start and end distance of each finger from the center: the larger one as wide as the screen allows (up to 150 pt).
    static func pinchRadii(scale: Double, radius: Double?, room: Double) -> (Double, Double) {
        if let radius {
            let start = min(radius, scale > 1 ? room / scale : room)
            return (start, start * scale)
        }
        let wide = min(150, room)
        return scale > 1 ? (max(wide / scale, 10), wide) : (wide, max(wide * scale, 10))
    }

    /// Fingers on a horizontal line through the center, moving from `from` to `to` points away from it.
    static func pinch(center: CGPoint, from: Double, to: Double, duration: Duration) -> [TwoFingerSample] {
        frames(duration).map { t, offset in
            let r = from + (to - from) * t
            return TwoFingerSample(CGPoint(x: center.x - r, y: center.y), CGPoint(x: center.x + r, y: center.y), at: offset)
        }
    }

    /// Fingers opposite each other turning around the center; y grows downwards, so a positive angle is clockwise.
    static func rotation(center: CGPoint, radius: Double, degrees: Double, duration: Duration) -> [TwoFingerSample] {
        frames(duration).map { t, offset in
            let angle = degrees * t * .pi / 180
            let dx = radius * cos(angle)
            let dy = radius * sin(angle)
            return TwoFingerSample(CGPoint(x: center.x - dx, y: center.y - dy), CGPoint(x: center.x + dx, y: center.y + dy), at: offset)
        }
    }

    /// Progress 0…1 and time of each frame of a movement.
    static func frames(_ duration: Duration) -> [(Double, Duration)] {
        let count = max(2, Int(duration / frameInterval))
        return (0...count).map { index in
            let t = Double(index) / Double(count)
            return (t, duration * t)
        }
    }

    /// `[{x1, y1, x2, y2, dt_ms}]` → samples, a frame apart between the given ones.
    static func twoFingerSamples(_ value: Value) throws(ISimError) -> [TwoFingerSample] {
        guard case .array(let items) = value, items.count >= 2 else {
            throw .invalidArgument("`points` must list at least two {x1, y1, x2, y2, dt_ms} samples.")
        }
        var given: [TwoFingerSample] = []
        var time = Duration.zero
        for (index, item) in items.enumerated() {
            let fields = ToolArguments(item.objectValue ?? [:])
            guard let x1 = try fields.double("x1"), let y1 = try fields.double("y1"),
                  let x2 = try fields.double("x2"), let y2 = try fields.double("y2")
            else { throw .invalidArgument("`points[\(index)]` needs x1, y1, x2 and y2 in points.") }
            if index > 0 { time += .milliseconds(max(0, try fields.int("dt_ms") ?? 100)) }
            given.append(TwoFingerSample(CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2), at: time))
        }
        guard time <= maxGesture else { throw .invalidArgument("The gesture takes longer than \(Int(maxGesture.inSeconds)) s.") }
        let first = interpolate(given.map { TouchSample($0.first, at: $0.offset) })
        let second = interpolate(given.map { TouchSample($0.second, at: $0.offset) })
        return zip(first, second).map { TwoFingerSample($0.point, $1.point, at: $0.offset) }
    }

    // MARK: Scrolling

    static let scrollUntilVisible = ToolDefinition(
        name: "scroll_until_visible",
        toolset: .ui,
        description: """
            Swipe until an element is on screen, e.g. a row far down a list, then return it with its frame. `direction` is \
            where the finger moves: up (the default) brings later content in. Stops when the screen no longer changes.
            """,
        inputSchema: Schema.deviceObject([
            "element": Schema.selector("The element to bring on screen."),
            "direction": Schema.string("Finger movement; up scrolls towards the end of a list.", enum: ["up", "down", "left", "right"]),
            "container": Schema.selector("The scroll view to swipe in, if not the whole screen."),
            "max_swipes": Schema.integer("Give up after this many swipes.", default: 10, minimum: 1, maximum: 50),
            "distance": Schema.number("Share of the screen or container each swipe covers, 0.1–1. Default 0.5.", minimum: 0.1, maximum: 1),
        ], required: ["element"]),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        guard let selector = try arguments.selector("element") else { throw ISimError.invalidArgument("`element` is required.") }
        let direction = try arguments.choice("direction", from: ["up", "down", "left", "right"]) ?? "up"
        let container = try arguments.selector("container")
        let maxSwipes = try arguments.int("max_swipes", default: 10, range: 1...50)
        let distance = min(max(try arguments.double("distance") ?? 0.5, 0.1), 1)
        let device = try await context.session.resolveReady(try arguments.device)
        let input = try context.router.backend(.swipe, for: device, as: (any InputInjecting).self)

        var previous: [String]?
        var swipes = 0
        while true {
            let tree = try await context.screen(device, for: .swipe)
            var area = tree.frame
            if let container {
                let box = try UIQuery.single(container, in: tree).frame
                area = tree.frame.isEmpty ? box : box.intersection(tree.frame)
            }
            let matches = tree.descendants(matching: selector)
            if let match = (selector.index.map { $0 < matches.count ? [matches[$0]] : [] } ?? matches).first(where: { isVisible($0, in: area) }) {
                let after = swipes == 0 ? "already on screen" : "after \(swipes) swipe(s)"
                return .text("Found \(after): " + UIElementFormatter.line(match) + " center " + UIElementFormatter.point(match.center))
            }
            let lines = signature(of: tree)
            if let previous, previous == lines {
                throw ISimError.notFound("No element matches \(selector): the screen stopped changing after \(swipes) swipe(s), "
                    + "so the end is reached. Try the other direction." + UIQuery.similar(to: selector, in: tree))
            }
            guard swipes < maxSwipes else {
                throw ISimError.notFound("No element matches \(selector) after \(swipes) swipe(s)." + UIQuery.similar(to: selector, in: tree))
            }
            previous = lines
            let (start, end) = UITools.swipeLine(in: area, direction: direction, distance: distance)
            // Slow enough to keep the list from flinging past the element.
            try await input.swipe(udid: device.udid, from: start, to: end, duration: .milliseconds(500))
            swipes += 1
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    /// What is on screen, without frames: a list pulled past its end bounces back, so frames still move a little
    /// when its content no longer changes.
    static func signature(of tree: UIElement) -> [String] {
        tree.flattened.dropFirst().filter { UIQuery.isOnScreen($0, screen: tree) }.map { element in
            [element.role, element.label ?? "", element.value ?? "", element.identifier ?? ""].joined(separator: "|")
        }
    }

    /// The element's middle is inside the visible area.
    static func isVisible(_ element: UIElement, in area: CGRect) -> Bool {
        !element.frame.isEmpty && (area.isEmpty || area.contains(element.center))
    }

    // MARK: Shake

    static let shake = ToolDefinition(
        name: "shake",
        toolset: .ui,
        description: "Shake the device, like the Simulator's Shake Gesture: the app gets a motion-shake event (debug menus, undo). Simulators only.",
        inputSchema: Schema.deviceObject(),
        annotations: .mutating
    ) { arguments, context in
        try context.requireXcode()
        let device = try await context.session.resolveReady(try arguments.device)
        try await context.router.backend(.shake, for: device, as: (any ShakeSimulating).self).shake(udid: device.udid)
        return .text("Shook \"\(device.name)\".")
    }
}
