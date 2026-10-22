import DeviceCore

/// Picks the backend for a capability on a device: `CapabilityMatrix` says which, this resolves the instance.
public struct ToolRouter: Sendable {
    public let matrix: CapabilityMatrix
    private let backends: [BackendID: any Sendable]

    public init(matrix: CapabilityMatrix = .standard, backends: [BackendID: any Sendable]) {
        self.matrix = matrix
        self.backends = backends
    }

    public func backend<T>(_ capability: Capability, for device: Device, as type: T.Type = T.self) throws(ISimError) -> T {
        let id = try matrix.backend(for: capability, on: device.kind)
        guard let backend = backends[id] as? T else {
            // A programming error: the matrix names a backend that is not registered or lacks the protocol.
            preconditionFailure("Backend \(id) does not provide \(T.self) for \(capability)")
        }
        return backend
    }
}
