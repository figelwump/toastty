import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain

struct ToasttyMobileRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var sessionController: AppSessionController
    @State private var navigationPath: [ToasttyMobileRoute] = []
    @State private var pendingDeepLinkDestination: ToasttyMobileDeepLinkDestination?
    @State private var showsSettings = false
    @State private var fixtureHasLoadedOlderTranscript = false
    @State private var composerDraftState = ToasttyComposerDraftState()
    @State private var fixtureSendItems: [ToasttySendPresentationItem]
    @State private var fixtureComposerIsReserved = false
    @State private var diagnostics = ToasttyDiagnosticsState()
    @State private var diagnosedSessionState: AppSessionState?
    private let forcesPairingPrivacyShield: Bool
    private let fixtureScenario: ToasttyMobileFixtureScenario?
    private let deepLinkParser: DeepLinkParser?

    init(configuration: ToasttyMobileAppConfiguration) {
        _sessionController = State(initialValue: configuration.makeSessionController())
        _fixtureSendItems = State(initialValue: Self.initialFixtureSendItems(
            for: configuration.fixtureScenario
        ))
        forcesPairingPrivacyShield = configuration.fixtureScenario == .pairingPrivacy
        fixtureScenario = configuration.fixtureScenario
        deepLinkParser = configuration.urlScheme.flatMap(DeepLinkParser.init(scheme:))
    }

    var body: some View {
        Group {
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
        .task {
            sessionController.installDiagnosticEventHandler(recordDiagnostic)
            recordDiagnostic(.authStarted)
            observeSessionState(sessionController.state)
            await sessionController.restoreIfNeeded()
            observeSessionState(sessionController.state)
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
            }
        }
        .onChange(of: sessionController.homeController.snapshot) { _, newSnapshot in
            pruneComposerState(to: newSnapshot)
            routePendingDeepLinkIfAvailable()
        }
        .onChange(of: sessionController.homeController.freshness) {
            routePendingDeepLinkIfAvailable()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                sessionController.sceneBecameActive()
            case .inactive, .background:
                sessionController.sceneBecameInactive()
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
            }
        )
    }

    private func pairedApp(presentation: PairedConnectionPresentation) -> some View {
        NavigationStack(path: $navigationPath) {
            ToasttyHomeView(
                controller: sessionController.homeController,
                refresh: sessionController.refreshLiveSessions,
                onSettings: { showsSettings = true }
            )
                .navigationDestination(for: ToasttyMobileRoute.self) { route in
                    switch route {
                    case .workspace(let workspaceID):
                        ToasttyWorkspaceView(
                            workspaceID: workspaceID,
                            controller: sessionController.homeController
                        )
                    case .conversation(let conversationID):
                        conversationScreen(for: conversationID)
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
        }
        .onChange(of: sessionController.homeController.selectedConversationPresentation) { _, selection in
            syncNavigationPath(with: selection)
        }
        .onChange(of: navigationPath) { _, newPath in
            // A back swipe or back button pops the conversation route without
            // going through the controller; mirror the pop into selection so
            // the live conversation runtime closes.
            if newPath.containsConversation == false,
               sessionController.homeController.selectedConversationPresentation != nil {
                sessionController.homeController.dismissConversation()
            }
        }
        .sheet(isPresented: $showsSettings) {
            if let settingsPresentation {
                ToasttySettingsView(
                    presentation: settingsPresentation,
                    diagnostics: $diagnostics,
                    onUnpair: unpair
                )
            }
        }
        .onChange(of: showsSettings) { _, isPresented in
            guard isPresented else { return }
            Task {
                await sessionController.refreshCurrentDevice()
            }
        }
        .overlay(alignment: .top) {
            if let message = sessionController.homeController.removedSelectionMessage {
                RemovedConversationBanner(
                    message: message,
                    dismiss: sessionController.homeController.dismissRemovalMessage
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(
            .easeInOut(duration: 0.25),
            value: sessionController.homeController.removedSelectionMessage
        )
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
            showsSettings = false
        case .workspace(let workspaceID):
            guard sessionController.homeController.workspace(id: workspaceID) != nil else {
                discardPendingDeepLinkAfterLiveSnapshot()
                return
            }
            pendingDeepLinkDestination = nil
            sessionController.homeController.dismissConversation()
            navigationPath = [.workspace(workspaceID)]
            showsSettings = false
        }
    }

    private func discardPendingDeepLinkAfterLiveSnapshot() {
        if sessionController.homeController.freshness == .live {
            pendingDeepLinkDestination = nil
        }
    }

    private func syncNavigationPath(with selection: SelectedConversationPresentation?) {
        let updated = navigationPath.synchronized(with: selection)
        if updated != navigationPath {
            navigationPath = updated
        }
    }

    private func conversationScreen(for conversationID: UUID) -> some View {
        return ToasttyConversationScreen(
            conversationID: conversationID,
            controller: sessionController.homeController,
            presentation: conversationPresentation(for: conversationID),
            composer: conversationComposer(for: conversationID),
            draft: conversationDraft(for: conversationID),
            isSubmitting: composerDraftState.isSubmitting(conversationID),
            loadOlder: conversationLoadOlderAction(for: conversationID),
            submitDraft: conversationSubmitAction(for: conversationID),
            dismissSendReceipt: conversationReceiptDismissAction(for: conversationID),
            onVisibleLiveEdge: conversationVisibleLiveEdgeAction(for: conversationID)
        )
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
        case .toolActivity:
            return ToasttyConversationFixture.toolActivityPresentation(for: conversationID)
        case .gatedSend, .gatedSendReceipt:
            return ToasttyConversationFixture.gatedSendPresentation(
                for: conversationID,
                sendItems: conversationID == Self.fixtureOpenPromptConversationID
                    ? fixtureSendItems
                    : []
            )
        case .unpaired, .cameraDenied, .scannerUnsupported,
             .pairingFailure, .pairingPrivacy, nil:
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

    private func conversationDraft(for conversationID: UUID) -> Binding<String> {
        Binding(
            get: { composerDraftState.draft(for: conversationID) },
            set: {
                composerDraftState.updateDraft($0, for: conversationID)
                if let controller = sessionController.liveController?.activeConversationController,
                   controller.conversationID == conversationID {
                    controller.draftDidChange()
                }
            }
        )
    }

    private func conversationSubmitAction(for conversationID: UUID) -> () -> Void {
        {
            guard let submission = composerDraftState.beginSubmission(
                for: conversationID
            ) else {
                return
            }
            recordDiagnostic(.sendStarted)
            guard let controller = sessionController.liveController?.activeConversationController,
                  controller.conversationID == conversationID else {
                fixtureSubmit(submission)
                return
            }
            Task { @MainActor in
                let outcome = await controller.send(submission.text)
                finishSubmission(submission, outcome: outcome)
            }
        }
    }

    private func conversationReceiptDismissAction(
        for conversationID: UUID
    ) -> (String) -> Void {
        { clientRequestID in
            guard let controller = sessionController.liveController?.activeConversationController,
                  controller.conversationID == conversationID else {
                fixtureDismissReceipt(clientRequestID)
                return
            }
            Task { await controller.dismissSendReceipt(clientRequestID) }
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

    private func fixtureSubmit(_ submission: ToasttyComposerSubmission) {
#if DEBUG
        guard fixtureScenario == .gatedSend || fixtureScenario == .gatedSendReceipt,
              submission.conversationID == Self.fixtureOpenPromptConversationID else {
            finishSubmission(
                submission,
                outcome: .notEnqueued(.conversationNotOpen)
            )
            return
        }
        let clientRequestID = "fixture-enqueued-\(fixtureSendItems.count + 1)"
        fixtureSendItems.append(ToasttySendPresentationItem(
            clientRequestID: clientRequestID,
            text: submission.text,
            content: .optimistic(response: .accepted)
        ))
        fixtureComposerIsReserved = true
        finishSubmission(
            submission,
            outcome: .enqueued(clientRequestID: clientRequestID)
        )
#else
        finishSubmission(
            submission,
            outcome: .notEnqueued(.conversationNotOpen)
        )
#endif
    }

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
        recordDiagnostic(ToasttyAppDiagnosticProjection.event(for: outcome))
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
        }
    }

    @MainActor
    private func unpair() async {
        await sessionController.unpairCurrentDevice()
        showsSettings = false
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
            RoundedRectangle(cornerRadius: 12)
                .stroke(ToasttyDesignTokens.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
        case .live, .reconnecting, .unreachable:
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
