import CoreState
import Foundation
import Testing
@testable import ToasttyAppLogic

/// macOS builds `BrowserAnnotationTestImage` with AppKit in
/// Tests/App/BrowserAnnotationTests.swift (not mirrored); the shared
/// BrowserAnnotationModelTests use this one on Linux.
enum BrowserAnnotationTestImage {
    static func pngData(width: Int, height: Int) -> Data {
        LinuxBitmap(width: width, height: height, rgba: [UInt8](repeating: 255, count: width * height * 4)).pngData()
    }
}

/// A browser host with a fixed viewport, scroll offset and screenshot.
@MainActor
final class FakeAnnotationBrowserHost: LinuxBrowserPanelHost {
    var viewportSize = CGSize(width: 800, height: 600)
    var scrollOffset = CGPoint(x: 0, y: 0)
    var pageZoom: Double = 1
    var currentURLString: String? = "https://example.com/page"
    var currentTitle: String? = "Example Page"
    var screenshotCount = 0
    var failScreenshots = false

    func focus() -> Bool { true }
    func load(urlString: String) -> Bool { currentURLString = urlString; return true }
    func goBack() -> Bool { false }
    func goForward() -> Bool { false }
    func reloadOrStop() -> Bool { true }
    func reload(urlString: String) -> Bool { true }
    func synchronize(webState: WebPanelState) {}
    func focusLocationField() {}
    var isInWindow: Bool { true }
    var canGoBack: Bool { false }
    var canGoForward: Bool { false }
    var isLoading: Bool { false }
    var faviconPNG: Data? { nil }

    func captureScreenshotPNG() async throws -> Data {
        screenshotCount += 1
        if failScreenshots { throw LinuxWebPanelError.invalidImage }
        return BrowserAnnotationTestImage.pngData(width: Int(viewportSize.width), height: Int(viewportSize.height))
    }

    func pageScrollOffset() async -> CGPoint? { scrollOffset }
}

@MainActor
@Suite(.serialized)
struct LinuxBrowserAnnotationControllerTests {
    @MainActor
    final class Harness {
        let runtime: BrowserPanelRuntime
        let host = FakeAnnotationBrowserHost()
        let controller: LinuxWebPanelAnnotationController
        var candidates: [BrowserScreenshotSendCandidate] = []
        var availability: BrowserAnnotationSendAvailability = .available
        var sent: [(payload: String, sessionID: String)] = []
        var sendSucceeds = true

        init() {
            runtime = BrowserPanelRuntime(
                panelID: UUID(),
                metadataDidChange: { _, _, _ in },
                interactionDidRequestFocus: { _ in },
                responderDidRequestFocus: { _ in },
                openSecondaryURL: { _, _ in false }
            )
            runtime.attach(host: host)
            var harness: Harness?
            controller = LinuxWebPanelAnnotationController(
                runtime: runtime,
                dependencies: .init(
                    candidates: { harness?.candidates ?? [] },
                    availability: { _ in harness?.availability ?? .blocked(reason: "unavailable") },
                    sendPayload: { payload, candidate in
                        guard let harness, harness.sendSucceeds else { return false }
                        harness.sent.append((payload, candidate.sessionID))
                        return true
                    }
                )
            )
            controller.overlaySize = CGSize(width: 800, height: 600)
            // The closures hold the harness (a test-lifetime cycle).
            harness = self
        }

        func idle() async throws {
            try await LinuxTestSupport.waitUntil("annotation idle") { controller.isBusy == false }
            // Deferred session observation.
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        func annotate(at start: CGPoint, to end: CGPoint? = nil, comment: String) async throws {
            #expect(controller.pointerPressed(at: start))
            if let end { controller.pointerDragged(to: end) }
            controller.pointerReleased(at: end ?? start)
            controller.popoverTextChanged(comment)
            controller.savePopover(text: comment)
            try await idle()
        }
    }

    @Test func clickOpensCreatePopoverAndSaveRecordsAPoint() async throws {
        let h = Harness()
        h.controller.setAnnotationModeEnabled(true)
        try await h.idle()
        #expect(h.controller.isAnnotationModeEnabled)

        #expect(h.controller.pointerPressed(at: CGPoint(x: 200, y: 150)))
        h.controller.pointerReleased(at: CGPoint(x: 200, y: 150))
        let popover = try #require(h.controller.popover)
        #expect(popover.purpose == .create)
        #expect(popover.number == 1)
        #expect(h.controller.pendingMark?.shape == .point(center: CGPoint(x: 200, y: 150)))
        #expect(h.controller.isEditorActive)
        #expect(h.controller.isSendDisabled)

        // Empty comments are not saved.
        h.controller.savePopover(text: "   ")
        #expect(h.controller.popover != nil)

        h.controller.savePopover(text: "  Make this bigger \n")
        try await h.idle()
        #expect(h.controller.popover == nil)
        #expect(h.controller.pendingMark == nil)
        #expect(h.controller.draftCount == 1)
        #expect(h.controller.annotationSummaries.map(\.comment) == ["Make this bigger"])
        let item = try #require(h.runtime.annotationState.sections.first?.annotations.first)
        #expect(item.kind == .point(CGPoint(x: 0.25, y: 0.25)))
        let section = try #require(h.runtime.annotationState.sections.first)
        #expect(section.url == "https://example.com/page")
        #expect(section.title == "Example Page")
        #expect(section.viewportSize == CGSize(width: 800, height: 600))
        #expect(h.controller.marks.map(\.number) == [1])
        #expect(h.controller.isSendDisabled == false)
    }

    @Test func dragRecordsANormalizedRectangleWithItsBadgeOnTheCorner() async throws {
        let h = Harness()
        h.controller.setAnnotationModeEnabled(true)
        try await h.idle()
        #expect(h.controller.pointerPressed(at: CGPoint(x: 600, y: 450)))
        h.controller.pointerDragged(to: CGPoint(x: 400, y: 300))
        #expect(h.controller.inProgressRectangle == CGRect(x: 400, y: 300, width: 200, height: 150))
        h.controller.pointerDragged(to: CGPoint(x: 200, y: 150))
        h.controller.pointerReleased(at: CGPoint(x: 200, y: 150))
        #expect(h.controller.inProgressRectangle == nil)
        h.controller.savePopover(text: "Region")
        try await h.idle()
        let item = try #require(h.runtime.annotationState.sections.first?.annotations.first)
        #expect(item.kind == .rectangle(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)))
        let mark = try #require(h.controller.marks.first)
        #expect(mark.shape == .rectangle(CGRect(x: 200, y: 150, width: 400, height: 300)))
        #expect(mark.bubbleRect.midX == 200 && mark.bubbleRect.midY == 150)
    }

    @Test func clickAwayCommitsTypedTextAndCancelsEmptyEditors() async throws {
        let h = Harness()
        h.controller.setAnnotationModeEnabled(true)
        try await h.idle()

        h.controller.pointerPressed(at: CGPoint(x: 100, y: 100))
        h.controller.pointerReleased(at: CGPoint(x: 100, y: 100))
        h.controller.popoverDismissedByOutsideClick()
        try await h.idle()
        #expect(h.controller.popover == nil)
        #expect(h.controller.pendingMark == nil)
        #expect(h.controller.draftCount == 0)

        h.controller.pointerPressed(at: CGPoint(x: 100, y: 100))
        h.controller.pointerReleased(at: CGPoint(x: 100, y: 100))
        h.controller.popoverTextChanged("Typed then clicked away")
        // A click on the overlay while the popover is open resolves it and
        // does not start a new annotation.
        #expect(h.controller.pointerPressed(at: CGPoint(x: 500, y: 500)))
        try await h.idle()
        #expect(h.controller.annotationSummaries.map(\.comment) == ["Typed then clicked away"])
        #expect(h.controller.inProgressRectangle == nil)
    }

    @Test func detailPopoverEditsAndDeletesWithRenumbering() async throws {
        let h = Harness()
        h.controller.setAnnotationModeEnabled(true)
        try await h.idle()
        try await h.annotate(at: CGPoint(x: 100, y: 100), comment: "First")
        try await h.annotate(at: CGPoint(x: 400, y: 300), comment: "Second")
        #expect(h.controller.annotationSummaries.map(\.number) == [1, 2])

        // Hover and click the first bubble.
        h.controller.pointerMoved(to: CGPoint(x: 101, y: 99))
        #expect(h.controller.marks.first?.isHovered == true)
        #expect(h.controller.isOverMark(CGPoint(x: 101, y: 99)))
        #expect(h.controller.pointerPressed(at: CGPoint(x: 101, y: 99)))
        let detail = try #require(h.controller.popover)
        #expect(detail.purpose == .view(annotationID: try #require(h.controller.marks.first?.annotationID)))
        #expect(detail.comment == "First")
        #expect(detail.isEditing == false)

        h.controller.editFromDetailPopover()
        let edit = try #require(h.controller.popover)
        #expect(edit.isEditing)
        #expect(edit.comment == "First")
        h.controller.savePopover(text: "First, edited")
        #expect(h.controller.annotationSummaries.map(\.comment) == ["First, edited", "Second"])

        h.controller.pointerPressed(at: CGPoint(x: 100, y: 100))
        h.controller.deletePopoverAnnotation()
        #expect(h.controller.popover == nil)
        #expect(h.controller.annotationSummaries.map(\.number) == [1])
        #expect(h.controller.annotationSummaries.map(\.comment) == ["Second"])
    }

    @Test func escapeCancelsDragThenPopoverThenLeavesTheMode() async throws {
        let h = Harness()
        h.controller.setAnnotationModeEnabled(true)
        try await h.idle()
        h.controller.pointerPressed(at: CGPoint(x: 10, y: 10))
        h.controller.pointerDragged(to: CGPoint(x: 90, y: 90))
        #expect(h.controller.escapePressed())
        #expect(h.controller.inProgressRectangle == nil)
        #expect(h.controller.popover == nil)

        h.controller.pointerPressed(at: CGPoint(x: 10, y: 10))
        h.controller.pointerReleased(at: CGPoint(x: 10, y: 10))
        #expect(h.controller.popover != nil)
        #expect(h.controller.escapePressed())
        #expect(h.controller.popover == nil)
        #expect(h.controller.pendingMark == nil)
        #expect(h.controller.isAnnotationModeEnabled)

        #expect(h.controller.escapePressed())
        #expect(h.controller.isAnnotationModeEnabled == false)
        #expect(h.controller.escapePressed() == false)
    }

    @Test func scrollingMovesMarksAndIsFrozenWhileComposing() async throws {
        let h = Harness()
        h.controller.setAnnotationModeEnabled(true)
        try await h.idle()
        try await h.annotate(at: CGPoint(x: 400, y: 300), comment: "Center")
        #expect(h.controller.marks.first?.bubbleRect.midY == 300)

        #expect(h.controller.shouldScrollPage(deltaX: 0, deltaY: 100))
        #expect(h.controller.marks.first?.bubbleRect.midY == 200)
        h.host.scrollOffset = CGPoint(x: 0, y: 120)
        h.controller.pageDidScroll()
        try await h.idle()
        #expect(h.controller.marks.first?.bubbleRect.midY == 180)

        h.controller.pointerPressed(at: CGPoint(x: 50, y: 50))
        h.controller.pointerReleased(at: CGPoint(x: 50, y: 50))
        #expect(h.controller.shouldScrollPage(deltaX: 0, deltaY: 100) == false)
        h.controller.cancelPopover()
        // A second capture at the new offset is a separate section.
        try await h.annotate(at: CGPoint(x: 400, y: 300), comment: "Lower")
        #expect(h.runtime.annotationState.sections.count == 2)
        #expect(h.runtime.annotationState.sections.last?.scrollOffset == CGPoint(x: 0, y: 120))
    }

    @Test func pageChangesClearDraftsButLoadingDoesNot() async throws {
        let h = Harness()
        h.runtime.hostDidCommitNavigation(urlString: "https://example.com/page")
        h.controller.setAnnotationModeEnabled(true)
        try await h.idle()
        try await h.annotate(at: CGPoint(x: 100, y: 100), comment: "Keep")

        h.runtime.handleObservedURLChange("https://example.com/other", isPageLoading: true)
        #expect(h.controller.draftCount == 1)
        h.runtime.handleObservedURLChange("https://example.com/page#section")
        try await h.idle()
        #expect(h.controller.draftCount == 0)
        #expect(h.controller.isAnnotationModeEnabled == false)

        h.controller.setAnnotationModeEnabled(true)
        try await h.idle()
        try await h.annotate(at: CGPoint(x: 100, y: 100), comment: "Again")
        h.runtime.hostDidCommitNavigation(urlString: "https://example.com/next")
        try await h.idle()
        #expect(h.controller.draftCount == 0)
    }

    @Test func captureFailureDiscardsTheDraftWithANotice() async throws {
        let h = Harness()
        h.host.failScreenshots = true
        h.controller.setAnnotationModeEnabled(true)
        try await h.idle()
        try await h.annotate(at: CGPoint(x: 100, y: 100), comment: "Lost")
        #expect(h.controller.draftCount == 0)
        #expect(h.controller.notice?.message == "Couldn't capture the page — annotation discarded")
        #expect(h.controller.notice?.isFailure == true)
    }

    @Test func sendRendersScreenshotsAndHandsThePayloadToTheAgent() async throws {
        let h = Harness()
        var rendered: [LinuxAnnotationRenderRequest] = []
        LinuxAppLogic.installAnnotationScreenshotRenderer { request in
            MainActor.assumeIsolated { rendered.append(request) }
            return request.pngData
        }
        defer { LinuxAppLogic.installAnnotationScreenshotRenderer(nil) }
        h.candidates = [BrowserScreenshotSendCandidate(sessionID: "s1", agent: .claude, panelID: UUID(), label: "Claude Code")]
        h.controller.setAnnotationModeEnabled(true)
        try await h.idle()
        try await h.annotate(at: CGPoint(x: 200, y: 150), comment: "Fix the header")
        try await h.annotate(at: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200), comment: "Line one\nline two")

        #expect(h.controller.sendCandidates == [
            LinuxAnnotationSendCandidate(sessionID: "s1", panelID: h.candidates[0].panelID, label: "Claude Code", blockedReason: nil),
        ])
        #expect(h.controller.send(toSessionID: "s1"))
        #expect(h.controller.send(toSessionID: "missing") == false)
        try await LinuxTestSupport.waitUntil("send finished") { h.controller.isSendInFlight == false && h.sent.count == 1 }
        try await h.idle()

        let payload = try #require(h.sent.first?.payload)
        #expect(payload.hasPrefix("Browser annotation feedback from Toastty."))
        #expect(payload.contains("Page: Example Page"))
        #expect(payload.contains("URL: https://example.com/page"))
        #expect(payload.contains("1. Fix the header"))
        #expect(payload.contains("2. Line one\n   line two"))
        #expect(rendered.count == 1)
        #expect(rendered.first?.marks == [
            .init(number: 1, kind: .point(CGPoint(x: 0.25, y: 0.25))),
            .init(number: 2, kind: .rectangle(CGRect(x: 0.125, y: 1.0 / 6.0, width: 0.25, height: 1.0 / 6.0))),
        ])
        let path = try #require(h.controller.lastSentScreenshotPaths.first)
        #expect(path.contains("toastty-browser-annotations"))
        #expect(FileManager.default.fileExists(atPath: path))
        try? FileManager.default.removeItem(atPath: path)
        #expect(h.controller.lastSentSessionID == "s1")
        #expect(h.controller.draftCount == 0)
        #expect(h.controller.isAnnotationModeEnabled == false)
        #expect(h.controller.notice?.message == "Sent 2 annotations to Claude Code")
    }

    @Test func blockedOrFailingSendsKeepDraftsAndExplainWhy() async throws {
        let h = Harness()
        LinuxAppLogic.installAnnotationScreenshotRenderer { $0.pngData }
        defer { LinuxAppLogic.installAnnotationScreenshotRenderer(nil) }
        h.candidates = [BrowserScreenshotSendCandidate(sessionID: "s1", agent: .codex, panelID: UUID(), label: "Codex")]
        h.availability = .blocked(reason: "awaiting approval")
        h.controller.setAnnotationModeEnabled(true)
        try await h.idle()
        try await h.annotate(at: CGPoint(x: 200, y: 150), comment: "Pending")
        #expect(h.controller.sendCandidates.first?.blockedReason == "awaiting approval")
        h.controller.send(toSessionID: "s1")
        try await h.idle()
        #expect(h.sent.isEmpty)
        #expect(h.controller.draftCount == 1)
        #expect(h.controller.notice?.message == "Codex is awaiting approval — can't send right now")

        h.availability = .available
        h.sendSucceeds = false
        h.controller.send(toSessionID: "s1")
        try await LinuxTestSupport.waitUntil("send finished") { h.controller.isSendInFlight == false }
        try await h.idle()
        #expect(h.controller.draftCount == 1)
        #expect(h.controller.notice?.message == "Couldn't send annotations to Codex")
        #expect(h.controller.lastSentPayload == nil)
    }

    @Test func sendWithoutARendererFails() async throws {
        let h = Harness()
        LinuxAppLogic.installAnnotationScreenshotRenderer(nil)
        h.candidates = [BrowserScreenshotSendCandidate(sessionID: "s1", agent: .claude, panelID: UUID(), label: "Claude Code")]
        h.controller.setAnnotationModeEnabled(true)
        try await h.idle()
        try await h.annotate(at: CGPoint(x: 200, y: 150), comment: "No renderer")
        h.controller.send(toSessionID: "s1")
        try await LinuxTestSupport.waitUntil("send finished") { h.controller.isSendInFlight == false }
        try await h.idle()
        #expect(h.sent.isEmpty)
        #expect(h.controller.notice?.message == "Couldn't send annotations")
        #expect(h.controller.draftCount == 1)
    }

    @Test func screenshotWriterAndShimDecodeLinuxPNGs() throws {
        let png = BrowserAnnotationTestImage.pngData(width: 4, height: 3)
        let image = try #require(NSImage(pngData: png, size: CGSize(width: 4, height: 3)))
        #expect(try BrowserPanelScreenshotWriter.pngData(from: image) == png)
        #expect(NSBitmapImageRep(data: Data("not a png".utf8)) == nil)
        let request = BrowserAnnotatedScreenshotRenderer.renderRequest(for: BrowserAnnotationSection(
            id: UUID(), pngData: png, url: nil, title: nil, scrollOffset: .zero,
            viewportSize: CGSize(width: 2, height: 3), capturedAt: Date(),
            annotations: [BrowserAnnotationItem(id: UUID(), sequenceNumber: 3, kind: .point(.zero), comment: "x", createdAt: Date())]
        ))
        #expect(request.marks == [.init(number: 3, kind: .point(.zero))])
        #expect(request.markScale(imagePixelWidth: 4) == 2)
        #expect(throws: BrowserAnnotatedScreenshotRendererError.invalidPNGData) {
            LinuxAppLogic.installAnnotationScreenshotRenderer { $0.pngData }
            defer { LinuxAppLogic.installAnnotationScreenshotRenderer(nil) }
            _ = try BrowserAnnotatedScreenshotRenderer.render(section: BrowserAnnotationSection(
                id: UUID(), pngData: Data("x".utf8), url: nil, title: nil, scrollOffset: .zero,
                viewportSize: CGSize(width: 2, height: 3), capturedAt: Date(), annotations: []
            ))
        }
    }
}

/// The facade wiring (`LinuxAppLogic.browserAnnotationController`): send
/// candidates come from managed sessions in the browser's workspace tab, the
/// payload is typed into that agent's terminal and submitted, and the agent
/// panel takes focus — macOS `WorkspaceView.sendBrowserAnnotationPayload`.
@MainActor
@Suite(.serialized)
struct LinuxBrowserAnnotationFacadeTests {
    @Test func annotationsReachTheAgentTerminalThroughTheTerminalRegistry() async throws {
        let cli = try LinuxTestSupport.productPath("toastty")
        let shim = try LinuxTestSupport.productPath("toastty-agent-shim")
        let root = try LinuxTestSupport.makeTemporaryDirectory("tba")
        let environment = LinuxTestSupport.ScopedEnvironment()
        environment.set("TOASTTY_AUTOMATION", "1")
        environment.set("TOASTTY_RUN_ID", "linux-annotations")
        environment.set("TOASTTY_ARTIFACTS_DIR", root.appendingPathComponent("artifacts").path)
        environment.set("TOASTTY_SOCKET_PATH", root.appendingPathComponent("s.sock").path)
        let logic = LinuxAppLogic(options: LinuxAppLogic.Options(
            cliExecutablePath: cli, agentShimExecutablePath: shim, allowsRemoteAccess: false, runsBackgroundMaintenance: false
        ))
        LinuxAppLogic.installAnnotationScreenshotRenderer { $0.pngData }
        defer {
            LinuxAppLogic.installAnnotationScreenshotRenderer(nil)
            logic.shutdown(reason: "test_teardown")
            environment.restore()
            try? FileManager.default.removeItem(at: root)
        }

        let workspace = try #require(logic.store.selectedWorkspace)
        let terminalPanelID = try #require(workspace.focusedPanelID)
        let surface = RecordingTerminalSurface()
        logic.attachTerminalSurface(surface, panelID: terminalPanelID)
        logic.terminalSurfaceDidLaunch(panelID: terminalPanelID)
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(logic.send(.createWebPanel(
            workspaceID: workspace.id,
            panel: WebPanelState(definition: .browser, initialURL: "https://example.com/page"),
            placement: .rightPanel
        )))
        let browserPanelID = try #require(logic.state.workspacesByID[workspace.id]?.rightAuxPanel.orderedTabs.first?.panelID)
        let host = FakeAnnotationBrowserHost()
        logic.attachBrowserHost(host, panelID: browserPanelID)
        let controller = logic.browserAnnotationController(panelID: browserPanelID)
        #expect(logic.browserAnnotationController(panelID: browserPanelID) === controller)
        controller.overlaySize = host.viewportSize
        #expect(controller.sendCandidates.isEmpty)

        logic.sessionRuntimeStore.startSession(
            sessionID: "annotation-agent", agent: .claude, panelID: terminalPanelID,
            windowID: try #require(logic.state.windows.first?.id), workspaceID: workspace.id,
            codexStatusTrackingSource: .externallyReported, cwd: nil, repoRoot: nil, at: Date()
        )
        let candidate = try #require(controller.sendCandidates.first)
        #expect(candidate.sessionID == "annotation-agent")
        #expect(candidate.panelID == terminalPanelID)

        controller.setAnnotationModeEnabled(true)
        try await LinuxTestSupport.waitUntil("annotation idle") { controller.isBusy == false }
        controller.pointerPressed(at: CGPoint(x: 200, y: 150))
        controller.pointerReleased(at: CGPoint(x: 200, y: 150))
        controller.savePopover(text: "Tighten this spacing")
        try await LinuxTestSupport.waitUntil("draft saved") { controller.draftCount == 1 }

        logic.sessionRuntimeStore.updateStatus(
            sessionID: "annotation-agent", status: SessionStatus(kind: .ready, summary: "Ready"), at: Date()
        )
        #expect(controller.sendCandidates.first?.blockedReason == nil)
        #expect(controller.send(toSessionID: "annotation-agent"))
        try await LinuxTestSupport.waitUntil("payload typed") { surface.typed.isEmpty == false }
        let typed = surface.typed.joined()
        #expect(typed.contains("Browser annotation feedback from Toastty."))
        #expect(typed.contains("1. Tighten this spacing"))
        #expect(surface.returnCount >= 1)
        try await LinuxTestSupport.waitUntil("agent panel focused") {
            logic.store.selectedWorkspace?.focusedPanelID == terminalPanelID
        }
        for path in controller.lastSentScreenshotPaths { try? FileManager.default.removeItem(atPath: path) }
    }
}
