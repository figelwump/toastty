import Foundation

/// One local audit entry for a remote action or security-relevant change.
/// Audit entries never contain transcript content or credential values.
public struct RemoteAccessAuditEntry: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Equatable, Sendable {
        case pairingCodeIssued = "pairing_code_issued"
        case devicePaired = "device_paired"
        case pairingFailed = "pairing_failed"
        case authenticationFailed = "authentication_failed"
        case rateLimitLockout = "rate_limit_lockout"
        case deviceScopesChanged = "device_scopes_changed"
        case deviceRevoked = "device_revoked"
        case allDevicesRevoked = "all_devices_revoked"
        case remoteAccessEnabled = "remote_access_enabled"
        case remoteAccessDisabled = "remote_access_disabled"
        case sessionSubscribed = "session_subscribed"
        case questionAnswerSubmitted = "question_answer_submitted"
        case questionAnswerRejected = "question_answer_rejected"
        case remoteSendAccepted = "remote_send_accepted"
        case remoteSendRejected = "remote_send_rejected"
        case remoteSendUncertain = "remote_send_uncertain"
        case sessionWritesChanged = "session_writes_changed"
    }

    public var at: Date
    public var action: Action
    public var deviceID: UUID?
    /// Stable non-identifying context (for example, a rejection reason).
    /// Never names, identities, paths, message text, prompts, or tokens.
    public var detail: String?

    public init(at: Date, action: Action, deviceID: UUID? = nil, detail: String? = nil) {
        self.at = at
        self.action = action
        self.deviceID = deviceID
        self.detail = detail
    }
}

/// Bounded, persisted audit ring for remote-access activity.
public final class RemoteAccessAuditLog {
    public static let defaultCapacity = 500

    private(set) var entries: [RemoteAccessAuditEntry]
    private let capacity: Int
    private let fileURL: URL?

    public init(fileURL: URL?, capacity: Int = RemoteAccessAuditLog.defaultCapacity) {
        self.fileURL = fileURL
        self.capacity = max(1, capacity)
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([RemoteAccessAuditEntry].self, from: data) {
            self.entries = Array(decoded.suffix(self.capacity))
        } else {
            self.entries = []
        }
    }

    public func record(_ entry: RemoteAccessAuditEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        persist()
        ToasttyLog.info(
            "Remote access audit",
            category: .automation,
            metadata: [
                "action": entry.action.rawValue,
                "device_id": entry.deviceID?.uuidString ?? "-",
                "detail": entry.detail ?? "-",
            ]
        )
    }

    public func recentEntries(limit: Int = 100) -> [RemoteAccessAuditEntry] {
        Array(entries.suffix(max(0, limit)))
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(entries)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            ToasttyLog.error(
                "Failed to persist remote access audit log",
                category: .automation,
                metadata: ["error_type": String(reflecting: type(of: error))]
            )
        }
    }
}
