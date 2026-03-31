import AppKit

func toasttyResponderUsesReservedTextInput(_ responder: NSResponder?) -> Bool {
    guard responder is NSTextInputClient else {
        return false
    }

    // The embedded terminal participates in AppKit IME composition, but Toastty
    // should still treat it like a terminal for app-owned shortcuts and find.
    return responder is TerminalHostView == false
}
