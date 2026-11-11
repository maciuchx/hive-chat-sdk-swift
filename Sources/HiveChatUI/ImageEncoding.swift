import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns whatever the photo library or Files hands back into a JPEG the
/// server accepts.
///
/// iPhone photos are usually HEIC, which Hive does not take, and a 12MP
/// photo is well over the 5MB upload limit even as a JPEG. ImageIO decodes
/// HEIC, PNG, JPEG and the rest on every Apple platform, so this needs no
/// UIKit and works the same on macOS.
enum ImageEncoding {
    static let maximumPixelSize = 2048
    static let qualitySteps: [Double] = [0.8, 0.7, 0.6, 0.5, 0.4, 0.3]

    /// Re-encodes `data` as JPEG with the longest side at most 2048px,
    /// stepping quality down until it fits in `limitBytes`. Returns nil when
    /// the data is not an image ImageIO can read. The result may still exceed
    /// the limit if even the lowest quality does not fit; the caller checks.
    static func jpeg(from data: Data, limitBytes: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            /* Bakes the EXIF orientation in. Without it a portrait photo
               arrives on its side, because the JPEG we write has no
               orientation tag to correct it. */
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        var smallest: Data?
        for quality in qualitySteps {
            guard let encoded = encode(image, quality: quality) else { continue }
            smallest = encoded
            if encoded.count <= limitBytes { return encoded }
        }
        return smallest
    }

    private static func encode(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// `name.heic` → `name.jpg`; falls back to `photo.jpg`.
    static func jpegFilename(for original: String?) -> String {
        let base = original.map { ($0 as NSString).deletingPathExtension } ?? ""
        return (base.isEmpty ? "photo" : base) + ".jpg"
    }
}
