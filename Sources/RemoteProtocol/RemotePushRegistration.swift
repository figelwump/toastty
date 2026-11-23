import Foundation

public enum RemotePushAPNsEnvironment: String, Codable, Equatable, Sendable {
    case development
    case production
}

public enum RemotePushPolicy {
    public static let maximumBodyBytes = 4 * 1024
    public static let maximumTitleBytes = 512
    /// A task alert's question, the only alert text besides a title.
    public static let maximumDetailBytes = 512
    public static let developmentRelayID = "toastty-push-dev-v1"
    public static let configurationPath = "/v1/native-device/push-configuration"
    public static let registrationPath = "/v1/native-device/push"

    public static func isValidCapabilityToken(_ token: String) -> Bool {
        guard token.utf8.count == 43,
              let bytes = Data(base64URLString: token), bytes.count == 32 else { return false }
        return bytes.base64URLEncodedString() == token
    }

    /// Keep complete characters in the alert and omit characters that can
    /// change how notification text is displayed.
    public static func notificationTitle(_ title: String, fallback: String = "Toastty session") -> String {
        let clean = String(String.UnicodeScalarView(title.unicodeScalars.filter {
            switch $0.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: false
            default: true
            }
        }))
        return prefix(clean, maximumBytes: maximumTitleBytes) ?? fallback
    }

    /// One line of alert text: line breaks and tabs become spaces, other
    /// characters that change how text is displayed are dropped, and text
    /// longer than `maximumBytes` ends with an ellipsis. `nil` when nothing
    /// remains.
    public static func notificationDetail(_ text: String, maximumBytes: Int = maximumDetailBytes) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .lineSeparator, .paragraphSeparator: scalars.append(" ")
            case .control: if scalar == "\n" || scalar == "\r" || scalar == "\t" { scalars.append(" ") }
            default: scalars.append(scalar)
            }
        }
        let line = String(scalars).split(whereSeparator: { $0 == " " }).joined(separator: " ")
        guard line.utf8.count > maximumBytes else { return line.isEmpty ? nil : line }
        return prefix(line, maximumBytes: maximumBytes - "…".utf8.count).map { $0 + "…" }
    }

    private static func prefix(_ text: String, maximumBytes: Int) -> String? {
        var result = ""
        for character in text {
            guard result.utf8.count + String(character).utf8.count <= maximumBytes else { break }
            result.append(character)
        }
        return result.isEmpty ? nil : result
    }
}

public struct RemoteGatewayPushConfigurationResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var relayID: String?
    public var apnsEnvironment: RemotePushAPNsEnvironment?
    public var registrationID: UUID?

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        relayID: String? = nil,
        apnsEnvironment: RemotePushAPNsEnvironment? = nil,
        registrationID: UUID? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.relayID = relayID
        self.apnsEnvironment = apnsEnvironment
        self.registrationID = registrationID
    }

    private enum CodingKeys: String, CodingKey { case protocolVersion, relayID, apnsEnvironment, registrationID }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encodeIfPresent(relayID, forKey: .relayID)
        try container.encodeIfPresent(apnsEnvironment, forKey: .apnsEnvironment)
        try container.encode(registrationID, forKey: .registrationID)
    }
}

/// Returned by the phone only after its relay delivery proof is complete.
/// The host derives the paired device identity from native authentication.
public struct RemoteGatewayPushRegistration: Codable, Equatable, Sendable {
    public var registrationID: UUID
    public var sendToken: String
    public var relayID: String

    public init(registrationID: UUID, sendToken: String, relayID: String) {
        self.registrationID = registrationID
        self.sendToken = sendToken
        self.relayID = relayID
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case registrationID, sendToken, relayID }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownPushFields(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        registrationID = try container.decode(UUID.self, forKey: .registrationID)
        sendToken = try container.decode(String.self, forKey: .sendToken)
        relayID = try container.decode(String.self, forKey: .relayID)
    }
}

public struct RemoteGatewayPushRegistrationRequest: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var registration: RemoteGatewayPushRegistration?

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        registration: RemoteGatewayPushRegistration?
    ) {
        self.protocolVersion = protocolVersion
        self.registration = registration
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case protocolVersion, registration }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownPushFields(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        guard container.contains(.registration) else {
            throw DecodingError.keyNotFound(CodingKeys.registration, .init(codingPath: decoder.codingPath, debugDescription: "Missing registration"))
        }
        registration = try container.decodeIfPresent(RemoteGatewayPushRegistration.self, forKey: .registration)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(registration, forKey: .registration)
    }
}

public struct RemoteGatewayPushRegistrationResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var registrationID: UUID?

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        registrationID: UUID?
    ) {
        self.protocolVersion = protocolVersion
        self.registrationID = registrationID
    }

    private enum CodingKeys: String, CodingKey { case protocolVersion, registrationID }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(registrationID, forKey: .registrationID)
    }
}

public enum RemotePushSessionStatus: String, Codable, Equatable, Sendable {
    case ready
    case needsApproval = "needs_approval"
}

public struct RemotePushSessionNotification: Codable, Equatable, Sendable {
    public var eventID: UUID
    public var conversationID: RemoteConversationID
    public var sessionTitle: String
    public var status: RemotePushSessionStatus

    public init(eventID: UUID, conversationID: RemoteConversationID, sessionTitle: String, status: RemotePushSessionStatus) {
        self.eventID = eventID
        self.conversationID = conversationID
        self.sessionTitle = RemotePushPolicy.notificationTitle(sessionTitle)
        self.status = status
    }
}

/// Why a task needs the user. The relay words the alert for each reason, so
/// the Mac sends only the task's title, its question and a pull request
/// number.
public enum RemotePushTaskAlertReason: String, Codable, Equatable, Sendable, CaseIterable {
    /// The agent ended its turn with a question (`task needs-reply`).
    case question
    /// The pull request is open and waits for review, or the agent marked
    /// work without one ready.
    case review
    /// An accepted merge stopped without merging.
    case mergeStopped = "merge_stopped"
    case setupFailed = "setup_failed"
    /// The move into a worktree failed.
    case moveFailed = "move_failed"
    /// The cleanup after a merge, archive or release stopped.
    case cleanupStopped = "cleanup_stopped"
}

/// A task alert, as the Mac sends it to the relay. Every key is present, as
/// `null` when empty: the relay accepts exactly these keys.
public struct RemotePushTaskNotification: Codable, Equatable, Sendable {
    public var eventID: UUID
    public var taskID: UUID
    /// The task's session, which a tap opens while its task space is open.
    public var conversationID: RemoteConversationID?
    public var reason: RemotePushTaskAlertReason
    public var taskTitle: String
    /// The agent's question; only `question` carries one.
    public var detail: String?
    /// Only `review` and `mergeStopped` carry one.
    public var pullRequestNumber: Int?

    public init(
        eventID: UUID,
        taskID: UUID,
        conversationID: RemoteConversationID?,
        reason: RemotePushTaskAlertReason,
        taskTitle: String,
        detail: String? = nil,
        pullRequestNumber: Int? = nil
    ) {
        self.eventID = eventID
        self.taskID = taskID
        self.conversationID = conversationID
        self.reason = reason
        self.taskTitle = RemotePushPolicy.notificationTitle(taskTitle, fallback: "Toastty task")
        self.detail = reason == .question ? detail.flatMap { RemotePushPolicy.notificationDetail($0) } : nil
        switch reason {
        case .review, .mergeStopped:
            self.pullRequestNumber = pullRequestNumber.flatMap { (1...Int(Int32.max)).contains($0) ? $0 : nil }
        case .question, .setupFailed, .moveFailed, .cleanupStopped:
            self.pullRequestNumber = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, eventID, taskID, conversationID, reason, taskTitle, detail, pullRequestNumber
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "task" else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Not a task alert")
        }
        self.init(
            eventID: try container.decode(UUID.self, forKey: .eventID),
            taskID: try container.decode(UUID.self, forKey: .taskID),
            conversationID: try container.decodeIfPresent(RemoteConversationID.self, forKey: .conversationID),
            reason: try container.decode(RemotePushTaskAlertReason.self, forKey: .reason),
            taskTitle: try container.decode(String.self, forKey: .taskTitle),
            detail: try container.decodeIfPresent(String.self, forKey: .detail),
            pullRequestNumber: try container.decodeIfPresent(Int.self, forKey: .pullRequestNumber)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("task", forKey: .kind)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(taskID, forKey: .taskID)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encode(reason, forKey: .reason)
        try container.encode(taskTitle, forKey: .taskTitle)
        try container.encode(detail, forKey: .detail)
        try container.encode(pullRequestNumber, forKey: .pullRequestNumber)
    }
}

/// A phone build that predates a kind cannot decode its alerts: iOS still
/// shows the alert's text, and a tap opens the app without routing.
public enum RemotePushPayloadKind: String, Codable, Equatable, Sendable {
    case verification
    case session
    case task
}

/// The bounded `toastty` object inside an APNs alert. Notification taps use
/// pairing identity; a token renewal does not invalidate older session alerts.
public struct RemotePushPayload: Codable, Equatable, Sendable {
    public var version: Int
    public var kind: RemotePushPayloadKind
    public var registrationID: UUID
    public var pairingID: UUID
    public var nonce: String?
    public var conversationID: RemoteConversationID?
    public var eventID: UUID?
    /// The task a task alert is about.
    public var taskID: UUID?

    public init(
        version: Int = 1,
        kind: RemotePushPayloadKind,
        registrationID: UUID,
        pairingID: UUID,
        nonce: String? = nil,
        conversationID: RemoteConversationID? = nil,
        eventID: UUID? = nil,
        taskID: UUID? = nil
    ) {
        self.version = version
        self.kind = kind
        self.registrationID = registrationID
        self.pairingID = pairingID
        self.nonce = nonce
        self.conversationID = conversationID
        self.eventID = eventID
        self.taskID = taskID
    }

    public var isValid: Bool {
        guard version == 1 else { return false }
        switch kind {
        case .verification:
            return nonce.map(RemotePushPolicy.isValidCapabilityToken) == true && conversationID == nil && eventID == nil
                && taskID == nil
        case .session:
            return nonce == nil && conversationID != nil && eventID != nil && taskID == nil
        case .task:
            // A task without an open session has no conversation.
            return nonce == nil && taskID != nil && eventID != nil
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, kind, registrationID, pairingID, nonce, conversationID, eventID, taskID
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownPushFields(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        kind = try container.decode(RemotePushPayloadKind.self, forKey: .kind)
        registrationID = try container.decode(UUID.self, forKey: .registrationID)
        pairingID = try container.decode(UUID.self, forKey: .pairingID)
        nonce = try container.decodeIfPresent(String.self, forKey: .nonce)
        conversationID = try container.decodeIfPresent(RemoteConversationID.self, forKey: .conversationID)
        eventID = try container.decodeIfPresent(UUID.self, forKey: .eventID)
        taskID = try container.decodeIfPresent(UUID.self, forKey: .taskID)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid push payload"))
        }
    }
}

private struct PushCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownPushFields(_ decoder: any Decoder, allowed: [String]) throws {
    let container = try decoder.container(keyedBy: PushCodingKey.self)
    guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown push field"))
    }
}
