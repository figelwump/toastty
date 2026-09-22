import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ToasttyMobileApp

final class ToasttyAttachmentLoaderTests: XCTestCase {
    func testFilesRejectOversizedUnsupportedDirectoriesAndSymbolicLinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try Data("notes".utf8).write(to: file)
        XCTAssertEqual(try ToasttyAttachmentLoader.file(at: file).data, Data("notes".utf8))
        let link = directory.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try ToasttyAttachmentLoader.file(at: link))
        let unsupported = directory.appendingPathComponent("program.exe")
        try Data("binary".utf8).write(to: unsupported)
        XCTAssertThrowsError(try ToasttyAttachmentLoader.file(at: unsupported))
        let oversized = directory.appendingPathComponent("large.txt")
        try Data(repeating: 65, count: 4 * 1024 * 1024 + 1).write(to: oversized)
        XCTAssertThrowsError(try ToasttyAttachmentLoader.file(at: oversized))
        let package = directory.appendingPathComponent("folder.txt")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ToasttyAttachmentLoader.file(at: package))
    }

    func testPhotoNormalizationDownsamplesAndDropsGPSAndEXIF() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2400, height: 1600, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.0, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private metadata"],
            kCGImagePropertyOrientation: 6
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let attachment = try ToasttyAttachmentLoader.photo(data: encoded as Data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(attachment.data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment as String])
        XCTAssertLessThanOrEqual((properties[kCGImagePropertyPixelWidth as String] as? Int) ?? Int.max, 2048)
        XCTAssertLessThanOrEqual((properties[kCGImagePropertyPixelHeight as String] as? Int) ?? Int.max, 2048)
        XCTAssertTrue(attachment.filename.hasSuffix(".jpg"))
    }
}
