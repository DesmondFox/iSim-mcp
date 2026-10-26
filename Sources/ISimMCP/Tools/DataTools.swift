import DeviceCore
import Foundation
import MCP

/// App data: files in an app's containers, its UserDefaults, the simulator keychain.
enum DataTools {
    static let all: [ToolDefinition] = [listContainerFiles, readContainerFile, writeContainerFile, readUserDefaults, writeUserDefaults, keychain]

    static let containerProperty = Schema.string("data (Documents, Library, tmp) or an app group identifier. Default: data.")

    static func container(_ arguments: ToolArguments) throws(ISimError) -> AppContainer {
        guard let name = try arguments.string("container").flatMap({ $0.isEmpty ? nil : $0 }), name != "data" else { return .data }
        return .group(name)
    }

    // MARK: Files

    static let listContainerFiles = ToolDefinition(
        name: "list_container_files",
        toolset: .data,
        description: """
            List files in an app's data container or app group container: Documents, Library (Preferences, Caches, \
            Application Support), tmp. On an iPhone only development builds of your apps can be read.
            """,
        inputSchema: Schema.deviceObject([
            "bundle_id": Schema.string("Bundle identifier of the app."),
            "container": containerProperty,
            "subpath": Schema.string("Folder inside the container, e.g. Library/Preferences. Default: the container root."),
            "depth": Schema.integer("How many levels down to list.", default: 3, minimum: 1, maximum: 20),
            "limit": Schema.integer("At most this many entries.", default: 300, minimum: 1, maximum: 5000),
        ], required: ["bundle_id"]),
        annotations: .readOnly
    ) { arguments, context in
        try context.requireXcode()
        let bundleId = try arguments.requiredString("bundle_id")
        let container = try container(arguments)
        let subpath = try arguments.string("subpath") ?? ""
        let depth = try arguments.int("depth", default: 3, range: 1...20)
        let limit = try arguments.int("limit", default: 300, range: 1...5000)
        let device = try await context.session.resolveReady(try arguments.device)
        let files = try await context.router.backend(.containerFiles, for: device, as: (any ContainerFileAccessing).self)
            .listFiles(udid: device.udid, bundleId: bundleId, container: container, subpath: subpath, depth: depth)
        var lines = ["\(files.count) entr\(files.count == 1 ? "y" : "ies") in the \(container) of \(bundleId)"
            + (subpath.isEmpty ? "" : " under \(subpath)") + ":"]
        if device.kind == .simulator, case .data = container,
           let root = try? await context.simctl.containerPath(udid: device.udid, bundleId: bundleId, container: "data") {
            lines[0] = lines[0].dropLast() + " (\(root)):"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        lines += files.prefix(limit).map { file in
            if file.isDirectory { return file.path + "/" }
            var line = file.path
            if let size = file.size { line += "  " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
            if let modified = file.modified { line += "  " + formatter.string(from: modified) }
            return line
        }
        if files.count > limit { lines.append("… \(files.count - limit) more; narrow it with subpath or depth.") }
        return .text(lines.joined(separator: "\n"))
    }

    static let readContainerFile = ToolDefinition(
        name: "read_container_file",
        toolset: .data,
        description: """
            Read a file from an app's container. Property lists come back as JSON, text as text, PNG and JPEG as an image, \
            other binaries as base64 up to max_bytes. save_path copies the file to the Mac instead, e.g. a SQLite database.
            """,
        inputSchema: Schema.deviceObject([
            "bundle_id": Schema.string("Bundle identifier of the app."),
            "path": Schema.string("Path inside the container, e.g. Documents/notes.json or Library/Preferences/<bundle id>.plist."),
            "container": containerProperty,
            "max_bytes": Schema.integer("Longest text or base64 to return.", default: 100_000, minimum: 1, maximum: 5_000_000),
            "save_path": Schema.string("Copy the file to this path on the Mac and return only a summary."),
        ], required: ["bundle_id", "path"]),
        annotations: .readOnly
    ) { arguments, context in
        try context.requireXcode()
        let bundleId = try arguments.requiredString("bundle_id")
        let path = try ContainerPath.normalize(try arguments.requiredString("path"))
        let container = try container(arguments)
        let maxBytes = try arguments.int("max_bytes", default: 100_000, range: 1...5_000_000)
        let savePath = try arguments.string("save_path").flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
        let device = try await context.session.resolveReady(try arguments.device)
        let files = try context.router.backend(.containerFiles, for: device, as: (any ContainerFileAccessing).self)

        let destination = savePath.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("isim-read-\(UUID().uuidString)-" + (path as NSString).lastPathComponent)
        if savePath != nil { try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true) }
        defer { if savePath == nil { try? FileManager.default.removeItem(at: destination) } }
        try await files.readFile(udid: device.udid, bundleId: bundleId, container: container, path: path, to: destination)
        guard let data = FileManager.default.contents(atPath: destination.path) else {
            throw ISimError.commandFailed(command: "read_container_file", message: "no file was copied")
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        if savePath != nil {
            return .text("Copied \(path) (\(size)) from the \(container) of \(bundleId) to \(destination.path).")
        }
        return try contents(of: data, path: path, size: size, maxBytes: maxBytes)
    }

    /// The file in the form that reads best: JSON for property lists, text, an image, or base64.
    static func contents(of data: Data, path: String, size: String, maxBytes: Int) throws -> CallTool.Result {
        let ext = (path as NSString).pathExtension.lowercased()
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil), data.starts(with: Data("bplist".utf8)) || ext == "plist" {
            return .text("\(path) (\(size), property list):\n" + PropertyList.json(plist))
        }
        if ["png", "jpg", "jpeg"].contains(ext), let image = try? ImageEncoder.encode(data, format: .jpeg, quality: 80, maxDimension: 1024) {
            return CallTool.Result(content: [
                .text(text: "\(path) (\(size), \(image.sourceWidth)×\(image.sourceHeight) px)", annotations: nil, _meta: nil),
                .image(data: image.data.base64EncodedString(), mimeType: image.format.mimeType, annotations: nil, _meta: nil),
            ])
        }
        if data.starts(with: Data("SQLite format 3".utf8)) {
            return .text("\(path) (\(size)) is a SQLite database; copy it with save_path and open it with sqlite3.")
        }
        let head = data.prefix(maxBytes)
        if !head.contains(0), let text = String(data: head, encoding: .utf8) ?? String(data: head.dropLast(3), encoding: .utf8) {
            return .text("\(path) (\(size)):\n" + text + (data.count > maxBytes ? "\n… [cut at \(maxBytes) bytes]" : ""))
        }
        return .text("\(path) (\(size), binary), base64" + (data.count > maxBytes ? " of the first \(maxBytes) bytes" : "") + ":\n"
            + head.base64EncodedString())
    }

    static let writeContainerFile = ToolDefinition(
        name: "write_container_file",
        toolset: .data,
        description: """
            Write a file into an app's container, replacing one at the same path: test data, a fixture database, a config. \
            Give the contents as text (or base64 with is_base64), or source_path to copy a file from the Mac. \
            Folders are created as needed. Relaunch the app if it read the file already.
            """,
        inputSchema: Schema.deviceObject([
            "bundle_id": Schema.string("Bundle identifier of the app."),
            "path": Schema.string("Path inside the container, e.g. Documents/fixture.json."),
            "container": containerProperty,
            "content": Schema.string("The file's contents."),
            "is_base64": Schema.bool("`content` is base64 for a binary file.", default: false),
            "source_path": Schema.string("A file on the Mac to copy instead of `content`."),
        ], required: ["bundle_id", "path"]),
        annotations: .destructive
    ) { arguments, context in
        try context.requireXcode()
        let bundleId = try arguments.requiredString("bundle_id")
        let path = try ContainerPath.normalize(try arguments.requiredString("path"))
        guard !path.isEmpty else { throw ISimError.invalidArgument("`path` must name a file inside the container.") }
        let container = try container(arguments)
        let content = try arguments.string("content")
        let sourcePath = try arguments.string("source_path").flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
        guard (content == nil) != (sourcePath == nil) else { throw ISimError.invalidArgument("Pass either `content` or `source_path`.") }
        let device = try await context.session.resolveReady(try arguments.device)
        let files = try context.router.backend(.containerFiles, for: device, as: (any ContainerFileAccessing).self)

        var source: URL
        var temporary: URL?
        if let sourcePath {
            source = URL(fileURLWithPath: sourcePath)
            guard FileManager.default.fileExists(atPath: source.path) else { throw ISimError.invalidArgument("File not found: \(source.path)") }
        } else {
            let data: Data
            if try arguments.bool("is_base64", default: false) {
                guard let decoded = Data(base64Encoded: content!, options: .ignoreUnknownCharacters) else {
                    throw ISimError.invalidArgument("`content` is not valid base64.")
                }
                data = decoded
            } else {
                data = Data(content!.utf8)
            }
            // Named like the target: devicectl copies a file under its own name when the destination is a folder.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("isim-write-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            source = directory.appendingPathComponent((path as NSString).lastPathComponent)
            try data.write(to: source)
            temporary = directory
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        try await files.writeFile(udid: device.udid, bundleId: bundleId, container: container, path: path, from: source)
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path))?[.size] as? Int ?? 0
        return .text("Wrote \(path) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))) to the \(container) of \(bundleId) on \"\(device.name)\".")
    }

    // MARK: UserDefaults

    static let readUserDefaults = ToolDefinition(
        name: "read_user_defaults",
        toolset: .data,
        description: """
            Read an app's UserDefaults as JSON: the whole domain or one key. suite reads UserDefaults(suiteName:), \
            group.* suites from the app group container. On an iPhone this is the preferences file, which may lag a few \
            seconds behind values the app just set.
            """,
        inputSchema: Schema.deviceObject([
            "bundle_id": Schema.string("Bundle identifier of the app."),
            "key": Schema.string("One key instead of the whole domain."),
            "suite": Schema.string("Suite name instead of the app's standard defaults."),
        ], required: ["bundle_id"]),
        annotations: .readOnly
    ) { arguments, context in
        try context.requireXcode()
        let bundleId = try arguments.requiredString("bundle_id")
        let key = try arguments.string("key").flatMap { $0.isEmpty ? nil : $0 }
        let suite = try arguments.string("suite").flatMap { $0.isEmpty ? nil : $0 }
        let device = try await context.session.resolveReady(try arguments.device)
        let data = try await context.router.backend(.userDefaults, for: device, as: (any UserDefaultsReading).self)
            .userDefaults(udid: device.udid, bundleId: bundleId, suite: suite)
        let domain = (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]) ?? [:]
        let name = suite.map { "suite \($0) of \(bundleId)" } ?? bundleId
        if let key {
            guard let value = domain[key] else {
                return .text("\(name) has no default \"\(key)\"." + (domain.isEmpty ? "" : " Keys: " + domain.keys.sorted().joined(separator: ", ")))
            }
            return .text("\(key) = " + PropertyList.json(value))
        }
        guard !domain.isEmpty else { return .text("\(name) has no UserDefaults set.") }
        return .text("UserDefaults of \(name) (\(domain.count) key(s)):\n" + PropertyList.json(domain))
    }

    enum ValueType: String, CaseIterable {
        case string
        case integer
        case float
        case boolean
        case date
        case data
        /// Whatever the JSON value is: arrays and objects become arrays and dictionaries.
        case json
    }

    static let writeUserDefaults = ToolDefinition(
        name: "write_user_defaults",
        toolset: .data,
        description: """
            Set or remove a key in an app's UserDefaults on a simulator: feature flags, onboarding state, a server URL. \
            The running app sees the new value (through cfprefsd); code that cached it at launch needs a relaunch. \
            On iPhones, override a default for one run with launch_app args ["-key", "value"] instead. Simulators only.
            """,
        inputSchema: Schema.deviceObject([
            "bundle_id": Schema.string("Bundle identifier of the app."),
            "key": Schema.string("The key."),
            "value": ["description": "The value: string, number, boolean, array or object."],
            "type": Schema.string("How to store `value`; default: as its JSON type (json). date takes ISO 8601, data base64.",
                                  enum: ValueType.allCases.map(\.rawValue)),
            "suite": Schema.string("Suite name instead of the app's standard defaults."),
            "delete": Schema.bool("Remove the key instead.", default: false),
        ], required: ["bundle_id", "key"]),
        annotations: .idempotent
    ) { arguments, context in
        try context.requireXcode()
        let bundleId = try arguments.requiredString("bundle_id")
        let key = try arguments.requiredString("key")
        let suite = try arguments.string("suite").flatMap { $0.isEmpty ? nil : $0 }
        let delete = try arguments.bool("delete", default: false)
        var element: String?
        if !delete {
            guard let value = arguments.values["value"], value != .null else {
                throw ISimError.invalidArgument("Pass `value`, or delete: true to remove the key.")
            }
            element = try PropertyList.xmlElement(try plistValue(value, as: try arguments.choice("type", default: ValueType.json)))
        }
        let device = try await context.session.resolveReady(try arguments.device)
        try await context.router.backend(.writeUserDefaults, for: device, as: (any UserDefaultsWriting).self)
            .writeUserDefault(udid: device.udid, bundleId: bundleId, suite: suite, key: key, value: element)
        let name = suite.map { "suite \($0) of \(bundleId)" } ?? bundleId
        return .text(delete ? "Removed \"\(key)\" from the UserDefaults of \(name)." : "Set \"\(key)\" in the UserDefaults of \(name) to \(element!).")
    }

    /// The tool's JSON value as a property list object of the requested type.
    static func plistValue(_ value: Value, as type: ValueType) throws(ISimError) -> Any {
        let object = foundationObject(value)
        switch type {
        case .json:
            return object
        case .string:
            if case .string(let text) = value { return text }
            return "\(object)"
        case .integer:
            if case .int(let number) = value { return NSNumber(value: number) }
            if case .double(let number) = value, number.rounded() == number { return NSNumber(value: Int(number)) }
            if case .string(let text) = value, let number = Int(text) { return NSNumber(value: number) }
            throw .invalidArgument("`value` is not an integer.")
        case .float:
            if case .double(let number) = value { return NSNumber(value: number) }
            if case .int(let number) = value { return NSNumber(value: Double(number)) }
            if case .string(let text) = value, let number = Double(text) { return NSNumber(value: number) }
            throw .invalidArgument("`value` is not a number.")
        case .boolean:
            if case .bool(let flag) = value { return NSNumber(value: flag) }
            if case .string(let text) = value, ["true", "false", "yes", "no"].contains(text.lowercased()) {
                return NSNumber(value: ["true", "yes"].contains(text.lowercased()))
            }
            if case .int(let number) = value, number == 0 || number == 1 { return NSNumber(value: number == 1) }
            throw .invalidArgument("`value` is not a boolean.")
        case .date:
            guard case .string(let text) = value, let date = ISO8601DateFormatter().date(from: text) else {
                throw .invalidArgument("`value` must be an ISO 8601 date such as 2026-10-23T12:00:00Z.")
            }
            return date
        case .data:
            guard case .string(let text) = value, let data = Data(base64Encoded: text) else { throw .invalidArgument("`value` must be base64.") }
            return data
        }
    }

    /// MCP's JSON value as Foundation objects; booleans stay booleans.
    static func foundationObject(_ value: Value) -> Any {
        switch value {
        case .null: NSNull()
        case .bool(let flag): NSNumber(value: flag)
        case .int(let number): NSNumber(value: number)
        case .double(let number): NSNumber(value: number)
        case .string(let text): text
        case .data(_, let data): data
        case .array(let items): items.map(foundationObject)
        case .object(let fields): fields.mapValues(foundationObject)
        }
    }

    // MARK: Keychain

    enum KeychainAction: String, CaseIterable {
        case addRootCert = "add_root_cert"
        case addCert = "add_cert"
        case reset
    }

    static let keychain = ToolDefinition(
        name: "keychain",
        toolset: .data,
        description: """
            The simulator's keychain: add_root_cert trusts a CA certificate (for a debugging proxy or a test server's own CA), \
            add_cert adds a certificate, reset deletes every keychain item of every app (saved logins, tokens). Simulators only.
            """,
        inputSchema: Schema.deviceObject([
            "action": Schema.string("What to do.", enum: KeychainAction.allCases.map(\.rawValue)),
            "path": Schema.string("Certificate file on the Mac (.cer, .crt, .der, .pem) for add_root_cert and add_cert."),
        ], required: ["action"]),
        annotations: .destructive
    ) { arguments, context in
        try context.requireXcode()
        guard let action = try arguments.choice("action", as: KeychainAction.self) else {
            throw ISimError.invalidArgument("`action` is required: add_root_cert, add_cert or reset.")
        }
        let device = try await context.session.resolveReady(try arguments.device)
        let backend = try context.router.backend(.keychain, for: device, as: (any KeychainManaging).self)
        if action == .reset {
            try await backend.resetKeychain(udid: device.udid)
            return .text("Reset the keychain of \"\(device.name)\": apps lost their saved items.")
        }
        let path = (try arguments.requiredString("path") as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { throw ISimError.invalidArgument("File not found: \(path)") }
        try await backend.addCertificate(udid: device.udid, path: path, trustedRoot: action == .addRootCert)
        return .text(action == .addRootCert
            ? "Added \((path as NSString).lastPathComponent) to the trusted roots of \"\(device.name)\"."
            : "Added \((path as NSString).lastPathComponent) to the keychain of \"\(device.name)\".")
    }
}
