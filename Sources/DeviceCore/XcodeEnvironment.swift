import Foundation

/// The Xcode the server works with: `DEVELOPER_DIR`, otherwise `xcode-select -p`.
public struct XcodeEnvironment: Sendable, Equatable {
    public static let minimumVersion = "27.0"

    /// e.g. /Applications/Xcode.app/Contents/Developer
    public var developerDir: String
    /// e.g. "27.1"
    public var version: String
    /// e.g. "27A9275"
    public var build: String?

    public var isSupported: Bool {
        version.compare(Self.minimumVersion, options: .numeric) != .orderedAscending
    }

    /// Environment to pass to child processes so `xcrun` uses the same Xcode.
    public var childEnvironment: [String: String] { ["DEVELOPER_DIR": developerDir] }

    public init(developerDir: String, version: String, build: String?) {
        self.developerDir = developerDir
        self.version = version
        self.build = build
    }

    public static func detect(environment: [String: String] = ProcessInfo.processInfo.environment) throws(ISimError) -> XcodeEnvironment {
        let developerDir: String
        if let fromEnv = environment["DEVELOPER_DIR"], !fromEnv.isEmpty {
            developerDir = fromEnv
        } else if let selected = xcodeSelectPath() {
            developerDir = selected
        } else {
            throw .xcodeUnavailable("Xcode not found: `xcode-select -p` failed and DEVELOPER_DIR is not set. Install Xcode \(minimumVersion)+.")
        }

        // .../Xcode.app/Contents/Developer → .../Xcode.app/Contents
        let contents = URL(fileURLWithPath: developerDir).deletingLastPathComponent()
        let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist"))
        guard let version = info?["CFBundleShortVersionString"] as? String else {
            throw .xcodeUnavailable(
                "\(developerDir) is not inside Xcode.app (Command Line Tools are not enough). "
                    + "Run `sudo xcode-select -s /Applications/Xcode.app` or set DEVELOPER_DIR.")
        }
        let versionPlist = NSDictionary(contentsOf: contents.appendingPathComponent("version.plist"))
        return XcodeEnvironment(developerDir: developerDir, version: version, build: versionPlist?["ProductBuildVersion"] as? String)
    }

    private static func xcodeSelectPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
