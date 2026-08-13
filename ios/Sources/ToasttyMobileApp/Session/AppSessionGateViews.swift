import SwiftUI

struct AppSessionGateView: View {
    let state: AppSessionState
    let beginPairing: () -> Void
    let retryRestoration: () -> Void

    var body: some View {
        ZStack {
            ToasttyDesignTokens.background.ignoresSafeArea()
            switch state {
            case .restoring:
                sessionMessage(
                    icon: "lock.shield",
                    title: "Restoring this device…",
                    message: "Toastty is checking the credential stored securely on this iPhone.",
                    identifier: "toastty-mobile-session-restoring"
                ) {
                    ProgressView().tint(ToasttyDesignTokens.amber)
                }
            case .unpaired:
                sessionMessage(
                    icon: "iphone.and.arrow.forward",
                    title: "Pair with your Mac",
                    message: "Pair this iPhone directly with Toastty over your private Tailscale network.",
                    identifier: "toastty-mobile-session-unpaired"
                ) {
                    Button("Get started", action: beginPairing)
                        .buttonStyle(ToasttyPrimaryButtonStyle())
                        .controlSize(.large)
                        .accessibilityIdentifier("toastty-mobile-session-begin-pairing")
                }
            case .keychainLocked:
                sessionMessage(
                    icon: "lock.fill",
                    title: "Unlock this iPhone",
                    message: "Toastty cannot read this device credential while protected data is locked.",
                    identifier: "toastty-mobile-session-keychain-locked"
                ) {
                    Button("Try again", action: retryRestoration)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("toastty-mobile-session-retry-keychain")
                }
            case .repairNeeded(let reason):
                sessionMessage(
                    icon: "wrench.and.screwdriver",
                    title: reason == .corrupt ? "Credential needs repair" : "Secure storage unavailable",
                    message: reason == .corrupt
                        ? "Toastty could not read the saved device record. Your Mac has not been changed."
                        : "Toastty could not access the saved device record. Try again after unlocking this iPhone.",
                    identifier: "toastty-mobile-session-repair-needed"
                ) {
                    Button("Try again", action: retryRestoration)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("toastty-mobile-session-retry-repair")
                }
            case .incompatible(let incompatibility):
                sessionMessage(
                    icon: "arrow.down.app",
                    title: "Update Toastty",
                    message: incompatibleMessage(incompatibility),
                    identifier: "toastty-mobile-session-incompatible"
                ) {
                    Button("Check again", action: retryRestoration)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("toastty-mobile-session-retry-incompatible")
                }
            case .pairing, .paired:
                EmptyView()
            }
        }
    }

    private func incompatibleMessage(_ incompatibility: IncompatiblePresentation) -> String {
        switch incompatibility {
        case .credentialSchema:
            "This saved device record was created by a newer version of Toastty. Update the app to continue."
        case .gatewayProtocol(let version):
            "Your Mac uses remote protocol \(version). Update Toastty on this iPhone or your Mac to continue."
        }
    }

    private func sessionMessage<Action: View>(
        icon: String,
        title: String,
        message: String,
        identifier: String,
        @ViewBuilder action: () -> Action
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(ToasttyDesignTokens.amber)
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(ToasttyDesignTokens.primaryText)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier(identifier)
            Text(message)
                .font(.body)
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            action()
                .padding(.top, 4)
        }
        .frame(maxWidth: 430)
        .padding(28)
    }
}
