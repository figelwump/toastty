import Foundation
import SwiftUI

extension FocusedValues {
    var toasttyCommandWindowID: UUID? {
        get { self[ToasttyCommandWindowIDKey.self] }
        set { self[ToasttyCommandWindowIDKey.self] = newValue }
    }
}

private struct ToasttyCommandWindowIDKey: FocusedValueKey {
    typealias Value = UUID
}

enum GettingStartedPanelNativeAction: String, Equatable {
    case openAgentProfiles = "open-agent-profiles"
    case openShortcutReference = "open-shortcut-reference"
}

enum GettingStartedPanelRequest: Equatable {
    case open(windowID: UUID, anchor: String?)
    case performNativeAction(panelID: UUID, action: GettingStartedPanelNativeAction)
}

extension Notification.Name {
    static let toasttyShowAgentGetStartedFlow = Notification.Name("ToasttyShowAgentGetStartedFlow")
}
