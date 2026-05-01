@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class AppWindowViewTests: XCTestCase {
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

    func testShouldPresentAgentGetStartedFlowMatchesWindowID() {
        let windowID = UUID()

        XCTAssertTrue(
            AppWindowView.shouldPresentAgentGetStartedFlow(
                windowID: windowID,
                notificationObject: windowID
            )
        )
    }

    func testShouldPresentAgentGetStartedFlowIgnoresMismatchedOrMissingWindowIDs() {
        let windowID = UUID()

        XCTAssertFalse(
            AppWindowView.shouldPresentAgentGetStartedFlow(
                windowID: windowID,
                notificationObject: UUID()
            )
        )
        XCTAssertFalse(
            AppWindowView.shouldPresentAgentGetStartedFlow(
                windowID: windowID,
                notificationObject: "not-a-window-id"
            )
        )
        XCTAssertFalse(
            AppWindowView.shouldPresentAgentGetStartedFlow(
                windowID: windowID,
                notificationObject: nil
            )
        )
    }
}
