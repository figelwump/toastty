@testable import ToasttyApp
import XCTest

@MainActor
final class AppWindowViewTests: XCTestCase {
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
