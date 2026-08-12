import RemoteProtocol
import CoreState
import Foundation
import Network
import Testing
@testable import ToasttyApp

@MainActor
struct RemoteAccessGatewayServerTests {
    private struct FixedFacade: RemoteSessionFacade {
        let snapshot: RemoteSessionListSnapshot

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
            .conversationNotFound
        }
    }

    private struct Harness {
        let server: RemoteAccessGatewayServer
        let deviceStore: RemoteDeviceStore
        let auditLog: RemoteAccessAuditLog
        let port: UInt16
        let origin: String

        var baseURL: URL {
            URL(string: "http://127.0.0.1:\(port)")!
        }
    }

    private struct NativePairing {
        var credential: String
        var offer: RemoteNativePairingOffer
        var tailscaleLogin: String
    }

    private static func makeSnapshot() -> RemoteSessionListSnapshot {
        RemoteSessionListSnapshot(
            projectionRunID: RemoteProjectionRunID(),
            conversations: [
                RemoteConversationSummary(
                    conversationID: RemoteConversationID(),
                    provider: .codex,
                    title: "Demo session",
                    placement: RemoteConversationPlacement(workspaceID: UUID(), workspaceTitle: "Workspace 1", panelID: UUID()),
                    cwd: "/tmp/demo",
                    state: .working,
                    inputAvailability: .unavailable(reason: .unknownProviderState),
                    latestSequence: 0,
                    updatedAt: Date(timeIntervalSince1970: 1_786_300_000)
                ),
            ],
            generatedAt: Date(timeIntervalSince1970: 1_786_300_000)
        )
    }

    private static func startHarness(
        maximumConnections: Int = RemoteAccessGatewayServer.defaultMaximumConnections,
        requestHeaderTimeoutNanoseconds: UInt64 = RemoteAccessGatewayServer.defaultRequestHeaderTimeoutNanoseconds
    ) throws -> Harness {
        let deviceStore = RemoteDeviceStore(fileURL: nil)
        var port: UInt16 = 0
        var lastError: Error?
        for _ in 0..<10 {
            let candidate = UInt16.random(in: 49500..<64000)
            let origin = "http://127.0.0.1:\(candidate)"
            let auditLog = RemoteAccessAuditLog(fileURL: nil)
            let handler = RemoteGatewayRequestHandler(
                deviceStore: deviceStore,
                auditLog: auditLog,
                facade: FixedFacade(snapshot: makeSnapshot()),
                configuration: RemoteGatewayConfiguration(
                    allowedOrigins: [origin],
                    staticResources: [
                        "/index.html": RemoteGatewayStaticResource(
                            contentType: "text/html; charset=utf-8",
                            data: Data("<html>remote</html>".utf8)
                        ),
                    ]
                )
            )
            let server = RemoteAccessGatewayServer(
                handler: handler,
                maximumConnections: maximumConnections,
                requestHeaderTimeoutNanoseconds: requestHeaderTimeoutNanoseconds
            )
            do {
                try server.start(port: candidate)
                port = candidate
                return Harness(
                    server: server,
                    deviceStore: deviceStore,
                    auditLog: auditLog,
                    port: port,
                    origin: origin
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? RemoteAccessGatewayServer.ServerError.invalidPort
    }

    private static func awaitListening(_ harness: Harness) async throws {
        var request = URLRequest(url: harness.baseURL.appending(path: "/"))
        request.timeoutInterval = 2
        for _ in 0..<40 {
            do {
                _ = try await URLSession.shared.data(for: request)
                return
            } catch {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        Issue.record("Server never became reachable on port \(harness.port)")
    }

    private static func pairDevice(_ harness: Harness, name: String = "Test phone") async throws -> String {
        let code = harness.deviceStore.issuePairingCode(at: Date())
        var request = URLRequest(url: harness.baseURL.appending(path: "/api/pair"))
        request.httpMethod = "POST"
        request.setValue(harness.origin, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ConversationEventCoding.makeEncoder().encode(RemoteGatewayPairRequest(
            code: code.code,
            deviceName: name
        ))
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        let setCookie = try #require(http.value(forHTTPHeaderField: "Set-Cookie"))
        let token = try #require(
            setCookie.split(separator: ";").first?
                .split(separator: "=", maxSplits: 1).last
                .map(String.init)
        )
        return "\(RemoteGatewayProtocol.credentialCookieName)=\(token)"
    }

    private static func pairNativeDevice(
        _ harness: Harness,
        name: String = "Native phone",
        tailscaleLogin: String = "person@example.com"
    ) async throws -> NativePairing {
        let offer = try harness.deviceStore.issueNativePairingOffer(
            gatewayURL: URL(string: "https://toastty-test.tailnet.ts.net")!,
            at: Date()
        )
        var request = URLRequest(url: harness.baseURL.appending(path: "/v1/native-pairing/exchange"))
        request.httpMethod = "POST"
        request.setValue(tailscaleLogin, forHTTPHeaderField: "Tailscale-User-Login")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ConversationEventCoding.makeEncoder().encode(
            RemoteGatewayNativePairingExchangeRequest(
                deviceName: name,
                offerID: offer.id,
                secret: offer.qrPayload.secret
            )
        )
        // Keep the trusted-loopback native transport fixture independent from
        // the process-wide cookie jar. A browser credential from an earlier
        // test must not change native Bearer authentication precedence.
        let session = cookieFreeEphemeralSession()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let credential = try ConversationEventCoding.makeDecoder().decode(
            RemoteGatewayNativePairingExchangeResponse.self,
            from: data
        ).credential
        return NativePairing(
            credential: credential,
            offer: offer,
            tailscaleLogin: tailscaleLogin
        )
    }

    private static func cookieFreeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }

    private static func expectPolicyClose(_ sockets: [URLSessionWebSocketTask]) async throws {
        for socket in sockets {
            do {
                _ = try await socket.receive()
                Issue.record("Expected the WebSocket receive loop to terminate")
            } catch {
                // URLSession reports a peer close by terminating the active
                // receive. The exact close code remains the assertion below,
                // so a transport reset cannot satisfy this helper.
            }
            #expect(socket.closeCode == URLSessionWebSocketTask.CloseCode.policyViolation)
        }
    }

    @Test func servesStaticClientAndSessionListOverTCP() async throws {
        let harness = try Self.startHarness()
        defer { harness.server.stop() }
        try await Self.awaitListening(harness)

        // Static index.
        let (indexData, indexResponse) = try await URLSession.shared.data(from: harness.baseURL)
        #expect((indexResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: indexData, encoding: .utf8) == "<html>remote</html>")

        // Unauthenticated session list is rejected.
        var unauthenticated = URLRequest(url: harness.baseURL.appending(path: "/api/sessions"))
        unauthenticated.setValue(nil, forHTTPHeaderField: "Cookie")
        let (_, unauthenticatedResponse) = try await URLSession.shared.data(for: unauthenticated)
        #expect((unauthenticatedResponse as? HTTPURLResponse)?.statusCode == 401)

        // Pair, then read the snapshot.
        let cookie = try await Self.pairDevice(harness)
        var authenticated = URLRequest(url: harness.baseURL.appending(path: "/api/sessions"))
        authenticated.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (sessionData, sessionResponse) = try await URLSession.shared.data(for: authenticated)
        #expect((sessionResponse as? HTTPURLResponse)?.statusCode == 200)
        let decoded = try ConversationEventCoding.makeDecoder().decode(RemoteGatewaySessionListResponse.self, from: sessionData)
        #expect(decoded.snapshot.conversations.first?.title == "Demo session")
    }

    @Test func webSocketSubscribeReceivesBroadcasts() async throws {
        let harness = try Self.startHarness()
        defer { harness.server.stop() }
        try await Self.awaitListening(harness)
        let cookie = try await Self.pairDevice(harness)

        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(harness.port)/api/subscribe")!)
        request.setValue(harness.origin, forHTTPHeaderField: "Origin")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        // Wait until the server registers the subscriber, then broadcast.
        for _ in 0..<40 where harness.server.webSocketClientCount == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(harness.server.webSocketClientCount == 1)
        harness.server.broadcast(.sessionList(Self.makeSnapshot()))

        let message = try await socket.receive()
        guard case .string(let text) = message else {
            Issue.record("Expected text frame, got \(message)")
            return
        }
        let decoded = try ConversationEventCoding.makeDecoder().decode(
            RemoteGatewayStreamMessage.self,
            from: Data(text.utf8)
        )
        guard case .sessionList(let snapshot) = decoded else {
            Issue.record("Expected session list message")
            return
        }
        #expect(snapshot.conversations.first?.title == "Demo session")
    }

    /// Loopback transport coverage only. Local processes are inside the host
    /// trust boundary and can forge Serve headers; this does not substitute
    /// for the separate live Tailscale Serve identity validation.
    @Test func loopbackNativeBearerAuthenticatesRESTAndWebSocketWithoutBrowserOrigin() async throws {
        let harness = try Self.startHarness()
        defer { harness.server.stop() }
        try await Self.awaitListening(harness)
        let login = "native-person@example.com"
        let pairing = try await Self.pairNativeDevice(harness, tailscaleLogin: login)
        let credential = pairing.credential

        var sessions = URLRequest(url: harness.baseURL.appending(path: "/api/sessions"))
        sessions.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        sessions.setValue(login, forHTTPHeaderField: "Tailscale-User-Login")
        let (data, response) = try await URLSession.shared.data(for: sessions)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try ConversationEventCoding.makeDecoder().decode(
            RemoteGatewaySessionListResponse.self,
            from: data
        ).snapshot.conversations.first?.title == "Demo session")

        var subscribe = URLRequest(url: URL(string: "ws://127.0.0.1:\(harness.port)/api/subscribe")!)
        subscribe.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        subscribe.setValue(login, forHTTPHeaderField: "Tailscale-User-Login")
        let socket = URLSession.shared.webSocketTask(with: subscribe)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        for _ in 0..<40 where harness.server.webSocketClientCount == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(harness.server.webSocketClientCount == 1)
        harness.server.broadcast(.sessionList(Self.makeSnapshot()))
        guard case .string = try await socket.receive() else {
            Issue.record("Expected native Bearer WebSocket stream")
            return
        }
    }

    @Test func nativeGatewayAuditOmitsCredentialsOfferIdentityAndConversationContent() async throws {
        let harness = try Self.startHarness()
        defer { harness.server.stop() }
        try await Self.awaitListening(harness)
        let pairing = try await Self.pairNativeDevice(
            harness,
            name: "Native phone",
            tailscaleLogin: "secret-login@example.com"
        )

        var sessions = URLRequest(url: harness.baseURL.appending(path: "/api/sessions"))
        sessions.setValue("Bearer \(pairing.credential)", forHTTPHeaderField: "Authorization")
        sessions.setValue(pairing.tailscaleLogin, forHTTPHeaderField: "Tailscale-User-Login")
        _ = try await URLSession.shared.data(for: sessions)

        let encodedAudit = try String(
            decoding: ConversationEventCoding.makeEncoder().encode(harness.auditLog.recentEntries()),
            as: UTF8.self
        )
        let forbiddenValues = [
            pairing.credential,
            pairing.offer.id.uuidString,
            pairing.offer.qrPayload.secret,
            pairing.offer.fallbackCode,
            pairing.tailscaleLogin,
            pairing.offer.qrPayload.gatewayURL.host ?? "toastty-test.tailnet.ts.net",
            "/tmp/demo",
            "Demo session",
            "prompt contents",
            "transcript contents",
        ]
        for value in forbiddenValues {
            #expect(encodedAudit.contains(value) == false)
        }
    }

    /// Exercises the real handler callback -> deferred server sweep path over
    /// loopback. The trusted-local header caveat from the test above applies.
    @Test func loopbackNativeSelfRevokeRespondsThenSweepsEveryDeviceSocket() async throws {
        let harness = try Self.startHarness()
        defer { harness.server.stop() }
        try await Self.awaitListening(harness)
        let login = "self-revoke@example.com"
        let credential = try await Self.pairNativeDevice(harness, tailscaleLogin: login).credential
        let sockets = (0..<2).map { _ in
            Self.makeNativeWebSocket(harness, credential: credential, tailscaleLogin: login)
        }
        sockets.forEach { $0.resume() }
        defer {
            sockets.forEach {
                $0.cancel(with: URLSessionWebSocketTask.CloseCode.goingAway, reason: nil)
            }
        }

        for _ in 0..<40 where harness.server.webSocketClientCount < 2 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(harness.server.webSocketClientCount == 2)

        var revoke = URLRequest(url: harness.baseURL.appending(path: "/v1/native-device/revoke"))
        revoke.httpMethod = "POST"
        revoke.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        revoke.setValue(login, forHTTPHeaderField: "Tailscale-User-Login")
        revoke.setValue("application/json", forHTTPHeaderField: "Content-Type")
        revoke.httpBody = try ConversationEventCoding.makeEncoder().encode(
            RemoteGatewayRevokeCurrentDeviceRequest()
        )
        let (responseData, response) = try await URLSession.shared.data(for: revoke)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let revoked = try ConversationEventCoding.makeDecoder().decode(
            RemoteGatewayRevokeCurrentDeviceResponse.self,
            from: responseData
        )
        #expect(harness.deviceStore.devices.first(where: { $0.id == revoked.revokedDeviceID })?.isRevoked == true)

        try await Self.expectPolicyClose(sockets)
        for _ in 0..<40 where harness.server.webSocketClientCount != 0 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(harness.server.webSocketClientCount == 0)
    }

    @Test func disconnectingDeviceClosesItsActiveWebSocket() async throws {
        let harness = try Self.startHarness()
        defer { harness.server.stop() }
        try await Self.awaitListening(harness)
        let cookie = try await Self.pairDevice(harness)
        let deviceID = try #require(harness.deviceStore.devices.first?.id)

        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(harness.port)/api/subscribe")!)
        request.setValue(harness.origin, forHTTPHeaderField: "Origin")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        for _ in 0..<40 where harness.server.webSocketClientCount == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(harness.server.webSocketClientCount == 1)

        #expect(try harness.deviceStore.revokeDevice(deviceID, at: Date()))
        #expect(try harness.deviceStore.revokeDevice(deviceID, at: Date()) == false)
        harness.server.disconnectWebSockets(for: deviceID)
        try await Self.expectPolicyClose([socket])
        #expect(harness.server.webSocketClientCount == 0)
    }

    @Test func disconnectingDeviceSweepsAllMatchingSocketsAndIsolatesOtherDevice() async throws {
        let harness = try Self.startHarness()
        defer { harness.server.stop() }
        try await Self.awaitListening(harness)
        let firstCookie = try await Self.pairDevice(harness, name: "First phone")
        let firstDeviceID = try #require(harness.deviceStore.devices.first(where: { $0.name == "First phone" })?.id)
        let secondCookie = try await Self.pairDevice(harness, name: "Second phone")

        let firstSockets = (0..<2).map { _ in
            Self.makeWebSocket(harness, cookie: firstCookie)
        }
        let secondSocket = Self.makeWebSocket(harness, cookie: secondCookie)
        let allSockets = firstSockets + [secondSocket]
        allSockets.forEach { $0.resume() }
        defer {
            allSockets.forEach {
                $0.cancel(with: URLSessionWebSocketTask.CloseCode.goingAway, reason: nil)
            }
        }

        for _ in 0..<40 where harness.server.webSocketClientCount < 3 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(harness.server.webSocketClientCount == 3)

        #expect(try harness.deviceStore.revokeDevice(firstDeviceID, at: Date()))
        harness.server.disconnectWebSockets(for: firstDeviceID)
        try await Self.expectPolicyClose(firstSockets)
        #expect(harness.server.webSocketClientCount == 1)

        harness.server.broadcast(.sessionList(Self.makeSnapshot()))
        let message = try await secondSocket.receive()
        guard case .string = message else {
            Issue.record("Expected the other device to remain subscribed")
            return
        }
    }

    @Test func disconnectAllSweepsEveryDeviceSocket() async throws {
        let harness = try Self.startHarness()
        defer { harness.server.stop() }
        try await Self.awaitListening(harness)
        let firstCookie = try await Self.pairDevice(harness, name: "First phone")
        let nativePairing = try await Self.pairNativeDevice(
            harness,
            name: "Native phone",
            tailscaleLogin: "revoke-all@example.com"
        )
        let sockets = [
            Self.makeWebSocket(harness, cookie: firstCookie),
            Self.makeWebSocket(harness, cookie: firstCookie),
            Self.makeNativeWebSocket(
                harness,
                credential: nativePairing.credential,
                tailscaleLogin: nativePairing.tailscaleLogin
            ),
        ]
        sockets.forEach { $0.resume() }
        defer {
            sockets.forEach {
                $0.cancel(with: URLSessionWebSocketTask.CloseCode.goingAway, reason: nil)
            }
        }

        for _ in 0..<40 where harness.server.webSocketClientCount < 3 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(harness.server.webSocketClientCount == 3)

        try harness.deviceStore.revokeAllDevices(at: Date())
        harness.server.disconnectAllWebSockets()
        try await Self.expectPolicyClose(sockets)
        #expect(harness.server.webSocketClientCount == 0)
        let allDevicesRevoked: Bool = harness.deviceStore.devices.allSatisfy(\.isRevoked)
        #expect(allDevicesRevoked)
    }

    @Test func sendScopeDowngradeKeepsReadSocketAliveAndRejectsSendImmediately() async throws {
        let harness = try Self.startHarness()
        defer { harness.server.stop() }
        try await Self.awaitListening(harness)
        let cookie = try await Self.pairDevice(harness)
        let deviceID = try #require(harness.deviceStore.devices.first?.id)
        let socket = Self.makeWebSocket(harness, cookie: cookie)
        socket.resume()
        defer {
            socket.cancel(with: URLSessionWebSocketTask.CloseCode.goingAway, reason: nil)
        }

        for _ in 0..<40 where harness.server.webSocketClientCount == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(harness.server.webSocketClientCount == 1)
        let didUpdateScopes = try harness.deviceStore.setScopes([.read], forDevice: deviceID)
        #expect(didUpdateScopes)

        var send = URLRequest(url: harness.baseURL.appending(path: "/api/conversation.message.send"))
        send.httpMethod = "POST"
        send.setValue(harness.origin, forHTTPHeaderField: "Origin")
        send.setValue(cookie, forHTTPHeaderField: "Cookie")
        send.setValue("application/json", forHTTPHeaderField: "Content-Type")
        send.httpBody = try ConversationEventCoding.makeEncoder().encode(RemoteMessageSendRequest(
            conversationID: RemoteConversationID(),
            clientRequestID: "request-1",
            expectedInputEpoch: RemoteInputEpoch(bindingID: UUID(), counter: 1),
            text: "Do not log this prompt"
        ))
        let (responseData, response) = try await URLSession.shared.data(for: send)
        #expect((response as? HTTPURLResponse)?.statusCode == 403)
        #expect(try ConversationEventCoding.makeDecoder().decode(RemoteMessageSendResult.self, from: responseData) == .rejected(reason: .sendScopeDenied))
        #expect(harness.server.webSocketClientCount == 1)

        harness.server.broadcast(.sessionList(Self.makeSnapshot()))
        guard case .string = try await socket.receive() else {
            Issue.record("Expected read stream to survive a send-scope downgrade")
            return
        }
    }

    @Test func incompletePreAuthRequestIsDroppedAtDeadline() async throws {
        let harness = try Self.startHarness(requestHeaderTimeoutNanoseconds: 100_000_000)
        defer { harness.server.stop() }
        try await Self.awaitListening(harness)

        let connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: harness.port)!,
            using: .tcp
        )
        connection.start(queue: DispatchQueue(label: "remote-access-timeout-test"))
        connection.send(content: Data("GET /api/sessions HTTP/1.1\r\n".utf8), completion: .contentProcessed { _ in })
        defer { connection.cancel() }

        for _ in 0..<40 where harness.server.connectionCountForTesting == 0 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(harness.server.connectionCountForTesting == 1)

        for _ in 0..<40 where harness.server.connectionCountForTesting != 0 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(harness.server.connectionCountForTesting == 0)
    }

    @Test func preAuthConnectionCountIsCapped() async throws {
        let harness = try Self.startHarness(maximumConnections: 1, requestHeaderTimeoutNanoseconds: 2_000_000_000)
        defer { harness.server.stop() }
        try await Self.awaitListening(harness)

        let queue = DispatchQueue(label: "remote-access-cap-test")
        let connections = (0..<3).map { _ in
            NWConnection(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: harness.port)!,
                using: .tcp
            )
        }
        for connection in connections {
            connection.start(queue: queue)
            connection.send(content: Data("GET / HTTP/1.1\r\n".utf8), completion: .contentProcessed { _ in })
        }
        defer { connections.forEach { $0.cancel() } }

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(harness.server.connectionCountForTesting == 1)
    }

    @Test func stopClosesTheListener() async throws {
        let harness = try Self.startHarness()
        try await Self.awaitListening(harness)
        await harness.server.stopAndWaitForListenerCancellation()

        var request = URLRequest(url: harness.baseURL.appending(path: "/"))
        request.timeoutInterval = 1
        do {
            _ = try await URLSession.shared.data(for: request)
            Issue.record("Expected connection failure after stop")
        } catch {
            // Expected: connection refused / cannot connect.
        }
    }

    @Test func stopAndRestartKeepsExistingCredentialValid() async throws {
        let harness = try Self.startHarness()
        defer { harness.server.stop() }
        try await Self.awaitListening(harness)
        let cookie = try await Self.pairDevice(harness)

        await harness.server.stopAndWaitForListenerCancellation()
        try harness.server.start(port: harness.port)
        try await Self.awaitListening(harness)

        var sessions = URLRequest(url: harness.baseURL.appending(path: "/api/sessions"))
        sessions.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (_, response) = try await URLSession.shared.data(for: sessions)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    private static func makeWebSocket(_ harness: Harness, cookie: String) -> URLSessionWebSocketTask {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(harness.port)/api/subscribe")!)
        request.setValue(harness.origin, forHTTPHeaderField: "Origin")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        return URLSession.shared.webSocketTask(with: request)
    }

    private static func makeNativeWebSocket(
        _ harness: Harness,
        credential: String,
        tailscaleLogin: String
    ) -> URLSessionWebSocketTask {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(harness.port)/api/subscribe")!)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue(tailscaleLogin, forHTTPHeaderField: "Tailscale-User-Login")
        return URLSession.shared.webSocketTask(with: request)
    }
}
