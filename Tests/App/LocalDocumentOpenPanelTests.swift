@testable import ToasttyApp
import CoreState
import Foundation
import XCTest

@MainActor
final class LocalDocumentOpenPanelTests: XCTestCase {
    func testAllowsSelectionForEverySupportedFileExtension() throws {
        try withTemporaryDirectory { temporaryDirectoryURL in
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

                XCTAssertTrue(
                    LocalDocumentOpenPanel.allowsSelection(at: fileURL),
                    "expected picker to allow \(fileExtension)"
                )
            }
        }
    }

    func testAllowsSelectionIsCaseInsensitiveForSupportedExtensions() throws {
        try withTemporaryDirectory { temporaryDirectoryURL in
            let supportedFiles = [
                ("README.MD", "# Toastty\n"),
                ("config.YAML", "key: value\n"),
                ("Toastty.TOML", "key = \"value\"\n"),
                ("App.TS", "export const toastty = true\n"),
            ]

            for (fileName, content) in supportedFiles {
                let fileURL = temporaryDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
                try content.write(to: fileURL, atomically: true, encoding: .utf8)

                XCTAssertTrue(
                    LocalDocumentOpenPanel.allowsSelection(at: fileURL),
                    "expected picker to allow \(fileName)"
                )
            }
        }
    }

    func testAllowsSelectionForSupportedExactFileNames() throws {
        try withTemporaryDirectory { temporaryDirectoryURL in
            let fileURL = temporaryDirectoryURL.appendingPathComponent(".gitignore", isDirectory: false)
            try "*.xcuserstate\n".write(to: fileURL, atomically: true, encoding: .utf8)

            XCTAssertTrue(
                LocalDocumentOpenPanel.allowsSelection(at: fileURL),
                "expected picker to allow .gitignore"
            )
        }
    }

    func testAllowsSelectionKeepsDirectoriesEnabledForNavigation() throws {
        try withTemporaryDirectory { temporaryDirectoryURL in
            let nestedDirectoryURL = temporaryDirectoryURL.appendingPathComponent(
                "Nested Docs",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: nestedDirectoryURL,
                withIntermediateDirectories: true
            )

            XCTAssertTrue(LocalDocumentOpenPanel.allowsSelection(at: nestedDirectoryURL))
        }
    }

    func testAllowsSelectionRejectsUnsupportedFiles() throws {
        try withTemporaryDirectory { temporaryDirectoryURL in
            let unsupportedFiles = [
                ("notes.txt", "plain text\n"),
                ("LICENSE", "no extension\n"),
                ("archive.zip", "zip placeholder\n"),
            ]

            for (fileName, content) in unsupportedFiles {
                let fileURL = temporaryDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
                try content.write(to: fileURL, atomically: true, encoding: .utf8)

                XCTAssertFalse(
                    LocalDocumentOpenPanel.allowsSelection(at: fileURL),
                    "expected picker to reject \(fileName)"
                )
            }
        }
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }

        try body(temporaryDirectoryURL)
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
        case "swift":
            return "struct Toastty {}\n"
        case "js", "mjs", "cjs", "jsx":
            return "export const toastty = true;\n"
        case "ts", "mts", "cts", "tsx":
            return "export const toastty: boolean = true;\n"
        case "py":
            return "print('toastty')\n"
        case "go":
            return "package main\n"
        case "rs":
            return "fn main() {}\n"
        default:
            return "# Sample\n"
        }
    }
}
