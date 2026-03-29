@testable import ToasttyApp
import AppKit
import CoreState
import SwiftUI
import XCTest

@MainActor
final class SidebarViewTests: XCTestCase {
    private enum SessionPanelPlacement {
        case focused
        case backgroundUnread
    }

    private struct SidebarHarness {
        let windowID: UUID
        let workspaceID: UUID
        let panelID: UUID
        let store: AppStore
        let hostingView: NSView
        let window: NSWindow
    }

    func testAbbreviatedPathLabelKeepsOnlyLastPathComponent() {
        XCTAssertEqual(SidebarView.abbreviatedPathLabel("/Users/vishal/GiantThings/repos/toastty-session-status"), ".../toastty-session-status")
        XCTAssertEqual(SidebarView.abbreviatedPathLabel("/"), "/")
        XCTAssertEqual(SidebarView.abbreviatedPathLabel("relative"), "relative")
    }

    func testSessionStatusChipKindShowsPersistentUnresolvedAndUnreadReady() {
        XCTAssertNil(
            SidebarView.sessionStatusChipKind(
                for: SessionStatus(kind: .idle, summary: "Idle"),
                showsUnreadSessionAccent: true
            )
        )
        XCTAssertNil(
            SidebarView.sessionStatusChipKind(
                for: SessionStatus(kind: .working, summary: "Working"),
                showsUnreadSessionAccent: true
            )
        )
        XCTAssertNil(
            SidebarView.sessionStatusChipKind(
                for: SessionStatus(kind: .ready, summary: "Ready"),
                showsUnreadSessionAccent: false
            )
        )
        XCTAssertEqual(
            SidebarView.sessionStatusChipKind(
                for: SessionStatus(kind: .needsApproval, summary: "Needs approval"),
                showsUnreadSessionAccent: false
            ),
            .needsApproval
        )
        XCTAssertEqual(
            SidebarView.sessionStatusChipKind(
                for: SessionStatus(kind: .ready, summary: "Ready"),
                showsUnreadSessionAccent: true
            ),
            .ready
        )
        XCTAssertEqual(
            SidebarView.sessionStatusChipKind(
                for: SessionStatus(kind: .error, summary: "Error"),
                showsUnreadSessionAccent: false
            ),
            .error
        )
    }

    func testSessionIndicatorStateShowsSpinnerOnlyForWorking() {
        XCTAssertEqual(SidebarView.sessionIndicatorState(for: .working), .spinner)
        XCTAssertEqual(SidebarView.sessionIndicatorState(for: .idle), .hidden)
        XCTAssertEqual(SidebarView.sessionIndicatorState(for: .needsApproval), .hidden)
        XCTAssertEqual(SidebarView.sessionIndicatorState(for: .ready), .hidden)
        XCTAssertEqual(SidebarView.sessionIndicatorState(for: .error), .hidden)
    }

    func testUnreadSessionTypographyUsesEmphasizedWeights() {
        XCTAssertEqual(SidebarView.sessionAgentFontWeight(showsUnreadSessionAccent: false), .medium)
        XCTAssertEqual(SidebarView.sessionAgentFontWeight(showsUnreadSessionAccent: true), .heavy)
        XCTAssertEqual(SidebarView.sessionBodyFontWeight(showsUnreadSessionAccent: false), .regular)
        XCTAssertEqual(SidebarView.sessionBodyFontWeight(showsUnreadSessionAccent: true), .bold)
    }

    func testWorkingSessionDetailUsesItalicOnlyWhileWorking() {
        XCTAssertTrue(SidebarView.sessionDetailUsesItalic(for: .working))
        XCTAssertFalse(SidebarView.sessionDetailUsesItalic(for: .idle))
        XCTAssertFalse(SidebarView.sessionDetailUsesItalic(for: .needsApproval))
        XCTAssertFalse(SidebarView.sessionDetailUsesItalic(for: .ready))
        XCTAssertFalse(SidebarView.sessionDetailUsesItalic(for: .error))
    }

    func testBackgroundTabSessionPanelRemainsFocusable() throws {
        let backgroundTab = WorkspaceTabState.bootstrap(terminalTitle: "Background Agent")
        let selectedTab = WorkspaceTabState.bootstrap(terminalTitle: "Foreground Terminal")
        let panelID = try XCTUnwrap(backgroundTab.focusedPanelID)
        let workspace = WorkspaceState(
            id: UUID(),
            title: "One",
            selectedTabID: selectedTab.id,
            tabIDs: [backgroundTab.id, selectedTab.id],
            tabsByID: [
                backgroundTab.id: backgroundTab,
                selectedTab.id: selectedTab,
            ]
        )

        XCTAssertTrue(SidebarView.canFocusSessionPanel(panelID, in: workspace))
    }

    func testUnreadSessionAccentUsesPanelTabUnreadStateAcrossTabs() throws {
        var backgroundTab = WorkspaceTabState.bootstrap(terminalTitle: "Background Agent")
        let selectedTab = WorkspaceTabState.bootstrap(terminalTitle: "Foreground Terminal")
        let backgroundPanelID = try XCTUnwrap(backgroundTab.focusedPanelID)
        let selectedPanelID = try XCTUnwrap(selectedTab.focusedPanelID)
        backgroundTab.unreadPanelIDs = [backgroundPanelID]
        let workspaceID = UUID()
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "One",
            selectedTabID: selectedTab.id,
            tabIDs: [backgroundTab.id, selectedTab.id],
            tabsByID: [
                backgroundTab.id: backgroundTab,
                selectedTab.id: selectedTab,
            ]
        )

        XCTAssertTrue(
            SidebarView.showsUnreadSessionAccent(
                for: backgroundPanelID,
                in: workspace,
                selectedWorkspaceID: workspaceID,
                selectedPanelID: selectedPanelID
            )
        )
    }

    func testUnreadSessionAccentSuppressesFocusedPanelInSelectedWorkspace() throws {
        var selectedTab = WorkspaceTabState.bootstrap(terminalTitle: "Foreground Terminal")
        let selectedPanelID = try XCTUnwrap(selectedTab.focusedPanelID)
        selectedTab.unreadPanelIDs = [selectedPanelID]
        let workspaceID = UUID()
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "One",
            selectedTabID: selectedTab.id,
            tabIDs: [selectedTab.id],
            tabsByID: [selectedTab.id: selectedTab]
        )

        XCTAssertFalse(
            SidebarView.showsUnreadSessionAccent(
                for: selectedPanelID,
                in: workspace,
                selectedWorkspaceID: workspaceID,
                selectedPanelID: selectedPanelID
            )
        )
    }

    func testReadySessionDoesNotRenderStatusChipLabelAfterItIsRead() throws {
        let hostingView = try makeSidebarHostingView(
            sessionID: "sess-ready",
            sessionStatus: SessionStatus(kind: .ready, summary: "Ready", detail: "Completed response")
        )

        let textValues = renderedTextValues(in: hostingView)
        XCTAssertFalse(
            textValues.contains("ready"),
            "Sidebar text values should not include a ready chip label: \(textValues)"
        )
        XCTAssertTrue(
            textValues.contains(where: { $0.contains("Completed response") }),
            "Sidebar text values should preserve the last ready detail after the chip disappears: \(textValues)"
        )
    }

    func testIdleSessionWithDetailStillRendersDescription() throws {
        let hostingView = try makeSidebarHostingView(
            sessionID: "sess-idle-detail",
            sessionStatus: SessionStatus(kind: .idle, summary: "Waiting", detail: "Completed response")
        )

        let textValues = renderedTextValues(in: hostingView)
        XCTAssertTrue(
            textValues.contains(where: { $0.contains("Completed response") }),
            "Sidebar text values should include idle detail text when present: \(textValues)"
        )
    }

    func testUnreadReadySessionRendersStatusChipLabel() throws {
        let hostingView = try makeSidebarHostingView(
            sessionID: "sess-ready-unread",
            sessionStatus: SessionStatus(kind: .ready, summary: "Ready", detail: "Completed response"),
            sessionPanelPlacement: .backgroundUnread
        )

        let textValues = renderedTextValues(in: hostingView)
        XCTAssertTrue(
            textValues.contains(where: { $0.localizedCaseInsensitiveContains("ready") }),
            "Sidebar text values should include a ready chip label for unread ready rows: \(textValues)"
        )
    }

    func testNeedsApprovalAndErrorSessionsRenderStatusChipLabels() throws {
        let approvalTextValues = renderedTextValues(
            in: try makeSidebarHostingView(
                sessionID: "sess-approval",
                sessionStatus: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Review command")
            )
        )
        XCTAssertTrue(approvalTextValues.contains(where: { $0.localizedCaseInsensitiveContains("needs approval") }))

        let errorTextValues = renderedTextValues(
            in: try makeSidebarHostingView(
                sessionID: "sess-error",
                sessionStatus: SessionStatus(kind: .error, summary: "Error", detail: "Command failed")
            )
        )
        XCTAssertTrue(errorTextValues.contains(where: { $0.localizedCaseInsensitiveContains("error") }))
    }

    func testWorkingSessionDoesNotRenderStatusChipLabel() throws {
        let hostingView = try makeSidebarHostingView(
            sessionID: "sess-working",
            sessionStatus: SessionStatus(kind: .working, summary: "Working", detail: "Streaming changes")
        )

        let textValues = renderedTextValues(in: hostingView)
        XCTAssertFalse(
            textValues.contains("working"),
            "Sidebar text values should not include a working chip label: \(textValues)"
        )
        XCTAssertFalse(textValues.contains("ready"))
        XCTAssertFalse(textValues.contains("needs approval"))
        XCTAssertFalse(textValues.contains("error"))
    }

    func testSidebarUnreadBackgroundUsesReadyGreenTint() throws {
        let unreadColor = try XCTUnwrap(
            NSColor(ToastyTheme.sidebarSessionUnreadBackground).usingColorSpace(.deviceRGB)
        )
        let readyColor = try XCTUnwrap(
            NSColor(ToastyTheme.sessionReadyText).usingColorSpace(.deviceRGB)
        )

        XCTAssertEqual(unreadColor.redComponent, readyColor.redComponent, accuracy: 0.001)
        XCTAssertEqual(unreadColor.greenComponent, readyColor.greenComponent, accuracy: 0.001)
        XCTAssertEqual(unreadColor.blueComponent, readyColor.blueComponent, accuracy: 0.001)
        XCTAssertGreaterThan(unreadColor.alphaComponent, 0.2)
    }

    func testAttentionStatusChipColorsAreDistinct() throws {
        let readyColor = try XCTUnwrap(
            NSColor(ToastyTheme.sessionReadyText).usingColorSpace(.deviceRGB)
        )
        let approvalColor = try XCTUnwrap(
            NSColor(ToastyTheme.sessionNeedsApprovalText).usingColorSpace(.deviceRGB)
        )
        let errorColor = try XCTUnwrap(
            NSColor(ToastyTheme.sessionErrorText).usingColorSpace(.deviceRGB)
        )

        XCTAssertNotEqual(approvalColor.redComponent, readyColor.redComponent, accuracy: 0.001)
        XCTAssertNotEqual(errorColor.redComponent, readyColor.redComponent, accuracy: 0.001)
    }

    func testWorkspaceSubtitleIsHidden() throws {
        let state = AppState.bootstrap()
        let windowID = try XCTUnwrap(state.windows.first?.id)
        let workspaceID = try XCTUnwrap(state.windows.first?.workspaceIDs.first)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        let runtimeContext = TerminalWindowRuntimeContext(windowID: windowID, runtimeRegistry: registry)
        let sidebarView = SidebarView(
            windowID: windowID,
            store: store,
            terminalRuntimeRegistry: registry,
            sessionRuntimeStore: sessionRuntimeStore,
            terminalRuntimeContext: runtimeContext
        )
        let hostingView = NSHostingView(rootView: sidebarView.frame(width: ToastyTheme.sidebarWidth))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: ToastyTheme.sidebarWidth, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()

        // Subtitle should not appear even without activity
        XCTAssertFalse(
            renderedTextValues(in: hostingView).contains(where: { $0.contains("pane") })
        )

        // Subtitle should remain hidden even after runtime activity updates
        registry.setWorkspaceActivitySubtext([workspaceID: "1 busy"])
        pumpMainRunLoop()
        hostingView.layoutSubtreeIfNeeded()

        let textValues = renderedTextValues(in: hostingView)
        XCTAssertFalse(
            textValues.contains(where: { $0.contains("pane") }),
            "Workspace subtitle should be hidden but found: \(textValues)"
        )
    }

    func testSelectingLowWorkspaceScrollsSidebarToRevealIt() throws {
        let workspaces = (1...12).map { WorkspaceState.bootstrap(title: "Workspace \($0)") }
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: ToastyTheme.sidebarWidth, height: 220),
                    workspaceIDs: workspaces.map(\.id),
                    selectedWorkspaceID: workspaces.first?.id
                )
            ],
            workspacesByID: Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) }),
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        let runtimeContext = TerminalWindowRuntimeContext(windowID: windowID, runtimeRegistry: registry)
        let sidebarView = SidebarView(
            windowID: windowID,
            store: store,
            terminalRuntimeRegistry: registry,
            sessionRuntimeStore: sessionRuntimeStore,
            terminalRuntimeContext: runtimeContext
        )
        let hostingView = NSHostingView(
            rootView: sidebarView.frame(width: ToastyTheme.sidebarWidth, height: 220)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: ToastyTheme.sidebarWidth, height: 220),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        pumpMainRunLoop()
        hostingView.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(findSubview(ofType: NSScrollView.self, in: hostingView))
        let initialOffset = scrollView.contentView.bounds.origin.y

        _ = store.send(.selectWorkspace(windowID: windowID, workspaceID: try XCTUnwrap(workspaces.last?.id)))
        pumpMainRunLoop(duration: 0.3)
        hostingView.layoutSubtreeIfNeeded()

        let scrolledOffset = scrollView.contentView.bounds.origin.y
        XCTAssertGreaterThan(
            scrolledOffset,
            initialOffset + 20,
            "Expected sidebar selection to scroll the list when the selected workspace starts off-screen"
        )
    }

    func testPendingSidebarFlashRequestPulsesAndClearsSelectedSessionRow() throws {
        let harness = try makeSidebarHarness(
            sessionID: "sess-flash",
            sessionStatus: SessionStatus(
                kind: .error,
                summary: "Blocked",
                detail: "No more active panels"
            )
        )
        let baselineBitmap = try renderedBitmap(for: harness.hostingView)

        harness.store.pendingSidebarSessionFlashRequest = PendingSidebarSessionFlashRequest(
            requestID: UUID(),
            windowID: harness.windowID,
            workspaceID: harness.workspaceID,
            panelID: harness.panelID
        )
        pumpMainRunLoop(duration: 0.12)
        harness.hostingView.layoutSubtreeIfNeeded()
        let peakBitmap = try renderedBitmap(for: harness.hostingView)

        pumpMainRunLoop(duration: 0.5)
        harness.hostingView.layoutSubtreeIfNeeded()
        let settledBitmap = try renderedBitmap(for: harness.hostingView)

        XCTAssertNil(harness.store.pendingSidebarSessionFlashRequest)
        XCTAssertGreaterThan(
            try differingPixelCount(between: baselineBitmap, and: peakBitmap),
            0,
            "Expected the selected session row to visibly pulse when no further active panels exist"
        )
        XCTAssertEqual(
            try differingPixelCount(between: baselineBitmap, and: settledBitmap),
            0,
            "Expected the sidebar pulse to settle back to its baseline appearance"
        )

        harness.window.orderOut(nil)
    }

    func testPendingSidebarFlashRequestPulsesSelectedWorkspaceRowWhenNoSessionRowIsVisible() throws {
        let harness = try makeSidebarHarnessWithoutSessionRow()
        let baselineBitmap = try renderedBitmap(for: harness.hostingView)

        harness.store.pendingSidebarSessionFlashRequest = PendingSidebarSessionFlashRequest(
            requestID: UUID(),
            windowID: harness.windowID,
            workspaceID: harness.workspaceID,
            panelID: harness.panelID
        )
        pumpMainRunLoop(duration: 0.12)
        harness.hostingView.layoutSubtreeIfNeeded()
        let peakBitmap = try renderedBitmap(for: harness.hostingView)

        pumpMainRunLoop(duration: 0.5)
        harness.hostingView.layoutSubtreeIfNeeded()
        let settledBitmap = try renderedBitmap(for: harness.hostingView)

        XCTAssertNil(harness.store.pendingSidebarSessionFlashRequest)
        XCTAssertGreaterThan(
            try differingPixelCount(between: baselineBitmap, and: peakBitmap),
            0,
            "Expected the selected workspace row to visibly pulse when no session row is visible"
        )
        XCTAssertEqual(
            try differingPixelCount(between: baselineBitmap, and: settledBitmap),
            0,
            "Expected the workspace-row pulse to settle back to its baseline appearance"
        )

        harness.window.orderOut(nil)
    }

    func testPendingSidebarFlashRequestPulsesSelectedWorkspaceRowWithoutFocusedPanelID() throws {
        let harness = try makeSidebarHarnessWithoutSessionRow()
        let baselineBitmap = try renderedBitmap(for: harness.hostingView)

        harness.store.pendingSidebarSessionFlashRequest = PendingSidebarSessionFlashRequest(
            requestID: UUID(),
            windowID: harness.windowID,
            workspaceID: harness.workspaceID,
            panelID: nil
        )
        pumpMainRunLoop(duration: 0.12)
        harness.hostingView.layoutSubtreeIfNeeded()
        let peakBitmap = try renderedBitmap(for: harness.hostingView)

        pumpMainRunLoop(duration: 0.5)
        harness.hostingView.layoutSubtreeIfNeeded()
        let settledBitmap = try renderedBitmap(for: harness.hostingView)

        XCTAssertNil(harness.store.pendingSidebarSessionFlashRequest)
        XCTAssertGreaterThan(
            try differingPixelCount(between: baselineBitmap, and: peakBitmap),
            0,
            "Expected the selected workspace row to visibly pulse when the flash request has no panel target"
        )
        XCTAssertEqual(
            try differingPixelCount(between: baselineBitmap, and: settledBitmap),
            0,
            "Expected the workspace-row pulse to settle back to its baseline appearance"
        )

        harness.window.orderOut(nil)
    }

    private func pumpMainRunLoop(duration: TimeInterval = 0) {
        let expectation = expectation(description: "Flush SwiftUI update")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        guard duration > 0 else { return }
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }

    private func makeSidebarHostingView(
        sessionID: String,
        sessionStatus: SessionStatus,
        sessionPanelPlacement: SessionPanelPlacement = .focused
    ) throws -> NSView {
        try makeSidebarHarness(
            sessionID: sessionID,
            sessionStatus: sessionStatus,
            sessionPanelPlacement: sessionPanelPlacement
        ).hostingView
    }

    private func makeSidebarHarness(
        sessionID: String,
        sessionStatus: SessionStatus,
        sessionPanelPlacement: SessionPanelPlacement = .focused
    ) throws -> SidebarHarness {
        let harnessState = makeSidebarAppState(for: sessionPanelPlacement)
        let state = harnessState.state
        let windowID = harnessState.windowID
        let workspaceID = harnessState.workspaceID
        let panelID = harnessState.sessionPanelID
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        let runtimeContext = TerminalWindowRuntimeContext(windowID: windowID, runtimeRegistry: registry)
        if sessionPanelPlacement == .backgroundUnread {
            sessionRuntimeStore.bind(store: store)
        }
        sessionRuntimeStore.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: panelID,
            windowID: windowID,
            workspaceID: workspaceID,
            cwd: "/repo/sidebar",
            repoRoot: "/repo",
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        sessionRuntimeStore.updateStatus(
            sessionID: sessionID,
            status: sessionStatus,
            at: Date(timeIntervalSince1970: 1_700_000_001)
        )

        let sidebarView = SidebarView(
            windowID: windowID,
            store: store,
            terminalRuntimeRegistry: registry,
            sessionRuntimeStore: sessionRuntimeStore,
            terminalRuntimeContext: runtimeContext
        )
        let hostingView = NSHostingView(rootView: sidebarView.frame(width: ToastyTheme.sidebarWidth))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: ToastyTheme.sidebarWidth, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        pumpMainRunLoop()
        hostingView.layoutSubtreeIfNeeded()
        return SidebarHarness(
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID,
            store: store,
            hostingView: hostingView,
            window: window
        )
    }

    private func makeSidebarHarnessWithoutSessionRow() throws -> SidebarHarness {
        let harnessState = makeSidebarAppState(for: .focused)
        let state = harnessState.state
        let windowID = harnessState.windowID
        let workspaceID = harnessState.workspaceID
        let panelID = harnessState.sessionPanelID
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        let runtimeContext = TerminalWindowRuntimeContext(windowID: windowID, runtimeRegistry: registry)

        let sidebarView = SidebarView(
            windowID: windowID,
            store: store,
            terminalRuntimeRegistry: registry,
            sessionRuntimeStore: sessionRuntimeStore,
            terminalRuntimeContext: runtimeContext
        )
        let hostingView = NSHostingView(rootView: sidebarView.frame(width: ToastyTheme.sidebarWidth))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: ToastyTheme.sidebarWidth, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        pumpMainRunLoop()
        hostingView.layoutSubtreeIfNeeded()
        return SidebarHarness(
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID,
            store: store,
            hostingView: hostingView,
            window: window
        )
    }

    private func makeSidebarAppState(
        for sessionPanelPlacement: SessionPanelPlacement
    ) -> (state: AppState, windowID: UUID, workspaceID: UUID, sessionPanelID: UUID) {
        switch sessionPanelPlacement {
        case .focused:
            let state = AppState.bootstrap()
            let windowID = state.windows[0].id
            let workspaceID = state.windows[0].workspaceIDs[0]
            let workspace = state.workspacesByID[workspaceID]!
            return (state, windowID, workspaceID, workspace.focusedPanelID!)

        case .backgroundUnread:
            let leftPanelID = UUID()
            let rightPanelID = UUID()
            let workspaceID = UUID()
            let windowID = UUID()
            let workspace = WorkspaceState(
                id: workspaceID,
                title: "Workspace 1",
                layoutTree: .split(
                    nodeID: UUID(),
                    orientation: .horizontal,
                    ratio: 0.5,
                    first: .slot(slotID: UUID(), panelID: leftPanelID),
                    second: .slot(slotID: UUID(), panelID: rightPanelID)
                ),
                panels: [
                    leftPanelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/repo")),
                    rightPanelID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/repo")),
                ],
                focusedPanelID: leftPanelID
            )
            let state = AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: ToastyTheme.sidebarWidth, height: 600),
                        workspaceIDs: [workspaceID],
                        selectedWorkspaceID: workspaceID
                    )
                ],
                workspacesByID: [workspaceID: workspace],
                selectedWindowID: windowID
            )
            return (state, windowID, workspaceID, rightPanelID)
        }
    }

    private func renderedBitmap(for view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: bitmap)
        return bitmap
    }

    private func differingPixelCount(
        between lhs: NSBitmapImageRep,
        and rhs: NSBitmapImageRep
    ) throws -> Int {
        XCTAssertEqual(lhs.pixelsWide, rhs.pixelsWide)
        XCTAssertEqual(lhs.pixelsHigh, rhs.pixelsHigh)

        let lhsData = try XCTUnwrap(lhs.bitmapData)
        let rhsData = try XCTUnwrap(rhs.bitmapData)
        let bytesPerPixel = max(1, lhs.bitsPerPixel / 8)
        let byteCount = lhs.bytesPerRow * lhs.pixelsHigh
        XCTAssertEqual(byteCount, rhs.bytesPerRow * rhs.pixelsHigh)

        var differenceCount = 0
        for pixelOffset in stride(from: 0, to: byteCount, by: bytesPerPixel) {
            for byteOffset in 0..<bytesPerPixel where lhsData[pixelOffset + byteOffset] != rhsData[pixelOffset + byteOffset] {
                differenceCount += 1
                break
            }
        }

        return differenceCount
    }

    private func renderedTextValues(in rootView: NSView) -> [String] {
        let subviewValues = recursiveSubviewTextValues(in: rootView)
        let accessibilityValues = recursiveAccessibilityTextValues(in: rootView)
        return Array(Set(subviewValues + accessibilityValues)).sorted()
    }

    private func recursiveSubviewTextValues(in view: NSView) -> [String] {
        var values: [String] = []
        if let textField = view as? NSTextField {
            let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty == false {
                values.append(trimmed)
            }
        }

        for subview in view.subviews {
            values.append(contentsOf: recursiveSubviewTextValues(in: subview))
        }

        return values
    }

    private func recursiveAccessibilityTextValues(in object: AnyObject) -> [String] {
        var values: [String] = []

        for selectorName in ["accessibilityLabel", "accessibilityValue"] {
            let selector = NSSelectorFromString(selectorName)
            guard object.responds(to: selector),
                  let result = object.perform(selector)?.takeUnretainedValue() else {
                continue
            }

            if let string = result as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty == false {
                    values.append(trimmed)
                }
            }
        }

        let childrenSelector = NSSelectorFromString("accessibilityChildren")
        if object.responds(to: childrenSelector),
           let children = object.perform(childrenSelector)?.takeUnretainedValue() as? [AnyObject] {
            for child in children {
                values.append(contentsOf: recursiveAccessibilityTextValues(in: child))
            }
        }

        return values
    }

    private func findSubview<ViewType: NSView>(
        ofType type: ViewType.Type,
        in rootView: NSView
    ) -> ViewType? {
        if let typedView = rootView as? ViewType {
            return typedView
        }

        for subview in rootView.subviews {
            if let match = findSubview(ofType: type, in: subview) {
                return match
            }
        }

        return nil
    }
}
