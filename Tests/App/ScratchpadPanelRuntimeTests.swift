import AppKit
@testable import ToasttyApp
import CoreState
import WebKit
import XCTest

@MainActor
final class ScratchpadPanelRuntimeTests: XCTestCase {
    func testLocalOnlyCapabilityProfileUsesNonPersistentWebsiteDataStore() {
        let configuration = ScratchpadPanelRuntime.makeWebViewConfiguration(for: .localOnly)

        XCTAssertFalse(configuration.websiteDataStore.isPersistent)
    }

    func testAssetLocatorResolvesFolderReferencedPanelBundle() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resourcesDirectoryURL = tempDirectoryURL
            .appendingPathComponent("Test.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let panelDirectoryURL = resourcesDirectoryURL
            .appendingPathComponent("WebPanels", isDirectory: true)
            .appendingPathComponent("scratchpad-panel", isDirectory: true)
        let entryURL = panelDirectoryURL.appendingPathComponent("index.html")

        try FileManager.default.createDirectory(at: panelDirectoryURL, withIntermediateDirectories: true)
        try Data("<!doctype html>".utf8).write(to: entryURL)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let bundleURL = tempDirectoryURL.appendingPathComponent("Test.app", isDirectory: true)
        let bundle = try XCTUnwrap(Bundle(path: bundleURL.path))

        XCTAssertEqual(ScratchpadPanelAssetLocator.entryURL(bundle: bundle), entryURL)
        XCTAssertEqual(ScratchpadPanelAssetLocator.directoryURL(bundle: bundle), panelDirectoryURL)
    }

    func testBootstrapLoadsPersistedDocument() throws {
        let fixture = try ScratchpadRuntimeFixture()
        let document = try fixture.store.createDocument(
            title: "Sketch",
            content: "<strong>Visible</strong>",
            sessionLink: nil
        )
        let webState = WebPanelState(
            definition: .scratchpad,
            title: "Scratchpad",
            scratchpad: ScratchpadState(
                documentID: document.documentID,
                revision: document.revision
            )
        )

        let bootstrap = ScratchpadPanelRuntime.bootstrap(
            for: webState,
            documentStore: fixture.store,
            theme: .dark
        )

        XCTAssertEqual(bootstrap.documentID, document.documentID)
        XCTAssertEqual(bootstrap.displayName, "Sketch")
        XCTAssertEqual(bootstrap.revision, 1)
        XCTAssertEqual(bootstrap.contentHTML, "<strong>Visible</strong>")
        XCTAssertFalse(bootstrap.missingDocument)
    }

    func testBootstrapReportsMissingDocument() throws {
        let fixture = try ScratchpadRuntimeFixture()
        let documentID = UUID()
        let webState = WebPanelState(
            definition: .scratchpad,
            title: "Scratchpad",
            scratchpad: ScratchpadState(
                documentID: documentID,
                revision: 3
            )
        )

        let bootstrap = ScratchpadPanelRuntime.bootstrap(
            for: webState,
            documentStore: fixture.store,
            theme: .light
        )

        XCTAssertEqual(bootstrap.documentID, documentID)
        XCTAssertEqual(bootstrap.revision, 3)
        XCTAssertTrue(bootstrap.missingDocument)
        XCTAssertNil(bootstrap.contentHTML)
    }

    func testBridgeIgnoresSubframeMessagesInTestingShim() throws {
        let fixture = try ScratchpadRuntimeFixture()
        var logs: [(ToasttyLogLevel, String)] = []
        let runtime = ScratchpadPanelRuntime(
            panelID: UUID(),
            documentStore: fixture.store,
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            diagnosticLogger: { level, message, _ in
                logs.append((level, message))
            }
        )

        runtime.simulateBridgeMessageForTesting(
            ["type": "consoleMessage", "level": "error", "message": "from generated frame"],
            isMainFrame: false
        )

        XCTAssertTrue(logs.isEmpty)
    }
}

private struct ScratchpadRuntimeFixture {
    let directoryURL: URL
    let store: ScratchpadDocumentStore

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = ScratchpadDocumentStore(directoryURL: directoryURL)
    }
}
