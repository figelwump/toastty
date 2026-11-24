import CoreState
import Foundation

/// The task and coordinator services, built as `ToasttyApp.init` builds them
/// on macOS (Sources/App/ToasttyApp.swift, "TaskCoordinator" through
/// "CoordinatorController"). `LinuxAppLogic.init` makes one before Remote
/// Access and the automation socket, which both take it.
///
/// What macOS does and this does not, yet: the coordinator chat model
/// (`CoordinatorController.chat`), the What's new start offer, the global
/// quick entry key and the keyboard link from the coordinator's terminal to
/// the chat's composer. Each arrives with its GTK view; see
/// docs/plans/linux-tasks-ui.md.
@MainActor
struct LinuxTaskStack {
    let coordinator: TaskCoordinator
    let board: TaskBoardStore
    let webhooks: TaskWebhookService
    let pullRequests: PullRequestStateCache
    let sessions: LiveTaskSessions
    let sessionCloseController: SessionCloseController
    let sessionExitController: SessionExitController

    var coordinatorController: CoordinatorController? { coordinator.coordinatorController }

    // swiftlint:disable:next function_body_length
    static func make(
        runtimePaths: ToasttyRuntimePaths,
        environment: [String: String],
        usesPersistentPreferences: Bool,
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore,
        terminalRuntimeRegistry: TerminalRuntimeRegistry,
        webPanelRuntimeRegistry: WebPanelRuntimeRegistry,
        focusedPanelCommandController: FocusedPanelCommandController,
        agentLaunchService: AgentLaunchService,
        agentCatalogStore: AgentCatalogStore,
        workspaceMergeCoordinator: WorkspaceMergeCoordinator,
        socketPath: String,
        cliExecutablePath: String?
    ) -> LinuxTaskStack {
        let recentWorkspaces = RecentWorkspacesStore(runtimePaths: runtimePaths)
        recentWorkspaces.observe(store)
        let coordinator = TaskCoordinator(
            records: TaskRecordStore(runtimePaths: runtimePaths),
            store: store,
            launcher: agentLaunchService,
            configLoader: { try TasksConfigFile.load() },
            attachmentsDirectoryURL: runtimePaths.taskAttachmentsDirectoryURL,
            hasActiveSession: { [weak sessionRuntimeStore] workspaceID in
                guard let registry = sessionRuntimeStore?.sessionRegistry else { return false }
                return registry.activeSessionIDByPanelID.values.contains { sessionID in
                    registry.sessionsByID[sessionID]?.workspaceID == workspaceID
                }
            },
            grantScope: { [weak sessionRuntimeStore] sessionID, workspaceID in
                guard let sessionRuntimeStore, sessionRuntimeStore.isWorkspaceScoped(sessionID: sessionID) else { return }
                _ = sessionRuntimeStore.addScope(sessionID: sessionID, workspaceIDs: [workspaceID])
            },
            triageRunner: TaskLiveTriageRunner(),
            recentWorkspaces: recentWorkspaces
        )
        coordinator.reconcileAfterLaunch()

        let pullRequests = PullRequestStateCache(
            runner: WorkspaceMergeLiveCommandRunner(socketPath: socketPath, cliExecutablePath: cliExecutablePath)
        )
        workspaceMergeCoordinator.pullRequestStateCache = pullRequests
        sessionRuntimeStore.pullRequestStateCache = pullRequests
        let board = TaskBoardStore(
            coordinator: coordinator,
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            pullRequests: pullRequests
        )
        coordinator.board = board

        let webhooks = TaskWebhookService(
            webhooksFileURL: runtimePaths.taskWebhooksFileURL,
            outboxFileURL: runtimePaths.taskWebhookOutboxFileURL,
            coordinatorRepliesFileURL: runtimePaths.coordinatorRepliesFileURL,
            secrets: FileTaskWebhookSecretStore(fileURL: FileTaskWebhookSecretStore.fileURL(runtimePaths: runtimePaths))
        )
        webhooks.taskStates = { [weak board] in
            TaskWebhookService.taskStates(board?.items() ?? [])
        }
        webhooks.taskAlertFacts = { [weak coordinator] taskIDs in
            coordinator?.alertFacts(for: taskIDs) ?? [:]
        }
        coordinator.webhooks = webhooks
        webhooks.start()

        coordinator.merges = workspaceMergeCoordinator
        workspaceMergeCoordinator.cleanupObserver = { [weak coordinator] workspaceID, event in
            coordinator?.mergeCleanupEvent(workspaceID: workspaceID, event: event)
        }
        sessionRuntimeStore.taskCoordinator = coordinator
        coordinator.unsavedDocumentCount = { [weak store, weak webPanelRuntimeRegistry] workspaceID in
            guard let panelIDs = store?.state.workspacesByID[workspaceID]?.allPanelsByID.keys,
                  let summary = webPanelRuntimeRegistry?.localDocumentCloseConfirmationSummary(panelIDs: panelIDs) else { return 0 }
            return summary.dirtyDraftCount + summary.saveInProgressCount
        }

        let sessionCloseController = SessionCloseController(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: focusedPanelCommandController,
            terminalCloseAssessment: { [weak terminalRuntimeRegistry] panelID in
                terminalRuntimeRegistry?.terminalCloseConfirmationAssessment(panelID: panelID)
            },
            localDocumentCloseConfirmationState: { [weak webPanelRuntimeRegistry] panelID in
                webPanelRuntimeRegistry?.localDocumentCloseConfirmationState(panelID: panelID)
            }
        )
        let sendText: @MainActor (String, UUID) -> Bool = { [weak terminalRuntimeRegistry] text, panelID in
            terminalRuntimeRegistry?.sendText(
                text,
                submit: true,
                panelID: panelID,
                focusPolicy: .preserveFirstResponder
            ) ?? false
        }
        let deliverText: @MainActor (String, UUID) -> TerminalInputDeliveryResult = { [weak terminalRuntimeRegistry] text, panelID in
            terminalRuntimeRegistry?.sendTextResult(
                text,
                submit: true,
                panelID: panelID,
                focusPolicy: .preserveFirstResponder
            ) ?? .unavailable
        }
        let sessionExitController = SessionExitController(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            sessionCloseController: sessionCloseController,
            sendText: sendText
        )
        sessionRuntimeStore.sessionExitController = sessionExitController
        coordinator.closeFinishedTaskSpace = { [weak store, weak sessionRuntimeStore] workspaceID in
            store?.closeTaskSpaceFocusingNextActive(
                workspaceID: workspaceID,
                sessionRuntimeStore: sessionRuntimeStore
            ) ?? false
        }
        let sessions = LiveTaskSessions(
            sessionRuntimeStore: sessionRuntimeStore,
            closeController: sessionCloseController,
            exitController: sessionExitController,
            sendText: sendText,
            deliverText: deliverText
        )
        coordinator.sessions = sessions

        let userDefaults = usesPersistentPreferences ? ToasttyAppDefaults.current : nil
        coordinator.coordinatorController = CoordinatorController(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            launcher: agentLaunchService,
            directoryURL: runtimePaths.coordinatorDirectoryURL,
            queueFileURL: runtimePaths.coordinatorQueueFileURL,
            workspaceFileURL: runtimePaths.coordinatorWorkspaceFileURL,
            configLoader: { try TasksConfigFile.load() },
            // The agent's terminal inherits this process's environment.
            trustFolder: { [weak agentCatalogStore] profileID, directory in
                await ClaudeFolderTrust.trustCoordinatorFolder(
                    directory,
                    profileID: profileID,
                    profileArgv: agentCatalogStore?.catalog.profile(id: profileID)?.argv ?? [],
                    environment: environment
                )
            },
            deliverText: deliverText,
            promptState: { [weak terminalRuntimeRegistry] panelID in
                terminalRuntimeRegistry?.promptState(panelID: panelID) ?? .unavailable
            },
            managedAgentRestoreState: { [weak terminalRuntimeRegistry] panelID in
                terminalRuntimeRegistry?.managedAgentRestoreState(panelID: panelID) ?? .inactive
            },
            revealDocumentLine: { [weak webPanelRuntimeRegistry] panelID, lineNumber in
                webPanelRuntimeRegistry?.requestLocalDocumentReveal(panelID: panelID, lineNumber: lineNumber) ?? false
            },
            defaults: userDefaults
        )
        if let coordinatorController = coordinator.coordinatorController {
            webhooks.attach(coordinator: coordinatorController)
            webhooks.notifyUser = { [weak coordinatorController] title, body in
                let location = coordinatorController?.location
                Task {
                    await SystemNotificationSender.send(
                        title: title,
                        body: body,
                        workspaceID: location?.workspaceID,
                        panelID: location?.panelID
                    )
                }
            }
            // A wake turn the coordinator marked quiet ends without an
            // unread mark, a notification or a push.
            sessionRuntimeStore.isQuietTurnEnd = { [weak coordinatorController] sessionID in
                coordinatorController?.turnEndsQuietly(sessionID: sessionID) ?? false
            }
        }
        return LinuxTaskStack(
            coordinator: coordinator,
            board: board,
            webhooks: webhooks,
            pullRequests: pullRequests,
            sessions: sessions,
            sessionCloseController: sessionCloseController,
            sessionExitController: sessionExitController
        )
    }

    /// After Remote Access exists: task sends and the coordinator type
    /// through the conversation path a paired phone uses.
    func connect(remoteAccessService: RemoteAccessService?) {
        sessions.conversationAccess = remoteAccessService
        coordinatorController?.conversationAccess = remoteAccessService
    }

    /// A quit must leave the marks of turns it cuts off; see
    /// `TaskCoordinator.recordStateTimes`.
    func prepareForTermination() {
        coordinator.prepareForTermination()
    }
}
