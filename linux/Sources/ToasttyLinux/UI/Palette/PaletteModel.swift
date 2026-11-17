import CoreState
import Foundation

public struct PaletteItem: Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let keywords: [String]
    public let accelerator: String?

    public init(id: String, title: String, subtitle: String? = nil, keywords: [String] = [], accelerator: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.accelerator = accelerator
    }
}

/// Command palette catalog and ranking. Ranking matches the macOS palette
/// (`CommandPaletteViewModel`): title matches outrank keyword matches, then
/// fuzzy score, then catalog order; an empty query keeps catalog order.
public enum PaletteModel {
    public static let workspacePrefix = "palette.workspace:"

    public static func catalog(state: AppState, windowID: UUID) -> [PaletteItem] {
        var items: [PaletteItem] = []
        for binding in LinuxCommandTable.all where binding.inPalette && binding.scope != .terminal {
            items.append(PaletteItem(
                id: binding.id,
                title: dynamicTitle(binding, state: state, windowID: windowID),
                keywords: binding.keywords,
                accelerator: binding.primaryAccelerator
            ))
        }
        if let window = state.window(id: windowID) {
            for (index, workspaceID) in window.workspaceIDs.enumerated() {
                guard let workspace = state.workspacesByID[workspaceID] else { continue }
                items.append(PaletteItem(
                    id: workspacePrefix + workspaceID.uuidString,
                    title: "Go to Workspace: \(workspace.title)",
                    subtitle: workspace.selectedTabDisplayTitle,
                    keywords: ["workspace", "switch", "go"],
                    accelerator: index < 9 ? "<Control><Alt>\(index + 1)" : nil
                ))
            }
        }
        return items
    }

    /// Toggle commands read as the action they will take, like macOS.
    static func dynamicTitle(_ binding: LinuxCommandBinding, state: AppState, windowID: UUID) -> String {
        let selection = state.workspaceSelection(in: windowID)
        switch binding.id {
        case "window.toggle-sidebar":
            return (state.window(id: windowID)?.sidebarVisible ?? true) ? "Hide Sidebar" : "Show Sidebar"
        case "window.toggle-right-panel":
            return (selection?.workspace.rightAuxPanel.isVisible ?? false) ? "Hide Right Panel" : "Show Right Panel"
        case "panel.focus-mode.toggle":
            return (selection?.workspace.focusedPanelModeActive ?? false) ? "Restore Layout" : "Focus Panel"
        case "terminal.agent-reads.toggle":
            if let tab = selection?.workspace.selectedTab, let panelID = tab.resolvedFocusedPanelID,
               case .terminal(let terminal)? = tab.panels[panelID], terminal.allowsAgentReads == false {
                return "Allow Agents to Read Terminal"
            }
            return binding.title
        default:
            return binding.title
        }
    }

    public static func filter(_ items: [PaletteItem], query: String) -> [PaletteItem] {
        let normalized = query.normalizedPaletteQuery
        guard normalized.isEmpty == false else { return items }

        struct Ranked {
            let item: PaletteItem
            let priority: Int
            let score: Int
            let index: Int
        }
        let ranked: [Ranked] = items.enumerated().compactMap { index, item in
            if let match = FuzzyScorer.match(query: normalized, candidate: item.title) {
                return Ranked(item: item, priority: 1, score: match.score, index: index)
            }
            let keywordScore = item.keywords.compactMap { FuzzyScorer.match(query: normalized, candidate: $0)?.score }.max()
            if let keywordScore {
                return Ranked(item: item, priority: 0, score: keywordScore, index: index)
            }
            return nil
        }
        return ranked.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.index < rhs.index
        }.map(\.item)
    }
}
