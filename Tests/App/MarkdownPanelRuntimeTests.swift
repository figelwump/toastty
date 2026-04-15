import AppKit
@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class MarkdownPanelRuntimeTests: XCTestCase {
    func testLocalOnlyCapabilityProfileUsesNonPersistentWebsiteDataStore() {
        let configuration = MarkdownPanelRuntime.makeWebViewConfiguration(for: .localOnly)

        XCTAssertFalse(configuration.websiteDataStore.isPersistent)
    }

    func testApplySkipsDuplicateReloadWhenWebStateIsUnchanged() async throws {
        let bootstrapRecorder = BootstrapRecorder()
        let metadataExpectation = expectation(description: "Initial metadata update arrives")
        metadataExpectation.assertForOverFulfill = true
        var metadataCallCount = 0

        let runtime = MarkdownPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataCallCount += 1
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await bootstrapRecorder.recordCall()
                return MarkdownPanelDocumentSnapshot(
                    filePath: webState.filePath,
                    displayName: webState.title,
                    content: "# Docs",
                    diskRevision: nil
                )
            },
            reloadDebounceNanoseconds: 10_000_000
        )
        let webState = WebPanelState(
            definition: .localDocument,
            title: "README.md",
            filePath: "/tmp/toastty/readme.md"
        )

        runtime.apply(webState: webState)
        runtime.apply(webState: webState)

        await fulfillment(of: [metadataExpectation], timeout: 1)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(metadataCallCount, 1)
        let bootstrapCallCount = await bootstrapRecorder.snapshot()
        XCTAssertEqual(bootstrapCallCount, 1)
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

    func testEditingSessionAdvancesRevisionWhenCleanBaselineChanges() {
        var session = MarkdownEditingSession(
            document: MarkdownPanelDocumentSnapshot(
                filePath: "/tmp/toastty/notes.md",
                displayName: "notes.md",
                content: "# First",
                diskRevision: nil
            )
        )

        session.replaceCleanBaseline(
            with: MarkdownPanelDocumentSnapshot(
                filePath: "/tmp/toastty/notes.md",
                displayName: "notes.md",
                content: "# Second",
                diskRevision: nil
            )
        )

        XCTAssertEqual(session.contentRevision, 2)
        XCTAssertEqual(session.loadedContent, "# Second")
        XCTAssertEqual(session.draftContent, "# Second")
        XCTAssertFalse(session.isDirty)
    }

    func testEditingSessionKeepsRevisionForSameContentRebootstrap() {
        var session = MarkdownEditingSession(
            document: MarkdownPanelDocumentSnapshot(
                filePath: "/tmp/toastty/notes.md",
                displayName: "notes.md",
                content: "# Notes",
                diskRevision: nil
            )
        )

        session.replaceCleanBaseline(
            with: MarkdownPanelDocumentSnapshot(
                filePath: "/tmp/toastty/notes.md",
                displayName: "Notes",
                content: "# Notes",
                diskRevision: MarkdownPanelDiskRevision(
                    fileNumber: 42,
                    modificationDate: Date(timeIntervalSince1970: 123),
                    size: 7
                )
            )
        )

        XCTAssertEqual(session.contentRevision, 1)
        XCTAssertEqual(session.displayName, "Notes")
        XCTAssertEqual(session.loadedContent, "# Notes")
        XCTAssertEqual(session.draftContent, "# Notes")
        XCTAssertEqual(
            session.diskRevision,
            MarkdownPanelDiskRevision(
                fileNumber: 42,
                modificationDate: Date(timeIntervalSince1970: 123),
                size: 7
            )
        )
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
                definition: .localDocument,
                title: "README.md",
                filePath: fileURL.path
            )
        )

        XCTAssertEqual(bootstrap.contractVersion, 3)
        XCTAssertEqual(bootstrap.displayName, "README.md")
        XCTAssertEqual(bootstrap.filePath, fileURL.path)
        XCTAssertEqual(bootstrap.content, "# Hello Toastty\n\nA local markdown panel.")
        XCTAssertEqual(bootstrap.contentRevision, 1)
        XCTAssertFalse(bootstrap.isEditing)
        XCTAssertFalse(bootstrap.isDirty)
        XCTAssertFalse(bootstrap.hasExternalConflict)
        XCTAssertFalse(bootstrap.isSaving)
        XCTAssertNil(bootstrap.saveErrorMessage)
        XCTAssertEqual(bootstrap.theme, .dark)
    }

    func testBootstrapFallsBackToErrorDocumentWhenFileIsMissing() async {
        let filePath = "/tmp/toastty/missing.md"

        let bootstrap = await MarkdownPanelRuntime.bootstrap(
            for: WebPanelState(
                definition: .localDocument,
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
            content: "# Docs",
            contentRevision: 7,
            isEditing: true,
            isDirty: true,
            hasExternalConflict: true,
            isSaving: false,
            saveErrorMessage: "Could not save",
            theme: .dark
        )

        let script = try XCTUnwrap(MarkdownPanelRuntime.bootstrapJavaScript(for: bootstrap))

        XCTAssertTrue(script.contains("window.ToasttyMarkdownPanel?.receiveBootstrap("))
        XCTAssertTrue(script.contains("\"contractVersion\":3"))
        XCTAssertTrue(script.contains("\"displayName\":\"readme.md\""))
        XCTAssertTrue(script.contains("\"content\":\"# Docs\""))
        XCTAssertTrue(script.contains("\"contentRevision\":7"))
        XCTAssertTrue(script.contains("\"isEditing\":true"))
        XCTAssertTrue(script.contains("\"isDirty\":true"))
        XCTAssertTrue(script.contains("\"hasExternalConflict\":true"))
        XCTAssertTrue(script.contains("\"saveErrorMessage\":\"Could not save\""))
        XCTAssertTrue(script.contains("\"theme\":\"dark\""))
    }

    func testThemeResolvesFromEffectiveAppearance() {
        XCTAssertEqual(MarkdownPanelRuntime.theme(for: NSAppearance(named: .darkAqua)), .dark)
        XCTAssertEqual(MarkdownPanelRuntime.theme(for: NSAppearance(named: .aqua)), .light)
        XCTAssertEqual(MarkdownPanelRuntime.theme(for: nil), .dark)
    }

    func testApplyUsesCurrentEffectiveAppearanceThemeForBootstrap() async throws {
        let bootstrapRecorder = BootstrapRecorder()
        let metadataExpectation = expectation(description: "Initial metadata update arrives")
        metadataExpectation.assertForOverFulfill = true

        let runtime = MarkdownPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await bootstrapRecorder.recordCall()
                return MarkdownPanelDocumentSnapshot(
                    filePath: webState.filePath,
                    displayName: webState.title,
                    content: "# Docs",
                    diskRevision: nil
                )
            },
            reloadDebounceNanoseconds: 10_000_000
        )
        let webState = WebPanelState(
            definition: .localDocument,
            title: "README.md",
            filePath: "/tmp/toastty/readme.md"
        )

        runtime.applyEffectiveAppearance(NSAppearance(named: .aqua))
        runtime.apply(webState: webState)

        await fulfillment(of: [metadataExpectation], timeout: 1)

        let bootstrapCallCount = await bootstrapRecorder.snapshot()
        XCTAssertEqual(bootstrapCallCount, 1)
        XCTAssertEqual(runtime.automationState().currentBootstrap?.theme, .light)
    }

    func testAppearanceChangeDoesNotReReadMarkdownContent() async throws {
        let bootstrapRecorder = BootstrapRecorder()
        let metadataExpectation = expectation(description: "Initial metadata update arrives")
        metadataExpectation.assertForOverFulfill = true

        let runtime = MarkdownPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await bootstrapRecorder.recordCall()
                return MarkdownPanelDocumentSnapshot(
                    filePath: webState.filePath,
                    displayName: webState.title,
                    content: "# Docs",
                    diskRevision: nil
                )
            },
            reloadDebounceNanoseconds: 10_000_000
        )
        let webState = WebPanelState(
            definition: .localDocument,
            title: "README.md",
            filePath: "/tmp/toastty/readme.md"
        )

        runtime.apply(webState: webState)
        await fulfillment(of: [metadataExpectation], timeout: 1)

        runtime.applyEffectiveAppearance(NSAppearance(named: .aqua))
        try await Task.sleep(nanoseconds: 100_000_000)

        let bootstrapCallCount = await bootstrapRecorder.snapshot()
        XCTAssertEqual(bootstrapCallCount, 1)
    }

    func testObservedFileReplacementTriggersSingleReload() async throws {
        let bootstrapRecorder = BootstrapRecorder()
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("README.md")
        try "# Initial\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let initialLoad = expectation(description: "Initial metadata update arrives")
        initialLoad.assertForOverFulfill = true
        let liveReload = expectation(description: "Live reload metadata update arrives")
        liveReload.assertForOverFulfill = true
        var metadataCallCount = 0

        let runtime = MarkdownPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataCallCount += 1
                if metadataCallCount == 1 {
                    initialLoad.fulfill()
                } else if metadataCallCount == 2 {
                    liveReload.fulfill()
                }
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await bootstrapRecorder.recordCall()
                return await MarkdownPanelRuntime.loadDocument(for: webState)
            },
            reloadDebounceNanoseconds: 50_000_000
        )
        let webState = WebPanelState(
            definition: .localDocument,
            title: "README.md",
            filePath: fileURL.path
        )

        runtime.apply(webState: webState)
        await fulfillment(of: [initialLoad], timeout: 1)

        try "# Updated\n".write(to: fileURL, atomically: true, encoding: .utf8)

        await fulfillment(of: [liveReload], timeout: 1)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(metadataCallCount, 2)
        let bootstrapCallCount = await bootstrapRecorder.snapshot()
        XCTAssertEqual(bootstrapCallCount, 2)
    }

    func testObservedFileDeletionAndRecreationReloadsAtSamePath() async throws {
        let bootstrapRecorder = BootstrapRecorder()
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("notes.md")
        try "# Notes\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let initialLoad = expectation(description: "Initial metadata update arrives")
        initialLoad.assertForOverFulfill = true
        let deletedReload = expectation(description: "Missing-file reload arrives")
        deletedReload.assertForOverFulfill = true
        let recreatedReload = expectation(description: "Recovered-file reload arrives")
        recreatedReload.assertForOverFulfill = true
        var metadataCallCount = 0

        let runtime = MarkdownPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataCallCount += 1
                switch metadataCallCount {
                case 1:
                    initialLoad.fulfill()
                case 2:
                    deletedReload.fulfill()
                case 3:
                    recreatedReload.fulfill()
                default:
                    break
                }
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await bootstrapRecorder.recordCall()
                return await MarkdownPanelRuntime.loadDocument(for: webState)
            },
            reloadDebounceNanoseconds: 50_000_000
        )
        let webState = WebPanelState(
            definition: .localDocument,
            title: "notes.md",
            filePath: fileURL.path
        )

        runtime.apply(webState: webState)
        await fulfillment(of: [initialLoad], timeout: 1)

        try FileManager.default.removeItem(at: fileURL)
        await fulfillment(of: [deletedReload], timeout: 1)

        try "# Notes restored\n".write(to: fileURL, atomically: true, encoding: .utf8)
        await fulfillment(of: [recreatedReload], timeout: 1)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(metadataCallCount, 3)
        let bootstrapCallCount = await bootstrapRecorder.snapshot()
        XCTAssertEqual(bootstrapCallCount, 3)
    }

    func testRetargetingStopsObservingPreviousMarkdownPath() async throws {
        let bootstrapRecorder = BootstrapRecorder()
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let firstFileURL = tempDirectoryURL.appendingPathComponent("first.md")
        let secondFileURL = tempDirectoryURL.appendingPathComponent("second.md")
        try "# First\n".write(to: firstFileURL, atomically: true, encoding: .utf8)
        try "# Second\n".write(to: secondFileURL, atomically: true, encoding: .utf8)

        let initialLoad = expectation(description: "Initial metadata update arrives")
        initialLoad.assertForOverFulfill = true
        let retargetLoad = expectation(description: "Retarget metadata update arrives")
        retargetLoad.assertForOverFulfill = true
        let secondFileReload = expectation(description: "Second file live reload arrives")
        secondFileReload.assertForOverFulfill = true
        var metadataCallCount = 0

        let runtime = MarkdownPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataCallCount += 1
                switch metadataCallCount {
                case 1:
                    initialLoad.fulfill()
                case 2:
                    retargetLoad.fulfill()
                case 3:
                    secondFileReload.fulfill()
                default:
                    break
                }
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await bootstrapRecorder.recordCall()
                return await MarkdownPanelRuntime.loadDocument(for: webState)
            },
            reloadDebounceNanoseconds: 50_000_000
        )

        runtime.apply(
            webState: WebPanelState(
                definition: .localDocument,
                title: "first.md",
                filePath: firstFileURL.path
            )
        )
        await fulfillment(of: [initialLoad], timeout: 1)

        runtime.apply(
            webState: WebPanelState(
                definition: .localDocument,
                title: "second.md",
                filePath: secondFileURL.path
            )
        )
        await fulfillment(of: [retargetLoad], timeout: 1)

        try "# First updated\n".write(to: firstFileURL, atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(metadataCallCount, 2)

        try "# Second updated\n".write(to: secondFileURL, atomically: true, encoding: .utf8)
        await fulfillment(of: [secondFileReload], timeout: 1)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(metadataCallCount, 3)
        let bootstrapCallCount = await bootstrapRecorder.snapshot()
        XCTAssertEqual(bootstrapCallCount, 3)
    }
}

private actor BootstrapRecorder {
    private var callCount = 0

    func recordCall() {
        callCount += 1
    }

    func snapshot() -> Int {
        callCount
    }
}
