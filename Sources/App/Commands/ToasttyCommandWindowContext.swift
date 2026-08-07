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
    case openSkillsManagement = "open-skills-management"
    case openShortcutReference = "open-shortcut-reference"
}

enum GettingStartedPanelRequest: Equatable {
    case open(windowID: UUID, anchor: String?)
    case performNativeAction(panelID: UUID, action: GettingStartedPanelNativeAction)
}

extension Notification.Name {
    static let toasttyShowAgentGetStartedFlow = Notification.Name("ToasttyShowAgentGetStartedFlow")
    static let toasttyShowSkillsManagement = Notification.Name("ToasttyShowSkillsManagement")
    static let toasttyManagedAgentSkillsProvisioned = Notification.Name(
        "dev.toastty.managed-agent-skills-provisioned"
    )
    static let toasttyManagedCodexSkillsUnavailable = Notification.Name(
        "dev.toastty.managed-codex-skills-unavailable"
    )
}
