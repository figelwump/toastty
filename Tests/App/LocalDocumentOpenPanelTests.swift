@testable import ToasttyApp
import CoreState
import UniformTypeIdentifiers
import XCTest

@MainActor
final class LocalDocumentOpenPanelTests: XCTestCase {
    func testAllowedContentTypesMatchSharedMarkdownExtensions() {
        let expectedTypeIdentifiers = Set(
            LocalDocumentClassifier.markdownFilenameExtensions.compactMap {
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
