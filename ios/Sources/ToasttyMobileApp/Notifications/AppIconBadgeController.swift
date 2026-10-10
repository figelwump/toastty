import OSLog
import UserNotifications

struct AppIconBadgeSettings: Sendable {
    let authorizationStatus: UNAuthorizationStatus
    let badgesEnabled: Bool
}

@MainActor
protocol AppIconBadgeClient {
    func notificationSettings() async -> AppIconBadgeSettings
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

    func setBadgeCount(_ count: Int) async throws {
        try await UNUserNotificationCenter.current().setBadgeCount(count)
    }
}

/// Uses existing badge permission and never requests it.
/// Keeps one system write in flight so an older update cannot undo an unpair.
@MainActor
final class AppIconBadgeController {
    private static let logger = Logger(subsystem: "com.giantthings.toastty.mobile", category: "badge")
    private let client: any AppIconBadgeClient
    private var desiredCount: Int?
    private var needsSync = false
    private var worker: Task<Void, Never>?

    init(client: any AppIconBadgeClient) {
        self.client = client
    }

    /// `nil` means the current count is unknown. Preserve the last count,
    /// including the system's badge across a cold launch, until a live snapshot.
    /// The returned task finishes after all queued updates have been applied.
    @discardableResult
    func update(count: Int?) -> Task<Void, Never>? {
        if let count { desiredCount = count }
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
                let settings = await client.notificationSettings()
                guard !needsSync else { continue }
                guard settings.badgesEnabled else { continue }
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
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
