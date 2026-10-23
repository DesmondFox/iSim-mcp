import AgentBackend
import DeviceCore

/// Picks the backend for a capability on a device: `CapabilityMatrix` says which, this resolves the instance.
/// A simulator whose UI agent was started with ui_agent sends its UI tools to the agent instead of SimBridge.
public struct ToolRouter: Sendable {
    public let matrix: CapabilityMatrix
    private let backends: [BackendID: any Sendable]
    private let agentRouting: AgentRouting?

    public init(matrix: CapabilityMatrix = .standard, backends: [BackendID: any Sendable], agentRouting: AgentRouting? = nil) {
        self.matrix = matrix
        self.backends = backends
        self.agentRouting = agentRouting
    }

    public func backend<T>(_ capability: Capability, for device: Device, as type: T.Type = T.self) throws(ISimError) -> T {
        var id = try matrix.backend(for: capability, on: device.kind)
        if device.kind == .simulator, CapabilityMatrix.agentCapabilities.contains(capability), agentRouting?.usesAgent(device.udid) == true {
            id = .agent
        }
        guard let backend = backends[id] as? T else {
            // A programming error: the matrix names a backend that is not registered or lacks the protocol.
            preconditionFailure("Backend \(id) does not provide \(T.self) for \(capability)")
        }
        return backend
    }
}
