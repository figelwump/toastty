import AppKit
@testable import ToasttyApp
import CoreState
import WebKit
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

    func testSetEffectivelyVisibleHidesAttachedWebViewWithoutDetaching() {
        let runtime = MarkdownPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let attachment = PanelHostAttachmentToken.next()

        runtime.attachHost(to: container, attachment: attachment)
        runtime.setEffectivelyVisible(false)

        XCTAssertEqual(container.subviews.count, 1)
        XCTAssertTrue(container.subviews[0].isHidden)

        runtime.setEffectivelyVisible(true)

        XCTAssertEqual(container.subviews.count, 1)
        XCTAssertFalse(container.subviews[0].isHidden)
    }

    func testSetEffectivelyVisibleBeforeAttachKeepsWebViewHiddenOnAttach() {
        let runtime = MarkdownPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let attachment = PanelHostAttachmentToken.next()

        runtime.setEffectivelyVisible(false)
        runtime.attachHost(to: container, attachment: attachment)

        XCTAssertEqual(container.subviews.count, 1)
        XCTAssertTrue(container.subviews[0] is WKWebView)
        XCTAssertTrue(container.subviews[0].isHidden)
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

    func testEnterEditModeSwitchesBootstrapIntoEditingState() async throws {
        let metadataExpectation = expectation(description: "Initial metadata update arrives")
        let runtime = MarkdownPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                MarkdownPanelDocumentSnapshot(
                    filePath: webState.filePath,
                    displayName: webState.title,
                    content: "# Draft",
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

        runtime.enterEditMode()

        let bootstrap = try XCTUnwrap(runtime.automationState().currentBootstrap)
        XCTAssertTrue(bootstrap.isEditing)
        XCTAssertFalse(bootstrap.isDirty)
        XCTAssertEqual(bootstrap.content, "# Draft")
        XCTAssertEqual(bootstrap.contentRevision, 1)
    }

    func testDraftUpdateTracksEditingBufferWithoutAdvancingRevision() async throws {
        let metadataExpectation = expectation(description: "Initial metadata update arrives")

        let runtime = MarkdownPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                MarkdownPanelDocumentSnapshot(
                    filePath: webState.filePath,
                    displayName: webState.title,
                    content: "# Original",
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
        runtime.enterEditMode()
        let baseRevision = try XCTUnwrap(runtime.automationState().currentBootstrap?.contentRevision)

        runtime.updateDraftContent("## Changed", baseContentRevision: baseRevision)

        let bootstrap = try XCTUnwrap(runtime.automationState().currentBootstrap)
        XCTAssertTrue(bootstrap.isEditing)
        XCTAssertTrue(bootstrap.isDirty)
        XCTAssertEqual(bootstrap.content, "## Changed")
        XCTAssertEqual(bootstrap.contentRevision, baseRevision)
    }

    func testDraftUpdateIgnoresStaleRevision() async throws {
        let metadataExpectation = expectation(description: "Initial metadata update arrives")

        let runtime = MarkdownPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                MarkdownPanelDocumentSnapshot(
                    filePath: webState.filePath,
                    displayName: webState.title,
                    content: "# Original",
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
        runtime.enterEditMode()
        let baseRevision = try XCTUnwrap(runtime.automationState().currentBootstrap?.contentRevision)

        runtime.updateDraftContent("## Ignored", baseContentRevision: baseRevision + 1)

        let bootstrap = try XCTUnwrap(runtime.automationState().currentBootstrap)
        XCTAssertTrue(bootstrap.isEditing)
        XCTAssertFalse(bootstrap.isDirty)
        XCTAssertEqual(bootstrap.content, "# Original")
        XCTAssertEqual(bootstrap.contentRevision, baseRevision)
    }

    func testCancelEditModeRestoresPreviewAndAdvancesRevision() async throws {
        let metadataExpectation = expectation(description: "Initial metadata update arrives")

        let runtime = MarkdownPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                MarkdownPanelDocumentSnapshot(
                    filePath: webState.filePath,
                    displayName: webState.title,
                    content: "# Original",
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
        runtime.enterEditMode()
        let baseRevision = try XCTUnwrap(runtime.automationState().currentBootstrap?.contentRevision)
        runtime.updateDraftContent("## Changed", baseContentRevision: baseRevision)

        runtime.cancelEditMode(baseContentRevision: baseRevision)

        let bootstrap = try XCTUnwrap(runtime.automationState().currentBootstrap)
        XCTAssertFalse(bootstrap.isEditing)
        XCTAssertFalse(bootstrap.isDirty)
        XCTAssertEqual(bootstrap.content, "# Original")
        XCTAssertEqual(bootstrap.contentRevision, baseRevision + 1)
    }

    func testSaveWritesDraftToDiskAndReturnsToPreview() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("README.md")
        try "# Original\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let runtime = MarkdownPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await MarkdownPanelRuntime.loadDocument(for: webState)
            },
            reloadDebounceNanoseconds: 10_000_000
        )
        let webState = WebPanelState(
            definition: .localDocument,
            title: "README.md",
            filePath: fileURL.path
        )

        runtime.apply(webState: webState)
        try await waitUntil { runtime.automationState().currentBootstrap != nil }
        runtime.enterEditMode()
        let baseRevision = try XCTUnwrap(runtime.automationState().currentBootstrap?.contentRevision)
        runtime.updateDraftContent("# Saved\n", baseContentRevision: baseRevision)

        runtime.save(baseContentRevision: baseRevision)
        try await Task.sleep(nanoseconds: 250_000_000)

        let bootstrap = try XCTUnwrap(runtime.automationState().currentBootstrap)
        XCTAssertFalse(bootstrap.isEditing)
        XCTAssertFalse(bootstrap.isDirty)
        XCTAssertFalse(bootstrap.hasExternalConflict)
        XCTAssertFalse(bootstrap.isSaving)
        XCTAssertNil(bootstrap.saveErrorMessage)
        XCTAssertEqual(bootstrap.contentRevision, baseRevision + 1)
        XCTAssertEqual(bootstrap.content, "# Saved\n")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "# Saved\n")
    }

    func testSaveFailureKeepsEditingDraftAndSurfacesError() async throws {
        let missingDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = missingDirectoryURL.appendingPathComponent("README.md")

        let runtime = MarkdownPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                MarkdownPanelDocumentSnapshot(
                    filePath: webState.filePath,
                    displayName: webState.title,
                    content: "# Original\n",
                    diskRevision: nil
                )
            },
            reloadDebounceNanoseconds: 10_000_000
        )
        let webState = WebPanelState(
            definition: .localDocument,
            title: "README.md",
            filePath: fileURL.path
        )

        runtime.apply(webState: webState)
        try await waitUntil { runtime.automationState().currentBootstrap != nil }
        runtime.enterEditMode()
        let baseRevision = try XCTUnwrap(runtime.automationState().currentBootstrap?.contentRevision)
        runtime.updateDraftContent("# Failed save\n", baseContentRevision: baseRevision)

        runtime.save(baseContentRevision: baseRevision)
        try await Task.sleep(nanoseconds: 250_000_000)

        let bootstrap = try XCTUnwrap(runtime.automationState().currentBootstrap)
        XCTAssertTrue(bootstrap.isEditing)
        XCTAssertTrue(bootstrap.isDirty)
        XCTAssertFalse(bootstrap.hasExternalConflict)
        XCTAssertFalse(bootstrap.isSaving)
        XCTAssertEqual(bootstrap.contentRevision, baseRevision)
        XCTAssertEqual(bootstrap.content, "# Failed save\n")
        XCTAssertNotNil(bootstrap.saveErrorMessage)
    }

    func testExternalModificationWhileDirtyPreservesDraftAndRaisesConflict() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("README.md")
        try "# Original\n".write(to: fileURL, atomically: true, encoding: .utf8)

        var metadataCallCount = 0

        let runtime = MarkdownPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataCallCount += 1
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await MarkdownPanelRuntime.loadDocument(for: webState)
            },
            reloadDebounceNanoseconds: 50_000_000
        )
        let webState = WebPanelState(
            definition: .localDocument,
            title: "README.md",
            filePath: fileURL.path
        )

        runtime.apply(webState: webState)
        try await waitUntil { metadataCallCount >= 1 }
        runtime.enterEditMode()
        let baseRevision = try XCTUnwrap(runtime.automationState().currentBootstrap?.contentRevision)
        runtime.updateDraftContent("# Local draft\n", baseContentRevision: baseRevision)

        try "# External change\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try await waitUntil { metadataCallCount >= 2 }

        let bootstrap = try XCTUnwrap(runtime.automationState().currentBootstrap)
        XCTAssertTrue(bootstrap.isEditing)
        XCTAssertTrue(bootstrap.isDirty)
        XCTAssertTrue(bootstrap.hasExternalConflict)
        XCTAssertEqual(bootstrap.contentRevision, baseRevision)
        XCTAssertEqual(bootstrap.content, "# Local draft\n")

        runtime.cancelEditMode(baseContentRevision: baseRevision)
        let canceledBootstrap = try XCTUnwrap(runtime.automationState().currentBootstrap)
        XCTAssertFalse(canceledBootstrap.isEditing)
        XCTAssertFalse(canceledBootstrap.isDirty)
        XCTAssertFalse(canceledBootstrap.hasExternalConflict)
        XCTAssertEqual(canceledBootstrap.content, "# External change\n")
    }

    func testOverwriteAfterConflictWritesDraftAndReturnsToPreview() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("README.md")
        try "# Original\n".write(to: fileURL, atomically: true, encoding: .utf8)

        var metadataCallCount = 0

        let runtime = MarkdownPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataCallCount += 1
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await MarkdownPanelRuntime.loadDocument(for: webState)
            },
            reloadDebounceNanoseconds: 50_000_000
        )
        let webState = WebPanelState(
            definition: .localDocument,
            title: "README.md",
            filePath: fileURL.path
        )

        runtime.apply(webState: webState)
        try await waitUntil { metadataCallCount >= 1 }
        runtime.enterEditMode()
        let baseRevision = try XCTUnwrap(runtime.automationState().currentBootstrap?.contentRevision)
        runtime.updateDraftContent("# Local draft\n", baseContentRevision: baseRevision)

        try "# External change\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try await waitUntil { metadataCallCount >= 2 }

        runtime.overwriteAfterConflict(baseContentRevision: baseRevision)
        try await Task.sleep(nanoseconds: 250_000_000)

        let bootstrap = try XCTUnwrap(runtime.automationState().currentBootstrap)
        XCTAssertFalse(bootstrap.isEditing)
        XCTAssertFalse(bootstrap.isDirty)
        XCTAssertFalse(bootstrap.hasExternalConflict)
        XCTAssertFalse(bootstrap.isSaving)
        XCTAssertEqual(bootstrap.contentRevision, baseRevision + 1)
        XCTAssertEqual(bootstrap.content, "# Local draft\n")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "# Local draft\n")
    }

    func testDuplicateSaveRequestsWhileSavingTriggerSingleWrite() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("README.md")
        try "# Original\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let saver = ControlledDocumentSaver()
        let runtime = MarkdownPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await MarkdownPanelRuntime.loadDocument(for: webState)
            },
            documentSaver: { filePath, content in
                try await saver.save(filePath: filePath, content: content)
            },
            savedDocumentReader: { filePath, displayName in
                var encoding = String.Encoding.utf8
                let content = try String(contentsOf: URL(fileURLWithPath: filePath), usedEncoding: &encoding)
                let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
                return MarkdownPanelDocumentSnapshot(
                    filePath: filePath,
                    displayName: displayName,
                    content: content,
                    diskRevision: MarkdownPanelDiskRevision(
                        fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                        modificationDate: attributes[.modificationDate] as? Date,
                        size: (attributes[.size] as? NSNumber)?.uint64Value
                    )
                )
            },
            reloadDebounceNanoseconds: 10_000_000
        )
        let webState = WebPanelState(
            definition: .localDocument,
            title: "README.md",
            filePath: fileURL.path
        )

        runtime.apply(webState: webState)
        try await waitUntil { runtime.automationState().currentBootstrap != nil }
        runtime.enterEditMode()
        let baseRevision = try XCTUnwrap(runtime.automationState().currentBootstrap?.contentRevision)
        runtime.updateDraftContent("# Saved once\n", baseContentRevision: baseRevision)

        runtime.save(baseContentRevision: baseRevision)
        runtime.save(baseContentRevision: baseRevision)
        try await Task.sleep(nanoseconds: 50_000_000)

        let savingBootstrap = try XCTUnwrap(runtime.automationState().currentBootstrap)
        let saveCallCountWhileSaving = await saver.snapshot()
        XCTAssertTrue(savingBootstrap.isSaving)
        XCTAssertEqual(saveCallCountWhileSaving, 1)

        await saver.resume()
        try await Task.sleep(nanoseconds: 250_000_000)

        let bootstrap = try XCTUnwrap(runtime.automationState().currentBootstrap)
        let finalSaveCallCount = await saver.snapshot()
        XCTAssertFalse(bootstrap.isSaving)
        XCTAssertFalse(bootstrap.isEditing)
        XCTAssertEqual(bootstrap.content, "# Saved once\n")
        XCTAssertEqual(finalSaveCallCount, 1)
    }

    func testCloseConfirmationStateWaitsForSaveInProgress() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("README.md")
        try "# Original\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let saver = ControlledDocumentSaver()
        let runtime = MarkdownPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await MarkdownPanelRuntime.loadDocument(for: webState)
            },
            documentSaver: { filePath, content in
                try await saver.save(filePath: filePath, content: content)
            },
            reloadDebounceNanoseconds: 10_000_000
        )
        let webState = WebPanelState(
            definition: .localDocument,
            title: "README.md",
            filePath: fileURL.path
        )

        runtime.apply(webState: webState)
        try await waitUntil { runtime.automationState().currentBootstrap != nil }
        runtime.enterEditMode()
        let baseRevision = try XCTUnwrap(runtime.automationState().currentBootstrap?.contentRevision)
        runtime.updateDraftContent("# Saving\n", baseContentRevision: baseRevision)

        runtime.save(baseContentRevision: baseRevision)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(
            runtime.closeConfirmationState(),
            MarkdownCloseConfirmationState(kind: .saveInProgress, displayName: "README.md")
        )

        await saver.resume()
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

    func testShouldApplyWebViewAppearanceSkipsSameNamedAppearance() {
        XCTAssertFalse(
            MarkdownPanelRuntime.shouldApplyWebViewAppearance(
                current: NSAppearance(named: .aqua),
                next: NSAppearance(named: .aqua)
            )
        )
    }

    func testShouldApplyWebViewAppearanceAllowsMeaningfulAppearanceChanges() {
        XCTAssertTrue(
            MarkdownPanelRuntime.shouldApplyWebViewAppearance(
                current: NSAppearance(named: .darkAqua),
                next: NSAppearance(named: .aqua)
            )
        )
        XCTAssertTrue(
            MarkdownPanelRuntime.shouldApplyWebViewAppearance(
                current: nil,
                next: NSAppearance(named: .aqua)
            )
        )
        XCTAssertTrue(
            MarkdownPanelRuntime.shouldApplyWebViewAppearance(
                current: NSAppearance(named: .aqua),
                next: nil
            )
        )
        XCTAssertFalse(
            MarkdownPanelRuntime.shouldApplyWebViewAppearance(
                current: nil,
                next: nil
            )
        )
    }

    func testApplyUsesCurrentEffectiveAppearanceThemeForBootstrap() async throws {
        let bootstrapRecorder = BootstrapRecorder()
        let metadataExpectation = expectation(description: "Initial metadata update arrives")

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

    func testObservedFileReplacementReloadsUpdatedContent() async throws {
        let bootstrapRecorder = BootstrapRecorder()
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("README.md")
        try "# Initial\n".write(to: fileURL, atomically: true, encoding: .utf8)

        var metadataCallCount = 0

        let runtime = MarkdownPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataCallCount += 1
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
        try await waitUntil { metadataCallCount >= 1 }

        try "# Updated\n".write(to: fileURL, atomically: true, encoding: .utf8)

        try await waitUntil { metadataCallCount >= 2 }
        try await Task.sleep(nanoseconds: 200_000_000)

        let bootstrap = try XCTUnwrap(runtime.automationState().currentBootstrap)
        XCTAssertEqual(bootstrap.content, "# Updated\n")
        XCTAssertGreaterThanOrEqual(metadataCallCount, 2)
        let bootstrapCallCount = await bootstrapRecorder.snapshot()
        XCTAssertGreaterThanOrEqual(bootstrapCallCount, 2)
    }

    func testObservedFileDeletionAndRecreationReloadsAtSamePath() async throws {
        let bootstrapRecorder = BootstrapRecorder()
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("notes.md")
        try "# Notes\n".write(to: fileURL, atomically: true, encoding: .utf8)

        var metadataCallCount = 0

        let runtime = MarkdownPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataCallCount += 1
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
        try await waitUntil { metadataCallCount >= 1 }

        try FileManager.default.removeItem(at: fileURL)
        try await waitUntil { metadataCallCount >= 2 }
        let deletedBootstrap = try XCTUnwrap(runtime.automationState().currentBootstrap)
        XCTAssertTrue(deletedBootstrap.content.contains("Toastty could not load this markdown file."))
        XCTAssertTrue(deletedBootstrap.content.contains(fileURL.path))

        try "# Notes restored\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try await waitUntil { metadataCallCount >= 3 }
        try await Task.sleep(nanoseconds: 200_000_000)

        let recreatedBootstrap = try XCTUnwrap(runtime.automationState().currentBootstrap)
        XCTAssertEqual(recreatedBootstrap.content, "# Notes restored\n")
        XCTAssertGreaterThanOrEqual(metadataCallCount, 3)
        let bootstrapCallCount = await bootstrapRecorder.snapshot()
        XCTAssertGreaterThanOrEqual(bootstrapCallCount, 3)
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

        var metadataCallCount = 0

        let runtime = MarkdownPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataCallCount += 1
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
        try await waitUntil { metadataCallCount >= 1 }

        runtime.apply(
            webState: WebPanelState(
                definition: .localDocument,
                title: "second.md",
                filePath: secondFileURL.path
            )
        )
        try await waitUntil { metadataCallCount >= 2 }

        try "# First updated\n".write(to: firstFileURL, atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(metadataCallCount, 2)

        try "# Second updated\n".write(to: secondFileURL, atomically: true, encoding: .utf8)
        try await waitUntil { metadataCallCount >= 3 }
        try await Task.sleep(nanoseconds: 200_000_000)

        let bootstrap = try XCTUnwrap(runtime.automationState().currentBootstrap)
        XCTAssertEqual(bootstrap.content, "# Second updated\n")
        XCTAssertGreaterThanOrEqual(metadataCallCount, 3)
        let bootstrapCallCount = await bootstrapRecorder.snapshot()
        XCTAssertGreaterThanOrEqual(bootstrapCallCount, 3)
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

private actor ControlledDocumentSaver {
    private var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func save(filePath: String, content: String) async throws {
        callCount += 1
        try content.write(to: URL(fileURLWithPath: filePath), atomically: true, encoding: .utf8)
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func snapshot() -> Int {
        callCount
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private struct WaitUntilTimedOutError: Error {}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollIntervalNanoseconds: UInt64 = 10_000_000,
    condition: @MainActor () -> Bool
) async throws {
    let timeoutInterval = Duration.nanoseconds(Int64(timeoutNanoseconds))
    let pollInterval = Duration.nanoseconds(Int64(pollIntervalNanoseconds))
    let deadline = ContinuousClock.now + timeoutInterval

    while condition() == false {
        guard ContinuousClock.now < deadline else {
            throw WaitUntilTimedOutError()
        }
        try await Task.sleep(for: pollInterval)
    }
}
