import Foundation

public enum AutomationSocketProtocol {
    public static let version = "1.0"
}

public struct AutomationEnvelopeHeader: Decodable, Equatable, Sendable {
    public let protocolVersion: String
    public let kind: String

    public init(protocolVersion: String, kind: String) {
        self.protocolVersion = protocolVersion
        self.kind = kind
    }
}

public struct AutomationEventEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: String
    public let kind: String
    public let requestID: String?
    public let eventType: String
    public let sessionID: String?
    public let panelID: String?
    public let timestamp: String?
    public let payload: [String: AutomationJSONValue]

    public init(
        eventType: String,
        sessionID: String? = nil,
        panelID: String? = nil,
        timestamp: String? = nil,
        requestID: String? = nil,
        payload: [String: AutomationJSONValue]
    ) {
        self.protocolVersion = AutomationSocketProtocol.version
        self.kind = "event"
        self.requestID = requestID
        self.eventType = eventType
        self.sessionID = sessionID
        self.panelID = panelID
        self.timestamp = timestamp
        self.payload = payload
    }

    public var parsedTimestamp: Date? {
        guard let timestamp else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFractional.date(from: timestamp) {
            return parsed
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: timestamp)
    }
}

public struct AutomationRequestEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: String
    public let kind: String
    public let requestID: String
    public let command: String
    public let payload: [String: AutomationJSONValue]

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case kind
        case requestID
        case command
        case payload
    }

    public init(
        requestID: String,
        command: String,
        payload: [String: AutomationJSONValue] = [:]
    ) {
        self.protocolVersion = AutomationSocketProtocol.version
        self.kind = "request"
        self.requestID = requestID
        self.command = command
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        kind = try container.decode(String.self, forKey: .kind)
        requestID = try container.decode(String.self, forKey: .requestID)
        command = try container.decode(String.self, forKey: .command)
        payload = try container.decodeIfPresent([String: AutomationJSONValue].self, forKey: .payload) ?? [:]
    }
}

public struct AutomationResponseEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: String
    public let kind: String
    public let requestID: String
    public let ok: Bool
    public let result: [String: AutomationJSONValue]?
    public let error: AutomationResponseError?

    public init(
        requestID: String,
        ok: Bool,
        result: [String: AutomationJSONValue]?,
        error: AutomationResponseError?
    ) {
        self.protocolVersion = AutomationSocketProtocol.version
        self.kind = "response"
        self.requestID = requestID
        self.ok = ok
        self.result = result
        self.error = error
    }
}

public struct AutomationResponseError: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum AutomationJSONValue: Sendable, Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: AutomationJSONValue])
    case array([AutomationJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: AutomationJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([AutomationJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported json value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public extension Dictionary where Key == String, Value == AutomationJSONValue {
    func string(_ key: String) -> String? {
        guard case .string(let value)? = self[key] else {
            return nil
        }
        return value
    }

    func bool(_ key: String) -> Bool? {
        guard case .bool(let value)? = self[key] else {
            return nil
        }
        return value
    }

    func int(_ key: String) -> Int? {
        guard case .int(let value)? = self[key] else {
            return nil
        }
        return value
    }

    func uuid(_ key: String) -> UUID? {
        guard let value = string(key) else { return nil }
        return UUID(uuidString: value)
    }

    func stringArray(_ key: String) -> [String] {
        guard case .array(let values)? = self[key] else {
            return []
        }
        return values.compactMap {
            guard case .string(let value) = $0 else { return nil }
            return value
        }
    }

    func object(_ key: String) -> [String: AutomationJSONValue]? {
        guard case .object(let value)? = self[key] else {
            return nil
        }
        return value
    }
}
