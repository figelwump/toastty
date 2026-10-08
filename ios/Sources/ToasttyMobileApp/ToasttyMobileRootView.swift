import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain

struct ToasttyMobileRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sessionController: AppSessionController
    @State private var appIconBadgeController: AppIconBadgeController?
    @State private var navigationPath: [ToasttyMobileRoute] = []
    @State private var pendingDeepLinkDestination: ToasttyMobileDeepLinkDestination?
    @State private var presentedSheet: ToasttyMobileSheet?
    @State private var fixtureHasLoadedOlderTranscript = false
    @State private var composerDraftState = ToasttyComposerDraftState()
    @State private var fixtureSendItems: [ToasttySendPresentationItem]
    @State private var fixtureComposerIsReserved = false
#if DEBUG
    @State private var controlledFixtureSubmission: ControlledFixtureSubmission?
    @State private var fixtureSentText: String?
    @State private var fixtureSendUpdateCount = 0
#endif
    @State private var fixtureInteractionAnswerState: ToasttyInteractionAnswerState?
    @State private var fixtureInteractionAcceptedAnswers: [RemoteInteractionAnswer]?
    @State private var diagnostics = ToasttyDiagnosticsState()
    @State private var diagnosedSessionState: AppSessionState?
    private let forcesPairingPrivacyShield: Bool
    private let fixtureScenario: ToasttyMobileFixtureScenario?
#if DEBUG
    private let controlsFixtureSubmission: Bool
    private let fixtureSendEventOrder: ToasttyConversationFixture.SendEventOrder?
#endif
    private let deepLinkParser: DeepLinkParser?
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
            _composerDraftState = State(initialValue: draft)
        }
        if configuration.fixtureScenario == .interactionAnswer {
            let key = ToasttyInteractionAnswerKey(
                interactionID: ToasttyConversationFixture.questionInteractionID,
                responseID: ToasttyConversationFixture.questionResponseID,
                inputEpoch: ToasttyConversationFixture.questionEpoch
            )
            _fixtureInteractionAnswerState = State(initialValue: ToasttyInteractionAnswerState(
                key: key,
                questions: ToasttyConversationFixture.questions
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
        controlsFixtureSubmission = configuration.fixtureScenario == .gatedSend
            && ProcessInfo.processInfo.environment["TOASTTY_MOBILE_FIXTURE_CONTROLLED_SUBMIT"] == "1"
        fixtureSendEventOrder = configuration.fixtureScenario == .gatedSend
            ? ProcessInfo.processInfo.environment["TOASTTY_MOBILE_FIXTURE_SEND_EVENT_ORDER"]
                .flatMap(ToasttyConversationFixture.SendEventOrder.init(rawValue:))
            : nil
#endif
        deepLinkParser = configuration.urlScheme.flatMap(DeepLinkParser.init(scheme:))
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
        .task {
            if let pushBridge { sessionController.pushController?.attachBridge(pushBridge) }
            sessionController.installDiagnosticEventHandler(recordDiagnostic)
            recordDiagnostic(.authStarted)
            observeSessionState(sessionController.state)
            await sessionController.restoreIfNeeded()
            observeSessionState(sessionController.state)
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
                    navigationPath.removeAll(keepingCapacity: false)
                }
            } else {
                routePendingDeepLinkIfAvailable()
                presentNotificationIntroIfNeeded()
            }
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
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                sessionController.sceneBecameActive()
            case .inactive:
                sessionController.sceneBecameInactive()
            case .background:
                sessionController.sceneEnteredBackground()
            @unknown default:
                sessionController.sceneBecameInactive()
            }
        }
        .onOpenURL(perform: handleDeepLink)
        .preferredColorScheme(.dark)
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
        NavigationStack(path: $navigationPath) {
            ToasttyHomeView(
                controller: sessionController.homeController,
                refresh: sessionController.refreshLiveSessions,
                onSettings: { presentedSheet = .settings },
                openWorkspace: openWorkspace,
                notificationError: sessionController.pushController?.configuration == nil
                    ? nil : sessionController.pushController?.errorMessage,
                retryNotifications: { sessionController.pushController?.retry() }
            )
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
        .tint(ToasttyDesignTokens.amber)
        .background(ToasttyDesignTokens.background.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            PairedConnectionBanner(presentation: presentation)
        }
        .onAppear {
            // The stack can be (re)inserted while a selection already exists,
            // e.g. after a keychain-lock cycle; onChange alone would miss it.
            syncNavigationPath(with: sessionController.homeController.selectedConversationPresentation)
            handleNotificationTap()
            presentNotificationIntroIfNeeded()
        }
        .onChange(of: sessionController.homeController.selectedConversationPresentation) { _, selection in
            syncNavigationPath(with: selection)
        }
        .onChange(of: navigationPath) { _, newPath in
            sessionController.pushController?.setOpenConversation(newPath.last?.conversationID)
            presentNotificationIntroIfNeeded()
            // A back swipe or back button pops the conversation route without
            // going through the controller; mirror the pop into selection so
            // the live conversation runtime closes.
            if newPath.containsConversation == false,
               sessionController.homeController.selectedConversationPresentation != nil {
                sessionController.homeController.dismissConversation()
            }
        }
        .sheet(item: $presentedSheet) { sheet in
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
    }

    /// Pushes a workspace from a row or menu, which cannot use a
    /// navigation link. Subspaces open from their parent this way.
    private func openWorkspace(_ workspaceID: UUID) {
        guard navigationPath.last != .workspace(workspaceID) else { return }
        navigationPath.append(.workspace(workspaceID))
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
            guard sessionController.homeController.openConversation(id: conversationID) else {
                discardPendingDeepLinkAfterLiveSnapshot()
                return
            }
            pendingDeepLinkDestination = nil
            presentedSheet = nil
        case .workspace(let workspaceID):
            guard sessionController.homeController.workspace(id: workspaceID) != nil else {
                discardPendingDeepLinkAfterLiveSnapshot()
                return
            }
            pendingDeepLinkDestination = nil
            sessionController.homeController.dismissConversation()
            navigationPath = [.workspace(workspaceID)]
            presentedSheet = nil
        }
    }

    private func discardPendingDeepLinkAfterLiveSnapshot() {
        if sessionController.homeController.freshness == .live {
            pendingDeepLinkDestination = nil
        }
    }

    private func handleNotificationTap() {
        guard let push = sessionController.pushController, let id = push.pendingConversationID else { return }
        pendingDeepLinkDestination = .conversation(id)
        push.consumedConversationTap()
        routePendingDeepLinkIfAvailable()
    }

    private func presentNotificationIntroIfNeeded() {
        guard presentedSheet == nil, navigationPath.isEmpty,
              pendingDeepLinkDestination == nil,
              sessionController.state == .paired(.live),
              sessionController.pushController?.canIntroduce == true else { return }
        presentedSheet = .notifications
    }

    private func syncNavigationPath(with selection: SelectedConversationPresentation?) {
        let updated = navigationPath.synchronized(with: selection)
        if updated != navigationPath {
            navigationPath = updated
        }
    }

    private func conversationScreen(for conversationID: UUID) -> some View {
        let generation = composerDraftState.generation
        let liveConversation = sessionController.liveController?.activeConversationController
        let supportsAttachments = liveConversation?.conversationID == conversationID
            ? liveConversation?.supportsAttachments == true
            : fixtureScenario == .gatedSend || fixtureScenario == .gatedSendReceipt
        return ToasttyConversationScreen(
            conversationID: conversationID,
            controller: sessionController.homeController,
            presentation: conversationPresentation(for: conversationID),
            composer: conversationComposer(for: conversationID),
            draft: composerDraftState.draft(for: conversationID),
            draftGeneration: generation,
            draftEditRevision: composerDraftState.editRevisions[conversationID, default: 0],
            draftReplacement: composerDraftState.replacements[conversationID],
            draftDidChange: conversationDraftChange(for: conversationID, generation: generation),
            draftReplacementCompleted: { result in
                guard composerDraftState.generation == generation,
                      sessionController.homeController.conversation(id: conversationID) != nil else { return }
                composerDraftState.completeReplacement(result, for: conversationID)
                reconcileAttachmentDrafts()
            },
            isSubmitting: composerDraftState.isSubmitting(conversationID),
            attachments: composerDraftState.attachments(for: conversationID),
            supportsAttachments: supportsAttachments,
            addAttachments: { additions in
                guard composerDraftState.generation == generation,
                      sessionController.homeController.conversation(id: conversationID) != nil else {
                    return "This conversation is no longer available."
                }
                return composerDraftState.addAttachments(additions, for: conversationID)
            },
            removeAttachment: {
                composerDraftState.removeAttachment($0, for: conversationID)
                reconcileAttachmentDrafts()
            },
            attachmentRecoveryMessage: composerDraftState.attachmentRecoveryMessages[conversationID],
            loadOlder: conversationLoadOlderAction(for: conversationID),
            submitDraft: conversationSubmitAction(for: conversationID),
            dismissSendReceipt: conversationReceiptDismissAction(for: conversationID),
            interactionAnswerStates: conversationInteractionAnswerStates(for: conversationID),
            editInteractionAnswer: conversationInteractionEditAction(for: conversationID),
            submitInteractionAnswer: conversationInteractionSubmitAction(for: conversationID),
            onVisibleLiveEdge: conversationVisibleLiveEdgeAction(for: conversationID)
        )
        .id(conversationID)
#if DEBUG
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
        switch fixtureScenario {
        case .home, .reconnecting:
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
              let controller = sessionController.liveController?.activeConversationController,
              controller.conversationID == conversationID else {
            return fixtureComposer(for: conversationID)
        }
        return ToasttyComposerPresentation.make(
            agentDisplayName: conversation.agent.displayName.capitalized,
            authority: controller.presentedComposerAuthority
        )
    }

    private func conversationDraftChange(for conversationID: UUID, generation: UUID) -> (String, UInt64) -> Void {
        { text, editRevision in
            guard composerDraftState.generation == generation,
                  sessionController.homeController.conversation(id: conversationID) != nil else { return }
            composerDraftState.updateDraft(text, for: conversationID, editRevision: editRevision)
            reconcileAttachmentDrafts()
            if let controller = sessionController.liveController?.activeConversationController,
               controller.conversationID == conversationID {
                controller.draftDidChange()
            }
        }
    }

    private func conversationSubmitAction(for conversationID: UUID) -> () -> Bool {
        {
            guard let submission = composerDraftState.beginSubmission(
                for: conversationID
            ) else {
                return false
            }
            recordDiagnostic(.sendStarted)
            guard let controller = sessionController.liveController?.activeConversationController,
                  controller.conversationID == conversationID else {
                return fixtureSubmit(submission)
            }
            Task { @MainActor in
                let outcome = await controller.send(submission.text, attachments: submission.attachments)
                finishSubmission(submission, outcome: outcome)
            }
            return true
        }
    }

    private func conversationReceiptDismissAction(
        for conversationID: UUID
    ) -> (String) -> Void {
        { clientRequestID in
            composerDraftState.discardAttachmentRecovery(clientRequestID: clientRequestID, for: conversationID)
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

    private func fixtureComposer(for conversationID: UUID) -> ToasttyComposerPresentation? {
#if DEBUG
        guard fixtureScenario == .gatedSend || fixtureScenario == .gatedSendReceipt,
              conversationID == Self.fixtureOpenPromptConversationID else { return nil }
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
            agentDisplayName: "Codex",
            authority: authority
        )
#else
        nil
#endif
    }

    private func fixtureSubmit(_ submission: ToasttyComposerSubmission) -> Bool {
#if DEBUG
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
            text: submission.text,
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
            snapshot: MobileHomeSnapshot(hostName: home.snapshot.hostName, workspaces: workspaces),
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

    private func resetComposerPresentation() {
        composerDraftState.reset()
#if DEBUG
        controlledFixtureSubmission = nil
#endif
        fixtureSendItems.removeAll(keepingCapacity: false)
        fixtureComposerIsReserved = false
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
        composerDraftState.finishSubmission(submission, outcome: outcome)
        reconcileAttachmentDrafts()
        recordDiagnostic(ToasttyAppDiagnosticProjection.event(for: outcome))
    }

    private func reconcileAttachmentDrafts() {
        guard let controller = sessionController.liveController?.activeConversationController else { return }
        composerDraftState.reconcileAttachments(controller.sendReconciliation, for: controller.conversationID)
    }

    private func recordDiagnostic(_ event: ToasttyConnectionDiagnosticEvent) {
        ToasttyDiagnosticLogger.record(event, in: &diagnostics)
    }

    private func pruneComposerState(to snapshot: MobileHomeSnapshot) {
        let conversationIDs = Set(
            snapshot.workspaces.flatMap(\.conversations).map(\.id)
        )
        composerDraftState.retainConversations(conversationIDs)
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
