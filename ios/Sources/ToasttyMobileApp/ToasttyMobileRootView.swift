import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain

struct ToasttyMobileRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var sessionController: AppSessionController
    @State private var showsSettings = false
    @State private var fixtureHasLoadedOlderTranscript = false
    @State private var composerDraftState = ToasttyComposerDraftState()
    @State private var fixtureSendItems: [ToasttySendPresentationItem]
    @State private var fixtureComposerIsReserved = false
    private let forcesPairingPrivacyShield: Bool
    private let fixtureScenario: ToasttyMobileFixtureScenario?

    init(configuration: ToasttyMobileAppConfiguration) {
        _sessionController = State(initialValue: configuration.makeSessionController())
        _fixtureSendItems = State(initialValue: Self.initialFixtureSendItems(
            for: configuration.fixtureScenario
        ))
        forcesPairingPrivacyShield = configuration.fixtureScenario == .pairingPrivacy
        fixtureScenario = configuration.fixtureScenario
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
            await sessionController.restoreIfNeeded()
        }
        .onChange(of: sessionController.state) { _, newState in
            if newState.isPaired == false {
                resetComposerPresentation()
            }
        }
        .onChange(of: sessionController.homeController.snapshot) { _, newSnapshot in
            pruneComposerState(to: newSnapshot)
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
        NavigationStack {
            ToasttyHomeView(controller: sessionController.homeController)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") {
                            showsSettings = true
                        }
                        .accessibilityIdentifier("toastty-mobile-settings-button")
                    }
                }
                .toolbar(.visible, for: .navigationBar)
                .navigationDestination(for: UUID.self) { workspaceID in
                    ToasttyWorkspaceView(
                        workspaceID: workspaceID,
                        controller: sessionController.homeController
                    )
                }
        }
        .tint(ToasttyDesignTokens.amber)
        .background(ToasttyDesignTokens.background.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            PairedConnectionBanner(presentation: presentation)
        }
        .sheet(item: selectedConversationPresentation) { selection in
            ToasttyConversationSheet(
                conversationID: selection.id,
                controller: sessionController.homeController,
                presentation: conversationPresentation(for: selection.id),
                composer: conversationComposer(for: selection.id),
                draft: conversationDraft(for: selection.id),
                isSubmitting: composerDraftState.isSubmitting(selection.id),
                loadOlder: conversationLoadOlderAction(for: selection.id),
                submitDraft: conversationSubmitAction(for: selection.id),
                dismissSendReceipt: conversationReceiptDismissAction(for: selection.id),
                onDismiss: sessionController.homeController.dismissConversation
            )
            .presentationDetents([.fraction(0.92)])
            .presentationDragIndicator(.visible)
            .presentationBackground(ToasttyDesignTokens.elevatedSurface)
        }
        .sheet(isPresented: $showsSettings) {
            if let settingsPresentation {
                ToasttySettingsView(
                    presentation: settingsPresentation,
                    onUnpair: unpair
                )
            }
        }
        .onChange(of: showsSettings) { _, isPresented in
            guard isPresented else { return }
            Task { await sessionController.refreshCurrentDevice() }
        }
        .alert("Conversation unavailable", isPresented: removedSelectionIsPresented) {
            Button("OK", action: sessionController.homeController.dismissRemovalMessage)
        } message: {
            Text(sessionController.homeController.removedSelectionMessage ?? "This conversation is no longer available on your Mac.")
        }
    }

    private var selectedConversationPresentation: Binding<SelectedConversationPresentation?> {
        Binding(
            get: { sessionController.homeController.selectedConversationPresentation },
            set: { sessionController.homeController.selectedConversationPresentation = $0 }
        )
    }

    private var removedSelectionIsPresented: Binding<Bool> {
        Binding(
            get: { sessionController.homeController.removedSelectionMessage != nil },
            set: { isPresented in
                if !isPresented {
                    sessionController.homeController.dismissRemovalMessage()
                }
            }
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
        case .gatedSend, .gatedSendReceipt:
            return ToasttyConversationFixture.gatedSendPresentation(
                for: conversationID,
                sendItems: conversationID == Self.fixtureOpenPromptConversationID
                    ? fixtureSendItems
                    : []
            )
        case .home, .unpaired, .cameraDenied, .scannerUnsupported,
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
            guard let controller = sessionController.liveController?.activeConversationController,
                  controller.conversationID == conversationID else {
                fixtureSubmit(submission)
                return
            }
            Task { @MainActor in
                let outcome = await controller.send(submission.text)
                composerDraftState.finishSubmission(submission, outcome: outcome)
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
            composerDraftState.finishSubmission(
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
        composerDraftState.finishSubmission(
            submission,
            outcome: .enqueued(clientRequestID: clientRequestID)
        )
#else
        composerDraftState.finishSubmission(
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
