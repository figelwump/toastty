import SwiftUI

struct PairingFlowView: View {
    let controller: PairingController
    let onCancel: () -> Void
    var forcesPrivacyShield = false

    var body: some View {
        ZStack {
            ToasttyDesignTokens.background.ignoresSafeArea()
            if forcesPrivacyShield || controller.isPrivacyShielded {
                PairingPrivacyShield()
            } else {
                content
            }
        }
        .tint(ToasttyDesignTokens.amber)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .intro:
            PairingIntroView(
                onScan: { Task { await controller.startScanning() } },
                onManual: controller.showManualEntry
            )
        case .scanning:
            PairingScanView(controller: controller)
        case .manual:
            PairingManualEntryView(controller: controller)
        case .confirming(let confirmation):
            PairingConfirmationView(
                confirmation: confirmation,
                onConfirm: controller.confirmAndExchange,
                onBack: controller.showIntro
            )
        case .exchanging(let hostname):
            PairingExchangeView(hostname: hostname)
        case .failure(let failure):
            PairingFailureView(
                failure: failure,
                onRetry: controller.showIntro,
                onManual: controller.showManualEntry
            )
        }
    }
}

private struct PairingIntroView: View {
    let onScan: () -> Void
    let onManual: () -> Void

    var body: some View {
        PairingScrollContainer {
            PairingBrandHeader(
                title: "Pair this iPhone",
                subtitle: "Connect directly to Toastty on your Mac through your private Tailscale network."
            )

            VStack(alignment: .leading, spacing: 14) {
                Label("On your Mac, open Toastty → Settings → Remote Access and create a native pairing offer.", systemImage: "macbook")
                Label("The offer expires after two minutes and can be used only once.", systemImage: "timer")
            }
            .font(.subheadline)
            .foregroundStyle(ToasttyDesignTokens.secondaryText)
            .toasttyCard()

            Button(action: onScan) {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ToasttyPrimaryButtonStyle())
            .controlSize(.large)
            .accessibilityIdentifier("toastty-mobile-pairing-scan")

            Button("Enter code manually", action: onManual)
                .buttonStyle(.plain)
                .font(.body.weight(.semibold))
                .foregroundStyle(ToasttyDesignTokens.amberText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .accessibilityIdentifier("toastty-mobile-pairing-manual")
        }
        .accessibilityIdentifier("toastty-mobile-pairing-intro")
    }
}

private struct PairingScanView: View {
    let controller: PairingController

    var body: some View {
        PairingScrollContainer {
            PairingBrandHeader(
                title: "Scan the pairing code",
                subtitle: "Point this iPhone at the native pairing QR code shown by Toastty on your Mac."
            )

            scannerContent

            Button("Enter code manually", action: controller.showManualEntry)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("toastty-mobile-pairing-scan-manual")

            Button("Back", action: controller.showIntro)
                .buttonStyle(.plain)
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("toastty-mobile-pairing-scanner")
    }

    @ViewBuilder
    private var scannerContent: some View {
        if controller.scannerAvailability == .unsupported {
            PairingScannerUnavailableView(
                title: "QR scanning is unavailable",
                message: "This device cannot use the camera scanner. Enter the hostname and code shown on your Mac instead."
            )
            .accessibilityIdentifier("toastty-mobile-pairing-scanner-unsupported")
        } else if controller.scannerAuthorization == .denied {
            PairingScannerUnavailableView(
                title: "Camera access is off",
                message: "You can allow camera access in Settings, or pair without the camera by entering the code manually."
            )
            .accessibilityIdentifier("toastty-mobile-pairing-camera-denied")
        } else if controller.scannerAuthorization == .authorized {
            controller.scannerView()
                .frame(minHeight: 340)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(ToasttyDesignTokens.border, lineWidth: 1)
                }
        } else {
            ProgressView("Requesting camera access…")
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 180)
        }
    }
}

private struct PairingScannerUnavailableView: View {
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: "camera.fill",
            description: Text(message)
        )
        .foregroundStyle(ToasttyDesignTokens.secondaryText)
        .toasttyCard()
    }
}

private struct PairingManualEntryView: View {
    @Bindable var controller: PairingController

    var body: some View {
        PairingScrollContainer {
            PairingBrandHeader(
                title: "Enter pairing details",
                subtitle: "Use the complete Tailscale Serve hostname and fallback code shown by Toastty on your Mac."
            )

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("TAILSCALE HOSTNAME")
                        .font(.caption2.monospaced())
                        .tracking(1.4)
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                    TextField("mac-name.tailnet.ts.net", text: $controller.manualGateway)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .toasttyPairingField()
                        .accessibilityIdentifier("toastty-mobile-pairing-hostname")
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("PAIRING CODE")
                        .font(.caption2.monospaced())
                        .tracking(1.4)
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                    SecureField("Code from your Mac", text: $controller.manualCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .textContentType(.oneTimeCode)
                        .toasttyPairingField()
                        .accessibilityIdentifier("toastty-mobile-pairing-code")
                }
            }
            .toasttyCard()

            Button(action: controller.submitManualEntry) {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ToasttyPrimaryButtonStyle())
            .controlSize(.large)
            .disabled(
                controller.manualGateway.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || controller.manualCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .accessibilityIdentifier("toastty-mobile-pairing-manual-continue")

            Button("Back", action: controller.showIntro)
                .buttonStyle(.plain)
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("toastty-mobile-pairing-manual-entry")
    }
}

private struct PairingConfirmationView: View {
    let confirmation: PairingConfirmation
    let onConfirm: () -> Void
    let onBack: () -> Void

    var body: some View {
        PairingScrollContainer {
            PairingBrandHeader(
                title: "Confirm your Mac",
                subtitle: "Compare this complete hostname with the one shown in Toastty before connecting."
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("AUTHORITATIVE HOSTNAME")
                    .font(.caption2.monospaced())
                    .tracking(1.4)
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                Text(confirmation.hostname)
                    .font(.body.monospaced().weight(.semibold))
                    .foregroundStyle(ToasttyDesignTokens.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("toastty-mobile-pairing-confirm-hostname")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .toasttyCard()

            Button(action: onConfirm) {
                Text("Pair with this Mac")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ToasttyPrimaryButtonStyle())
            .controlSize(.large)
            .accessibilityIdentifier("toastty-mobile-pairing-confirm")

            Button("This is not my Mac", action: onBack)
                .buttonStyle(.plain)
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("toastty-mobile-pairing-confirmation")
    }
}

private struct PairingExchangeView: View {
    let hostname: String

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
                .tint(ToasttyDesignTokens.amber)
            Text("Pairing securely…")
                .font(.title3.weight(.semibold))
                .foregroundStyle(ToasttyDesignTokens.primaryText)
            Text(hostname)
                .font(.caption.monospaced())
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("toastty-mobile-pairing-exchanging")
    }
}

private struct PairingFailureView: View {
    let failure: PairingFailurePresentation
    let onRetry: () -> Void
    let onManual: () -> Void

    var body: some View {
        PairingScrollContainer {
            PairingBrandHeader(title: failure.title, subtitle: failure.message)

            Button(action: onRetry) {
                Text("Try a new offer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ToasttyPrimaryButtonStyle())
            .controlSize(.large)
            .accessibilityIdentifier("toastty-mobile-pairing-retry")

            Button("Enter code manually", action: onManual)
                .buttonStyle(.plain)
                .foregroundStyle(ToasttyDesignTokens.amberText)
                .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("toastty-mobile-pairing-failure")
    }
}

private struct PairingPrivacyShield: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 38))
                .foregroundStyle(ToasttyDesignTokens.amber)
            Text("Pairing details hidden")
                .font(.headline)
                .foregroundStyle(ToasttyDesignTokens.primaryText)
            Text("Return to Toastty to continue securely.")
                .font(.subheadline)
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
        }
        .padding(28)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("toastty-mobile-pairing-privacy-shield")
    }
}

private struct PairingBrandHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TOASTTY")
                .font(.headline.monospaced().weight(.bold))
                .tracking(3.2)
                .foregroundStyle(ToasttyDesignTokens.amberText)
            Text(title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(ToasttyDesignTokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PairingScrollContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                content
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

private extension View {
    func toasttyPairingField() -> some View {
        padding(.horizontal, 13)
            .padding(.vertical, 12)
            .foregroundStyle(ToasttyDesignTokens.primaryText)
            .background(ToasttyDesignTokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(ToasttyDesignTokens.border, lineWidth: 1)
            }
    }
}
