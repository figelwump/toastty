import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyAppLogic

/// Server-initiated WebSocket close coverage with an RFC 6455 client of our
/// own. The shared gateway tests that wait for a peer close through
/// swift-corelibs `URLSessionWebSocketTask` never see it on Linux (its
/// `receive()` does not complete after a server close frame), so they are
/// disabled there and these cover the same gateway behavior.
@MainActor
@Suite(.serialized)
struct LinuxGatewayWebSocketTests {
    private struct EmptyFacade: RemoteSessionFacade {
        func sessionList(at date: Date) -> RemoteSessionListSnapshot {
            RemoteSessionListSnapshot(projectionRunID: RemoteProjectionRunID(), conversations: [], generatedAt: date)
        }

        func conversationSnapshot(for conversationID: RemoteConversationID, at date: Date) -> RemoteConversationSnapshot? { nil }

        func conversationEvents(
            for conversationID: RemoteConversationID,
            after cursor: ConversationEventCursor?,
            limit: Int
        ) -> ConversationEventPageOutcome {
            .conversationNotFound
        }
    }

    private func startServer() async throws -> (RemoteAccessGatewayServer, RemoteDeviceStore, UInt16) {
        let port = try LinuxTestSupport.freeLoopbackPort()
        let deviceStore = RemoteDeviceStore(fileURL: nil)
        let handler = RemoteGatewayRequestHandler(
            deviceStore: deviceStore,
            auditLog: RemoteAccessAuditLog(fileURL: nil),
            facade: EmptyFacade(),
            configuration: RemoteGatewayConfiguration(allowedOrigins: [])
        )
        let server = RemoteAccessGatewayServer(handler: handler)
        var ready = false
        server.onListenerReady = { _ in ready = true }
        try server.start(port: port)
        try await LinuxTestSupport.waitUntil("listener") { ready }
        return (server, deviceStore, port)
    }

    private func pair(_ deviceStore: RemoteDeviceStore, port: UInt16, name: String, login: String) async throws -> String {
        let offer = try deviceStore.issueNativePairingOffer(gatewayURL: URL(string: "https://toastty-test.tailnet.ts.net")!, at: Date())
        let body = try ConversationEventCoding.makeEncoder().encode(
            RemoteGatewayNativePairingExchangeRequest(deviceName: name, offerID: offer.id, secret: offer.qrPayload.secret)
        )
        let response = try await RawHTTPClient(port: port).request(
            "POST /v1/native-pairing/exchange",
            headers: ["Tailscale-User-Login": login, "Content-Type": "application/json"],
            body: body
        )
        #expect(response.status == 200)
        return try ConversationEventCoding.makeDecoder()
            .decode(RemoteGatewayNativePairingExchangeResponse.self, from: response.body).credential
    }

    @Test func revokingADeviceClosesItsSocketsWithPolicyViolationAndKeepsOthers() async throws {
        let (server, deviceStore, port) = try await startServer()
        defer { server.stop() }
        let firstCredential = try await pair(deviceStore, port: port, name: "First phone", login: "first@example.com")
        let secondCredential = try await pair(deviceStore, port: port, name: "Second phone", login: "second@example.com")
        let firstDeviceID = try #require(deviceStore.devices.first { $0.name == "First phone" }?.id)

        func subscribe(_ credential: String, _ login: String) async throws -> RawWebSocketClient {
            try await RawWebSocketClient.connect(
                port: port,
                path: "/api/subscribe",
                headers: ["Authorization": "Bearer \(credential)", "Tailscale-User-Login": login]
            )
        }
        let firstSockets = [
            try await subscribe(firstCredential, "first@example.com"),
            try await subscribe(firstCredential, "first@example.com"),
        ]
        let second = try await subscribe(secondCredential, "second@example.com")
        defer { (firstSockets + [second]).forEach { $0.close() } }
        try await LinuxTestSupport.waitUntil("three sockets") { server.webSocketClientCount == 3 }

        #expect(try deviceStore.revokeDevice(firstDeviceID, at: Date()))
        server.disconnectWebSockets(for: firstDeviceID)
        for socket in firstSockets {
            #expect(try await socket.receiveFrame() == .close(code: 1008))
        }
        #expect(server.webSocketClientCount == 1)

        server.broadcast(.sessionList(EmptyFacade().sessionList(at: Date())))
        guard case .text(let text) = try await second.receiveFrame() else {
            Issue.record("expected the other device to stay subscribed")
            return
        }
        #expect(text.contains("session_list"))

        server.disconnectAllWebSockets()
        #expect(try await second.receiveFrame() == .close(code: 1008))
    }
}
