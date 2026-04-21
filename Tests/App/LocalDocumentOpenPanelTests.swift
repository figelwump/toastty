@testable import ToasttyApp
import CoreState
import UniformTypeIdentifiers
import XCTest

@MainActor
final class LocalDocumentOpenPanelTests: XCTestCase {
    func testSupportedFilenameExtensionsResolveToContentTypes() {
        for fileExtension in LocalDocumentClassifier.supportedFilenameExtensions {
            XCTAssertNotNil(
                LocalDocumentOpenPanel.contentType(forFileExtension: fileExtension),
                "expected \(fileExtension) to resolve to a UTType"
            )
        }
    }

    func testAllowedContentTypesMatchSharedSupportedExtensions() {
        let expectedTypeIdentifiers = Set(
            LocalDocumentClassifier.supportedFilenameExtensions.compactMap {
                LocalDocumentOpenPanel.contentType(forFileExtension: $0)?.identifier
            }
        )
        let actualTypeIdentifiers = Set(
            LocalDocumentOpenPanel.allowedContentTypes().map(\.identifier)
        )

        XCTAssertFalse(expectedTypeIdentifiers.isEmpty)
        XCTAssertEqual(actualTypeIdentifiers, expectedTypeIdentifiers)
    }

    func testAllowedContentTypesPreferTextCompatibleTypesForSupportedExtensions() throws {
        for fileExtension in LocalDocumentClassifier.supportedFilenameExtensions {
            let contentType = try XCTUnwrap(
                LocalDocumentOpenPanel.contentType(forFileExtension: fileExtension),
                "expected content type for \(fileExtension)"
            )
            XCTAssertTrue(
                contentType.conforms(to: .text) || contentType.conforms(to: .sourceCode),
                "expected picker type \(contentType.identifier) for \(fileExtension) to stay text-compatible"
            )
        }
    }

    func testTypeScriptExtensionsAvoidTransportStreamUTTypeFallbacks() {
        XCTAssertEqual(
            LocalDocumentOpenPanel.contentType(forFileExtension: "ts")?.identifier,
            "com.microsoft.typescript"
        )
        XCTAssertNotEqual(
            LocalDocumentOpenPanel.contentType(forFileExtension: "ts")?.identifier,
            "public.mpeg-2-transport-stream"
        )
        XCTAssertNotEqual(
            LocalDocumentOpenPanel.contentType(forFileExtension: "mts")?.identifier,
            "public.avchd-mpeg-2-transport-stream"
        )
    }
}
