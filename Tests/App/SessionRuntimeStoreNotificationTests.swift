import Combine
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

extension SessionRuntimeStoreTests {
    @Test
    func updateStatusSendsNotificationForManagedUnfocusedPanel() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-managed",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-managed",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished"),
            at: startedAt.addingTimeInterval(1)
        )

        await waitUntilNotificationCount(recorder, expectedCount: 1)

        let notifications = await recorder.notifications()
        let notification = try #require(notifications.first)
        #expect(notification.title == "Codex is ready")
        #expect(notification.body == "Finished")
        #expect(notification.workspaceID == selection.workspaceID)
        #expect(notification.panelID == backgroundPanelID)
        #expect(notification.context.workspaceTitle == "Workspace 1")

        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [backgroundPanelID])
    }

    @Test
    func readyStatusWithOutstandingSubagentActivitySuppressesNotificationAndUnread() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            },
            isApplicationActive: { false }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_010)

        sessionStore.startSession(
            sessionID: "sess-subagent-waiting",
            agent: .claude,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        #expect(sessionStore.updateBackgroundActivity(
            sessionID: "sess-subagent-waiting",
            activity: SessionBackgroundActivity(
                id: "subagent-1",
                kind: .subagent,
                displayName: "general-purpose",
                startedAt: startedAt.addingTimeInterval(1),
                lastUpdatedAt: startedAt.addingTimeInterval(1)
            ),
            at: startedAt.addingTimeInterval(1)
        ))
        sessionStore.updateStatus(
            sessionID: "sess-subagent-waiting",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Turn complete"),
            at: startedAt.addingTimeInterval(2)
        )

        await settleNotificationTasks()

        let notifications = await recorder.notifications()
        #expect(notifications.isEmpty)
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs.isEmpty)
        #expect(sessionStore.sessionRegistry.sessionsByID["sess-subagent-waiting"]?.status?.kind == .ready)
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.status.kind == .working)
    }

    @Test
    func resumeGraceTimerRepublishesRawReadyAfterExpiry() async throws {
        let sessionStore = SessionRuntimeStore()
        defer { sessionStore.reset() }
        var publishCount = 0
        let cancellable = sessionStore.$sessionRegistry.sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }

        let workspaceID = UUID()
        let panelID = UUID()
        let finishAt = Date().addingTimeInterval(
            -(SessionRegistry.resumeProjectionGraceInterval - 0.4)
        )
        let startedAt = finishAt.addingTimeInterval(-3)

        sessionStore.startSession(
            sessionID: "sess-resume-timer",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-resume-timer",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Root complete"),
            at: finishAt.addingTimeInterval(-2)
        )
        #expect(sessionStore.updateBackgroundActivity(
            sessionID: "sess-resume-timer",
            activity: SessionBackgroundActivity(
                id: "subagent-1",
                kind: .subagent,
                startedAt: finishAt.addingTimeInterval(-1),
                lastUpdatedAt: finishAt.addingTimeInterval(-1)
            ),
            at: finishAt.addingTimeInterval(-1)
        ))

        #expect(sessionStore.finishBackgroundActivity(
            sessionID: "sess-resume-timer",
            activityID: "subagent-1",
            at: finishAt
        ))
        let publishCountAfterFinish = publishCount

        #expect(sessionStore.panelStatus(for: panelID)?.projection == .resuming)
        await SessionRuntimeStoreTestSupport.waitUntil(timeoutNanoseconds: 1_000_000_000) {
            publishCount > publishCountAfterFinish &&
                sessionStore.panelStatus(for: panelID)?.projection == SessionStatusProjection.none
        }

        let status = try #require(sessionStore.panelStatus(for: panelID))
        #expect(status.status.kind == .ready)
        #expect(status.status.detail == "Root complete")
        #expect(status.projection == .none)
    }

    @Test
    func readyStatusDuringResumeGraceClearsProjectionAndSendsNotification() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            },
            isApplicationActive: { false }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let finishAt = Date().addingTimeInterval(-0.1)
        let startedAt = finishAt.addingTimeInterval(-3)

        sessionStore.startSession(
            sessionID: "sess-ready-during-grace",
            agent: .claude,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        #expect(sessionStore.updateBackgroundActivity(
            sessionID: "sess-ready-during-grace",
            activity: SessionBackgroundActivity(
                id: "subagent-1",
                kind: .subagent,
                displayName: "general-purpose",
                startedAt: finishAt.addingTimeInterval(-2),
                lastUpdatedAt: finishAt.addingTimeInterval(-2)
            ),
            at: finishAt.addingTimeInterval(-2)
        ))
        sessionStore.updateStatus(
            sessionID: "sess-ready-during-grace",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Stale complete"),
            at: finishAt.addingTimeInterval(-1)
        )
        await settleNotificationTasks()
        let staleNotifications = await recorder.notifications()
        #expect(staleNotifications.isEmpty)

        #expect(sessionStore.finishBackgroundActivity(
            sessionID: "sess-ready-during-grace",
            activityID: "subagent-1",
            at: finishAt
        ))
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.projection == .resuming)

        sessionStore.updateStatus(
            sessionID: "sess-ready-during-grace",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Fresh complete"),
            at: Date()
        )

        await waitUntilNotificationCount(recorder, expectedCount: 1)

        let notification = try #require(await recorder.notifications().first)
        #expect(notification.title == "Claude Code is ready")
        #expect(notification.body == "Fresh complete")
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [backgroundPanelID])
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.status.kind == .ready)
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.projection == SessionStatusProjection.none)
    }

    @Test
    func idleAtPromptFallbackCompletesBackgroundProcessWatchAndSendsNotification() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            },
            isApplicationActive: { false }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_060)

        sessionStore.startProcessWatch(
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            displayTitleOverride: "bundle exec rspec",
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        #expect(
            sessionStore.stopSessionForPanelIfOlderThan(
                panelID: backgroundPanelID,
                minimumRuntime: 1,
                reason: .idleAtPrompt,
                at: startedAt.addingTimeInterval(2)
            )
        )

        await waitUntilNotificationCount(recorder, expectedCount: 1)

        let record = try #require(sessionStore.sessionRegistry.activeSession(for: backgroundPanelID))
        #expect(record.status?.kind == .ready)
        #expect(record.status?.detail == "Completed")

        let notification = try #require(await recorder.notifications().first)
        #expect(notification.title == "Command finished")
        #expect(notification.body == "bundle exec rspec")
        #expect(notification.workspaceID == selection.workspaceID)
        #expect(notification.panelID == backgroundPanelID)

        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [backgroundPanelID])
    }

    @Test
    func updateStatusDoesNotSendNotificationForFocusedManagedPanel() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            },
            isApplicationActive: { true }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let focusedPanelID = try #require(selection.workspace.focusedPanelID)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-focused-managed",
            agent: .claude,
            panelID: focusedPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-focused-managed",
            status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Confirm"),
            at: startedAt.addingTimeInterval(1)
        )

        await settleNotificationTasks()

        let notifications = await recorder.notifications()
        #expect(notifications.isEmpty)
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs.isEmpty)
    }

    @Test
    func updateStatusSendsNotificationForFocusedManagedPanelWhenApplicationIsInactive() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            },
            isApplicationActive: { false }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let focusedPanelID = try #require(selection.workspace.focusedPanelID)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-focused-backgrounded",
            agent: .codex,
            panelID: focusedPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-focused-backgrounded",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished"),
            at: startedAt.addingTimeInterval(1)
        )

        await waitUntilNotificationCount(recorder, expectedCount: 1)

        let notification = try #require(await recorder.notifications().first)
        #expect(notification.title == "Codex is ready")
        #expect(notification.body == "Finished")

        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [focusedPanelID])
    }

    @Test
    func updateStatusSendsNotificationForUnfocusedManagedPanelWhenApplicationIsInactive() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            },
            isApplicationActive: { false }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-background-backgrounded",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-background-backgrounded",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished"),
            at: startedAt.addingTimeInterval(1)
        )

        await waitUntilNotificationCount(recorder, expectedCount: 1)

        let notification = try #require(await recorder.notifications().first)
        #expect(notification.title == "Codex is ready")
        #expect(notification.body == "Finished")

        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [backgroundPanelID])
    }

    @Test
    func updateStatusDoesNotSendNotificationForUnmanagedSession() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-unmanaged",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-unmanaged",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished"),
            at: startedAt.addingTimeInterval(1)
        )

        await settleNotificationTasks()

        let notifications = await recorder.notifications()
        #expect(notifications.isEmpty)
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [backgroundPanelID])
    }

    @Test
    func updateStatusDoesNotRepeatNotificationForSameActionableKind() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-repeat",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-repeat",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "First"),
            at: startedAt.addingTimeInterval(1)
        )
        await waitUntilNotificationCount(recorder, expectedCount: 1)

        sessionStore.updateStatus(
            sessionID: "sess-repeat",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Second"),
            at: startedAt.addingTimeInterval(2)
        )
        await settleNotificationTasks()

        let notificationCount = await recorder.count()
        #expect(notificationCount == 1)
    }

    @Test
    func updateStatusFallsBackToTrimmedSummaryWhenDetailIsBlank() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-blank-detail",
            agent: .claude,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-blank-detail",
            status: SessionStatus(kind: .ready, summary: "  Ready for prompt  ", detail: "   \n"),
            at: startedAt.addingTimeInterval(1)
        )

        await waitUntilNotificationCount(recorder, expectedCount: 1)

        let notification = try #require(await recorder.notifications().first)
        #expect(notification.body == "Ready for prompt")
    }

}
