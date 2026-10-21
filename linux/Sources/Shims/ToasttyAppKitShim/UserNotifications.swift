import Foundation

// UserNotifications subset. Delivery goes to
// `LinuxPlatformServices.deliverNotification` (GNotification in the GTK
// frontend); activation comes back through
// `LinuxPlatform.handleNotificationActivation`, which calls the installed
// `UNUserNotificationCenterDelegate` like macOS does.

public enum UNAuthorizationStatus: Int, Sendable {
    case notDetermined = 0
    case denied = 1
    case authorized = 2
    case provisional = 3
    case ephemeral = 4
}

public struct UNAuthorizationOptions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let badge = Self(rawValue: 1 << 0)
    public static let sound = Self(rawValue: 1 << 1)
    public static let alert = Self(rawValue: 1 << 2)
}

public let UNErrorDomain = "UNErrorDomain"

public struct UNError: Error, Sendable {
    public enum Code: Int, Sendable {
        case notificationsNotAllowed = 1
        case attachmentInvalidURL = 100
        case notificationInvalidNoDate = 1400
        case notificationInvalidNoContent = 1401
    }

    public let code: Code
    public init(_ code: Code) { self.code = code }
}

extension UNError: CustomNSError {
    public static var errorDomain: String { UNErrorDomain }
    public var errorCode: Int { code.rawValue }
}

public struct UNNotificationSound: Equatable, Sendable {
    public static let `default` = UNNotificationSound()
}

public class UNNotificationContent: @unchecked Sendable {
    public internal(set) var title = ""
    public internal(set) var subtitle = ""
    public internal(set) var body = ""
    public internal(set) var sound: UNNotificationSound?
    public internal(set) var userInfo: [AnyHashable: Any] = [:]
    public init() {}
}

public final class UNMutableNotificationContent: UNNotificationContent, @unchecked Sendable {
    public override var title: String {
        get { super.title }
        set { super.title = newValue }
    }

    public override var subtitle: String {
        get { super.subtitle }
        set { super.subtitle = newValue }
    }

    public override var body: String {
        get { super.body }
        set { super.body = newValue }
    }

    public override var sound: UNNotificationSound? {
        get { super.sound }
        set { super.sound = newValue }
    }

    public override var userInfo: [AnyHashable: Any] {
        get { super.userInfo }
        set { super.userInfo = newValue }
    }
}

public class UNNotificationTrigger: @unchecked Sendable {}

public final class UNNotificationRequest: @unchecked Sendable {
    public let identifier: String
    public let content: UNNotificationContent
    public let trigger: UNNotificationTrigger?

    public init(identifier: String, content: UNNotificationContent, trigger: UNNotificationTrigger?) {
        self.identifier = identifier
        self.content = content
        self.trigger = trigger
    }
}

public final class UNNotification: @unchecked Sendable {
    public let request: UNNotificationRequest
    public let date: Date
    init(request: UNNotificationRequest, date: Date) {
        self.request = request
        self.date = date
    }
}

public final class UNNotificationResponse: @unchecked Sendable {
    public static let defaultActionIdentifier = "com.apple.UNNotificationDefaultActionIdentifier"
    public let notification: UNNotification
    public let actionIdentifier: String
    init(notification: UNNotification, actionIdentifier: String) {
        self.notification = notification
        self.actionIdentifier = actionIdentifier
    }
}

public final class UNNotificationSettings: @unchecked Sendable {
    public let authorizationStatus: UNAuthorizationStatus
    init(authorizationStatus: UNAuthorizationStatus) {
        self.authorizationStatus = authorizationStatus
    }
}

public protocol UNUserNotificationCenterDelegate: AnyObject {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async
}

public final class UNUserNotificationCenter: @unchecked Sendable {
    private static let shared = UNUserNotificationCenter()
    private let lock = NSLock()
    private weak var storedDelegate: (any UNUserNotificationCenterDelegate)?

    public static func current() -> UNUserNotificationCenter { shared }

    public var delegate: (any UNUserNotificationCenterDelegate)? {
        get { lock.withLock { storedDelegate } }
        set { lock.withLock { storedDelegate = newValue } }
    }

    public func notificationSettings() async -> UNNotificationSettings {
        let status = await MainActor.run { () -> UNAuthorizationStatus in
            switch LinuxPlatform.services.notificationAuthorization() {
            case .notDetermined: .notDetermined
            case .authorized: .authorized
            case .denied: .denied
            }
        }
        return UNNotificationSettings(authorizationStatus: status)
    }

    public func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        _ = options
        return await MainActor.run { LinuxPlatform.services.requestNotificationAuthorization() }
    }

    public func add(_ request: UNNotificationRequest) async throws {
        let content = request.content
        var userInfo: [String: String] = [:]
        for (key, value) in content.userInfo {
            if let key = key as? String, let value = value as? String {
                userInfo[key] = value
            }
        }
        let notification = LinuxDesktopNotification(
            identifier: request.identifier,
            title: content.title,
            body: content.body,
            playsSound: content.sound != nil,
            userInfo: userInfo
        )
        try await MainActor.run {
            do {
                try LinuxPlatform.services.deliverNotification(notification)
            } catch LinuxPlatformError.notificationsUnavailable {
                throw UNError(.notificationsNotAllowed)
            }
        }
    }

    public func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        Task { @MainActor in LinuxPlatform.services.removeNotifications(identifiers: identifiers) }
    }

    public func removeAllDeliveredNotifications() {}

    func deliverActivation(identifier: String, userInfo: [String: String]) {
        let content = UNMutableNotificationContent()
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        let response = UNNotificationResponse(
            notification: UNNotification(request: request, date: Date()),
            actionIdentifier: UNNotificationResponse.defaultActionIdentifier
        )
        guard let delegate else { return }
        let box = UncheckedSendableBox(value: (delegate, response))
        Task {
            await box.value.0.userNotificationCenter(self, didReceive: box.value.1)
        }
    }
}

struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}
