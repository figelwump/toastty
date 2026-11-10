import CoreState
import Foundation
import RemoteProtocol

/// Fake managed-agent sessions for visual checks of the sidebar session
/// rows before `SessionRuntimeStore` is wired (`TOASTTY_LINUX_DEMO_SESSIONS=1`).
/// Each terminal panel past the first in a workspace gets a session with a
/// rotating status.
@MainActor
public final class DemoSessionSource: LinuxSessionSource {
    private weak var store: (any LinuxStoreBinding)?
    private var flagged: Set<String> = []
    private var observers: [UUID: @MainActor () -> Void] = [:]

    public init() {}

    public func attach(to store: any LinuxStoreBinding) {
        self.store = store
    }

    public func sessions(workspaceID: UUID) -> [WorkspaceSessionStatus] {
        guard let workspace = store?.state.workspacesByID[workspaceID] else { return [] }
        let kinds: [(AgentKind, SessionStatusKind, String)] = [
            (.claude, .working, "Refactoring the split renderer"),
            (.codex, .needsApproval, "Wants to run swift test"),
            (.claude, .ready, "Finished: sidebar cards"),
            (.codex, .error, "Build failed in CGtkShim"),
            (.claude, .idle, ""),
        ]
        var result: [WorkspaceSessionStatus] = []
        var index = 0
        for tab in workspace.orderedTabs {
            for slot in tab.layoutTree.allSlotInfos {
                guard case .terminal = tab.panels[slot.panelID] else { continue }
                let kind = kinds[index % kinds.count]
                index += 1
                result.append(WorkspaceSessionStatus(
                    sessionID: "demo-\(slot.panelID.uuidString)",
                    panelID: slot.panelID,
                    workspaceID: workspaceID,
                    agent: kind.0,
                    status: SessionStatus(kind: kind.1, summary: kind.2),
                    cwd: nil,
                    updatedAt: Date(),
                    isActive: true
                ))
            }
        }
        return result
    }

    public func isFlaggedForLater(sessionID: String) -> Bool { flagged.contains(sessionID) }

    public func setFlaggedForLater(sessionID: String, flagged isFlagged: Bool) {
        if isFlagged { flagged.insert(sessionID) } else { flagged.remove(sessionID) }
        for observer in observers.values { observer() }
    }

    public func observe(_ handler: @escaping @MainActor () -> Void) -> LinuxObservation {
        let id = UUID()
        observers[id] = handler
        return LinuxObservation { [weak self] in
            MainActor.assumeIsolated { _ = self?.observers.removeValue(forKey: id) }
        }
    }
}
