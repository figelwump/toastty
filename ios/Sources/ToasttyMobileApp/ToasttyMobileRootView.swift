import ConversationUI
import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain

struct ToasttyMobileRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sessionController: AppSessionController
    @State private var appIconBadgeController: AppIconBadgeController?
    /// The selected tab and each tab's stack. Without the Mac's task system
    /// there is no tab bar, and Home's stack is the only one.
    @State private var tabs = ToasttyMobileTabState()
    @State private var tasksScrollRequest: ToasttyTasksScrollRequest?
    @State private var pendingDeepLinkDestination: ToasttyMobileDeepLinkDestination?
    @State private var presentedSheet: ToasttyMobileSheet?
    /// The new-session sheet for content shared from another app, when the
    /// Mac cannot create tasks.
    @State private var sharedNewSession: ToasttyNewSessionModel?
    /// The New Task sheet for content shared from another app.
    @State private var sharedNewTask: ToasttyNewTaskModel?
    /// A notification or link opened something during this activation, so a
    /// waiting shared draft does not cover it.
    @State private var routedDestinationSinceActivation = false
    @State private var fixtureHasLoadedOlderTranscript = false
    /// Only the composer reads the drafts' state, so typing does not update
    /// this view, its tabs or the transcript.
    @State private var composerDrafts = ToasttyComposerDraftStore()
    @State private var fixtureSendItems: [ToasttySendPresentationItem]
    @State private var fixtureComposerIsReserved = false
    @State private var fixtureQueuedMessages: [RemoteQueuedMessage] = []
    @State private var fixtureQueueSubmissionCount = 0
    @State private var fixtureQueuePaused = false
    @State private var fixtureTurnStopped = false
    /// The fixture coordinator's own queue
    /// (`TOASTTY_MOBILE_FIXTURE_COORDINATOR_QUEUE`), and the token of the
    /// Stop that holds its messages.
    @State private var fixtureCoordinatorQueueEntries: [RemoteCoordinatorQueueEntry] = []
    @State private var fixtureCoordinatorHeldSetToken: String?
    /// The fixture's entries whose Remove the Mac refused
    /// (`TOASTTY_MOBILE_FIXTURE_COORDINATOR_QUEUE_REMOVE_FAILS`).
    @State private var fixtureCoordinatorRemoveFailures: Set<String> = []
    @State private var fixtureLocalDraftReleaseAttempts = 0
#if DEBUG
    @State private var fixtureEntryLoadStep = 0
    @State private var controlledFixtureSubmission: ControlledFixtureSubmission?
    @State private var fixtureSentText: String?
    @State private var fixtureSendUpdateCount = 0
    /// A send in the fixture coordinator chat removed its New line.
    @State private var fixtureCoordinatorLineCleared = false
    /// What the Mac sends while the user types, from TOASTTY_MOBILE_FIXTURE_INCOMING=1.
    @State private var fixtureIncoming: ToasttyIncomingFixture?
    /// The fixture coordinator chat finished loading since it last opened,
    /// with `TOASTTY_MOBILE_FIXTURE_COORDINATOR_REOPENS=1`.
    @State private var fixtureCoordinatorIsLoaded = false
#endif
    @State private var fixtureInteractionAnswerState: ToasttyInteractionAnswerState?
    @State private var fixtureInteractionAcceptedAnswers: [RemoteInteractionAnswer]?
    @State private var diagnostics = ToasttyDiagnosticsState()
    @State private var diagnosedSessionState: AppSessionState?
    private let forcesPairingPrivacyShield: Bool
    private let fixtureScenario: ToasttyMobileFixtureScenario?
#if DEBUG
    private let entryLoadFixture: ToasttyConversationFixture.EntryLoad?
    private let controlsFixtureSubmission: Bool
    private let fixtureSendEventOrder: ToasttyConversationFixture.SendEventOrder?
    private let showsNotificationTapButtons: Bool
    /// `TOASTTY_MOBILE_FIXTURE_RENDER_COUNTS=1`: UI tests read how many times
    /// a transcript's body ran.
    private let showsTranscriptBodyCount: Bool
#endif
    private let deepLinkParser: DeepLinkParser?
    private let sharedDraftStore: ToasttySharedDraftStore?
    private let pushBridge: ToasttyPushNotificationBridge?

    init(configuration: ToasttyMobileAppConfiguration, pushBridge: ToasttyPushNotificationBridge? = nil) {
        _sessionController = State(initialValue: configuration.makeSessionController(pushBridge: pushBridge))
        self.pushBridge = pushBridge
        _appIconBadgeController = State(initialValue: configuration.enablesSystemAppIconBadge
            ? AppIconBadgeController(client: SystemAppIconBadgeClient())
            : nil)
        _fixtureSendItems = State(initialValue: Self.initialFixtureSendItems(
            for: configuration.fixtureScenario
        ))
#if DEBUG
        if configuration.fixtureScenario == .gatedSend,
           let attachmentCount = Int(ProcessInfo.processInfo.environment["TOASTTY_MOBILE_FIXTURE_ATTACHMENT_DRAFT"] ?? ""),
           (1...4).contains(attachmentCount) {
            var draft = ToasttyComposerDraftState()
            let attachments = (1...attachmentCount).map { index in
                RemoteMessageAttachment(
                    filename: index == 1 ? "fixture-notes.txt" : "fixture-notes-\(index).txt",
                    data: Data("Attachment preview fixture".utf8)
                )
            }
            _ = draft.addAttachments(attachments, for: Self.fixtureOpenPromptConversationID)
            _composerDrafts = State(initialValue: ToasttyComposerDraftStore(draft))
        }
        if configuration.fixtureScenario == .interactionAnswer {
            let key = ToasttyInteractionAnswerKey(
                interactionID: ToasttyConversationFixture.questionInteractionID,
                responseID: ToasttyConversationFixture.questionResponseID,
                inputEpoch: ToasttyConversationFixture.questionEpoch
            )
            _fixtureInteractionAnswerState = State(initialValue: ToasttyInteractionAnswerState(
                key: key,
                questions: ToasttyConversationFixture.answerQuestions
            ))
        } else {
            _fixtureInteractionAnswerState = State(initialValue: nil)
        }
#else
        _fixtureInteractionAnswerState = State(initialValue: nil)
#endif
        _fixtureInteractionAcceptedAnswers = State(initialValue: nil)
        forcesPairingPrivacyShield = configuration.fixtureScenario == .pairingPrivacy
        fixtureScenario = configuration.fixtureScenario
#if DEBUG
        entryLoadFixture = configuration.entryLoadFixture
        showsNotificationTapButtons = configuration.showsNotificationTapButtons
        showsTranscriptBodyCount = configuration.fixtureScenario != nil
            && ProcessInfo.processInfo.environment["TOASTTY_MOBILE_FIXTURE_RENDER_COUNTS"] == "1"
        controlsFixtureSubmission = configuration.fixtureScenario == .gatedSend
            && ProcessInfo.processInfo.environment["TOASTTY_MOBILE_FIXTURE_CONTROLLED_SUBMIT"] == "1"
        fixtureSendEventOrder = configuration.fixtureScenario == .gatedSend
            ? ProcessInfo.processInfo.environment["TOASTTY_MOBILE_FIXTURE_SEND_EVENT_ORDER"]
                .flatMap(ToasttyConversationFixture.SendEventOrder.init(rawValue:))
            : nil
        _fixtureIncoming = State(initialValue: configuration.fixtureScenario == .home
            && ProcessInfo.processInfo.environment["TOASTTY_MOBILE_FIXTURE_INCOMING"] == "1"
            ? ToasttyIncomingFixture() : nil)
        if configuration.fixtureScenario == .home, Self.fixtureCoordinatorQueueMode != nil {
            _fixtureQueuedMessages = State(initialValue: ToasttyConversationFixture.coordinatorChatQueue)
            if Self.fixtureCoordinatorQueueMode == .shared {
                let environment = ProcessInfo.processInfo.environment
                let isInterrupted = environment["TOASTTY_MOBILE_FIXTURE_COORDINATOR_QUEUE_INTERRUPTED"] == "1"
                _fixtureCoordinatorQueueEntries = State(initialValue: ToasttyConversationFixture.coordinatorOwnQueue(
                    hasLongMessage: environment["TOASTTY_MOBILE_FIXTURE_COORDINATOR_QUEUE_LONG"] == "1",
                    hasInterruptedMessage: isInterrupted
                ))
                // As after a relaunch of the Mac: the interrupted message
                // waits, held, under a new token.
                _fixtureCoordinatorHeldSetToken = State(initialValue: isInterrupted ? UUID().uuidString : nil)
            }
        }
#endif
        deepLinkParser = configuration.urlScheme.flatMap(DeepLinkParser.init(scheme:))
        sharedDraftStore = configuration.sharedDraftStore
#if DEBUG
        if configuration.runtimeMode == .fixture, let store = configuration.sharedDraftStore {
            ToasttySharedDraftFixture.seed(
                store,
                handoff: ProcessInfo.processInfo.environment["TOASTTY_MOBILE_FIXTURE_SHARED_DRAFT"]
                    .flatMap(ToasttySharedDraftFixture.Handoff.init(rawValue:))
            )
        }
#endif
    }

    var body: some View {
        Group {
            // The loading branch must stay a single view identity across the
            // restoring → connecting handoff so its animations run
            // uninterrupted and only the caption crossfades.
            if let loadingPhase {
                AppSessionLoadingView(phase: loadingPhase)
                    .transition(.opacity)
            } else {
                switch sessionController.state {
                case .pairing:
                    if let pairingController = sessionController.pairingController {
                        PairingFlowView(
                            controller: pairingController,
                            onCancel: sessionController.cancelPairing,
                            forcesPrivacyShield: forcesPairingPrivacyShield
                        )
                    } else {
                        sessionGate
                    }
                case .paired(let presentation):
                    pairedApp(presentation: presentation)
                case .restoring, .unpaired, .keychainLocked, .repairNeeded, .incompatible:
                    sessionGate
                }
            }
        }
        .environment(\.toasttyPreviewService, sessionController.previewService)
        .background {
            AppIconBadgeSync(sessionController: sessionController, controller: appIconBadgeController)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: loadingPhase == nil)
        .sensoryFeedback(trigger: sessionController.state) { old, new in
            ToasttyHapticFeedback.pairingCompleted(from: old, to: new)
        }
        .task {
            sessionController.installDiagnosticRecordHandler { record in
                ToasttyDiagnosticLogger.record(record.event, recordedAt: record.recordedAt,
                    pushDetails: record.pushDetails, in: &diagnostics)
            }
            if let pushBridge { sessionController.pushController?.attachBridge(pushBridge) }
            recordDiagnostic(.authStarted)
            observeSessionState(sessionController.state)
            await sessionController.restoreIfNeeded()
            observeSessionState(sessionController.state)
            queueWaitingSharedDraft()
        }
        .onChange(of: sessionController.liveController?.activeConversationController?.sendReconciliation) {
            reconcileAttachmentDrafts()
        }
        .onChange(of: sessionController.state) { _, newState in
            observeSessionState(newState)
            if newState.isPaired == false {
                resetComposerPresentation()
                if newState != .restoring, newState != .keychainLocked {
                    pendingDeepLinkDestination = nil
                    tabs = ToasttyMobileTabState()
                }
            } else {
                routePendingDeepLinkIfAvailable()
                queueWaitingSharedDraft()
                presentNotificationIntroIfNeeded()
            }
        }
        .onChange(of: sessionController.homeController.isShowingNewSessionForm) { _, isShowing in
            if isShowing == false { routePendingDeepLinkIfAvailable() }
        }
        .onChange(of: sessionController.homeController.snapshot) { _, newSnapshot in
            pruneComposerState(to: newSnapshot)
            routePendingDeepLinkIfAvailable()
        }
        .onChange(of: sessionController.homeController.freshness) {
            routePendingDeepLinkIfAvailable()
        }
        .onChange(of: sessionController.pushController?.canIntroduce) { presentNotificationIntroIfNeeded() }
        .onChange(of: sessionController.pushController?.pendingConversationID) { handleNotificationTap() }
        .onChange(of: sessionController.pushController?.pendingTaskTap) { handleNotificationTap() }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                sessionController.sceneBecameActive()
                queueWaitingSharedDraft()
            case .inactive:
                sessionController.sceneBecameInactive()
            case .background:
                routedDestinationSinceActivation = false
                sessionController.sceneEnteredBackground()
            @unknown default:
                sessionController.sceneBecameInactive()
            }
        }
        .onOpenURL(perform: handleDeepLink)
#if DEBUG
        .overlay(alignment: .topLeading) {
            if showsTranscriptBodyCount {
                ToasttyTranscriptBodyCountElement()
                    .frame(width: 2, height: 2)
            }
        }
#endif
        .preferredColorScheme(.dark)
#if DEBUG
        .toasttyIncomingKeyboardLog($fixtureIncoming)
        .modifier(FixtureCoordinatorReopenLoad(
            isEnabled: Self.fixtureCoordinatorReopens,
            selectedConversationID: sessionController.homeController.selectedConversationPresentation?.id,
            isLoaded: $fixtureCoordinatorIsLoaded
        ))
#endif
    }

    private var sessionGate: some View {
        AppSessionGateView(
            state: sessionController.state,
            beginPairing: sessionController.beginPairing,
            retryRestoration: {
                Task { await sessionController.retryRestoration() }
            },
            forgetCorruptPairing: { await sessionController.forgetCorruptPairing() }
        )
    }

    private var loadingPhase: AppSessionLoadingPhase? {
        switch sessionController.state {
        case .restoring:
            .restoring
        case .paired(.connecting):
            .connecting(hostName: sessionController.homeController.snapshot.hostName)
        case .pairing, .paired, .unpaired, .keychainLocked, .repairNeeded, .incompatible:
            nil
        }
    }

    private func pairedApp(presentation: PairedConnectionPresentation) -> some View {
        tabContent
        .tint(ToasttyDesignTokens.amber)
        .background(ToasttyDesignTokens.background.ignoresSafeArea())
        // Once for the whole stack: Home stays in it under a pushed
        // workspace, so a per-screen dialog would present twice.
        .toasttySessionCloseConfirmation(sessionController.homeController)
        .safeAreaInset(edge: .top, spacing: 0) {
            PairedConnectionBanner(presentation: presentation)
        }
        .onAppear {
            // The stack can be (re)inserted while a selection already exists,
            // e.g. after a keychain-lock cycle; onChange alone would miss it.
            syncNavigationPath(with: sessionController.homeController.selectedConversationPresentation)
            sessionController.pushController?.setOpenConversation(screenConversationID)
            handleNotificationTap()
            presentNotificationIntroIfNeeded()
        }
        .onChange(of: sessionController.homeController.selectedConversationPresentation) { _, selection in
            syncNavigationPath(with: selection)
        }
        // Leaving the task system closes the Tasks and Coordinator tabs and
        // their stacks.
        .onChange(of: showsTasksTab) { _, showsTasksTab in
            guard showsTasksTab == false else { return }
            selectTab(.home)
            tabs.paths[.tasks] = nil
            tabs.paths[.coordinator] = nil
        }
        // A closed coordinator closes its tab.
        .onChange(of: showsCoordinatorTab) { _, showsCoordinatorTab in
            guard showsCoordinatorTab == false else { return }
            if tabs.selected == .coordinator { selectTab(.home) }
            tabs.paths[.coordinator] = nil
        }
        .onChange(of: navigationPath) { _, newPath in
            presentNotificationIntroIfNeeded()
            // A back swipe or back button pops the conversation route without
            // going through the controller; mirror the pop into selection so
            // the live conversation runtime closes, or, back on the
            // Coordinator tab's own screen, opens the coordinator's.
            if newPath.containsConversation == false {
                openScreenConversation()
            }
        }
        // Also when the tab changes, or the coordinator's session comes or
        // goes: only the screen on top of the tab on screen has an open
        // conversation.
        .onChange(of: screenConversationID) { _, conversationID in
            sessionController.pushController?.setOpenConversation(conversationID)
            if navigationPath.containsConversation == false {
                openScreenConversation()
            }
        }
        // A shared draft waits for these sheets to close before its own opens.
        .sheet(item: $presentedSheet, onDismiss: routePendingDeepLinkIfAvailable) { sheet in
            switch sheet {
            case .settings:
              if let settingsPresentation {
                ToasttySettingsView(
                    presentation: settingsPresentation,
                    diagnostics: $diagnostics,
                    onUnpair: unpair,
                    pushController: sessionController.pushController
                )
              }
            case .notifications:
              if let push = sessionController.pushController {
                ToasttyNotificationIntroduction(controller: push)
              }
            }
        }
        .toasttyNewSessionSheet($sharedNewSession, controller: sessionController.homeController)
        .toasttyNewTaskSheet($sharedNewTask, controller: sessionController.homeController)
        .onChange(of: presentedSheet) { _, sheet in
            guard sheet == .settings else { presentNotificationIntroIfNeeded(); return }
            Task {
                await sessionController.refreshCurrentDevice()
            }
        }
        .overlay(alignment: .top) {
          VStack(spacing: 8) {
            if let message = sessionController.homeController.removedSelectionMessage {
                RemovedConversationBanner(
                    message: message,
                    dismiss: sessionController.homeController.dismissRemovalMessage
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
          }
        }
        .animation(
            .easeInOut(duration: 0.25),
            value: sessionController.homeController.removedSelectionMessage
        )
#if DEBUG
        .overlay(alignment: .topTrailing) {
            if showsNotificationTapButtons, let push = sessionController.pushController {
                // A notification tap, delivered as the system delivers one.
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Coordinator alert") {
                        push.receiveFixtureSessionTap(conversationID: ToasttyMobileFixture.coordinatorConversationID)
                    }
                    .accessibilityIdentifier("toastty-mobile-fixture-tap-coordinator-notification")
                    Button("Session alert") {
                        push.receiveFixtureSessionTap(conversationID: Self.fixtureWorkingConversationID)
                    }
                    .accessibilityIdentifier("toastty-mobile-fixture-tap-session-notification")
                }
                .font(.caption2.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .padding(.top, 120)
                .padding(.trailing, 8)
            }
        }
#endif
    }

    /// Home and Tasks tabs while the Mac sends a task board, and Coordinator
    /// between them while it also has a coordinator; otherwise Home alone,
    /// with no tab bar.
    @ViewBuilder
    private var tabContent: some View {
        if showsTasksTab {
            // A closure, not the method itself: Swift 6.3 crashes making the
            // isolated thunk for a method passed as `set`.
            TabView(selection: Binding(get: { tabs.selected }, set: { selectTab($0) })) {
                Tab("Home", systemImage: "house", value: ToasttyMobileTab.home) {
                    navigationStack(.home) { homeView }
                }
                // Second, between Home and Tasks, while the Mac has one.
                if showsCoordinatorTab {
                    Tab(value: ToasttyMobileTab.coordinator) {
                        navigationStack(.coordinator) { coordinatorRoot }
                    } label: {
                        Label {
                            Text(ToasttyCoordinatorTabPresentation.title)
                        } icon: {
                            Image(uiImage: ToasttyCoordinatorTabPresentation.tabImage)
                        }
                    }
                    .badge(ToasttyCoordinatorTabPresentation.badge(
                        sessionController.homeController.snapshot.coordinatorMark,
                        isOnScreen: tabs.selected == .coordinator
                    ).map { Text($0) })
                }
                Tab("Tasks", systemImage: "checklist", value: ToasttyMobileTab.tasks) {
                    navigationStack(.tasks) {
                        ToasttyTasksTabView(
                            controller: sessionController.homeController,
                            refresh: sessionController.refreshLiveSessions,
                            openWorkspace: openWorkspace,
                            scrollRequest: $tasksScrollRequest
                        )
                    }
                }
            }
        } else {
            navigationStack(.home) { homeView }
        }
    }

    private var showsTasksTab: Bool {
        sessionController.homeController.snapshot.taskBoard != nil
    }

    /// The snapshot sets the coordinator's workspace apart only with a task
    /// board, so this tab comes and goes with the tab bar.
    private var showsCoordinatorTab: Bool {
        sessionController.homeController.snapshot.coordinator != nil
    }

    /// The coordinator's session while the Coordinator tab shows.
    private var coordinatorConversationID: UUID? {
        sessionController.homeController.snapshot.coordinatorConversation?.id
    }

    /// The conversation that the screen on top of the tab on screen shows.
    private var screenConversationID: UUID? {
        tabs.openConversationID(in: tabs.selected, coordinatorConversationID: coordinatorConversationID)
    }

    /// The Coordinator tab's own screen: the coordinator's chat, or what
    /// shows while its workspace lists no session.
    @ViewBuilder
    private var coordinatorRoot: some View {
        if let coordinatorConversationID {
            conversationScreen(for: coordinatorConversationID, isCoordinatorRoot: true)
        } else {
            ToasttyCoordinatorUnavailableView(isLive: sessionController.homeController.freshness == .live)
        }
    }

    private var homeView: some View {
        ToasttyHomeView(
            controller: sessionController.homeController,
            refresh: sessionController.refreshLiveSessions,
            onSettings: { presentedSheet = .settings },
            openWorkspace: openWorkspace,
            // Reinstall advice outlasts the relay cooldown error that usually follows it.
            notificationError: sessionController.pushController?.configuration == nil
                ? nil : sessionController.pushController.flatMap { $0.deliveryHint ?? $0.errorMessage },
            retryNotifications: sessionController.pushController?.deliveryHint != nil
                ? nil : { sessionController.pushController?.retry() },
            showTasks: showTasks
        )
    }

    private func navigationStack<Root: View>(_ tab: ToasttyMobileTab, @ViewBuilder root: () -> Root) -> some View {
        NavigationStack(path: Binding(get: { tabs.paths[tab] ?? [] }, set: { tabs.paths[tab] = $0 })) {
            root()
                .navigationDestination(for: ToasttyMobileRoute.self) { route in
                    switch route {
                    case .workspace(let workspaceID):
                        ToasttyWorkspaceView(
                            workspaceID: workspaceID,
                            controller: sessionController.homeController,
                            openWorkspace: openWorkspace
                        )
                    case .conversation(let conversationID):
                        conversationScreen(for: conversationID)
                    case .panelPreview(let workspaceID, let panelID):
                        workspacePreview(workspaceID: workspaceID, panelID: panelID)
                    }
                }
        }
    }

    /// The stack of the tab on screen. Routing, deep links and the selected
    /// conversation all act on it.
    private var navigationPath: [ToasttyMobileRoute] {
        get { tabs.selectedPath }
        nonmutating set { tabs.selectedPath = newValue }
    }

    /// Shows a tab with its stack as the user left it. The open conversation
    /// follows the tab on screen: a conversation on top of the new tab's
    /// stack opens again, and one left behind in the other tab closes until
    /// that tab shows again.
    private func selectTab(_ tab: ToasttyMobileTab) {
        guard tabs.selected != tab else { return }
        tabs.selected = tab
        openScreenConversation()
    }

    /// Opens the conversation the top screen shows, or closes the open one
    /// when that screen shows none.
    private func openScreenConversation() {
        let home = sessionController.homeController
        if let conversationID = screenConversationID {
            if home.selectedConversationPresentation?.id != conversationID,
               home.openConversation(id: conversationID) == false {
                navigationPath = navigationPath.synchronized(with: nil)
            }
        } else if home.selectedConversationPresentation != nil {
            home.dismissConversation()
        }
    }

    /// The coordinator's chat on its tab's own screen, from a notification
    /// or a link. A screen pushed over the chat closes.
    private func openCoordinatorTab() {
        tabs.paths[.coordinator] = []
        tabs.selected = .coordinator
        openScreenConversation()
    }

    /// From a card's To ship line or Done count: the Tasks tab's list, at
    /// that group.
    private func showTasks(_ target: ToasttyTasksTabTarget) {
        tabs.paths[.tasks] = []
        selectTab(.tasks)
        tasksScrollRequest = ToasttyTasksScrollRequest(target: target)
    }

    /// A link or a notification opens its conversation in Home's stack,
    /// also when the Tasks tab already shows it, which leaves the selection
    /// as it was.
    private func openInHome(conversationID: UUID) {
        // Home does not list the coordinator's session; its tab shows it.
        if showsCoordinatorTab, conversationID == coordinatorConversationID {
            openCoordinatorTab()
            return
        }
        tabs.selected = .home
        sessionController.homeController.openConversation(id: conversationID)
        syncNavigationPath(with: sessionController.homeController.selectedConversationPresentation)
    }

    /// Pushes a workspace from a row or menu, which cannot use a
    /// navigation link. Subspaces open from their parent this way.
    private func openWorkspace(_ workspaceID: UUID) {
        guard navigationPath.last != .workspace(workspaceID) else { return }
        navigationPath.append(.workspace(workspaceID))
    }

    /// Opens a task space from a task chip in a conversation, by the rule a
    /// task space row uses: a task space with one session and no task
    /// spaces of its own opens that session, else the task space's screen.
    /// The conversation route always sits on top of the stack, so either
    /// takes the conversation's place, and Back goes to the screen under
    /// it. On the Coordinator tab's own screen nothing is under the chat,
    /// so the session or task space is pushed over it.
    private func openTaskSpaceInPlaceOfConversation(_ workspaceID: UUID) {
        let home = sessionController.homeController
        if let row = home.snapshot.subspaceRow(id: workspaceID),
           let session = ToasttySubspaceGroupPresentation.directConversation(for: row, in: home.snapshot) {
            // The selection change puts the session in the conversation's
            // place (`syncNavigationPath`).
            if session.id == screenConversationID || home.openConversation(id: session.id) { return }
        }
        home.dismissConversation()
        var path = navigationPath.synchronized(with: nil)
        if path.last != .workspace(workspaceID) { path.append(.workspace(workspaceID)) }
        navigationPath = path
    }

    private func handleDeepLink(_ url: URL) {
        guard let destination = deepLinkParser?.parse(url) else { return }
        switch sessionController.state {
        case .restoring, .keychainLocked:
            pendingDeepLinkDestination = destination
        case .paired:
            pendingDeepLinkDestination = destination
            routePendingDeepLinkIfAvailable()
        case .pairing, .unpaired, .repairNeeded, .incompatible:
            break
        }
    }

    private func routePendingDeepLinkIfAvailable() {
        guard sessionController.state.isPaired,
              let destination = pendingDeepLinkDestination
        else {
            return
        }

        switch destination {
        case .conversation(let conversationID):
            guard sessionController.homeController.conversation(id: conversationID) != nil else {
                discardPendingDeepLinkAfterLiveSnapshot()
                return
            }
            openInHome(conversationID: conversationID)
            pendingDeepLinkDestination = nil
            presentedSheet = nil
            routedDestinationSinceActivation = true
        case .workspace(let workspaceID):
            guard sessionController.homeController.workspace(id: workspaceID) != nil else {
                discardPendingDeepLinkAfterLiveSnapshot()
                return
            }
            pendingDeepLinkDestination = nil
            if workspaceID == sessionController.homeController.snapshot.coordinator?.id {
                openCoordinatorTab()
            } else {
                tabs.selected = .home
                sessionController.homeController.dismissConversation()
                navigationPath = [.workspace(workspaceID)]
            }
            presentedSheet = nil
            routedDestinationSinceActivation = true
        case .sharedDraft(let draftID):
            routeSharedDraft(draftID)
        case .task(let taskID, let conversationID):
            routeTaskAlert(taskID: taskID, conversationID: conversationID)
        }
    }

    /// A task alert opens the task's session while its task space is open,
    /// else the task's detail.
    private func routeTaskAlert(taskID: UUID, conversationID: UUID?) {
        let home = sessionController.homeController
        switch home.taskAlertRoute(taskID: taskID, conversationID: conversationID) {
        case .conversation(let id):
            guard home.conversation(id: id) != nil else { return }
            openInHome(conversationID: id)
            pendingDeepLinkDestination = nil
            presentedSheet = nil
            routedDestinationSinceActivation = true
        case .taskDetail(let id):
            pendingDeepLinkDestination = nil
            tabs.selected = .home
            home.dismissConversation()
            navigationPath = []
            presentedSheet = nil
            home.requestedTaskDetailID = id
            routedDestinationSinceActivation = true
        case .waitForLiveSnapshot:
            break
        case .unavailable:
            pendingDeepLinkDestination = nil
        }
    }

    /// Opens a draft the share extension saved over whatever screen is
    /// showing: in the New Task sheet, or in the new-session sheet, in the
    /// workspace Home would use, when the Mac cannot create tasks. A draft
    /// that cannot open yet stays saved for `queueWaitingSharedDraft`.
    private func routeSharedDraft(_ draftID: UUID) {
        let home = sessionController.homeController
        let preferences = ToasttyNewSessionPreferences()
        let sessionWorkspace = home.defaultSessionStartWorkspace(lastUsed: preferences.lastWorkspaceID)
        guard home.canCreateTasks || (home.canStartSessions && sessionWorkspace != nil) else {
            discardPendingDeepLinkAfterLiveSnapshot()
            return
        }
        // One sheet at a time. Settings closes for the draft; an open
        // New Task or new-session form keeps its own draft, and this one
        // waits for it.
        guard home.isShowingNewSessionForm == false else { return }
        guard presentedSheet == nil else {
            presentedSheet = nil
            return
        }
        pendingDeepLinkDestination = nil
        guard let draft = sharedDraftStore?.take(id: draftID) else { return }
        if home.canCreateTasks {
            sharedNewTask = ToasttyNewTaskModel(
                host: home,
                text: draft.text,
                attachments: draft.attachments,
                notice: draft.skippedItemsNotice
            )
        } else if let workspace = sessionWorkspace {
            sharedNewSession = ToasttyNewSessionModel(
                workspaceID: workspace.id,
                workspaceTitle: workspace.title,
                host: home,
                preferences: preferences,
                message: draft.text,
                attachments: draft.attachments,
                notice: draft.skippedItemsNotice
            )
        }
    }

    /// Opens a shared draft that its link did not open: the extension could
    /// not open the app, or the app could not show the draft then.
    private func queueWaitingSharedDraft() {
        guard let sharedDraftStore else { return }
        sharedDraftStore.removeExpired()
        guard pendingDeepLinkDestination == nil,
              routedDestinationSinceActivation == false,
              sessionController.pushController?.pendingConversationID == nil,
              sessionController.pushController?.pendingTaskTap == nil,
              let draftID = sharedDraftStore.waitingDraftID() else { return }
        pendingDeepLinkDestination = .sharedDraft(draftID)
        routePendingDeepLinkIfAvailable()
    }

    private func discardPendingDeepLinkAfterLiveSnapshot() {
        if sessionController.homeController.freshness == .live {
            pendingDeepLinkDestination = nil
        }
    }

    private func handleNotificationTap() {
        guard let push = sessionController.pushController else { return }
        if let tap = push.pendingTaskTap {
            pendingDeepLinkDestination = .task(tap.taskID, conversationID: tap.conversationID)
            push.consumedTaskTap()
        } else if let id = push.pendingConversationID {
            pendingDeepLinkDestination = .conversation(id)
            push.consumedConversationTap()
        } else {
            return
        }
        routePendingDeepLinkIfAvailable()
    }

    private func presentNotificationIntroIfNeeded() {
        guard presentedSheet == nil, sharedNewSession == nil, sharedNewTask == nil, navigationPath.isEmpty,
              screenConversationID == nil,
              pendingDeepLinkDestination == nil,
              sessionController.state == .paired(.live),
              sessionController.pushController?.canIntroduce == true else { return }
        presentedSheet = .notifications
    }

    private func syncNavigationPath(with selection: SelectedConversationPresentation?) {
        // The coordinator's chat is its tab's own screen, never a pushed one.
        let updated = tabs.selected == .coordinator && selection != nil && selection?.id == coordinatorConversationID
            ? []
            : navigationPath.synchronized(with: selection)
        if updated != navigationPath {
            navigationPath = updated
        }
    }

    private func conversationScreen(for conversationID: UUID, isCoordinatorRoot: Bool = false) -> some View {
        let generation = composerDrafts.generation
        let liveConversation = sessionController.liveController?.activeConversationController
        let supportsAttachments = liveConversation?.conversationID == conversationID
            ? liveConversation?.supportsAttachments == true
            : fixtureScenario == .gatedSend || fixtureScenario == .gatedSendReceipt
        return ToasttyConversationScreen(
            conversationID: conversationID,
            controller: sessionController.homeController,
            presentation: conversationPresentation(for: conversationID),
            composer: conversationComposer(for: conversationID),
            drafts: composerDrafts,
            draftDidChange: conversationDraftChange(for: conversationID, generation: generation),
            draftReplacementCompleted: { result in
                guard composerDrafts.generation == generation,
                      sessionController.homeController.conversation(id: conversationID) != nil else { return }
                composerDrafts.update { $0.completeReplacement(result, for: conversationID) }
                reconcileAttachmentDrafts()
            },
            supportsAttachments: supportsAttachments,
            addAttachments: { additions in
                guard composerDrafts.generation == generation,
                      sessionController.homeController.conversation(id: conversationID) != nil else {
                    return "This conversation is no longer available."
                }
                return composerDrafts.update { $0.addAttachments(additions, for: conversationID) }
            },
            removeAttachment: { attachmentID in
                composerDrafts.update { $0.removeAttachment(attachmentID, for: conversationID) }
                reconcileAttachmentDrafts()
            },
            loadOlder: conversationLoadOlderAction(for: conversationID),
            submitDraft: conversationSubmitAction(for: conversationID),
            interrupt: conversationInterruptAction(for: conversationID),
            releaseLocalDraft: conversationReleaseLocalDraftAction(for: conversationID),
            dismissSendReceipt: conversationReceiptDismissAction(for: conversationID),
            queuedMessageAction: conversationQueuedMessageAction(for: conversationID),
            sendFeedback: conversationSendFeedback(for: conversationID),
            interactionAnswerStates: conversationInteractionAnswerStates(for: conversationID),
            editInteractionAnswer: conversationInteractionEditAction(for: conversationID),
            submitInteractionAnswer: conversationInteractionSubmitAction(for: conversationID),
            canAcknowledgeRead: liveConversation?.conversationID == conversationID
                && liveConversation?.canAcknowledgeRead == true,
            onVisibleLiveEdge: conversationVisibleLiveEdgeAction(for: conversationID),
            openTaskSpace: openTaskSpaceInPlaceOfConversation,
            isCoordinatorRoot: isCoordinatorRoot,
            replyToMessage: { target in
                guard composerDrafts.generation == generation else { return false }
                return composerDrafts.update { $0.reply(to: target, for: conversationID) }
            },
            cancelReply: {
                guard composerDrafts.generation == generation else { return }
                composerDrafts.update { $0.cancelReply(for: conversationID) }
                // A rejected message with files waits while the draft
                // answers another message.
                reconcileAttachmentDrafts()
            },
            newMessages: conversationNewMessages(for: conversationID)
        )
        .id(conversationID)
#if DEBUG
        .overlay(alignment: .topTrailing) {
            if let entryLoadFixture, conversationID == Self.fixtureOpenPromptConversationID,
               fixtureEntryLoadStep < 2 {
                Button(fixtureEntryLoadStep == 0 && entryLoadFixture == .catchUp
                       ? "Load latest response" : "Finish catch-up") {
                    fixtureEntryLoadStep = entryLoadFixture == .catchUp ? fixtureEntryLoadStep + 1 : 2
                    // The unread status can clear on another client while this
                    // phone is loading. Entry keeps the original ready intent.
                    sessionController.homeController.update(
                        snapshot: ToasttyConversationFixture.entryLoadHome(isRead: true),
                        connectionState: .live,
                        freshness: .live
                    )
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("toastty-mobile-fixture-entry-load-\(fixtureEntryLoadStep)")
                .padding(.top, 80)
            }
        }
        .overlay(alignment: .topTrailing) {
            if controlsFixtureSubmission,
               conversationID == Self.fixtureOpenPromptConversationID,
               let pending = controlledFixtureSubmission {
                Button {
                    advanceControlledFixtureSubmission()
                } label: {
                    Text(pending.phase == .awaitingOptimistic ? "Publish optimistic row" : "Finish submission")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .foregroundStyle(ToasttyDesignTokens.inkOnAmber)
                        .background(ToasttyDesignTokens.amber, in: Capsule())
                }
                .accessibilityIdentifier(
                    pending.phase == .awaitingOptimistic
                        ? "toastty-mobile-fixture-publish-optimistic"
                        : "toastty-mobile-fixture-finish-submit"
                )
                .padding(.top, 8)
                .padding(.trailing, 12)
            }
            if fixtureSendEventOrder != nil,
               conversationID == Self.fixtureOpenPromptConversationID,
               fixtureSentText != nil, fixtureSendUpdateCount < 5 {
                Button("Next send event") {
                    advanceFixtureSendEvent()
                }
                .font(.caption.weight(.semibold))
                .padding(12)
                .foregroundStyle(ToasttyDesignTokens.inkOnAmber)
                .background(ToasttyDesignTokens.amber, in: Capsule())
                .accessibilityIdentifier("toastty-mobile-fixture-send-update-\(fixtureSendUpdateCount)")
                .padding(8)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let fixtureIncoming, fixtureIncomingTurn(for: conversationID) != nil {
                ToasttyIncomingFixtureControls(fixture: fixtureIncoming) { step in
                    applyFixtureIncoming(step, in: conversationID)
                }
            }
        }
#endif
    }

    private func workspacePreview(workspaceID: UUID, panelID: UUID) -> some View {
        let controller = sessionController.homeController
        let title = controller.workspace(id: workspaceID)?.panels.first { $0.panelID == panelID }?.title
        return ToasttyPreviewPage(selection: ToasttyPreviewSelection(
            target: .panel(workspaceID: workspaceID, panelID: panelID),
            title: title ?? "Preview", id: panelID
        ))
        .toolbar {
            if let conversation = ToasttySessionScratchpads.conversation(
                in: controller.snapshot, workspaceID: workspaceID, panelID: panelID
            ) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        // Resolve again at tap time so an ended/rebound session
                        // cannot use an association captured by an older render.
                        guard let current = ToasttySessionScratchpads.conversation(
                            in: controller.snapshot, workspaceID: workspaceID, panelID: panelID
                        ) else { return }
                        controller.openConversation(id: current.id)
                    } label: {
                        Label("Session", systemImage: "bubble.left")
                    }
                    .accessibilityHint("Open \(conversation.title)")
                    .accessibilityIdentifier("toastty-scratchpad-session")
                }
            }
        }
    }

    private var settingsPresentation: ToasttySettingsPresentation? {
        guard let paired = sessionController.pairedDevice else { return nil }
        return ToasttySettingsPresentation(
            gatewayURL: paired.gatewayURL,
            reachability: sessionController.homeController.freshness,
            projectionRunID: sessionController.liveController?.projectionRunID,
            projectionGeneration: sessionController.liveController?.projectionGeneration,
            activeConversationCursor: sessionController.liveController?.activeConversationCursor,
            device: sessionController.currentDeviceSummary,
            credentialCreatedAt: paired.credentialCreatedAt
        )
    }

    private func conversationPresentation(
        for conversationID: UUID
    ) -> ToasttyConversationPresentationState? {
#if DEBUG
        if let entryLoadFixture, conversationID == Self.fixtureOpenPromptConversationID {
            return ToasttyConversationFixture.entryLoadPresentation(
                for: conversationID, mode: entryLoadFixture, step: fixtureEntryLoadStep
            )
        }
        if isFixtureTaskSession(conversationID) {
            return ToasttyConversationFixture.gatedSendPresentation(
                for: conversationID, sendItems: fixtureSendItems, responses: fixtureIncoming?.responses ?? 0
            )
        }
        if conversationID == ToasttyMobileFixture.coordinatorConversationID {
            // As the live app: a closed chat has no transcript, and each
            // opening loads it again.
            if Self.fixtureCoordinatorReopens {
                guard sessionController.homeController.selectedConversationPresentation?.id == conversationID
                else { return nil }
                if fixtureCoordinatorIsLoaded == false { return .loading }
            }
            return ToasttyConversationFixture.coordinatorPresentation(
                for: conversationID,
                sendItems: isFixtureWorkingConversation(conversationID)
                    ? ToasttySendPresentationAdapter.makeItems(
                        from: SendReconciliationState(),
                        inputControl: fixtureInputControl,
                        readsCoordinatorMessages: true,
                        coordinatorQueue: fixtureCoordinatorQueue
                    ) + fixtureSendItems.map(ToasttySendPresentationAdapter.coordinatorItem)
                    : [],
                hasLongMessage: ProcessInfo.processInfo.environment[
                    "TOASTTY_MOBILE_FIXTURE_COORDINATOR_LONG_MESSAGE"
                ] == "1",
                quietTurns: fixtureCoordinatorQuietTurns,
                attachedImages: fixtureCoordinatorAttachedImages,
                wakeTurns: Self.fixtureCoordinatorWakeTurns,
                responses: fixtureIncoming?.responses ?? 0
            )
        }
        switch fixtureScenario {
        case .home, .reconnecting:
            let hasWork = ProcessInfo.processInfo.environment["TOASTTY_MOBILE_FIXTURE_READY_WORK"] == "1"
            let hasLongHistory = ProcessInfo.processInfo.environment["TOASTTY_MOBILE_FIXTURE_READY_HISTORY"] == "1"
            if ProcessInfo.processInfo.environment["TOASTTY_MOBILE_FIXTURE_TASK_LINKS"] == "1" {
                return ToasttyConversationFixture.taskLinkPresentation(for: conversationID)
            }
            if hasWork || hasLongHistory {
                return ToasttyConversationFixture.responseEntryPresentation(
                    for: conversationID, hasWork: hasWork, hasLongHistory: hasLongHistory
                )
            }
            return ToasttyConversationFixture.presentation(for: conversationID)
        case .localDraftRelease:
            return ToasttyConversationFixture.presentation(for: conversationID)
        case .transcriptPerformance:
            return ToasttyConversationFixture.performancePresentation(for: conversationID)
        case .transcriptResyncing:
            return ToasttyConversationFixture.presentation(for: conversationID, phase: .resyncing)
        case .transcriptStale:
            return ToasttyConversationFixture.presentation(for: conversationID, phase: .stale)
        case .transcriptTruncated:
            return ToasttyConversationFixture.truncatedPresentation(for: conversationID)
        case .transcriptPaging:
            return ToasttyConversationFixture.pagedPresentation(
                for: conversationID,
                hasLoadedOlder: fixtureHasLoadedOlderTranscript
            )
        case .transcriptLongMessage:
            return ToasttyConversationFixture.longMessagePresentation(for: conversationID)
        case .transcriptTables:
            return ToasttyConversationFixture.tablePresentation(for: conversationID)
        case .toolActivity:
            return ToasttyConversationFixture.toolActivityPresentation(for: conversationID)
        case .queueSteer:
            return ToasttyConversationFixture.gatedSendPresentation(
                for: conversationID,
                sendItems: conversationID == Self.fixtureWorkingConversationID
                    ? ToasttySendPresentationAdapter.makeItems(
                        from: SendReconciliationState(),
                        inputControl: fixtureInputControl
                    ) + fixtureSendItems
                    : []
            )
        case .gatedSend, .gatedSendReceipt:
            if let order = fixtureSendEventOrder,
               conversationID == Self.fixtureOpenPromptConversationID {
                return ToasttyConversationFixture.reconciledSendPresentation(
                    for: conversationID, sendItems: fixtureSendItems, sentText: fixtureSentText,
                    updateCount: fixtureSendUpdateCount, order: order
                )
            }
            return ToasttyConversationFixture.gatedSendPresentation(
                for: conversationID,
                sendItems: conversationID == Self.fixtureOpenPromptConversationID
                    ? fixtureSendItems
                    : [],
                hasShortResponse: ProcessInfo.processInfo.environment[
                    "TOASTTY_MOBILE_FIXTURE_SHORT_READY_RESPONSE"
                ] == "1"
            )
        case .interactionAnswer:
            return ToasttyConversationFixture.questionPresentation(
                for: conversationID,
                answers: fixtureInteractionAcceptedAnswers
            )
        case .connecting, .unpaired, .cameraDenied, .scannerUnsupported,
             .pairingFailure, .pairingPrivacy, .scannerFailure, .credentialCorrupt, nil:
            break
        }
#endif
        guard let controller = sessionController.liveController?.activeConversationController,
              controller.conversationID == conversationID else {
            return nil
        }
        return controller.transcriptPresentation
    }

#if DEBUG
    /// The fixture coordinator chat's New line: the shared rule over the
    /// fixture's rows and the fixture Mac's read point, until a send.
    /// `TOASTTY_MOBILE_FIXTURE_COORDINATOR_CHAT_READ=unsupported` is a Mac
    /// that does not share the read point.
    private var fixtureCoordinatorNewMessages: ToasttyNewMessagesMarker? {
        guard fixtureCoordinatorLineCleared == false,
              ProcessInfo.processInfo.environment["TOASTTY_MOBILE_FIXTURE_COORDINATOR_CHAT_READ"] != "unsupported"
        else { return nil }
        let rows = ToasttyConversationFixture.coordinatorPresentation(
            for: ToasttyMobileFixture.coordinatorConversationID,
            hasLongMessage: ProcessInfo.processInfo.environment["TOASTTY_MOBILE_FIXTURE_COORDINATOR_LONG_MESSAGE"] == "1",
            quietTurns: fixtureCoordinatorQuietTurns,
            attachedImages: fixtureCoordinatorAttachedImages,
            wakeTurns: Self.fixtureCoordinatorWakeTurns
        ).rows
        return CoordinatorChatReadPoint.marker(in: rows, after: sessionController.homeController.snapshot.coordinatorChatRead)
    }

    /// `TOASTTY_MOBILE_FIXTURE_COORDINATOR_WAKE_TURNS=<n>` adds n wake
    /// turns to the fixture coordinator chat, for a long chat.
    private static let fixtureCoordinatorWakeTurns = Int(
        ProcessInfo.processInfo.environment["TOASTTY_MOBILE_FIXTURE_COORDINATOR_WAKE_TURNS"] ?? ""
    ) ?? 0

    /// `TOASTTY_MOBILE_FIXTURE_COORDINATOR_REOPENS=1`: the fixture
    /// coordinator chat has no transcript while it is closed and loads for a
    /// moment each time it opens, as the live app's does.
    private static let fixtureCoordinatorReopens =
        ProcessInfo.processInfo.environment["TOASTTY_MOBILE_FIXTURE_COORDINATOR_REOPENS"] == "1"

    /// `TOASTTY_MOBILE_FIXTURE_COORDINATOR_QUIET_TURNS=1` ends the fixture
    /// coordinator chat with two quiet wake turns, from a Mac that shares
    /// the marks; `unsupported` is an older Mac that does not.
    private var fixtureCoordinatorQuietTurns: ToasttyConversationFixture.CoordinatorQuietTurns {
        switch ProcessInfo.processInfo.environment["TOASTTY_MOBILE_FIXTURE_COORDINATOR_QUIET_TURNS"] {
        case "1": .shared
        case "unsupported": .unshared
        default: .none
        }
    }

    /// `TOASTTY_MOBILE_FIXTURE_COORDINATOR_IMAGES=1` adds a message with
    /// images to the fixture coordinator chat, from a Mac that serves them;
    /// `unsupported` is an older Mac that does not.
    private var fixtureCoordinatorAttachedImages: ToasttyConversationFixture.CoordinatorAttachedImages {
        switch ProcessInfo.processInfo.environment["TOASTTY_MOBILE_FIXTURE_COORDINATOR_IMAGES"] {
        case "1": .served
        case "unsupported": .notServed
        default: .none
        }
    }
#endif

    /// The coordinator chat's New line, from the read point the Mac shares.
    private func conversationNewMessages(for conversationID: UUID) -> ToasttyNewMessagesMarker? {
#if DEBUG
        if conversationID == ToasttyMobileFixture.coordinatorConversationID, fixtureScenario != nil {
            // As the live app: no line while the chat is closed or loads.
            if Self.fixtureCoordinatorReopens,
               fixtureCoordinatorIsLoaded == false
                || sessionController.homeController.selectedConversationPresentation?.id != conversationID {
                return nil
            }
            return fixtureCoordinatorNewMessages
        }
#endif
        guard let controller = sessionController.liveController?.activeConversationController,
              controller.conversationID == conversationID else {
            return nil
        }
        return controller.coordinatorNewMessages
    }

    private func conversationSendFeedback(for conversationID: UUID) -> ToasttyOutcomeFeedback? {
        guard let controller = sessionController.liveController?.activeConversationController,
              controller.conversationID == conversationID else {
            return nil
        }
        return controller.sendFeedback
    }

    private func conversationLoadOlderAction(
        for conversationID: UUID
    ) -> () -> Void {
#if DEBUG
        if fixtureScenario == .transcriptPaging {
            return { fixtureHasLoadedOlderTranscript = true }
        }
#endif
        if let controller = sessionController.liveController?.activeConversationController,
           controller.conversationID == conversationID {
            return {
                Task { await controller.loadOlder() }
            }
        }
        return {}
    }

    private func conversationComposer(
        for conversationID: UUID
    ) -> ToasttyComposerPresentation? {
        guard let conversation = sessionController.homeController.conversation(id: conversationID),
              let presentation = sessionController.liveController?.composerPresentation(for: conversation) else {
            return fixtureComposer(for: conversationID)
        }
        return presentation
    }

    private func conversationDraftChange(for conversationID: UUID, generation: UUID) -> (String, UInt64) -> Void {
        { text, editRevision in
            guard composerDrafts.generation == generation,
                  sessionController.homeController.conversation(id: conversationID) != nil else { return }
            composerDrafts.update { $0.updateDraft(text, for: conversationID, editRevision: editRevision) }
            reconcileAttachmentDrafts()
            if let controller = sessionController.liveController?.activeConversationController,
               controller.conversationID == conversationID {
                controller.draftDidChange()
            }
        }
    }

    private func conversationSubmitAction(for conversationID: UUID) -> (RemoteMessageDeliveryMode?) -> Bool {
        { deliveryMode in
            guard let submission = composerDrafts.update({ $0.beginSubmission(for: conversationID) }) else {
                return false
            }
            recordDiagnostic(.sendStarted)
            guard let controller = sessionController.liveController?.activeConversationController,
                  controller.conversationID == conversationID else {
                return fixtureSubmit(submission, deliveryMode: deliveryMode)
            }
            Task { @MainActor in
                let outcome = await controller.send(
                    submission.sentText,
                    attachments: submission.attachments,
                    deliveryMode: deliveryMode
                )
                finishSubmission(submission, outcome: outcome)
            }
            return true
        }
    }

    private func conversationInterruptAction(for conversationID: UUID) -> () -> Void {
        {
            guard let controller = sessionController.liveController?.activeConversationController,
                  controller.conversationID == conversationID else {
#if DEBUG
                fixtureInterrupt(conversationID)
#endif
                return
            }
            Task { await controller.interrupt() }
        }
    }

    private func conversationReleaseLocalDraftAction(
        for conversationID: UUID
    ) -> (RemoteInputEpoch) -> Void {
        { epoch in
            guard let controller = sessionController.liveController?.activeConversationController,
                  controller.conversationID == conversationID else {
#if DEBUG
                fixtureReleaseLocalDraft(conversationID)
#endif
                return
            }
            Task { await controller.releaseLocalDraft(expectedDraftEpoch: epoch) }
        }
    }

    /// Edit and Steer now first take the message out of the Mac's queue, and
    /// act on its text only when the Mac confirms it was still waiting. A
    /// message the Mac already typed is left alone.
    private func conversationQueuedMessageAction(
        for conversationID: UUID
    ) -> (ToasttyQueuedMessageAction) -> Void {
        { action in
            guard let controller = sessionController.liveController?.activeConversationController,
                  controller.conversationID == conversationID else {
#if DEBUG
                fixtureQueuedMessageAction(action, conversationID: conversationID)
#endif
                return
            }
            // The bubble can show other text than was sent, such as a reply
            // without its first line and quote; the Mac's queue holds it.
            let readsReplies = conversationID == coordinatorConversationID
            Task { @MainActor in
                switch action {
                case .remove(let clientRequestID):
                    _ = await controller.removeQueuedMessage(clientRequestID)
                case .edit(let clientRequestID, let shown):
                    let text = controller.queuedMessageText(clientRequestID) ?? shown
                    guard queuedEditIsAllowed(text, readsReplies: readsReplies, for: conversationID),
                          await controller.removeQueuedMessage(clientRequestID) else { return }
                    restoreQueuedMessage(text, readsReplies: readsReplies, for: conversationID)
                case .steer(let clientRequestID, let shown):
                    let text = controller.queuedMessageText(clientRequestID) ?? shown
                    guard await controller.removeQueuedMessage(clientRequestID) else { return }
                    let outcome = await controller.send(text, deliveryMode: .steer)
                    if case .notEnqueued = outcome {
                        restoreQueuedMessage(text, readsReplies: readsReplies, for: conversationID)
                    }
                case .resume:
                    await controller.resumeQueue()
                }
            }
        }
    }

    /// In the coordinator's chat the draft answers one message at most, so
    /// Edit leaves a waiting reply where it is while the draft answers
    /// another, and says why.
    private func queuedEditIsAllowed(_ text: String, readsReplies: Bool, for conversationID: UUID) -> Bool {
        guard readsReplies, let refusal = composerDrafts.state.queuedReplyEditRefusal(text, for: conversationID) else {
            return true
        }
        composerDrafts.update { $0.showReplyNotice(refusal, for: conversationID) }
        return false
    }

    /// A waiting message back in the draft. In the coordinator's chat a
    /// reply comes back as a reply.
    private func restoreQueuedMessage(_ text: String, readsReplies: Bool, for conversationID: UUID) {
        if readsReplies {
            composerDrafts.update { $0.restoreQueuedReply(text, for: conversationID) }
        } else {
            composerDrafts.update { $0.restoreDraft(text, for: conversationID) }
        }
    }

    private func conversationReceiptDismissAction(
        for conversationID: UUID
    ) -> (String) -> Void {
        { clientRequestID in
            composerDrafts.update { $0.discardAttachmentRecovery(clientRequestID: clientRequestID, for: conversationID) }
            guard let controller = sessionController.liveController?.activeConversationController,
                  controller.conversationID == conversationID else {
                fixtureDismissReceipt(clientRequestID)
                return
            }
            Task { await controller.dismissSendReceipt(clientRequestID) }
        }
    }

    private func conversationInteractionAnswerStates(
        for conversationID: UUID
    ) -> [RemotePendingInteraction.ID: ToasttyInteractionAnswerState] {
        if fixtureScenario == .interactionAnswer,
           let state = fixtureInteractionAnswerState {
            return [state.key.interactionID: state]
        }
        guard let controller = sessionController.liveController?.activeConversationController,
              controller.conversationID == conversationID else { return [:] }
        return controller.interactionAnswerStates
    }

    private func conversationInteractionEditAction(
        for conversationID: UUID
    ) -> (RemotePendingInteraction.ID, ToasttyInteractionAnswerEdit) -> Void {
        { interactionID, edit in
            if fixtureScenario == .interactionAnswer,
               var state = fixtureInteractionAnswerState,
               state.key.interactionID == interactionID {
                state.apply(edit)
                fixtureInteractionAnswerState = state
                return
            }
            guard let controller = sessionController.liveController?.activeConversationController,
                  controller.conversationID == conversationID else { return }
            controller.editInteractionAnswer(interactionID: interactionID, edit: edit)
        }
    }

    private func conversationInteractionSubmitAction(
        for conversationID: UUID
    ) -> (RemotePendingInteraction.ID) -> Void {
        { interactionID in
            if fixtureScenario == .interactionAnswer,
               var state = fixtureInteractionAnswerState,
               state.key.interactionID == interactionID,
               state.canSubmit,
               let answers = state.canonicalAnswers {
                state.retryRequest = RemoteQuestionAnswerRequest(
                    conversationID: RemoteConversationID(rawValue: conversationID),
                    interactionID: interactionID,
                    responseID: state.key.responseID,
                    expectedInputEpoch: state.key.inputEpoch,
                    clientRequestID: "fixture-answer",
                    answers: answers
                )
                state.status = .submitting
                fixtureInteractionAnswerState = state
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard var current = fixtureInteractionAnswerState,
                          current.key == state.key else { return }
                    current.status = .awaitingClaude
                    fixtureInteractionAnswerState = current
                    try? await Task.sleep(for: .milliseconds(700))
                    guard var waiting = fixtureInteractionAnswerState,
                          waiting.key == state.key else { return }
                    waiting.status = .resolved(answers)
                    fixtureInteractionAnswerState = waiting
                    fixtureInteractionAcceptedAnswers = answers
                }
                return
            }
            guard let controller = sessionController.liveController?.activeConversationController,
                  controller.conversationID == conversationID else { return }
            Task { await controller.submitInteractionAnswer(interactionID: interactionID) }
        }
    }

    private func conversationVisibleLiveEdgeAction(
        for conversationID: UUID
    ) -> (MobileSessionStatus) -> Void {
        { presentationStatus in
            guard let controller = sessionController.liveController?.activeConversationController,
                  controller.conversationID == conversationID else {
                return
            }
            controller.acknowledgeVisibleTranscript(
                presentationStatus: presentationStatus
            )
        }
    }

#if DEBUG
    private static let fixtureTurnEpoch = RemoteInputEpoch(
        bindingID: UUID(uuidString: "F1000000-0000-0000-0000-000000000002")!,
        counter: 9
    )

    private var fixtureInputControl: RemoteConversationInputControl {
        RemoteConversationInputControl(
            turnEpoch: fixtureTurnStopped ? nil : Self.fixtureTurnEpoch,
            canQueue: true,
            canSteer: !fixtureTurnStopped,
            canInterrupt: !fixtureTurnStopped,
            queuedMessages: fixtureQueuedMessages,
            isQueuePaused: fixtureQueuePaused
        )
    }

    private func fixtureQueueSteerComposer(agentDisplayName: String = "Codex") -> ToasttyComposerPresentation {
        let control = fixtureInputControl
        let authority: ConversationComposerAuthority
        if let turnEpoch = control.turnEpoch {
            authority = ConversationComposerAuthority(
                stamp: ConversationComposerStamp(
                    connectionGeneration: 1,
                    streamSnapshotOrdinal: 1,
                    projectionRunID: RemoteProjectionRunID(
                        rawValue: UUID(uuidString: "F2000000-0000-0000-0000-000000000002")!
                    ),
                    projectionGeneration: 1,
                    latestSequence: 13,
                    inputEpoch: turnEpoch,
                    deliveryMode: .queue
                ),
                inputAvailability: .unavailable(reason: .known(.working)),
                inputControl: control
            )
        } else {
            // After a stop the fixture host reports an interrupted turn with
            // no prompt yet, as a real host does until stabilization opens it.
            authority = ConversationComposerAuthority(
                inputAvailability: .unavailable(reason: .known(.interrupted)),
                gateFailure: .inputUnavailable,
                inputControl: control
            )
        }
        return ToasttyComposerPresentation.make(agentDisplayName: agentDisplayName, authority: authority)
    }

    private func fixtureReleaseLocalDraft(_ conversationID: UUID) {
        guard fixtureScenario == .localDraftRelease,
              conversationID == Self.fixtureLocalDraftConversationID else { return }
        fixtureLocalDraftReleaseAttempts += 1
    }

    private func fixtureLocalDraftComposer() -> ToasttyComposerPresentation {
        let epoch = RemoteInputEpoch(
            bindingID: UUID(uuidString: "F1000000-0000-0000-0000-000000000008")!,
            counter: 6
        )
        guard fixtureLocalDraftReleaseAttempts >= 2 else {
            return ToasttyComposerPresentation.make(
                agentDisplayName: "Claude",
                authority: ConversationComposerAuthority(
                    inputAvailability: .localDraft(epoch: epoch.next()),
                    gateFailure: .inputUnavailable
                ),
                releasableLocalDraftEpoch: epoch.next(),
                localDraftReleaseRefusal: fixtureLocalDraftReleaseAttempts == 1 ? .macTypedAgain : nil
            )
        }
        return ToasttyComposerPresentation.make(
            agentDisplayName: "Claude",
            authority: ConversationComposerAuthority(
                stamp: ConversationComposerStamp(
                    connectionGeneration: 1,
                    streamSnapshotOrdinal: 1,
                    projectionRunID: RemoteProjectionRunID(
                        rawValue: UUID(uuidString: "F2000000-0000-0000-0000-000000000008")!
                    ),
                    projectionGeneration: 1,
                    latestSequence: 13,
                    inputEpoch: epoch
                ),
                inputAvailability: .openPrompt(epoch: epoch)
            )
        )
    }

    /// The conversation whose turn the queue and steer fixture runs: the
    /// working session of that scenario, or the coordinator's chat while
    /// the fixture coordinator works.
    private func isFixtureWorkingConversation(_ conversationID: UUID) -> Bool {
        switch fixtureScenario {
        case .queueSteer:
            conversationID == Self.fixtureWorkingConversationID
        case .home:
            if let turn = fixtureIncomingTurn(for: conversationID) {
                turn == .working
            } else {
                conversationID == ToasttyMobileFixture.coordinatorConversationID
                    && sessionController.homeController.snapshot.coordinatorMark == .working
            }
        default:
            false
        }
    }

    /// The incoming fixture's turn in the coordinator's chat or the task
    /// fixture's session; nil elsewhere and without the fixture.
    private func fixtureIncomingTurn(for conversationID: UUID) -> ToasttyIncomingFixture.Turn? {
        guard let fixtureIncoming,
              conversationID == ToasttyMobileFixture.coordinatorConversationID
                || isFixtureTaskSession(conversationID) else { return nil }
        return fixtureIncoming.turn
    }

    /// Applies one step of what the Mac sends. A status change and a turn's
    /// end also change the coordinator's status in the home snapshot, as the
    /// Mac's session list does.
    private func applyFixtureIncoming(_ step: ToasttyIncomingFixture.Step, in conversationID: UUID) {
        fixtureIncoming?.apply(step)
        let snapshot = sessionController.homeController.snapshot
        let status: RemoteSessionPresentationStatus
        switch step {
        case .status:
            status = snapshot.coordinatorMark == .working ? .ready : .working
        case .turnEnd where conversationID == ToasttyMobileFixture.coordinatorConversationID:
            status = .ready
        default:
            return
        }
        guard snapshot.coordinatorMark != nil else { return }
        let base = MobileHomeSnapshot(
            hostName: snapshot.hostName,
            workspaces: snapshot.workspaces.filter { $0.isCoordinator == false },
            taskBoard: snapshot.taskBoard
        )
        sessionController.homeController.update(
            snapshot: ToasttyMobileFixture.withCoordinator(base, status: status, chatRead: snapshot.coordinatorChatRead),
            connectionState: .live,
            freshness: .live
        )
    }

    /// The session in the task fixture's early-session-titles task space
    /// takes messages at an open prompt with
    /// TOASTTY_MOBILE_FIXTURE_TASK_SESSION_SEND=1, so a test can send from a
    /// task's session, under its task bar.
    private func isFixtureTaskSession(_ conversationID: UUID) -> Bool {
        conversationID == Self.fixtureTaskSessionConversationID
            && ProcessInfo.processInfo.environment["TOASTTY_MOBILE_FIXTURE_TASK_SESSION_SEND"] == "1"
    }

    private func fixtureInterrupt(_ conversationID: UUID) {
        guard isFixtureWorkingConversation(conversationID) else { return }
        fixtureTurnStopped = true
        fixtureQueuePaused = !fixtureQueuedMessages.isEmpty
        // As the Mac: the Stop sets the coordinator's waiting messages
        // aside too, and names what it holds.
        if conversationID == ToasttyMobileFixture.coordinatorConversationID, Self.fixtureCoordinatorQueueMode == .shared {
            fixtureCoordinatorQueueEntries = fixtureCoordinatorQueueEntries.map {
                var entry = $0
                entry.isHeld = true
                return entry
            }
            fixtureCoordinatorHeldSetToken = fixtureQueuePaused || fixtureCoordinatorQueueEntries.isEmpty == false
                ? UUID().uuidString : nil
        }
    }

    /// `TOASTTY_MOBILE_FIXTURE_COORDINATOR_QUEUE`: `1` is a Mac that shares
    /// the coordinator's own queue, with messages waiting in both of the
    /// coordinator's queues; `unsupported` is an older Mac, whose chat lists
    /// only the conversation's own queue.
    enum FixtureCoordinatorQueueMode {
        case shared, unshared
    }

    static var fixtureCoordinatorQueueMode: FixtureCoordinatorQueueMode? {
        switch ProcessInfo.processInfo.environment["TOASTTY_MOBILE_FIXTURE_COORDINATOR_QUEUE"] {
        case "1": .shared
        case "unsupported": .unshared
        default: nil
        }
    }

    private var fixtureCoordinatorQueue: ToasttySendPresentationAdapter.CoordinatorQueue? {
        guard Self.fixtureCoordinatorQueueMode == .shared else { return nil }
        return .init(
            queue: RemoteCoordinatorQueue(
                revision: "fixture",
                conversationID: RemoteConversationID(rawValue: ToasttyMobileFixture.coordinatorConversationID),
                heldSetToken: fixtureCoordinatorHeldSetToken,
                entries: fixtureCoordinatorQueueEntries
            ),
            mayChange: true,
            removeFailures: fixtureCoordinatorRemoveFailures
        )
    }

    /// `TOASTTY_MOBILE_FIXTURE_COORDINATOR_QUEUE_REMOVE_FAILS=1`: the Mac
    /// cannot save its queue, so it answers each Remove of the
    /// coordinator's own messages with `failed`.
    private static var fixtureCoordinatorRemoveFails: Bool {
        ProcessInfo.processInfo.environment["TOASTTY_MOBILE_FIXTURE_COORDINATOR_QUEUE_REMOVE_FAILS"] == "1"
    }

    private func fixtureQueuedMessageAction(_ action: ToasttyQueuedMessageAction, conversationID: UUID) {
        guard isFixtureWorkingConversation(conversationID) else { return }
        switch action {
        case .remove(let clientRequestID):
            fixtureQueuedMessages.removeAll { $0.clientRequestID == clientRequestID }
            if Self.fixtureCoordinatorRemoveFails, fixtureCoordinatorQueueEntries.contains(where: { $0.id == clientRequestID }) {
                fixtureCoordinatorRemoveFailures.insert(clientRequestID)
            } else {
                fixtureCoordinatorQueueEntries.removeAll { $0.id == clientRequestID }
            }
        case .edit(let clientRequestID, let shown):
            let text = fixtureQueuedMessages.first { $0.clientRequestID == clientRequestID }?.text ?? shown
            let readsReplies = conversationID == coordinatorConversationID
            guard queuedEditIsAllowed(text, readsReplies: readsReplies, for: conversationID) else { return }
            fixtureQueuedMessages.removeAll { $0.clientRequestID == clientRequestID }
            restoreQueuedMessage(text, readsReplies: readsReplies, for: conversationID)
        case .steer(let clientRequestID, let shown):
            let text = fixtureQueuedMessages.first { $0.clientRequestID == clientRequestID }?.text ?? shown
            fixtureQueuedMessages.removeAll { $0.clientRequestID == clientRequestID }
            fixtureSendItems.append(ToasttySendPresentationItem(
                clientRequestID: "fixture-steered-\(fixtureSendItems.count + 1)",
                text: text,
                content: .optimistic(response: .accepted)
            ))
        case .resume:
            fixtureQueuePaused = false
            // One Resume lets go what the Stop holds in both queues. The
            // user sends an interrupted message again: it is typed as any
            // other.
            fixtureCoordinatorQueueEntries = fixtureCoordinatorQueueEntries.map {
                var entry = $0
                entry.isHeld = false
                entry.typingWasInterrupted = false
                return entry
            }
        }
        if fixtureQueuedMessages.isEmpty { fixtureQueuePaused = false }
        if fixtureQueuePaused == false, fixtureCoordinatorQueueEntries.allSatisfy({ $0.isHeld == false }) {
            fixtureCoordinatorHeldSetToken = nil
        }
    }
#endif

    private func fixtureComposer(for conversationID: UUID) -> ToasttyComposerPresentation? {
#if DEBUG
        if fixtureScenario == .queueSteer {
            return conversationID == Self.fixtureWorkingConversationID ? fixtureQueueSteerComposer() : nil
        }
        if fixtureIncomingTurn(for: conversationID) == .closing {
            return ToasttyIncomingFixture.closingComposer
        }
        // The coordinator's chat while the fixture coordinator works.
        if isFixtureWorkingConversation(conversationID) {
            return fixtureQueueSteerComposer(agentDisplayName: "Claude")
        }
        if fixtureScenario == .localDraftRelease {
            return conversationID == Self.fixtureLocalDraftConversationID ? fixtureLocalDraftComposer() : nil
        }
        // The coordinator's chat takes messages, as in the proposal's mockup,
        // and so does a task's session when a test asks for it.
        let isOpenClaudeSession = fixtureScenario == .home
            && (conversationID == ToasttyMobileFixture.coordinatorConversationID
                || isFixtureTaskSession(conversationID))
        guard isOpenClaudeSession
            || (fixtureScenario == .gatedSend || fixtureScenario == .gatedSendReceipt)
            && conversationID == Self.fixtureOpenPromptConversationID else { return nil }
        let epoch = RemoteInputEpoch(
            bindingID: UUID(uuidString: "F1000000-0000-0000-0000-000000000001")!,
            counter: 4
        )
        let stamp = ConversationComposerStamp(
            connectionGeneration: 1,
            streamSnapshotOrdinal: 1,
            projectionRunID: RemoteProjectionRunID(
                rawValue: UUID(uuidString: "F2000000-0000-0000-0000-000000000001")!
            ),
            projectionGeneration: 1,
            latestSequence: 13,
            inputEpoch: epoch
        )
        let availability = CompatibleInputAvailability.openPrompt(epoch: epoch)
        let authority = fixtureComposerIsReserved
            ? ConversationComposerAuthority(
                stamp: stamp,
                inputAvailability: availability,
                gateFailure: .sendAlreadyReserved
            )
            : ConversationComposerAuthority(
                stamp: stamp,
                inputAvailability: availability
            )
        return ToasttyComposerPresentation.make(
            agentDisplayName: isOpenClaudeSession ? "Claude" : "Codex",
            authority: authority
        )
#else
        nil
#endif
    }

    private func fixtureSubmit(
        _ submission: ToasttyComposerSubmission,
        deliveryMode: RemoteMessageDeliveryMode?
    ) -> Bool {
#if DEBUG
        if fixtureScenario == .queueSteer || isFixtureWorkingConversation(submission.conversationID) {
            guard isFixtureWorkingConversation(submission.conversationID),
                  fixtureTurnStopped == false else {
                finishSubmission(submission, outcome: .notEnqueued(.inputUnavailable))
                return false
            }
            fixtureQueueSubmissionCount += 1
            if submission.conversationID == ToasttyMobileFixture.coordinatorConversationID {
                fixtureCoordinatorLineCleared = true
            }
            let clientRequestID = "fixture-queued-\(fixtureQueueSubmissionCount)"
            if deliveryMode == .steer {
                fixtureSendItems.append(ToasttySendPresentationItem(
                    clientRequestID: clientRequestID,
                    text: submission.sentText,
                    content: .optimistic(response: .accepted)
                ))
            } else {
                fixtureQueuedMessages.append(RemoteQueuedMessage(
                    clientRequestID: clientRequestID,
                    text: submission.sentText,
                    attachmentCount: submission.attachments.count,
                    enqueuedAt: Date()
                ))
            }
            finishSubmission(submission, outcome: .enqueued(clientRequestID: clientRequestID))
            return true
        }
        if isFixtureTaskSession(submission.conversationID) {
            let clientRequestID = "fixture-task-session-\(fixtureSendItems.count + 1)"
            fixtureSendItems.append(ToasttySendPresentationItem(
                clientRequestID: clientRequestID,
                text: submission.text,
                content: .optimistic(response: .accepted)
            ))
            finishSubmission(submission, outcome: .enqueued(clientRequestID: clientRequestID))
            return true
        }
        guard fixtureScenario == .gatedSend || fixtureScenario == .gatedSendReceipt,
              submission.conversationID == Self.fixtureOpenPromptConversationID else {
            finishSubmission(
                submission,
                outcome: .notEnqueued(.conversationNotOpen)
            )
            return false
        }
        let clientRequestID = "fixture-enqueued-\(fixtureSendItems.count + 1)"
        if controlsFixtureSubmission {
            controlledFixtureSubmission = ControlledFixtureSubmission(
                submission: submission,
                clientRequestID: clientRequestID,
                phase: .awaitingOptimistic
            )
            return true
        }
        appendFixtureOptimisticSend(submission, clientRequestID: clientRequestID)
        finishSubmission(
            submission,
            outcome: .enqueued(clientRequestID: clientRequestID)
        )
        return true
#else
        finishSubmission(
            submission,
            outcome: .notEnqueued(.conversationNotOpen)
        )
        return false
#endif
    }

#if DEBUG
    private struct ControlledFixtureSubmission {
        enum Phase {
            case awaitingOptimistic
            case awaitingCompletion
        }

        let submission: ToasttyComposerSubmission
        let clientRequestID: String
        var phase: Phase
    }

    private func appendFixtureOptimisticSend(
        _ submission: ToasttyComposerSubmission,
        clientRequestID: String
    ) {
        if fixtureSendEventOrder != nil {
            fixtureSentText = submission.text
            fixtureSendUpdateCount = 0
        }
        fixtureSendItems.append(ToasttySendPresentationItem(
            clientRequestID: clientRequestID,
            text: submission.sentText,
            content: .optimistic(response: .accepted)
        ))
        fixtureComposerIsReserved = true
    }

    private func advanceFixtureSendEvent() {
        guard let order = fixtureSendEventOrder, fixtureSendUpdateCount < 5 else { return }
        fixtureSendUpdateCount += 1
        if order.hasCanonicalEcho(after: fixtureSendUpdateCount) {
            fixtureSendItems.removeAll()
        }
        let home = sessionController.homeController
        let workspaces = home.snapshot.workspaces.map { workspace in
            workspace.withConversations(workspace.conversations.map { conversation in
                guard conversation.id == Self.fixtureOpenPromptConversationID else { return conversation }
                return MobileConversation(
                    id: conversation.id, workspaceID: conversation.workspaceID,
                    workspaceTitle: conversation.workspaceTitle, cwd: conversation.cwd, agent: conversation.agent,
                    title: conversation.title,
                    state: order.hasWorkingStatus(after: fixtureSendUpdateCount) ? MobileSessionStatus.working : .ready,
                    inputAvailability: conversation.inputAvailability, age: conversation.age,
                    lastActivity: conversation.lastActivity, executionProfile: conversation.executionProfile,
                    workspaceTabID: conversation.workspaceTabID, workspaceTabTitle: conversation.workspaceTabTitle
                )
            })
        }
        home.update(
            snapshot: home.snapshot.withWorkspaces(workspaces),
            connectionState: home.connectionState, freshness: home.freshness
        )
    }

    private func advanceControlledFixtureSubmission() {
        guard let pending = controlledFixtureSubmission else { return }
        switch pending.phase {
        case .awaitingOptimistic:
            appendFixtureOptimisticSend(pending.submission, clientRequestID: pending.clientRequestID)
            controlledFixtureSubmission?.phase = .awaitingCompletion
        case .awaitingCompletion:
            finishSubmission(
                pending.submission,
                outcome: .enqueued(clientRequestID: pending.clientRequestID)
            )
            controlledFixtureSubmission = nil
        }
    }
#endif

    private func fixtureDismissReceipt(_ clientRequestID: String) {
        fixtureSendItems.removeAll { $0.clientRequestID == clientRequestID }
    }

    private static func initialFixtureSendItems(
        for scenario: ToasttyMobileFixtureScenario?
    ) -> [ToasttySendPresentationItem] {
        guard scenario == .gatedSendReceipt else { return [] }
        return [ToasttySendPresentationItem(
            clientRequestID: "fixture-delivery-unconfirmed",
            text: "Use build 413 and keep the release as a draft.",
            content: .receipt(.init(kind: .deliveryUnconfirmed))
        )]
    }

    private static let fixtureOpenPromptConversationID = UUID(
        uuidString: "B1000000-0000-0000-0000-000000000007"
    )!

    /// The fixture home's working Codex session ("Sparkle updater fix").
    private static let fixtureWorkingConversationID = UUID(
        uuidString: "B1000000-0000-0000-0000-000000000002"
    )!

    /// The task fixture's one session in early-session-titles.
    private static let fixtureTaskSessionConversationID = UUID(
        uuidString: "B1000000-0000-0000-0000-000000000010"
    )!

    /// The fixture home's Claude session paused by a Mac draft ("Smoke test triage").
    private static let fixtureLocalDraftConversationID = UUID(
        uuidString: "B1000000-0000-0000-0000-000000000008"
    )!

    private func resetComposerPresentation() {
        composerDrafts.update { $0.reset() }
#if DEBUG
        controlledFixtureSubmission = nil
#endif
        fixtureSendItems.removeAll(keepingCapacity: false)
        fixtureComposerIsReserved = false
        fixtureQueuedMessages.removeAll(keepingCapacity: false)
        fixtureQueuePaused = false
        fixtureTurnStopped = false
        fixtureCoordinatorQueueEntries.removeAll(keepingCapacity: false)
        fixtureCoordinatorHeldSetToken = nil
        fixtureCoordinatorRemoveFailures.removeAll()
        fixtureLocalDraftReleaseAttempts = 0
    }

    private func observeSessionState(_ state: AppSessionState) {
        let events = ToasttyAppDiagnosticProjection.events(
            from: diagnosedSessionState,
            to: state
        )
        diagnosedSessionState = state
        for event in events {
            recordDiagnostic(event)
        }
    }

    private func finishSubmission(
        _ submission: ToasttyComposerSubmission,
        outcome: ConversationSendOutcome
    ) {
        composerDrafts.update { $0.finishSubmission(submission, outcome: outcome) }
        reconcileAttachmentDrafts()
        recordDiagnostic(ToasttyAppDiagnosticProjection.event(for: outcome))
    }

    private func reconcileAttachmentDrafts() {
        guard let controller = sessionController.liveController?.activeConversationController else { return }
        composerDrafts.update { $0.reconcileAttachments(controller.sendReconciliation, for: controller.conversationID) }
    }

    private func recordDiagnostic(_ event: ToasttyConnectionDiagnosticEvent) {
        ToasttyDiagnosticLogger.record(event, in: &diagnostics)
    }

    private func pruneComposerState(to snapshot: MobileHomeSnapshot) {
        let conversationIDs = Set(
            snapshot.workspaces.flatMap(\.conversations).map(\.id)
        )
        composerDrafts.update { $0.retainConversations(conversationIDs) }
        if conversationIDs.contains(Self.fixtureOpenPromptConversationID) == false {
            fixtureSendItems.removeAll(keepingCapacity: false)
#if DEBUG
            controlledFixtureSubmission = nil
#endif
        }
    }

    @MainActor
    private func unpair() async {
        if await sessionController.unpairCurrentDevice() { presentedSheet = nil }
    }
}

private struct RemovedConversationBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                .foregroundStyle(ToasttyDesignTokens.amberText)
            Text(message)
                .font(.caption)
                .foregroundStyle(ToasttyDesignTokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ToasttyDesignTokens.secondaryText)
            .accessibilityLabel("Dismiss notice")
        }
        .padding(.leading, 14)
        .background(ToasttyDesignTokens.elevatedSurface)
        .overlay {
            RoundedRectangle(
                cornerRadius: ToasttyDesignTokens.cardCornerRadius,
                style: .continuous
            )
            .stroke(ToasttyDesignTokens.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(
            cornerRadius: ToasttyDesignTokens.cardCornerRadius,
            style: .continuous
        ))
        .padding(.horizontal, 14)
        .frame(maxWidth: 560)
        .task {
            try? await Task.sleep(for: .seconds(6))
            guard Task.isCancelled == false else { return }
            dismiss()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityIdentifier("toastty-mobile-removed-conversation-banner")
    }
}

private struct PairedConnectionBanner: View {
    let presentation: PairedConnectionPresentation

    var body: some View {
        if let content {
            Label(content.message, systemImage: content.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(content.color)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(ToasttyDesignTokens.elevatedSurface)
                .accessibilityIdentifier(content.identifier)
        }
    }

    private var content: (message: String, symbol: String, color: Color, identifier: String)? {
        switch presentation {
        case .connecting, .live, .reconnecting, .unreachable:
            nil
        case .authorizationDenied:
            ("This device does not have access to that action. Change its scopes on your Mac.", "lock.fill", ToasttyDesignTokens.red, "toastty-mobile-authorization-banner")
        }
    }
}

#if DEBUG
/// How many times a transcript's body has run, as the accessibility value
/// of a UIKit view. UIKit reads it when a UI test asks, so the count shows
/// without updating any SwiftUI view.
private struct ToasttyTranscriptBodyCountElement: UIViewRepresentable {
    func makeUIView(context: Context) -> CountView {
        CountView()
    }

    func updateUIView(_ view: CountView, context: Context) {}

    final class CountView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityLabel = "Transcript body count"
            accessibilityIdentifier = "toastty-mobile-fixture-transcript-body-count"
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override var accessibilityValue: String? {
            get { String(ToasttyTranscriptBodyCount.value) }
            set {}
        }
    }
}
#endif

#Preview("Fixture home") {
    ToasttyMobileRootView(configuration: ToasttyMobileAppConfiguration(
        environment: ["TOASTTY_MOBILE_USE_FIXTURE": "1"],
        infoDictionary: [:]
    ))
}

#Preview("Pairing") {
    ToasttyMobileRootView(configuration: ToasttyMobileAppConfiguration(
        environment: [
            "TOASTTY_MOBILE_USE_FIXTURE": "1",
            "TOASTTY_MOBILE_FIXTURE_SCENARIO": "unpaired",
        ],
        infoDictionary: [:]
    ))
}

#if DEBUG
/// With `TOASTTY_MOBILE_FIXTURE_COORDINATOR_REOPENS=1`, the fixture
/// coordinator chat loads for a moment each time it opens, as the live
/// app's new conversation controller does.
private struct FixtureCoordinatorReopenLoad: ViewModifier {
    let isEnabled: Bool
    let selectedConversationID: UUID?
    @Binding var isLoaded: Bool

    func body(content: Content) -> some View {
        content.task(id: selectedConversationID) {
            guard isEnabled else { return }
            isLoaded = false
            guard selectedConversationID == ToasttyMobileFixture.coordinatorConversationID else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard Task.isCancelled == false else { return }
            isLoaded = true
        }
    }
}
#endif
