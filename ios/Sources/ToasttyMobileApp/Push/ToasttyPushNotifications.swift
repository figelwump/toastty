import Foundation
import Observation
import RemoteProtocol
import UIKit
import UserNotifications

enum ToasttyNotificationPermission: Equatable, Sendable { case undetermined, allowed, denied }

@MainActor
protocol ToasttyPushNotificationClient: AnyObject {
    func permission() async -> ToasttyNotificationPermission
    func requestPermission() async throws -> Bool
    func register()
    func deliveredPayloads() async -> [RemotePushPayload]
    func removeVerificationNotifications(registrationIDs: Set<UUID>) async
}

/// APNs callbacks can arrive before SwiftUI creates the paired session.
/// Keep only bounded, typed events until the controller is installed.
@MainActor
final class ToasttyPushNotificationBridge {
    var onDiagnosticRecord: (@MainActor (ToasttyDiagnosticRecord) -> Void)? {
        didSet {
            guard let onDiagnosticRecord else { return }
            let queued = queuedDiagnostics
            queuedDiagnostics.removeAll()
            queued.forEach(onDiagnosticRecord)
        }
    }
    private var queuedDiagnostics: [ToasttyDiagnosticRecord] = []
    var deviceToken: String?
    var onToken: (@MainActor (String) -> Void)?
    var onRegistrationFailure: (@MainActor () -> Void)?
    var onForeground: (@MainActor (RemotePushPayload) async -> Bool)? {
        didSet {
            guard let onForeground else { return }
            let proofs = queuedProofs
            queuedProofs.removeAll()
            Task { for payload in proofs { _ = await onForeground(payload) } }
        }
    }
    var onTap: (@MainActor (RemotePushPayload) -> Void)? {
        didSet {
            guard let onTap else { return }
            let queued = queuedTaps
            queuedTaps.removeAll()
            queued.forEach(onTap)
        }
    }
    private var queuedTaps: [RemotePushPayload] = []
    private var queuedProofs: [RemotePushPayload] = []

    func recordDiagnostic(_ event: ToasttyConnectionDiagnosticEvent) {
        let record = ToasttyDiagnosticRecord(event: event)
        if let onDiagnosticRecord { onDiagnosticRecord(record) }
        else { queuedDiagnostics = Array((queuedDiagnostics + [record]).suffix(8)) }
    }

    func registered(_ data: Data) {
        let value = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = value
        onToken?(value)
    }

    func receivedTap(_ payload: RemotePushPayload) {
        if payload.kind == .verification {
            Task { _ = await receivedForeground(payload) }
            return
        }
        if let onTap { onTap(payload) }
        else { queuedTaps = Array((queuedTaps + [payload]).suffix(8)) }
    }

    func receivedForeground(_ payload: RemotePushPayload) async -> Bool {
        if let onForeground { return await onForeground(payload) }
        if payload.kind == .verification {
            recordDiagnostic(.pushProofBuffered)
            queuedProofs = Array((queuedProofs.filter { $0.registrationID != payload.registrationID } + [payload]).suffix(8))
        }
        return true
    }

    static nonisolated func payload(_ userInfo: [AnyHashable: Any]) -> RemotePushPayload? {
        guard let object = userInfo["toastty"] as? [String: Any],
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              data.count <= RemotePushPolicy.maximumBodyBytes else { return nil }
        return try? JSONDecoder().decode(RemotePushPayload.self, from: data)
    }
}

@MainActor
final class ToasttySystemPushNotificationClient: ToasttyPushNotificationClient {
    func permission() async -> ToasttyNotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.permission(authorizationStatus: settings.authorizationStatus,
                              alert: settings.alertSetting, lockScreen: settings.lockScreenSetting,
                              notificationCenter: settings.notificationCenterSetting)
    }
    static func permission(authorizationStatus: UNAuthorizationStatus, alert: UNNotificationSetting,
                           lockScreen: UNNotificationSetting, notificationCenter: UNNotificationSetting)
        -> ToasttyNotificationPermission {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            [alert, lockScreen, notificationCenter].contains(.enabled) ? .allowed : .denied
        case .notDetermined: .undetermined
        case .denied: .denied
        @unknown default: .denied
        }
    }
    func requestPermission() async throws -> Bool {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        return await permission() == .allowed
    }
    func register() { UIApplication.shared.registerForRemoteNotifications() }
    func deliveredPayloads() async -> [RemotePushPayload] {
        await UNUserNotificationCenter.current().deliveredNotifications().compactMap {
            ToasttyPushNotificationBridge.payload($0.request.content.userInfo)
        }
    }
    func removeVerificationNotifications(registrationIDs: Set<UUID>) async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.deliveredNotifications().compactMap { notification in
            guard let payload = ToasttyPushNotificationBridge.payload(notification.request.content.userInfo),
                  payload.kind == .verification, registrationIDs.contains(payload.registrationID) else { return nil as String? }
            return notification.request.identifier
        }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}

@MainActor
final class ToasttyMobileApplicationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let pushBridge = ToasttyPushNotificationBridge()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        pushBridge.registered(deviceToken)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        pushBridge.recordDiagnostic(.pushTokenRequestFailed)
        pushBridge.onRegistrationFailure?()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard let payload = ToasttyPushNotificationBridge.payload(notification.request.content.userInfo) else {
            await recordInvalidPayload()
            return []
        }
        let suppress = await handleForeground(payload)
        return suppress ? [] : [.banner, .list, .sound]
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let isDefaultAction = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let payload = isDefaultAction
            ? ToasttyPushNotificationBridge.payload(response.notification.request.content.userInfo) : nil
        // UIKit updates its snapshot when this callback finishes. The async
        // delegate form can invoke its generated completion off the main thread.
        Task { @MainActor in
            if isDefaultAction, payload == nil {
                pushBridge.recordDiagnostic(.pushPayloadInvalid)
            }
            if let payload { pushBridge.receivedTap(payload) }
            completionHandler()
        }
    }
    private func handleForeground(_ payload: RemotePushPayload) async -> Bool {
        await pushBridge.receivedForeground(payload)
    }

    private func recordInvalidPayload() { pushBridge.recordDiagnostic(.pushPayloadInvalid) }
}
