import CoreGraphics
import DeviceCore
import Foundation
import XPC

/// A message to `dtuhidd`, the CoreDevice HID daemon inside the simulator. Plain XPC dictionaries:
/// `{messageType, isBarrier, featureIdentifier, payload}`, numbers as uint64 (format from spike 0A and idb's DTUHIDModels).
struct DTUHIDMessage: Equatable, Sendable {
    enum Value: Equatable, Sendable {
        case uint(UInt64)
        case double(Double)
        case dictionary([String: Value])
    }

    /// One service takes touches, keys and buttons alike.
    static let service = "com.apple.coredevice.feature.remote.hid.digitizer"

    var type: String
    var isBarrier = false
    var payload: [String: Value]

    enum TouchPhase: UInt64 {
        case start = 0
        case move = 1
        case end = 2
    }

    // HIDButtonState is 1-based; 0 is rejected.
    private static let down: UInt64 = 1
    private static let up: UInt64 = 2

    /// `point` is a fraction (0…1) of the native portrait screen.
    static func touch(_ point: CGPoint, phase: TouchPhase) -> DTUHIDMessage {
        DTUHIDMessage(type: "IndigoDigitizerEvent", payload: [
            "pointOne": .dictionary(["x": .double(Double(point.x)), "y": .double(Double(point.y))]),
            "eventType": .uint(phase.rawValue),
            "edge": .uint(0),
            "target": .uint(0),
        ])
    }

    static func key(usage: UInt32, isDown: Bool) -> DTUHIDMessage {
        DTUHIDMessage(type: "IndigoKeyboardButtonEvent", payload: [
            "usageCode": .uint(UInt64(usage)),
            "state": .uint(isDown ? down : up),
        ])
    }

    static func button(_ button: HardwareButton, isDown: Bool) -> DTUHIDMessage {
        DTUHIDMessage(type: "IndigoButtonEvent", payload: [
            "usagePage": .uint(0x0C),
            "usageCode": .uint(consumerUsage(button)),
            "state": .uint(isDown ? down : up),
        ])
    }

    /// The only message the daemon answers, so a reply proves it is running and has activated this peer.
    /// Usage 0 means "no event": the guest sees no key press.
    static let barrier = DTUHIDMessage(type: "IndigoKeyboardButtonEvent", isBarrier: true, payload: [
        "usageCode": .uint(0),
        "state": .uint(up),
    ])

    /// HID consumer page (0x0C) usages of the hardware buttons.
    static func consumerUsage(_ button: HardwareButton) -> UInt64 {
        switch button {
        case .home: 0x40
        case .lock: 0x30
        case .side: 0x95
        case .siri: 0xCF
        case .volumeUp: 0xE9
        case .volumeDown: 0xEA
        }
    }

    func xpcObject() -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "messageType", type)
        xpc_dictionary_set_bool(message, "isBarrier", isBarrier)
        xpc_dictionary_set_string(message, "featureIdentifier", Self.service)
        xpc_dictionary_set_value(message, "payload", Self.xpc(.dictionary(payload)))
        return message
    }

    private static func xpc(_ value: Value) -> xpc_object_t {
        switch value {
        case .uint(let number): return xpc_uint64_create(number)
        case .double(let number): return xpc_double_create(number)
        case .dictionary(let entries):
            let dictionary = xpc_dictionary_create(nil, nil, 0)
            for (key, entry) in entries { xpc_dictionary_set_value(dictionary, key, xpc(entry)) }
            return dictionary
        }
    }
}

/// A gesture as messages and pauses between them.
enum HIDStep: Equatable, Sendable {
    case send(DTUHIDMessage)
    case wait(Duration)
}

enum HIDScript {
    /// Pause between the taps of a double tap: well within the system's double-tap interval.
    static let tapInterval = Duration.milliseconds(80)
    /// Moves are sent at the display's frame rate.
    static let moveInterval = Duration.milliseconds(16)

    /// Points are digitizer fractions.
    static func tap(at point: CGPoint, count: Int, hold: Duration) -> [HIDStep] {
        var steps: [HIDStep] = []
        for index in 0..<max(count, 1) {
            if index > 0 { steps.append(.wait(tapInterval)) }
            steps += [.send(.touch(point, phase: .start)), .wait(hold), .send(.touch(point, phase: .end))]
        }
        return steps
    }

    /// A straight line at constant speed, lifted at full speed: scroll views keep scrolling a little after it.
    static func swipe(from start: CGPoint, to end: CGPoint, duration: Duration) -> [HIDStep] {
        let moves = max(2, Int(duration / moveInterval))
        let pause = duration / moves
        var steps: [HIDStep] = [.send(.touch(start, phase: .start))]
        for index in 1...moves {
            let t = CGFloat(index) / CGFloat(moves)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            steps += [.wait(pause), .send(.touch(point, phase: .move))]
        }
        steps.append(.send(.touch(end, phase: .end)))
        return steps
    }

    static func keys(_ strokes: [KeyStroke]) -> [HIDStep] {
        strokes.flatMap { stroke in
            stroke.modifiers.map { HIDStep.send(.key(usage: $0.usage, isDown: true)) }
                + [.send(.key(usage: stroke.usage, isDown: true)), .send(.key(usage: stroke.usage, isDown: false))]
                + stroke.modifiers.reversed().map { HIDStep.send(.key(usage: $0.usage, isDown: false)) }
        }
    }

    static func button(_ button: HardwareButton, hold: Duration) -> [HIDStep] {
        [.send(.button(button, isDown: true)), .wait(hold), .send(.button(button, isDown: false))]
    }
}
