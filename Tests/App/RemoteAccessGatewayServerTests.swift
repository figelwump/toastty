import CoreState
import Foundation
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
        let port: UInt16
        let origin: String

        var baseURL: URL {
            URL(string: "http://127.0.0.1:\(port)")!
        }
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

    private static func startHarness() throws -> Harness {
        let deviceStore = RemoteDeviceStore(fileURL: nil)
        var port: UInt16 = 0
        var lastError: Error?
        for _ in 0..<10 {
            let candidate = UInt16.random(in: 49500..<64000)
            let origin = "http://127.0.0.1:\(candidate)"
            let handler = RemoteGatewayRequestHandler(
                deviceStore: deviceStore,
                auditLog: RemoteAccessAuditLog(fileURL: nil),
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
            let server = RemoteAccessGatewayServer(handler: handler)
            do {
                try server.start(port: candidate)
                port = candidate
                return Harness(server: server, deviceStore: deviceStore, port: port, origin: origin)
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

    private static func pairDevice(_ harness: Harness) async throws -> String {
        let code = harness.deviceStore.issuePairingCode(at: Date())
        var request = URLRequest(url: harness.baseURL.appending(path: "/api/pair"))
        request.httpMethod = "POST"
        request.setValue(harness.origin, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"code":"\#(code.code)","deviceName":"Test phone"}"#.utf8)
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

    @Test func stopClosesTheListener() async throws {
        let harness = try Self.startHarness()
        try await Self.awaitListening(harness)
        harness.server.stop()

        var request = URLRequest(url: harness.baseURL.appending(path: "/"))
        request.timeoutInterval = 1
        do {
            _ = try await URLSession.shared.data(for: request)
            Issue.record("Expected connection failure after stop")
        } catch {
            // Expected: connection refused / cannot connect.
        }
    }
}
