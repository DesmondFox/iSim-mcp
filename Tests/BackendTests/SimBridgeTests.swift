import CoreGraphics
import DeviceCore
@testable import SimBridgeBackend
import Testing
import XPC

struct DTUHIDMessageTests {
    private func string(_ object: xpc_object_t, _ key: String) -> String? {
        xpc_dictionary_get_string(object, key).map { String(cString: $0) }
    }

    @Test func touchesAreDigitizerEventsWithUInt64Fields() throws {
        let message = DTUHIDMessage.touch(CGPoint(x: 0.25, y: 0.5), phase: .end).xpcObject()
        #expect(string(message, "messageType") == "IndigoDigitizerEvent")
        #expect(string(message, "featureIdentifier") == "com.apple.coredevice.feature.remote.hid.digitizer")
        #expect(!xpc_dictionary_get_bool(message, "isBarrier"))
        let payload = try #require(xpc_dictionary_get_dictionary(message, "payload"))
        #expect(xpc_get_type(xpc_dictionary_get_value(payload, "eventType")!) == XPC_TYPE_UINT64)
        #expect(xpc_dictionary_get_uint64(payload, "eventType") == 2)
        let point = try #require(xpc_dictionary_get_dictionary(payload, "pointOne"))
        #expect(xpc_dictionary_get_double(point, "x") == 0.25)
        #expect(xpc_dictionary_get_double(point, "y") == 0.5)
    }

    @Test func buttonsUseTheConsumerPage() throws {
        let message = DTUHIDMessage.button(.home, isDown: true).xpcObject()
        #expect(string(message, "messageType") == "IndigoButtonEvent")
        let payload = try #require(xpc_dictionary_get_dictionary(message, "payload"))
        #expect(xpc_dictionary_get_uint64(payload, "usagePage") == 0x0C)
        #expect(xpc_dictionary_get_uint64(payload, "usageCode") == 0x40)
        #expect(xpc_dictionary_get_uint64(payload, "state") == 1)
    }

    @Test func barrierIsAKeyboardEventWithoutAKey() throws {
        let message = DTUHIDMessage.barrier.xpcObject()
        #expect(xpc_dictionary_get_bool(message, "isBarrier"))
        let payload = try #require(xpc_dictionary_get_dictionary(message, "payload"))
        #expect(xpc_dictionary_get_uint64(payload, "usageCode") == 0)
        #expect(xpc_dictionary_get_uint64(payload, "state") == 2)
    }
}

struct HIDScriptTests {
    let point = CGPoint(x: 0.5, y: 0.5)

    @Test func doubleTapPausesBetweenTaps() {
        #expect(HIDScript.tap(at: point, count: 2, hold: .milliseconds(60)) == [
            .send(.touch(point, phase: .start)), .wait(.milliseconds(60)), .send(.touch(point, phase: .end)),
            .wait(HIDScript.tapInterval),
            .send(.touch(point, phase: .start)), .wait(.milliseconds(60)), .send(.touch(point, phase: .end)),
        ])
    }

    @Test func swipeMovesEveryFrameAndEndsAtTheTarget() throws {
        let steps = HIDScript.swipe(from: CGPoint(x: 0.5, y: 0.8), to: CGPoint(x: 0.5, y: 0.2), duration: .milliseconds(160))
        let messages = steps.compactMap { if case .send(let message) = $0 { message } else { nil } }
        #expect(messages.first == .touch(CGPoint(x: 0.5, y: 0.8), phase: .start))
        #expect(messages.last == .touch(CGPoint(x: 0.5, y: 0.2), phase: .end))
        #expect(messages.count == 12, "start, 10 moves, end")
        let pauses = steps.compactMap { if case .wait(let duration) = $0 { duration } else { nil } }
        #expect(pauses.reduce(.zero, +) == .milliseconds(160))
    }

    @Test func modifiersWrapTheKey() {
        #expect(HIDScript.keys([KeyStroke(usage: 0x04, modifiers: [.command, .shift])]) == [
            .send(.key(usage: 0xE3, isDown: true)), .send(.key(usage: 0xE1, isDown: true)),
            .send(.key(usage: 0x04, isDown: true)), .send(.key(usage: 0x04, isDown: false)),
            .send(.key(usage: 0xE1, isDown: false)), .send(.key(usage: 0xE3, isDown: false)),
        ])
    }
}

struct TouchGeometryTests {
    let screen = CGSize(width: 402, height: 874)

    // Each case was checked by tapping "Item 1" of the test app on an iPhone 16 Pro simulator.
    @Test func mapsInterfacePointsToThePortraitDigitizer() {
        let portrait = TouchGeometry(screen: screen, rotation: .portrait)
        #expect(portrait.digitizerPoint(CGPoint(x: 201, y: 437)) == CGPoint(x: 0.5, y: 0.5))
        let left = TouchGeometry(screen: screen, rotation: .landscapeLeft)
        #expect(left.digitizerPoint(CGPoint(x: 437, y: 358)) == CGPoint(x: 44.0 / 402, y: 437.0 / 874))
        let right = TouchGeometry(screen: screen, rotation: .landscapeRight)
        #expect(right.digitizerPoint(CGPoint(x: 437, y: 358)) == CGPoint(x: 358.0 / 402, y: 437.0 / 874))
        let upsideDown = TouchGeometry(screen: screen, rotation: .upsideDown)
        #expect(upsideDown.digitizerPoint(CGPoint(x: 0, y: 0)) == CGPoint(x: 1, y: 1))
    }

    @Test func boundsFollowTheRotation() {
        let left = TouchGeometry(screen: screen, rotation: .landscapeLeft)
        #expect(left.interfaceSize == CGSize(width: 874, height: 402))
        #expect(left.contains(CGPoint(x: 800, y: 100)))
        #expect(!left.contains(CGPoint(x: 100, y: 800)))
    }

    @Test func rotationComesFromTheAppFrameAndDeviceOrientation() {
        let landscape = CGSize(width: 874, height: 402)
        let portrait = CGSize(width: 402, height: 874)
        #expect(TouchGeometry.rotation(appFrame: landscape, device: .landscapeRight, isPad: false) == .landscapeRight)
        #expect(TouchGeometry.rotation(appFrame: landscape, device: .landscapeLeft, isPad: false) == .landscapeLeft)
        // The home screen of an iPhone stays portrait on a device turned sideways.
        #expect(TouchGeometry.rotation(appFrame: portrait, device: .landscapeLeft, isPad: false) == .portrait)
        #expect(TouchGeometry.rotation(appFrame: portrait, device: .portraitUpsideDown, isPad: false) == .portrait)
        #expect(TouchGeometry.rotation(appFrame: portrait, device: .portraitUpsideDown, isPad: true) == .upsideDown)
        // An app without accessibility: trust the device.
        #expect(TouchGeometry.rotation(appFrame: .zero, device: .landscapeRight, isPad: false) == .landscapeRight)
        #expect(TouchGeometry.rotation(appFrame: nil, device: nil, isPad: false) == .portrait)
    }
}

struct AXRolesTests {
    @Test func mapsMacRolesToShortNames() {
        #expect(AXRoles.role("AXButton", subrole: nil) == "button")
        #expect(AXRoles.role("AXCheckBox", subrole: "AXSwitch") == "switch")
        #expect(AXRoles.role("AXTextField", subrole: "AXSecureTextField") == "secure_text_field")
        #expect(AXRoles.role("AXTextField", subrole: "AXSearchField") == "search_field")
        #expect(AXRoles.role("AXStaticText", subrole: nil) == "text")
        #expect(AXRoles.role("AXRadioButton", subrole: nil) == "radio_button")
        #expect(AXRoles.role(nil, subrole: nil) == "element")
    }
}
