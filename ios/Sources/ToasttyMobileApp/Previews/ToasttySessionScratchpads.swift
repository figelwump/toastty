import Foundation
import RemoteProtocol
import ToasttyMobileDomain

struct ToasttySessionScratchpad: Identifiable {
    var id: UUID { panel.panelID }
    let workspaceID: UUID
    let workspaceTitle: String
    let panel: RemoteWorkspacePanel

    var selection: ToasttyPreviewSelection {
        ToasttyPreviewSelection(
            target: .panel(workspaceID: workspaceID, panelID: panel.panelID),
            title: panel.title, id: panel.panelID
        )
    }

    var menuTitle: String {
        "\(panel.title) (\(workspaceTitle) · \(panel.workspaceTabTitle))"
    }
}

enum ToasttySessionScratchpads {
    static func panels(in snapshot: MobileHomeSnapshot, for conversationID: UUID) -> [ToasttySessionScratchpad] {
        guard snapshot.workspaces.contains(where: { workspace in
            workspace.conversations.contains { $0.id == conversationID }
        }) else { return [] }
        return snapshot.workspaces.flatMap { workspace -> [ToasttySessionScratchpad] in
            workspace.panels.compactMap { panel -> ToasttySessionScratchpad? in
                guard panel.kind == "scratchpad",
                      panel.associatedConversationID?.rawValue == conversationID else { return nil }
                return ToasttySessionScratchpad(
                    workspaceID: workspace.id, workspaceTitle: workspace.title, panel: panel
                )
            }
        }
    }

    static func conversation(
        in snapshot: MobileHomeSnapshot, workspaceID: UUID, panelID: UUID
    ) -> MobileConversation? {
        guard let panel = snapshot.workspaces.first(where: { $0.id == workspaceID })?
            .panels.first(where: { $0.panelID == panelID }),
              panel.kind == "scratchpad", let id = panel.associatedConversationID?.rawValue else { return nil }
        return snapshot.workspaces.lazy.flatMap(\.conversations).first { $0.id == id }
    }
}
