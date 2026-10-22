import CoreGraphics
import DeviceCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageFormat: String, CaseIterable, Sendable {
    case jpeg
    case png

    var mimeType: String { self == .jpeg ? "image/jpeg" : "image/png" }
    var fileExtension: String { self == .jpeg ? "jpg" : "png" }
    var utType: UTType { self == .jpeg ? .jpeg : .png }
}

struct EncodedImage: Sendable {
    var data: Data
    var format: ImageFormat
    var width: Int
    var height: Int
    var sourceWidth: Int
    var sourceHeight: Int
}

/// Downscales and re-encodes screenshots so they cost fewer tokens.
enum ImageEncoder {
    /// - Parameter maxDimension: longest side of the result in pixels; 0 keeps the original size.
    /// - Parameter quality: JPEG quality 1…100; ignored for PNG.
    static func encode(_ source: Data, format: ImageFormat, quality: Int, maxDimension: Int) throws(ISimError) -> EncodedImage {
        guard
            let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
            let original = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw .commandFailed(command: "screenshot", message: "the captured file is not a readable image")
        }

        var image = original
        if maxDimension > 0 && max(original.width, original.height) > maxDimension {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let scaled = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                throw .commandFailed(command: "screenshot", message: "failed to resize the image")
            }
            image = scaled
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, format.utType.identifier as CFString, 1, nil) else {
            throw .commandFailed(command: "screenshot", message: "cannot create a \(format.rawValue) encoder")
        }
        var properties: [CFString: Any] = [:]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = Double(quality) / 100
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw .commandFailed(command: "screenshot", message: "failed to encode \(format.rawValue)")
        }
        return EncodedImage(
            data: output as Data,
            format: format,
            width: image.width,
            height: image.height,
            sourceWidth: original.width,
            sourceHeight: original.height
        )
    }
}
