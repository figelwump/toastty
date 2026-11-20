@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class AppWindowViewTests: XCTestCase {
    func testColumnResizeTracksLocalPreviewAndCommitsOnlyMouseUpWidth() {
        let resize = LiveColumnResize()
        resize.begin(.sidebar, width: 260, holdingWorkspaceAt: 800)
        resize.update(.sidebar, translation: 10, availableWidth: 1061)
        resize.update(.sidebar, translation: 20, availableWidth: 1061)
        XCTAssertEqual(resize.width(for: .sidebar), 280)
        XCTAssertNil(resize.width(for: .dock))
        XCTAssertEqual(resize.heldWorkspaceWidth, 800)
        XCTAssertEqual(resize.finish(.sidebar, translation: 25, availableWidth: 1061), 285)
        XCTAssertNil(resize.width(for: .sidebar))
        XCTAssertNil(resize.heldWorkspaceWidth)
        XCTAssertNil(resize.finish(.sidebar, translation: 30, availableWidth: 1061))
    }

    func testRightPanelPreviewIsTabScopedAndCancellationPreservesDefault() {
        let resize = LiveColumnResize()
        let workspaceID = UUID()
        let column = ResizingColumn.rightPanel(workspaceID: workspaceID, tabID: UUID())
        resize.begin(column, width: 400)
        resize.update(column, translation: -60, availableWidth: 1000)
        XCTAssertEqual(resize.width(for: column), 460)
        XCTAssertNil(resize.width(for: .rightPanel(workspaceID: workspaceID, tabID: UUID())))
        XCTAssertNil(resize.heldWorkspaceWidth)
        resize.cancel(column)
        XCTAssertNil(resize.finish(column, translation: -60, availableWidth: 1000))
        resize.begin(column, width: 400)
        XCTAssertNil(resize.finish(column, translation: 0, availableWidth: 1000))
    }

    func testPreviewAndCommitUseTheSameColumnLimits() {
        let available: CGFloat = 1000
        let cases: [(ResizingColumn, CGFloat, CGFloat, CGFloat)] = [
            (.sidebar, 240, -1000, WindowState.minSidebarWidth),
            (.dock, 300, 1000, WindowState.maxCoordinatorDockWidth(windowWidth: available)),
            (.rightPanel(workspaceID: UUID(), tabID: UUID()), 400, -1000,
             RightAuxPanelState.clampedWidth(1400, for: available)),
        ]
        for (column, start, delta, expected) in cases {
            let resize = LiveColumnResize()
            resize.begin(column, width: start)
            resize.update(column, translation: delta, availableWidth: available)
            XCTAssertEqual(resize.width(for: column), expected)
            XCTAssertEqual(resize.finish(column, translation: delta, availableWidth: available), expected)
        }
    }

    func testNavigationControlsFitMinimumSidebarAndReserveHiddenSidebarHeaderSpace() {
        let controlsTrailingEdge = ToastyTheme.titlebarSidebarToggleLeadingPadding +
            (3 * ToastyTheme.titlebarSidebarToggleButtonSize) + (2 * ToastyTheme.titlebarControlSpacing)
        XCTAssertLessThan(controlsTrailingEdge, CGFloat(WindowState.minSidebarWidth))
        XCTAssertGreaterThan(ToastyTheme.topBarLeadingPaddingWithoutSidebar, controlsTrailingEdge)
    }

    func testSidebarToggleShowsUnreadBadgeOnlyWhenSidebarIsHidden() {
        XCTAssertTrue(
            AppWindowView.sidebarToggleShowsUnreadBadge(
                sidebarVisible: false,
                hasUnreadNotifications: true
            )
        )
        XCTAssertFalse(
            AppWindowView.sidebarToggleShowsUnreadBadge(
                sidebarVisible: true,
                hasUnreadNotifications: true
            )
        )
        XCTAssertFalse(
            AppWindowView.sidebarToggleShowsUnreadBadge(
                sidebarVisible: false,
                hasUnreadNotifications: false
            )
        )
    }

    func testSidebarToggleAccessibilityCopyReflectsVisibilityAndUnreadState() {
        XCTAssertEqual(
            AppWindowView.sidebarToggleAccessibilityLabel(sidebarVisible: true),
            "Hide Workspaces"
        )
        XCTAssertEqual(
            AppWindowView.sidebarToggleAccessibilityLabel(sidebarVisible: false),
            "Show Workspaces"
        )
        XCTAssertEqual(
            AppWindowView.sidebarToggleAccessibilityValue(hasUnreadBadge: true),
            "Unread notifications"
        )
        XCTAssertEqual(
            AppWindowView.sidebarToggleAccessibilityValue(hasUnreadBadge: false),
            ""
        )
    }

    func testEffectiveSidebarWidthUsesFullDefaultWithoutOverride() {
        XCTAssertEqual(AppWindowView.effectiveSidebarWidth(sidebarWidthPointsOverride: nil), 280)
    }

    func testEffectiveSidebarWidthUsesPersistedOverride() {
        XCTAssertEqual(AppWindowView.effectiveSidebarWidth(sidebarWidthPointsOverride: 320), 320)
    }

    func testEffectiveSidebarWidthClampsPersistedOverride() {
        XCTAssertEqual(
            AppWindowView.effectiveSidebarWidth(sidebarWidthPointsOverride: 10),
            CGFloat(WindowState.minSidebarWidth)
        )
        XCTAssertEqual(
            AppWindowView.effectiveSidebarWidth(sidebarWidthPointsOverride: 900),
            CGFloat(WindowState.maxSidebarWidth)
        )
    }

    func testSidebarResizeHandleFrameStraddlesDivider() {
        let frame = AppWindowView.sidebarResizeHandleFrame(sidebarWidth: 280, height: 600)

        XCTAssertEqual(frame.origin.x, 275.5)
        XCTAssertEqual(frame.origin.y, 0)
        XCTAssertEqual(frame.size.width, AppWindowView.sidebarResizeHandleHitWidth)
        XCTAssertEqual(frame.size.height, 600)
    }

    func testFirstRunAutoOpenGatingAllowsOneFreshPersistentLaunchPresentation() {
        XCTAssertTrue(
            AppWindowSceneView.shouldAutoOpenGettingStartedPanel(
                allowsAutoPresentation: true,
                hasAutoOpenedThisLaunch: false
            )
        )
        XCTAssertFalse(
            AppWindowSceneView.shouldAutoOpenGettingStartedPanel(
                allowsAutoPresentation: false,
                hasAutoOpenedThisLaunch: false
            )
        )
        XCTAssertFalse(
            AppWindowSceneView.shouldAutoOpenGettingStartedPanel(
                allowsAutoPresentation: true,
                hasAutoOpenedThisLaunch: true
            )
        )
    }

    func testStoreRecordsGettingStartedPanelAutoOpenOnlyAfterSuccessfulOpen() throws {
        let initialState = AppState.bootstrap()
        let workspaceID = try XCTUnwrap(initialState.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: initialState, persistTerminalFontPreference: false)

        XCTAssertFalse(store.hasAutoOpenedGettingStartedPanelThisLaunch)
        XCTAssertFalse(store.autoOpenGettingStartedPanelIfNeeded(workspaceID: UUID()))
        XCTAssertFalse(store.hasAutoOpenedGettingStartedPanelThisLaunch)

        XCTAssertTrue(store.autoOpenGettingStartedPanelIfNeeded(workspaceID: workspaceID))
        XCTAssertTrue(store.hasAutoOpenedGettingStartedPanelThisLaunch)
        XCTAssertFalse(store.autoOpenGettingStartedPanelIfNeeded(workspaceID: workspaceID))
    }
}
