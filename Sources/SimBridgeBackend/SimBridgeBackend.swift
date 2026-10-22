import CoreGraphics
import DeviceCore
import Foundation
import SimBridge

/// Input and UI inspection on simulators through private APIs (spike 0A): HID events go to `dtuhidd`
/// inside the simulator, the UI tree comes from AccessibilityPlatformTranslation over CoreSimulator.
public struct SimBridgeBackend: InputInjecting, AccessibilityProviding {
    /// Enough for any real screen; a runaway tree (a huge collection view) is cut here.
    public static let maxElements = 3000
    static let treeTimeout: TimeInterval = 15

    private let developerDir: String?
    private let orientation: any OrientationControlling
    private let state = State()

    /// `orientation` tells which way a landscape interface is turned; `developerDir` selects CoreSimulator's device set.
    public init(developerDir: String?, orientation: any OrientationControlling) {
        self.developerDir = developerDir
        self.orientation = orientation
    }

    // MARK: Input

    public func tap(udid: String, at point: CGPoint, count: Int, hold: Duration) async throws {
        let geometry = try await geometry(udid: udid, checking: [point])
        try await channel(udid).run(HIDScript.tap(at: geometry.digitizerPoint(point), count: count, hold: hold))
    }

    public func swipe(udid: String, from start: CGPoint, to end: CGPoint, duration: Duration) async throws {
        let geometry = try await geometry(udid: udid, checking: [start, end])
        try await channel(udid).run(HIDScript.swipe(from: geometry.digitizerPoint(start), to: geometry.digitizerPoint(end), duration: duration))
    }

    public func pressKeys(udid: String, _ strokes: [KeyStroke]) async throws {
        try await channel(udid).run(HIDScript.keys(strokes))
    }

    public func pressButton(udid: String, _ button: HardwareButton, hold: Duration) async throws {
        try await channel(udid).run(HIDScript.button(button, hold: hold))
    }

    /// Checks HID input end to end: the daemon answers a barrier.
    public func checkInput(udid: String) async throws {
        try await channel(udid).run([])
    }

    // MARK: Accessibility

    public func uiTree(udid: String, maxDepth: Int?) async throws -> UIElement {
        let simulator = try await state.simulator(udid: udid, developerDir: try developerDirectory())
        let accessibility = try Self.accessibility()
        do {
            let root = try await accessibility.frontmostApplication(
                of: simulator, maxDepth: maxDepth ?? -1, maxElements: Self.maxElements, timeout: Self.treeTimeout)
            return UIElement(root)
        } catch {
            throw Self.translate(error)
        }
    }

    public func element(udid: String, at point: CGPoint) async throws -> UIElement? {
        let simulator = try await state.simulator(udid: udid, developerDir: try developerDirectory())
        let accessibility = try Self.accessibility()
        do {
            return UIElement(try await accessibility.element(at: point, simulator: simulator, timeout: Self.treeTimeout))
        } catch let error as SBError where error.code == .accessibility {
            return nil
        } catch {
            throw Self.translate(error)
        }
    }

    // MARK: Helpers

    private func channel(_ udid: String) async throws -> HIDChannel {
        try await state.channel(udid: udid, developerDir: try developerDirectory())
    }

    /// How interface points map to the digitizer right now; fails for points off the screen.
    private func geometry(udid: String, checking points: [CGPoint]) async throws -> TouchGeometry {
        let simulator = try await state.simulator(udid: udid, developerDir: try developerDirectory())
        let appFrame = try? await uiTree(udid: udid, maxDepth: 0).frame.size
        let isPad = simulator.productFamily == 2
        // The app frame alone settles a portrait iPhone; the device orientation costs a devicectl call.
        var deviceOrientation: DeviceOrientation?
        if isPad || appFrame.map({ $0.width >= $0.height }) ?? true {
            deviceOrientation = try? await orientation.orientation(udid: udid).orientation
        }
        let geometry = TouchGeometry(
            screen: simulator.screenSize,
            rotation: TouchGeometry.rotation(appFrame: appFrame, device: deviceOrientation, isPad: isPad))
        if let outside = points.first(where: { !geometry.contains($0) }) {
            let size = geometry.interfaceSize
            throw ISimError.invalidArgument(
                "Point (\(UIElementFormatter.number(outside.x)),\(UIElementFormatter.number(outside.y))) is outside the screen, "
                    + "which is \(UIElementFormatter.number(size.width))×\(UIElementFormatter.number(size.height)) pt.")
        }
        return geometry
    }

    private func developerDirectory() throws(ISimError) -> String {
        guard let developerDir else { throw .xcodeUnavailable("Xcode was not found; simulator input needs its CoreSimulator.") }
        return developerDir
    }

    private static func accessibility() throws -> SBAccessibility {
        do {
            return try SBAccessibility.shared()
        } catch {
            throw translate(error)
        }
    }

    static func translate(_ error: any Error) -> any Error {
        guard let error = error as? SBError else { return error }
        return ISimError.commandFailed(command: "SimBridge", message: error.localizedDescription)
    }

    /// Simulators and HID channels, created on first use.
    private actor State {
        private var simulators: [String: SBSimulator] = [:]
        private var channels: [String: HIDChannel] = [:]

        func simulator(udid: String, developerDir: String) throws -> SBSimulator {
            if let simulator = simulators[udid] { return simulator }
            do {
                let simulator = try SBSimulator(udid: udid, developerDir: developerDir)
                simulators[udid] = simulator
                return simulator
            } catch {
                throw SimBridgeBackend.translate(error)
            }
        }

        func channel(udid: String, developerDir: String) throws -> HIDChannel {
            if let channel = channels[udid] { return channel }
            let channel = HIDChannel(simulator: try simulator(udid: udid, developerDir: developerDir))
            channels[udid] = channel
            return channel
        }
    }
}
