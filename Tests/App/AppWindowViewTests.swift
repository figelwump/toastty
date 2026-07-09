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

    func testManualAgentGetStartedPresentationBypassesAutoSuppressionState() {
        let windowID = UUID()
        let suppressedStore = AppStore(
            persistTerminalFontPreference: false,
            initialHasSuppressedGettingStarted: true,
            gettingStartedSetupFootprint: GettingStartedSetupFootprint(hasAgentProfiles: true)
        )

        XCTAssertFalse(suppressedStore.shouldShowGettingStartedTopBarButton)
        XCTAssertTrue(
            AppWindowView.shouldPresentAgentGetStartedFlow(
                windowID: windowID,
                notificationObject: windowID
            )
        )
    }

    func testAgentGetStartedPresentationRequestPreservesInitialStep() throws {
        let windowID = UUID()
        let request = AgentGetStartedPresentationRequest(
            windowID: windowID,
            initialStep: .agentStatusHooks
        )

        let resolvedRequest = try XCTUnwrap(
            AppWindowView.agentGetStartedPresentationRequest(
                windowID: windowID,
                notificationObject: request
            )
        )

        XCTAssertEqual(resolvedRequest, request)
        XCTAssertFalse(resolvedRequest.isAutomatic)
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

    func testShouldAutoPresentAgentGetStartedFlowOnlyForEligibleFirstSessionPresentation() {
        XCTAssertTrue(
            AppWindowView.shouldAutoPresentAgentGetStartedFlow(
                allowsAutoPresentation: true,
                hasSuppressedGettingStarted: false,
                hasAutoPresentedThisSession: false
            )
        )

        XCTAssertFalse(
            AppWindowView.shouldAutoPresentAgentGetStartedFlow(
                allowsAutoPresentation: false,
                hasSuppressedGettingStarted: false,
                hasAutoPresentedThisSession: false
            )
        )
        XCTAssertFalse(
            AppWindowView.shouldAutoPresentAgentGetStartedFlow(
                allowsAutoPresentation: true,
                hasSuppressedGettingStarted: true,
                hasAutoPresentedThisSession: false
            )
        )
        XCTAssertFalse(
            AppWindowView.shouldAutoPresentAgentGetStartedFlow(
                allowsAutoPresentation: true,
                hasSuppressedGettingStarted: false,
                hasAutoPresentedThisSession: true
            )
        )
    }

    func testAgentGetStartedAutoPresentationRequestTargetsChooser() throws {
        let windowID = UUID()

        let request = try XCTUnwrap(
            AppWindowView.agentGetStartedAutoPresentationRequest(
                windowID: windowID,
                allowsAutoPresentation: true,
                hasSuppressedGettingStarted: false,
                hasAutoPresentedThisSession: false
            )
        )

        XCTAssertEqual(
            request,
            AgentGetStartedPresentationRequest(windowID: windowID, isAutomatic: true)
        )
    }

    func testAgentGetStartedAutoPresentationRequestSuppressesIneligibleCases() {
        XCTAssertNil(
            AppWindowView.agentGetStartedAutoPresentationRequest(
                windowID: UUID(),
                allowsAutoPresentation: false,
                hasSuppressedGettingStarted: false,
                hasAutoPresentedThisSession: false
            )
        )
        XCTAssertNil(
            AppWindowView.agentGetStartedAutoPresentationRequest(
                windowID: UUID(),
                allowsAutoPresentation: true,
                hasSuppressedGettingStarted: true,
                hasAutoPresentedThisSession: false
            )
        )
        XCTAssertNil(
            AppWindowView.agentGetStartedAutoPresentationRequest(
                windowID: UUID(),
                allowsAutoPresentation: true,
                hasSuppressedGettingStarted: false,
                hasAutoPresentedThisSession: true
            )
        )
    }

    func testStoreRecordsGettingStartedAutoPresentationOnlyOncePerSession() {
        let store = AppStore(persistTerminalFontPreference: false)

        XCTAssertFalse(store.hasAutoPresentedGettingStartedThisSession)
        XCTAssertTrue(store.recordGettingStartedAutoPresentationIfNeeded())
        XCTAssertTrue(store.hasAutoPresentedGettingStartedThisSession)
        XCTAssertFalse(store.recordGettingStartedAutoPresentationIfNeeded())
    }

    func testStoreSuppressesGettingStartedWithoutPersistenceWhenDisabled() {
        let store = AppStore(persistTerminalFontPreference: false)

        XCTAssertFalse(store.hasSuppressedGettingStarted)
        XCTAssertTrue(store.shouldShowGettingStartedTopBarButton)
        store.suppressGettingStarted()
        XCTAssertTrue(store.hasSuppressedGettingStarted)
        XCTAssertFalse(store.shouldShowGettingStartedTopBarButton)
    }

    func testStoreHidesGettingStartedTopBarButtonWhenSetupFootprintExists() {
        let store = AppStore(
            persistTerminalFontPreference: false,
            gettingStartedSetupFootprint: GettingStartedSetupFootprint(hasAgentProfiles: true)
        )

        XCTAssertFalse(store.hasSuppressedGettingStarted)
        XCTAssertFalse(store.shouldShowGettingStartedTopBarButton)
    }
}
