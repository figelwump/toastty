import CoreState
import Foundation

extension WorkspaceLayoutSnapshot {
    var managedAgentResumeRecordCount: Int {
        managedAgentResumeRecordEntries.count
    }

    func managedAgentResumeRecordSummary(limit: Int = 8) -> String {
        let entries = managedAgentResumeRecordEntries
        guard entries.isEmpty == false else { return "none" }

        let prefix = entries.prefix(limit).map { entry in
            "\(entry.panelID.uuidString):\(entry.agent.rawValue)"
        }
        let suffix = entries.count > limit ? ",+\(entries.count - limit)" : ""
        return prefix.joined(separator: ",") + suffix
    }

    var managedAgentResumeRecordLogEntries: [WorkspaceLayoutPanelLogEntry] {
        panelLogEntries
            .filter { $0.resumeRecord != nil }
            .sorted { lhs, rhs in
                lhs.panelID.uuidString < rhs.panelID.uuidString
            }
    }

    var tabLogEntries: [WorkspaceLayoutTabLogEntry] {
        orderedWorkspaceLogContexts().flatMap { context in
            context.workspace.tabIDs.enumerated().compactMap { tabOffset, tabID in
                guard let tab = context.workspace.tabsByID[tabID] else { return nil }
                return WorkspaceLayoutTabLogEntry(
                    windowID: context.windowID,
                    windowSelected: context.windowSelected,
                    workspaceID: context.workspace.id,
                    workspaceTitle: context.workspace.title,
                    workspaceIndex: context.workspaceIndex,
                    workspaceSelected: context.workspaceSelected,
                    tabID: tab.id,
                    tabIndex: tabOffset,
                    tabSelected: context.workspace.resolvedSelectedTabID == tab.id,
                    panelCount: tab.panels.count,
                    terminalPanelCount: tab.terminalPanelCount,
                    customTitle: tab.customTitle
                )
            }
        }
    }

    var panelLogEntries: [WorkspaceLayoutPanelLogEntry] {
        orderedWorkspaceLogContexts().flatMap { context in
            context.workspace.tabIDs.enumerated().flatMap { tabOffset, tabID in
                guard let tab = context.workspace.tabsByID[tabID] else {
                    return [WorkspaceLayoutPanelLogEntry]()
                }
                let tabSelected = context.workspace.resolvedSelectedTabID == tab.id
                var entries: [WorkspaceLayoutPanelLogEntry] = []
                var seenPanelIDs = Set<UUID>()

                for (panelOffset, slot) in tab.layoutTree.allSlotInfos.enumerated() {
                    guard let panel = tab.panels[slot.panelID] else { continue }
                    seenPanelIDs.insert(slot.panelID)
                    entries.append(
                        WorkspaceLayoutPanelLogEntry(
                            windowID: context.windowID,
                            windowSelected: context.windowSelected,
                            workspaceID: context.workspace.id,
                            workspaceTitle: context.workspace.title,
                            workspaceIndex: context.workspaceIndex,
                            workspaceSelected: context.workspaceSelected,
                            tabID: tab.id,
                            tabIndex: tabOffset,
                            tabSelected: tabSelected,
                            panelID: slot.panelID,
                            panelIndex: panelOffset,
                            panelCount: tab.panels.count,
                            slotID: slot.slotID,
                            panel: panel
                        )
                    )
                }

                let extraPanelIDs = tab.panels.keys
                    .filter { seenPanelIDs.contains($0) == false }
                    .sorted { $0.uuidString < $1.uuidString }
                for panelID in extraPanelIDs {
                    guard let panel = tab.panels[panelID] else { continue }
                    entries.append(
                        WorkspaceLayoutPanelLogEntry(
                            windowID: context.windowID,
                            windowSelected: context.windowSelected,
                            workspaceID: context.workspace.id,
                            workspaceTitle: context.workspace.title,
                            workspaceIndex: context.workspaceIndex,
                            workspaceSelected: context.workspaceSelected,
                            tabID: tab.id,
                            tabIndex: tabOffset,
                            tabSelected: tabSelected,
                            panelID: panelID,
                            panelIndex: entries.count,
                            panelCount: tab.panels.count,
                            slotID: nil,
                            panel: panel
                        )
                    )
                }

                return entries
            }
        }
    }

    func panelLogEntry(panelID: UUID) -> WorkspaceLayoutPanelLogEntry? {
        panelLogEntries.first { $0.panelID == panelID }
    }

    private var managedAgentResumeRecordEntries: [ManagedAgentResumeRecordLogEntry] {
        managedAgentResumeRecordLogEntries.compactMap { entry in
            guard let resumeRecord = entry.resumeRecord else { return nil }
            return ManagedAgentResumeRecordLogEntry(
                panelID: entry.panelID,
                agent: resumeRecord.agent
            )
        }
    }

    private func orderedWorkspaceLogContexts() -> [WorkspaceLayoutWorkspaceLogContext] {
        var contexts: [WorkspaceLayoutWorkspaceLogContext] = []
        var seenWorkspaceIDs = Set<UUID>()

        for window in windows {
            let selectedWorkspaceID = window.selectedWorkspaceID ?? window.workspaceIDs.first
            for (workspaceOffset, workspaceID) in window.workspaceIDs.enumerated() {
                guard let workspace = workspacesByID[workspaceID] else { continue }
                seenWorkspaceIDs.insert(workspaceID)
                contexts.append(
                    WorkspaceLayoutWorkspaceLogContext(
                        windowID: window.id,
                        windowSelected: selectedWindowID == window.id,
                        workspace: workspace,
                        workspaceIndex: workspaceOffset,
                        workspaceSelected: selectedWorkspaceID == workspaceID
                    )
                )
            }
        }

        let orphanWorkspaceIDs = workspacesByID.keys
            .filter { seenWorkspaceIDs.contains($0) == false }
            .sorted { $0.uuidString < $1.uuidString }
        for (workspaceOffset, workspaceID) in orphanWorkspaceIDs.enumerated() {
            guard let workspace = workspacesByID[workspaceID] else { continue }
            contexts.append(
                WorkspaceLayoutWorkspaceLogContext(
                    windowID: nil,
                    windowSelected: false,
                    workspace: workspace,
                    workspaceIndex: workspaceOffset,
                    workspaceSelected: false
                )
            )
        }

        return contexts
    }
}

struct WorkspaceLayoutTabLogEntry: Equatable {
    let windowID: UUID?
    let windowSelected: Bool
    let workspaceID: UUID
    let workspaceTitle: String
    let workspaceIndex: Int
    let workspaceSelected: Bool
    let tabID: UUID
    let tabIndex: Int
    let tabSelected: Bool
    let panelCount: Int
    let terminalPanelCount: Int
    let customTitle: String?

    var locationKey: WorkspaceLayoutTabLocationKey {
        WorkspaceLayoutTabLocationKey(
            windowID: windowID,
            workspaceID: workspaceID,
            tabIndex: tabIndex
        )
    }

    var metadata: [String: String] {
        var metadata = [
            "window_id": windowID?.uuidString ?? "none",
            "window_selected": windowSelected ? "true" : "false",
            "workspace_id": workspaceID.uuidString,
            "workspace_title": workspaceTitle,
            "workspace_index": String(workspaceIndex),
            "workspace_selected": workspaceSelected ? "true" : "false",
            "tab_id": tabID.uuidString,
            "tab_index": String(tabIndex),
            "tab_selected": tabSelected ? "true" : "false",
            "panel_count": String(panelCount),
            "terminal_panel_count": String(terminalPanelCount),
        ]
        if let customTitle {
            metadata["tab_custom_title"] = customTitle
        }
        return metadata
    }

    func metadata(prefix: String) -> [String: String] {
        Self.prefixed(metadata, prefix: prefix)
    }

    private static func prefixed(_ metadata: [String: String], prefix: String) -> [String: String] {
        metadata.reduce(into: [String: String]()) { result, entry in
            result["\(prefix)\(entry.key)"] = entry.value
        }
    }
}

struct WorkspaceLayoutPanelLogEntry: Equatable {
    let windowID: UUID?
    let windowSelected: Bool
    let workspaceID: UUID
    let workspaceTitle: String
    let workspaceIndex: Int
    let workspaceSelected: Bool
    let tabID: UUID
    let tabIndex: Int
    let tabSelected: Bool
    let panelID: UUID
    let panelIndex: Int
    let panelCount: Int
    let slotID: UUID?
    let panelKind: String
    let terminalLaunchWorkingDirectory: String?
    let resumeRecord: ManagedAgentResumeRecord?

    init(
        windowID: UUID?,
        windowSelected: Bool,
        workspaceID: UUID,
        workspaceTitle: String,
        workspaceIndex: Int,
        workspaceSelected: Bool,
        tabID: UUID,
        tabIndex: Int,
        tabSelected: Bool,
        panelID: UUID,
        panelIndex: Int,
        panelCount: Int,
        slotID: UUID?,
        panel: WorkspaceLayoutPanelSnapshot
    ) {
        self.windowID = windowID
        self.windowSelected = windowSelected
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        self.workspaceIndex = workspaceIndex
        self.workspaceSelected = workspaceSelected
        self.tabID = tabID
        self.tabIndex = tabIndex
        self.tabSelected = tabSelected
        self.panelID = panelID
        self.panelIndex = panelIndex
        self.panelCount = panelCount
        self.slotID = slotID

        switch panel {
        case .terminal(let terminalSnapshot):
            panelKind = "terminal"
            terminalLaunchWorkingDirectory = terminalSnapshot.launchWorkingDirectory
            resumeRecord = terminalSnapshot.resumeRecord
        case .web:
            panelKind = "web"
            terminalLaunchWorkingDirectory = nil
            resumeRecord = nil
        }
    }

    var locationKey: WorkspaceLayoutPanelLocationKey {
        WorkspaceLayoutPanelLocationKey(
            windowID: windowID,
            workspaceID: workspaceID,
            tabID: tabID,
            slotID: slotID,
            panelIndex: panelIndex
        )
    }

    var metadata: [String: String] {
        var metadata = [
            "window_id": windowID?.uuidString ?? "none",
            "window_selected": windowSelected ? "true" : "false",
            "workspace_id": workspaceID.uuidString,
            "workspace_title": workspaceTitle,
            "workspace_index": String(workspaceIndex),
            "workspace_selected": workspaceSelected ? "true" : "false",
            "tab_id": tabID.uuidString,
            "tab_index": String(tabIndex),
            "tab_selected": tabSelected ? "true" : "false",
            "panel_id": panelID.uuidString,
            "panel_index": String(panelIndex),
            "panel_count": String(panelCount),
            "slot_id": slotID?.uuidString ?? "none",
            "panel_kind": panelKind,
        ]
        if let terminalLaunchWorkingDirectory {
            metadata["terminal_launch_working_directory"] = terminalLaunchWorkingDirectory
        }
        if let resumeRecord {
            metadata.merge(resumeRecord.metadata) { _, new in new }
        } else {
            metadata["resume_record_present"] = "false"
        }
        return metadata
    }

    func metadata(prefix: String) -> [String: String] {
        metadata.reduce(into: [String: String]()) { result, entry in
            result["\(prefix)\(entry.key)"] = entry.value
        }
    }
}

private struct WorkspaceLayoutWorkspaceLogContext {
    let windowID: UUID?
    let windowSelected: Bool
    let workspace: WorkspaceLayoutWorkspaceSnapshot
    let workspaceIndex: Int
    let workspaceSelected: Bool
}

struct WorkspaceLayoutTabLocationKey: Equatable {
    let windowID: UUID?
    let workspaceID: UUID
    let tabIndex: Int
}

struct WorkspaceLayoutPanelLocationKey: Equatable {
    let windowID: UUID?
    let workspaceID: UUID
    let tabID: UUID
    let slotID: UUID?
    let panelIndex: Int
}

private struct ManagedAgentResumeRecordLogEntry {
    var panelID: UUID
    var agent: AgentKind
}

private extension WorkspaceLayoutTabSnapshot {
    var terminalPanelCount: Int {
        panels.values.reduce(0) { count, panel in
            guard case .terminal = panel else { return count }
            return count + 1
        }
    }
}

private extension ManagedAgentResumeRecord {
    var metadata: [String: String] {
        [
            "resume_record_present": "true",
            "agent": agent.rawValue,
            "native_session_id": nativeSessionID,
            "session_file_basename": (sessionFilePath as NSString).lastPathComponent,
            "cwd": cwd,
        ]
    }
}
