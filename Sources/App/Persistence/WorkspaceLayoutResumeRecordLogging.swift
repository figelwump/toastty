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

    private var managedAgentResumeRecordEntries: [ManagedAgentResumeRecordLogEntry] {
        workspacesByID.flatMap { workspaceEntry in
            workspaceEntry.value.tabsByID.flatMap { tabEntry in
                tabEntry.value.panels.compactMap { panelEntry -> ManagedAgentResumeRecordLogEntry? in
                    guard case .terminal(let terminalSnapshot) = panelEntry.value,
                          let resumeRecord = terminalSnapshot.resumeRecord else {
                        return nil
                    }
                    return ManagedAgentResumeRecordLogEntry(
                        panelID: panelEntry.key,
                        agent: resumeRecord.agent
                    )
                }
            }
        }
        .sorted { lhs, rhs in
            lhs.panelID.uuidString < rhs.panelID.uuidString
        }
    }
}

private struct ManagedAgentResumeRecordLogEntry {
    var panelID: UUID
    var agent: AgentKind
}
