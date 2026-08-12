import SwiftUI
import ToasttyMobileDomain

struct ToasttyMobileRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var sessionController: AppSessionController
    @State private var showsSettings = false
    private let forcesPairingPrivacyShield: Bool

    init(configuration: ToasttyMobileAppConfiguration) {
        _sessionController = State(initialValue: configuration.makeSessionController())
        forcesPairingPrivacyShield = configuration.fixtureScenario == .pairingPrivacy
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
