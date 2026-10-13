import Foundation
import RemoteProtocol
import ToasttyMobileDomain

/// One entry in a conversation's panel menu, titled as its workspace page
/// row is.
struct ToasttyConversationPanel: Identifiable {
    var id: UUID { panel.panelID }
    let workspaceID: UUID
    let panel: RemoteWorkspacePanel
    let folderHint: String?

    var selection: ToasttyPreviewSelection {
        ToasttyPreviewSelection(
            target: .panel(workspaceID: workspaceID, panelID: panel.panelID),
            title: panel.title, id: panel.panelID
        )
    }
}

struct ToasttyConversationPanelSection: Identifiable {
    var id: UUID { workspaceID }
    let workspaceID: UUID
    let workspaceTitle: String
    let panels: [ToasttyConversationPanel]
}

enum ToasttyConversationPanels {
    /// The panels a conversation's toolbar menu lists. The first section is
    /// the conversation's own workspace, in its workspace page's order. Later
    /// sections hold only Scratchpads bound to this conversation that live in
    /// another workspace.
    static func sections(
        in snapshot: MobileHomeSnapshot, for conversationID: UUID
    ) -> [ToasttyConversationPanelSection] {
        guard let home = snapshot.workspaces.first(where: { workspace in
            workspace.conversations.contains { $0.id == conversationID }
        }) else { return [] }
        let bound = { (panel: RemoteWorkspacePanel) in
            panel.kind == "scratchpad" && panel.associatedConversationID?.rawValue == conversationID
        }
        var sections = [section(for: home) { _ in true }]
        for workspace in snapshot.workspaces where workspace.id != home.id {
            sections.append(section(for: workspace, including: bound))
        }
        return sections.filter { !$0.panels.isEmpty }
    }

    private static func section(
        for workspace: MobileWorkspace, including include: (RemoteWorkspacePanel) -> Bool
    ) -> ToasttyConversationPanelSection {
        // Folder hints come from the whole workspace so titles read as they
        // do on its page.
        let sorted = ToasttyWorkspacePanels.sorted(workspace.panels)
        let hints = ToasttyWorkspacePanels.folderHints(sorted)
        return ToasttyConversationPanelSection(
            workspaceID: workspace.id,
            workspaceTitle: workspace.title,
            panels: sorted.filter(include).map {
                ToasttyConversationPanel(workspaceID: workspace.id, panel: $0, folderHint: hints[$0.panelID])
            }
        )
    }
}

enum ToasttySessionScratchpads {
    static func conversation(
        in snapshot: MobileHomeSnapshot, workspaceID: UUID, panelID: UUID
    ) -> MobileConversation? {
        guard let panel = snapshot.workspaces.first(where: { $0.id == workspaceID })?
            .panels.first(where: { $0.panelID == panelID }),
              panel.kind == "scratchpad", let id = panel.associatedConversationID?.rawValue else { return nil }
        return snapshot.workspaces.lazy.flatMap(\.conversations).first { $0.id == id }
    }
}
