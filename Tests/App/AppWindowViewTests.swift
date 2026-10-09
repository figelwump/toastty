@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class AppWindowViewTests: XCTestCase {
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

    func testEffectiveSidebarWidthUsesCompactDefaultBeforeAgentLaunch() {
        XCTAssertEqual(
            AppWindowView.effectiveSidebarWidth(hasEverLaunchedAgent: false),
            180
        )
    }

    func testEffectiveSidebarWidthUsesExpandedDefaultAfterAgentLaunch() {
        XCTAssertEqual(
            AppWindowView.effectiveSidebarWidth(hasEverLaunchedAgent: true),
            280
        )
    }

    func testEffectiveSidebarWidthUsesPersistedOverride() {
        XCTAssertEqual(
            AppWindowView.effectiveSidebarWidth(
                hasEverLaunchedAgent: false,
                sidebarWidthPointsOverride: 320
            ),
            320
        )
        XCTAssertEqual(
            AppWindowView.effectiveSidebarWidth(
                hasEverLaunchedAgent: true,
                sidebarWidthPointsOverride: 320
            ),
            320
        )
    }

    func testEffectiveSidebarWidthClampsPersistedOverride() {
        XCTAssertEqual(
            AppWindowView.effectiveSidebarWidth(
                hasEverLaunchedAgent: true,
                sidebarWidthPointsOverride: 10
            ),
            CGFloat(WindowState.minSidebarWidth)
        )
        XCTAssertEqual(
            AppWindowView.effectiveSidebarWidth(
                hasEverLaunchedAgent: true,
                sidebarWidthPointsOverride: 900
            ),
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

    func testEffectiveSidebarWidthTransitionsAfterSuccessfulAgentLaunch() {
        let store = AppStore(persistTerminalFontPreference: false)

        XCTAssertEqual(
            AppWindowView.effectiveSidebarWidth(hasEverLaunchedAgent: store.hasEverLaunchedAgent),
            180
        )

        store.recordSuccessfulAgentLaunch()

        XCTAssertEqual(
            AppWindowView.effectiveSidebarWidth(hasEverLaunchedAgent: store.hasEverLaunchedAgent),
            280
        )
    }

    func testFirstProgramStatusExpandsCompactSidebarAndRecordsEligibility() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        var hasHandledAppearance = false

        AppWindowView.expandSidebarForProgramStatusIfNeeded(
            store: store,
            windowID: windowID,
            hasHandledAppearance: &hasHandledAppearance
        )

        XCTAssertTrue(hasHandledAppearance)
        XCTAssertTrue(store.hasEverLaunchedAgent)
        XCTAssertNil(store.window(id: windowID)?.sidebarWidthPointsOverride)
        XCTAssertEqual(
            AppWindowView.effectiveSidebarWidth(hasEverLaunchedAgent: store.hasEverLaunchedAgent),
            280
        )
    }

    func testFirstProgramStatusExpandsNarrowOverrideToExpandedDefault() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        XCTAssertTrue(store.send(.setSidebarWidth(windowID: windowID, width: 220, defaultWidth: 180)))
        var hasHandledAppearance = false

        AppWindowView.expandSidebarForProgramStatusIfNeeded(
            store: store,
            windowID: windowID,
            hasHandledAppearance: &hasHandledAppearance
        )

        XCTAssertTrue(store.hasEverLaunchedAgent)
        XCTAssertNil(store.window(id: windowID)?.sidebarWidthPointsOverride)
    }

    func testFirstProgramStatusPreservesWiderOverride() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        XCTAssertTrue(store.send(.setSidebarWidth(windowID: windowID, width: 360, defaultWidth: 180)))
        var hasHandledAppearance = false

        AppWindowView.expandSidebarForProgramStatusIfNeeded(
            store: store,
            windowID: windowID,
            hasHandledAppearance: &hasHandledAppearance
        )

        XCTAssertTrue(hasHandledAppearance)
        XCTAssertTrue(store.hasEverLaunchedAgent)
        XCTAssertEqual(store.window(id: windowID)?.sidebarWidthPointsOverride, 360)
    }

    func testLaterProgramStatusAppearancePreservesManualNarrowing() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        var hasHandledAppearance = false
        AppWindowView.expandSidebarForProgramStatusIfNeeded(
            store: store,
            windowID: windowID,
            hasHandledAppearance: &hasHandledAppearance
        )
        XCTAssertTrue(store.send(.setSidebarWidth(windowID: windowID, width: 200, defaultWidth: 280)))

        AppWindowView.expandSidebarForProgramStatusIfNeeded(
            store: store,
            windowID: windowID,
            hasHandledAppearance: &hasHandledAppearance
        )

        XCTAssertEqual(store.window(id: windowID)?.sidebarWidthPointsOverride, 200)
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
