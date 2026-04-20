import CoreState

enum AutomationSocketError: Error {
    case invalidJSON
    case invalidEnvelope(String)
    case incompatibleProtocol
    case unknownEventType
    case unknownCommand
    case invalidPayload(String)
    case internalError(String)

    var response: AutomationResponseEnvelope {
        AutomationResponseEnvelope(
            requestID: "unknown",
            ok: false,
            result: nil,
            error: errorBody
        )
    }

    var errorBody: AutomationResponseError {
        switch self {
        case .invalidJSON:
            return AutomationResponseError(code: "INVALID_JSON", message: "request body must be valid JSON")
        case .invalidEnvelope(let message):
            return AutomationResponseError(code: "INVALID_ENVELOPE", message: message)
        case .incompatibleProtocol:
            return AutomationResponseError(code: "INCOMPATIBLE_PROTOCOL", message: "unsupported protocolVersion")
        case .unknownEventType:
            return AutomationResponseError(code: "UNKNOWN_EVENT_TYPE", message: "eventType is not supported")
        case .unknownCommand:
            return AutomationResponseError(code: "UNKNOWN_COMMAND", message: "command is not supported")
        case .invalidPayload(let message):
            return AutomationResponseError(code: "INVALID_PAYLOAD", message: message)
        case .internalError(let message):
            return AutomationResponseError(code: "INTERNAL_ERROR", message: message)
        }
    }
}
