import DeviceCore
import DevicectlBackend
import Foundation
import ProcessKit
import SimctlBackend

/// Everything a tool handler needs. One instance per server.
public struct ToolContext: Sendable {
    public let session: DeviceSession
    public let router: ToolRouter
    public let runner: any ProcessRunning
    public let xcode: Result<XcodeEnvironment, ISimError>
    public let simctl: SimctlBackend
    public let devicectl: DevicectlBackend
    public let displays: DisplayCache
    /// Where screenshots go when the caller asks for a path but gives no `save_path`.
    public let screenshotDirectory: URL

    public init(
        runner: any ProcessRunning,
        xcode: Result<XcodeEnvironment, ISimError>,
        screenshotDirectory: URL = ToolContext.defaultScreenshotDirectory
    ) {
        let simctl = SimctlBackend(runner: runner)
        let devicectl = DevicectlBackend(runner: runner)
        self.runner = runner
        self.xcode = xcode
        self.simctl = simctl
        self.devicectl = devicectl
        self.session = DeviceSession(sources: [simctl, devicectl])
        self.router = ToolRouter(backends: [.simctl: simctl, .devicectl: devicectl])
        self.displays = DisplayCache()
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
