import CryptoKit
import Foundation

/// The only approval scope that can be delegated to a bot. The app writes
/// the approval text from this data. Free-text questions are owner-only.
public struct TaskFleetChecks: Codable, Equatable, Sendable {
    public let version: String
    public let targets: [String]

    public init?(version: String, targets: [String]) {
        func isLabel(_ text: String, extra: String) -> Bool {
            let lettersAndDigits = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
            return (1...253).contains(text.utf8.count)
                && text.first.map { lettersAndDigits.contains($0) } == true
                && text.allSatisfy { lettersAndDigits.contains($0) || extra.contains($0) }
        }
        guard version.utf8.count <= 40, isLabel(version, extra: ".-+"),
              (1...50).contains(targets.count),
              targets.allSatisfy({ isLabel($0, extra: ".-_") }) else { return nil }
        self.version = version
        self.targets = Set(targets).sorted()
    }

    public var question: String { "Allow read-only fleet status checks?" }

    public var detail: String {
        "For website release \(version), read installed-version receipts and check Recovery HTTPS status for these targets: "
            + targets.joined(separator: ", ") + "."
    }
}

public struct TaskFleetAnswerGrant: Codable, Equatable, Sendable {
    public let webhookID: UUID
    public let webhookName: String
    public let credentialGeneration: String
    public let scope: TaskFleetChecks

    public init(webhookID: UUID, webhookName: String, credentialGeneration: String, scope: TaskFleetChecks) {
        self.webhookID = webhookID
        self.webhookName = webhookName
        self.credentialGeneration = credentialGeneration
        self.scope = scope
    }
}

public struct TaskApprovalAnswer: Codable, Equatable, Sendable {
    public enum Decision: String, Codable, Sendable {
        case approve, decline
    }

    public enum Delivery: String, Codable, Sendable {
        case queued, sent, sentUnconfirmed, cancelled
    }

    public static let questionLifetime: TimeInterval = 24 * 60 * 60
    public static let messagePrefix = "[Toastty task answer]"

    public let id: UUID
    public let questionID: UUID
    public let decision: Decision
    public let answeredAt: Date
    public let question: String
    public let grant: TaskFleetAnswerGrant?
    public var delivery: Delivery = .queued
    public var sessionID: String?

    public init(questionID: UUID, decision: Decision, answeredAt: Date, question: String, grant: TaskFleetAnswerGrant?) {
        self.id = UUID()
        self.questionID = questionID
        self.decision = decision
        self.answeredAt = answeredAt
        self.question = question
        self.grant = grant
    }

    public var messageHeader: String {
        "\(Self.messagePrefix) \(id.uuidString) \(questionID.uuidString) \(decision.rawValue)"
    }

    public var displaySource: String {
        grant.map { "via \($0.webhookName)" } ?? "by you"
    }

    /// Domain-separated from the webhook's outgoing signatures. Each
    /// signature authorizes one decision for one question on one task.
    public static func verifies(
        signature: String, secret: String, webhookID: UUID, taskID: UUID, questionID: UUID, decision: Decision
    ) -> Bool {
        guard signature.utf8.count == 64 else { return false }
        let bytes = Array(signature.utf8)
        var code = Data()
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            guard let value = UInt8(String(decoding: bytes[offset...offset + 1], as: UTF8.self), radix: 16) else { return false }
            code.append(value)
        }
        let message = "toastty-task-answer-v1\n\(webhookID.uuidString)\n\(taskID.uuidString)\n\(questionID.uuidString)\n\(decision.rawValue)"
        let key = SymmetricKey(data: Data(secret.utf8))
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: Data(message.utf8), using: key)
    }
}
