import CoreGraphics
import DeviceCore

/// Converts interface points (what screenshots and the UI tree show) to the digitizer's fractions of the
/// native portrait screen. `dtuhidd` does not rotate touches itself; checked on an iPhone 16 Pro simulator.
struct TouchGeometry: Equatable, Sendable {
    enum Rotation: Equatable, Sendable {
        case portrait
        case upsideDown
        /// Interface of a device turned to landscapeLeft (top of the interface at the device's left edge).
        case landscapeLeft
        case landscapeRight
    }

    /// Native portrait screen in points.
    var screen: CGSize
    var rotation: Rotation

    /// Size of the interface in points.
    var interfaceSize: CGSize {
        switch rotation {
        case .portrait, .upsideDown: screen
        case .landscapeLeft, .landscapeRight: CGSize(width: screen.height, height: screen.width)
        }
    }

    func contains(_ point: CGPoint) -> Bool {
        point.x >= 0 && point.y >= 0 && point.x <= interfaceSize.width && point.y <= interfaceSize.height
    }

    func digitizerPoint(_ point: CGPoint) -> CGPoint {
        let native: CGPoint = switch rotation {
        case .portrait: point
        case .upsideDown: CGPoint(x: screen.width - point.x, y: screen.height - point.y)
        case .landscapeLeft: CGPoint(x: screen.width - point.y, y: point.x)
        case .landscapeRight: CGPoint(x: point.y, y: screen.height - point.x)
        }
        return CGPoint(x: native.x / screen.width, y: native.y / screen.height)
    }

    /// The rotation of the interface, from the frontmost app's frame and the device orientation.
    /// The app frame says portrait or landscape: an iPhone's home screen stays portrait on a device turned sideways.
    /// The device orientation says which side; without it, portrait and landscapeLeft are the likely ones.
    /// Only iPads turn the interface upside down.
    static func rotation(appFrame: CGSize?, device: DeviceOrientation?, isPad: Bool) -> Rotation {
        let isLandscape: Bool
        if let appFrame, appFrame.width > 0, appFrame.height > 0 {
            isLandscape = appFrame.width > appFrame.height
        } else {
            isLandscape = device == .landscapeLeft || device == .landscapeRight
        }
        if isLandscape {
            return device == .landscapeRight ? .landscapeRight : .landscapeLeft
        }
        return isPad && device == .portraitUpsideDown ? .upsideDown : .portrait
    }
}
