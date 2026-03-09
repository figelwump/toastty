import CoreState
import Foundation

@MainActor
final class SessionRuntimeStore: ObservableObject {
    @Published private(set) var sessionRegistry = SessionRegistry()

    private var storeActionObserverToken: UUID?

    func bind(store: AppStore) {
        synchronize(with: store.state)

        guard storeActionObserverToken == nil else { return }
        storeActionObserverToken = store.addActionAppliedObserver { [weak self] _, _, nextState in
            self?.synchronize(with: nextState)
        }
    }

    func reset() {
        sessionRegistry = SessionRegistry()
    }

    func startSession(
        sessionID: String,
        agent: AgentKind,
        panelID: UUID,
        windowID: UUID,
        workspaceID: UUID,
        cwd: String?,
        repoRoot: String?,
        at now: Date
    ) {
        var nextRegistry = sessionRegistry
        nextRegistry.startSession(
            sessionID: sessionID,
            agent: agent,
            panelID: panelID,
            windowID: windowID,
            workspaceID: workspaceID,
            cwd: cwd,
            repoRoot: repoRoot,
            at: now
        )
        publish(nextRegistry)
    }

    func updateFiles(
        sessionID: String,
        files: [String],
        cwd: String?,
        repoRoot: String?,
        at now: Date
    ) {
        var nextRegistry = sessionRegistry
        nextRegistry.updateFiles(
            sessionID: sessionID,
            files: files,
            cwd: cwd,
            repoRoot: repoRoot,
            at: now
        )
        publish(nextRegistry)
    }

    func updateStatus(
        sessionID: String,
        status: SessionStatus,
        at now: Date
    ) {
        var nextRegistry = sessionRegistry
        nextRegistry.updateStatus(sessionID: sessionID, status: status, at: now)
        publish(nextRegistry)
    }

    func stopSession(sessionID: String, at now: Date) {
        var nextRegistry = sessionRegistry
        nextRegistry.stopSession(sessionID: sessionID, at: now)
        publish(nextRegistry)
    }

    func stopSessionForPanel(panelID: UUID, at now: Date) {
        var nextRegistry = sessionRegistry
        nextRegistry.stopSessionForPanel(panelID: panelID, at: now)
        publish(nextRegistry)
    }

    func workspaceStatuses(for workspaceID: UUID) -> [WorkspaceSessionStatus] {
        sessionRegistry.workspaceStatuses(for: workspaceID)
    }

    func panelStatus(for panelID: UUID) -> WorkspaceSessionStatus? {
        sessionRegistry.panelStatus(for: panelID)
    }

    private func synchronize(with state: AppState, now: Date = Date()) {
        var nextRegistry = sessionRegistry

        for record in Array(nextRegistry.sessionsByID.values) where record.isActive {
            guard let location = Self.locatePanel(record.panelID, in: state) else {
                nextRegistry.stopSession(sessionID: record.sessionID, at: now)
                continue
            }
            if record.windowID != location.windowID || record.workspaceID != location.workspaceID {
                nextRegistry.updatePanelLocation(
                    panelID: record.panelID,
                    windowID: location.windowID,
                    workspaceID: location.workspaceID,
                    at: now
                )
            }
        }

        publish(nextRegistry)
    }

    private func publish(_ nextRegistry: SessionRegistry) {
        guard nextRegistry != sessionRegistry else { return }
        sessionRegistry = nextRegistry
    }

    private static func locatePanel(
        _ panelID: UUID,
        in state: AppState
    ) -> (windowID: UUID, workspaceID: UUID)? {
        for window in state.windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = state.workspacesByID[workspaceID] else { continue }
                if workspace.panels[panelID] != nil {
                    return (window.id, workspaceID)
                }
            }
        }
        return nil
    }
}

extension SessionRuntimeStore: TerminalSessionLifecycleTracking {
    func stopSessionForPanelIfOlderThan(
        panelID: UUID,
        minimumRuntime: TimeInterval,
        at now: Date
    ) -> Bool {
        guard let record = sessionRegistry.activeSession(for: panelID),
              now.timeIntervalSince(record.startedAt) >= minimumRuntime else {
            return false
        }

        stopSessionForPanel(panelID: panelID, at: now)
        return true
    }
}
