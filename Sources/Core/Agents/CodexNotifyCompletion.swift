import CryptoKit
import Foundation

public struct CodexNotifyCompletion: Equatable, Sendable {
    public var notificationType: String
    public var threadID: String?
    public var turnID: String?
    public var lastInputMessageFingerprint: String?
    public var inputMessageCount: Int
    public var detail: String

    public init(
        notificationType: String,
        threadID: String?,
        turnID: String?,
        lastInputMessageFingerprint: String?,
        inputMessageCount: Int,
        detail: String
    ) {
        self.notificationType = notificationType
        self.threadID = threadID
        self.turnID = turnID
        self.lastInputMessageFingerprint = lastInputMessageFingerprint
        self.inputMessageCount = inputMessageCount
        self.detail = detail
    }
}

public enum CodexInputFingerprint {
    public static func fingerprint(for text: String?) -> String? {
        guard let normalized = normalizedText(text) else {
            return nil
        }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func normalizedText(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}
