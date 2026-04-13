@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class BrowserPanelHostViewTests: XCTestCase {
    func testCoordinatorDefersBrowserStateApplyUntilScheduledCallbackRuns() {
        let recorder = ScheduledBrowserPanelApplyRecorder()
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = BrowserPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let webState = WebPanelState(definition: .browser, currentURL: "about:blank")

        coordinator.scheduleApply(webState: webState, runtime: runtime)

        XCTAssertEqual(recorder.callbacks.count, 1)
        XCTAssertNil(runtime.navigationState.displayedURLString)

        recorder.callbacks.removeFirst()()

        XCTAssertEqual(runtime.navigationState.displayedURLString, "about:blank")
        XCTAssertEqual(coordinator.lastAppliedWebState, webState)
    }

    func testCoordinatorIgnoresStaleScheduledBrowserStateApply() {
        let recorder = ScheduledBrowserPanelApplyRecorder()
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = BrowserPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let firstState = WebPanelState(definition: .browser, currentURL: "about:blank")
        let secondState = WebPanelState(definition: .browser, currentURL: "https://example.com")

        coordinator.scheduleApply(webState: firstState, runtime: runtime)
        coordinator.scheduleApply(webState: secondState, runtime: runtime)

        XCTAssertEqual(recorder.callbacks.count, 2)

        recorder.callbacks.removeFirst()()
        XCTAssertNil(runtime.navigationState.displayedURLString)

        recorder.callbacks.removeFirst()()

        XCTAssertEqual(runtime.navigationState.displayedURLString, "https://example.com")
        XCTAssertEqual(coordinator.lastAppliedWebState, secondState)
    }

    func testCoordinatorAppliesLatestScheduledBrowserStateWhenUpdatesBounce() {
        let recorder = ScheduledBrowserPanelApplyRecorder()
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = BrowserPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let firstState = WebPanelState(definition: .browser, currentURL: "about:blank")
        let secondState = WebPanelState(definition: .browser, currentURL: "https://example.com")

        coordinator.scheduleApply(webState: firstState, runtime: runtime)
        coordinator.scheduleApply(webState: secondState, runtime: runtime)
        coordinator.scheduleApply(webState: firstState, runtime: runtime)

        XCTAssertEqual(recorder.callbacks.count, 3)

        for callback in recorder.callbacks {
            callback()
        }

        XCTAssertEqual(runtime.navigationState.displayedURLString, "about:blank")
        XCTAssertEqual(coordinator.lastAppliedWebState, firstState)
    }

    func testCoordinatorDoesNotReschedulePendingBrowserState() {
        let recorder = ScheduledBrowserPanelApplyRecorder()
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = BrowserPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let webState = WebPanelState(definition: .browser, currentURL: "about:blank")

        coordinator.scheduleApply(webState: webState, runtime: runtime)
        coordinator.scheduleApply(webState: webState, runtime: runtime)

        XCTAssertEqual(recorder.callbacks.count, 1)
    }

    func testCoordinatorResetPreventsPendingBrowserStateApply() {
        let recorder = ScheduledBrowserPanelApplyRecorder()
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = BrowserPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let webState = WebPanelState(definition: .browser, currentURL: "about:blank")

        coordinator.scheduleApply(webState: webState, runtime: runtime)
        coordinator.reset()

        recorder.callbacks.removeFirst()()

        XCTAssertNil(runtime.navigationState.displayedURLString)
        XCTAssertNil(coordinator.lastAppliedWebState)
    }
}

private final class ScheduledBrowserPanelApplyRecorder: @unchecked Sendable {
    var callbacks: [@MainActor @Sendable () -> Void] = []
}
