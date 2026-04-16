@testable import ToasttyApp
import CoreState
import UniformTypeIdentifiers
import XCTest

@MainActor
final class LocalDocumentOpenPanelTests: XCTestCase {
    func testSupportedFilenameExtensionsResolveToContentTypes() {
        for fileExtension in LocalDocumentClassifier.supportedFilenameExtensions {
            XCTAssertNotNil(
                UTType(filenameExtension: fileExtension, conformingTo: .plainText),
                "expected \(fileExtension) to resolve to a UTType"
            )
        }
    }

    func testAllowedContentTypesMatchSharedSupportedExtensions() {
        let expectedTypeIdentifiers = Set(
            LocalDocumentClassifier.supportedFilenameExtensions.compactMap {
                UTType(filenameExtension: $0, conformingTo: .plainText)?.identifier
            }
        )
        let actualTypeIdentifiers = Set(
            LocalDocumentOpenPanel.allowedContentTypes().map(\.identifier)
        )

        XCTAssertFalse(expectedTypeIdentifiers.isEmpty)
        XCTAssertEqual(actualTypeIdentifiers, expectedTypeIdentifiers)
    }
}
