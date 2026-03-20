@testable import ToasttyApp
import XCTest

@MainActor
final class AppWindowViewTests: XCTestCase {
    func testEffectiveSidebarWidthUsesCompactDefaultBeforeAgentLaunch() {
        XCTAssertEqual(
            AppWindowView.effectiveSidebarWidth(
                sidebarWidthOverride: nil,
                hasEverLaunchedAgent: false
            ),
            180
        )
    }

    func testEffectiveSidebarWidthUsesExpandedDefaultAfterAgentLaunch() {
        XCTAssertEqual(
            AppWindowView.effectiveSidebarWidth(
                sidebarWidthOverride: nil,
                hasEverLaunchedAgent: true
            ),
            280
        )
    }

    func testEffectiveSidebarWidthPrefersManualOverride() {
        XCTAssertEqual(
            AppWindowView.effectiveSidebarWidth(
                sidebarWidthOverride: 336,
                hasEverLaunchedAgent: false
            ),
            336
        )
    }

    func testEffectiveSidebarWidthTransitionsAfterSuccessfulAgentLaunch() {
        let store = AppStore(persistTerminalFontPreference: false)

        XCTAssertEqual(
            AppWindowView.effectiveSidebarWidth(
                sidebarWidthOverride: nil,
                hasEverLaunchedAgent: store.hasEverLaunchedAgent
            ),
            180
        )

        store.recordSuccessfulAgentLaunch()

        XCTAssertEqual(
            AppWindowView.effectiveSidebarWidth(
                sidebarWidthOverride: nil,
                hasEverLaunchedAgent: store.hasEverLaunchedAgent
            ),
            280
        )
    }

    func testClampedSidebarWidthLeavesRoomForWorkspace() {
        XCTAssertEqual(
            AppWindowView.clampedSidebarWidth(400, availableWidth: 700),
            370
        )
    }
}
