import CoreState
import Foundation

enum PanelHeaderUnreadReason: Equatable {
    case bell
    case needsApproval
    case ready
    case error
}

enum PanelHeaderTreatment: Equatable {
    case neutral
    case focused
    case unread(PanelHeaderUnreadReason)
}

struct PanelHeaderAppearance: Equatable {
    let treatment: PanelHeaderTreatment
    let indicatorState: SessionStatusIndicatorState

    var showsTintedFill: Bool {
        if case .unread = treatment {
            return true
        }
        return false
    }

    var dividerHeight: Double {
        showsTintedFill ? 2 : 1
    }

    static func resolve(
        isFocused: Bool,
        hasUnreadNotification: Bool,
        sessionStatusKind: SessionStatusKind?
    ) -> Self {
        if let unreadReason = unreadReason(
            hasUnreadNotification: hasUnreadNotification,
            sessionStatusKind: sessionStatusKind
        ) {
            // Keep the unread treatment visible during the short auto-read
            // window so focused notifications still register visually.
            return Self(
                treatment: .unread(unreadReason),
                indicatorState: .dot
            )
        }

        let treatment: PanelHeaderTreatment = isFocused ? .focused : .neutral
        let indicatorState: SessionStatusIndicatorState = sessionStatusKind == .working ? .spinner : .hidden
        return Self(treatment: treatment, indicatorState: indicatorState)
    }

    private static func unreadReason(
        hasUnreadNotification: Bool,
        sessionStatusKind: SessionStatusKind?
    ) -> PanelHeaderUnreadReason? {
        guard hasUnreadNotification else {
            return nil
        }

        switch sessionStatusKind {
        case .needsApproval:
            return .needsApproval
        case .ready:
            return .ready
        case .error:
            return .error
        case .idle, .working, nil:
            return .bell
        }
    }
}
