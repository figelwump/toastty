@testable import ToasttyApp
import CoreState
import UniformTypeIdentifiers
import XCTest

@MainActor
final class LocalDocumentOpenPanelTests: XCTestCase {
    func testSupportedFilenameExtensionsResolveToContentTypes() {
        for fileExtension in LocalDocumentClassifier.supportedFilenameExtensions {
            XCTAssertNotNil(
                UTType(filenameExtension: fileExtension),
                "expected \(fileExtension) to resolve to a UTType"
            )
        }
    }

    func testAllowedContentTypesMatchSharedSupportedExtensions() {
        let expectedTypeIdentifiers = Set(
            LocalDocumentClassifier.supportedFilenameExtensions.compactMap {
                UTType(filenameExtension: $0)?.identifier
            }
        )
        let actualTypeIdentifiers = Set(
            LocalDocumentOpenPanel.allowedContentTypes().map(\.identifier)
        )

        XCTAssertFalse(expectedTypeIdentifiers.isEmpty)
        XCTAssertEqual(actualTypeIdentifiers, expectedTypeIdentifiers)
    }

    func testAllowedContentTypesCoverYAMLAndTOMLExtensions() {
        let allowedTypes = LocalDocumentOpenPanel.allowedContentTypes()
        for fileExtension in ["yaml", "yml", "toml"] {
            XCTAssertTrue(
                allowedTypes.contains(where: { type in
                    type.tags[.filenameExtension]?.contains(fileExtension) == true
                }),
                "expected allowed content types to include an entry for .\(fileExtension)"
            )
        }
    }
}
