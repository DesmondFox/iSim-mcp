import DeviceCore
import DevicectlBackend
import Foundation
import ProcessKit
import SimBridgeBackend
import SimctlBackend

/// Everything a tool handler needs. One instance per server.
public struct ToolContext: Sendable {
    public let session: DeviceSession
    public let router: ToolRouter
    public let runner: any ProcessRunning
    public let xcode: Result<XcodeEnvironment, ISimError>
    public let simctl: SimctlBackend
    public let devicectl: DevicectlBackend
    public let simbridge: SimBridgeBackend
    public let displays: DisplayCache
    public let accessibility: AccessibilityPreparation
    /// Where screenshots go when the caller asks for a path but gives no `save_path`.
    public let screenshotDirectory: URL

    /// `uiBackend` replaces SimBridge for simulator input and accessibility (tests).
    public init(
        runner: any ProcessRunning,
        xcode: Result<XcodeEnvironment, ISimError>,
        screenshotDirectory: URL = ToolContext.defaultScreenshotDirectory,
        uiBackend: (any InputInjecting & AccessibilityProviding)? = nil
    ) {
        let simctl = SimctlBackend(runner: runner)
        let devicectl = DevicectlBackend(runner: runner)
        let simbridge = SimBridgeBackend(developerDir: (try? xcode.get())?.developerDir, orientation: devicectl)
        self.runner = runner
        self.xcode = xcode
        self.simctl = simctl
        self.devicectl = devicectl
        self.simbridge = simbridge
        self.session = DeviceSession(sources: [simctl, devicectl])
        self.router = ToolRouter(backends: [.simctl: simctl, .devicectl: devicectl, .simbridge: uiBackend ?? simbridge])
        self.displays = DisplayCache()
        self.accessibility = AccessibilityPreparation(simctl: simctl)
        self.screenshotDirectory = screenshotDirectory
    }

    public static var defaultScreenshotDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iSim-mcp/screenshots", isDirectory: true)
    }

    /// Fails every device tool with a clear message when Xcode is missing or too old.
    public func requireXcode() throws(ISimError) {
        let environment = try xcode.get()
        guard environment.isSupported else {
            throw .xcodeUnavailable("Xcode \(environment.version) is not supported; iSim-mcp needs Xcode \(XcodeEnvironment.minimumVersion) or newer.")
        }
    }
}

/// Display scale per device; it never changes, so it is fetched once.
public actor DisplayCache {
    private var scales: [String: Double] = [:]

    public init() {}

    public func scale(for device: Device, provider: any DisplayInfoProviding) async -> Double? {
        if let scale = scales[device.udid] { return scale }
        guard let info = try? await provider.displayInfo(udid: device.udid) else { return nil }
        scales[device.udid] = info.scale
        return info.scale
    }
}

/// Apps in a simulator load their accessibility runtime at launch, and only while the simulator's
/// `ApplicationAccessibilityEnabled` preference is on (XCUITest switches it on for its runs and back off after).
/// Without it, describe_ui sees an empty app. Checked once per simulator and session.
public actor AccessibilityPreparation {
    private let simctl: SimctlBackend
    private var prepared: Set<String> = []

    public init(simctl: SimctlBackend) {
        self.simctl = simctl
    }

    /// Turns the preference on if needed. Returns true when it was off: apps already running must be relaunched.
    @discardableResult
    public func prepare(_ device: Device) async -> Bool {
        guard device.kind == .simulator, !prepared.contains(device.udid) else { return false }
        guard let enabled = try? await simctl.isApplicationAccessibilityEnabled(udid: device.udid) else { return false }
        if !enabled {
            guard (try? await simctl.enableApplicationAccessibility(udid: device.udid)) != nil else { return false }
        }
        prepared.insert(device.udid)
        return !enabled
    }

    /// Erasing a simulator resets the preference.
    public func forget(_ udid: String) {
        prepared.remove(udid)
    }
}
