import CoreState
import Foundation

enum AutomationSocketError: Error {
    case invalidJSON
    case invalidEnvelope(String)
    case incompatibleProtocol
    case unknownEventType
    case unknownCommand
    case invalidPayload(String)
    case annotationColorLocked(key: String, currentColor: String)
    case annotationUsageUnavailable
    case scopeDenied(workspaceID: UUID)
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
        case .annotationColorLocked(let key, let currentColor):
            return AutomationResponseError(
                code: "ANNOTATION_COLOR_LOCKED",
                message: "annotation key '\(key)' is locked to color '\(currentColor)' while at least one annotation with that key exists"
            )
        case .annotationUsageUnavailable:
            return AutomationResponseError(
                code: "ANNOTATION_USAGE_UNAVAILABLE",
                message: "could not verify annotation usage in saved layout profiles; no annotation or color was changed"
            )
        case .scopeDenied:
            return AutomationResponseError(
                code: "scope_denied",
                message: "This workspace is outside your assigned scope. If the user explicitly assigned it, run toastty session scope add; otherwise stop and report."
            )
        case .internalError(let message):
            return AutomationResponseError(code: "INTERNAL_ERROR", message: message)
        }
    }
}
