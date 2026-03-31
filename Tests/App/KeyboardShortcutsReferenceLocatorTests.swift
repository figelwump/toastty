@testable import ToasttyApp
import CoreState
import XCTest

final class KeyboardShortcutsReferenceLocatorTests: XCTestCase {
    func testReferenceURLPrefersWorktreeDocumentOverBundledCopy() throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let docsDirectoryURL = rootURL.appending(path: "docs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: docsDirectoryURL, withIntermediateDirectories: true)

        let worktreeReferenceURL = docsDirectoryURL
            .appending(path: "keyboard-shortcuts.md", directoryHint: .notDirectory)
        try Data("worktree".utf8).write(to: worktreeReferenceURL)

        let bundledReferenceURL = rootURL
            .appending(path: "bundled-keyboard-shortcuts.md", directoryHint: .notDirectory)
        try Data("bundle".utf8).write(to: bundledReferenceURL)

        let resolvedURL = KeyboardShortcutsReferenceLocator.referenceURL(
            worktreeRootURL: rootURL,
            bundledReferenceURL: bundledReferenceURL
        )

        XCTAssertEqual(resolvedURL?.standardizedFileURL, worktreeReferenceURL.standardizedFileURL)
    }

    func testReferenceURLFallsBackToBundledCopyWhenWorktreeDocumentIsMissing() throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let bundledReferenceURL = rootURL
            .appending(path: "bundled-keyboard-shortcuts.md", directoryHint: .notDirectory)
        try Data("bundle".utf8).write(to: bundledReferenceURL)

        let resolvedURL = KeyboardShortcutsReferenceLocator.referenceURL(
            worktreeRootURL: rootURL,
            bundledReferenceURL: bundledReferenceURL
        )

        XCTAssertEqual(resolvedURL?.standardizedFileURL, bundledReferenceURL.standardizedFileURL)
    }

    func testOpenReferenceResultFailsWhenNoReferenceIsAvailable() {
        let runtimePaths = ToasttyRuntimePaths.resolve(environment: [:])

        let result = KeyboardShortcutsReferenceLocator.openReferenceResult(
            runtimePaths: runtimePaths,
            bundledReferenceURL: nil,
            openURL: { _ in
                XCTFail("openURL should not be called when no reference exists")
                return true
            }
        )

        switch result {
        case .success:
            XCTFail("Expected missing-reference failure")
        case .failure(let error):
            XCTAssertEqual(error.localizedDescription, "Toastty couldn't find the keyboard shortcuts reference.")
        }
    }

    func testOpenReferenceResultUsesResolvedReferenceURL() throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let docsDirectoryURL = rootURL.appending(path: "docs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: docsDirectoryURL, withIntermediateDirectories: true)

        let worktreeReferenceURL = docsDirectoryURL
            .appending(path: "keyboard-shortcuts.md", directoryHint: .notDirectory)
        try Data("worktree".utf8).write(to: worktreeReferenceURL)

        let runtimePaths = ToasttyRuntimePaths.resolve(
            environment: [ToasttyRuntimePaths.worktreeRootEnvironmentKey: rootURL.path]
        )

        var openedURL: URL?
        let result = KeyboardShortcutsReferenceLocator.openReferenceResult(
            runtimePaths: runtimePaths,
            bundledReferenceURL: nil,
            openURL: { url in
                openedURL = url
                return false
            }
        )

        XCTAssertEqual(openedURL?.standardizedFileURL, worktreeReferenceURL.standardizedFileURL)
        switch result {
        case .success:
            XCTFail("Expected open failure")
        case .failure(let error):
            XCTAssertEqual(error.localizedDescription, "Toastty couldn't open the keyboard shortcuts reference.")
        }
    }

    private func makeTemporaryDirectory() -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "toastty-keyboard-shortcuts-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: directoryURL)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
}
