#if TOASTTY_HAS_GHOSTTY_KIT
import CoreState
import Foundation
import GhosttyKit

enum GhosttySurfaceSemanticState {
    static func promptState(for surface: ghostty_surface_t?) -> TerminalPromptState {
        guard let surface else {
            return .unavailable
        }

        return promptState(
            surfaceAvailable: true,
            processExited: ghostty_surface_process_exited(surface),
            isAtPrompt: ghostty_surface_is_at_prompt(surface)
        )
    }

    static func closeConfirmationAssessment(for surface: ghostty_surface_t?) -> TerminalCloseConfirmationAssessment? {
        guard let surface else {
            return nil
        }

        return closeConfirmationAssessment(
            surfaceAvailable: true,
            processExited: ghostty_surface_process_exited(surface),
            needsConfirmQuit: ghostty_surface_needs_confirm_quit(surface)
        )
    }

    static func promptState(
        surfaceAvailable: Bool,
        processExited: Bool,
        isAtPrompt: Bool
    ) -> TerminalPromptState {
        guard surfaceAvailable else {
            return .unavailable
        }
        if processExited {
            return .exited
        }
        return isAtPrompt ? .idleAtPrompt : .busy
    }

    static func closeConfirmationAssessment(
        surfaceAvailable: Bool,
        processExited: Bool,
        needsConfirmQuit: Bool
    ) -> TerminalCloseConfirmationAssessment? {
        guard surfaceAvailable else {
            return nil
        }
        if processExited {
            return TerminalCloseConfirmationAssessment(requiresConfirmation: false)
        }
        return TerminalCloseConfirmationAssessment(requiresConfirmation: needsConfirmQuit)
    }
}
#endif
