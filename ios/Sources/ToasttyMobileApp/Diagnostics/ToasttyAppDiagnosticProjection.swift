import ToasttyMobileDomain

enum ToasttyAppDiagnosticProjection {
    static func events(
        from previousState: AppSessionState?,
        to state: AppSessionState
    ) -> [ToasttyConnectionDiagnosticEvent] {
        guard previousState != state else { return [] }

        var events: [ToasttyConnectionDiagnosticEvent] = []
        let wasPaired = previousState?.isPaired == true

        if state.isPaired, !wasPaired {
            events.append(.authSucceeded)
        } else if wasPaired, !state.isPaired {
            events.append(.authRevoked)
        } else if case .unpaired = state {
            events.append(.authRequired)
        }

        let previousConnectionEvent = previousState.flatMap(connectionEvent(for:))
        if let currentConnectionEvent = connectionEvent(for: state) {
            if currentConnectionEvent != previousConnectionEvent {
                events.append(currentConnectionEvent)
            }
        } else if wasPaired, !state.isPaired, previousConnectionEvent != .streamDisconnected {
            events.append(.streamDisconnected)
        }

        return events
    }

    static func event(for outcome: ConversationSendOutcome) -> ToasttyConnectionDiagnosticEvent {
        switch outcome {
        case .enqueued:
            .sendAccepted
        case .notEnqueued:
            .sendRejected
        }
    }

    private static func connectionEvent(
        for state: AppSessionState
    ) -> ToasttyConnectionDiagnosticEvent? {
        switch state {
        case .paired(.live):
            .streamConnected
        case .paired(.reconnecting):
            .streamReconnecting
        case .paired(.unreachable):
            .streamDisconnected
        case .restoring, .unpaired, .pairing, .paired(.authorizationDenied),
             .keychainLocked, .repairNeeded, .incompatible:
            nil
        }
    }
}
