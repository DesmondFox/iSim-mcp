import Foundation

// Models of the device environment the `system` and `ui` tools change: orientation, appearance,
// permissions, location, status bar, biometrics.

/// Interface orientations a device can be rotated to.
public enum DeviceOrientation: String, Sendable, CaseIterable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight
}

public struct OrientationState: Sendable, Equatable {
    /// Orientation of the interface; a device lying flat keeps the last upright one. nil if unknown.
    public var orientation: DeviceOrientation?
    /// What the sensors say when it differs: "faceUp", "faceDown", "unknown".
    public var physical: String?
    public var isLocked: Bool

    public init(orientation: DeviceOrientation?, physical: String? = nil, isLocked: Bool = false) {
        self.orientation = orientation
        self.physical = physical
        self.isLocked = isLocked
    }
}

public enum InterfaceStyle: String, Sendable, CaseIterable {
    case light
    case dark
}

/// Dynamic Type sizes, named as devicectl and simctl spell them.
public enum ContentSize: String, Sendable, CaseIterable {
    case extraSmall = "extra-small"
    case small
    case medium
    case large
    case extraLarge = "extra-large"
    case extraExtraLarge = "extra-extra-large"
    case extraExtraExtraLarge = "extra-extra-extra-large"
    case accessibilityMedium = "accessibility-medium"
    case accessibilityLarge = "accessibility-large"
    case accessibilityExtraLarge = "accessibility-extra-large"
    case accessibilityExtraExtraLarge = "accessibility-extra-extra-large"
    case accessibilityExtraExtraExtraLarge = "accessibility-extra-extra-extra-large"

    /// Accessibility sizes need "Larger Accessibility Sizes" switched on.
    public var isAccessibility: Bool { rawValue.hasPrefix("accessibility-") }

    /// "Extra Large" (devicectl's display name) → `.extraLarge`.
    public init?(displayName: String) {
        self.init(rawValue: displayName.lowercased().replacingOccurrences(of: " ", with: "-"))
    }
}

/// Appearance settings; as a change request, nil fields stay as they are.
public struct AppearanceSettings: Sendable, Equatable {
    public var style: InterfaceStyle?
    public var contentSize: ContentSize?
    public var increaseContrast: Bool?
    public var reduceMotion: Bool?

    public init(style: InterfaceStyle? = nil, contentSize: ContentSize? = nil, increaseContrast: Bool? = nil, reduceMotion: Bool? = nil) {
        self.style = style
        self.contentSize = contentSize
        self.increaseContrast = increaseContrast
        self.reduceMotion = reduceMotion
    }

    public var isEmpty: Bool { self == AppearanceSettings() }
}

public enum PermissionAction: String, Sendable, CaseIterable {
    case grant
    case revoke
    case reset
}

/// Services `simctl privacy` understands. There is no camera: simulators have none.
public enum PermissionService: String, Sendable, CaseIterable {
    case all
    case calendar
    case contacts
    case contactsLimited = "contacts-limited"
    case location
    case locationAlways = "location-always"
    case photos
    case photosAdd = "photos-add"
    case mediaLibrary = "media-library"
    case microphone
    case motion
    case reminders
    case siri
}

public struct Coordinate: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool { (-90...90).contains(latitude) && (-180...180).contains(longitude) }
}

/// Status bar indicators; nil fields are left as they are.
public struct StatusBarOverride: Sendable, Equatable {
    public static let dataNetworks = ["hide", "wifi", "hotspot", "1x", "GPRS", "Edge", "UMTS", "4G", "LTE", "LTEA", "LTEPlus", "5G", "5GPlus", "5GUWB", "5GUC"]
    /// Wi-Fi cannot be hidden: devicectl rejects notSupported for it.
    public static let wifiModes = ["active", "searching", "failed"]
    public static let cellularModes = ["active", "searching", "failed", "notSupported"]
    public static let batteryStates = ["charging", "charged", "draining"]
    public static let wifiBarsRange = 1...3
    public static let cellularBarsRange = 1...4

    /// e.g. "9:41".
    public var time: String?
    public var dataNetwork: String?
    public var wifiMode: String?
    public var wifiBars: Int?
    public var cellularMode: String?
    public var cellularBars: Int?
    public var batteryState: String?
    public var batteryLevel: Int?

    public init(
        time: String? = nil,
        dataNetwork: String? = nil,
        wifiMode: String? = nil,
        wifiBars: Int? = nil,
        cellularMode: String? = nil,
        cellularBars: Int? = nil,
        batteryState: String? = nil,
        batteryLevel: Int? = nil
    ) {
        self.time = time
        self.dataNetwork = dataNetwork
        self.wifiMode = wifiMode
        self.wifiBars = wifiBars
        self.cellularMode = cellularMode
        self.cellularBars = cellularBars
        self.batteryState = batteryState
        self.batteryLevel = batteryLevel
    }

    public var isEmpty: Bool { self == StatusBarOverride() }
}

public enum StatusBarPreset: String, Sendable, CaseIterable {
    /// 9:41, full battery, full signal.
    case screenshot
    case lowBattery = "low-battery"
    case noService = "no-service"
    case charging
}

public struct BiometricEnrollment: Sendable, Equatable {
    /// "Face ID", "Touch ID", "Optic ID".
    public var type: String
    public var enrolled: Bool

    public init(type: String, enrolled: Bool) {
        self.type = type
        self.enrolled = enrolled
    }
}
