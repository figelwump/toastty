import Foundation

/// A static resource the gateway can serve (the minimal phone web client).
public struct RemoteGatewayStaticResource: Equatable, Sendable {
    public var contentType: String
    public var data: Data

    public init(contentType: String, data: Data) {
        self.contentType = contentType
        self.data = data
    }
}

public struct RemoteGatewayConfiguration: Sendable {
    /// Exact-match Origin allowlist. WebSocket upgrades and state-changing
    /// requests always carry an Origin header in browsers; requests presenting
    /// a non-allowlisted Origin are rejected outright.
    public var allowedOrigins: Set<String>
    /// Absolute path → resource for the same-origin web client.
    public var staticResources: [String: RemoteGatewayStaticResource]

    public init(
        allowedOrigins: Set<String>,
        staticResources: [String: RemoteGatewayStaticResource] = [:]
    ) {
        self.allowedOrigins = allowedOrigins
        self.staticResources = staticResources
    }
}

/// Routes parsed gateway requests to pairing, session, and subscription
/// behavior. Pure application logic: the network listener owns bytes and
/// connection lifecycle, this type owns every authentication, origin, and
/// rate-limit decision so they are all unit-testable.
public final class RemoteGatewayRequestHandler {
    public enum Outcome: Equatable {
        case respond(RemoteGatewayHTTPResponse)
        /// Write `upgradeResponseData` and keep the connection open as a
        /// WebSocket subscribed to session-list updates for `device`.
        case upgradeToWebSocket(deviceID: UUID, upgradeResponseData: Data)
    }

    private let deviceStore: RemoteDeviceStore
    private let auditLog: RemoteAccessAuditLog
    private let facade: any RemoteSessionFacade
    private var configuration: RemoteGatewayConfiguration
    private var pairingRateLimiter: RemoteAccessRateLimiter
    private var authRateLimiter: RemoteAccessRateLimiter
    private let encoder = ConversationEventCoding.makeEncoder()

    public init(
        deviceStore: RemoteDeviceStore,
        auditLog: RemoteAccessAuditLog,
        facade: any RemoteSessionFacade,
        configuration: RemoteGatewayConfiguration,
        pairingRateLimiter: RemoteAccessRateLimiter = RemoteAccessRateLimiter(),
        authRateLimiter: RemoteAccessRateLimiter = RemoteAccessRateLimiter(maximumFailures: 20, windowDuration: 60, lockoutDuration: 300)
    ) {
        self.deviceStore = deviceStore
        self.auditLog = auditLog
        self.facade = facade
        self.configuration = configuration
        self.pairingRateLimiter = pairingRateLimiter
        self.authRateLimiter = authRateLimiter
    }

    public func updateConfiguration(_ configuration: RemoteGatewayConfiguration) {
        self.configuration = configuration
    }

    public func handle(_ request: RemoteGatewayHTTPRequest, at date: Date) -> Outcome {
        // A present-but-unlisted Origin is always hostile, on every route.
        if let origin = request.header("origin"),
           configuration.allowedOrigins.contains(origin) == false {
            return .respond(errorResponse(status: 403, reason: "Forbidden", code: "origin_denied", message: "Origin not allowed"))
        }

        switch (request.method, request.path) {
        case ("GET", "/api/sessions"):
            return handleSessionList(request, at: date)
        case ("GET", "/api/subscribe"):
            return handleSubscribe(request, at: date)
        case ("POST", "/api/pair"):
            return handlePair(request, at: date)
        case ("POST", "/api/conversation.events.get"):
            return handleConversationEvents(request, at: date)
        case ("GET", let path):
            return handleStatic(path: path)
        default:
            return .respond(errorResponse(status: 404, reason: "Not Found", code: "not_found", message: "Unknown route"))
        }
    }

    // MARK: - Routes

    private func handlePair(_ request: RemoteGatewayHTTPRequest, at date: Date) -> Outcome {
        // Browsers always attach Origin to POSTs; its absence means a
        // non-browser client that must not be pairing this way.
        guard let origin = request.header("origin"),
              configuration.allowedOrigins.contains(origin) else {
            return .respond(errorResponse(status: 403, reason: "Forbidden", code: "origin_required", message: "Origin required"))
        }
        if pairingRateLimiter.isLockedOut(at: date) {
            return .respond(errorResponse(status: 429, reason: "Too Many Requests", code: "rate_limited", message: "Pairing temporarily locked"))
        }
        guard let pairRequest = try? JSONDecoder().decode(RemoteGatewayPairRequest.self, from: request.body) else {
            return .respond(errorResponse(status: 400, reason: "Bad Request", code: "invalid_body", message: "Expected pairing JSON"))
        }

        switch deviceStore.redeemPairingCode(pairRequest.code, deviceName: pairRequest.deviceName, at: date) {
        case .invalidCode:
            let locked = pairingRateLimiter.recordFailure(at: date)
            auditLog.record(RemoteAccessAuditEntry(at: date, action: .pairingFailed))
            if locked {
                auditLog.record(RemoteAccessAuditEntry(at: date, action: .rateLimitLockout, detail: "pairing"))
            }
            return .respond(errorResponse(status: 403, reason: "Forbidden", code: "invalid_code", message: "Invalid or expired pairing code"))

        case .paired(let device, let credentialToken):
            auditLog.record(RemoteAccessAuditEntry(at: date, action: .devicePaired, deviceID: device.id, detail: device.name))
            let responseBody = (try? encoder.encode(RemoteGatewayPairResponse(device: RemoteGatewayDeviceSummary(device: device)))) ?? Data()
            // `Secure` only when the client actually reached us over HTTPS
            // (Tailscale Serve terminates TLS and forwards the proto); Safari
            // refuses Secure cookies set over plain loopback HTTP, which would
            // break local validation.
            let isHTTPS = request.header("x-forwarded-proto")?.lowercased() == "https"
            var cookie = "\(RemoteGatewayProtocol.credentialCookieName)=\(credentialToken); Path=/; HttpOnly; SameSite=Strict; Max-Age=31536000"
            if isHTTPS {
                cookie += "; Secure"
            }
            return .respond(.json(body: responseBody, extraHeaders: [("Set-Cookie", cookie)]))
        }
    }

    private func handleSessionList(_ request: RemoteGatewayHTTPRequest, at date: Date) -> Outcome {
        switch authenticate(request, at: date) {
        case .failure(let response):
            return .respond(response)
        case .success:
            let snapshot = facade.sessionList(at: date)
            let body = (try? encoder.encode(RemoteGatewaySessionListResponse(snapshot: snapshot))) ?? Data()
            return .respond(.json(body: body))
        }
    }

    private func handleConversationEvents(_ request: RemoteGatewayHTTPRequest, at date: Date) -> Outcome {
        // Browsers attach Origin to POSTs; require and verify it like pairing.
        guard let origin = request.header("origin"),
              configuration.allowedOrigins.contains(origin) else {
            return .respond(errorResponse(status: 403, reason: "Forbidden", code: "origin_required", message: "Origin required"))
        }
        switch authenticate(request, at: date) {
        case .failure(let response):
            return .respond(response)
        case .success:
            break
        }
        guard let eventsRequest = try? ConversationEventCoding.makeDecoder().decode(RemoteGatewayEventsRequest.self, from: request.body) else {
            return .respond(errorResponse(status: 400, reason: "Bad Request", code: "invalid_body", message: "Expected events request JSON"))
        }

        let outcome = facade.conversationEvents(
            for: eventsRequest.conversationID,
            after: eventsRequest.cursor,
            limit: eventsRequest.limit ?? 200
        )
        let response: RemoteGatewayEventsResponse
        switch outcome {
        case .page(let page):
            response = .page(page)
        case .resnapshotRequired:
            response = .resnapshotRequired
        case .conversationNotFound:
            response = .conversationNotFound
        }
        let body = (try? encoder.encode(response)) ?? Data()
        return .respond(.json(body: body))
    }

    private func handleSubscribe(_ request: RemoteGatewayHTTPRequest, at date: Date) -> Outcome {
        // WebSocket clients always send Origin; require and verify it.
        guard let origin = request.header("origin"),
              configuration.allowedOrigins.contains(origin) else {
            return .respond(errorResponse(status: 403, reason: "Forbidden", code: "origin_required", message: "Origin required"))
        }
        let device: RemoteDeviceRecord
        switch authenticate(request, at: date) {
        case .failure(let response):
            return .respond(response)
        case .success(let authenticated):
            device = authenticated
        }
        guard RemoteGatewayWebSocketHandshake.isUpgradeRequest(request),
              let clientKey = request.header("sec-websocket-key") else {
            return .respond(errorResponse(status: 400, reason: "Bad Request", code: "upgrade_required", message: "WebSocket upgrade required"))
        }
        auditLog.record(RemoteAccessAuditEntry(at: date, action: .sessionSubscribed, deviceID: device.id))
        return .upgradeToWebSocket(
            deviceID: device.id,
            upgradeResponseData: RemoteGatewayWebSocketHandshake.upgradeResponseData(forClientKey: clientKey)
        )
    }

    private func handleStatic(path: String) -> Outcome {
        let resolvedPath = path == "/" ? "/index.html" : path
        guard let resource = configuration.staticResources[resolvedPath] else {
            return .respond(errorResponse(status: 404, reason: "Not Found", code: "not_found", message: "Unknown route"))
        }
        return .respond(RemoteGatewayHTTPResponse(
            status: 200,
            reason: "OK",
            headers: [("Content-Type", resource.contentType)],
            body: resource.data
        ))
    }

    // MARK: - Authentication

    private enum AuthResult {
        case success(RemoteDeviceRecord)
        case failure(RemoteGatewayHTTPResponse)
    }

    private func authenticate(_ request: RemoteGatewayHTTPRequest, at date: Date) -> AuthResult {
        if authRateLimiter.isLockedOut(at: date) {
            return .failure(errorResponse(status: 429, reason: "Too Many Requests", code: "rate_limited", message: "Too many failed attempts"))
        }
        guard let token = request.cookies[RemoteGatewayProtocol.credentialCookieName],
              let device = deviceStore.authenticate(credentialToken: token, at: date) else {
            let locked = authRateLimiter.recordFailure(at: date)
            auditLog.record(RemoteAccessAuditEntry(at: date, action: .authenticationFailed))
            if locked {
                auditLog.record(RemoteAccessAuditEntry(at: date, action: .rateLimitLockout, detail: "auth"))
            }
            return .failure(errorResponse(status: 401, reason: "Unauthorized", code: "unauthorized", message: "Pair this device first"))
        }
        return .success(device)
    }

    private func errorResponse(status: Int, reason: String, code: String, message: String) -> RemoteGatewayHTTPResponse {
        let body = (try? encoder.encode(RemoteGatewayErrorResponse(code: code, message: message))) ?? Data()
        return .json(status: status, reason: reason, body: body)
    }
}
