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
        sendHandler: RemoteGatewayRequestHandler.SendHandler? = nil
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

    static func pairedDeviceCookie(_ store: RemoteDeviceStore) -> String {
        let code = store.issuePairingCode(at: now)
        guard case .paired(_, let token) = try! store.redeemPairingCode(code.code, deviceName: "Phone", at: now) else {
            fatalError("pairing must succeed")
        }
        return "\(RemoteGatewayProtocol.credentialCookieName)=\(token)"
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
        #expect(hello.capabilities == [.browserCookiePairing])

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
