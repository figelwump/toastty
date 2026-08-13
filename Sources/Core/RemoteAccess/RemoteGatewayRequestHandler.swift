import RemoteProtocol
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
    /// Exact-match Origin allowlist. A presented, non-allowlisted Origin is
    /// rejected on every route.
    public var allowedOrigins: Set<String>
    /// Absolute path -> resource for the same-origin web client.
    public var staticResources: [String: RemoteGatewayStaticResource]

    public init(
        allowedOrigins: Set<String>,
        staticResources: [String: RemoteGatewayStaticResource] = [:]
    ) {
        self.allowedOrigins = allowedOrigins
        self.staticResources = staticResources
    }
}

/// Pure route, authentication, identity, and scope policy for the loopback
/// gateway. The listener owns bytes and connection lifetime; this type owns
/// all decisions that can authorize access to host data or terminal input.
public final class RemoteGatewayRequestHandler {
    public enum Outcome: Equatable {
        case respond(RemoteGatewayHTTPResponse)
        case upgradeToWebSocket(deviceID: UUID, upgradeResponseData: Data)
    }

    public typealias SendHandler = (RemoteMessageSendRequest, RemoteDeviceRecord) -> RemoteMessageSendResult
    public typealias ReadAcknowledgementHandler = (
        RemoteConversationReadAcknowledgementRequest,
        RemoteDeviceRecord
    ) -> RemoteConversationReadAcknowledgementResult

    private enum AuthResult {
        case success(RemoteDeviceRecord)
        case failure(RemoteGatewayHTTPResponse)
    }

    private static let maximumAuthorizationBytes = 256
    private static let maximumCredentialBytes = 128
    private static let maximumIdentityBytes = 320
    private static let maximumNativeExchangeBodyBytes = 2 * 1024
    private static let maximumNativeRevokeBodyBytes = 256
    private static let maximumReadAcknowledgementBodyBytes = 1024

    private let deviceStore: RemoteDeviceStore
    private let auditLog: RemoteAccessAuditLog
    private let facade: any RemoteSessionFacade
    private let sendHandler: SendHandler?
    private let readAcknowledgementHandler: ReadAcknowledgementHandler?
    private let nativeIdentityForTesting: String?
    private var configuration: RemoteGatewayConfiguration
    private var pairingRateLimiter: RemoteAccessRateLimiter
    private var authRateLimiter: RemoteAccessRateLimiter
    private let encoder = ConversationEventCoding.makeEncoder()

    /// Called only after a pairing mutation has durably completed.
    public var onDevicePaired: ((RemoteDeviceRecord) -> Void)?
    /// Called only after self-revocation has durably completed. The server uses
    /// this side effect to close any stream belonging to the revoked device.
    public var onDeviceRevoked: ((UUID) -> Void)?

    public convenience init(
        deviceStore: RemoteDeviceStore,
        auditLog: RemoteAccessAuditLog,
        facade: any RemoteSessionFacade,
        configuration: RemoteGatewayConfiguration,
        sendHandler: SendHandler? = nil,
        readAcknowledgementHandler: ReadAcknowledgementHandler? = nil,
        pairingRateLimiter: RemoteAccessRateLimiter = RemoteAccessRateLimiter(),
        authRateLimiter: RemoteAccessRateLimiter = RemoteAccessRateLimiter(maximumFailures: 20, windowDuration: 60, lockoutDuration: 300)
    ) {
        self.init(
            deviceStore: deviceStore,
            auditLog: auditLog,
            facade: facade,
            configuration: configuration,
            sendHandler: sendHandler,
            readAcknowledgementHandler: readAcknowledgementHandler,
            // The public production entry point can never inject identity.
            nativeIdentityForTesting: nil,
            pairingRateLimiter: pairingRateLimiter,
            authRateLimiter: authRateLimiter
        )
    }

    /// The identity exception is internal and intentionally absent from the
    /// production initializer/configuration. It applies only when the trusted
    /// Serve header is absent, never when a value was presented and rejected.
    init(
        deviceStore: RemoteDeviceStore,
        auditLog: RemoteAccessAuditLog,
        facade: any RemoteSessionFacade,
        configuration: RemoteGatewayConfiguration,
        sendHandler: SendHandler? = nil,
        readAcknowledgementHandler: ReadAcknowledgementHandler? = nil,
        nativeIdentityForTesting: String?,
        pairingRateLimiter: RemoteAccessRateLimiter = RemoteAccessRateLimiter(),
        authRateLimiter: RemoteAccessRateLimiter = RemoteAccessRateLimiter(maximumFailures: 20, windowDuration: 60, lockoutDuration: 300)
    ) {
        self.deviceStore = deviceStore
        self.auditLog = auditLog
        self.facade = facade
        self.configuration = configuration
        self.sendHandler = sendHandler
        self.readAcknowledgementHandler = readAcknowledgementHandler
        self.nativeIdentityForTesting = nativeIdentityForTesting
        self.pairingRateLimiter = pairingRateLimiter
        self.authRateLimiter = authRateLimiter
    }

    public func updateConfiguration(_ configuration: RemoteGatewayConfiguration) {
        self.configuration = configuration
    }

    public func handle(_ request: RemoteGatewayHTTPRequest, at date: Date) -> Outcome {
        if let policy = RemoteGatewayRoutePolicy.policy(for: request.path) {
            return handle(request, policy: policy, at: date)
        }

        let staticPath = request.path == "/" ? "/index.html" : request.path
        if configuration.staticResources[staticPath] != nil {
            guard request.method == "GET" else { return .respond(methodNotAllowed("GET")) }
            if let rejection = optionalOriginRejection(request) { return .respond(rejection) }
            return handleStatic(path: staticPath)
        }

        // Preserve the global hostile-Origin rule even for unknown paths.
        if let rejection = optionalOriginRejection(request) { return .respond(rejection) }
        return .respond(errorResponse(status: 404, reason: "Not Found", code: "not_found", message: "Unknown route"))
    }

    private func handle(
        _ request: RemoteGatewayHTTPRequest,
        policy: RemoteGatewayRoutePolicy,
        at date: Date
    ) -> Outcome {
        // 1. Method. Known routes never fall through to another handler.
        guard request.method == policy.method else {
            return .respond(methodNotAllowed(policy.method))
        }

        // 2. Route-specific exchange shape. Pairing endpoints reject browser
        // or credential shapes before consulting identity or durable state.
        if policy.route == .browserPair, request.headerValues("authorization").isEmpty == false {
            return .respond(errorResponse(
                status: 403,
                reason: "Forbidden",
                code: "authorization_not_allowed",
                message: "Authorization is not accepted on browser pairing"
            ))
        }
        if policy.route == .nativePairingExchange, hasBrowserContext(request) {
            return .respond(errorResponse(
                status: 403,
                reason: "Forbidden",
                code: "browser_context_denied",
                message: "Browser context is not accepted for native pairing"
            ))
        }

        // 3. Origin/fetch policy, before any credential or identity lookup.
        switch policy.origin {
        case .optionalAllowed:
            if let rejection = optionalOriginRejection(request) { return .respond(rejection) }
        case .browserCredentialRequired:
            if let rejection = optionalOriginRejection(request) { return .respond(rejection) }
            // Authorization, when present, selects the native path even when
            // malformed. With none presented this is necessarily a browser
            // cookie attempt, so its Origin is required before authentication.
            if request.headerValues("authorization").isEmpty,
               let rejection = requiredOriginRejection(request) {
                return .respond(rejection)
            }
        case .requiredAllowed:
            if let rejection = requiredOriginRejection(request) { return .respond(rejection) }
        case .browserContextForbidden:
            break // Checked above as part of the exchange shape.
        }

        if policy.route == .nativePairingExchange {
            return handleNativePairingExchange(request, at: date)
        }
        if policy.route == .browserPair {
            return handleBrowserPair(request, at: date)
        }
        if policy.route == .hello {
            return handleHello()
        }

        // 4. Credential, then native identity. Authorization always wins; an
        // invalid Bearer value never falls back to a valid browser cookie.
        let authenticated: RemoteDeviceRecord
        switch authenticate(request, requirement: policy.authentication, at: date) {
        case .failure(let response):
            return .respond(response)
        case .success(let result):
            authenticated = result
        }

        // 5. Scope. Self-inspection and self-revocation intentionally remain
        // available to a valid native credential regardless of data scopes.
        switch policy.scope {
        case .none:
            break
        case .read:
            guard authenticated.scopes.contains(.read) else {
                return .respond(errorResponse(
                    status: 403,
                    reason: "Forbidden",
                    code: "read_scope_denied",
                    message: "Read access is not granted"
                ))
            }
        case .send:
            guard authenticated.scopes.contains(.send) else {
                auditLog.record(RemoteAccessAuditEntry(
                    at: date,
                    action: .remoteSendRejected,
                    deviceID: authenticated.id,
                    detail: "send_scope_denied"
                ))
                let body = (try? encoder.encode(RemoteMessageSendResult.rejected(reason: .sendScopeDenied))) ?? Data()
                return .respond(.json(status: 403, reason: "Forbidden", body: body))
            }
        }

        // 6. Handler/side effect.
        switch policy.route {
        case .sessions:
            return handleSessionList(at: date)
        case .conversationEvents:
            return handleConversationEvents(request)
        case .conversationReadAcknowledge:
            return handleConversationReadAcknowledgement(request, device: authenticated)
        case .messageSend:
            return handleMessageSend(request, device: authenticated, at: date)
        case .subscribe:
            return handleSubscribe(request, device: authenticated, at: date)
        case .nativeDevice:
            return handleNativeDevice(authenticated)
        case .nativeDeviceRevoke:
            return handleNativeDeviceRevoke(request, device: authenticated, at: date)
        case .hello, .browserPair, .nativePairingExchange:
            assertionFailure("Unauthenticated route reached authenticated dispatch")
            return .respond(errorResponse(status: 500, reason: "Internal Server Error", code: "internal_error", message: "Internal error"))
        }
    }

    // MARK: - Pairing routes

    private func handleHello() -> Outcome {
        let body = (try? encoder.encode(RemoteGatewayHelloResponse())) ?? Data()
        return .respond(.json(body: body))
    }

    private func handleBrowserPair(_ request: RemoteGatewayHTTPRequest, at date: Date) -> Outcome {
        if pairingRateLimiter.isLockedOut(at: date) {
            return .respond(errorResponse(status: 429, reason: "Too Many Requests", code: "rate_limited", message: "Pairing temporarily locked"))
        }
        guard let pairRequest = try? JSONDecoder().decode(RemoteGatewayPairRequest.self, from: request.body) else {
            return .respond(errorResponse(status: 400, reason: "Bad Request", code: "invalid_body", message: "Expected pairing JSON"))
        }

        let pairingOutcome: RemoteDeviceStore.PairingOutcome
        do {
            pairingOutcome = try deviceStore.redeemPairingCode(pairRequest.code, deviceName: pairRequest.deviceName, at: date)
        } catch {
            return .respond(persistenceFailure("Could not save the paired device", error: error))
        }

        switch pairingOutcome {
        case .invalidCode:
            recordPairingFailure(at: date, detail: "browser")
            return .respond(errorResponse(status: 403, reason: "Forbidden", code: "invalid_code", message: "Invalid or expired pairing code"))
        case .deviceLimitReached:
            return .respond(errorResponse(status: 409, reason: "Conflict", code: "device_limit_reached", message: "Remote device limit reached"))
        case .paired(let device, let credentialToken):
            auditLog.record(RemoteAccessAuditEntry(at: date, action: .devicePaired, deviceID: device.id))
            onDevicePaired?(device)
            let responseBody = (try? encoder.encode(RemoteGatewayPairResponse(device: RemoteGatewayDeviceSummary(device: device)))) ?? Data()
            let isHTTPS = request.header("x-forwarded-proto")?.lowercased() == "https"
            var cookie = "\(RemoteGatewayProtocol.credentialCookieName)=\(credentialToken); Path=/; HttpOnly; SameSite=Strict; Max-Age=31536000"
            if isHTTPS { cookie += "; Secure" }
            return .respond(.json(body: responseBody, extraHeaders: [("Set-Cookie", cookie)]))
        }
    }

    private func handleNativePairingExchange(_ request: RemoteGatewayHTTPRequest, at date: Date) -> Outcome {
        guard request.body.count <= Self.maximumNativeExchangeBodyBytes else {
            return .respond(errorResponse(status: 400, reason: "Bad Request", code: "invalid_body", message: "Expected native pairing JSON"))
        }
        guard let exchange = try? ConversationEventCoding.makeDecoder().decode(
            RemoteGatewayNativePairingExchangeRequest.self,
            from: request.body
        ) else {
            return .respond(errorResponse(status: 400, reason: "Bad Request", code: "invalid_body", message: "Expected native pairing JSON"))
        }
        guard exchange.protocolVersion == RemoteGatewayProtocol.version else {
            return .respond(errorResponse(status: 409, reason: "Conflict", code: "protocol_mismatch", message: "Unsupported protocol version"))
        }

        let proof: RemoteNativePairingProof
        switch (exchange.offerID, exchange.secret, exchange.fallbackCode) {
        case (.some(let offerID), .some(let secret), .none):
            proof = .qr(offerID: offerID, secret: secret)
        case (.none, .none, .some(let fallbackCode)):
            proof = .fallbackCode(fallbackCode)
        default:
            return .respond(errorResponse(status: 400, reason: "Bad Request", code: "invalid_body", message: "Expected exactly one pairing proof"))
        }

        guard let tailscaleLogin = verifiedNativeIdentity(request) else {
            return .respond(identityUnavailableResponse())
        }

        let outcome: RemoteDeviceStore.NativePairingOutcome
        do {
            outcome = try deviceStore.redeemNativePairingOffer(
                using: proof,
                deviceName: exchange.deviceName,
                tailscaleLogin: tailscaleLogin,
                at: date
            )
        } catch {
            return .respond(persistenceFailure("Could not save the paired device", error: error))
        }

        switch outcome {
        case .paired(let device, let credentialToken):
            auditLog.record(RemoteAccessAuditEntry(at: date, action: .devicePaired, deviceID: device.id))
            onDevicePaired?(device)
            let body = (try? encoder.encode(RemoteGatewayNativePairingExchangeResponse(
                device: RemoteGatewayDeviceSummary(device: device),
                credentialCreatedAt: device.createdAt,
                credential: credentialToken
            ))) ?? Data()
            return .respond(.json(body: body))
        case .invalidOffer:
            auditLog.record(RemoteAccessAuditEntry(at: date, action: .pairingFailed))
            return .respond(invalidNativePairingOfferResponse())
        case .lockedOut:
            auditLog.record(RemoteAccessAuditEntry(at: date, action: .pairingFailed))
            auditLog.record(RemoteAccessAuditEntry(at: date, action: .rateLimitLockout, detail: "native"))
            return .respond(errorResponse(status: 429, reason: "Too Many Requests", code: "pairing_locked", message: "Pairing temporarily locked"))
        case .invalidDeviceName:
            return .respond(errorResponse(status: 400, reason: "Bad Request", code: "invalid_body", message: "Invalid native pairing request"))
        case .deviceLimitReached:
            return .respond(errorResponse(status: 409, reason: "Conflict", code: "device_limit_reached", message: "Remote device limit reached"))
        }
    }

    // MARK: - Authenticated routes

    private func handleSessionList(at date: Date) -> Outcome {
        let snapshot = facade.sessionList(at: date)
        let body = (try? encoder.encode(RemoteGatewaySessionListResponse(snapshot: snapshot))) ?? Data()
        return .respond(.json(body: body))
    }

    private func handleConversationEvents(_ request: RemoteGatewayHTTPRequest) -> Outcome {
        guard let eventsRequest = try? ConversationEventCoding.makeDecoder().decode(RemoteGatewayEventsRequest.self, from: request.body) else {
            return .respond(errorResponse(status: 400, reason: "Bad Request", code: "invalid_body", message: "Expected events request JSON"))
        }
        let outcome: ConversationEventPageOutcome
        if let backward = eventsRequest.backward {
            guard eventsRequest.cursor == nil,
                  let limit = eventsRequest.limit,
                  (1...RemoteConversationProjectionStore.defaultPageLimit).contains(limit) else {
                return .respond(errorResponse(status: 400, reason: "Bad Request", code: "invalid_body", message: "Invalid events paging request"))
            }
            switch backward {
            case .latest:
                outcome = facade.conversationEvents(
                    for: eventsRequest.conversationID,
                    before: nil,
                    limit: limit
                )
            case .before(let cursor):
                outcome = facade.conversationEvents(
                    for: eventsRequest.conversationID,
                    before: cursor,
                    limit: limit
                )
            }
        } else {
            outcome = facade.conversationEvents(
                for: eventsRequest.conversationID,
                after: eventsRequest.cursor,
                limit: eventsRequest.limit ?? RemoteConversationProjectionStore.defaultPageLimit
            )
        }
        let response: RemoteGatewayEventsResponse
        switch outcome {
        case .page(let page): response = .page(page)
        case .resnapshotRequired: response = .resnapshotRequired
        case .conversationNotFound: response = .conversationNotFound
        case .invalidRequest:
            return .respond(errorResponse(status: 400, reason: "Bad Request", code: "invalid_body", message: "Invalid events paging request"))
        }
        let body = (try? encoder.encode(response)) ?? Data()
        return .respond(.json(body: body))
    }

    private func handleConversationReadAcknowledgement(
        _ request: RemoteGatewayHTTPRequest,
        device: RemoteDeviceRecord
    ) -> Outcome {
        guard request.body.count <= Self.maximumReadAcknowledgementBodyBytes,
              let acknowledgement = try? ConversationEventCoding.makeDecoder().decode(
                RemoteConversationReadAcknowledgementRequest.self,
                from: request.body
              ) else {
            return .respond(errorResponse(
                status: 400,
                reason: "Bad Request",
                code: "invalid_body",
                message: "Expected conversation read acknowledgement JSON"
            ))
        }
        guard acknowledgement.protocolVersion == RemoteGatewayProtocol.version else {
            return .respond(errorResponse(
                status: 409,
                reason: "Conflict",
                code: "protocol_mismatch",
                message: "Unsupported protocol version"
            ))
        }
        guard let readAcknowledgementHandler else {
            let body = (try? encoder.encode(RemoteConversationReadAcknowledgementResponse(
                result: .conversationNotFound
            ))) ?? Data()
            return .respond(.json(body: body))
        }
        let result = readAcknowledgementHandler(acknowledgement, device)
        let body = (try? encoder.encode(RemoteConversationReadAcknowledgementResponse(
            result: result
        ))) ?? Data()
        return .respond(.json(body: body))
    }

    private func handleMessageSend(
        _ request: RemoteGatewayHTTPRequest,
        device: RemoteDeviceRecord,
        at date: Date
    ) -> Outcome {
        guard let sendHandler else {
            return .respond(errorResponse(status: 404, reason: "Not Found", code: "not_found", message: "Remote send is not available"))
        }
        guard let sendRequest = try? ConversationEventCoding.makeDecoder().decode(RemoteMessageSendRequest.self, from: request.body) else {
            return .respond(errorResponse(status: 400, reason: "Bad Request", code: "invalid_body", message: "Expected send JSON"))
        }
        let result = sendHandler(sendRequest, device)
        switch result {
        case .accepted:
            auditLog.record(RemoteAccessAuditEntry(at: date, action: .remoteSendAccepted, deviceID: device.id))
        case .rejected(let reason):
            auditLog.record(RemoteAccessAuditEntry(at: date, action: .remoteSendRejected, deviceID: device.id, detail: reason.rawValue))
        case .uncertain:
            auditLog.record(RemoteAccessAuditEntry(at: date, action: .remoteSendUncertain, deviceID: device.id))
        case .duplicate:
            break
        }
        let body = (try? encoder.encode(result)) ?? Data()
        return .respond(.json(body: body))
    }

    private func handleSubscribe(
        _ request: RemoteGatewayHTTPRequest,
        device: RemoteDeviceRecord,
        at date: Date
    ) -> Outcome {
        let upgrades = request.headerValues("upgrade")
        let connections = request.headerValues("connection")
        let clientKeys = request.headerValues("sec-websocket-key")
        let versions = request.headerValues("sec-websocket-version")
        guard upgrades.count == 1,
              upgrades[0].lowercased() == "websocket",
              connections.count == 1,
              connections[0].split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "upgrade" }),
              clientKeys.count == 1,
              clientKeys[0].isEmpty == false,
              clientKeys[0].utf8.count <= 128,
              versions == ["13"] else {
            return .respond(errorResponse(status: 400, reason: "Bad Request", code: "upgrade_required", message: "WebSocket upgrade required"))
        }
        auditLog.record(RemoteAccessAuditEntry(at: date, action: .sessionSubscribed, deviceID: device.id))
        return .upgradeToWebSocket(
            deviceID: device.id,
            upgradeResponseData: RemoteGatewayWebSocketHandshake.upgradeResponseData(forClientKey: clientKeys[0])
        )
    }

    private func handleNativeDevice(_ device: RemoteDeviceRecord) -> Outcome {
        // Native v1 credentials are created atomically with the device record
        // and do not rotate, so device.createdAt is the credential issue date.
        let body = (try? encoder.encode(RemoteGatewayCurrentDeviceResponse(
            device: RemoteGatewayDeviceSummary(device: device),
            credentialCreatedAt: device.createdAt
        ))) ?? Data()
        return .respond(.json(body: body))
    }

    private func handleNativeDeviceRevoke(
        _ request: RemoteGatewayHTTPRequest,
        device: RemoteDeviceRecord,
        at date: Date
    ) -> Outcome {
        guard request.body.count <= Self.maximumNativeRevokeBodyBytes else {
            return .respond(errorResponse(status: 400, reason: "Bad Request", code: "invalid_body", message: "Expected revoke JSON"))
        }
        guard let revokeRequest = try? ConversationEventCoding.makeDecoder().decode(
            RemoteGatewayRevokeCurrentDeviceRequest.self,
            from: request.body
        ) else {
            return .respond(errorResponse(status: 400, reason: "Bad Request", code: "invalid_body", message: "Expected revoke JSON"))
        }
        guard revokeRequest.protocolVersion == RemoteGatewayProtocol.version else {
            return .respond(errorResponse(status: 409, reason: "Conflict", code: "protocol_mismatch", message: "Unsupported protocol version"))
        }
        do {
            guard try deviceStore.revokeDevice(device.id, at: date) else {
                return .respond(credentialInvalidResponse())
            }
        } catch {
            return .respond(persistenceFailure("Could not revoke the device", error: error))
        }

        // revokeDevice returns only after synchronous persistence. Keep audit
        // and the server notification outside the store mutation.
        auditLog.record(RemoteAccessAuditEntry(at: date, action: .deviceRevoked, deviceID: device.id))
        onDeviceRevoked?(device.id)
        let body = (try? encoder.encode(RemoteGatewayRevokeCurrentDeviceResponse(revokedDeviceID: device.id))) ?? Data()
        return .respond(.json(body: body))
    }

    private func handleStatic(path: String) -> Outcome {
        guard let resource = configuration.staticResources[path] else {
            return .respond(errorResponse(status: 404, reason: "Not Found", code: "not_found", message: "Unknown route"))
        }
        return .respond(RemoteGatewayHTTPResponse(
            status: 200,
            reason: "OK",
            headers: [("Content-Type", resource.contentType)],
            body: resource.data
        ))
    }

    // MARK: - Authentication and identity

    private func authenticate(
        _ request: RemoteGatewayHTTPRequest,
        requirement: RemoteGatewayRoutePolicy.Authentication,
        at date: Date
    ) -> AuthResult {
        let authorizationValues = request.headerValues("authorization")
        if authorizationValues.isEmpty == false {
            guard let token = bearerToken(from: authorizationValues) else {
                return .failure(auditedCredentialInvalidResponse(at: date))
            }
            guard let tailscaleLogin = verifiedNativeIdentity(request) else {
                auditLog.record(RemoteAccessAuditEntry(at: date, action: .authenticationFailed))
                return .failure(identityUnavailableResponse())
            }
            switch deviceStore.authenticateNativeBearer(token, tailscaleLogin: tailscaleLogin, at: date) {
            case .authenticated(let device):
                return .success(device)
            case .invalidCredential:
                return .failure(auditedCredentialInvalidResponse(at: date))
            case .identityMismatch:
                auditLog.record(RemoteAccessAuditEntry(at: date, action: .authenticationFailed))
                return .failure(errorResponse(
                    status: 401,
                    reason: "Unauthorized",
                    code: "identity_mismatch",
                    message: "Device identity does not match"
                ))
            }
        }

        guard requirement != .nativeBearer else {
            return .failure(auditedCredentialInvalidResponse(at: date))
        }
        guard let token = browserCredentialToken(request) else {
            // Missing, malformed, or ambiguous cookie input is not a brute-
            // force attempt and cannot globally lock out a valid browser.
            return .failure(auditedCredentialInvalidResponse(at: date))
        }
        guard let device = deviceStore.authenticateBrowserCredential(token, at: date) else {
            // Count only one shape-valid browser credential that fails durable
            // lookup. Native Bearer failures never use this legacy limiter.
            return .failure(failedCredentialResponse(at: date))
        }
        return .success(device)
    }

    private func bearerToken(from values: [String]) -> String? {
        guard values.count == 1 else { return nil }
        let value = values[0]
        guard value.utf8.count <= Self.maximumAuthorizationBytes,
              value.contains(",") == false else { return nil }
        let components = value.split(separator: " ", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0].lowercased() == "bearer" else { return nil }
        let token = String(components[1])
        return isValidCredentialTokenShape(token) ? token : nil
    }

    private func browserCredentialToken(_ request: RemoteGatewayHTTPRequest) -> String? {
        let cookieHeaders = request.headerValues("cookie")
        guard cookieHeaders.count == 1 else { return nil }
        let credentialValues = cookieHeaders[0].split(separator: ";", omittingEmptySubsequences: false).compactMap { pair -> String? in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == RemoteGatewayProtocol.credentialCookieName else {
                return nil
            }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard credentialValues.count == 1,
              let token = credentialValues.first,
              isValidCredentialTokenShape(token) else { return nil }
        return token
    }

    private func isValidCredentialTokenShape(_ token: String) -> Bool {
        guard token.isEmpty == false,
              token.utf8.count <= Self.maximumCredentialBytes else { return false }
        return token.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 48...57, 65...90, 95, 97...122: true // base64url
            default: false
            }
        }
    }

    private func verifiedNativeIdentity(_ request: RemoteGatewayHTTPRequest) -> String? {
        let presented = request.headerValues("tailscale-user-login")
        if presented.isEmpty {
            return nativeIdentityForTesting.flatMap(validatedIdentity)
        }
        guard presented.count == 1 else { return nil }
        return validatedIdentity(presented[0])
    }

    private func validatedIdentity(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false,
              rawValue == value,
              value.utf8.count <= Self.maximumIdentityBytes,
              value.contains(",") == false,
              value.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) == false }) else {
            return nil
        }
        return value
    }

    // MARK: - Request gates and responses

    private func hasBrowserContext(_ request: RemoteGatewayHTTPRequest) -> Bool {
        request.headerValues("authorization").isEmpty == false
            || request.headerValues("cookie").isEmpty == false
            || request.headerValues("origin").isEmpty == false
            || request.headers.keys.contains { $0.hasPrefix("sec-fetch-") }
    }

    private func optionalOriginRejection(_ request: RemoteGatewayHTTPRequest) -> RemoteGatewayHTTPResponse? {
        let origins = request.headerValues("origin")
        guard origins.isEmpty == false else { return nil }
        guard origins.count == 1,
              origins[0].contains(",") == false,
              configuration.allowedOrigins.contains(origins[0]) else {
            return errorResponse(status: 403, reason: "Forbidden", code: "origin_denied", message: "Origin not allowed")
        }
        return nil
    }

    private func requiredOriginRejection(_ request: RemoteGatewayHTTPRequest) -> RemoteGatewayHTTPResponse? {
        let origins = request.headerValues("origin")
        guard origins.isEmpty == false else {
            return errorResponse(status: 403, reason: "Forbidden", code: "origin_required", message: "Origin required")
        }
        return optionalOriginRejection(request)
    }

    private func methodNotAllowed(_ allowedMethod: String) -> RemoteGatewayHTTPResponse {
        var response = errorResponse(status: 405, reason: "Method Not Allowed", code: "method_not_allowed", message: "Method not allowed")
        response.headers.append(("Allow", allowedMethod))
        return response
    }

    private func invalidNativePairingOfferResponse() -> RemoteGatewayHTTPResponse {
        errorResponse(status: 403, reason: "Forbidden", code: "invalid_pairing_offer", message: "Invalid or expired pairing offer")
    }

    private func identityUnavailableResponse() -> RemoteGatewayHTTPResponse {
        errorResponse(status: 401, reason: "Unauthorized", code: "identity_unavailable", message: "Device identity is unavailable")
    }

    private func credentialInvalidResponse() -> RemoteGatewayHTTPResponse {
        errorResponse(status: 401, reason: "Unauthorized", code: "credential_invalid", message: "Pair this device again")
    }

    private func failedCredentialResponse(at date: Date) -> RemoteGatewayHTTPResponse {
        if authRateLimiter.isLockedOut(at: date) {
            return errorResponse(status: 429, reason: "Too Many Requests", code: "rate_limited", message: "Too many failed attempts")
        }
        let locked = authRateLimiter.recordFailure(at: date)
        auditLog.record(RemoteAccessAuditEntry(at: date, action: .authenticationFailed))
        if locked {
            auditLog.record(RemoteAccessAuditEntry(at: date, action: .rateLimitLockout, detail: "auth"))
        }
        return credentialInvalidResponse()
    }

    private func auditedCredentialInvalidResponse(at date: Date) -> RemoteGatewayHTTPResponse {
        auditLog.record(RemoteAccessAuditEntry(at: date, action: .authenticationFailed))
        return credentialInvalidResponse()
    }

    private func recordPairingFailure(at date: Date, detail: String) {
        let locked = pairingRateLimiter.recordFailure(at: date)
        auditLog.record(RemoteAccessAuditEntry(at: date, action: .pairingFailed))
        if locked {
            auditLog.record(RemoteAccessAuditEntry(at: date, action: .rateLimitLockout, detail: detail))
        }
    }

    private func persistenceFailure(_ message: String, error: Error) -> RemoteGatewayHTTPResponse {
        ToasttyLog.error(
            "Failed to persist remote device state",
            category: .automation,
            metadata: ["error_type": String(reflecting: type(of: error))]
        )
        return errorResponse(status: 500, reason: "Internal Server Error", code: "persistence_failed", message: message)
    }

    private func errorResponse(status: Int, reason: String, code: String, message: String) -> RemoteGatewayHTTPResponse {
        let body = (try? encoder.encode(RemoteGatewayErrorResponse(code: code, message: message))) ?? Data()
        return .json(status: status, reason: reason, body: body)
    }
}
