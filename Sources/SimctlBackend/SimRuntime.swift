public struct SimRuntime: Decodable, Sendable, Equatable {
    public var identifier: String
    /// e.g. "iOS 27.0"
    public var name: String
    public var version: String
    public var buildversion: String?
    public var platform: String?
    public var isAvailable: Bool
    public var availabilityError: String?
    public var supportedDeviceTypes: [SimDeviceType]?
}

public struct SimDeviceType: Decodable, Sendable, Equatable {
    /// e.g. "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
    public var identifier: String
    /// e.g. "iPhone 16 Pro"
    public var name: String
    /// "iPhone", "iPad", …
    public var productFamily: String?
}
