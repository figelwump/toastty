@testable import ToasttyApp
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
