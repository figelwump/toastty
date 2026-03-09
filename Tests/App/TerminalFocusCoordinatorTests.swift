@testable import ToasttyApp
import XCTest

@MainActor
final class TerminalFocusCoordinatorTests: XCTestCase {
    func testFocusSelectedWorkspaceSlotIfPossibleReturnsFalseWhenTargetIsUnavailable() {
        let coordinator = TerminalFocusCoordinator(
            maxAttempts: 1,
            retryDelayNanoseconds: 1,
            isApplicationActive: { true },
            shouldAvoidStealingKeyboardFocus: { false }
        )

        let didFocus = coordinator.focusSelectedWorkspaceSlotIfPossible {
            nil
        }

        XCTAssertFalse(didFocus)
    }

    func testFocusSelectedWorkspaceSlotIfPossibleReturnsResolvedFocusResult() {
        let coordinator = TerminalFocusCoordinator(
            maxAttempts: 1,
            retryDelayNanoseconds: 1,
            isApplicationActive: { true },
            shouldAvoidStealingKeyboardFocus: { false }
        )
        var focusCalls = 0

        let didFocus = coordinator.focusSelectedWorkspaceSlotIfPossible {
            TerminalFocusCoordinator.FocusTarget(
                isReadyForFocus: true,
                focusHostViewIfNeeded: {
                    focusCalls += 1
                    return true
                }
            )
        }

        XCTAssertTrue(didFocus)
        XCTAssertEqual(focusCalls, 1)
    }

    func testScheduleSelectedWorkspaceSlotFocusRestoreStopsWhenAvoidingFieldEditor() async {
        let coordinator = TerminalFocusCoordinator(
            maxAttempts: 2,
            retryDelayNanoseconds: 1_000_000,
            isApplicationActive: { true },
            shouldAvoidStealingKeyboardFocus: { true }
        )
        var restoreAttempts = 0

        coordinator.scheduleSelectedWorkspaceSlotFocusRestore {
            restoreAttempts += 1
            return false
        }

        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(restoreAttempts, 0)
    }

    func testScheduleSelectedWorkspaceSlotFocusRestoreRetriesWhenIgnoringFieldEditor() async {
        let coordinator = TerminalFocusCoordinator(
            maxAttempts: 4,
            retryDelayNanoseconds: 1_000_000,
            isApplicationActive: { true },
            shouldAvoidStealingKeyboardFocus: { true }
        )
        let restored = expectation(description: "restored focus")
        var restoreAttempts = 0

        coordinator.scheduleSelectedWorkspaceSlotFocusRestore(avoidStealingKeyboardFocus: false) {
            restoreAttempts += 1
            let didRestore = restoreAttempts == 3
            if didRestore {
                restored.fulfill()
            }
            return didRestore
        }

        await fulfillment(of: [restored], timeout: 1.0)
        XCTAssertEqual(restoreAttempts, 3)
    }

    func testScheduleSelectedWorkspaceSlotFocusRestoreCancelsPreviousTask() async {
        let coordinator = TerminalFocusCoordinator(
            maxAttempts: 4,
            retryDelayNanoseconds: 50_000_000,
            isApplicationActive: { true },
            shouldAvoidStealingKeyboardFocus: { false }
        )
        let restored = expectation(description: "latest restore request wins")
        var firstRestoreAttempts = 0
        var secondRestoreAttempts = 0

        coordinator.scheduleSelectedWorkspaceSlotFocusRestore {
            firstRestoreAttempts += 1
            return false
        }

        try? await Task.sleep(nanoseconds: 5_000_000)

        coordinator.scheduleSelectedWorkspaceSlotFocusRestore {
            secondRestoreAttempts += 1
            restored.fulfill()
            return true
        }

        await fulfillment(of: [restored], timeout: 1.0)
        try? await Task.sleep(nanoseconds: 70_000_000)

        XCTAssertLessThanOrEqual(firstRestoreAttempts, 1)
        XCTAssertEqual(secondRestoreAttempts, 1)
    }
}
