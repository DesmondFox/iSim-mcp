import DeviceCore
import Foundation
import MCP

enum ScreenTools {
    static let all: [ToolDefinition] = [screenshot]

    enum ReturnMode: String, CaseIterable {
        case image
        case path
        case both
    }

    static let screenshot = ToolDefinition(
        name: "screenshot",
        toolset: .screen,
        description: """
            Capture the screen. Returns the image (downscaled JPEG by default to save tokens) and the screen size in points: \
            UI tools take coordinates in points, so convert image pixels with the factor given in the text. \
            Use return=path to only save a file, format=png with max_dimension=0 for a full-resolution PNG.
            """,
        inputSchema: Schema.deviceObject([
            "format": Schema.string("Image format.", enum: ImageFormat.allCases.map(\.rawValue)),
            "quality": Schema.integer("JPEG quality.", default: 80, minimum: 1, maximum: 100),
            "max_dimension": Schema.integer("Longest side of the image in pixels; 0 keeps full resolution.", default: 1024, minimum: 0),
            "return": Schema.string("What to return: the image, a file path, or both.", enum: ReturnMode.allCases.map(\.rawValue)),
            "save_path": Schema.string("Where to save the file (with return=path/both). Default: a new file in ~/Library/Caches/iSim-mcp/screenshots."),
        ]),
        annotations: .readOnly
    ) { arguments, context in
        try context.requireXcode()
        let format = try arguments.choice("format", default: ImageFormat.jpeg)
        let quality = try arguments.int("quality", default: 80, range: 1...100)
        let maxDimension = try arguments.int("max_dimension", default: 1024, range: 0...100_000)
        let returnMode = try arguments.choice("return", default: ReturnMode.image)
        let savePath = try arguments.string("save_path").map { ($0 as NSString).expandingTildeInPath }

        let device = try await context.session.resolveReady(try arguments.device)
        let capturer = try context.router.backend(.screenshot, for: device, as: (any ScreenCapturing).self)

        let rawURL = FileManager.default.temporaryDirectory.appendingPathComponent("isim-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: rawURL) }
        async let scale = displayScale(of: device, context: context)
        try await capturer.screenshot(udid: device.udid, to: rawURL.path)
        guard let raw = FileManager.default.contents(atPath: rawURL.path) else {
            throw ISimError.commandFailed(command: "screenshot", message: "no file was written")
        }
        let image = try ImageEncoder.encode(raw, format: format, quality: quality, maxDimension: maxDimension)

        var lines = ["Screenshot of \"\(device.name)\": " + describe(image, scale: await scale)]
        var content: [Tool.Content] = []
        if returnMode != .image {
            let url = try save(image, to: savePath, directory: context.screenshotDirectory, device: device)
            lines.append("Saved to \(url.path)")
        }
        if returnMode != .path {
            content.append(.image(data: image.data.base64EncodedString(), mimeType: image.format.mimeType, annotations: nil, _meta: nil))
        }
        content.insert(.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil), at: 0)
        return CallTool.Result(content: content)
    }

    private static func displayScale(of device: Device, context: ToolContext) async -> Double? {
        guard let provider = try? context.router.backend(.displayInfo, for: device, as: (any DisplayInfoProviding).self) else {
            return nil
        }
        return await context.displays.scale(for: device, provider: provider)
    }

    /// "402×874 pt (scale 3, 1206×2622 px); image 471×1024 px JPEG, 1 image px = 0.854 pt"
    static func describe(_ image: EncodedImage, scale: Double?) -> String {
        let imageText = "image \(image.width)×\(image.height) px \(image.format.rawValue.uppercased())"
        guard let scale, scale > 0 else {
            return "\(image.sourceWidth)×\(image.sourceHeight) px (point scale unknown); \(imageText)"
        }
        let widthPt = Double(image.sourceWidth) / scale
        let heightPt = Double(image.sourceHeight) / scale
        let factor = widthPt / Double(image.width)
        return "\(format(widthPt))×\(format(heightPt)) pt (scale \(format(scale)), \(image.sourceWidth)×\(image.sourceHeight) px); "
            + "\(imageText), 1 image px = \(String(format: "%.3f", factor)) pt"
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func save(_ image: EncodedImage, to savePath: String?, directory: URL, device: Device) throws -> URL {
        let url: URL
        if let savePath {
            url = URL(fileURLWithPath: savePath)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
            let stamp = formatter.string(from: Date())
            let name = device.name.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
            url = directory.appendingPathComponent("\(name)-\(stamp).\(image.format.fileExtension)")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try image.data.write(to: url)
        return url
    }
}
