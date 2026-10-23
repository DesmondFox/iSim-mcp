import CoreGraphics
import DeviceCore
import Foundation
import ProcessKit

/// Input and UI inspection through the on-device XCUITest agent: iPhones, and simulators where it was started
/// with ui_agent. The first call on a device builds and starts the agent.
public struct AgentBackend: InputInjecting, AccessibilityProviding, TextTyping {
    public let manager: AgentManager
    private let resolve: @Sendable (String) async throws -> Device

    /// `resolve` finds the device of a UDID: the agent is reached differently on simulators and iPhones.
    public init(manager: AgentManager, resolve: @escaping @Sendable (String) async throws -> Device) {
        self.manager = manager
        self.resolve = resolve
    }

    // MARK: Input

    public func tap(udid: String, at point: CGPoint, count: Int, hold: Duration) async throws {
        try await call(udid, "POST", "/tap", ["x": point.x, "y": point.y, "count": count, "hold_ms": milliseconds(hold)],
                       timeout: .seconds(10) + hold * count)
    }

    public func swipe(udid: String, from start: CGPoint, to end: CGPoint, duration: Duration) async throws {
        try await call(udid, "POST", "/swipe", [
            "from_x": start.x, "from_y": start.y, "to_x": end.x, "to_y": end.y, "duration_ms": milliseconds(duration),
        ], timeout: .seconds(10) + duration)
    }

    public func pressKeys(udid: String, _ strokes: [KeyStroke]) async throws {
        let keys = try strokes.map { stroke in
            guard let key = HIDKeyboard.key(for: stroke) else {
                throw ISimError.invalidArgument(String(format: "HID usage 0x%02X has no key the UI agent can press.", stroke.usage))
            }
            return ["key": key.key, "modifiers": key.modifiers.map(\.rawValue)] as [String: Any]
        }
        try await call(udid, "POST", "/keys", ["keys": keys], timeout: .seconds(10 + strokes.count))
    }

    public func pressButton(udid: String, _ button: HardwareButton, hold: Duration) async throws {
        guard button != .siri else { throw ISimError.invalidArgument("The UI agent cannot press the Siri button.") }
        try await call(udid, "POST", "/button", ["name": button.rawValue], timeout: .seconds(10))
    }

    /// Any script; the agent types 60 characters a second.
    public func typeText(udid: String, _ text: String) async throws {
        try await call(udid, "POST", "/type", ["text": text], timeout: .seconds(10 + text.count / 60))
    }

    // MARK: Accessibility

    public func uiTree(udid: String, maxDepth: Int?) async throws -> UIElement {
        let path = "/tree" + (maxDepth.map { "?max_depth=\($0)" } ?? "")
        return try AgentTree.screen(from: try await call(udid, "GET", path, nil, timeout: .seconds(30)))
    }

    public func element(udid: String, at point: CGPoint) async throws -> UIElement? {
        AgentTree.element(at: point, in: try await uiTree(udid: udid, maxDepth: nil))
    }

    // MARK: Requests

    /// Starts the agent if needed. When it is not listening (it stopped), starts it once more and retries:
    /// the request never reached it.
    @discardableResult
    private func call(_ udid: String, _ method: String, _ path: String, _ body: [String: Any]?, timeout: Duration) async throws -> Data {
        let device = try await resolve(udid)
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        do {
            return try await manager.client(for: device).request(method, path, body: data, timeout: timeout)
        } catch AgentConnectionError.refused {
            await manager.forget(udid)
            return try await manager.client(for: device).request(method, path, body: data, timeout: timeout)
        } catch AgentConnectionError.transfer(let message) {
            await manager.forget(udid)
            let reason = await manager.lastExit(udid)
            throw ISimError.commandFailed(command: "UI agent \(method) \(path)", message: message
                + (reason.map { " \($0)" } ?? "") + " The next UI tool starts the agent again.")
        } catch let AgentConnectionError.agent(_, message) {
            throw ISimError.commandFailed(command: "UI agent \(method) \(path)", message: message)
        }
    }

    private func milliseconds(_ duration: Duration) -> Int {
        Int(duration.inSeconds * 1000)
    }
}
