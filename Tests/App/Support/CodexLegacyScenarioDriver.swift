import CoreState
import Foundation
@testable import ToasttyApp

enum CodexLegacySessionPanelPlacement {
    case focused
    case background
}

struct CodexLegacyScenarioSnapshot: Equatable {
    let recordStatus: SessionStatus?
    let recordIsActive: Bool?
    let workspaceStatus: SessionStatus?
    let workspaceProjection: SessionStatusProjection?
    let panelIsUnread: Bool
}

struct CodexLegacyNotificationEffect: Equatable, Sendable {
    let title: String
    let body: String
    let workspaceID: UUID
    let panelID: UUID
    let context: DesktopNotificationContext
}

@MainActor
final class CodexLegacyScenarioDriver {
    private let appStore: AppStore
    private let sessionStore: SessionRuntimeStore
    private let notificationRecorder = CodexLegacyNotificationRecorder()
    private let sessionID = "codex-legacy-characterization"
    private let windowID: UUID
    private let workspaceID: UUID
    private let sessionPanelID: UUID
    private let startedAt = Date(timeIntervalSince1970: 1_700_400_000)
    private var eventIndex = 1

    init(
        trackingSource: CodexStatusTrackingSource,
        applicationIsActive: Bool,
        sessionPanelPlacement: CodexLegacySessionPanelPlacement
    ) {
        let fixture = Self.makeAppState(sessionPanelPlacement: sessionPanelPlacement)
        windowID = fixture.windowID
        workspaceID = fixture.workspaceID
        sessionPanelID = fixture.sessionPanelID
        appStore = AppStore(state: fixture.state, persistTerminalFontPreference: false)

        let recorder = notificationRecorder
        sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    CodexLegacyNotificationEffect(
                        title: title,
                        body: body,
                        workspaceID: workspaceID,
                        panelID: panelID,
                        context: context
                    )
                )
            },
            isApplicationActive: { applicationIsActive }
        )
        sessionStore.bind(store: appStore)
        sessionStore.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: sessionPanelID,
            windowID: windowID,
            workspaceID: workspaceID,
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: trackingSource,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: sessionID,
            status: SessionStatus(
                kind: .working,
                summary: "Working",
                detail: "Root turn is running"
            ),
            at: nextEventDate()
        )
    }

    func recordRootTurnContext(
        threadID: String,
        turnID: String,
        prompt: String = "Characterize the root turn"
    ) {
        sessionStore.recordCodexRootTurnInput(
            sessionID: sessionID,
            fingerprint: CodexInputFingerprint.fingerprint(for: prompt),
            threadID: threadID,
            turnID: turnID
        )
    }

    func setStatus(_ status: SessionStatus) {
        sessionStore.updateStatus(
            sessionID: sessionID,
            status: status,
            at: nextEventDate()
        )
    }

    @discardableResult
    func sendHookEvent(
        name: String,
        threadID: String?,
        turnID: String?,
        status: SessionStatus?
    ) -> Bool {
        sessionStore.handleCodexHookEvent(
            sessionID: sessionID,
            event: CodexHookEvent(
                hookEventName: name,
                threadID: threadID,
                turnID: turnID,
                promptFingerprint: nil,
                status: status,
                nativeSessionID: threadID,
                sessionFilePath: nil,
                cwd: nil
            ),
            at: nextEventDate()
        )
    }

    @discardableResult
    func sendNotifyCompletion(
        threadID: String?,
        turnID: String?,
        detail: String
    ) -> Bool {
        sessionStore.handleCodexNotifyCompletion(
            sessionID: sessionID,
            completion: CodexNotifyCompletion(
                notificationType: "agent-turn-complete",
                threadID: threadID,
                turnID: turnID,
                lastInputMessageFingerprint: nil,
                inputMessageCount: 0,
                detail: detail
            ),
            at: nextEventDate()
        )
    }

    @discardableResult
    func sendSessionLogCompletion(
        threadID: String?,
        turnID: String?,
        detail: String
    ) -> Bool {
        sessionStore.handleCodexSessionLogCompletion(
            sessionID: sessionID,
            detail: detail,
            threadID: threadID,
            turnID: turnID,
            at: nextEventDate()
        )
    }

    func snapshot() -> CodexLegacyScenarioSnapshot {
        let record = sessionStore.sessionRegistry.sessionsByID[sessionID]
        let workspaceProjection = sessionStore.workspaceStatuses(
            for: workspaceID,
            at: startedAt.addingTimeInterval(TimeInterval(eventIndex))
        ).first { $0.sessionID == sessionID }
        let panelIsUnread = appStore.state.workspacesByID[workspaceID]?
            .unreadPanelIDs.contains(sessionPanelID) == true

        return CodexLegacyScenarioSnapshot(
            recordStatus: record?.status,
            recordIsActive: record?.isActive,
            workspaceStatus: workspaceProjection?.status,
            workspaceProjection: workspaceProjection?.projection,
            panelIsUnread: panelIsUnread
        )
    }

    func capturedEffects(
        waitingForNotificationCount expectedCount: Int? = nil
    ) async -> [CodexLegacyNotificationEffect] {
        if let expectedCount {
            let deadline = Date().addingTimeInterval(1)
            while await notificationRecorder.count() < expectedCount, Date() < deadline {
                await Task.yield()
            }
        } else {
            // Notification delivery is intentionally unstructured in the legacy
            // store. Let an already-enqueued delivery run before asserting that
            // the observable effect was suppressed.
            for _ in 0..<12 {
                await Task.yield()
            }
        }
        return await notificationRecorder.effects()
    }

    func reset() {
        sessionStore.reset()
        sessionStore.unbind()
    }

    private func nextEventDate() -> Date {
        defer { eventIndex += 1 }
        return startedAt.addingTimeInterval(TimeInterval(eventIndex))
    }

    private static func makeAppState(
        sessionPanelPlacement: CodexLegacySessionPanelPlacement
    ) -> (state: AppState, windowID: UUID, workspaceID: UUID, sessionPanelID: UUID) {
        let focusedPanelID = UUID()
        let backgroundPanelID = UUID()
        let workspaceID = UUID()
        let windowID = UUID()
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Characterization Workspace",
            layoutTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: UUID(), panelID: focusedPanelID),
                second: .slot(slotID: UUID(), panelID: backgroundPanelID)
            ),
            panels: [
                focusedPanelID: .terminal(
                    TerminalPanelState(title: "Focused Terminal", shell: "zsh", cwd: "/repo")
                ),
                backgroundPanelID: .terminal(
                    TerminalPanelState(title: "Background Terminal", shell: "zsh", cwd: "/repo")
                ),
            ],
            focusedPanelID: focusedPanelID
        )
        let window = WindowState(
            id: windowID,
            frame: CGRectCodable(x: 100, y: 100, width: 1200, height: 800),
            workspaceIDs: [workspaceID],
            selectedWorkspaceID: workspaceID
        )
        let sessionPanelID = switch sessionPanelPlacement {
        case .focused:
            focusedPanelID
        case .background:
            backgroundPanelID
        }

        return (
            AppState(
                windows: [window],
                workspacesByID: [workspaceID: workspace],
                selectedWindowID: windowID,
                configuredTerminalFontPoints: nil
            ),
            windowID,
            workspaceID,
            sessionPanelID
        )
    }
}

private actor CodexLegacyNotificationRecorder {
    private var recordedEffects: [CodexLegacyNotificationEffect] = []

    func record(_ effect: CodexLegacyNotificationEffect) {
        recordedEffects.append(effect)
    }

    func effects() -> [CodexLegacyNotificationEffect] {
        recordedEffects
    }

    func count() -> Int {
        recordedEffects.count
    }
}
