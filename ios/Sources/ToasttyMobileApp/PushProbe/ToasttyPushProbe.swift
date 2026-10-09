#if TOASTTY_MOBILE_PUSH_PROBE
import Observation
import SwiftUI
import UIKit
import UserNotifications

@MainActor
@Observable
final class ToasttyPushProbeState {
    private(set) var status = "Request notification permission to register this iPhone with APNs sandbox."
    private(set) var deviceToken: String?
    private(set) var isRegistering = false
    private(set) var receivedNotificationCount = 0
    private(set) var lastNotificationTitle: String?

    func register() async {
        guard !isRegistering else { return }
        isRegistering = true
        deviceToken = nil
        status = "Requesting notification permission…"
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            guard granted else {
                status = "Notification permission is off. Enable it in Settings, then register again."
                isRegistering = false
                return
            }
            status = "Registering with APNs sandbox…"
            UIApplication.shared.registerForRemoteNotifications()
            // APNs can leave registration pending while unreachable. Allow a
            // retry without waiting for a callback that might never arrive.
            isRegistering = false
        } catch {
            status = "Notification permission failed: \(error.localizedDescription)"
            isRegistering = false
        }
    }

    func registrationSucceeded(token: Data) {
        // Keep the APNs token in memory. Copy it only at the user's request.
        deviceToken = token.map { String(format: "%02x", $0) }.joined()
        status = "Registered with APNs sandbox."
        isRegistering = false
    }

    func registrationFailed(error: Error) {
        deviceToken = nil
        status = "APNs registration failed: \(error.localizedDescription)"
        isRegistering = false
    }

    func recordNotification(title: String) {
        receivedNotificationCount += 1
        lastNotificationTitle = title.isEmpty ? "Untitled notification" : title
    }

    func copyToken() {
        guard let deviceToken else { return }
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: deviceToken]],
            options: [.expirationDate: Date().addingTimeInterval(120)]
        )
        status = "Token copied for two minutes. Paste it into the secure vault on your Mac."
    }
}

@MainActor
final class ToasttyPushProbeDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let state = ToasttyPushProbeState()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        state.registrationSucceeded(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        state.registrationFailed(error: error)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let title = notification.request.content.title
        await state.recordNotification(title: title)
        return [.banner, .list, .sound]
    }
}

struct ToasttyPushProbeView: View {
    let state: ToasttyPushProbeState

    var body: some View {
        NavigationStack {
            Form {
                Section("Development receiver") {
                    Text("APNs sandbox · com.giantthings.toastty.mobile.dev")
                        .font(.footnote)
                    Text(state.status)
                    Button("Request permission and register") {
                        Task { await state.register() }
                    }
                    .disabled(state.isRegistering)
                }
                if state.deviceToken != nil {
                    Section("Device token") {
                        Text("The token is kept in memory. Copy it to the secure vault for the sandbox sender.")
                        Button("Copy APNs token") { state.copyToken() }
                    }
                }
                Section("Foreground delivery") {
                    Text("Received: \(state.receivedNotificationCount)")
                    if let title = state.lastNotificationTitle {
                        Text(title)
                    }
                    Text("Keep this screen open to see a banner and record a sandbox delivery.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Push Probe")
        }
    }
}
#endif
