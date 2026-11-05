import CryptoKit
import Foundation

/// An address outside Toastty that receives task events: an HTTPS URL that
/// wakes a coordinator, such as a bot that follows tasks.
///
/// A webhook added from the CLI waits for the user's approval in the app
/// and receives nothing until then. The approval covers the address, the
/// events, the filters and the auth mode; see `settingsDigest`. The secret
/// lives in the Keychain, never in this record.
public struct TaskWebhook: Codable, Equatable, Identifiable, Sendable {
    public static let maximumPending = 5

    public let id: UUID
    public var name: String
    public var url: String
    public var events: [TaskWebhookEventType]
    /// Project roots, normalized. Empty means every root.
    public var roots: [String]
    /// Only tasks whose `externalRef.id` starts with this.
    public var externalRefPrefix: String?
    public var auth: TaskWebhookAuth
    public var status: TaskWebhookStatus
    /// Why Toastty stopped sending, such as "HTTP 401".
    public var disabledReason: String?
    public var requestedAt: Date
    public var requestedBy: TaskWebhookRequester
    public var approvedAt: Date?
    public var lastDelivery: TaskWebhookDelivery?

    public init(
        id: UUID = UUID(),
        name: String,
        url: String,
        events: [TaskWebhookEventType] = TaskWebhookEventType.defaults,
        roots: [String] = [],
        externalRefPrefix: String? = nil,
        auth: TaskWebhookAuth,
        status: TaskWebhookStatus = .pendingApproval,
        disabledReason: String? = nil,
        requestedAt: Date,
        requestedBy: TaskWebhookRequester,
        approvedAt: Date? = nil,
        lastDelivery: TaskWebhookDelivery? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.events = events
        self.roots = roots
        self.externalRefPrefix = externalRefPrefix
        self.auth = auth
        self.status = status
        self.disabledReason = disabledReason
        self.requestedAt = requestedAt
        self.requestedBy = requestedBy
        self.approvedAt = approvedAt
        self.lastDelivery = lastDelivery
    }

    /// A SHA-256 of what the user approves: where events go, which events,
    /// for which tasks, and how the request proves where it came from. The
    /// secret is left out, so a new secret keeps the approval.
    public var settingsDigest: String {
        // JSON keeps every field's boundaries, whatever characters it holds.
        struct Approved: Encodable {
            var version = 1
            var url: String
            var events: [String]
            var roots: [String]
            var externalRefPrefix: String?
            var auth: String
        }
        let approved = Approved(
            url: url,
            events: events.map(\.rawValue).sorted(),
            roots: roots.sorted(),
            externalRefPrefix: externalRefPrefix,
            auth: auth.description
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(approved)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether events for a task with this root and external reference go
    /// to this webhook.
    public func matches(projectRoot: String?, externalRefID: String?) -> Bool {
        if roots.isEmpty == false {
            guard let projectRoot, roots.contains(where: { Self.path(projectRoot, isInside: $0) }) else { return false }
        }
        if let externalRefPrefix {
            guard let externalRefID, externalRefID.hasPrefix(externalRefPrefix) else { return false }
        }
        return true
    }

    private static func path(_ path: String, isInside root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// The URL with its path hidden, for display: paths often hold a
    /// token. The host stays whole.
    public var displayURL: String {
        TaskWebhookValidation.displayURL(url)
    }

    public var host: String {
        URLComponents(string: url)?.host ?? url
    }
}

public enum TaskWebhookStatus: String, Codable, Equatable, Sendable {
    case pendingApproval
    case approved
    /// Toastty stopped sending after the receiver refused the request
    /// (HTTP 401, 403 or 410). A new secret resumes it.
    case disabled
}

/// Who asked for the webhook, as the approval sheet shows it.
public struct TaskWebhookRequester: Codable, Equatable, Sendable {
    /// An agent session in a Toastty task space asked, so the sheet warns.
    public var agentTaskTitle: String?
    public var agentSessionID: String?

    public init(agentTaskTitle: String? = nil, agentSessionID: String? = nil) {
        self.agentTaskTitle = agentTaskTitle
        self.agentSessionID = agentSessionID
    }

    public var isAgentSession: Bool { agentSessionID != nil }
}

public struct TaskWebhookDelivery: Codable, Equatable, Sendable {
    public var at: Date
    /// The HTTP status, or `nil` when no response came.
    public var statusCode: Int?
    /// A class of failure without the URL, such as "timeout".
    public var error: String?

    public init(at: Date, statusCode: Int? = nil, error: String? = nil) {
        self.at = at
        self.statusCode = statusCode
        self.error = error
    }

    public var summary: String {
        if let statusCode { return "HTTP \(statusCode)" }
        return error ?? "no response"
    }
}

public enum TaskWebhookEventType: String, Codable, CaseIterable, Equatable, Sendable {
    case needsYou = "needs_you"
    case merged
    case done
    case archived
    case deleted
    case running
    case idle

    public static let defaults: [TaskWebhookEventType] = [.needsYou, .merged, .done, .archived, .deleted]

    /// The `type` field of the payload.
    public var payloadType: String { "task.\(rawValue)" }

    /// Events that say where a task's stage is now. A newer one for the same
    /// task replaces one still waiting to send; milestones such as merged
    /// are kept.
    public var isTransient: Bool {
        switch self {
        case .needsYou, .running, .idle: true
        case .merged, .done, .archived, .deleted: false
        }
    }

    public var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .merged: "Merged"
        case .done: "Done"
        case .archived: "Archived"
        case .deleted: "Deleted"
        case .running: "Running"
        case .idle: "Idle"
        }
    }
}

/// How a request proves where it came from. Every mode uses the webhook's
/// one secret.
public enum TaskWebhookAuth: Equatable, Sendable, CustomStringConvertible, Codable {
    /// `Authorization: Bearer <secret>`.
    case bearer
    /// `<name>: <secret>`.
    case header(name: String)
    /// `Toastty-Signature: t=<unix>,v1=<hex HMAC-SHA256(secret, "<t>.<body>")>`.
    case hmac
    /// No secret: loopback addresses only, for local tests.
    case none

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch trimmed.lowercased() {
        case "bearer": self = .bearer
        case "hmac": self = .hmac
        case "none": self = .none
        default:
            guard trimmed.lowercased().hasPrefix("header:") else { return nil }
            let name = String(trimmed.dropFirst("header:".count))
            guard name.isEmpty == false else { return nil }
            self = .header(name: name)
        }
    }

    public var description: String {
        switch self {
        case .bearer: "bearer"
        case .header(let name): "header:\(name)"
        case .hmac: "hmac"
        case .none: "none"
        }
    }

    public var needsSecret: Bool { self != .none }

    /// For the approval sheet and `webhook list`.
    public var title: String {
        switch self {
        case .bearer: "Bearer token"
        case .header(let name): "\(name) header"
        case .hmac: "HMAC signature"
        case .none: "None (local test address)"
        }
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let auth = TaskWebhookAuth(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown auth \(text)"))
        }
        self = auth
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct TaskWebhookValidationError: Error, Equatable, Sendable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum TaskWebhookValidation {
    public static let minimumSecretLength = 16
    public static let maximumSecretLength = 4096

    /// Headers a webhook may not set with `header:<name>`: transport headers,
    /// `Authorization` (use bearer), and Toastty's own.
    private static let reservedHeaders: Set<String> = [
        "host", "content-length", "content-type", "content-encoding", "transfer-encoding",
        "connection", "authorization", "user-agent", "accept", "te", "upgrade", "trailer",
    ]

    public static func validateName(_ name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        guard (1...40).contains(name.count),
              name.unicodeScalars.allSatisfy(allowed.contains),
              name.first?.isLetter == true || name.first?.isNumber == true else {
            throw TaskWebhookValidationError("A webhook name is 1 to 40 lowercase letters, digits, - and _, starting with a letter or digit.")
        }
    }

    /// Checks the address and returns it in a normal form. Only HTTPS goes
    /// off the Mac; plain HTTP is for 127.0.0.1 and localhost, for tests.
    public static func validateURL(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), host.isEmpty == false else {
            throw TaskWebhookValidationError("The webhook URL must be an absolute https:// URL.")
        }
        guard components.user == nil, components.password == nil else {
            throw TaskWebhookValidationError("Put credentials in the secret, not in the URL.")
        }
        guard components.fragment == nil else {
            throw TaskWebhookValidationError("The webhook URL cannot have a #fragment.")
        }
        switch scheme {
        case "https":
            break
        case "http":
            guard isLoopback(host: host) else {
                throw TaskWebhookValidationError("The webhook URL must use https://. Plain http:// is only for 127.0.0.1 and localhost.")
            }
        default:
            throw TaskWebhookValidationError("The webhook URL must use https://.")
        }
        return trimmed
    }

    public static func isLoopback(host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
    }

    public static func isLoopback(url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host else { return false }
        return isLoopback(host: host)
    }

    public static func validateAuth(_ auth: TaskWebhookAuth, url: String) throws {
        switch auth {
        case .none:
            guard isLoopback(url: url) else {
                throw TaskWebhookValidationError("--auth none is only for 127.0.0.1 and localhost; use bearer, header:<name> or hmac.")
            }
        case .header(let name):
            // An HTTP token (RFC 9110).
            let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
            guard name.count <= 64, name.unicodeScalars.allSatisfy(token.contains) else {
                throw TaskWebhookValidationError("\(name) is not a valid HTTP header name.")
            }
            let lowered = name.lowercased()
            guard reservedHeaders.contains(lowered) == false, lowered.hasPrefix("toastty-") == false else {
                throw TaskWebhookValidationError("A webhook cannot set the \(name) header.")
            }
        case .bearer, .hmac:
            break
        }
    }

    public static func validateSecret(_ secret: String) throws {
        guard (minimumSecretLength...maximumSecretLength).contains(secret.utf8.count) else {
            throw TaskWebhookValidationError("The secret must be \(minimumSecretLength) to \(maximumSecretLength) bytes.")
        }
        guard secret.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
            throw TaskWebhookValidationError("The secret must be printable ASCII without spaces, so it fits in a header.")
        }
    }

    /// `https://host/…`: the host whole, the path and query hidden, since
    /// either can hold a token.
    public static func displayURL(_ url: String) -> String {
        guard let components = URLComponents(string: url), let scheme = components.scheme, let host = components.host else {
            return "(invalid URL)"
        }
        let port = components.port.map { ":\($0)" } ?? ""
        let hidden = components.path.split(separator: "/").isEmpty == false || components.query != nil
        return "\(scheme)://\(host)\(port)" + (hidden ? "/…" : "")
    }
}
