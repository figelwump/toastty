import Foundation
import RemoteProtocol
import UserNotifications

/// This projection contains no notification content or device/pairing identity.
struct ToasttyPushReceiverSnapshot: Codable, Equatable, Sendable {
    struct Settings: Codable, Equatable, Sendable {
        enum Authorization: String, Codable, Sendable {
            case notDetermined, denied, authorized, provisional, ephemeral, unknown
        }
        enum Setting: String, Codable, Sendable { case enabled, disabled, notSupported, unknown }
        let authorization: Authorization
        let alert: Setting
        let lockScreen: Setting
        let notificationCenter: Setting

        init(authorizationStatus: UNAuthorizationStatus, alert: UNNotificationSetting,
             lockScreen: UNNotificationSetting, notificationCenter: UNNotificationSetting) {
            switch authorizationStatus {
            case .notDetermined: authorization = .notDetermined
            case .denied: authorization = .denied
            case .authorized: authorization = .authorized
            case .provisional: authorization = .provisional
            case .ephemeral: authorization = .ephemeral
            @unknown default: authorization = .unknown
            }
            self.alert = Self.setting(alert)
            self.lockScreen = Self.setting(lockScreen)
            self.notificationCenter = Self.setting(notificationCenter)
        }

        private static func setting(_ value: UNNotificationSetting) -> Setting {
            switch value {
            case .enabled: .enabled
            case .disabled: .disabled
            case .notSupported: .notSupported
            @unknown default: .unknown
            }
        }
    }

    struct Delegate: Codable, Equatable, Sendable {
        enum Identity: String, Codable, Sendable { case expected, none, other }
        let identity: Identity
        let foregroundSelector: Bool
        let responseSelector: Bool

        @MainActor
        static func capture(actual: (any UNUserNotificationCenterDelegate)?,
                            expected: (any UNUserNotificationCenterDelegate)?) -> Self {
            let identity: Identity = actual == nil ? .none : actual === expected ? .expected : .other
            return Self(identity: identity,
                foregroundSelector: actual?.responds(to: NSSelectorFromString(
                    "userNotificationCenter:willPresentNotification:withCompletionHandler:")) == true,
                responseSelector: actual?.responds(to: NSSelectorFromString(
                    "userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:")) == true)
        }
    }

    struct Callbacks: Codable, Equatable, Sendable {
        var entered: UInt64 = 0
        var verification: UInt64 = 0
        var session: UInt64 = 0
        var malformed: UInt64 = 0
        var ignored: UInt64 = 0
    }

    struct Recovery: Codable, Equatable, Sendable {
        enum ReferenceKind: String, Codable, Sendable { case none, pendingCreated, requestStarted }
        let capturedAt: Date
        let referenceAt: Date?
        let referenceKind: ReferenceKind
        let hasPendingRegistration: Bool
        let hasPairing: Bool
        var raw = 0
        var verification = 0
        var session = 0
        var malformed = 0
        // Match counts apply only to decoded verification notifications.
        var matchingRegistration = 0
        var matchingPairing = 0
        var matchingBoth = 0
        var beforeReference = 0
        var atOrAfterReference = 0
        var withoutReference = 0
        var verificationAtOrAfterReference = 0
    }

    var sequence: UInt64 = 0
    var capturedAt = Date.now
    var settings: Settings?
    var delegate: Delegate?
    var foreground = Callbacks()
    var response = Callbacks()
    var firstRecovery: Recovery?
    var latestRecovery: Recovery?
}

/// Used only while classifying one fetched array. Never encoded or retained in
/// the recorder. A restored pending creation time is not an observed send time.
struct ToasttyPushRecoveryContext {
    let pendingRegistrationID: UUID?
    let pairingID: UUID?
    let referenceAt: Date?
    let referenceKind: ToasttyPushReceiverSnapshot.Recovery.ReferenceKind
}

/// UN callbacks can enter off the main actor and before SwiftUI attaches the
/// report. Keep counters synchronously at that boundary, then publish safe
/// snapshots. The lock protects all state; handlers run outside it.
final class ToasttyPushReceiverDiagnostics: @unchecked Sendable {
    enum Callback { case foreground, response }
    private let lock = NSLock()
    private var value = ToasttyPushReceiverSnapshot()
    private var handler: (@Sendable (ToasttyPushReceiverSnapshot) -> Void)?

    var snapshot: ToasttyPushReceiverSnapshot { lock.withLock { value } }

    func installHandler(_ handler: @escaping @Sendable (ToasttyPushReceiverSnapshot) -> Void) {
        let snapshot = lock.withLock {
            self.handler = handler
            return value
        }
        handler(snapshot)
    }

    func beginCallback(_ callback: Callback) {
        update { value in
            switch callback {
            case .foreground: value.foreground.entered &+= 1
            case .response: value.response.entered &+= 1
            }
        }
    }

    func decodedCallback(_ callback: Callback, payload: RemotePushPayload?, ignored: Bool = false) {
        update { value in
            var counts = callback == .foreground ? value.foreground : value.response
            if ignored { counts.ignored &+= 1 }
            else if let payload {
                switch payload.kind {
                case .verification: counts.verification &+= 1
                case .session: counts.session &+= 1
                }
            } else { counts.malformed &+= 1 }
            switch callback {
            case .foreground: value.foreground = counts
            case .response: value.response = counts
            }
        }
    }

    func recordEnvironment(settings: ToasttyPushReceiverSnapshot.Settings,
                           delegate: ToasttyPushReceiverSnapshot.Delegate) {
        update { $0.settings = settings; $0.delegate = delegate }
    }

    func recordRecovery(_ recovery: ToasttyPushReceiverSnapshot.Recovery) {
        update {
            if $0.firstRecovery == nil { $0.firstRecovery = recovery }
            $0.latestRecovery = recovery
        }
    }

    private func update(_ body: (inout ToasttyPushReceiverSnapshot) -> Void) {
        let (snapshot, publish): (ToasttyPushReceiverSnapshot,
            (@Sendable (ToasttyPushReceiverSnapshot) -> Void)?) = lock.withLock {
            body(&value)
            value.sequence &+= 1
            value.capturedAt = .now
            return (value, handler)
        }
        // Concurrent callback threads can publish out of order. The file
        // recorder accepts only newer sequence numbers.
        publish?(snapshot)
    }
}
