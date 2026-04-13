#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
import CoreState
import XCTest

final class GhosttySurfaceSemanticStateTests: XCTestCase {
    func testPromptStateReturnsUnavailableWithoutSurface() {
        XCTAssertEqual(
            GhosttySurfaceSemanticState.promptState(
                surfaceAvailable: false,
                processExited: false,
                isAtPrompt: false
            ),
            .unavailable
        )
    }

    func testPromptStateReturnsExitedBeforePromptState() {
        XCTAssertEqual(
            GhosttySurfaceSemanticState.promptState(
                surfaceAvailable: true,
                processExited: true,
                isAtPrompt: true
            ),
            .exited
        )
    }

    func testPromptStateReturnsIdleAtPrompt() {
        XCTAssertEqual(
            GhosttySurfaceSemanticState.promptState(
                surfaceAvailable: true,
                processExited: false,
                isAtPrompt: true
            ),
            .idleAtPrompt
        )
    }

    func testPromptStateReturnsBusyWhenNotAtPrompt() {
        XCTAssertEqual(
            GhosttySurfaceSemanticState.promptState(
                surfaceAvailable: true,
                processExited: false,
                isAtPrompt: false
            ),
            .busy
        )
    }

    func testCloseConfirmationAssessmentReturnsNilWithoutSurface() {
        XCTAssertNil(
            GhosttySurfaceSemanticState.closeConfirmationAssessment(
                surfaceAvailable: false,
                processExited: false,
                needsConfirmQuit: true
            )
        )
    }

    func testCloseConfirmationAssessmentSkipsExitedSurface() {
        XCTAssertEqual(
            GhosttySurfaceSemanticState.closeConfirmationAssessment(
                surfaceAvailable: true,
                processExited: true,
                needsConfirmQuit: true
            ),
            TerminalCloseConfirmationAssessment(requiresConfirmation: false)
        )
    }

    func testCloseConfirmationAssessmentUsesGhosttyNeedsConfirmQuitSignal() {
        XCTAssertEqual(
            GhosttySurfaceSemanticState.closeConfirmationAssessment(
                surfaceAvailable: true,
                processExited: false,
                needsConfirmQuit: true
            ),
            TerminalCloseConfirmationAssessment(requiresConfirmation: true)
        )
        XCTAssertEqual(
            GhosttySurfaceSemanticState.closeConfirmationAssessment(
                surfaceAvailable: true,
                processExited: false,
                needsConfirmQuit: false
            ),
            TerminalCloseConfirmationAssessment(requiresConfirmation: false)
        )
    }
}
#endif
