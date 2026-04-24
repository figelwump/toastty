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
        XCTAssertTrue(runtime.automationState().recentDiagnostics.isEmpty)
    }

    func testGeneratedContentDiagnosticsAreRecordedInAutomationState() throws {
        let fixture = try ScratchpadRuntimeFixture()
        var logs: [(ToasttyLogLevel, String, [String: String])] = []
        let runtime = ScratchpadPanelRuntime(
            panelID: UUID(),
            documentStore: fixture.store,
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            diagnosticLogger: { level, message, metadata in
                logs.append((level, message, metadata))
            }
        )

        runtime.simulateBridgeMessageForTesting([
            "type": "javascriptError",
            "diagnosticSource": "generated-content",
            "message": "Cannot read properties of null",
            "source": "about:srcdoc",
            "line": 14,
            "column": 9,
            "stack": "render@about:srcdoc:14:9",
        ])

        let diagnostic = try XCTUnwrap(runtime.automationState().recentDiagnostics.first)
        XCTAssertEqual(diagnostic.source, "generated-content")
        XCTAssertEqual(diagnostic.kind, "javascript-error")
        XCTAssertEqual(diagnostic.level, "error")
        XCTAssertEqual(diagnostic.message, "Cannot read properties of null")
        XCTAssertEqual(diagnostic.metadata["source"], "about:srcdoc")
        XCTAssertEqual(diagnostic.metadata["line"], "14")
        XCTAssertEqual(diagnostic.metadata["column"], "9")
        XCTAssertEqual(diagnostic.metadata["stack"], "render@about:srcdoc:14:9")
        XCTAssertEqual(logs.last?.0, .error)
        XCTAssertEqual(logs.last?.1, "Scratchpad JavaScript error")
        XCTAssertEqual(logs.last?.2["diagnostic_source"], "generated-content")
    }

    func testContentSecurityPolicyViolationsAreRecordedInAutomationState() throws {
        let fixture = try ScratchpadRuntimeFixture()
        let runtime = ScratchpadPanelRuntime(
            panelID: UUID(),
            documentStore: fixture.store,
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            diagnosticLogger: { _, _, _ in }
        )

        runtime.simulateBridgeMessageForTesting([
            "type": "cspViolation",
            "diagnosticSource": "generated-content",
            "violatedDirective": "connect-src",
            "effectiveDirective": "connect-src",
            "blockedURI": "https://example.com/data.json",
            "sourceFile": "about:srcdoc",
            "line": 22,
            "column": 5,
            "disposition": "enforce",
        ])

        let diagnostic = try XCTUnwrap(runtime.automationState().recentDiagnostics.first)
        XCTAssertEqual(diagnostic.source, "generated-content")
        XCTAssertEqual(diagnostic.kind, "csp-violation")
        XCTAssertEqual(diagnostic.level, "warn")
        XCTAssertEqual(diagnostic.message, "Blocked https://example.com/data.json by connect-src")
        XCTAssertEqual(diagnostic.metadata["violatedDirective"], "connect-src")
        XCTAssertEqual(diagnostic.metadata["effectiveDirective"], "connect-src")
        XCTAssertEqual(diagnostic.metadata["blockedURI"], "https://example.com/data.json")
        XCTAssertEqual(diagnostic.metadata["sourceFile"], "about:srcdoc")
    }

    func testDiagnosticsResetWhenBootstrapReloads() throws {
        let fixture = try ScratchpadRuntimeFixture()
        let runtime = ScratchpadPanelRuntime(
            panelID: UUID(),
            documentStore: fixture.store,
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            diagnosticLogger: { _, _, _ in }
        )
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

        runtime.simulateBridgeMessageForTesting([
            "type": "consoleMessage",
            "diagnosticSource": "generated-content",
            "level": "error",
            "message": "before reload",
        ])
        XCTAssertEqual(runtime.automationState().recentDiagnostics.count, 1)

        runtime.reloadBootstrap(for: webState)

        XCTAssertTrue(runtime.automationState().recentDiagnostics.isEmpty)
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
