import RemoteProtocol
import CoreState
import Foundation

struct ScratchpadAgentBindCandidate: Equatable, Identifiable {
    let sessionID: String
    let agent: AgentKind
    let panelID: UUID
    let label: String
    let isCurrent: Bool

    var id: String { sessionID }
}

enum ScratchpadAgentBindCandidateBuilder {
    static func candidates(
        workspaceTab: WorkspaceTabState,
        sessionRegistry: SessionRegistry,
        currentSessionID: String?
    ) -> [ScratchpadAgentBindCandidate] {
        let visiblePanelIDs = Set(workspaceTab.layoutTree.allSlotInfos.map(\.panelID))

        return sessionRegistry.sessionOrder.compactMap { sessionID in
            guard let record = sessionRegistry.activeSession(sessionID: sessionID),
                  record.agent != .processWatch,
                  visiblePanelIDs.contains(record.panelID),
                  workspaceTab.panels[record.panelID] != nil else {
                return nil
            }

            let isCurrent = record.sessionID == currentSessionID
            return ScratchpadAgentBindCandidate(
                sessionID: record.sessionID,
                agent: record.agent,
                panelID: record.panelID,
                label: candidateLabel(
                    for: record,
                    in: workspaceTab,
                    isCurrent: isCurrent
                ),
                isCurrent: isCurrent
            )
        }
    }

    private static func candidateLabel(
        for record: SessionRecord,
        in workspaceTab: WorkspaceTabState,
        isCurrent: Bool
    ) -> String {
        let baseLabel = normalized(record.displayTitleOverride) ?? record.agent.displayName
        if isCurrent {
            return "\(baseLabel) - current binding"
        }
        if let locationLabel = splitLocationLabel(for: record.panelID, in: workspaceTab.layoutTree) {
            return "\(baseLabel) - \(locationLabel)"
        }
        return baseLabel
    }

    private static func splitLocationLabel(for panelID: UUID, in node: LayoutNode) -> String? {
        splitLocationPath(for: panelID, in: node)?.last
    }

    private static func splitLocationPath(for panelID: UUID, in node: LayoutNode) -> [String]? {
        switch node {
        case .slot(_, let slotPanelID):
            return slotPanelID == panelID ? [] : nil
        case .split(_, let orientation, _, let first, let second):
            if let path = splitLocationPath(for: panelID, in: first) {
                return [orientation == .horizontal ? "left split" : "top split"] + path
            }
            if let path = splitLocationPath(for: panelID, in: second) {
                return [orientation == .horizontal ? "right split" : "bottom split"] + path
            }
            return nil
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
