import SwiftUI

struct ToasttyNotificationIntroduction: View {
    let controller: ToasttyPushController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var headlineSize: CGFloat = 25
    @ScaledMetric(relativeTo: .subheadline) private var explanationSize: CGFloat = 13
    @ScaledMetric(relativeTo: .footnote) private var disclosureSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption) private var footerSize: CGFloat = 11
    @State private var requestingPermission = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                introduction
                ToasttyNotificationPreview()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Alerts include the session title. Titles pass through Toastty’s notification service and Apple.")
                    Text("Toastty checks delivery while the app is open. A test alert may appear if you leave during setup.")
                }
                .font(.system(size: disclosureSize))
                .foregroundStyle(ToasttyDesignTokens.mutedText)
                .fixedSize(horizontal: false, vertical: true)
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .foregroundStyle(ToasttyDesignTokens.primaryText)
        .presentationBackground(ToasttyDesignTokens.raisedSurface)
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(540), .large])
        .presentationDragIndicator(dynamicTypeSize.isAccessibilitySize ? .hidden : .visible)
        .interactiveDismissDisabled()
        .accessibilityIdentifier("toastty-mobile-notifications-introduction")
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "bell")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(ToasttyDesignTokens.amberText)
                .accessibilityHidden(true)
                .padding(.bottom, 4)
            Text("Know when your\nagent needs you.")
                .font(.system(size: headlineSize, weight: .semibold))
                .tracking(-0.5)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Get a notification when an agent finishes working or needs approval.")
                .font(.system(size: explanationSize))
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        VStack(spacing: 4) {
            Button {
                requestingPermission = true
                Task {
                    await controller.continueIntroduction()
                    dismiss()
                }
            } label: {
                HStack {
                    if requestingPermission { ProgressView() }
                    Text("Continue")
                }
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(ToasttyPrimaryButtonStyle())
            .tint(ToasttyDesignTokens.inkOnAmber)
            .disabled(requestingPermission)
            .accessibilityIdentifier("toastty-mobile-notifications-continue")
            Button { controller.deferIntroduction(); dismiss() } label: {
                Text("Not now")
                    .font(.subheadline)
                    .foregroundStyle(ToasttyDesignTokens.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(requestingPermission)
            .accessibilityIdentifier("toastty-mobile-notifications-not-now")
            Text("You can change this later in Settings.")
                .font(.system(size: footerSize))
                .foregroundStyle(ToasttyDesignTokens.mutedText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
    }
}

private struct ToasttyNotificationPreview: View {
    @ScaledMetric(relativeTo: .caption2) private var metadataSize: CGFloat = 10
    @ScaledMetric(relativeTo: .subheadline) private var titleSize: CGFloat = 13
    @ScaledMetric(relativeTo: .footnote) private var statusSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var iconSize: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                // Copied from AppIcon.appiconset/App-Icon-60x60@3x.png; keep
                // the preview image in sync when the app icon changes.
                Image("NotificationToastIcon")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .accessibilityHidden(true)
                Text("Toastty").textCase(.uppercase)
                Spacer(minLength: 8)
                Text("now")
            }
            .font(.system(size: metadataSize))
            .foregroundStyle(ToasttyDesignTokens.secondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text("Fix checkout bug")
                    .font(.system(size: titleSize, weight: .semibold))
                Text("Ready")
                    .font(.system(size: statusSize))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        // The approved notification preview uses this warmer surface.
        .background(
            Color(red: 48 / 255, green: 42 / 255, blue: 36 / 255),
            in: RoundedRectangle(cornerRadius: ToasttyDesignTokens.cardCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ToasttyDesignTokens.cardCornerRadius, style: .continuous)
                .stroke(ToasttyDesignTokens.chipBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Example notification: Fix checkout bug, Ready")
        .accessibilityIdentifier("toastty-mobile-notifications-preview")
    }
}

struct ToasttyNotificationSettingsSection: View {
    let controller: ToasttyPushController
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section("Notifications") {
            Toggle("Session alerts", isOn: Binding(get: {
                controller.desired && controller.permission != .denied
            }, set: { value in
                Task { await controller.setDesired(value) }
            }))
            .disabled(!controller.stateIsLoaded || controller.permission == .denied)
            .accessibilityIdentifier("toastty-mobile-notifications-toggle")
            Text(status)
                .font(.footnote)
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .accessibilityIdentifier("toastty-mobile-notifications-status")
            if controller.permission == .denied {
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                .accessibilityIdentifier("toastty-mobile-notifications-open-settings")
            }
            if let error = controller.errorMessage {
                Text(error).font(.footnote).foregroundStyle(ToasttyDesignTokens.red)
                Button("Retry", action: controller.retry)
                    .accessibilityIdentifier("toastty-mobile-notifications-retry")
            }
            Text("Alerts include session titles, sent through Toastty’s notification service and Apple.")
                .font(.footnote)
                .foregroundStyle(ToasttyDesignTokens.mutedText)
        }
    }

    private var status: String {
        if controller.permission == .denied { return "Alerts are off in iOS Settings." }
        return switch controller.presentation {
        case .unavailable: "Notifications are unavailable in this app build."
        case .off: "Off"
        case .turningOff: "Off on this iPhone. Waiting to stop alerts at the notification service."
        case .permissionDenied: "Alerts are off in iOS Settings."
        case .pending: "Enabling alerts. Keep Toastty open and connected to your Mac."
        case .enabled: "On"
        }
    }
}

struct ToasttyNotificationErrorBanner: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: retry).font(.caption.weight(.semibold))
                .accessibilityIdentifier("toastty-mobile-notifications-banner-retry")
        }
        .padding(12)
        .background(ToasttyDesignTokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(ToasttyDesignTokens.primaryText)
        .tint(ToasttyDesignTokens.amber)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toastty-mobile-notifications-error")
    }
}

enum ToasttyMobileSheet: String, Identifiable { case settings, notifications; var id: String { rawValue } }
