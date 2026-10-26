import CoreGraphics

/// Where one finger is at a moment of a gesture, in points.
public struct TouchSample: Sendable, Equatable {
    public var point: CGPoint
    /// Time since the gesture started.
    public var offset: Duration

    public init(_ point: CGPoint, at offset: Duration) {
        self.point = point
        self.offset = offset
    }
}

/// Where both fingers of a two-finger gesture are at a moment, in points.
public struct TwoFingerSample: Sendable, Equatable {
    public var first: CGPoint
    public var second: CGPoint
    /// Time since the gesture started.
    public var offset: Duration

    public init(_ first: CGPoint, _ second: CGPoint, at offset: Duration) {
        self.first = first
        self.second = second
        self.offset = offset
    }
}
