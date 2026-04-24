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

    func testLaterFlagActionTitleUsesLaterCopy() {
        XCTAssertEqual(SidebarView.laterFlagActionTitle(isFlaggedForLater: false), "Flag for Later")
        XCTAssertEqual(SidebarView.laterFlagActionTitle(isFlaggedForLater: true), "Clear Later Flag")
    }

    func testUnreadSessionTypographyUsesEmphasizedWeights() {
        XCTAssertEqual(SidebarView.sessionAgentFontWeight(showsUnreadSessionAccent: false), .medium)
        XCTAssertEqual(SidebarView.sessionAgentFontWeight(showsUnreadSessionAccent: true), .heavy)
        XCTAssertEqual(SidebarView.sessionBodyFontWeight(showsUnreadSessionAccent: false), .regular)
        XCTAssertEqual(SidebarView.sessionBodyFontWeight(showsUnreadSessionAccent: true), .bold)
    }

    func testWorkingSessionTextUsesItalicOnlyWhileWorking() {
        XCTAssertTrue(SidebarView.sessionTextUsesItalic(for: .working))
        XCTAssertFalse(SidebarView.sessionTextUsesItalic(for: .idle))
        XCTAssertFalse(SidebarView.sessionTextUsesItalic(for: .needsApproval))
        XCTAssertFalse(SidebarView.sessionTextUsesItalic(for: .ready))
        XCTAssertFalse(SidebarView.sessionTextUsesItalic(for: .error))
    }

    func testWorkingSessionDetailTextRendersDistinctItalicGlyphs() throws {
        let normalBitmap = try renderedBitmap(
            for: SidebarView.styledSessionDetailText(
                "Inspecting compile issues",
                statusKind: .idle,
                showsUnreadSessionAccent: false
            )
        )
        let workingBitmap = try renderedBitmap(
            for: SidebarView.styledSessionDetailText(
                "Inspecting compile issues",
                statusKind: .working,
                showsUnreadSessionAccent: false
            )
        )

        XCTAssertGreaterThan(try differingPixelCount(between: normalBitmap, and: workingBitmap), 0)
    }

    func testWorkingSessionAgentTextRendersDistinctItalicGlyphs() throws {
        let normalBitmap = try renderedBitmap(
            for: SidebarView.styledSessionAgentText(
                "Codex",
                statusKind: .idle,
                showsUnreadSessionAccent: false
            )
        )
        let workingBitmap = try renderedBitmap(
            for: SidebarView.styledSessionAgentText(
                "Codex",
                statusKind: .working,
                showsUnreadSessionAccent: false
            )
        )

        XCTAssertGreaterThan(try differingPixelCount(between: normalBitmap, and: workingBitmap), 0)
    }

    func testSessionAgentTextUsesConfiguredSidebarFontSize() throws {
        let styledBitmap = try renderedBitmap(
            for: SidebarView.styledSessionAgentText(
                "Codex",
                statusKind: .idle,
                showsUnreadSessionAccent: false
            )
        )
        let expectedBitmap = try renderedBitmap(
            for: Text("Codex").font(Font.system(size: 11, weight: .medium, design: .monospaced))
        )

        XCTAssertEqual(try differingPixelCount(between: styledBitmap, and: expectedBitmap), 0)
    }

    func testSessionDetailTextUsesConfiguredSidebarFontSize() throws {
        let styledBitmap = try renderedBitmap(
            for: SidebarView.styledSessionDetailText(
                "Inspecting compile issues",
                statusKind: .idle,
                showsUnreadSessionAccent: false
            )
        )
        let expectedBitmap = try renderedBitmap(
            for: Text("Inspecting compile issues").font(Font.system(size: 11, weight: .regular, design: .default))
        )

        XCTAssertEqual(try differingPixelCount(between: styledBitmap, and: expectedBitmap), 0)
    }

    func testSessionChipTextUsesConfiguredSidebarFontSize() throws {
        let styledBitmap = try renderedBitmap(
            for: Text("ready").font(ToastyTheme.fontWorkspaceSessionChip)
        )
        let expectedBitmap = try renderedBitmap(
            for: Text("ready").font(Font.system(size: 10, weight: .medium, design: .default))
        )

        XCTAssertEqual(try differingPixelCount(between: styledBitmap, and: expectedBitmap), 0)
    }

    func testWorkspaceTitleUsesConfiguredSidebarFontSize() throws {
        let styledBitmap = try renderedBitmap(
            for: Text("Workspace 1").font(ToastyTheme.fontWorkspaceName)
        )
        let expectedBitmap = try renderedBitmap(
            for: Text("Workspace 1").font(Font.system(size: 13, weight: .semibold, design: .default))
        )

        XCTAssertEqual(try differingPixelCount(between: styledBitmap, and: expectedBitmap), 0)
    }

    func testInactiveWorkspaceTitleUsesConfiguredSidebarFontSize() throws {
        let styledBitmap = try renderedBitmap(
            for: Text("Workspace 1").font(ToastyTheme.fontWorkspaceNameInactive)
        )
        let expectedBitmap = try renderedBitmap(
            for: Text("Workspace 1").font(Font.system(size: 13, weight: .medium, design: .default))
        )

        XCTAssertEqual(try differingPixelCount(between: styledBitmap, and: expectedBitmap), 0)
    }

    func testWorkspaceRenameFontsMatchSidebarTitleFonts() {
        XCTAssertEqual(
            ToastyTheme.sidebarWorkspaceNameNSFont(isSelected: true),
            NSFont.systemFont(ofSize: 13, weight: .semibold)
        )
        XCTAssertEqual(
            ToastyTheme.sidebarWorkspaceNameNSFont(isSelected: false),
            NSFont.systemFont(ofSize: 13, weight: .medium)
        )
    }

    func testWorkspaceReorderTargetIndexHandlesBeforeFirstBoundary() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let targetIndex = SidebarView.workspaceReorderTargetIndex(
            orderedWorkspaceIDs: [first, second, third],
            measuredHeaderFramesByID: [
                first: CGRect(x: 0, y: 0, width: 260, height: 42),
                second: CGRect(x: 0, y: 42, width: 260, height: 42),
                third: CGRect(x: 0, y: 84, width: 260, height: 42),
            ],
            draggedWorkspaceID: second,
            pointerY: -8
        )

        XCTAssertEqual(targetIndex, 0)
    }

    func testWorkspaceReorderTargetIndexHandlesAfterLastBoundary() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let targetIndex = SidebarView.workspaceReorderTargetIndex(
            orderedWorkspaceIDs: [first, second, third],
            measuredHeaderFramesByID: [
                first: CGRect(x: 0, y: 0, width: 260, height: 42),
                second: CGRect(x: 0, y: 42, width: 260, height: 42),
                third: CGRect(x: 0, y: 84, width: 260, height: 42),
            ],
            draggedWorkspaceID: second,
            pointerY: 150
        )

        XCTAssertEqual(targetIndex, 2)
    }

    func testWorkspaceReorderTargetIndexTreatsSelfDropAsNoOpIndex() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let targetIndex = SidebarView.workspaceReorderTargetIndex(
            orderedWorkspaceIDs: [first, second, third],
            measuredHeaderFramesByID: [
                first: CGRect(x: 0, y: 0, width: 260, height: 42),
                second: CGRect(x: 0, y: 42, width: 260, height: 42),
                third: CGRect(x: 0, y: 84, width: 260, height: 42),
            ],
            draggedWorkspaceID: second,
            pointerY: 60
        )

        XCTAssertEqual(targetIndex, 1)
    }

    func testWorkspaceReorderTargetIndexReturnsNilWhenHeaderFramesAreMissing() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let targetIndex = SidebarView.workspaceReorderTargetIndex(
            orderedWorkspaceIDs: [first, second, third],
            measuredHeaderFramesByID: [
                first: CGRect(x: 0, y: 0, width: 260, height: 42),
                second: CGRect(x: 0, y: 42, width: 260, height: 42),
            ],
            draggedWorkspaceID: second,
            pointerY: 120
        )

        XCTAssertNil(targetIndex)
    }

    func testWorkspaceDragActivationUsesVerticalThreshold() {
        XCTAssertFalse(
            SidebarView.workspaceDragActivationExceeded(translation: CGSize(width: 30, height: 3.9))
        )
        XCTAssertTrue(
            SidebarView.workspaceDragActivationExceeded(translation: CGSize(width: 0, height: 4))
        )
        XCTAssertTrue(
            SidebarView.workspaceDragActivationExceeded(translation: CGSize(width: 0, height: -4))
        )
    }

    func testWorkspaceTapToleranceUsesTotalPointerDistance() {
        XCTAssertTrue(
            SidebarView.pointerMovementWithinTapTolerance(translation: CGSize(width: 2, height: 2))
        )
        XCTAssertFalse(
            SidebarView.pointerMovementWithinTapTolerance(translation: CGSize(width: 4, height: 0))
        )
        XCTAssertFalse(
            SidebarView.pointerMovementWithinTapTolerance(translation: CGSize(width: 3, height: 3))
        )
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

    func testProcessWatchRowUsesDisplayTitleOverride() throws {
        let hostingView = try makeSidebarHostingView(
            sessionID: "watcher-row",
            agent: .processWatch,
            sessionStatus: SessionStatus(kind: .working, summary: "Working", detail: "Running"),
            displayTitleOverride: "bundle exec rspec"
        )

        let textValues = renderedTextValues(in: hostingView)
        XCTAssertTrue(textValues.contains(where: { $0.contains("bundle exec rspec") }))
        XCTAssertFalse(textValues.contains("Process Watch"))
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
    }

    func testSelectingLowWorkspaceRequestsSidebarScrollToRevealIt() throws {
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
        var scrollRequests: [(workspaceID: UUID, animated: Bool)] = []
        let sidebarView = SidebarView(
            windowID: windowID,
            store: store,
            terminalRuntimeRegistry: registry,
            sessionRuntimeStore: sessionRuntimeStore,
            terminalRuntimeContext: runtimeContext,
            scrollRequestObserver: { workspaceID, animated in
                scrollRequests.append((workspaceID, animated))
            }
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

        XCTAssertEqual(scrollRequests.last?.workspaceID, workspaces.first?.id)
        XCTAssertEqual(scrollRequests.last?.animated, false)
        scrollRequests.removeAll()

        _ = store.send(.selectWorkspace(windowID: windowID, workspaceID: try XCTUnwrap(workspaces.last?.id)))
        pumpMainRunLoop(duration: 0.3)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(scrollRequests.count, 1)
        XCTAssertEqual(scrollRequests.last?.workspaceID, workspaces.last?.id)
        XCTAssertEqual(scrollRequests.last?.animated, true)
    }

    func testWorkspaceHeaderPaddingClickSelectsWorkspace() throws {
        let workspaces = (1...2).map { WorkspaceState.bootstrap(title: "Workspace \($0)") }
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: ToastyTheme.sidebarWidth, height: 220),
                    workspaceIDs: workspaces.map(\.id),
                    selectedWorkspaceID: workspaces[0].id
                )
            ],
            workspacesByID: Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) }),
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        let runtimeContext = TerminalWindowRuntimeContext(windowID: windowID, runtimeRegistry: registry)
        var headerFramesByID: [UUID: CGRect] = [:]
        let sidebarView = SidebarView(
            windowID: windowID,
            store: store,
            terminalRuntimeRegistry: registry,
            sessionRuntimeStore: sessionRuntimeStore,
            terminalRuntimeContext: runtimeContext,
            workspaceHeaderFrameObserver: { headerFramesByID = $0 }
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
        defer { window.orderOut(nil) }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        pumpMainRunLoop()
        hostingView.layoutSubtreeIfNeeded()
        pumpMainRunLoop()

        let secondWorkspaceFrame = try XCTUnwrap(headerFramesByID[workspaces[1].id])
        let clickPointInHost = NSPoint(
            x: secondWorkspaceFrame.midX,
            y: ToastyTheme.sidebarTopPadding + secondWorkspaceFrame.minY + 6
        )
        let clickPointInWindow = hostingView.convert(clickPointInHost, to: nil)

        XCTAssertGreaterThan(secondWorkspaceFrame.height, 30)
        XCTAssertTrue(hostingView.bounds.contains(clickPointInHost))

        try click(window: window, at: clickPointInWindow)
        pumpMainRunLoop(duration: 0.2)

        XCTAssertEqual(
            store.selectedWorkspaceID(in: windowID),
            workspaces[1].id,
            "Expected click at \(clickPointInWindow) to select frame \(secondWorkspaceFrame)"
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
        agent: AgentKind = .codex,
        sessionStatus: SessionStatus,
        displayTitleOverride: String? = nil,
        sessionPanelPlacement: SessionPanelPlacement = .focused
    ) throws -> NSView {
        try makeSidebarHarness(
            sessionID: sessionID,
            agent: agent,
            sessionStatus: sessionStatus,
            displayTitleOverride: displayTitleOverride,
            sessionPanelPlacement: sessionPanelPlacement
        ).hostingView
    }

    private func makeSidebarHarness(
        sessionID: String,
        agent: AgentKind = .codex,
        sessionStatus: SessionStatus,
        displayTitleOverride: String? = nil,
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
            agent: agent,
            panelID: panelID,
            windowID: windowID,
            workspaceID: workspaceID,
            displayTitleOverride: displayTitleOverride,
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

    private func renderedBitmap(
        for text: Text,
        width: CGFloat = 320,
        height: CGFloat = 60
    ) throws -> NSBitmapImageRep {
        let hostingView = NSHostingView(
            rootView: ZStack(alignment: .topLeading) {
                Color.white
                text
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: width, height: height)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        pumpMainRunLoop()
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try renderedBitmap(for: hostingView)
        window.orderOut(nil)
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

    private func click(
        window: NSWindow,
        at location: NSPoint,
        clickCount: Int = 1
    ) throws {
        guard let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ) else {
            throw NSError(domain: "SidebarViewTests", code: 1, userInfo: nil)
        }
        guard let mouseUp = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: 0.05,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: clickCount,
            pressure: 0
        ) else {
            throw NSError(domain: "SidebarViewTests", code: 2, userInfo: nil)
        }

        window.sendEvent(mouseDown)
        window.sendEvent(mouseUp)
    }

    private func renderedTextValues(in rootView: NSView) -> [String] {
        let subviewValues = recursiveSubviewTextValues(in: rootView)
        let accessibilityRoot = (NSAccessibility.unignoredDescendant(of: rootView) as? AnyObject) ?? rootView
        let accessibilityValues = recursiveAccessibilityTextValues(
            in: accessibilityRoot,
            visitedObjects: []
        )
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

    private func recursiveAccessibilityTextValues(
        in object: AnyObject,
        visitedObjects: Set<ObjectIdentifier>
    ) -> [String] {
        let identifier = ObjectIdentifier(object)
        guard visitedObjects.contains(identifier) == false else {
            return []
        }

        var visitedObjects = visitedObjects
        visitedObjects.insert(identifier)
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

        var children: [AnyObject] = []

        for selectorName in ["accessibilityChildrenInNavigationOrder", "accessibilityChildren"] {
            let selector = NSSelectorFromString(selectorName)
            guard object.responds(to: selector),
                  let result = object.perform(selector)?.takeUnretainedValue() else {
                continue
            }

            if let typedChildren = result as? [AnyObject], typedChildren.isEmpty == false {
                children = typedChildren
                break
            }
        }

        let unignoredChildren = NSAccessibility.unignoredChildren(from: children).compactMap { $0 as? AnyObject }
        for child in unignoredChildren {
            values.append(
                contentsOf: recursiveAccessibilityTextValues(
                    in: child,
                    visitedObjects: visitedObjects
                )
            )
        }

        return values
    }

}
