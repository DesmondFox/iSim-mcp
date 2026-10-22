public struct SimRuntime: Decodable, Sendable, Equatable {
    public var identifier: String
    /// e.g. "iOS 27.0"
    public var name: String
    public var version: String
    public var platform: String?
    public var isAvailable: Bool
    public var availabilityError: String?
}
