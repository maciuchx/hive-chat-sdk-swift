import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import HiveChatUI
import HiveChat

final class ImageEncodingTests: XCTestCase {
    /// A large PNG (standing in for a HEIC from the photo library) comes out
    /// as a JPEG, longest side 2048px, under the upload limit.
    func testLargeImageIsDownscaledToJPEG() throws {
        let width = 4032, height = 3024
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())

        let png = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let jpeg = try XCTUnwrap(ImageEncoding.jpeg(from: png as Data, limitBytes: HiveChat.maximumUploadBytes))
        XCTAssertLessThanOrEqual(jpeg.count, HiveChat.maximumUploadBytes)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let outWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let outHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        XCTAssertEqual(max(outWidth, outHeight), 2048)
    }

    func testNonImageDataIsRejected() {
        XCTAssertNil(ImageEncoding.jpeg(from: Data("not an image".utf8), limitBytes: HiveChat.maximumUploadBytes))
    }

    func testFilenameBecomesJPG() {
        XCTAssertEqual(ImageEncoding.jpegFilename(for: "IMG_0001.HEIC"), "IMG_0001.jpg")
        XCTAssertEqual(ImageEncoding.jpegFilename(for: nil), "photo.jpg")
    }
}
