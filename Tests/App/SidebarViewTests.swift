import RemoteProtocol
@testable import ToasttyApp
import AppKit
import CoreState
import SwiftUI
import XCTest

private final class SidebarLayoutWidthRecorder {
    var width: CGFloat = 0
    var height: CGFloat = 0
}

private struct SidebarProposedWidthRecordingLayout: Layout {
    let proposedWidth: CGFloat
    let recorder: SidebarLayoutWidthRecorder

    func sizeThatFits(
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(
            ProposedViewSize(width: proposedWidth, height: nil)
        )
        recorder.width = size.width
        recorder.height = size.height
        return size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: recorder.width, height: bounds.height)
        )
    }
}

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
        let sessionRuntimeStore: SessionRuntimeStore
        let hostingView: NSView
        let window: NSWindow
    }

    private struct MultiSessionSidebarHarness {
        let windowID: UUID
        let workspaceID: UUID
        let panelIDs: [UUID]
        let sessionIDs: [String]
        let store: AppStore
        let sessionRuntimeStore: SessionRuntimeStore
        let hostingView: NSView
        let window: NSWindow
    }

    func testHoverTipOriginPlacesTipBelowAnchorLeftEdge() {
        let origin = HoverTipPresenter.tipOrigin(
            anchor: CGRect(x: 120, y: 500, width: 180, height: 24),
            tipSize: CGSize(width: 320, height: 100),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        XCTAssertEqual(origin, CGPoint(x: 120, y: 394))
    }

    func testHoverTipOriginFlipsAboveNearBottomEdge() {
        let origin = HoverTipPresenter.tipOrigin(
            anchor: CGRect(x: 120, y: 40, width: 180, height: 24),
            tipSize: CGSize(width: 320, height: 100),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        XCTAssertEqual(origin, CGPoint(x: 120, y: 70))
    }

    func testHoverTipOriginClampsHorizontally() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)

        let rightClampedOrigin = HoverTipPresenter.tipOrigin(
            anchor: CGRect(x: 850, y: 500, width: 120, height: 24),
            tipSize: CGSize(width: 320, height: 100),
            visibleFrame: visibleFrame
        )
        let leftClampedOrigin = HoverTipPresenter.tipOrigin(
            anchor: CGRect(x: -40, y: 500, width: 120, height: 24),
            tipSize: CGSize(width: 320, height: 100),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(rightClampedOrigin, CGPoint(x: 680, y: 394))
        XCTAssertEqual(leftClampedOrigin, CGPoint(x: 0, y: 394))
    }

    func testChildActivityDotPhaseOffsetIsStableAndBounded() {
        let first = SessionChildActivityDot.phaseOffset(forStableID: "activity:agent-1")
        let second = SessionChildActivityDot.phaseOffset(forStableID: "activity:agent-1")
        XCTAssertEqual(first, second)
        XCTAssertGreaterThanOrEqual(first, 0)
        XCTAssertLessThan(first, 2)
        XCTAssertNotEqual(
            SessionChildActivityDot.phaseOffset(forStableID: "activity:agent-1"),
            SessionChildActivityDot.phaseOffset(forStableID: "activity:agent-2")
        )
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

    func testWorkspaceNewBadgeUsesConfiguredSidebarFontSize() throws {
        let styledBitmap = try renderedBitmap(
            for: Text(SidebarSessionPresentation.workspaceNewBadgeLabel).font(ToastyTheme.fontWorkspaceNewBadge)
        )
        let expectedBitmap = try renderedBitmap(
            for: Text(SidebarSessionPresentation.workspaceNewBadgeLabel).font(Font.system(size: 10, weight: .medium, design: .default))
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

    func testUnvisitedWorkspaceTitleRendersDistinctWeightFromVisitedTitle() throws {
        let unvisitedBitmap = try renderedBitmap(
            for: SidebarView.styledWorkspaceTitleText(
                "Workspace 2",
                isSelected: false,
                hasBeenVisited: false
            )
        )
        let visitedBitmap = try renderedBitmap(
            for: SidebarView.styledWorkspaceTitleText(
                "Workspace 2",
                isSelected: false,
                hasBeenVisited: true
            )
        )

        XCTAssertGreaterThan(try differingPixelCount(between: unvisitedBitmap, and: visitedBitmap), 0)
    }

    func testInactiveUnvisitedWorkspaceRowRendersNewBadgeLabel() throws {
        let selectedWorkspace = WorkspaceState.bootstrap(title: "Workspace 1")
        let backgroundWorkspace = WorkspaceState.bootstrap(
            title: "Workspace 2",
            hasBeenVisited: false
        )
        let sidebarState = makeSidebarAppState(
            selectedWorkspace: selectedWorkspace,
            additionalWorkspaces: [backgroundWorkspace]
        )
        let hostingView = try makeSidebarHostingView(
            state: sidebarState.state,
            windowID: sidebarState.windowID
        )

        let textValues = renderedTextValues(in: hostingView)
        let workspaceRowValues = textValues.filter { $0.hasPrefix("Workspace 2") }
        XCTAssertTrue(
            workspaceRowValues.contains(where: { $0.contains(SidebarSessionPresentation.workspaceNewBadgeLabel) }),
            "Expected inactive unvisited workspace row to expose the New badge label: \(textValues)"
        )
    }

    func testVisitedInactiveWorkspaceRowDoesNotRenderNewBadgeLabel() throws {
        let selectedWorkspace = WorkspaceState.bootstrap(title: "Workspace 1")
        let backgroundWorkspace = WorkspaceState.bootstrap(
            title: "Workspace 2",
            hasBeenVisited: true
        )
        let sidebarState = makeSidebarAppState(
            selectedWorkspace: selectedWorkspace,
            additionalWorkspaces: [backgroundWorkspace]
        )
        let hostingView = try makeSidebarHostingView(
            state: sidebarState.state,
            windowID: sidebarState.windowID
        )

        let textValues = renderedTextValues(in: hostingView)
        let workspaceRowValues = textValues.filter { $0.hasPrefix("Workspace 2") }
        XCTAssertFalse(
            workspaceRowValues.contains(where: { $0.contains(SidebarSessionPresentation.workspaceNewBadgeLabel) }),
            "Did not expect a New badge for visited workspace rows: \(textValues)"
        )
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
            measuredRowFramesByID: [
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
            measuredRowFramesByID: [
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
            measuredRowFramesByID: [
                first: CGRect(x: 0, y: 0, width: 260, height: 42),
                second: CGRect(x: 0, y: 42, width: 260, height: 42),
                third: CGRect(x: 0, y: 84, width: 260, height: 42),
            ],
            draggedWorkspaceID: second,
            pointerY: 60
        )

        XCTAssertEqual(targetIndex, 1)
    }

    func testWorkspaceReorderTargetIndexReturnsNilWhenRowFramesAreMissing() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let targetIndex = SidebarView.workspaceReorderTargetIndex(
            orderedWorkspaceIDs: [first, second, third],
            measuredRowFramesByID: [
                first: CGRect(x: 0, y: 0, width: 260, height: 42),
                second: CGRect(x: 0, y: 42, width: 260, height: 42),
            ],
            draggedWorkspaceID: second,
            pointerY: 120
        )

        XCTAssertNil(targetIndex)
    }

    func testWorkspaceReorderTargetIndexUsesFullWorkspaceRowHeight() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let targetIndex = SidebarView.workspaceReorderTargetIndex(
            orderedWorkspaceIDs: [first, second, third],
            measuredRowFramesByID: [
                first: CGRect(x: 0, y: 0, width: 260, height: 42),
                second: CGRect(x: 0, y: 42, width: 260, height: 118),
                third: CGRect(x: 0, y: 160, width: 260, height: 42),
            ],
            draggedWorkspaceID: first,
            pointerY: 90
        )

        XCTAssertEqual(targetIndex, 0)
    }

    func testWorkspaceInsertionIndicatorFrameUsesRowHorizontalBounds() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let indicatorFrame = SidebarView.workspaceInsertionIndicatorFrame(
            orderedWorkspaceIDs: [first, second, third],
            measuredRowFramesByID: [
                first: CGRect(x: 8, y: 0, width: 244, height: 42),
                second: CGRect(x: 8, y: 42, width: 244, height: 42),
                third: CGRect(x: 8, y: 84, width: 244, height: 42),
            ],
            draggedWorkspaceID: second,
            targetIndex: 0
        )

        XCTAssertEqual(indicatorFrame, CGRect(x: 8, y: 0, width: 244, height: 2))
    }

    func testWorkspaceInsertionIndicatorFrameUsesAfterLastBoundary() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let indicatorFrame = SidebarView.workspaceInsertionIndicatorFrame(
            orderedWorkspaceIDs: [first, second, third],
            measuredRowFramesByID: [
                first: CGRect(x: 8, y: 0, width: 244, height: 42),
                second: CGRect(x: 8, y: 42, width: 244, height: 42),
                third: CGRect(x: 8, y: 84, width: 244, height: 42),
            ],
            draggedWorkspaceID: second,
            targetIndex: 2
        )

        XCTAssertEqual(indicatorFrame, CGRect(x: 8, y: 126, width: 244, height: 2))
    }

    func testWorkspaceInsertionIndicatorFrameUsesTallRowBottom() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let indicatorFrame = SidebarView.workspaceInsertionIndicatorFrame(
            orderedWorkspaceIDs: [first, second, third],
            measuredRowFramesByID: [
                first: CGRect(x: 8, y: 0, width: 244, height: 42),
                second: CGRect(x: 8, y: 42, width: 244, height: 118),
                third: CGRect(x: 8, y: 160, width: 244, height: 42),
            ],
            draggedWorkspaceID: first,
            targetIndex: 1
        )

        XCTAssertEqual(indicatorFrame, CGRect(x: 8, y: 160, width: 244, height: 2))
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

    func testWorkspaceScopedSessionRendersScopeCountTag() throws {
        let hostingView = try makeSidebarHostingView(
            sessionID: "scoped-row",
            sessionStatus: SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready"),
            scopedWorkspaceIDs: []
        )

        let textValues = renderedTextValues(in: hostingView)
        XCTAssertTrue(
            textValues.contains("1 scope"),
            "Sidebar text values should include single-scope tag text: \(textValues)"
        )
        XCTAssertTrue(
            textValues.contains(where: { $0.localizedCaseInsensitiveContains("Scoped to: Workspace 1") }),
            "Sidebar accessibility text should describe workspace scope: \(textValues)"
        )
    }

    func testCrowdedNarrowSessionRowDropsScopeTagAndMovesScopeHelpToRowTooltip() throws {
        let hostingView = try makeSidebarHostingView(
            sessionID: "scoped-row-narrow",
            sessionStatus: SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready"),
            displayTitleOverride: "Codex sidebar compact row review",
            scopedWorkspaceIDs: [],
            sidebarWidth: CGFloat(WindowState.minSidebarWidth)
        )

        let textValues = renderedTextValues(in: hostingView)
        XCTAssertFalse(
            textValues.contains("1 scope"),
            "A header that does not fit should drop the scope tag: \(textValues)"
        )
        let tooltipValues = renderedTooltipValues(in: hostingView)
        XCTAssertTrue(
            tooltipValues.contains(where: { $0.contains("Scoped to: Workspace 1") }),
            "Row tooltip should carry the dropped scope tag's help text: \(tooltipValues)"
        )
    }

    func testCrowdedNarrowSessionRowDropsWaitingChipAndMovesStatusToRowTooltip() throws {
        let state = AppState.bootstrap()
        let windowID = try XCTUnwrap(state.windows.first?.id)
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let panelID = try XCTUnwrap(state.workspacesByID[workspaceID]?.focusedPanelID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        let runtimeContext = TerminalWindowRuntimeContext(windowID: windowID, runtimeRegistry: registry)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        sessionRuntimeStore.startSession(
            sessionID: "waiting-row-narrow",
            agent: .codex,
            panelID: panelID,
            windowID: windowID,
            workspaceID: workspaceID,
            displayTitleOverride: "Codex sidebar compact row review",
            cwd: "/repo/sidebar",
            repoRoot: "/repo",
            at: now
        )
        sessionRuntimeStore.updateStatus(
            sessionID: "waiting-row-narrow",
            status: SessionStatus(kind: .idle, summary: "Idle", detail: "Ready"),
            at: now.addingTimeInterval(1)
        )
        XCTAssertTrue(sessionRuntimeStore.updateBackgroundActivity(
            sessionID: "waiting-row-narrow",
            activity: SessionBackgroundActivity(
                id: "activity-1",
                kind: .subagent,
                displayName: "Explore",
                startedAt: now.addingTimeInterval(2),
                lastUpdatedAt: now.addingTimeInterval(2)
            ),
            at: now.addingTimeInterval(2)
        ))
        defer { sessionRuntimeStore.reset() }

        let sidebarWidth = CGFloat(WindowState.minSidebarWidth)
        let sidebarView = SidebarView(
            windowID: windowID,
            store: store,
            terminalRuntimeRegistry: registry,
            sessionRuntimeStore: sessionRuntimeStore,
            annotationStyleStore: makeTestAnnotationStyleStore(),
            terminalRuntimeContext: runtimeContext
        )
        let hostingView = NSHostingView(rootView: sidebarView.frame(width: sidebarWidth))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: sidebarWidth, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        pumpMainRunLoop()
        hostingView.layoutSubtreeIfNeeded()

        let textValues = renderedTextValues(in: hostingView)
        XCTAssertFalse(
            textValues.contains("waiting"),
            "A header that does not fit should drop the waiting chip: \(textValues)"
        )
        XCTAssertTrue(
            textValues.contains(where: { $0.contains("Codex sidebar compact row review, waiting") }),
            "Accessibility label should still report the waiting projection: \(textValues)"
        )
        let tooltipValues = renderedTooltipValues(in: hostingView)
        XCTAssertTrue(
            tooltipValues.contains(where: { $0.contains("Status: waiting") }),
            "Row tooltip should carry the dropped waiting chip's status: \(tooltipValues)"
        )
    }

    func testWorkspaceScopedSessionTooltipListsEffectiveWorkspaceNames() throws {
        let additionalWorkspaceID = UUID()
        let additionalWorkspace = makeSinglePanelWorkspace(
            id: additionalWorkspaceID,
            title: "workspace-scope-diagnostic"
        )
        let hostingView = try makeSidebarHostingView(
            sessionID: "multi-scope-row",
            sessionStatus: SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready"),
            scopedWorkspaceIDs: [additionalWorkspaceID],
            additionalWorkspaces: [additionalWorkspace],
            prependAdditionalWorkspaces: true
        )

        let textValues = renderedTextValues(in: hostingView)
        XCTAssertTrue(
            textValues.contains("2 scopes"),
            "Sidebar text values should include multi-scope tag text: \(textValues)"
        )
        XCTAssertTrue(
            textValues.contains(where: {
                $0.contains("Scoped to: Workspace 1 and workspace-scope-diagnostic")
            }),
            "Sidebar accessibility text should list effective workspace scope names: \(textValues)"
        )

        let tooltipValues = renderedTooltipValues(in: hostingView)
        XCTAssertTrue(
            tooltipValues.contains(where: {
                $0.contains("Scoped to: Workspace 1 and workspace-scope-diagnostic")
            }),
            "Sidebar scoped tag should expose a native tooltip with effective workspace names: \(tooltipValues)"
        )
    }

    func testWorkspaceScopedSessionTooltipBridgeDoesNotSwallowRowClick() throws {
        let harness = try makeSidebarHarness(
            sessionID: "scoped-click-row",
            sessionStatus: SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready"),
            scopedWorkspaceIDs: [],
            sessionPanelPlacement: .backgroundUnread
        )
        XCTAssertNotEqual(harness.store.selectedWorkspace(in: harness.windowID)?.focusedPanelID, harness.panelID)

        let tooltipView = try XCTUnwrap(
            tooltipView(
                in: harness.hostingView,
                containing: "Scoped to: Workspace 1"
            )
        )
        let clickLocation = tooltipView.convert(
            NSPoint(x: tooltipView.bounds.midX, y: tooltipView.bounds.midY),
            to: nil
        )
        try click(window: harness.window, at: clickLocation)
        pumpMainRunLoop()

        XCTAssertEqual(
            harness.store.selectedWorkspace(in: harness.windowID)?.focusedPanelID,
            harness.panelID
        )

        harness.window.orderOut(nil)
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
            annotationStyleStore: makeTestAnnotationStyleStore(),
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

    func testWorkspaceAnnotationChipsRenderAndRestyleOnColorOnlyChange() throws {
        var state = AppState.bootstrap()
        let windowID = try XCTUnwrap(state.windows.first?.id)
        let workspaceID = try XCTUnwrap(state.workspacesByID.keys.first)
        let longAnnotationText = String(repeating: "long-annotation-", count: 5)
        state.workspacesByID[workspaceID]?.annotations = [
            "pr": WorkspaceAnnotation(text: longAnnotationText, url: "https://example.com/pr/4512"),
            "env": WorkspaceAnnotation(text: "staging", url: nil),
        ]
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        let annotationStyleStore = makeTestAnnotationStyleStore()
        let runtimeContext = TerminalWindowRuntimeContext(windowID: windowID, runtimeRegistry: registry)
        let sidebarView = SidebarView(
            windowID: windowID,
            store: store,
            terminalRuntimeRegistry: registry,
            sessionRuntimeStore: sessionRuntimeStore,
            annotationStyleStore: annotationStyleStore,
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

        let renderedValues = renderedTextValues(in: hostingView)
        XCTAssertTrue(renderedValues.contains(where: { $0.contains(longAnnotationText) }))
        XCTAssertTrue(renderedValues.contains(where: { $0.contains("staging") }))
        let tooltipValues = renderedTooltipValues(in: hostingView)
        XCTAssertTrue(tooltipValues.contains(longAnnotationText))
        XCTAssertTrue(tooltipValues.contains("staging"))

        // A color-only change publishes through the observed store and swaps
        // the effective chip colors every rendered chip resolves through.
        let colorsBefore = ToastyTheme.annotationChipColors(
            for: annotationStyleStore.effectiveColorToken(forKey: "env")
        )
        var didPublish = false
        let cancellable = annotationStyleStore.objectWillChange.sink { _ in
            didPublish = true
        }
        XCTAssertTrue(try annotationStyleStore.setColor(.hex("#102030"), forKey: "env"))
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertTrue(didPublish)
        let colorsAfter = ToastyTheme.annotationChipColors(
            for: annotationStyleStore.effectiveColorToken(forKey: "env")
        )
        XCTAssertNotEqual(colorsBefore, colorsAfter)
        XCTAssertTrue(renderedTextValues(in: hostingView).contains(where: { $0.contains("staging") }))
        _ = cancellable
    }

    func testWorkspaceAnnotationChipFitsContentAndCapsLongLabels() {
        let shortWidth = measuredAnnotationChipWidth(text: "LIN-030", isLink: false)
        let linkedWidth = measuredAnnotationChipWidth(text: "LIN-030", isLink: true)
        let longWidth = measuredAnnotationChipWidth(
            text: String(repeating: "very-long-annotation-", count: 12),
            isLink: false
        )

        XCTAssertLessThan(shortWidth, 80)
        XCTAssertGreaterThan(linkedWidth, shortWidth)
        XCTAssertEqual(longWidth, 160, accuracy: 1)
    }

    func testWorkspaceAnnotationChipsRespectNarrowSidebarProposals() {
        let shortWidth = measuredAnnotationChipWidth(
            text: "LIN-030",
            isLink: false,
            proposedWidth: 40
        )
        let longWidth = measuredAnnotationChipWidth(
            text: String(repeating: "very-long-annotation-", count: 12),
            isLink: false,
            proposedWidth: 100
        )
        let singleRowSize = measuredAnnotationChipsFlowSize(
            texts: ["Bodega", "LIN-319", "PR-1931", "LIN-030"],
            proposedWidth: 400
        )
        let wrappedSize = measuredAnnotationChipsFlowSize(
            texts: ["Bodega", "LIN-319", "PR-1931", "LIN-030"],
            proposedWidth: 140
        )
        let cappedLongChipSize = measuredAnnotationChipsFlowSize(
            texts: [String(repeating: "very-long-annotation-", count: 12)],
            proposedWidth: 400
        )
        let zeroProposalSize = measuredAnnotationChipsFlowSize(
            texts: ["Bodega", "LIN-319"],
            proposedWidth: 0
        )

        XCTAssertEqual(shortWidth, 40, accuracy: 1)
        XCTAssertEqual(longWidth, 100, accuracy: 1)
        XCTAssertLessThanOrEqual(wrappedSize.width, 140)
        XCTAssertGreaterThan(wrappedSize.height, singleRowSize.height)
        XCTAssertEqual(cappedLongChipSize.width, 160, accuracy: 1)
        XCTAssertEqual(zeroProposalSize.width, 0, accuracy: 1)
        XCTAssertEqual(zeroProposalSize.height, 0, accuracy: 1)
    }

    func testWorkspaceAccessibilityLabelIncludesTextOnlyChipsAndExcludesLinkChips() {
        var workspace = WorkspaceState.bootstrap(title: "Infra")
        workspace.annotations = [
            "env": WorkspaceAnnotation(text: "staging", url: nil),
            "pr": WorkspaceAnnotation(text: "PR #4512", url: "https://example.com/pr"),
            "branch": WorkspaceAnnotation(text: "main", url: nil),
        ]

        let label = SidebarSessionPresentation.workspaceAccessibilityLabel(
            for: workspace,
            isSelected: true
        )

        XCTAssertEqual(label, "Infra, branch: main, env: staging")
    }

    func testAnnotationChipColorsDeriveReadableForegroundForDarkHex() throws {
        let namedForegrounds = AnnotationColorToken.NamedColor.allCases.map { named in
            ToastyTheme.annotationChipColors(for: .named(named)).foreground
        }
        XCTAssertEqual(Set(namedForegrounds).count, namedForegrounds.count)

        // A near-black hex must not be used verbatim as chip text on the dark
        // sidebar; the derived foreground has to be materially lighter.
        let darkChip = ToastyTheme.annotationChipColors(for: .hex("#101010"))
        let foreground = try XCTUnwrap(NSColor(darkChip.foreground).usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(foreground.redComponent, 0.3)

        // A bright hex keeps its own hue as the foreground.
        let brightChip = ToastyTheme.annotationChipColors(for: .hex("#E8A635"))
        let brightForeground = try XCTUnwrap(NSColor(brightChip.foreground).usingColorSpace(.deviceRGB))
        XCTAssertEqual(brightForeground.redComponent, Double(0xE8) / 255, accuracy: 0.01)
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
            annotationStyleStore: makeTestAnnotationStyleStore(),
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

    func testSidebarViewportHeightObserverReportsRenderedScrollHeight() throws {
        let workspaces = (1...3).map { WorkspaceState.bootstrap(title: "Workspace \($0)") }
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
        var observedViewportHeights: [CGFloat] = []
        let sidebarView = SidebarView(
            windowID: windowID,
            store: store,
            terminalRuntimeRegistry: registry,
            sessionRuntimeStore: sessionRuntimeStore,
            annotationStyleStore: makeTestAnnotationStyleStore(),
            terminalRuntimeContext: runtimeContext,
            workspaceViewportHeightObserver: { height in
                observedViewportHeights.append(height)
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
        defer { window.orderOut(nil) }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        pumpMainRunLoop()
        hostingView.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(1)
        while (observedViewportHeights.max() ?? 0) <= 100, Date() < deadline {
            pumpMainRunLoop(duration: 0.05)
            hostingView.layoutSubtreeIfNeeded()
        }

        XCTAssertGreaterThan(
            observedViewportHeights.max() ?? 0,
            100,
            "Hidden-session pills need the rendered scroll viewport height; a zero height suppresses both pills"
        )
    }

    func testLongSessionChildNameDoesNotExpandSidebarWorkspaceRows() throws {
        let state = AppState.bootstrap()
        let windowID = try XCTUnwrap(state.windows.first?.id)
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
        let panelID = try XCTUnwrap(workspace.focusedPanelID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        let runtimeContext = TerminalWindowRuntimeContext(windowID: windowID, runtimeRegistry: registry)
        let now = Date()
        let sessionID = "long-child-name-parent"

        sessionRuntimeStore.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: panelID,
            windowID: windowID,
            workspaceID: workspaceID,
            cwd: "/repo/sidebar",
            repoRoot: "/repo",
            at: now
        )
        sessionRuntimeStore.updateBackgroundActivity(
            sessionID: sessionID,
            activity: SessionBackgroundActivity(
                id: "long-child-name",
                kind: .subagent,
                displayName: "primary_object_consistency_audit_with_an_intentionally_long_name",
                startedAt: now.addingTimeInterval(-40_000),
                lastUpdatedAt: now
            ),
            at: now
        )

        defer { sessionRuntimeStore.reset() }

        let workspaceListHorizontalPadding: CGFloat = 8
        for sidebarWidth in [CGFloat(WindowState.minSidebarWidth), 291] {
            var workspaceRowFramesByID: [UUID: CGRect] = [:]
            let sidebarView = SidebarView(
                windowID: windowID,
                store: store,
                terminalRuntimeRegistry: registry,
                sessionRuntimeStore: sessionRuntimeStore,
                annotationStyleStore: makeTestAnnotationStyleStore(),
                terminalRuntimeContext: runtimeContext,
                workspaceRowFrameObserver: { workspaceRowFramesByID = $0 }
            )
            let hostingView = NSHostingView(rootView: sidebarView.frame(width: sidebarWidth))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: sidebarWidth, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostingView
            window.makeKeyAndOrderFront(nil)

            let deadline = Date().addingTimeInterval(1)
            while workspaceRowFramesByID[workspaceID] == nil, Date() < deadline {
                pumpMainRunLoop(duration: 0.05)
                hostingView.layoutSubtreeIfNeeded()
            }

            let workspaceRowFrame = try XCTUnwrap(workspaceRowFramesByID[workspaceID])
            XCTAssertGreaterThanOrEqual(
                workspaceRowFrame.minX,
                workspaceListHorizontalPadding - 0.5,
                "Expanded child rows must not shift the sidebar contents past its leading padding"
            )
            XCTAssertLessThanOrEqual(
                workspaceRowFrame.maxX,
                sidebarWidth - workspaceListHorizontalPadding + 0.5,
                "Expanded child rows must truncate within the sidebar instead of widening its contents"
            )
            window.orderOut(nil)
        }
    }

    func testNeedsApprovalSessionChildChipRemainsSingleLineAtMinimumSidebarWidth() throws {
        let readyFrame = try measuredWorkspaceRowFrame(childStatusKind: .ready)
        let approvalFrame = try measuredWorkspaceRowFrame(childStatusKind: .needsApproval)

        XCTAssertEqual(
            approvalFrame.height,
            readyFrame.height,
            accuracy: 0.5,
            "The needs-approval child chip must not make the row taller than another single-line status chip"
        )
        XCTAssertLessThanOrEqual(
            approvalFrame.maxX,
            CGFloat(WindowState.minSidebarWidth) - 8 + 0.5,
            "Protecting the approval chip width must not widen the sidebar contents"
        )
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
        var rowFramesByID: [UUID: CGRect] = [:]
        let sidebarView = SidebarView(
            windowID: windowID,
            store: store,
            terminalRuntimeRegistry: registry,
            sessionRuntimeStore: sessionRuntimeStore,
            annotationStyleStore: makeTestAnnotationStyleStore(),
            terminalRuntimeContext: runtimeContext,
            workspaceRowFrameObserver: { rowFramesByID = $0 }
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

        let secondWorkspaceFrame = try XCTUnwrap(rowFramesByID[workspaces[1].id])
        let secondWorkspacePointerView = try XCTUnwrap(
            pointerInteractionView(in: hostingView, workspaceID: workspaces[1].id)
        )
        secondWorkspacePointerView.usesEventTrackingLoop = false
        let clickPointInHeader = NSPoint(
            x: secondWorkspacePointerView.bounds.midX,
            y: 6
        )

        XCTAssertGreaterThan(secondWorkspaceFrame.height, 30)
        XCTAssertTrue(secondWorkspacePointerView.bounds.contains(clickPointInHeader))

        try click(view: secondWorkspacePointerView, at: clickPointInHeader)
        pumpMainRunLoop(duration: 0.2)

        XCTAssertEqual(
            store.selectedWorkspaceID(in: windowID),
            workspaces[1].id,
            "Expected click at \(clickPointInHeader) to select frame \(secondWorkspaceFrame)"
        )
    }

    func testDraggingFirstSessionRowAfterLastUpdatesOnlySidebarOrder() throws {
        let harness = try makeMultiSessionSidebarHarness(sessionCount: 3)
        defer { harness.window.orderOut(nil) }
        let sourceView = try sessionPointerInteractionView(
            in: harness.hostingView,
            sessionID: harness.sessionIDs[0]
        )
        let targetView = try sessionPointerInteractionView(
            in: harness.hostingView,
            sessionID: harness.sessionIDs[2]
        )
        let originalState = harness.store.state

        try drag(
            view: sourceView,
            from: NSPoint(x: sourceView.bounds.midX, y: sourceView.bounds.midY),
            to: sourceView.convert(
                NSPoint(x: targetView.bounds.midX, y: targetView.bounds.maxY - 1),
                from: targetView
            )
        )
        pumpMainRunLoop(duration: 0.2)

        let expectedOrder = [harness.panelIDs[1], harness.panelIDs[2], harness.panelIDs[0]]
        XCTAssertEqual(
            harness.store.state.workspacesByID[harness.workspaceID]?.sidebarSessionPanelOrder,
            expectedOrder
        )
        var expectedState = originalState
        expectedState.workspacesByID[harness.workspaceID]?.sidebarSessionPanelOrder = expectedOrder
        XCTAssertEqual(harness.store.state, expectedState)
    }

    func testDraggingLastSessionRowBeforeFirstUpdatesOnlySidebarOrder() throws {
        let harness = try makeMultiSessionSidebarHarness(sessionCount: 3)
        defer { harness.window.orderOut(nil) }
        let sourceView = try sessionPointerInteractionView(
            in: harness.hostingView,
            sessionID: harness.sessionIDs[2]
        )
        let targetView = try sessionPointerInteractionView(
            in: harness.hostingView,
            sessionID: harness.sessionIDs[0]
        )
        let originalState = harness.store.state

        try drag(
            view: sourceView,
            from: NSPoint(x: sourceView.bounds.midX, y: sourceView.bounds.midY),
            to: sourceView.convert(
                NSPoint(x: targetView.bounds.midX, y: targetView.bounds.minY + 1),
                from: targetView
            )
        )
        pumpMainRunLoop(duration: 0.2)

        let expectedOrder = [harness.panelIDs[2], harness.panelIDs[0], harness.panelIDs[1]]
        XCTAssertEqual(
            harness.store.state.workspacesByID[harness.workspaceID]?.sidebarSessionPanelOrder,
            expectedOrder
        )
        var expectedState = originalState
        expectedState.workspacesByID[harness.workspaceID]?.sidebarSessionPanelOrder = expectedOrder
        XCTAssertEqual(harness.store.state, expectedState)
    }

    func testClickingSessionPointerRegionFocusesPanelWithoutChangingSidebarOrder() throws {
        let harness = try makeMultiSessionSidebarHarness(sessionCount: 2)
        defer { harness.window.orderOut(nil) }
        let targetView = try sessionPointerInteractionView(
            in: harness.hostingView,
            sessionID: harness.sessionIDs[1]
        )
        targetView.usesEventTrackingLoop = false

        XCTAssertEqual(harness.store.state.workspacesByID[harness.workspaceID]?.focusedPanelID, harness.panelIDs[0])

        try click(view: targetView, at: NSPoint(x: targetView.bounds.midX, y: targetView.bounds.midY))
        pumpMainRunLoop(duration: 0.2)

        XCTAssertEqual(harness.store.state.workspacesByID[harness.workspaceID]?.focusedPanelID, harness.panelIDs[1])
        XCTAssertEqual(harness.store.state.workspacesByID[harness.workspaceID]?.sidebarSessionPanelOrder, [])
    }

    func testDraggingSessionRowBackToOriginDoesNotFocusOrReorder() throws {
        let harness = try makeMultiSessionSidebarHarness(sessionCount: 3)
        defer { harness.window.orderOut(nil) }
        let sourceView = try sessionPointerInteractionView(
            in: harness.hostingView,
            sessionID: harness.sessionIDs[1]
        )
        let start = NSPoint(x: sourceView.bounds.midX, y: sourceView.bounds.midY)

        XCTAssertEqual(harness.store.state.workspacesByID[harness.workspaceID]?.focusedPanelID, harness.panelIDs[0])

        try drag(view: sourceView, from: start, through: NSPoint(x: start.x, y: start.y + 8), to: start)
        pumpMainRunLoop(duration: 0.2)

        XCTAssertEqual(harness.store.state.workspacesByID[harness.workspaceID]?.focusedPanelID, harness.panelIDs[0])
        XCTAssertEqual(harness.store.state.workspacesByID[harness.workspaceID]?.sidebarSessionPanelOrder, [])
    }

    func testSessionDragCancelsWhenSourceSessionRestartsBeforeMouseUp() throws {
        let harness = try makeMultiSessionSidebarHarness(sessionCount: 3)
        defer { harness.window.orderOut(nil) }
        let sourceView = try sessionPointerInteractionView(
            in: harness.hostingView,
            sessionID: harness.sessionIDs[1]
        )
        let targetView = try sessionPointerInteractionView(
            in: harness.hostingView,
            sessionID: harness.sessionIDs[2]
        )
        sourceView.usesEventTrackingLoop = false
        let start = NSPoint(x: sourceView.bounds.midX, y: sourceView.bounds.midY)
        let dragPoint = sourceView.convert(
            NSPoint(x: targetView.bounds.midX, y: targetView.bounds.midY),
            from: targetView
        )

        try beginDrag(view: sourceView, at: start)
        try continueDrag(view: sourceView, at: dragPoint)
        harness.sessionRuntimeStore.stopSession(
            sessionID: harness.sessionIDs[1],
            at: Date(timeIntervalSince1970: 1_700_000_010)
        )
        harness.sessionRuntimeStore.startSession(
            sessionID: "session-row-restarted",
            agent: .codex,
            panelID: harness.panelIDs[1],
            windowID: harness.windowID,
            workspaceID: harness.workspaceID,
            displayTitleOverride: "Session Restarted",
            cwd: "/repo/sidebar",
            repoRoot: "/repo",
            at: Date(timeIntervalSince1970: 1_700_000_011)
        )
        pumpMainRunLoop(duration: 0.2)
        try endDrag(view: sourceView, at: dragPoint)
        pumpMainRunLoop(duration: 0.2)

        XCTAssertEqual(harness.store.state.workspacesByID[harness.workspaceID]?.focusedPanelID, harness.panelIDs[0])
        XCTAssertEqual(harness.store.state.workspacesByID[harness.workspaceID]?.sidebarSessionPanelOrder, [])
    }

    func testSessionDisclosureExcludedRectPassesThroughToDisclosureButton() throws {
        let harness = try makeParentChildSessionSidebarHarness()
        defer { harness.window.orderOut(nil) }
        let parentView = try sessionPointerInteractionView(
            in: harness.hostingView,
            sessionID: harness.sessionIDs[0]
        )
        parentView.usesEventTrackingLoop = false
        let siblingView = try sessionPointerInteractionView(
            in: harness.hostingView,
            sessionID: harness.sessionIDs[1]
        )
        let expandedSpacing = siblingView.convert(.zero, to: nil).y - parentView.convert(.zero, to: nil).y

        XCTAssertGreaterThan(expandedSpacing, parentView.bounds.height + 4)
        let excludedRect = try XCTUnwrap(parentView.excludedRects.first)
        let excludedPoint = NSPoint(x: excludedRect.midX, y: excludedRect.midY)
        if let superview = parentView.superview {
            XCTAssertNil(parentView.hitTest(parentView.convert(excludedPoint, to: superview)))
        }

        try click(window: harness.window, at: parentView.convert(excludedPoint, to: nil))
        pumpMainRunLoop(duration: 0.2)
        harness.hostingView.layoutSubtreeIfNeeded()
        let collapsedParentView = try sessionPointerInteractionView(
            in: harness.hostingView,
            sessionID: harness.sessionIDs[0]
        )
        let collapsedSiblingView = try sessionPointerInteractionView(
            in: harness.hostingView,
            sessionID: harness.sessionIDs[1]
        )
        let collapsedSpacing = collapsedSiblingView.convert(.zero, to: nil).y -
            collapsedParentView.convert(.zero, to: nil).y

        XCTAssertLessThan(collapsedSpacing, expandedSpacing - 4)
        XCTAssertEqual(harness.store.state.workspacesByID[harness.workspaceID]?.sidebarSessionPanelOrder, [])
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

        let settledBitmap = try waitForRenderedBitmap(
            of: harness.hostingView,
            matching: baselineBitmap
        )

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

        let settledBitmap = try waitForRenderedBitmap(
            of: harness.hostingView,
            matching: baselineBitmap
        )

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

        let settledBitmap = try waitForRenderedBitmap(
            of: harness.hostingView,
            matching: baselineBitmap
        )

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
        scopedWorkspaceIDs: Set<UUID>? = nil,
        additionalWorkspaces: [WorkspaceState] = [],
        prependAdditionalWorkspaces: Bool = false,
        sessionPanelPlacement: SessionPanelPlacement = .focused,
        sidebarWidth: CGFloat = ToastyTheme.sidebarWidth
    ) throws -> NSView {
        try makeSidebarHarness(
            sessionID: sessionID,
            agent: agent,
            sessionStatus: sessionStatus,
            displayTitleOverride: displayTitleOverride,
            scopedWorkspaceIDs: scopedWorkspaceIDs,
            additionalWorkspaces: additionalWorkspaces,
            prependAdditionalWorkspaces: prependAdditionalWorkspaces,
            sessionPanelPlacement: sessionPanelPlacement,
            sidebarWidth: sidebarWidth
        ).hostingView
    }

    private func makeSidebarHostingView(
        state: AppState,
        windowID: UUID
    ) throws -> NSView {
        try makeSidebarHarness(state: state, windowID: windowID).hostingView
    }

    private func makeSidebarHarness(
        sessionID: String,
        agent: AgentKind = .codex,
        sessionStatus: SessionStatus,
        displayTitleOverride: String? = nil,
        scopedWorkspaceIDs: Set<UUID>? = nil,
        additionalWorkspaces: [WorkspaceState] = [],
        prependAdditionalWorkspaces: Bool = false,
        sessionPanelPlacement: SessionPanelPlacement = .focused,
        sidebarWidth: CGFloat = ToastyTheme.sidebarWidth
    ) throws -> SidebarHarness {
        let harnessState = makeSidebarAppState(for: sessionPanelPlacement)
        var state = harnessState.state
        let windowID = harnessState.windowID
        let workspaceID = harnessState.workspaceID
        let panelID = harnessState.sessionPanelID
        if additionalWorkspaces.isEmpty == false,
           let windowIndex = state.windows.firstIndex(where: { $0.id == windowID }) {
            let additionalWorkspaceIDs = additionalWorkspaces.map(\.id)
            if prependAdditionalWorkspaces {
                state.windows[windowIndex].workspaceIDs.insert(contentsOf: additionalWorkspaceIDs, at: 0)
            } else {
                state.windows[windowIndex].workspaceIDs.append(contentsOf: additionalWorkspaceIDs)
            }
            for workspace in additionalWorkspaces {
                state.workspacesByID[workspace.id] = workspace
            }
        }
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
            scopedWorkspaceIDs: scopedWorkspaceIDs,
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
            annotationStyleStore: makeTestAnnotationStyleStore(),
            terminalRuntimeContext: runtimeContext
        )
        let hostingView = NSHostingView(rootView: sidebarView.frame(width: sidebarWidth))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: sidebarWidth, height: 600),
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
            sessionRuntimeStore: sessionRuntimeStore,
            hostingView: hostingView,
            window: window
        )
    }

    private func makeSidebarHarness(
        state: AppState,
        windowID: UUID
    ) throws -> SidebarHarness {
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        let runtimeContext = TerminalWindowRuntimeContext(windowID: windowID, runtimeRegistry: registry)

        let sidebarView = SidebarView(
            windowID: windowID,
            store: store,
            terminalRuntimeRegistry: registry,
            sessionRuntimeStore: sessionRuntimeStore,
            annotationStyleStore: makeTestAnnotationStyleStore(),
            terminalRuntimeContext: runtimeContext
        )
        let hostingView = NSHostingView(rootView: sidebarView.frame(width: ToastyTheme.sidebarWidth))
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: ToastyTheme.sidebarWidth, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        hostWindow.contentView = hostingView
        hostWindow.makeKeyAndOrderFront(nil)
        pumpMainRunLoop()
        hostingView.layoutSubtreeIfNeeded()

        let stateWindow = try XCTUnwrap(state.windows.first(where: { $0.id == windowID }))
        let selectedWorkspaceID = try XCTUnwrap(stateWindow.selectedWorkspaceID)
        let selectedWorkspace = try XCTUnwrap(state.workspacesByID[selectedWorkspaceID])
        let selectedPanelID = try XCTUnwrap(selectedWorkspace.focusedPanelID)

        return SidebarHarness(
            windowID: windowID,
            workspaceID: selectedWorkspaceID,
            panelID: selectedPanelID,
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            hostingView: hostingView,
            window: hostWindow
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
            annotationStyleStore: makeTestAnnotationStyleStore(),
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
            sessionRuntimeStore: sessionRuntimeStore,
            hostingView: hostingView,
            window: window
        )
    }

    private func makeMultiSessionSidebarHarness(sessionCount: Int) throws -> MultiSessionSidebarHarness {
        XCTAssertGreaterThanOrEqual(sessionCount, 2)
        let panelIDs = (0..<sessionCount).map { _ in UUID() }
        let workspaceID = UUID()
        let windowID = UUID()
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Workspace 1",
            layoutTree: layoutTree(forPanelIDs: panelIDs),
            panels: Dictionary(
                uniqueKeysWithValues: panelIDs.enumerated().map { offset, panelID in
                    (
                        panelID,
                        PanelState.terminal(TerminalPanelState(
                            title: "Terminal \(offset + 1)",
                            shell: "zsh",
                            cwd: "/repo"
                        ))
                    )
                }
            ),
            focusedPanelID: panelIDs[0]
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
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        let runtimeContext = TerminalWindowRuntimeContext(windowID: windowID, runtimeRegistry: registry)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionIDs = panelIDs.indices.map { "session-row-\($0 + 1)" }
        for (offset, panelID) in panelIDs.enumerated() {
            sessionRuntimeStore.startSession(
                sessionID: sessionIDs[offset],
                agent: .codex,
                panelID: panelID,
                windowID: windowID,
                workspaceID: workspaceID,
                displayTitleOverride: "Session \(offset + 1)",
                cwd: "/repo/sidebar",
                repoRoot: "/repo",
                at: now.addingTimeInterval(TimeInterval(offset))
            )
            sessionRuntimeStore.updateStatus(
                sessionID: sessionIDs[offset],
                status: SessionStatus(kind: .idle, summary: "Idle", detail: "Ready"),
                at: now.addingTimeInterval(TimeInterval(offset) + 0.5)
            )
        }

        let sidebarView = SidebarView(
            windowID: windowID,
            store: store,
            terminalRuntimeRegistry: registry,
            sessionRuntimeStore: sessionRuntimeStore,
            annotationStyleStore: makeTestAnnotationStyleStore(),
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
        waitForSessionPointerViews(sessionIDs, in: hostingView)

        return MultiSessionSidebarHarness(
            windowID: windowID,
            workspaceID: workspaceID,
            panelIDs: panelIDs,
            sessionIDs: sessionIDs,
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            hostingView: hostingView,
            window: window
        )
    }

    private func makeParentChildSessionSidebarHarness() throws -> MultiSessionSidebarHarness {
        let harness = try makeMultiSessionSidebarHarness(sessionCount: 2)
        harness.sessionRuntimeStore.updateBackgroundActivity(
            sessionID: harness.sessionIDs[0],
            activity: SessionBackgroundActivity(
                id: "drag-child",
                kind: .subagent,
                displayName: "Drag Child",
                startedAt: Date(timeIntervalSince1970: 1_700_000_020),
                lastUpdatedAt: Date(timeIntervalSince1970: 1_700_000_020)
            ),
            at: Date(timeIntervalSince1970: 1_700_000_020)
        )
        pumpMainRunLoop(duration: 0.2)
        harness.hostingView.layoutSubtreeIfNeeded()
        return harness
    }

    private func layoutTree(forPanelIDs panelIDs: [UUID]) -> LayoutNode {
        precondition(panelIDs.isEmpty == false)
        if panelIDs.count == 1 {
            return .slot(slotID: UUID(), panelID: panelIDs[0])
        }
        return .split(
            nodeID: UUID(),
            orientation: .vertical,
            ratio: 1.0 / Double(panelIDs.count),
            first: .slot(slotID: UUID(), panelID: panelIDs[0]),
            second: layoutTree(forPanelIDs: Array(panelIDs.dropFirst()))
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

    private func makeSidebarAppState(
        selectedWorkspace: WorkspaceState,
        additionalWorkspaces: [WorkspaceState]
    ) -> (state: AppState, windowID: UUID) {
        let windowID = UUID()
        let workspaces = [selectedWorkspace] + additionalWorkspaces
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: ToastyTheme.sidebarWidth, height: 600),
                    workspaceIDs: workspaces.map(\.id),
                    selectedWorkspaceID: selectedWorkspace.id
                )
            ],
            workspacesByID: Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) }),
            selectedWindowID: windowID
        )
        return (state, windowID)
    }

    private func makeSinglePanelWorkspace(id: UUID, title: String) -> WorkspaceState {
        let panelID = UUID()
        return WorkspaceState(
            id: id,
            title: title,
            layoutTree: .slot(slotID: UUID(), panelID: panelID),
            panels: [
                panelID: .terminal(TerminalPanelState(title: title, shell: "zsh", cwd: "/repo"))
            ],
            focusedPanelID: panelID
        )
    }

    private func measuredAnnotationChipWidth(
        text: String,
        isLink: Bool,
        proposedWidth: CGFloat = 300
    ) -> CGFloat {
        let recorder = SidebarLayoutWidthRecorder()
        let colors = ToastyTheme.AnnotationChipColors(
            foreground: .white,
            background: .blue,
            border: .blue
        )
        let hostingView = NSHostingView(
            rootView: SidebarProposedWidthRecordingLayout(
                proposedWidth: proposedWidth,
                recorder: recorder
            ) {
                SidebarView.workspaceAnnotationChipLabel(
                    annotation: WorkspaceAnnotation(text: text),
                    chipColors: colors,
                    isLink: isLink
                )
            }
        )
        _ = hostingView.fittingSize
        hostingView.layoutSubtreeIfNeeded()
        return recorder.width
    }

    private func measuredWorkspaceRowFrame(childStatusKind: SessionStatusKind) throws -> CGRect {
        let state = AppState.bootstrap()
        let windowID = try XCTUnwrap(state.windows.first?.id)
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
        let parentPanelID = try XCTUnwrap(workspace.focusedPanelID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        let runtimeContext = TerminalWindowRuntimeContext(windowID: windowID, runtimeRegistry: registry)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let parentSessionID = "single-line-child-chip-parent"
        let childSessionID = "single-line-child-chip-child"

        sessionRuntimeStore.startSession(
            sessionID: parentSessionID,
            agent: .codex,
            panelID: parentPanelID,
            windowID: windowID,
            workspaceID: workspaceID,
            cwd: "/repo/sidebar",
            repoRoot: "/repo",
            at: now
        )
        sessionRuntimeStore.startSession(
            sessionID: childSessionID,
            agent: .claude,
            panelID: UUID(),
            windowID: windowID,
            workspaceID: workspaceID,
            parentSessionID: parentSessionID,
            displayTitleOverride: "long-running-review-agent",
            cwd: "/repo/sidebar",
            repoRoot: "/repo",
            at: now.addingTimeInterval(1)
        )
        sessionRuntimeStore.updateStatus(
            sessionID: childSessionID,
            status: SessionStatus(
                kind: childStatusKind,
                summary: "Child status",
                detail: "Review a command with intentionally long context"
            ),
            at: now.addingTimeInterval(2)
        )
        defer { sessionRuntimeStore.reset() }

        var workspaceRowFramesByID: [UUID: CGRect] = [:]
        let sidebarWidth = CGFloat(WindowState.minSidebarWidth)
        let sidebarView = SidebarView(
            windowID: windowID,
            store: store,
            terminalRuntimeRegistry: registry,
            sessionRuntimeStore: sessionRuntimeStore,
            annotationStyleStore: makeTestAnnotationStyleStore(),
            terminalRuntimeContext: runtimeContext,
            workspaceRowFrameObserver: { workspaceRowFramesByID = $0 }
        )
        let hostingView = NSHostingView(rootView: sidebarView.frame(width: sidebarWidth))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: sidebarWidth, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)

        let deadline = Date().addingTimeInterval(1)
        while workspaceRowFramesByID[workspaceID] == nil, Date() < deadline {
            pumpMainRunLoop(duration: 0.05)
            hostingView.layoutSubtreeIfNeeded()
        }

        return try XCTUnwrap(workspaceRowFramesByID[workspaceID])
    }

    private func measuredAnnotationChipsFlowSize(
        texts: [String],
        proposedWidth: CGFloat
    ) -> CGSize {
        let recorder = SidebarLayoutWidthRecorder()
        let colors = ToastyTheme.AnnotationChipColors(
            foreground: .white,
            background: .blue,
            border: .blue
        )
        let hostingView = NSHostingView(
            rootView: SidebarProposedWidthRecordingLayout(
                proposedWidth: proposedWidth,
                recorder: recorder
            ) {
                SidebarWrappingFlowLayout(horizontalSpacing: 4, verticalSpacing: 4) {
                    ForEach(Array(texts.enumerated()), id: \.offset) { _, text in
                        SidebarView.workspaceAnnotationChipLabel(
                            annotation: WorkspaceAnnotation(text: text),
                            chipColors: colors,
                            isLink: false
                        )
                    }
                }
            }
        )
        _ = hostingView.fittingSize
        hostingView.layoutSubtreeIfNeeded()
        return CGSize(width: recorder.width, height: recorder.height)
    }

    private func renderedBitmap(for view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: bitmap)
        return bitmap
    }

    private func waitForRenderedBitmap(
        of view: NSView,
        matching baseline: NSBitmapImageRep,
        timeout: TimeInterval = 1.5,
        pollInterval: TimeInterval = 0.05
    ) throws -> NSBitmapImageRep {
        let deadline = Date().addingTimeInterval(timeout)
        var latestBitmap = try renderedBitmap(for: view)
        var latestDifference = try differingPixelCount(between: baseline, and: latestBitmap)

        while latestDifference != 0, Date() < deadline {
            pumpMainRunLoop(duration: pollInterval)
            latestBitmap = try renderedBitmap(for: view)
            latestDifference = try differingPixelCount(between: baseline, and: latestBitmap)
        }

        return latestBitmap
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
        view: PointerInteractionView,
        at location: NSPoint,
        clickCount: Int = 1
    ) throws {
        let windowLocation = view.convert(location, to: nil)
        guard let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowLocation,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ) else {
            throw NSError(domain: "SidebarViewTests", code: 1, userInfo: nil)
        }
        guard let mouseUp = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowLocation,
            modifierFlags: [],
            timestamp: 0.05,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 1,
            clickCount: clickCount,
            pressure: 0
        ) else {
            throw NSError(domain: "SidebarViewTests", code: 2, userInfo: nil)
        }

        view.mouseDown(with: mouseDown)
        view.mouseUp(with: mouseUp)
    }

    private func drag(
        view: PointerInteractionView,
        from start: NSPoint,
        through dragPoint: NSPoint? = nil,
        to end: NSPoint
    ) throws {
        view.usesEventTrackingLoop = false
        try beginDrag(view: view, at: start)
        try continueDrag(view: view, at: dragPoint ?? end)
        try endDrag(view: view, at: end)
    }

    private func beginDrag(view: PointerInteractionView, at location: NSPoint) throws {
        guard let event = pointerMouseEvent(type: .leftMouseDown, view: view, at: location, timestamp: 0, eventNumber: 0) else {
            throw NSError(domain: "SidebarViewTests", code: 5, userInfo: nil)
        }
        view.mouseDown(with: event)
    }

    private func continueDrag(view: PointerInteractionView, at location: NSPoint) throws {
        guard let event = pointerMouseEvent(type: .leftMouseDragged, view: view, at: location, timestamp: 0.05, eventNumber: 1) else {
            throw NSError(domain: "SidebarViewTests", code: 6, userInfo: nil)
        }
        view.mouseDragged(with: event)
    }

    private func endDrag(view: PointerInteractionView, at location: NSPoint) throws {
        guard let event = pointerMouseEvent(type: .leftMouseUp, view: view, at: location, timestamp: 0.1, eventNumber: 2) else {
            throw NSError(domain: "SidebarViewTests", code: 7, userInfo: nil)
        }
        view.mouseUp(with: event)
    }

    private func pointerMouseEvent(
        type: NSEvent.EventType,
        view: NSView,
        at location: NSPoint,
        timestamp: TimeInterval,
        eventNumber: Int
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: view.convert(location, to: nil),
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: eventNumber,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )
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
            throw NSError(domain: "SidebarViewTests", code: 3, userInfo: nil)
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
            throw NSError(domain: "SidebarViewTests", code: 4, userInfo: nil)
        }

        let pointerView = enclosingPointerInteractionView(from: window.contentView?.hitTest(location))
        let previousUsesEventTrackingLoop = pointerView?.usesEventTrackingLoop
        pointerView?.usesEventTrackingLoop = false
        defer {
            if let previousUsesEventTrackingLoop {
                pointerView?.usesEventTrackingLoop = previousUsesEventTrackingLoop
            }
        }

        window.sendEvent(mouseDown)
        window.sendEvent(mouseUp)
    }

    private func pointerInteractionView(in rootView: NSView, workspaceID: UUID) -> PointerInteractionView? {
        if let pointerView = rootView as? PointerInteractionView,
           pointerView.logName == "workspace-sidebar-row",
           pointerView.logMetadata["workspaceID"] == workspaceID.uuidString {
            return pointerView
        }

        for subview in rootView.subviews {
            if let matchingView = pointerInteractionView(in: subview, workspaceID: workspaceID) {
                return matchingView
            }
        }

        return nil
    }

    private func sessionPointerInteractionView(in rootView: NSView, sessionID: String) throws -> PointerInteractionView {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            pumpMainRunLoop(duration: 0.05)
            rootView.layoutSubtreeIfNeeded()
            if let view = pointerInteractionView(in: rootView, sessionID: sessionID) {
                view.usesEventTrackingLoop = false
                return view
            }
        }
        return try XCTUnwrap(pointerInteractionView(in: rootView, sessionID: sessionID))
    }

    private func waitForSessionPointerViews(_ sessionIDs: [String], in rootView: NSView) {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            pumpMainRunLoop(duration: 0.05)
            rootView.layoutSubtreeIfNeeded()
            let missing = sessionIDs.contains { pointerInteractionView(in: rootView, sessionID: $0) == nil }
            if missing == false { return }
        }
    }

    private func pointerInteractionView(in rootView: NSView, sessionID: String) -> PointerInteractionView? {
        if let pointerView = rootView as? PointerInteractionView,
           pointerView.logName == "session-sidebar-row",
           pointerView.logMetadata["sessionID"] == sessionID {
            return pointerView
        }

        for subview in rootView.subviews {
            if let matchingView = pointerInteractionView(in: subview, sessionID: sessionID) {
                return matchingView
            }
        }

        return nil
    }

    private func enclosingPointerInteractionView(from view: NSView?) -> PointerInteractionView? {
        var currentView = view
        while let view = currentView {
            if let pointerView = view as? PointerInteractionView {
                return pointerView
            }
            currentView = view.superview
        }
        return nil
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

    private func renderedTooltipValues(in rootView: NSView) -> [String] {
        Array(Set(recursiveSubviewTooltipValues(in: rootView))).sorted()
    }

    private func recursiveSubviewTooltipValues(in view: NSView) -> [String] {
        var values: [String] = []
        if let tooltip = view.toolTip?.trimmingCharacters(in: .whitespacesAndNewlines),
           tooltip.isEmpty == false {
            values.append(tooltip)
        }

        for subview in view.subviews {
            values.append(contentsOf: recursiveSubviewTooltipValues(in: subview))
        }

        return values
    }

    private func tooltipView(in rootView: NSView, containing text: String) -> NSView? {
        if let tooltip = rootView.toolTip,
           tooltip.contains(text) {
            return rootView
        }

        for subview in rootView.subviews {
            if let matchingView = tooltipView(in: subview, containing: text) {
                return matchingView
            }
        }

        return nil
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
