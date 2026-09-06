import CoreFoundation
import Foundation
import RemoteProtocol

public enum GatewayCompatibilityError: Error, Equatable, Sendable {
    case missingCapability(RemoteGatewayCapability)
    case invalidJSON
    case invalidEnvelope(String)
    case unsupportedProtocolVersion(String)
    case unsupportedEventsOutcome(String)
    case unsupportedSendStatus(String)
    case unsupportedSendRejectionReason(String)
    case unsupportedAPIErrorCode(String)
}

public struct GatewayCompatibilityDecoder: Sendable {
    public init() {}

    public func decodeHello(_ data: Data) throws -> RemoteGatewayHelloResponse {
        let object = try JSONObject(data)
        let protocolVersion = try object.requiredString("protocolVersion")
        try validateProtocolVersion(protocolVersion)
        return RemoteGatewayHelloResponse(
            protocolVersion: protocolVersion,
            minimumSupportedProtocolVersion: try object.requiredString(
                "minimumSupportedProtocolVersion"
            ),
            // Capabilities are additive hints. Keep the shared host model
            // strict, but let an older native client ignore capabilities it
            // does not understand instead of rejecting the entire handshake.
            capabilities: try object.requiredStringArray("capabilities")
                .compactMap(RemoteGatewayCapability.init(rawValue:))
        )
    }

    public func decodePairResponse(_ data: Data) throws -> RemoteGatewayPairResponse {
        let object = try JSONObject(data)
        try validateProtocolVersion(try object.requiredString("protocolVersion"))
        return try decode(RemoteGatewayPairResponse.self, from: object)
    }

    public func decodeSessionListResponse(_ data: Data) throws -> CompatibleSessionListSnapshot {
        let object = try JSONObject(data)
        try validateProtocolVersion(try object.requiredString("protocolVersion"))
        return try decodeSessionListSnapshot(try object.requiredObject("snapshot"))
    }

    public func decodeEventsResponse(_ data: Data) throws -> CompatibleGatewayEventsResponse {
        let object = try JSONObject(data)
        try validateProtocolVersion(try object.requiredString("protocolVersion"))
        switch try object.requiredString("outcome") {
        case "page":
            return .page(try decodeEventPage(try object.requiredObject("page")))
        case "resnapshot_required":
            return .resnapshotRequired
        case "not_found":
            return .conversationNotFound
        case let outcome:
            throw GatewayCompatibilityError.unsupportedEventsOutcome(outcome)
        }
    }

    public func decodeStreamMessage(_ data: Data) throws -> CompatibleGatewayStreamMessage {
        let object = try JSONObject(data)
        try validateProtocolVersion(try object.requiredString("protocolVersion"))
        switch try object.requiredString("type") {
        case "session_list":
            return .sessionList(try decodeSessionListSnapshot(try object.requiredObject("snapshot")))
        case "conversation_events":
            return .conversationEvents(try decodeEventPage(try object.requiredObject("page")))
        case "resnapshot_required":
            return .resnapshotRequired(
                conversationID: try decodeConversationID(object.requiredString("conversationID"))
            )
        case let type:
            return .ignoredUnknown(type: type)
        }
    }

    public func decodeEventPage(_ data: Data) throws -> CompatibleConversationEventPage {
        try decodeEventPage(JSONObject(data))
    }

    public func decodeSendResult(_ data: Data) throws -> RemoteMessageSendResult {
        let object = try JSONObject(data)
        switch try object.requiredString("status") {
        case "accepted", "uncertain", "duplicate":
            return try decode(RemoteMessageSendResult.self, from: object)
        case "rejected":
            let reason = try object.requiredString("reason")
            guard RemoteMessageRejectionReason(rawValue: reason) != nil else {
                throw GatewayCompatibilityError.unsupportedSendRejectionReason(reason)
            }
            return try decode(RemoteMessageSendResult.self, from: object)
        case let status:
            throw GatewayCompatibilityError.unsupportedSendStatus(status)
        }
    }

    private func decodeSessionListSnapshot(_ object: JSONObject) throws -> CompatibleSessionListSnapshot {
        CompatibleSessionListSnapshot(
            projectionRunID: try decodeProjectionRunID(object.requiredString("projectionRunID")),
            conversations: try object.requiredArray("conversations").map(decodeSummary),
            workspaces: ((try? object.requiredArray("workspaces")) ?? []).compactMap {
                try? decodeWorkspaceSummary($0)
            },
            generatedAt: try object.requiredDate("generatedAt")
        )
    }

    private func decodeWorkspaceSummary(_ object: JSONObject) throws -> RemoteWorkspaceSummary {
        guard let id = try object.optionalUUID("id") else {
            throw GatewayCompatibilityError.invalidEnvelope("Missing workspace id")
        }
        return RemoteWorkspaceSummary(id: id, title: (try? object.optionalString("title")) ?? "Workspace",
            panels: ((try? object.requiredArray("panels")) ?? []).compactMap {
                try? decode(RemoteWorkspacePanel.self, from: $0)
            })
    }

    private func decodeSummary(_ object: JSONObject) throws -> CompatibleConversationSummary {
        let providerValue = try object.requiredString("provider")
        guard let provider = AgentKind(rawValue: providerValue) else {
            throw GatewayCompatibilityError.invalidEnvelope("Invalid provider")
        }
        let placementObject = try object.requiredObject("placement")
        let placement = RemoteConversationPlacement(
            workspaceID: try placementObject.optionalUUID("workspaceID"),
            workspaceTitle: try placementObject.optionalString("workspaceTitle"),
            panelID: try placementObject.optionalUUID("panelID")
        )
        let inputAvailability = try decodeInputAvailability(try object.requiredObject("inputAvailability"))
        let pendingInteractionPreview: RemotePendingInteractionPreview?
        if case .pendingInteraction = inputAvailability,
           let previewObject = object.lossyObject("pendingInteractionPreview") {
            pendingInteractionPreview = try? decode(RemotePendingInteractionPreview.self, from: previewObject)
        } else {
            pendingInteractionPreview = nil
        }
        return CompatibleConversationSummary(
            conversationID: try decodeConversationID(object.requiredString("conversationID")),
            provider: provider,
            title: try object.requiredString("title"),
            placement: placement,
            cwd: try object.optionalString("cwd"),
            statusDetail: object.lossyString("statusDetail"),
            state: decodeDisplayState(try object.requiredString("state")),
            presentationStatus: decodePresentationStatus(
                try object.optionalString("presentationStatus")
            ),
            inputAvailability: inputAvailability,
            pendingInteractionPreview: pendingInteractionPreview,
            projectionGeneration: try object.requiredUInt64("projectionGeneration"),
            latestSequence: try object.requiredUInt64("latestSequence"),
            updatedAt: try object.requiredDate("updatedAt")
        )
    }

    private func decodeDisplayState(_ rawValue: String) -> MobileSessionDisplayState {
        RemoteSessionState(rawValue: rawValue).map(MobileSessionDisplayState.known)
            ?? .unsupported(rawValue: rawValue)
    }

    private func decodePresentationStatus(
        _ rawValue: String?
    ) -> CompatibleSessionPresentationStatus? {
        guard let rawValue else { return nil }
        return RemoteSessionPresentationStatus(rawValue: rawValue)
            .map(CompatibleSessionPresentationStatus.known)
            ?? .unsupported(rawValue: rawValue)
    }

    private func decodeInputAvailability(_ object: JSONObject) throws -> CompatibleInputAvailability {
        switch try object.requiredString("kind") {
        case "open_prompt":
            return .openPrompt(epoch: try decode(RemoteInputEpoch.self, from: object.requiredObject("epoch")))
        case "local_draft":
            return .localDraft(epoch: try decode(RemoteInputEpoch.self, from: object.requiredObject("epoch")))
        case "pending_interaction":
            let identifiers = try object.requiredStringArray("interactionIDs")
                .map(RemotePendingInteraction.ID.init(rawValue:))
            return .pendingInteraction(interactionIDs: identifiers)
        case "unavailable":
            let rawReason = try object.requiredString("reason")
            let reason = RemoteInputUnavailableReason(rawValue: rawReason)
                .map(CompatibleInputUnavailableReason.known)
                ?? .unsupported(rawValue: rawReason)
            return .unavailable(reason: reason)
        case let kind:
            return .unsupported(rawKind: kind)
        }
    }

    private func decodeEventPage(_ object: JSONObject) throws -> CompatibleConversationEventPage {
        let pageConversationID = try decodeConversationID(object.requiredString("conversationID"))
        let events = try object.requiredArray("events").map { eventObject in
            try decodeEvent(eventObject, pageConversationID: pageConversationID)
        }
        return CompatibleConversationEventPage(
            conversationID: pageConversationID,
            projectionRunID: try decodeProjectionRunID(object.requiredString("projectionRunID")),
            projectionGeneration: try object.requiredUInt64("projectionGeneration"),
            // Preserve wire order. Sorting here would conceal a malformed or
            // downgraded host response before the paging/runtime invariants
            // can reject it, potentially turning corruption into silent gaps.
            events: events,
            latestSequence: try object.requiredUInt64("latestSequence"),
            firstAvailableSequence: try object.optionalUInt64("firstAvailableSequence"),
            historyTruncated: try object.optionalBool("historyTruncated") ?? false
        )
    }

    private func decodeEvent(
        _ object: JSONObject,
        pageConversationID: RemoteConversationID
    ) throws -> CompatibleConversationEvent {
        let conversationID = try decodeConversationID(object.requiredString("conversationID"))
        guard conversationID == pageConversationID else {
            throw GatewayCompatibilityError.invalidEnvelope("Event conversation ID does not match page")
        }
        let sequence = try object.requiredUInt64("sequence")
        let kind = try object.requiredString("kind")
        guard ConversationEventKind(rawValue: kind) != nil else {
            return .unknown(conversationID: conversationID, sequence: sequence, kind: kind)
        }

        if kind == ConversationEventKind.statusChanged.rawValue {
            do {
                return .statusChanged(try decodeStatusChangedEvent(object))
            } catch {
                return .unknown(conversationID: conversationID, sequence: sequence, kind: kind)
            }
        }

        do {
            return .known(try decode(ConversationEvent.self, from: object))
        } catch {
            // Known envelope kinds may acquire a future nested discriminator.
            // Preserve ordering/cursor progress without rejecting the page.
            return .unknown(conversationID: conversationID, sequence: sequence, kind: kind)
        }
    }

    private func decodeStatusChangedEvent(_ object: JSONObject) throws -> CompatibleStatusChangedEvent {
        let providerValue = try object.requiredString("provider")
        guard let provider = AgentKind(rawValue: providerValue) else {
            throw GatewayCompatibilityError.invalidEnvelope("Invalid event provider")
        }
        let payload = try object.requiredObject("payload")
        return CompatibleStatusChangedEvent(
            conversationID: try decodeConversationID(object.requiredString("conversationID")),
            sequence: try object.requiredUInt64("sequence"),
            eventID: try object.requiredString("eventID"),
            schemaVersion: try object.requiredInt("schemaVersion"),
            timestamp: try object.requiredDate("timestamp"),
            provider: provider,
            providerIdentity: try object.optionalString("providerIdentity"),
            turnID: try object.optionalString("turnID"),
            state: decodeDisplayState(try payload.requiredString("state")),
            inputAvailability: try decodeInputAvailability(try payload.requiredObject("inputAvailability"))
        )
    }

    private func validateProtocolVersion(_ version: String) throws {
        guard version == RemoteGatewayProtocol.version else {
            throw GatewayCompatibilityError.unsupportedProtocolVersion(version)
        }
    }

    private func decodeConversationID(_ value: String) throws -> RemoteConversationID {
        guard let uuid = UUID(uuidString: value) else {
            throw GatewayCompatibilityError.invalidEnvelope("Invalid conversation ID")
        }
        return RemoteConversationID(rawValue: uuid)
    }

    private func decodeProjectionRunID(_ value: String) throws -> RemoteProjectionRunID {
        guard let uuid = UUID(uuidString: value) else {
            throw GatewayCompatibilityError.invalidEnvelope("Invalid projection run ID")
        }
        return RemoteProjectionRunID(rawValue: uuid)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from object: JSONObject) throws -> Value {
        do {
            return try Self.decoder.decode(type, from: object.data())
        } catch let error as GatewayCompatibilityError {
            throw error
        } catch {
            throw GatewayCompatibilityError.invalidEnvelope(String(describing: error))
        }
    }

    private static var decoder: JSONDecoder { ConversationEventCoding.makeDecoder() }
}

private struct JSONObject {
    private let storage: [String: Any]

    init(_ data: Data) throws {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw GatewayCompatibilityError.invalidJSON
            }
            storage = object
        } catch let error as GatewayCompatibilityError {
            throw error
        } catch {
            throw GatewayCompatibilityError.invalidJSON
        }
    }

    init(_ storage: [String: Any]) {
        self.storage = storage
    }

    func data() throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: storage, options: [.sortedKeys])
        } catch {
            throw GatewayCompatibilityError.invalidJSON
        }
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = storage[key] as? String else {
            throw GatewayCompatibilityError.invalidEnvelope("Missing string \(key)")
        }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = storage[key] else { return nil }
        guard !(value is NSNull), let string = value as? String else {
            if value is NSNull { return nil }
            throw GatewayCompatibilityError.invalidEnvelope("Invalid string \(key)")
        }
        return string
    }

    func requiredUInt64(_ key: String) throws -> UInt64 {
        let number = try requiredNumber(key)
        let rawValue = number.stringValue
        guard rawValue.isEmpty == false,
              rawValue.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains),
              let value = UInt64(rawValue) else {
            throw GatewayCompatibilityError.invalidEnvelope("Invalid integer \(key)")
        }
        return value
    }

    func requiredInt(_ key: String) throws -> Int {
        let number = try requiredNumber(key)
        guard let value = Int(number.stringValue) else {
            throw GatewayCompatibilityError.invalidEnvelope("Invalid integer \(key)")
        }
        return value
    }

    func optionalUInt64(_ key: String) throws -> UInt64? {
        guard let value = storage[key], !(value is NSNull) else { return nil }
        return try requiredUInt64(key)
    }

    func optionalBool(_ key: String) throws -> Bool? {
        guard let value = storage[key], !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw GatewayCompatibilityError.invalidEnvelope("Invalid bool \(key)")
        }
        return number.boolValue
    }

    func optionalUUID(_ key: String) throws -> UUID? {
        guard let value = try optionalString(key) else { return nil }
        guard let uuid = UUID(uuidString: value) else {
            throw GatewayCompatibilityError.invalidEnvelope("Invalid UUID \(key)")
        }
        return uuid
    }

    func requiredObject(_ key: String) throws -> JSONObject {
        guard let object = storage[key] as? [String: Any] else {
            throw GatewayCompatibilityError.invalidEnvelope("Missing object \(key)")
        }
        return JSONObject(object)
    }

    /// Optional additive fields must not make a known snapshot unusable when a
    /// future host changes their nested representation.
    func lossyObject(_ key: String) -> JSONObject? {
        guard let object = storage[key] as? [String: Any] else { return nil }
        return JSONObject(object)
    }

    /// Optional additive display copy should never make the authoritative
    /// session facts unusable when an older or future host omits it or changes
    /// its representation.
    func lossyString(_ key: String) -> String? {
        storage[key] as? String
    }

    func requiredArray(_ key: String) throws -> [JSONObject] {
        guard let array = storage[key] as? [[String: Any]] else {
            throw GatewayCompatibilityError.invalidEnvelope("Missing object array \(key)")
        }
        return array.map(JSONObject.init)
    }

    func requiredStringArray(_ key: String) throws -> [String] {
        guard let array = storage[key] as? [String] else {
            throw GatewayCompatibilityError.invalidEnvelope("Missing string array \(key)")
        }
        return array
    }

    func requiredDate(_ key: String) throws -> Date {
        let value = try requiredString(key)
        let data = try JSONEncoder().encode(value)
        if let date = try? ConversationEventCoding.makeDecoder().decode(Date.self, from: data) { return date }
        throw GatewayCompatibilityError.invalidEnvelope("Invalid date \(key)")
    }

    private func requiredNumber(_ key: String) throws -> NSNumber {
        guard let number = storage[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw GatewayCompatibilityError.invalidEnvelope("Missing integer \(key)")
        }
        return number
    }
}
