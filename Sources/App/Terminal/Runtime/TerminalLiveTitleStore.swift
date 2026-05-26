import CoreState
import Combine
import Foundation

@MainActor
final class TerminalLiveTitleModel: ObservableObject {
    let panelID: UUID
    @Published private(set) var title: String?

    init(panelID: UUID, title: String? = nil) {
        self.panelID = panelID
        self.title = title
    }

    func setTitle(_ title: String?) {
        guard self.title != title else { return }
        self.title = title
    }
}

@MainActor
final class TerminalLiveTitleStore {
    private var modelsByPanelID: [UUID: TerminalLiveTitleModel] = [:]

    func model(for panelID: UUID) -> TerminalLiveTitleModel {
        if let model = modelsByPanelID[panelID] {
            return model
        }
        let model = TerminalLiveTitleModel(panelID: panelID)
        modelsByPanelID[panelID] = model
        return model
    }

    func title(for panelID: UUID) -> String? {
        modelsByPanelID[panelID]?.title
    }

    func setTitle(_ title: String, for panelID: UUID) {
        model(for: panelID).setTitle(title)
    }

    func synchronizeLivePanels(_ livePanelIDs: Set<UUID>) {
        modelsByPanelID = modelsByPanelID.filter { panelID, _ in
            livePanelIDs.contains(panelID)
        }
    }

    func remove(panelID: UUID) {
        modelsByPanelID.removeValue(forKey: panelID)
    }
}

enum TerminalDisplayTitleResolver {
    static func terminalTitleSourcePanelID(for tab: WorkspaceTabState) -> UUID? {
        guard tab.customTitle == nil,
              let focusedPanelID = tab.resolvedFocusedPanelID,
              case .terminal = tab.panels[focusedPanelID] else {
            return nil
        }

        return focusedPanelID
    }

    static func panelHeaderTitle(
        panelState: PanelState,
        liveTerminalTitle: String?,
        panelSessionStatus: WorkspaceSessionStatus?
    ) -> String {
        switch panelState {
        case .terminal(let terminalState):
            if let liveTerminalTitle {
                return terminalDisplayTitle(terminalState: terminalState, liveTerminalTitle: liveTerminalTitle)
            }
            if let panelSessionStatus, panelSessionStatus.isActive {
                return panelSessionStatus.displayTitle
            }
            return terminalState.displayPanelLabel

        case .web(let webState):
            return webState.displayPanelLabel
        }
    }

    static func workspaceTabTitle(
        tab: WorkspaceTabState,
        liveTerminalTitle: String?
    ) -> String {
        guard let liveTerminalTitle else {
            return tab.displayTitle
        }
        guard let panelID = terminalTitleSourcePanelID(for: tab),
              case .terminal(let terminalState) = tab.panels[panelID] else {
            return tab.displayTitle
        }

        return terminalDisplayTitle(terminalState: terminalState, liveTerminalTitle: liveTerminalTitle)
    }

    private static func terminalDisplayTitle(
        terminalState: TerminalPanelState,
        liveTerminalTitle: String
    ) -> String {
        var displayState = terminalState
        displayState.title = liveTerminalTitle
        return displayState.displayPanelLabel
    }
}
