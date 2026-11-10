import Foundation

@MainActor
enum TerminalInputDeliveryResult: Equatable {
    case delivered
    case unavailable
    /// Text may have reached the surface, but submission did not complete.
    /// Retrying could append or submit twice.
    case uncertain
}

@MainActor
struct TerminalAutomationInputDelivery {
    let focusPolicy: TerminalInputFocusPolicy
    let focusHostViewIfNeeded: () -> Bool
    let sendText: (String) -> Void
    let sendSubmit: () -> Bool
    let logFocusFailure: () -> Void

    @discardableResult
    func deliver(text: String, submit: Bool) -> Bool {
        deliverResult(text: text, submit: submit) == .delivered
    }

    func deliverResult(text: String, submit: Bool) -> TerminalInputDeliveryResult {
        if focusPolicy == .focusTarget {
            guard focusHostViewIfNeeded() else {
                logFocusFailure()
                return .unavailable
            }
        }

        let sentText = text.isEmpty == false
        if text.isEmpty == false {
            sendText(text)
        }

        if submit {
            guard sendSubmit() else {
                return sentText ? .uncertain : .unavailable
            }
        }

        return .delivered
    }
}
