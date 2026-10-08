import SwiftUI

struct ToasttyNotificationIntroduction: View {
    let controller: ToasttyPushController
    @Environment(\.dismiss) private var dismiss
    @State private var requestingPermission = false

    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "bell.badge.fill")
                .font(.largeTitle)
                .foregroundStyle(ToasttyDesignTokens.amber)
                .accessibilityHidden(true)
            Text("Know when a session needs you")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Get an alert when a session is ready or needs approval. Tap it to open the conversation.")
            Text("Alerts include the session title. Titles pass through Toastty’s notification service and Apple.")
                .font(.footnote)
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
            Text("Toastty checks delivery while the app is open. A test alert may appear if you leave during setup.")
                .font(.footnote)
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
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
                }.frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(requestingPermission)
            .accessibilityIdentifier("toastty-mobile-notifications-continue")
            Button { controller.deferIntroduction(); dismiss() } label: {
                Text("Not now").frame(maxWidth: .infinity).padding(.vertical, 8)
            }
                .disabled(requestingPermission)
                .accessibilityIdentifier("toastty-mobile-notifications-not-now")
        }
        .padding(24)
      }
        .foregroundStyle(ToasttyDesignTokens.primaryText)
        .tint(ToasttyDesignTokens.amber)
        .presentationBackground(ToasttyDesignTokens.background)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
        .accessibilityIdentifier("toastty-mobile-notifications-introduction")
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
            if controller.presentation == .permissionDenied {
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
        switch controller.presentation {
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
