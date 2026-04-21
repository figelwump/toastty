import AppKit
@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class LocalDocumentPanelRuntimeTests: XCTestCase {
    func testLocalOnlyCapabilityProfileUsesNonPersistentWebsiteDataStore() {
        let configuration = LocalDocumentPanelRuntime.makeWebViewConfiguration(for: .localOnly)

        XCTAssertFalse(configuration.websiteDataStore.isPersistent)
    }

    func testApplySkipsDuplicateReloadWhenWebStateIsUnchanged() async throws {
        let bootstrapRecorder = BootstrapRecorder()
        let metadataExpectation = expectation(description: "Initial metadata update arrives")
        var metadataCallCount = 0

        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataCallCount += 1
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await bootstrapRecorder.recordCall()
                return LocalDocumentPanelDocumentSnapshot(
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
            .appendingPathComponent("local-document-panel", isDirectory: true)
        let entryURL = panelDirectoryURL.appendingPathComponent("index.html")

        try FileManager.default.createDirectory(at: panelDirectoryURL, withIntermediateDirectories: true)
        try Data("<!doctype html>".utf8).write(to: entryURL)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let bundleURL = tempDirectoryURL.appendingPathComponent("Test.app", isDirectory: true)
        let bundle = try XCTUnwrap(Bundle(path: bundleURL.path))

        XCTAssertEqual(LocalDocumentPanelAssetLocator.entryURL(bundle: bundle), entryURL)
        XCTAssertEqual(LocalDocumentPanelAssetLocator.directoryURL(bundle: bundle), panelDirectoryURL)
    }

    func testEditingSessionAdvancesRevisionWhenCleanBaselineChanges() {
        var session = LocalDocumentEditingSession(
            document: LocalDocumentPanelDocumentSnapshot(
                filePath: "/tmp/toastty/notes.md",
                displayName: "notes.md",
                content: "# First",
                diskRevision: nil
            )
        )

        session.replaceCleanBaseline(
            with: LocalDocumentPanelDocumentSnapshot(
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
        var session = LocalDocumentEditingSession(
            document: LocalDocumentPanelDocumentSnapshot(
                filePath: "/tmp/toastty/notes.md",
                displayName: "notes.md",
                content: "# Notes",
                diskRevision: nil
            )
        )

        session.replaceCleanBaseline(
            with: LocalDocumentPanelDocumentSnapshot(
                filePath: "/tmp/toastty/notes.md",
                displayName: "Notes",
                content: "# Notes",
                diskRevision: LocalDocumentPanelDiskRevision(
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
            LocalDocumentPanelDiskRevision(
                fileNumber: 42,
                modificationDate: Date(timeIntervalSince1970: 123),
                size: 7
            )
        )
    }

    func testEnterEditModeSwitchesBootstrapIntoEditingState() async throws {
        let metadataExpectation = expectation(description: "Initial metadata update arrives")
        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                LocalDocumentPanelDocumentSnapshot(
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

        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                LocalDocumentPanelDocumentSnapshot(
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

        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                LocalDocumentPanelDocumentSnapshot(
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

        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                LocalDocumentPanelDocumentSnapshot(
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

        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await LocalDocumentPanelRuntime.loadDocument(for: webState)
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

    func testCancelEditFromCommandRestoresPreviewAndAdvancesRevision() async throws {
        let metadataExpectation = expectation(description: "Initial metadata update arrives")

        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                LocalDocumentPanelDocumentSnapshot(
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

        XCTAssertTrue(runtime.canCancelEditFromCommand())
        XCTAssertTrue(runtime.cancelEditFromCommand())

        let bootstrap = try XCTUnwrap(runtime.automationState().currentBootstrap)
        XCTAssertFalse(bootstrap.isEditing)
        XCTAssertFalse(bootstrap.isDirty)
        XCTAssertEqual(bootstrap.content, "# Original")
        XCTAssertEqual(bootstrap.contentRevision, baseRevision + 1)
        XCTAssertFalse(runtime.canCancelEditFromCommand())
    }

    func testSaveFailureKeepsEditingDraftAndSurfacesError() async throws {
        let missingDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = missingDirectoryURL.appendingPathComponent("README.md")

        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                LocalDocumentPanelDocumentSnapshot(
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

    func testOpenInDefaultAppUsesCurrentBackingFileURL() async throws {
        let filePath = "/tmp/toastty/App.swift"
        let metadataExpectation = expectation(description: "Initial metadata update arrives")
        let openExpectation = expectation(description: "External open request arrives")
        let capturedURL = LockedBox<URL?>(nil)

        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                LocalDocumentPanelDocumentSnapshot(
                    filePath: webState.filePath,
                    displayName: webState.title,
                    format: .code,
                    content: "struct App {}\n",
                    diskRevision: LocalDocumentPanelDiskRevision(
                        fileNumber: 1,
                        modificationDate: Date(),
                        size: 13
                    )
                )
            },
            externalFileOpener: { url in
                Task {
                    await capturedURL.set(url)
                    openExpectation.fulfill()
                }
                return true
            },
            reloadDebounceNanoseconds: 10_000_000
        )
        let webState = WebPanelState(
            definition: .localDocument,
            title: "App.swift",
            localDocument: LocalDocumentState(
                filePath: filePath,
                format: .code
            )
        )

        runtime.apply(webState: webState)
        await fulfillment(of: [metadataExpectation], timeout: 1)

        runtime.openInDefaultApp()
        await fulfillment(of: [openExpectation], timeout: 1)

        let openedURL = await capturedURL.snapshot()
        XCTAssertEqual(openedURL, URL(filePath: filePath))
    }

    func testOpenInDefaultAppIgnoresPanelsWithoutBackingFile() async throws {
        let metadataExpectation = expectation(description: "Initial metadata update arrives")
        let openExpectation = expectation(description: "No external open request should arrive")
        openExpectation.isInverted = true

        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                LocalDocumentPanelDocumentSnapshot(
                    filePath: webState.filePath,
                    displayName: webState.title,
                    content: "# Notes",
                    diskRevision: nil
                )
            },
            externalFileOpener: { _ in
                openExpectation.fulfill()
                return true
            },
            reloadDebounceNanoseconds: 10_000_000
        )
        let webState = WebPanelState(
            definition: .localDocument,
            title: "Untitled",
            localDocument: LocalDocumentState(filePath: nil, format: .markdown)
        )

        runtime.apply(webState: webState)
        await fulfillment(of: [metadataExpectation], timeout: 1)

        runtime.openInDefaultApp()
        await fulfillment(of: [openExpectation], timeout: 0.1)
    }

    func testExternalModificationWhileDirtyPreservesDraftAndRaisesConflict() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("README.md")
        try "# Original\n".write(to: fileURL, atomically: true, encoding: .utf8)

        var metadataCallCount = 0

        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataCallCount += 1
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await LocalDocumentPanelRuntime.loadDocument(for: webState)
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

        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataCallCount += 1
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await LocalDocumentPanelRuntime.loadDocument(for: webState)
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
        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await LocalDocumentPanelRuntime.loadDocument(for: webState)
            },
            documentSaver: { filePath, content in
                try await saver.save(filePath: filePath, content: content)
            },
            savedDocumentReader: { filePath, displayName, format in
                var encoding = String.Encoding.utf8
                let content = try String(contentsOf: URL(fileURLWithPath: filePath), usedEncoding: &encoding)
                let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
                return LocalDocumentPanelDocumentSnapshot(
                    filePath: filePath,
                    displayName: displayName,
                    format: format,
                    content: content,
                    diskRevision: LocalDocumentPanelDiskRevision(
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

    func testSavePreservesYamlFormatThroughSavedDocumentReload() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("config.yaml")
        try "mode: draft\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let capturedFormat = LockedBox<LocalDocumentFormat?>(nil)
        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await LocalDocumentPanelRuntime.loadDocument(for: webState)
            },
            documentSaver: { filePath, content in
                try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            },
            savedDocumentReader: { filePath, displayName, format in
                await capturedFormat.set(format)
                var encoding = String.Encoding.utf8
                let content = try String(contentsOf: URL(fileURLWithPath: filePath), usedEncoding: &encoding)
                let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
                return LocalDocumentPanelDocumentSnapshot(
                    filePath: filePath,
                    displayName: displayName,
                    format: format,
                    content: content,
                    diskRevision: LocalDocumentPanelDiskRevision(
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
            title: "config.yaml",
            localDocument: LocalDocumentState(
                filePath: fileURL.path,
                format: .yaml
            )
        )

        runtime.apply(webState: webState)
        try await waitUntil { runtime.automationState().currentBootstrap != nil }
        runtime.enterEditMode()
        let baseRevision = try XCTUnwrap(runtime.automationState().currentBootstrap?.contentRevision)
        runtime.updateDraftContent("mode: saved\n", baseContentRevision: baseRevision)

        runtime.save(baseContentRevision: baseRevision)
        try await waitUntil {
            guard let bootstrap = runtime.automationState().currentBootstrap else {
                return false
            }
            return bootstrap.isEditing == false && bootstrap.isSaving == false
        }

        let bootstrap: LocalDocumentPanelBootstrap = try XCTUnwrap(runtime.automationState().currentBootstrap)
        let capturedFormatValue = await capturedFormat.snapshot()
        XCTAssertEqual(capturedFormatValue, .yaml)
        XCTAssertEqual(bootstrap.format, .yaml)
        XCTAssertTrue(bootstrap.shouldHighlight)
        XCTAssertEqual(bootstrap.content, "mode: saved\n")
    }

    func testCloseConfirmationStateWaitsForSaveInProgress() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("README.md")
        try "# Original\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let saver = ControlledDocumentSaver()
        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await LocalDocumentPanelRuntime.loadDocument(for: webState)
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
            LocalDocumentCloseConfirmationState(kind: .saveInProgress, displayName: "README.md")
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

        let bootstrap = await LocalDocumentPanelRuntime.bootstrap(
            for: WebPanelState(
                definition: .localDocument,
                title: "README.md",
                localDocument: LocalDocumentState(
                    filePath: fileURL.path,
                    format: .markdown
                )
            )
        )

        XCTAssertEqual(bootstrap.contractVersion, 6)
        XCTAssertEqual(bootstrap.displayName, "README.md")
        XCTAssertEqual(bootstrap.filePath, fileURL.path)
        XCTAssertEqual(bootstrap.format, .markdown)
        XCTAssertNil(bootstrap.syntaxLanguage)
        XCTAssertEqual(bootstrap.formatLabel, "Markdown")
        XCTAssertTrue(bootstrap.shouldHighlight)
        XCTAssertEqual(bootstrap.highlightState, .enabled)
        XCTAssertEqual(bootstrap.content, "# Hello Toastty\n\nA local markdown panel.")
        XCTAssertEqual(bootstrap.contentRevision, 1)
        XCTAssertFalse(bootstrap.isEditing)
        XCTAssertFalse(bootstrap.isDirty)
        XCTAssertFalse(bootstrap.hasExternalConflict)
        XCTAssertFalse(bootstrap.isSaving)
        XCTAssertNil(bootstrap.saveErrorMessage)
        XCTAssertEqual(bootstrap.theme, .dark)
        XCTAssertEqual(bootstrap.textScale, AppState.defaultMarkdownTextScale)
    }

    func testBootstrapReadsJSONFileContents() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("package.json")
        let content = """
        {
          "name": "toastty",
          "private": true
        }
        """
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let bootstrap = await LocalDocumentPanelRuntime.bootstrap(
            for: WebPanelState(
                definition: .localDocument,
                title: "package.json",
                localDocument: LocalDocumentState(
                    filePath: fileURL.path,
                    format: .json
                )
            )
        )

        XCTAssertEqual(bootstrap.displayName, "package.json")
        XCTAssertEqual(bootstrap.filePath, fileURL.path)
        XCTAssertEqual(bootstrap.format, .json)
        XCTAssertEqual(bootstrap.syntaxLanguage, .json)
        XCTAssertEqual(bootstrap.formatLabel, "JSON")
        XCTAssertTrue(bootstrap.shouldHighlight)
        XCTAssertEqual(bootstrap.highlightState, .enabled)
        XCTAssertEqual(bootstrap.content, content)
    }

    func testBootstrapReadsSwiftFileContentsAsCodeDocument() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("App.swift")
        let content = """
        struct ToasttyApp {
            let panelCount = 1
        }
        """
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let bootstrap = await LocalDocumentPanelRuntime.bootstrap(
            for: WebPanelState(
                definition: .localDocument,
                title: "App.swift",
                localDocument: LocalDocumentState(
                    filePath: fileURL.path,
                    format: .code
                )
            )
        )

        XCTAssertEqual(bootstrap.displayName, "App.swift")
        XCTAssertEqual(bootstrap.filePath, fileURL.path)
        XCTAssertEqual(bootstrap.format, .code)
        XCTAssertEqual(bootstrap.syntaxLanguage, .swift)
        XCTAssertEqual(bootstrap.formatLabel, "Swift")
        XCTAssertTrue(bootstrap.shouldHighlight)
        XCTAssertEqual(bootstrap.highlightState, .enabled)
        XCTAssertEqual(bootstrap.content, content)
    }

    func testBootstrapReadsJSONLinesFileContents() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("events.jsonl")
        let content = """
        {"event":"toastty","kind":"launch"}
        {"event":"toastty","kind":"focus"}
        """
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let bootstrap = await LocalDocumentPanelRuntime.bootstrap(
            for: WebPanelState(
                definition: .localDocument,
                title: "events.jsonl",
                localDocument: LocalDocumentState(
                    filePath: fileURL.path,
                    format: .jsonl
                )
            )
        )

        XCTAssertEqual(bootstrap.displayName, "events.jsonl")
        XCTAssertEqual(bootstrap.filePath, fileURL.path)
        XCTAssertEqual(bootstrap.format, .jsonl)
        XCTAssertTrue(bootstrap.shouldHighlight)
        XCTAssertEqual(bootstrap.highlightState, .enabled)
        XCTAssertEqual(bootstrap.content, content)
    }

    func testBootstrapReadsShellFileContents() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("bootstrap.sh")
        let content = """
        #!/usr/bin/env bash
        set -euo pipefail
        echo "toastty"
        """
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let bootstrap = await LocalDocumentPanelRuntime.bootstrap(
            for: WebPanelState(
                definition: .localDocument,
                title: "bootstrap.sh",
                localDocument: LocalDocumentState(
                    filePath: fileURL.path,
                    format: .shell
                )
            )
        )

        XCTAssertEqual(bootstrap.displayName, "bootstrap.sh")
        XCTAssertEqual(bootstrap.filePath, fileURL.path)
        XCTAssertEqual(bootstrap.format, .shell)
        XCTAssertEqual(bootstrap.syntaxLanguage, .bash)
        XCTAssertEqual(bootstrap.formatLabel, "Shell Script")
        XCTAssertTrue(bootstrap.shouldHighlight)
        XCTAssertEqual(bootstrap.highlightState, .enabled)
        XCTAssertEqual(bootstrap.content, content)
    }

    func testBootstrapFallsBackToErrorDocumentWhenFileIsMissing() async {
        let filePath = "/tmp/toastty/missing.md"

        let bootstrap = await LocalDocumentPanelRuntime.bootstrap(
            for: WebPanelState(
                definition: .localDocument,
                title: "missing.md",
                localDocument: LocalDocumentState(
                    filePath: filePath,
                    format: .markdown
                )
            )
        )

        XCTAssertEqual(bootstrap.displayName, "missing.md")
        XCTAssertEqual(bootstrap.filePath, filePath)
        XCTAssertFalse(bootstrap.shouldHighlight)
        XCTAssertEqual(bootstrap.highlightState, .unavailable)
        XCTAssertTrue(bootstrap.content.contains("Toastty could not load this document."))
        XCTAssertTrue(bootstrap.content.contains(filePath))
        XCTAssertTrue(bootstrap.content.contains("Path:\n\(filePath)"))
        XCTAssertTrue(bootstrap.content.contains("\n\nReason:\n"))
        XCTAssertFalse(bootstrap.content.contains("**Path**"))
        XCTAssertFalse(bootstrap.content.contains("# "))
    }

    func testBootstrapForMissingYamlFallsBackToPlainTextCodeDocument() async {
        let filePath = "/tmp/toastty/missing.yaml"

        let bootstrap = await LocalDocumentPanelRuntime.bootstrap(
            for: WebPanelState(
                definition: .localDocument,
                title: "missing.yaml",
                localDocument: LocalDocumentState(
                    filePath: filePath,
                    format: .yaml
                )
            )
        )

        XCTAssertEqual(bootstrap.format, .yaml)
        XCTAssertFalse(bootstrap.shouldHighlight)
        XCTAssertEqual(bootstrap.highlightState, .unavailable)
        XCTAssertTrue(bootstrap.content.hasPrefix("Toastty could not load this document."))
        XCTAssertTrue(bootstrap.content.contains("Path:\n\(filePath)"))
        XCTAssertTrue(bootstrap.content.contains("\n\nReason:\n"))
        XCTAssertFalse(bootstrap.content.contains("**Path**"))
        XCTAssertFalse(bootstrap.content.contains("# "))
    }

    func testBootstrapDisablesHighlightingForLargeTomlFiles() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("Toastty.toml")
        let largeContent = String(repeating: "key = \"value\"\n", count: 40_500)
        try largeContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let bootstrap = await LocalDocumentPanelRuntime.bootstrap(
            for: WebPanelState(
                definition: .localDocument,
                title: "Toastty.toml",
                localDocument: LocalDocumentState(
                    filePath: fileURL.path,
                    format: .toml
                )
            )
        )

        XCTAssertEqual(bootstrap.format, .toml)
        XCTAssertFalse(bootstrap.shouldHighlight)
        XCTAssertEqual(bootstrap.highlightState, .disabledForLargeFile)
        XCTAssertEqual(bootstrap.content, largeContent)
    }

    func testBootstrapDisablesHighlightingForLargeMarkdownFiles() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("README.md")
        let largeContent = String(repeating: "# Toastty markdown-as-code\n", count: 40_500)
        try largeContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let bootstrap = await LocalDocumentPanelRuntime.bootstrap(
            for: WebPanelState(
                definition: .localDocument,
                title: "README.md",
                localDocument: LocalDocumentState(
                    filePath: fileURL.path,
                    format: .markdown
                )
            )
        )

        XCTAssertEqual(bootstrap.format, .markdown)
        XCTAssertFalse(bootstrap.shouldHighlight)
        XCTAssertEqual(bootstrap.highlightState, .disabledForLargeFile)
        XCTAssertEqual(bootstrap.content, largeContent)
    }

    func testBootstrapDisablesHighlightingForLargeJSONLinesFiles() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("events.jsonl")
        let largeContent = String(repeating: "{\"event\":\"toastty\"}\n", count: 40_500)
        try largeContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let bootstrap = await LocalDocumentPanelRuntime.bootstrap(
            for: WebPanelState(
                definition: .localDocument,
                title: "events.jsonl",
                localDocument: LocalDocumentState(
                    filePath: fileURL.path,
                    format: .jsonl
                )
            )
        )

        XCTAssertEqual(bootstrap.format, .jsonl)
        XCTAssertFalse(bootstrap.shouldHighlight)
        XCTAssertEqual(bootstrap.highlightState, .disabledForLargeFile)
        XCTAssertEqual(bootstrap.content, largeContent)
    }

    func testBootstrapLeavesJSONCHighlightingDisabled() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("settings.jsonc")
        let content = """
        {
          // toastty
          "mode": "jsonc"
        }
        """
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let bootstrap = await LocalDocumentPanelRuntime.bootstrap(
            for: WebPanelState(
                definition: .localDocument,
                title: "settings.jsonc",
                localDocument: LocalDocumentState(
                    filePath: fileURL.path,
                    format: .json
                )
            )
        )

        XCTAssertEqual(bootstrap.format, .json)
        XCTAssertNil(bootstrap.syntaxLanguage)
        XCTAssertEqual(bootstrap.formatLabel, "JSONC")
        XCTAssertFalse(bootstrap.shouldHighlight)
        XCTAssertEqual(bootstrap.highlightState, .unsupportedFormat)
        XCTAssertEqual(bootstrap.content, content)
    }

    func testBootstrapKeepsHighlightingAtExactCodeThreshold() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("boundary.xml")
        let thresholdContent = String(repeating: "a", count: 524_288)
        try thresholdContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let bootstrap = await LocalDocumentPanelRuntime.bootstrap(
            for: WebPanelState(
                definition: .localDocument,
                title: "boundary.xml",
                localDocument: LocalDocumentState(
                    filePath: fileURL.path,
                    format: .xml
                )
            )
        )

        XCTAssertEqual(bootstrap.format, .xml)
        XCTAssertTrue(bootstrap.shouldHighlight)
        XCTAssertEqual(bootstrap.highlightState, .enabled)
        XCTAssertEqual(bootstrap.content.utf8.count, 524_288)
    }

    func testBootstrapJavaScriptEmbedsJSONPayload() throws {
        let bootstrap = LocalDocumentPanelBootstrap(
            filePath: "/tmp/toastty/readme.md",
            displayName: "readme.md",
            content: "# Docs",
            contentRevision: 7,
            isEditing: true,
            isDirty: true,
            hasExternalConflict: true,
            isSaving: false,
            saveErrorMessage: "Could not save",
            theme: .dark,
            textScale: 1.3
        )

        let script = try XCTUnwrap(LocalDocumentPanelRuntime.bootstrapJavaScript(for: bootstrap))

        XCTAssertTrue(script.contains("window.ToasttyLocalDocumentPanel?.receiveBootstrap("))
        XCTAssertTrue(script.contains("\"contractVersion\":6"))
        XCTAssertTrue(script.contains("\"displayName\":\"readme.md\""))
        XCTAssertTrue(script.contains("\"format\":\"markdown\""))
        XCTAssertTrue(script.contains("\"formatLabel\":\"Markdown\""))
        XCTAssertTrue(script.contains("\"shouldHighlight\":true"))
        XCTAssertTrue(script.contains("\"highlightState\":\"enabled\""))
        XCTAssertTrue(script.contains("\"content\":\"# Docs\""))
        XCTAssertTrue(script.contains("\"contentRevision\":7"))
        XCTAssertTrue(script.contains("\"isEditing\":true"))
        XCTAssertTrue(script.contains("\"isDirty\":true"))
        XCTAssertTrue(script.contains("\"hasExternalConflict\":true"))
        XCTAssertTrue(script.contains("\"saveErrorMessage\":\"Could not save\""))
        XCTAssertTrue(script.contains("\"theme\":\"dark\""))
        XCTAssertTrue(script.contains("\"textScale\":1.3"))
    }

    func testThemeResolvesFromEffectiveAppearance() {
        XCTAssertEqual(LocalDocumentPanelRuntime.theme(for: NSAppearance(named: .darkAqua)), .dark)
        XCTAssertEqual(LocalDocumentPanelRuntime.theme(for: NSAppearance(named: .aqua)), .light)
        XCTAssertEqual(LocalDocumentPanelRuntime.theme(for: nil), .dark)
    }

    func testShouldApplyWebViewAppearanceSkipsSameNamedAppearance() {
        XCTAssertFalse(
            LocalDocumentPanelRuntime.shouldApplyWebViewAppearance(
                current: NSAppearance(named: .aqua),
                next: NSAppearance(named: .aqua)
            )
        )
    }

    func testShouldApplyWebViewAppearanceAllowsMeaningfulAppearanceChanges() {
        XCTAssertTrue(
            LocalDocumentPanelRuntime.shouldApplyWebViewAppearance(
                current: NSAppearance(named: .darkAqua),
                next: NSAppearance(named: .aqua)
            )
        )
        XCTAssertTrue(
            LocalDocumentPanelRuntime.shouldApplyWebViewAppearance(
                current: nil,
                next: NSAppearance(named: .aqua)
            )
        )
        XCTAssertTrue(
            LocalDocumentPanelRuntime.shouldApplyWebViewAppearance(
                current: NSAppearance(named: .aqua),
                next: nil
            )
        )
        XCTAssertFalse(
            LocalDocumentPanelRuntime.shouldApplyWebViewAppearance(
                current: nil,
                next: nil
            )
        )
    }

    func testApplyUsesCurrentEffectiveAppearanceThemeForBootstrap() async throws {
        let bootstrapRecorder = BootstrapRecorder()
        let metadataExpectation = expectation(description: "Initial metadata update arrives")

        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await bootstrapRecorder.recordCall()
                return LocalDocumentPanelDocumentSnapshot(
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

        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await bootstrapRecorder.recordCall()
                return LocalDocumentPanelDocumentSnapshot(
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

    func testApplyTextScaleDoesNotReReadMarkdownContent() async throws {
        let bootstrapRecorder = BootstrapRecorder()
        let metadataExpectation = expectation(description: "Initial metadata update arrives")

        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await bootstrapRecorder.recordCall()
                return LocalDocumentPanelDocumentSnapshot(
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

        runtime.applyTextScale(1.2)
        try await Task.sleep(nanoseconds: 100_000_000)

        let bootstrapCallCount = await bootstrapRecorder.snapshot()
        XCTAssertEqual(bootstrapCallCount, 1)
        XCTAssertEqual(runtime.automationState().currentBootstrap?.textScale, 1.2)
    }

    func testAppearanceChangePreservesCurrentTextScale() async throws {
        let metadataExpectation = expectation(description: "Initial metadata update arrives")

        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                LocalDocumentPanelDocumentSnapshot(
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
        runtime.applyTextScale(1.3)
        runtime.applyEffectiveAppearance(NSAppearance(named: .aqua))
        try await Task.sleep(nanoseconds: 100_000_000)

        let bootstrap = try XCTUnwrap(runtime.automationState().currentBootstrap)
        XCTAssertEqual(bootstrap.theme, .light)
        XCTAssertEqual(bootstrap.textScale, 1.3)
    }

    func testApplyTextScaleClampsToConfiguredBounds() async throws {
        let metadataExpectation = expectation(description: "Initial metadata update arrives")

        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                LocalDocumentPanelDocumentSnapshot(
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

        runtime.applyTextScale(0)
        let minimumScale = try XCTUnwrap(runtime.automationState().currentBootstrap?.textScale)
        XCTAssertEqual(
            minimumScale,
            AppState.minMarkdownTextScale,
            accuracy: 0.0001
        )

        runtime.applyTextScale(10)
        let maximumScale = try XCTUnwrap(runtime.automationState().currentBootstrap?.textScale)
        XCTAssertEqual(
            maximumScale,
            AppState.maxMarkdownTextScale,
            accuracy: 0.0001
        )
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

        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataCallCount += 1
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await bootstrapRecorder.recordCall()
                return await LocalDocumentPanelRuntime.loadDocument(for: webState)
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

        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataCallCount += 1
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await bootstrapRecorder.recordCall()
                return await LocalDocumentPanelRuntime.loadDocument(for: webState)
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
        XCTAssertTrue(deletedBootstrap.content.contains("Toastty could not load this document."))
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

        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataCallCount += 1
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                await bootstrapRecorder.recordCall()
                return await LocalDocumentPanelRuntime.loadDocument(for: webState)
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

private actor LockedBox<Value: Sendable> {
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ value: Value) {
        self.value = value
    }

    func snapshot() -> Value {
        value
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
