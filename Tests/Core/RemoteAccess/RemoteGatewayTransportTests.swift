import RemoteProtocol
import Foundation
import Testing
@testable import CoreState

struct RemoteGatewayHTTPTests {
    @Test func parsesGetRequestWithHeadersAndCookies() throws {
        let raw = "GET /api/sessions?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nCookie: a=1; toastty_remote_session=tok123\r\n\r\n"
        guard case .request(let request, let consumed) = RemoteGatewayHTTPRequest.parse(Data(raw.utf8)) else {
            Issue.record("Expected parsed request")
            return
        }
        #expect(request.method == "GET")
        #expect(request.path == "/api/sessions")
        #expect(request.header("Host") == "127.0.0.1")
        #expect(request.cookies["toastty_remote_session"] == "tok123")
        #expect(request.cookies["a"] == "1")
        #expect(consumed == raw.utf8.count)
    }

    @Test func parsesPostBodyByContentLength() {
        let body = #"{"code":"AB-12"}"#
        let raw = "POST /api/pair HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .request(let request, _) = RemoteGatewayHTTPRequest.parse(Data(raw.utf8)) else {
            Issue.record("Expected parsed request")
            return
        }
        #expect(String(data: request.body, encoding: .utf8) == body)

        let incomplete = "POST /api/pair HTTP/1.1\r\nContent-Length: 50\r\n\r\nshort"
        #expect(RemoteGatewayHTTPRequest.parse(Data(incomplete.utf8)) == .needMoreData)
    }

    @Test func rejectsMalformedAndOversizeRequests() {
        #expect(RemoteGatewayHTTPRequest.parse(Data("GARBAGE\r\n\r\n".utf8)) == .invalid)
        #expect(RemoteGatewayHTTPRequest.parse(Data("GET /\r\n\r\n".utf8)) == .invalid)
        let hugeHead = "GET / HTTP/1.1\r\nX-Pad: " + String(repeating: "x", count: 20_000)
        #expect(RemoteGatewayHTTPRequest.parse(Data(hugeHead.utf8)) == .invalid)
        #expect(RemoteGatewayHTTPRequest.parse(Data("GET / HT".utf8)) == .needMoreData)
    }

    @Test func parserPreservesRepeatedSecurityHeadersAndRejectsDuplicateContentLength() {
        let raw = "GET /api/sessions HTTP/1.1\r\nAuthorization: Bearer first\r\nAuthorization: Bearer second\r\nTailscale-User-Login: first@example.com\r\nTailscale-User-Login: second@example.com\r\n\r\n"
        guard case .request(let request, _) = RemoteGatewayHTTPRequest.parse(Data(raw.utf8)) else {
            Issue.record("Expected parsed request")
            return
        }
        #expect(request.headerValues("authorization") == ["Bearer first", "Bearer second"])
        #expect(request.headerValues("tailscale-user-login") == ["first@example.com", "second@example.com"])

        let ambiguousLength = "POST /api/pair HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n"
        #expect(RemoteGatewayHTTPRequest.parse(Data(ambiguousLength.utf8)) == .invalid)
    }

    @Test func parserRejectsInvalidHeaderNamesAndObsoleteFolding() {
        let invalidHeaders = [
            ": value",
            " Bad: value",
            "\tBad: value",
            "Bad : value",
            "Bad@Name: value",
            "Bad(Name): value",
            "X-Good: first\r\n continued",
            "X-Good: first\r\n\tcontinued",
        ]
        for header in invalidHeaders {
            let raw = "GET / HTTP/1.1\r\n\(header)\r\n\r\n"
            #expect(RemoteGatewayHTTPRequest.parse(Data(raw.utf8)) == .invalid)
        }

        let valid = "GET / HTTP/1.1\r\nX_Good-Token:\t value \t\r\n\r\n"
        guard case .request(let request, _) = RemoteGatewayHTTPRequest.parse(Data(valid.utf8)) else {
            Issue.record("Expected valid token header")
            return
        }
        #expect(request.header("x_good-token") == "value")
    }

    @Test func parserRejectsInvalidContentLengthHostAndTransferEncoding() {
        let invalidRequests = [
            "POST / HTTP/1.1\r\nContent-Length:\r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length:   \r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length: +1\r\n\r\nx",
            "POST / HTTP/1.1\r\nContent-Length: nope\r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length: 1x\r\n\r\nx",
            "POST / HTTP/1.1\r\nContent-Length: 999999999999999999999999999999\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: first\r\nHost: second\r\n\r\n",
            "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
        ]
        for raw in invalidRequests {
            #expect(RemoteGatewayHTTPRequest.parse(Data(raw.utf8)) == .invalid)
        }
    }

    @Test func parserAcceptsOnlyOriginFormTargetsAndExactHTTP1Versions() {
        let invalidRequestLines = [
            "GET http://example.com/path HTTP/1.1",
            "CONNECT example.com:443 HTTP/1.1",
            "OPTIONS * HTTP/1.1",
            "GET /path#fragment HTTP/1.1",
            "GET  /path HTTP/1.1",
            "GET /path  HTTP/1.1",
            "GET /path HTTP/1.2",
        ]
        for requestLine in invalidRequestLines {
            let raw = "\(requestLine)\r\n\r\n"
            #expect(RemoteGatewayHTTPRequest.parse(Data(raw.utf8)) == .invalid)
        }
    }

    @Test func responsesCarrySecurityHeaders() throws {
        let response = RemoteGatewayHTTPResponse.text(status: 200, reason: "OK", "hi")
        let serialized = try #require(String(data: response.serialized(), encoding: .utf8))
        #expect(serialized.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(serialized.contains("Cache-Control: no-store"))
        #expect(serialized.contains("X-Content-Type-Options: nosniff"))
        #expect(serialized.contains("Content-Security-Policy:"))
        #expect(serialized.contains("Content-Length: 2"))
        #expect(serialized.hasSuffix("\r\n\r\nhi"))
    }

    @Test func webSocketAcceptKeyMatchesRFCExample() {
        // RFC 6455 section 1.3 worked example.
        #expect(
            RemoteGatewayWebSocketHandshake.acceptKey(forClientKey: "dGhlIHNhbXBsZSBub25jZQ==")
                == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        )
    }
}

struct RemoteWebSocketFramingTests {
    static func maskedClientFrame(opcode: RemoteWebSocketFraming.Opcode, payload: [UInt8], mask: [UInt8] = [1, 2, 3, 4]) -> Data {
        var data = Data()
        data.append(0x80 | opcode.rawValue)
        precondition(payload.count < 126)
        data.append(0x80 | UInt8(payload.count))
        data.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() {
            data.append(byte ^ mask[index % 4])
        }
        return data
    }

    @Test func decodesMaskedClientTextFrame() {
        let payload = Array("hello".utf8)
        let framed = Self.maskedClientFrame(opcode: .text, payload: payload)
        guard case .frame(let frame, let consumed) = RemoteWebSocketFraming.decodeClientFrame(framed) else {
            Issue.record("Expected decoded frame")
            return
        }
        #expect(frame.opcode == .text)
        #expect(frame.payload == Data(payload))
        #expect(consumed == framed.count)
    }

    @Test func rejectsUnmaskedAndFragmentedClientFrames() {
        var unmasked = Data([0x81, 0x02])
        unmasked.append(contentsOf: Array("hi".utf8))
        #expect(RemoteWebSocketFraming.decodeClientFrame(unmasked) == .invalid)

        // FIN bit clear = fragmented.
        var fragmented = Self.maskedClientFrame(opcode: .text, payload: [1, 2])
        fragmented[fragmented.startIndex] = 0x01
        #expect(RemoteWebSocketFraming.decodeClientFrame(fragmented) == .invalid)

        #expect(RemoteWebSocketFraming.decodeClientFrame(Data([0x81])) == .needMoreData)
    }

    @Test func serverFramesRoundTripThroughLengthEncodings() {
        for size in [5, 200, 70_000] {
            let payload = Data(repeating: 0xAB, count: size)
            let encoded = RemoteWebSocketFraming.encodeServerFrame(opcode: .binary, payload: payload)
            // Server frames are unmasked: verify header shape by re-parsing
            // manually.
            #expect(encoded[encoded.startIndex] == (0x80 | RemoteWebSocketFraming.Opcode.binary.rawValue))
            #expect(encoded.count >= size + 2)
            #expect(encoded.suffix(size) == payload)
        }
    }

    @Test func closeFrameCarriesCode() {
        let encoded = RemoteWebSocketFraming.encodeServerCloseFrame(code: 1001)
        let bytes = [UInt8](encoded)
        #expect(bytes[0] == 0x88)
        #expect(bytes[1] == 2)
        #expect((Int(bytes[2]) << 8 | Int(bytes[3])) == 1001)
    }
}

private struct StubFacade: RemoteSessionFacade {
    var snapshot: RemoteSessionListSnapshot
    var eventsOutcome: ConversationEventPageOutcome = .conversationNotFound

    func sessionList(at date: Date) -> RemoteSessionListSnapshot {
        snapshot
    }

    func conversationSnapshot(for conversationID: RemoteConversationID, at date: Date) -> RemoteConversationSnapshot? {
        nil
    }

    func conversationEvents(
        for conversationID: RemoteConversationID,
        after cursor: ConversationEventCursor?,
        limit: Int
    ) -> ConversationEventPageOutcome {
        eventsOutcome
    }

    func conversationEvents(
        for conversationID: RemoteConversationID,
        before cursor: ConversationEventBackwardCursor?,
        limit: Int
    ) -> ConversationEventPageOutcome {
        eventsOutcome
    }
}

private final class PersistenceWriteBudget: @unchecked Sendable {
    var remaining: Int

    init(_ remaining: Int) {
        self.remaining = remaining
    }
}

struct RemoteGatewayRequestHandlerTests {
    static let now = Date(timeIntervalSince1970: 1_786_200_000)
    static let origin = "https://mac.tailnet.ts.net"
    static let fixtureDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Tests/RemoteProtocol/Fixtures/v1", isDirectory: true)

    static func makeHandler(
        deviceStore: RemoteDeviceStore = RemoteDeviceStore(fileURL: nil),
        pairingLimiter: RemoteAccessRateLimiter = RemoteAccessRateLimiter(maximumFailures: 2, windowDuration: 60, lockoutDuration: 300),
        authLimiter: RemoteAccessRateLimiter = RemoteAccessRateLimiter(maximumFailures: 20, windowDuration: 60, lockoutDuration: 300),
        eventsOutcome: ConversationEventPageOutcome = .conversationNotFound,
        sendHandler: RemoteGatewayRequestHandler.SendHandler? = nil,
        nativeIdentityForTesting: String? = nil
    ) -> (RemoteGatewayRequestHandler, RemoteDeviceStore, RemoteAccessAuditLog) {
        let audit = RemoteAccessAuditLog(fileURL: nil)
        let snapshot = RemoteSessionListSnapshot(
            projectionRunID: RemoteProjectionRunID(),
            conversations: [],
            generatedAt: now
        )
        let handler = RemoteGatewayRequestHandler(
            deviceStore: deviceStore,
            auditLog: audit,
            facade: StubFacade(snapshot: snapshot, eventsOutcome: eventsOutcome),
            configuration: RemoteGatewayConfiguration(
                allowedOrigins: [origin],
                staticResources: [
                    "/index.html": RemoteGatewayStaticResource(contentType: "text/html; charset=utf-8", data: Data("<html>app</html>".utf8)),
                ]
            ),
            sendHandler: sendHandler,
            nativeIdentityForTesting: nativeIdentityForTesting,
            pairingRateLimiter: pairingLimiter,
            authRateLimiter: authLimiter
        )
        return (handler, deviceStore, audit)
    }

    static func request(
        _ method: String,
        _ path: String,
        origin: String? = nil,
        cookie: String? = nil,
        body: String = "",
        extraHeaders: [String: String] = [:]
    ) -> RemoteGatewayHTTPRequest {
        var headers: [String: String] = extraHeaders
        if let origin { headers["origin"] = origin }
        if let cookie { headers["cookie"] = cookie }
        return RemoteGatewayHTTPRequest(method: method, path: path, headers: headers, body: Data(body.utf8))
    }

    static func request(
        _ method: String,
        _ path: String,
        headerFields: [(String, String)],
        body: Data = Data()
    ) -> RemoteGatewayHTTPRequest {
        RemoteGatewayHTTPRequest(method: method, path: path, headerFields: headerFields, body: body)
    }

    static func pairedDeviceCookie(_ store: RemoteDeviceStore) -> String {
        let code = store.issuePairingCode(at: now)
        guard case .paired(_, let token) = try! store.redeemPairingCode(code.code, deviceName: "Phone", at: now) else {
            fatalError("pairing must succeed")
        }
        return "\(RemoteGatewayProtocol.credentialCookieName)=\(token)"
    }

    static func nativeCredential(
        handler: RemoteGatewayRequestHandler,
        store: RemoteDeviceStore,
        identity: String = "owner@example.com"
    ) throws -> (credential: String, device: RemoteGatewayDeviceSummary) {
        let offer = try store.issueNativePairingOffer(
            gatewayURL: URL(string: "https://mac.tailnet.ts.net")!,
            at: now
        )
        let exchange = RemoteGatewayNativePairingExchangeRequest(
            deviceName: "Native Phone",
            offerID: offer.id,
            secret: offer.qrPayload.secret
        )
        let body = try ConversationEventCoding.makeEncoder().encode(exchange)
        guard case .respond(let response) = handler.handle(
            request(
                "POST",
                "/v1/native-pairing/exchange",
                headerFields: [("tailscale-user-login", identity)],
                body: body
            ),
            at: now
        ) else {
            throw CocoaError(.coderInvalidValue)
        }
        #expect(response.status == 200)
        let decoded = try ConversationEventCoding.makeDecoder().decode(
            RemoteGatewayNativePairingExchangeResponse.self,
            from: response.body
        )
        // V1 credentials are issued atomically with their device and never
        // rotate, making the device creation date the credential issue date.
        #expect(decoded.credentialCreatedAt == now)
        return (decoded.credential, decoded.device)
    }

    static func error(_ response: RemoteGatewayHTTPResponse) throws -> RemoteGatewayErrorResponse {
        try ConversationEventCoding.makeDecoder().decode(RemoteGatewayErrorResponse.self, from: response.body)
    }

    @Test func servesStaticIndexAtRoot() {
        let (handler, _, _) = Self.makeHandler()
        guard case .respond(let response) = handler.handle(Self.request("GET", "/"), at: Self.now) else {
            Issue.record("Expected response")
            return
        }
        #expect(response.status == 200)
        #expect(String(data: response.body, encoding: .utf8) == "<html>app</html>")
    }

    @Test func helloIsPublicCachelessAndAdvertisesOnlyImplementedAuthentication() throws {
        let (handler, _, _) = Self.makeHandler()
        guard case .respond(let response) = handler.handle(
            Self.request("GET", "/api/hello"),
            at: Self.now
        ) else {
            Issue.record("Expected response")
            return
        }

        #expect(response.status == 200)
        let hello = try ConversationEventCoding.makeDecoder().decode(
            RemoteGatewayHelloResponse.self,
            from: response.body
        )
        #expect(hello == RemoteGatewayHelloResponse())
        #expect(hello.capabilities == [
            .browserCookiePairing,
            .nativeBearerPairing,
            .conversationBackwardPaging,
        ])

        let expectedFixture = try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent("hello-response.json"))
        #expect(response.body == expectedFixture)

        let serialized = try #require(String(data: response.serialized(), encoding: .utf8))
        #expect(serialized.contains("Cache-Control: no-store"))
        #expect(serialized.localizedCaseInsensitiveContains("access-control-allow-origin") == false)
        #expect(serialized.localizedCaseInsensitiveContains("set-cookie") == false)
        #expect(serialized.contains(RemoteGatewayProtocol.credentialCookieName) == false)
    }

    @Test func helloRejectsAPresentDisallowedOrigin() {
        let (handler, _, _) = Self.makeHandler()
        guard case .respond(let response) = handler.handle(
            Self.request("GET", "/api/hello", origin: "https://evil.example"),
            at: Self.now
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(response.status == 403)
    }

    @Test func rejectsUnlistedOriginOnEveryRoute() {
        let (handler, _, _) = Self.makeHandler()
        guard case .respond(let response) = handler.handle(
            Self.request("GET", "/", origin: "https://evil.example"),
            at: Self.now
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(response.status == 403)
    }

    @Test func pairingHappyPathSetsHttpOnlyCookie() throws {
        let (handler, store, _) = Self.makeHandler()
        var pairedDevice: RemoteDeviceRecord?
        handler.onDevicePaired = { pairedDevice = $0 }
        let code = store.issuePairingCode(at: Self.now)
        let body = #"{"code":"\#(code.code)","deviceName":"Vishal's phone"}"#
        guard case .respond(let response) = handler.handle(
            Self.request("POST", "/api/pair", origin: Self.origin, body: body),
            at: Self.now.addingTimeInterval(5)
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(response.status == 200)
        let cookieHeader = try #require(response.headers.first { $0.0 == "Set-Cookie" }?.1)
        #expect(cookieHeader.contains("HttpOnly"))
        #expect(cookieHeader.contains("SameSite=Strict"))
        // Plain loopback HTTP: no Secure attribute, or Safari drops the cookie.
        #expect(cookieHeader.contains("Secure") == false)
        let decoded = try ConversationEventCoding.makeDecoder().decode(RemoteGatewayPairResponse.self, from: response.body)
        #expect(decoded.device.name == "Vishal's phone")
        #expect(decoded.device.scopes == [.read, .send])
        #expect(pairedDevice?.id == decoded.device.id)
    }

    @Test func pairingOverHTTPSFrontMarksCookieSecure() throws {
        let (handler, store, _) = Self.makeHandler()
        let code = store.issuePairingCode(at: Self.now)
        guard case .respond(let response) = handler.handle(
            Self.request(
                "POST",
                "/api/pair",
                origin: Self.origin,
                body: #"{"code":"\#(code.code)","deviceName":"Phone"}"#,
                extraHeaders: ["x-forwarded-proto": "https"]
            ),
            at: Self.now
        ) else {
            Issue.record("Expected response")
            return
        }
        let cookieHeader = try #require(response.headers.first { $0.0 == "Set-Cookie" }?.1)
        #expect(cookieHeader.contains("; Secure"))
    }

    @Test func pairingWithoutOriginIsRejected() {
        let (handler, store, _) = Self.makeHandler()
        let code = store.issuePairingCode(at: Self.now)
        guard case .respond(let response) = handler.handle(
            Self.request("POST", "/api/pair", body: #"{"code":"\#(code.code)","deviceName":"X"}"#),
            at: Self.now
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(response.status == 403)
    }

    @Test func repeatedPairingFailuresLockOut() {
        let (handler, _, audit) = Self.makeHandler()
        for attempt in 0..<3 {
            guard case .respond(let response) = handler.handle(
                Self.request("POST", "/api/pair", origin: Self.origin, body: #"{"code":"XXXX-XXXX","deviceName":"X"}"#),
                at: Self.now.addingTimeInterval(Double(attempt))
            ) else {
                Issue.record("Expected response")
                return
            }
            #expect(response.status == 403)
        }
        guard case .respond(let lockedResponse) = handler.handle(
            Self.request("POST", "/api/pair", origin: Self.origin, body: #"{"code":"XXXX-XXXX","deviceName":"X"}"#),
            at: Self.now.addingTimeInterval(4)
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(lockedResponse.status == 429)
        #expect(audit.recentEntries().contains { $0.action == .rateLimitLockout })
    }

    @Test func routeCatalogIsCompleteAndEveryKnownPathRejectsWrongMethods() {
        #expect(RemoteGatewayRoutePolicy.fixed.count == RemoteGatewayRoute.allCases.count)
        #expect(Set(RemoteGatewayRoutePolicy.fixed.keys) == Set(RemoteGatewayRoute.allCases))

        let (handler, _, _) = Self.makeHandler()
        for route in RemoteGatewayRoute.allCases {
            guard let policy = RemoteGatewayRoutePolicy.fixed[route] else {
                Issue.record("Missing policy for \(route)")
                continue
            }
            let wrongMethod = policy.method == "GET" ? "POST" : "GET"
            guard case .respond(let response) = handler.handle(
                Self.request(wrongMethod, route.path),
                at: Self.now
            ) else {
                Issue.record("Expected response for \(route.path)")
                continue
            }
            #expect(response.status == 405)
            #expect(response.headers.contains { $0.0 == "Allow" && $0.1 == policy.method })
        }
    }

    @Test func optionsAndUnknownMethodsNeverEnableCORS() throws {
        let (handler, _, _) = Self.makeHandler()
        for path in RemoteGatewayRoute.allCases.map(\.path) + ["/", "/unknown"] {
            guard case .respond(let response) = handler.handle(
                Self.request("OPTIONS", path, origin: Self.origin),
                at: Self.now
            ) else {
                Issue.record("Expected response for \(path)")
                continue
            }
            #expect(response.status == (path == "/unknown" ? 404 : 405))
            let serialized = try #require(String(data: response.serialized(), encoding: .utf8))
            #expect(serialized.localizedCaseInsensitiveContains("access-control-allow") == false)
        }
    }

    @Test func nativeExchangeRejectsEveryBrowserContextBeforeIdentityOrState() throws {
        let contexts: [[(String, String)]] = [
            [("authorization", "Bearer ignored")],
            [("cookie", "a=b")],
            [("origin", Self.origin)],
            [("sec-fetch-site", "same-origin")],
            [("sec-fetch-mode", "cors")],
        ]
        for headerFields in contexts {
            let (handler, store, _) = Self.makeHandler(nativeIdentityForTesting: "owner@example.com")
            let offer = try store.issueNativePairingOffer(
                gatewayURL: URL(string: "https://mac.tailnet.ts.net")!,
                at: Self.now
            )
            let body = try ConversationEventCoding.makeEncoder().encode(
                RemoteGatewayNativePairingExchangeRequest(
                    deviceName: "Phone",
                    offerID: offer.id,
                    secret: offer.qrPayload.secret
                )
            )
            guard case .respond(let response) = handler.handle(
                Self.request("POST", "/v1/native-pairing/exchange", headerFields: headerFields, body: body),
                at: Self.now
            ) else {
                Issue.record("Expected response")
                continue
            }
            #expect(response.status == 403)
            #expect(try Self.error(response).code == "browser_context_denied")
            #expect(store.activeNativePairingOffer(at: Self.now) != nil)
        }
    }

    @Test func browserPairRejectsAuthorizationBeforeRedeemingCode() throws {
        let (handler, store, _) = Self.makeHandler()
        let code = store.issuePairingCode(at: Self.now)
        guard case .respond(let response) = handler.handle(
            Self.request(
                "POST",
                "/api/pair",
                origin: Self.origin,
                body: #"{"code":"\#(code.code)","deviceName":"Phone"}"#,
                extraHeaders: ["authorization": "Bearer hostile"]
            ),
            at: Self.now
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(response.status == 403)
        #expect(try Self.error(response).code == "authorization_not_allowed")
        #expect(store.hasActivePairingCode)
    }

    @Test func nativeExchangeValidatesProtocolIdentityProofShapeAndTightBodyBound() throws {
        let (handler, store, _) = Self.makeHandler()
        let offer = try store.issueNativePairingOffer(
            gatewayURL: URL(string: "https://mac.tailnet.ts.net")!,
            at: Self.now
        )
        let encoder = ConversationEventCoding.makeEncoder()

        let valid = try encoder.encode(RemoteGatewayNativePairingExchangeRequest(
            deviceName: "Phone",
            offerID: offer.id,
            secret: offer.qrPayload.secret
        ))
        guard case .respond(let missingIdentity) = handler.handle(
            Self.request("POST", "/v1/native-pairing/exchange", headerFields: [], body: valid),
            at: Self.now
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(missingIdentity.status == 401)
        #expect(try Self.error(missingIdentity).code == "identity_unavailable")

        let mismatch = try encoder.encode(RemoteGatewayNativePairingExchangeRequest(
            protocolVersion: "99.0",
            deviceName: "Phone",
            offerID: offer.id,
            secret: offer.qrPayload.secret
        ))
        guard case .respond(let protocolMismatch) = handler.handle(
            Self.request("POST", "/v1/native-pairing/exchange", headerFields: [("tailscale-user-login", "owner@example.com")], body: mismatch),
            at: Self.now
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(protocolMismatch.status == 409)
        #expect(try Self.error(protocolMismatch).code == "protocol_mismatch")

        let bothProofs = try encoder.encode(RemoteGatewayNativePairingExchangeRequest(
            deviceName: "Phone",
            offerID: offer.id,
            secret: offer.qrPayload.secret,
            fallbackCode: offer.fallbackCode
        ))
        guard case .respond(let invalidShape) = handler.handle(
            Self.request("POST", "/v1/native-pairing/exchange", headerFields: [("tailscale-user-login", "owner@example.com")], body: bothProofs),
            at: Self.now
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(invalidShape.status == 400)
        #expect(store.activeNativePairingOffer(at: Self.now) != nil)

        guard case .respond(let oversized) = handler.handle(
            Self.request(
                "POST",
                "/v1/native-pairing/exchange",
                headerFields: [("tailscale-user-login", "owner@example.com")],
                body: Data(repeating: 0x41, count: 2_049)
            ),
            at: Self.now
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(oversized.status == 400)
        #expect(store.activeNativePairingOffer(at: Self.now) != nil)
    }

    @Test func missingWrongAndConsumedNativeProofsAreIndistinguishable() throws {
        let decoder = ConversationEventCoding.makeDecoder()
        let identity = "owner@example.com"

        func exchange(
            handler: RemoteGatewayRequestHandler,
            request: RemoteGatewayNativePairingExchangeRequest
        ) throws -> RemoteGatewayHTTPResponse {
            let body = try ConversationEventCoding.makeEncoder().encode(request)
            guard case .respond(let response) = handler.handle(
                Self.request("POST", "/v1/native-pairing/exchange", headerFields: [("tailscale-user-login", identity)], body: body),
                at: Self.now
            ) else {
                throw CocoaError(.coderInvalidValue)
            }
            return response
        }

        let (missingHandler, _, _) = Self.makeHandler()
        let missing = try exchange(
            handler: missingHandler,
            request: RemoteGatewayNativePairingExchangeRequest(
                deviceName: "Phone",
                offerID: UUID(),
                secret: String(repeating: "a", count: 43)
            )
        )

        let (wrongHandler, wrongStore, _) = Self.makeHandler()
        let wrongOffer = try wrongStore.issueNativePairingOffer(gatewayURL: URL(string: "https://mac.tailnet.ts.net")!, at: Self.now)
        let wrong = try exchange(
            handler: wrongHandler,
            request: RemoteGatewayNativePairingExchangeRequest(
                deviceName: "Phone",
                offerID: wrongOffer.id,
                secret: String(repeating: "a", count: 43)
            )
        )

        let (consumedHandler, consumedStore, _) = Self.makeHandler()
        let consumedOffer = try consumedStore.issueNativePairingOffer(gatewayURL: URL(string: "https://mac.tailnet.ts.net")!, at: Self.now)
        let validRequest = RemoteGatewayNativePairingExchangeRequest(
            deviceName: "Phone",
            offerID: consumedOffer.id,
            secret: consumedOffer.qrPayload.secret
        )
        #expect(try exchange(handler: consumedHandler, request: validRequest).status == 200)
        let consumed = try exchange(handler: consumedHandler, request: validRequest)

        for response in [missing, wrong, consumed] {
            #expect(response.status == 403)
            #expect(try decoder.decode(RemoteGatewayErrorResponse.self, from: response.body).code == "invalid_pairing_offer")
        }
        #expect(missing.body == wrong.body)
        #expect(wrong.body == consumed.body)
    }

    @Test func sessionListRequiresCredential() throws {
        let (handler, store, _) = Self.makeHandler()
        guard case .respond(let unauthorized) = handler.handle(Self.request("GET", "/api/sessions"), at: Self.now) else {
            Issue.record("Expected response")
            return
        }
        #expect(unauthorized.status == 401)

        let cookie = Self.pairedDeviceCookie(store)
        guard case .respond(let authorized) = handler.handle(
            Self.request("GET", "/api/sessions", cookie: cookie),
            at: Self.now.addingTimeInterval(1)
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(authorized.status == 200)
        let decoded = try ConversationEventCoding.makeDecoder().decode(RemoteGatewaySessionListResponse.self, from: authorized.body)
        #expect(decoded.protocolVersion == RemoteGatewayProtocol.version)
    }

    @Test func nativeBearerAuthorizesDataWithoutOriginAndRejectsIdentityFailures() throws {
        let identity = "owner@example.com"
        let (handler, store, _) = Self.makeHandler()
        let native = try Self.nativeCredential(handler: handler, store: store, identity: identity)

        guard case .respond(let allowed) = handler.handle(
            Self.request(
                "GET",
                "/api/sessions",
                headerFields: [
                    ("authorization", "Bearer \(native.credential)"),
                    ("tailscale-user-login", identity),
                ]
            ),
            at: Self.now.addingTimeInterval(1)
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(allowed.status == 200)

        guard case .respond(let absentIdentity) = handler.handle(
            Self.request("GET", "/api/sessions", headerFields: [("authorization", "Bearer \(native.credential)")]),
            at: Self.now.addingTimeInterval(2)
        ), case .respond(let mismatchedIdentity) = handler.handle(
            Self.request(
                "GET",
                "/api/sessions",
                headerFields: [
                    ("authorization", "Bearer \(native.credential)"),
                    ("tailscale-user-login", "other@example.com"),
                ]
            ),
            at: Self.now.addingTimeInterval(3)
        ) else {
            Issue.record("Expected responses")
            return
        }
        #expect(absentIdentity.status == 401)
        #expect(try Self.error(absentIdentity).code == "identity_unavailable")
        #expect(mismatchedIdentity.status == 401)
        #expect(try Self.error(mismatchedIdentity).code == "identity_mismatch")
        #expect(String(data: mismatchedIdentity.body, encoding: .utf8)?.contains(identity) == false)
    }

    @Test func authorizationPresenceAlwaysWinsWithoutCookieFallback() throws {
        let (handler, store, _) = Self.makeHandler(nativeIdentityForTesting: "owner@example.com")
        let cookie = Self.pairedDeviceCookie(store)
        let hostileValues = [
            "",
            "Bearer",
            "Bearer ",
            "Basic abc",
            "Bearer token extra",
            "Bearer bad,second",
            "Bearer " + String(repeating: "a", count: 257),
        ]
        for value in hostileValues {
            guard case .respond(let response) = handler.handle(
                Self.request(
                    "GET",
                    "/api/sessions",
                    headerFields: [
                        ("authorization", value),
                        ("cookie", cookie),
                    ]
                ),
                at: Self.now
            ) else {
                Issue.record("Expected response")
                continue
            }
            #expect(response.status == 401)
            #expect(try Self.error(response).code == "credential_invalid")
        }

        guard case .respond(let duplicated) = handler.handle(
            Self.request(
                "GET",
                "/api/sessions",
                headerFields: [
                    ("authorization", "Bearer first"),
                    ("authorization", "Bearer second"),
                    ("cookie", cookie),
                ]
            ),
            at: Self.now
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(duplicated.status == 401)
        #expect(try Self.error(duplicated).code == "credential_invalid")
    }

    @Test func malformedNativeAndAmbiguousCookieFailuresDoNotDriveBrowserLimiter() throws {
        let limiter = RemoteAccessRateLimiter(maximumFailures: 2, windowDuration: 60, lockoutDuration: 300)
        let identity = "owner@example.com"
        let (handler, store, audit) = Self.makeHandler(
            authLimiter: limiter,
            nativeIdentityForTesting: identity
        )
        let validBrowserCookie = Self.pairedDeviceCookie(store)
        let native = try Self.nativeCredential(handler: handler, store: store, identity: identity)

        let nonCountingRequests: [RemoteGatewayHTTPRequest] = [
            Self.request("GET", "/api/sessions"),
            Self.request("GET", "/api/sessions", cookie: "unrelated=value"),
            Self.request("GET", "/api/sessions", cookie: "\(RemoteGatewayProtocol.credentialCookieName)="),
            Self.request(
                "GET",
                "/api/sessions",
                headerFields: [
                    ("cookie", "\(RemoteGatewayProtocol.credentialCookieName)=first"),
                    ("cookie", "\(RemoteGatewayProtocol.credentialCookieName)=second"),
                ]
            ),
            Self.request(
                "GET",
                "/api/sessions",
                cookie: "\(RemoteGatewayProtocol.credentialCookieName)=first; \(RemoteGatewayProtocol.credentialCookieName)=second"
            ),
            Self.request(
                "GET",
                "/api/sessions",
                headerFields: [
                    ("authorization", "Bearer"),
                    ("cookie", validBrowserCookie),
                ]
            ),
            Self.request(
                "GET",
                "/api/sessions",
                headerFields: [
                    ("authorization", "Bearer first"),
                    ("authorization", "Bearer second"),
                    ("cookie", validBrowserCookie),
                ]
            ),
            Self.request(
                "GET",
                "/api/sessions",
                headerFields: [
                    ("authorization", "Bearer \(String(repeating: "a", count: 43))"),
                    ("tailscale-user-login", identity),
                ]
            ),
        ]
        for (offset, request) in nonCountingRequests.enumerated() {
            guard case .respond(let response) = handler.handle(
                request,
                at: Self.now.addingTimeInterval(Double(offset + 1))
            ) else {
                Issue.record("Expected response")
                continue
            }
            #expect(response.status == 401)
            #expect(try Self.error(response).code == "credential_invalid")
        }

        #expect(try store.revokeDevice(native.device.id, at: Self.now.addingTimeInterval(20)))
        for offset in 0..<3 {
            guard case .respond(let response) = handler.handle(
                Self.request(
                    "GET",
                    "/api/sessions",
                    headerFields: [
                        ("authorization", "Bearer \(native.credential)"),
                        ("tailscale-user-login", identity),
                    ]
                ),
                at: Self.now.addingTimeInterval(Double(21 + offset))
            ) else {
                Issue.record("Expected response")
                continue
            }
            #expect(response.status == 401)
        }

        // A first shape-valid unknown browser token still gets 401, proving
        // the preceding malformed/native failures did not lock the limiter.
        guard case .respond(let firstInvalidBrowser) = handler.handle(
            Self.request(
                "GET",
                "/api/sessions",
                cookie: "\(RemoteGatewayProtocol.credentialCookieName)=invalid-browser-one"
            ),
            at: Self.now.addingTimeInterval(30)
        ), case .respond(let validBrowser) = handler.handle(
            Self.request("GET", "/api/sessions", cookie: validBrowserCookie),
            at: Self.now.addingTimeInterval(31)
        ) else {
            Issue.record("Expected responses")
            return
        }
        #expect(firstInvalidBrowser.status == 401)
        #expect(validBrowser.status == 200)

        _ = handler.handle(
            Self.request(
                "GET",
                "/api/sessions",
                cookie: "\(RemoteGatewayProtocol.credentialCookieName)=invalid-browser-two"
            ),
            at: Self.now.addingTimeInterval(32)
        )
        guard case .respond(let thresholdCrossingFailure) = handler.handle(
            Self.request(
                "GET",
                "/api/sessions",
                cookie: "\(RemoteGatewayProtocol.credentialCookieName)=invalid-browser-three"
            ),
            at: Self.now.addingTimeInterval(33)
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(thresholdCrossingFailure.status == 401)

        guard case .respond(let lockedBrowserFailure) = handler.handle(
            Self.request(
                "GET",
                "/api/sessions",
                cookie: "\(RemoteGatewayProtocol.credentialCookieName)=invalid-browser-four"
            ),
            at: Self.now.addingTimeInterval(34)
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(lockedBrowserFailure.status == 429)
        #expect(audit.recentEntries().filter { $0.action == .authenticationFailed }.count >= nonCountingRequests.count + 5)
    }

    @Test func nativeBearerRejectsHostileOriginButAcceptsAllowlistedOrigin() throws {
        let identity = "owner@example.com"
        let (handler, store, _) = Self.makeHandler()
        let native = try Self.nativeCredential(handler: handler, store: store, identity: identity)
        let authFields = [
            ("authorization", "Bearer \(native.credential)"),
            ("tailscale-user-login", identity),
        ]

        guard case .respond(let hostile) = handler.handle(
            Self.request("GET", "/api/sessions", headerFields: authFields + [("origin", "https://evil.example")]),
            at: Self.now.addingTimeInterval(1)
        ), case .respond(let allowed) = handler.handle(
            Self.request("GET", "/api/sessions", headerFields: authFields + [("origin", Self.origin)]),
            at: Self.now.addingTimeInterval(2)
        ) else {
            Issue.record("Expected responses")
            return
        }
        #expect(hostile.status == 403)
        #expect(allowed.status == 200)
    }

    @Test func nativeBearerDataRouteMatrixAllowsAbsentOriginWithCorrectScopes() throws {
        let identity = "owner@example.com"
        let epoch = RemoteInputEpoch(bindingID: UUID(), counter: 1)
        var sendCount = 0
        let (handler, store, _) = Self.makeHandler(sendHandler: { _, _ in
            sendCount += 1
            return .accepted(epoch: epoch)
        })
        let native = try Self.nativeCredential(handler: handler, store: store, identity: identity)
        let authHeaders = [
            ("authorization", "Bearer \(native.credential)"),
            ("tailscale-user-login", identity),
        ]
        let eventsBody = Data(#"{"conversationID":"11111111-1111-1111-1111-111111111111"}"#.utf8)
        let sendBody = Data(#"{"conversationID":"11111111-1111-1111-1111-111111111111","clientRequestID":"native-r1","expectedInputEpoch":{"bindingID":"22222222-2222-2222-2222-222222222222","counter":1},"text":"hi"}"#.utf8)

        for (method, path, body) in [
            ("GET", "/api/sessions", Data()),
            ("POST", "/api/conversation.events.get", eventsBody),
            ("POST", "/api/conversation.message.send", sendBody),
        ] {
            guard case .respond(let response) = handler.handle(
                Self.request(method, path, headerFields: authHeaders, body: body),
                at: Self.now.addingTimeInterval(1)
            ) else {
                Issue.record("Expected REST response for \(path)")
                continue
            }
            #expect(response.status == 200)
        }
        #expect(sendCount == 1)

        let webSocketHeaders = authHeaders + [
            ("upgrade", "websocket"),
            ("connection", "Upgrade"),
            ("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="),
            ("sec-websocket-version", "13"),
        ]
        guard case .upgradeToWebSocket(let deviceID, _) = handler.handle(
            Self.request("GET", "/api/subscribe", headerFields: webSocketHeaders),
            at: Self.now.addingTimeInterval(2)
        ) else {
            Issue.record("Expected native WebSocket upgrade")
            return
        }
        #expect(deviceID == native.device.id)

        #expect(try store.setScopes([.read], forDevice: native.device.id))
        guard case .respond(let sendDenied) = handler.handle(
            Self.request("POST", "/api/conversation.message.send", headerFields: authHeaders, body: sendBody),
            at: Self.now.addingTimeInterval(3)
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(sendDenied.status == 403)
        #expect(sendCount == 1)
    }

    @Test func webSocketRejectsAmbiguousOrIncompleteUpgradeHeaders() throws {
        let identity = "owner@example.com"
        let (handler, store, _) = Self.makeHandler()
        let native = try Self.nativeCredential(handler: handler, store: store, identity: identity)
        let authHeaders = [
            ("authorization", "Bearer \(native.credential)"),
            ("tailscale-user-login", identity),
        ]
        let invalidUpgradeFields: [[(String, String)]] = [
            [
                ("upgrade", "websocket"), ("upgrade", "websocket"),
                ("connection", "Upgrade"),
                ("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="),
                ("sec-websocket-version", "13"),
            ],
            [
                ("upgrade", "websocket"),
                ("connection", "Upgrade"), ("connection", "Upgrade"),
                ("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="),
                ("sec-websocket-version", "13"),
            ],
            [
                ("upgrade", "websocket"),
                ("connection", "Upgrade"),
                ("sec-websocket-key", "first"), ("sec-websocket-key", "second"),
                ("sec-websocket-version", "13"),
            ],
            [
                ("upgrade", "websocket"),
                ("connection", "Upgrade"),
                ("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="),
                ("sec-websocket-version", "12"),
            ],
        ]
        for fields in invalidUpgradeFields {
            guard case .respond(let response) = handler.handle(
                Self.request("GET", "/api/subscribe", headerFields: authHeaders + fields),
                at: Self.now.addingTimeInterval(1)
            ) else {
                Issue.record("Expected rejected WebSocket upgrade")
                continue
            }
            #expect(response.status == 400)
        }
    }

    @Test func browserCredentialsCannotCrossIntoNativeRoutes() throws {
        let (handler, store, _) = Self.makeHandler()
        let cookie = Self.pairedDeviceCookie(store)
        for (method, path, body) in [
            ("GET", "/v1/native-device", ""),
            ("POST", "/v1/native-device/revoke", #"{"protocolVersion":"1.0"}"#),
        ] {
            guard case .respond(let response) = handler.handle(
                Self.request(method, path, cookie: cookie, body: body),
                at: Self.now
            ) else {
                Issue.record("Expected response")
                continue
            }
            #expect(response.status == 401)
            #expect(try Self.error(response).code == "credential_invalid")
        }
    }

    @Test func nativeCurrentDeviceIsRedactedAndCredentialDateMatchesCreation() throws {
        let identity = "owner@example.com"
        let (handler, store, _) = Self.makeHandler()
        let native = try Self.nativeCredential(handler: handler, store: store, identity: identity)
        guard case .respond(let response) = handler.handle(
            Self.request(
                "GET",
                "/v1/native-device",
                headerFields: [
                    ("authorization", "Bearer \(native.credential)"),
                    ("tailscale-user-login", identity),
                ]
            ),
            at: Self.now.addingTimeInterval(1)
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(response.status == 200)
        let decoded = try ConversationEventCoding.makeDecoder().decode(RemoteGatewayCurrentDeviceResponse.self, from: response.body)
        #expect(decoded.device == native.device)
        #expect(decoded.credentialCreatedAt == Self.now)
        let text = try #require(String(data: response.body, encoding: .utf8))
        #expect(text.contains(native.credential) == false)
        #expect(text.contains(identity) == false)
    }

    @Test func nativeSelfRevokeNotifiesOnlyAfterDurableMutation() throws {
        let identity = "owner@example.com"
        let (handler, store, audit) = Self.makeHandler()
        let native = try Self.nativeCredential(handler: handler, store: store, identity: identity)
        var callbackDeviceID: UUID?
        var credentialRejectedInsideCallback = false
        handler.onDeviceRevoked = { deviceID in
            callbackDeviceID = deviceID
            if case .invalidCredential = store.authenticateNativeBearer(
                native.credential,
                tailscaleLogin: identity,
                at: Self.now.addingTimeInterval(2)
            ) {
                credentialRejectedInsideCallback = true
            }
        }
        let body = try ConversationEventCoding.makeEncoder().encode(RemoteGatewayRevokeCurrentDeviceRequest())
        guard case .respond(let response) = handler.handle(
            Self.request(
                "POST",
                "/v1/native-device/revoke",
                headerFields: [
                    ("authorization", "Bearer \(native.credential)"),
                    ("tailscale-user-login", identity),
                ],
                body: body
            ),
            at: Self.now.addingTimeInterval(1)
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(response.status == 200)
        #expect(callbackDeviceID == native.device.id)
        #expect(credentialRejectedInsideCallback)
        #expect(audit.recentEntries().contains { $0.action == .deviceRevoked && $0.deviceID == native.device.id })
    }

    @Test func failedNativeSelfRevokeDoesNotNotifyOrInvalidateCredential() throws {
        enum ExpectedFailure: Error { case write }
        let writeBudget = PersistenceWriteBudget(1)
        let store = RemoteDeviceStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("remote-revoke-failure-\(UUID().uuidString).json")
        ) { _, _ in
            guard writeBudget.remaining > 0 else { throw ExpectedFailure.write }
            writeBudget.remaining -= 1
        }
        let identity = "owner@example.com"
        let (handler, _, _) = Self.makeHandler(deviceStore: store)
        let native = try Self.nativeCredential(handler: handler, store: store, identity: identity)
        var callbackCount = 0
        handler.onDeviceRevoked = { _ in callbackCount += 1 }
        let body = try ConversationEventCoding.makeEncoder().encode(RemoteGatewayRevokeCurrentDeviceRequest())
        guard case .respond(let response) = handler.handle(
            Self.request(
                "POST",
                "/v1/native-device/revoke",
                headerFields: [
                    ("authorization", "Bearer \(native.credential)"),
                    ("tailscale-user-login", identity),
                ],
                body: body
            ),
            at: Self.now.addingTimeInterval(1)
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(response.status == 500)
        #expect(callbackCount == 0)
        guard case .authenticated = store.authenticateNativeBearer(
            native.credential,
            tailscaleLogin: identity,
            at: Self.now.addingTimeInterval(2)
        ) else {
            Issue.record("Failed revoke must preserve the credential")
            return
        }
    }

    @Test func missingCredentialsDoNotLockOutAPairedDevice() {
        let authLimiter = RemoteAccessRateLimiter(maximumFailures: 2, windowDuration: 60, lockoutDuration: 300)
        let (handler, store, _) = Self.makeHandler(authLimiter: authLimiter)
        let validCookie = Self.pairedDeviceCookie(store)

        for offset in 0..<6 {
            guard case .respond(let response) = handler.handle(
                Self.request("GET", "/api/sessions"),
                at: Self.now.addingTimeInterval(Double(offset))
            ) else {
                Issue.record("Expected response")
                return
            }
            #expect(response.status == 401)
        }

        guard case .respond(let validResponse) = handler.handle(
            Self.request("GET", "/api/sessions", cookie: validCookie),
            at: Self.now.addingTimeInterval(10)
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(validResponse.status == 200)
    }

    @Test func validCredentialBypassesInvalidCredentialLockout() {
        let authLimiter = RemoteAccessRateLimiter(maximumFailures: 2, windowDuration: 60, lockoutDuration: 300)
        let (handler, store, _) = Self.makeHandler(authLimiter: authLimiter)
        let validCookie = Self.pairedDeviceCookie(store)

        for offset in 0..<3 {
            _ = handler.handle(
                Self.request(
                    "GET",
                    "/api/sessions",
                    cookie: "\(RemoteGatewayProtocol.credentialCookieName)=invalid-\(offset)"
                ),
                at: Self.now.addingTimeInterval(Double(offset))
            )
        }

        guard case .respond(let lockedInvalid) = handler.handle(
            Self.request(
                "GET",
                "/api/sessions",
                cookie: "\(RemoteGatewayProtocol.credentialCookieName)=still-invalid"
            ),
            at: Self.now.addingTimeInterval(4)
        ), case .respond(let validResponse) = handler.handle(
            Self.request("GET", "/api/sessions", cookie: validCookie),
            at: Self.now.addingTimeInterval(5)
        ) else {
            Issue.record("Expected responses")
            return
        }
        #expect(lockedInvalid.status == 429)
        #expect(validResponse.status == 200)
    }

    @Test func pairingPersistenceFailureReturnsServerErrorWithoutConsumingCode() {
        enum ExpectedFailure: Error { case write }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-pairing-failure-\(UUID().uuidString).json")
        let store = RemoteDeviceStore(fileURL: fileURL) { _, _ in
            throw ExpectedFailure.write
        }
        let (handler, _, _) = Self.makeHandler(deviceStore: store)
        let code = store.issuePairingCode(at: Self.now)

        guard case .respond(let response) = handler.handle(
            Self.request(
                "POST",
                "/api/pair",
                origin: Self.origin,
                body: #"{"code":"\#(code.code)","deviceName":"Phone"}"#
            ),
            at: Self.now
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(response.status == 500)
        #expect(store.devices.isEmpty)
        #expect(store.hasActivePairingCode)
    }

    @Test func revokedDeviceCredentialStopsWorking() throws {
        let (handler, store, _) = Self.makeHandler()
        let cookie = Self.pairedDeviceCookie(store)
        try store.revokeAllDevices(at: Self.now.addingTimeInterval(1))
        guard case .respond(let response) = handler.handle(
            Self.request("GET", "/api/sessions", cookie: cookie),
            at: Self.now.addingTimeInterval(2)
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(response.status == 401)
    }

    @Test func subscribeUpgradesToWebSocket() throws {
        let (handler, store, audit) = Self.makeHandler()
        let cookie = Self.pairedDeviceCookie(store)
        let outcome = handler.handle(
            Self.request(
                "GET",
                "/api/subscribe",
                origin: Self.origin,
                cookie: cookie,
                extraHeaders: [
                    "upgrade": "websocket",
                    "connection": "Upgrade",
                    "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==",
                    "sec-websocket-version": "13",
                ]
            ),
            at: Self.now
        )
        guard case .upgradeToWebSocket(let deviceID, let upgradeData) = outcome else {
            Issue.record("Expected upgrade, got \(outcome)")
            return
        }
        #expect(store.devices.first?.id == deviceID)
        let upgradeText = try #require(String(data: upgradeData, encoding: .utf8))
        #expect(upgradeText.contains("101 Switching Protocols"))
        #expect(upgradeText.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
        #expect(audit.recentEntries().contains { $0.action == .sessionSubscribed })
    }

    @Test func eventsEndpointRequiresOriginAndCredential() {
        let (handler, store, _) = Self.makeHandler()
        let cookie = Self.pairedDeviceCookie(store)
        let body = #"{"conversationID":"11111111-1111-1111-1111-111111111111"}"#

        guard case .respond(let noOrigin) = handler.handle(
            Self.request("POST", "/api/conversation.events.get", cookie: cookie, body: body),
            at: Self.now
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(noOrigin.status == 403)

        guard case .respond(let noAuth) = handler.handle(
            Self.request("POST", "/api/conversation.events.get", origin: Self.origin, body: body),
            at: Self.now
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(noAuth.status == 401)
    }

    @Test func eventsEndpointReturnsFacadeOutcomes() throws {
        let conversationID = RemoteConversationID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let page = ConversationEventPage(
            conversationID: conversationID,
            projectionRunID: RemoteProjectionRunID(),
            projectionGeneration: 1,
            events: [
                ConversationEvent(
                    conversationID: conversationID,
                    sequence: 1,
                    eventID: "codex:test",
                    timestamp: Self.now,
                    provider: .codex,
                    payload: .userMessage(ConversationUserMessagePayload(text: "hi"))
                ),
            ],
            latestSequence: 1
        )
        let decoder = ConversationEventCoding.makeDecoder()
        let body = #"{"conversationID":"11111111-1111-1111-1111-111111111111","limit":50}"#

        for (outcome, expectation) in [
            (ConversationEventPageOutcome.page(page), RemoteGatewayEventsResponse.page(page)),
            (.resnapshotRequired, .resnapshotRequired),
            (.conversationNotFound, .conversationNotFound),
        ] {
            let (handler, store, _) = Self.makeHandler(eventsOutcome: outcome)
            let cookie = Self.pairedDeviceCookie(store)
            guard case .respond(let response) = handler.handle(
                Self.request("POST", "/api/conversation.events.get", origin: Self.origin, cookie: cookie, body: body),
                at: Self.now
            ) else {
                Issue.record("Expected response")
                return
            }
            #expect(response.status == 200)
            let decoded = try decoder.decode(RemoteGatewayEventsResponse.self, from: response.body)
            #expect(decoded == expectation)
        }
    }

    @Test func eventsEndpointAcceptsExplicitBackwardAnchorsAndRejectsAmbiguity() throws {
        let conversationID = RemoteConversationID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let runID = RemoteProjectionRunID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        let page = ConversationEventPage(
            conversationID: conversationID,
            projectionRunID: runID,
            projectionGeneration: 7,
            events: [],
            latestSequence: 12,
            firstAvailableSequence: 1,
            historyTruncated: false
        )
        let (handler, store, _) = Self.makeHandler(eventsOutcome: .page(page))
        let cookie = Self.pairedDeviceCookie(store)
        let validBodies = [
            #"{"backward":{"anchor":"latest"},"conversationID":"11111111-1111-1111-1111-111111111111","limit":50}"#,
            #"{"backward":{"anchor":"latest","future":true},"conversationID":"11111111-1111-1111-1111-111111111111","limit":50}"#,
            #"{"backward":{"anchor":"before","cursor":{"beforeSequence":10,"projectionGeneration":7,"projectionRunID":"22222222-2222-2222-2222-222222222222"}},"conversationID":"11111111-1111-1111-1111-111111111111","limit":50}"#,
        ]
        for body in validBodies {
            guard case .respond(let response) = handler.handle(
                Self.request("POST", "/api/conversation.events.get", origin: Self.origin, cookie: cookie, body: body),
                at: Self.now
            ) else {
                Issue.record("Expected backward response")
                return
            }
            #expect(response.status == 200)
        }

        let invalidBodies = [
            #"{"backward":null,"conversationID":"11111111-1111-1111-1111-111111111111","limit":50}"#,
            #"{"backward":{"anchor":"latest"},"conversationID":"11111111-1111-1111-1111-111111111111"}"#,
            #"{"backward":{"anchor":"latest","cursor":null},"conversationID":"11111111-1111-1111-1111-111111111111","limit":50}"#,
            #"{"backward":{"anchor":"latest"},"conversationID":"11111111-1111-1111-1111-111111111111","cursor":null,"limit":50}"#,
            #"{"backward":{"anchor":"before"},"conversationID":"11111111-1111-1111-1111-111111111111","limit":50}"#,
            #"{"backward":{"anchor":"latest"},"conversationID":"11111111-1111-1111-1111-111111111111","cursor":{"afterSequence":1,"projectionGeneration":7,"projectionRunID":"22222222-2222-2222-2222-222222222222"},"limit":50}"#,
            #"{"backward":{"anchor":"latest"},"conversationID":"11111111-1111-1111-1111-111111111111","limit":0}"#,
            #"{"backward":{"anchor":"latest"},"conversationID":"11111111-1111-1111-1111-111111111111","limit":201}"#,
        ]
        for body in invalidBodies {
            guard case .respond(let response) = handler.handle(
                Self.request("POST", "/api/conversation.events.get", origin: Self.origin, cookie: cookie, body: body),
                at: Self.now
            ) else {
                Issue.record("Expected invalid request response")
                return
            }
            #expect(response.status == 400)
            #expect(try Self.error(response).code == "invalid_body")
        }
    }

    @Test func streamMessagesForEventsAndResnapshotRoundTrip() throws {
        let conversationID = RemoteConversationID()
        let page = ConversationEventPage(
            conversationID: conversationID,
            projectionRunID: RemoteProjectionRunID(),
            projectionGeneration: 0,
            events: [],
            latestSequence: 12
        )
        let encoder = ConversationEventCoding.makeEncoder()
        let decoder = ConversationEventCoding.makeDecoder()

        let eventsData = try encoder.encode(RemoteGatewayStreamMessage.conversationEvents(page))
        let eventsJSON = try #require(String(data: eventsData, encoding: .utf8))
        #expect(eventsJSON.contains(#""type":"conversation_events""#))
        #expect(try decoder.decode(RemoteGatewayStreamMessage.self, from: eventsData) == .conversationEvents(page))

        let resnapshotData = try encoder.encode(RemoteGatewayStreamMessage.resnapshotRequired(conversationID: conversationID))
        let resnapshotJSON = try #require(String(data: resnapshotData, encoding: .utf8))
        #expect(resnapshotJSON.contains(#""type":"resnapshot_required""#))
        #expect(try decoder.decode(RemoteGatewayStreamMessage.self, from: resnapshotData)
            == .resnapshotRequired(conversationID: conversationID))
    }

    @Test func messageSendRequiresSendScopeBeforeReachingHandler() throws {
        let epoch = RemoteInputEpoch(bindingID: UUID(), counter: 1)
        var handlerCalled = false
        let (handler, store, audit) = Self.makeHandler(sendHandler: { _, _ in
            handlerCalled = true
            return .accepted(epoch: epoch)
        })
        let cookie = Self.pairedDeviceCookie(store)
        // Explicitly remove the default send scope to exercise the gate.
        #expect(try store.setScopes([.read], forDevice: store.devices[0].id))
        let body = #"{"conversationID":"11111111-1111-1111-1111-111111111111","clientRequestID":"r1","expectedInputEpoch":{"bindingID":"\#(UUID().uuidString)","counter":1},"text":"hi"}"#
        guard case .respond(let response) = handler.handle(
            Self.request("POST", "/api/conversation.message.send", origin: Self.origin, cookie: cookie, body: body),
            at: Self.now
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(response.status == 403)
        #expect(handlerCalled == false)
        #expect(audit.recentEntries().contains { $0.action == .remoteSendRejected })
    }

    @Test func messageSendForwardsToHandlerWithSendScope() throws {
        let epoch = RemoteInputEpoch(bindingID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, counter: 4)
        var received: RemoteMessageSendRequest?
        let (handler, store, audit) = Self.makeHandler(sendHandler: { request, _ in
            received = request
            return .accepted(epoch: epoch)
        })
        // A freshly paired device can send without an additional grant.
        let cookie = Self.pairedDeviceCookie(store)

        let body = #"{"conversationID":"11111111-1111-1111-1111-111111111111","clientRequestID":"r7","expectedInputEpoch":{"bindingID":"22222222-2222-2222-2222-222222222222","counter":4},"text":"deploy please"}"#
        guard case .respond(let response) = handler.handle(
            Self.request("POST", "/api/conversation.message.send", origin: Self.origin, cookie: cookie, body: body),
            at: Self.now
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(response.status == 200)
        #expect(received?.clientRequestID == "r7")
        #expect(received?.text == "deploy please")
        let decoded = try ConversationEventCoding.makeDecoder().decode(RemoteMessageSendResult.self, from: response.body)
        #expect(decoded == .accepted(epoch: epoch))
        #expect(audit.recentEntries().contains { $0.action == .remoteSendAccepted })
    }

    @Test func messageSendRejectionIsReported200WithReason() throws {
        let (handler, store, _) = Self.makeHandler(sendHandler: { _, _ in
            .rejected(reason: .epochMismatch)
        })
        let cookie = Self.pairedDeviceCookie(store)
        try store.setScopes([.read, .send], forDevice: store.devices[0].id)
        let body = #"{"conversationID":"11111111-1111-1111-1111-111111111111","clientRequestID":"r1","expectedInputEpoch":{"bindingID":"22222222-2222-2222-2222-222222222222","counter":1},"text":"hi"}"#
        guard case .respond(let response) = handler.handle(
            Self.request("POST", "/api/conversation.message.send", origin: Self.origin, cookie: cookie, body: body),
            at: Self.now
        ) else {
            Issue.record("Expected response")
            return
        }
        // A stale-epoch rejection is a normal outcome, not a transport error.
        #expect(response.status == 200)
        let decoded = try ConversationEventCoding.makeDecoder().decode(RemoteMessageSendResult.self, from: response.body)
        #expect(decoded == .rejected(reason: .epochMismatch))
    }

    @Test func messageSendUncertaintyIsReported200AndAudited() throws {
        let (handler, store, audit) = Self.makeHandler(sendHandler: { _, _ in .uncertain })
        let cookie = Self.pairedDeviceCookie(store)
        try store.setScopes([.read, .send], forDevice: store.devices[0].id)
        let body = #"{"conversationID":"11111111-1111-1111-1111-111111111111","clientRequestID":"r1","expectedInputEpoch":{"bindingID":"22222222-2222-2222-2222-222222222222","counter":1},"text":"hi"}"#
        guard case .respond(let response) = handler.handle(
            Self.request("POST", "/api/conversation.message.send", origin: Self.origin, cookie: cookie, body: body),
            at: Self.now
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(response.status == 200)
        let decoded = try ConversationEventCoding.makeDecoder().decode(RemoteMessageSendResult.self, from: response.body)
        #expect(decoded == .uncertain)
        #expect(audit.recentEntries().contains { $0.action == .remoteSendUncertain })
    }

    @Test func messageSendReturns404WhenNotWired() throws {
        let (handler, store, _) = Self.makeHandler(sendHandler: nil)
        let cookie = Self.pairedDeviceCookie(store)
        try store.setScopes([.read, .send], forDevice: store.devices[0].id)
        let body = #"{"conversationID":"11111111-1111-1111-1111-111111111111","clientRequestID":"r1","expectedInputEpoch":{"bindingID":"22222222-2222-2222-2222-222222222222","counter":1},"text":"hi"}"#
        guard case .respond(let response) = handler.handle(
            Self.request("POST", "/api/conversation.message.send", origin: Self.origin, cookie: cookie, body: body),
            at: Self.now
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(response.status == 404)
    }

    @Test func subscribeWithoutOriginOrUpgradeIsRejected() {
        let (handler, store, _) = Self.makeHandler()
        let cookie = Self.pairedDeviceCookie(store)

        guard case .respond(let noOrigin) = handler.handle(
            Self.request("GET", "/api/subscribe", cookie: cookie),
            at: Self.now
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(noOrigin.status == 403)

        guard case .respond(let notUpgrade) = handler.handle(
            Self.request("GET", "/api/subscribe", origin: Self.origin, cookie: cookie),
            at: Self.now
        ) else {
            Issue.record("Expected response")
            return
        }
        #expect(notUpgrade.status == 400)
    }
}
