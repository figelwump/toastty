import AppKit
import WebKit

@MainActor
func toasttyResponderUsesReservedTextInput(_ responder: NSResponder?) -> Bool {
    guard responder is NSTextInputClient else {
        return false
    }

    // The embedded terminal participates in AppKit IME composition, but Toastty
    // should still treat it like a terminal for app-owned shortcuts and find.
    return responder is TerminalHostView == false
}

@MainActor
func toasttyResponderUsesReservedClosePanelShortcut(_ responder: NSResponder?) -> Bool {
    guard toasttyResponderUsesReservedTextInput(responder) else {
        return false
    }

    // WebKit-backed browser panels host text-input-capable responder views
    // inside the page. Cmd+W should still close the panel rather than falling
    // through to AppKit's native window-close path.
    return toasttyResponderBelongsToWebView(responder) == false
}

@MainActor
private func toasttyResponderBelongsToWebView(_ responder: NSResponder?) -> Bool {
    if responder is WKWebView {
        return true
    }

    if let view = responder as? NSView,
       toasttyViewHasWebViewAncestor(view) {
        return true
    }

    var currentResponder = responder?.nextResponder
    while let responder = currentResponder {
        if responder is WKWebView {
            return true
        }
        if let view = responder as? NSView,
           toasttyViewHasWebViewAncestor(view) {
            return true
        }
        currentResponder = responder.nextResponder
    }

    return false
}

@MainActor
private func toasttyViewHasWebViewAncestor(_ view: NSView) -> Bool {
    var currentView: NSView? = view
    while let view = currentView {
        if view is WKWebView {
            return true
        }
        currentView = view.superview
    }
    return false
}
