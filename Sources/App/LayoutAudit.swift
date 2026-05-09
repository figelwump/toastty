import CoreState
import Foundation

struct AppActionSource: Equatable, Sendable {
    let name: String
    let detail: String?

    init(_ name: String, detail: String? = nil) {
        self.name = name
        self.detail = detail
    }

    static let unknown = AppActionSource("unknown")
    static let workspaceCloseConfirmation = AppActionSource("workspace_close_confirmation")

    static func command(_ detail: String) -> AppActionSource {
        AppActionSource("command", detail: detail)
    }

    static func ui(_ detail: String) -> AppActionSource {
        AppActionSource("ui", detail: detail)
    }

    static func automation(command: String, actionID: String? = nil) -> AppActionSource {
        if let actionID {
            return AppActionSource("automation", detail: "\(command):\(actionID)")
        }
        return AppActionSource("automation", detail: command)
    }

    static func appControl(actionID: String) -> AppActionSource {
        AppActionSource("app_control", detail: actionID)
    }

    var metadata: [String: String] {
        var values = ["source": name]
        if let detail {
            values["source_detail"] = detail
        }
        return values
    }
}

struct LayoutAuditSummary: Equatable, Sendable {
    let windowIDs: Set<UUID>
    let selectedWindowID: UUID?
    let workspaceIDs: Set<UUID>
    let panelIDs: Set<UUID>

    init(state: AppState) {
        windowIDs = Set(state.windows.map(\.id))
        selectedWindowID = state.selectedWindowID
        workspaceIDs = Set(state.workspacesByID.keys)
        panelIDs = state.workspacesByID.values.reduce(into: Set<UUID>()) { result, workspace in
            result.formUnion(workspace.allPanelsByID.keys)
        }
    }

    init(layout: WorkspaceLayoutSnapshot) {
        windowIDs = Set(layout.windows.map(\.id))
        selectedWindowID = layout.selectedWindowID
        workspaceIDs = Set(layout.workspacesByID.keys)
        panelIDs = layout.workspacesByID.values.reduce(into: Set<UUID>()) { result, workspace in
            for tab in workspace.orderedTabs {
                result.formUnion(tab.panels.keys)
                result.formUnion(tab.rightAuxPanel.panelIDs)
            }
        }
    }

    var windowCount: Int { windowIDs.count }
    var workspaceCount: Int { workspaceIDs.count }
    var panelCount: Int { panelIDs.count }
}

struct LayoutAuditDiff: Equatable, Sendable {
    let before: LayoutAuditSummary
    let after: LayoutAuditSummary

    var removedWindowIDs: Set<UUID> {
        before.windowIDs.subtracting(after.windowIDs)
    }

    var removedWorkspaceIDs: Set<UUID> {
        before.workspaceIDs.subtracting(after.workspaceIDs)
    }

    var removedPanelIDs: Set<UUID> {
        before.panelIDs.subtracting(after.panelIDs)
    }

    var didDropContainerLayout: Bool {
        removedWindowIDs.isEmpty == false ||
            removedWorkspaceIDs.isEmpty == false ||
            after.windowCount < before.windowCount ||
            after.workspaceCount < before.workspaceCount
    }

    var metadata: [String: String] {
        [
            "window_count_before": String(before.windowCount),
            "window_count_after": String(after.windowCount),
            "workspace_count_before": String(before.workspaceCount),
            "workspace_count_after": String(after.workspaceCount),
            "panel_count_before": String(before.panelCount),
            "panel_count_after": String(after.panelCount),
            "selected_window_id_before": before.selectedWindowID?.uuidString ?? "<none>",
            "selected_window_id_after": after.selectedWindowID?.uuidString ?? "<none>",
            "removed_window_ids": Self.commaSeparatedUUIDs(removedWindowIDs),
            "removed_workspace_ids": Self.commaSeparatedUUIDs(removedWorkspaceIDs),
            "removed_panel_ids": Self.commaSeparatedUUIDs(removedPanelIDs),
        ]
    }

    private static func commaSeparatedUUIDs(_ ids: Set<UUID>) -> String {
        guard ids.isEmpty == false else { return "<none>" }
        return ids
            .map(\.uuidString)
            .sorted()
            .joined(separator: ",")
    }
}

extension AppAction {
    var isDestructiveLayoutAction: Bool {
        switch self {
        case .closeWindow,
             .closeWorkspace,
             .closeWorkspaceTab,
             .closePanel,
             .closeRightAuxPanelTab:
            return true

        default:
            return false
        }
    }

    var layoutAuditTargetMetadata: [String: String] {
        switch self {
        case .closeWindow(let windowID):
            return ["target_window_id": windowID.uuidString]

        case .closeWorkspace(let workspaceID):
            return ["target_workspace_id": workspaceID.uuidString]

        case .closeWorkspaceTab(let workspaceID, let tabID):
            return [
                "target_workspace_id": workspaceID.uuidString,
                "target_tab_id": tabID.uuidString,
            ]

        case .closePanel(let panelID):
            return ["target_panel_id": panelID.uuidString]

        case .closeRightAuxPanelTab(let workspaceID, let tabID):
            return [
                "target_workspace_id": workspaceID.uuidString,
                "target_right_aux_tab_id": tabID.uuidString,
            ]

        default:
            return [:]
        }
    }
}
