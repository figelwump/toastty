import CoreState
import RemoteProtocol
import Foundation

/// The task and coordinator services, built as `ToasttyApp.init` builds them
/// on macOS (Sources/App/ToasttyApp.swift, "TaskCoordinator" through
/// "CoordinatorController"). `LinuxAppLogic.init` makes one before Remote
/// Access and the automation socket, which both take it.
///
/// What macOS does and this does not, yet: the What's new start offer. Each arrives with its GTK view; see
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
    let quickEntry: QuickEntryController
    let terminalRuntimeRegistry: TerminalRuntimeRegistry
    let userDefaults: UserDefaults?

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
        cliExecutablePath: String?,
        codexProcessPathStore: CodexProcessPathStore,
        registersGlobalShortcut: Bool
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

        let quickEntry = QuickEntryController(
            store: store,
            agentProfiles: { [weak agentLaunchService] in agentLaunchService?.launchProfileSummaries() ?? [] },
            presetUsage: QuickEntryPresetUsage(runtimePaths: runtimePaths),
            create: { [weak coordinator] request in
                guard let coordinator else { throw TaskError("Toastty is quitting.") }
                return try await coordinator.create(request, caller: .quickEntry)
            },
            configLoader: { try TasksConfigFile.load() },
            // A smoke run or a test host must not take the user's shortcut
            // from the Toastty they are using.
            registersGlobalHotKey: registersGlobalShortcut
        )
        quickEntry.loadCodexModels = { [weak agentLaunchService] in
            guard let executable = try agentLaunchService?.profileExecutableState(profileID: AgentKind.codex.rawValue),
                  // As with launch argument support, only a direct provider
                  // command is known to accept provider subcommands.
                  ["codex", "cdx"].contains(URL(fileURLWithPath: executable.command).lastPathComponent),
                  let executablePath = executable.executablePath else {
                return []
            }
            let processPath = codexProcessPathStore.currentPath()
            let models = try await Task.detached(priority: .userInitiated) {
                let runtime = try CodexIntegrationRuntimeLocator.resolve(
                    preferredProcessPath: processPath,
                    executableURL: URL(fileURLWithPath: executablePath)
                )
                return try CodexModelCatalog().load(runtime: runtime, deadline: Date().addingTimeInterval(5))
            }.value
            // A configuration reload can replace the CLI while it runs.
            guard let currentExecutable = try agentLaunchService?.profileExecutableState(profileID: AgentKind.codex.rawValue).executablePath,
                  currentExecutable == executablePath, codexProcessPathStore.currentPath() == processPath else { return [] }
            return models
        }
        board.newTask = { [weak quickEntry] in
            quickEntry?.present(prefill: .empty)
        }
        board.showShortcut(of: quickEntry)
        terminalRuntimeRegistry.presentQuickEntryFromSelection = { [weak quickEntry] text, panelID in
            quickEntry?.presentFromSelection(text, panelID: panelID)
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
        // While a coordinator exists, quick entry sends to it.
        quickEntry.coordinatorController = coordinator.coordinatorController
        quickEntry.loadShortcutAtLaunch()
        return LinuxTaskStack(
            coordinator: coordinator,
            board: board,
            webhooks: webhooks,
            pullRequests: pullRequests,
            sessions: sessions,
            sessionCloseController: sessionCloseController,
            sessionExitController: sessionExitController,
            quickEntry: quickEntry,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            userDefaults: userDefaults
        )
    }

    /// After Remote Access exists: task sends and the coordinator type
    /// through the conversation path a paired phone uses.
    func connect(remoteAccessService: RemoteAccessService?) {
        sessions.conversationAccess = remoteAccessService
        // The coordinator types through its agent's conversation, the path
        // a paired phone uses, so one prompt check covers every sender.
        if let coordinatorController, let remoteAccessService {
            coordinatorController.conversationAccess = remoteAccessService
            coordinatorController.chat = CoordinatorChatModel(
                controller: coordinatorController,
                access: remoteAccessService,
                defaults: userDefaults
            )
            // Keyboard focus meant for the terminal under the chat goes to
            // the chat's composer, and Show Terminal gives it back.
            coordinatorController.connectKeyboard(to: terminalRuntimeRegistry)
        }
        // The quick entry Agent picker offers the models the iPhone's
        // start-session screen offers.
        quickEntry.recentModels = { [weak remoteAccessService] provider in
            remoteAccessService?.recentModels(for: provider) ?? []
        }
    }

    /// Reload Configuration: the quick entry shortcut and the Codex model
    /// catalog. Returns a message when the shortcut could not be set up.
    func reloadConfiguration() -> String? {
        quickEntry.invalidateCodexModels()
        return quickEntry.reloadShortcut()
    }

    /// A quit must leave the marks of turns it cuts off; see
    /// `TaskCoordinator.recordStateTimes`.
    func prepareForTermination() {
        coordinator.prepareForTermination()
        // macOS reaches this through NSApplication.willTerminateNotification.
        quickEntry.handleTermination()
    }
}
