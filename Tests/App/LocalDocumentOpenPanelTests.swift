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

    func testAllowedContentTypesAcceptFilesystemReportedTypesForSupportedFiles() throws {
        let allowedContentTypes = Set(LocalDocumentOpenPanel.allowedContentTypes())
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }

        for fileExtension in LocalDocumentClassifier.supportedFilenameExtensions {
            let fileURL = temporaryDirectoryURL.appendingPathComponent(
                "sample.\(fileExtension)",
                isDirectory: false
            )
            try sampleContent(for: fileExtension).write(
                to: fileURL,
                atomically: true,
                encoding: .utf8
            )

            let contentType = try XCTUnwrap(
                try fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType,
                "expected filesystem content type for \(fileExtension)"
            )
            XCTAssertTrue(
                allowedContentTypes.contains(contentType),
                "expected picker types to accept filesystem content type \(contentType.identifier) for \(fileExtension)"
            )
        }
    }

    private func sampleContent(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "yaml", "yml":
            return "key: value\n"
        case "toml":
            return "key = \"value\"\n"
        case "json", "jsonc":
            return "{\n  \"key\": \"value\"\n}\n"
        case "jsonl":
            return "{\"event\":\"open\"}\n{\"event\":\"save\"}\n"
        case "ini", "conf", "cfg", "properties":
            return "key=value\n"
        case "csv":
            return "name,value\nToastty,1\n"
        case "tsv":
            return "name\tvalue\nToastty\t1\n"
        case "xml":
            return "<root><item>Toastty</item></root>\n"
        case "sh", "bash", "zsh":
            return "#!/usr/bin/env bash\necho toastty\n"
        default:
            return "# Sample\n"
        }
    }
}
