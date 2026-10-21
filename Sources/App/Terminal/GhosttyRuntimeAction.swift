#if TOASTTY_HAS_GHOSTTY_KIT || os(Linux)
import CoreState
import Foundation

struct GhosttyRuntimeAction: Sendable {
    enum Intent: Sendable {
        case split(SlotSplitDirection)
        case focus(SlotFocusDirection)
        case resizeSplit(SplitResizeDirection, amount: Int)
        case equalizeSplits
        case toggleFocusedPanelMode
        case startSearch(needle: String)
        case endSearch
        case searchTotal(Int?)
        case searchSelected(Int?)
        case setTerminalTitle(String)
        case setTerminalCWD(String)
        case showChildExited(exitCode: Int)
        case commandFinished(exitCode: Int?)
        case programStatus(TerminalProgramStatusEvent)
        case desktopNotification(title: String, body: String)
    }

    let surfaceHandle: UInt?
    let intent: Intent

    var logIntentName: String {
        switch intent {
        case .split(let direction):
            return "split.\(direction.rawValue)"
        case .focus(let direction):
            return "focus.\(direction.rawValue)"
        case .resizeSplit(let direction, _):
            return "resize_split.\(direction.rawValue)"
        case .equalizeSplits:
            return "equalize_splits"
        case .toggleFocusedPanelMode:
            return "toggle_focused_panel_mode"
        case .startSearch:
            return "start_search"
        case .endSearch:
            return "end_search"
        case .searchTotal:
            return "search_total"
        case .searchSelected:
            return "search_selected"
        case .setTerminalTitle:
            return "set_terminal_title"
        case .setTerminalCWD:
            return "set_terminal_cwd"
        case .showChildExited:
            return "show_child_exited"
        case .commandFinished:
            return "command_finished"
        case .programStatus:
            return "program_status"
        case .desktopNotification:
            return "desktop_notification"
        }
    }
}
#endif
