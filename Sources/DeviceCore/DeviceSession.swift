import Foundation

/// Session state shared by all tools: the device list and the active device.
public actor DeviceSession {
    public struct Listing: Sendable {
        public var devices: [Device]
        /// Errors of sources that failed while others succeeded (e.g. devicectl is broken, simctl works).
        public var warnings: [String]
    }

    private let sources: [any DeviceListing]
    public private(set) var activeUDID: String?

    public init(sources: [any DeviceListing]) {
        self.sources = sources
    }

    public func listDevices() async throws -> Listing {
        let results = await withTaskGroup(of: (Int, Result<[Device], any Error>).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    do { return (index, .success(try await source.listDevices())) } catch { return (index, .failure(error)) }
                }
            }
            var results: [(Int, Result<[Device], any Error>)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var devices: [Device] = []
        var errors: [any Error] = []
        for result in results {
            switch result {
            case .success(let list): devices += list
            case .failure(let error): errors.append(error)
            }
        }
        if devices.isEmpty, let first = errors.first { throw first }
        return Listing(devices: devices, warnings: errors.map { "\($0)" })
    }

    /// Resolves the target device of a tool call; see `DeviceResolver`.
    public func resolve(_ query: String?) async throws -> Device {
        let devices = try await listDevices().devices
        return try DeviceResolver.resolve(query: query, activeUDID: activeUDID, devices: devices)
    }

    /// Like `resolve`, but also requires the device to be booted/connected.
    public func resolveReady(_ query: String?) async throws -> Device {
        let device = try await resolve(query)
        guard device.state.isReady else { throw ISimError.deviceNotReady(device) }
        return device
    }

    @discardableResult
    public func setActive(_ query: String) async throws -> Device {
        let devices = try await listDevices().devices
        let device = try DeviceResolver.match(query, in: devices)
        activeUDID = device.udid
        return device
    }

    public func clearActive() {
        activeUDID = nil
    }
}
