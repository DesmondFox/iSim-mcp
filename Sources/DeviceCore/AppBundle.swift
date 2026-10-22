import Foundation
import ProcessKit

/// Reads metadata of an `.app` or `.ipa` on the Mac before installing it.
public struct AppBundleInfo: Sendable, Equatable {
    public var bundleId: String
    public var name: String?
    public var version: String?
    /// "iphonesimulator" or "iphoneos" (from CFBundleSupportedPlatforms).
    public var platforms: [String]

    public init(bundleId: String, name: String?, version: String?, platforms: [String]) {
        self.bundleId = bundleId
        self.name = name
        self.version = version
        self.platforms = platforms
    }

    public static func read(path: String, runner: any ProcessRunning) async throws -> AppBundleInfo {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ISimError.invalidArgument("File not found: \(url.path)")
        }

        let plistData: Data
        switch url.pathExtension.lowercased() {
        case "app" where isDirectory.boolValue:
            guard let data = FileManager.default.contents(atPath: url.appendingPathComponent("Info.plist").path) else {
                throw ISimError.invalidArgument("\(url.path) has no Info.plist; is it an iOS app bundle?")
            }
            plistData = data
        case "ipa":
            let result = try await runner.run("/usr/bin/unzip", ["-p", url.path, "Payload/*.app/Info.plist"], timeout: .seconds(60))
            guard result.succeeded, !result.stdout.isEmpty else {
                throw ISimError.invalidArgument("\(url.path) does not contain Payload/*.app/Info.plist.")
            }
            plistData = result.stdout
        default:
            throw ISimError.invalidArgument("Expected a .app bundle or an .ipa file, got \(url.lastPathComponent).")
        }

        guard
            let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
            let bundleId = plist["CFBundleIdentifier"] as? String
        else {
            throw ISimError.invalidArgument("Cannot read CFBundleIdentifier from \(url.path).")
        }
        return AppBundleInfo(
            bundleId: bundleId,
            name: (plist["CFBundleDisplayName"] ?? plist["CFBundleName"]) as? String,
            version: plist["CFBundleShortVersionString"] as? String,
            platforms: plist["CFBundleSupportedPlatforms"] as? [String] ?? []
        )
    }
}
