import OSLog
import UserNotifications

struct AppIconBadgeSettings: Sendable {
    let authorizationStatus: UNAuthorizationStatus
    let badgesEnabled: Bool
}

@MainActor
protocol AppIconBadgeClient {
    func notificationSettings() async -> AppIconBadgeSettings
    func requestBadgeAuthorization() async throws
    func setBadgeCount(_ count: Int) async throws
}

struct SystemAppIconBadgeClient: AppIconBadgeClient {
    func notificationSettings() async -> AppIconBadgeSettings {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return AppIconBadgeSettings(
            authorizationStatus: settings.authorizationStatus,
            badgesEnabled: settings.badgeSetting == .enabled
        )
    }

    func requestBadgeAuthorization() async throws {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.badge])
    }

    func setBadgeCount(_ count: Int) async throws {
        try await UNUserNotificationCenter.current().setBadgeCount(count)
    }
}

/// Keeps one system write in flight. Permission dialogs and badge writes may
/// finish after a newer snapshot or unpair, so cancellation alone is not enough.
@MainActor
final class AppIconBadgeController {
    private static let logger = Logger(subsystem: "com.giantthings.toastty.mobile", category: "badge")
    private let client: any AppIconBadgeClient
    private let requestsAuthorization: Bool
    private var desiredCount: Int?
    private var canRequestAuthorization = false
    private var needsSync = false
    private var worker: Task<Void, Never>?

    init(client: any AppIconBadgeClient, requestsAuthorization: Bool = true) {
        self.client = client
        self.requestsAuthorization = requestsAuthorization
    }

    /// `nil` means the current count is unknown. Preserve the last count,
    /// including the system's badge across a cold launch, until a live snapshot.
    /// The returned task finishes after all queued updates have been applied.
    @discardableResult
    func update(count: Int?, isActive: Bool) -> Task<Void, Never>? {
        if let count { desiredCount = count }
        canRequestAuthorization = requestsAuthorization && isActive && count != nil
        guard desiredCount != nil else { return worker }
        needsSync = true
        if worker == nil {
            worker = Task { await synchronize() }
        }
        return worker
    }

    private func synchronize() async {
        defer { worker = nil }
        while needsSync {
            needsSync = false
            guard let count = desiredCount else { continue }
            do {
                // Clearing never prompts, even if permission was revoked.
                if count == 0 {
                    try await client.setBadgeCount(0)
                    continue
                }
                var settings = await client.notificationSettings()
                guard !needsSync else { continue }
                if settings.authorizationStatus == .notDetermined, canRequestAuthorization {
                    try await client.requestBadgeAuthorization()
                    guard !needsSync else { continue }
                    settings = await client.notificationSettings()
                    guard !needsSync else { continue }
                }
                guard settings.badgesEnabled else { continue }
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    // A permission alert can make the scene inactive. Only
                    // requesting permission requires an active scene.
                    try await client.setBadgeCount(count)
                case .notDetermined, .denied:
                    break
                @unknown default:
                    break
                }
            } catch {
                // Retry on a later count or lifecycle event, not a busy loop.
                let failure = error as NSError
                Self.logger.error("Could not synchronize app icon badge: \(failure.domain, privacy: .public) \(failure.code)")
            }
        }
    }
}
