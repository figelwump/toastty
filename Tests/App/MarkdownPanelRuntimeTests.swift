@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class MarkdownPanelRuntimeTests: XCTestCase {
    func testAssetLocatorResolvesFolderReferencedPanelBundle() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resourcesDirectoryURL = tempDirectoryURL
            .appendingPathComponent("Test.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let panelDirectoryURL = resourcesDirectoryURL
            .appendingPathComponent("WebPanels", isDirectory: true)
            .appendingPathComponent("markdown-panel", isDirectory: true)
        let entryURL = panelDirectoryURL.appendingPathComponent("index.html")

        try FileManager.default.createDirectory(at: panelDirectoryURL, withIntermediateDirectories: true)
        try Data("<!doctype html>".utf8).write(to: entryURL)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let bundleURL = tempDirectoryURL.appendingPathComponent("Test.app", isDirectory: true)
        let bundle = try XCTUnwrap(Bundle(path: bundleURL.path))

        XCTAssertEqual(MarkdownPanelAssetLocator.entryURL(bundle: bundle), entryURL)
        XCTAssertEqual(MarkdownPanelAssetLocator.directoryURL(bundle: bundle), panelDirectoryURL)
    }

    func testBootstrapReadsMarkdownFileContents() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("README.md")
        try "# Hello Toastty\n\nA local markdown panel.".write(to: fileURL, atomically: true, encoding: .utf8)

        let bootstrap = await MarkdownPanelRuntime.bootstrap(
            for: WebPanelState(
                definition: .markdown,
                title: "README.md",
                filePath: fileURL.path
            )
        )

        XCTAssertEqual(bootstrap.contractVersion, 1)
        XCTAssertEqual(bootstrap.mode, .view)
        XCTAssertEqual(bootstrap.displayName, "README.md")
        XCTAssertEqual(bootstrap.filePath, fileURL.path)
        XCTAssertEqual(bootstrap.content, "# Hello Toastty\n\nA local markdown panel.")
    }

    func testBootstrapFallsBackToErrorDocumentWhenFileIsMissing() async {
        let filePath = "/tmp/toastty/missing.md"

        let bootstrap = await MarkdownPanelRuntime.bootstrap(
            for: WebPanelState(
                definition: .markdown,
                title: "missing.md",
                filePath: filePath
            )
        )

        XCTAssertEqual(bootstrap.displayName, "missing.md")
        XCTAssertEqual(bootstrap.filePath, filePath)
        XCTAssertTrue(bootstrap.content.contains("Toastty could not load this markdown file."))
        XCTAssertTrue(bootstrap.content.contains(filePath))
    }

    func testBootstrapJavaScriptEmbedsJSONPayload() throws {
        let bootstrap = MarkdownPanelBootstrap(
            filePath: "/tmp/toastty/readme.md",
            displayName: "readme.md",
            content: "# Docs"
        )

        let script = try XCTUnwrap(MarkdownPanelRuntime.bootstrapJavaScript(for: bootstrap))

        XCTAssertTrue(script.contains("window.ToasttyMarkdownPanel?.receiveBootstrap("))
        XCTAssertTrue(script.contains("\"displayName\":\"readme.md\""))
        XCTAssertTrue(script.contains("\"content\":\"# Docs\""))
    }
}
