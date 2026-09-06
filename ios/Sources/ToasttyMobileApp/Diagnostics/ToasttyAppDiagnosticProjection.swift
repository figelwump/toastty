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
            .sendEnqueued
        case .notEnqueued:
            .sendRejected
        }
    }

    static func events(
        from previous: SendReconciliationState,
        to state: SendReconciliationState
    ) -> [ToasttyConnectionDiagnosticEvent] {
        state.records.compactMap { record in
            let oldEvent = previous[record.clientRequestID].flatMap {
                deliveryEvent(for: $0.deliveryState)
            }
            guard let event = deliveryEvent(for: record.deliveryState), event != oldEvent else {
                return nil
            }
            return event
        }
    }

    private static func deliveryEvent(for state: SendDeliveryState) -> ToasttyConnectionDiagnosticEvent? {
        switch state {
        case .pending(.awaitingResponse): nil
        case .pending(.accepted), .pending(.duplicate), .confirmed: .sendAccepted
        case .rejected, .operationFailed: .sendRejected
        case .uncertain, .deliveryUnconfirmed: .sendUncertain
        }
    }

    private static func connectionEvent(
        for state: AppSessionState
    ) -> ToasttyConnectionDiagnosticEvent? {
        switch state {
        case .paired(.connecting):
            .streamConnecting
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
