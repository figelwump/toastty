@testable import CoreState
import Foundation
import RemoteProtocol
import Testing

/// The gateway side of a device's read of the coordinator's chat: the wire
/// contract, the capability and the device checks. The Mac's read point
/// itself is in `CoordinatorChatNewMessagesTests`.
struct RemoteCoordinatorChatReadGatewayTests {
    private typealias Support = RemoteGatewayRequestHandlerTests

    private static let identity = "owner@example.com"
    private static let conversationID = RemoteConversationID(
        rawValue: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    )
    private static let runID = RemoteProjectionRunID(
        rawValue: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    )

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try ConversationEventCoding.makeEncoder().encode(value)
    }

    // MARK: - Codec

    @Test func readPointAndReadRoundTripAndDecodeSafelyFromOtherVersions() throws {
        let decoder = ConversationEventCoding.makeDecoder()
        let time = Date(timeIntervalSince1970: 1_786_406_400.5)
        let point = RemoteCoordinatorChatReadPoint(eventID: "codex:msg_7", timestamp: time)
        #expect(try decoder.decode(RemoteCoordinatorChatReadPoint.self, from: Self.encode(point)) == point)
        // The bytes a phone reads.
        #expect(String(decoding: try Self.encode(point), as: UTF8.self)
            == #"{"eventID":"codex:msg_7","timestamp":"2026-08-11T00:00:00.500Z"}"#)
        // A runtime event's identity does not survive a relaunch, so it is
        // not kept, also when a peer sends one.
        let runtime = Data(#"{"eventID":"rt:2:9","timestamp":"2026-08-11T00:00:00.500Z"}"#.utf8)
        #expect(try decoder.decode(RemoteCoordinatorChatReadPoint.self, from: runtime).eventID == nil)

        let request = RemoteCoordinatorChatReadRequest(
            conversationID: Self.conversationID, eventID: "codex:msg_7",
            projectionRunID: Self.runID, projectionGeneration: 3
        )
        #expect(try decoder.decode(RemoteCoordinatorChatReadRequest.self, from: Self.encode(request)) == request)
        for result in [RemoteCoordinatorChatReadResult.moved, .alreadyRead, .eventNotFound, .noCoordinator] {
            let encoded = try Self.encode(RemoteCoordinatorChatReadResponse(result: result))
            #expect(try decoder.decode(RemoteCoordinatorChatReadResponse.self, from: encoded).result == result)
        }
        let future = Data(#"{"protocolVersion":"1.0","result":"queued_for_later"}"#.utf8)
        #expect(try decoder.decode(RemoteCoordinatorChatReadResponse.self, from: future).result == .unknown)

        // The coordinator's workspace carries the read point. An older Mac
        // omits it, and one this client cannot read is left out.
        let workspace = RemoteWorkspaceSummary(
            id: UUID(), title: "Coordinator", panels: [], isCoordinator: true,
            coordinatorConversationID: Self.conversationID, coordinatorChatRead: point
        )
        #expect(try decoder.decode(RemoteWorkspaceSummary.self, from: Self.encode(workspace)) == workspace)
        let plain = RemoteWorkspaceSummary(id: UUID(), title: "toastty", panels: [])
        #expect(String(decoding: try Self.encode(plain), as: UTF8.self).contains("coordinatorChatRead") == false)
        var object = try #require(try JSONSerialization.jsonObject(with: Self.encode(workspace)) as? [String: Any])
        object["coordinatorChatRead"] = ["eventID": 7]
        let malformed = try JSONSerialization.data(withJSONObject: object)
        let decoded = try decoder.decode(RemoteWorkspaceSummary.self, from: malformed)
        #expect(decoded.coordinatorChatRead == nil)
        #expect(decoded.coordinatorConversationID == Self.conversationID)
    }

    // MARK: - Hello

    @Test func helloAdvertisesTheReadOnlyWithAHandler() throws {
        let (handler, _, _) = Support.makeHandler()
        func capabilities() throws -> [RemoteGatewayCapability] {
            guard case .respond(let response) = handler.handle(
                Support.request("GET", "/api/hello", headerFields: [], body: Data()),
                at: Support.now
            ) else { throw CocoaError(.coderInvalidValue) }
            return try JSONDecoder().decode(RemoteGatewayHelloResponse.self, from: response.body).capabilities
        }
        #expect(try capabilities().contains(.coordinatorChatRead) == false)
        handler.coordinatorChatReadHandler = { _, _ in .moved }
        #expect(try capabilities().contains(.coordinatorChatRead))
    }

    // MARK: - Read

    @Test func aPairedDeviceReadReachesTheHandlerWithReadAccessAlone() throws {
        let (handler, store, _) = Support.makeHandler()
        let native = try Support.nativeCredential(handler: handler, store: store, identity: Self.identity)
        let headers = [("authorization", "Bearer \(native.credential)"), ("tailscale-user-login", Self.identity)]
        let path = RemoteCoordinatorChatReadPolicy.readPath
        func respond(_ body: Data, headers override: [(String, String)]? = nil) throws -> RemoteGatewayHTTPResponse {
            guard case .respond(let response) = handler.handle(
                Support.request("POST", path, headerFields: override ?? headers, body: body),
                at: Support.now
            ) else { throw CocoaError(.coderInvalidValue) }
            return response
        }
        func result(_ response: RemoteGatewayHTTPResponse) throws -> RemoteCoordinatorChatReadResult {
            try ConversationEventCoding.makeDecoder().decode(RemoteCoordinatorChatReadResponse.self, from: response.body).result
        }
        let request = RemoteCoordinatorChatReadRequest(
            conversationID: Self.conversationID, eventID: "codex:msg_7",
            projectionRunID: Self.runID, projectionGeneration: 3
        )

        // A Mac without the coordinator installs no handler.
        let noHandler = try respond(try Self.encode(request))
        #expect(noHandler.status == 200)
        #expect(try result(noHandler) == .noCoordinator)

        var received: [(RemoteCoordinatorChatReadRequest, UUID)] = []
        handler.coordinatorChatReadHandler = { request, device in
            received.append((request, device.id))
            return .moved
        }
        // Showing the chat needs read access only, so a device that may
        // not send can still mark what it read.
        #expect(try store.setScopes([.read], forDevice: native.device.id) == true)
        let read = try respond(try Self.encode(request))
        #expect(read.status == 200)
        #expect(try result(read) == .moved)
        #expect(received.map(\.0) == [request])
        #expect(received.map(\.1) == [native.device.id])

        // A malformed read does not reach the handler. A request without a
        // paired device's credential is refused before it: see
        // `CoordinatorChatNewMessagesTests`.
        #expect(try respond(Data("{}".utf8)).status == 400)
        let empty = RemoteCoordinatorChatReadRequest(
            conversationID: Self.conversationID, eventID: "", projectionRunID: Self.runID, projectionGeneration: 3
        )
        #expect(try respond(try Self.encode(empty)).status == 400)
        let long = RemoteCoordinatorChatReadRequest(
            conversationID: Self.conversationID,
            eventID: String(repeating: "a", count: RemoteCoordinatorChatReadPolicy.maximumEventIDLength + 1),
            projectionRunID: Self.runID, projectionGeneration: 3
        )
        #expect(try respond(try Self.encode(long)).status == 400)
        var older = request
        older.protocolVersion = "0.9"
        #expect(try respond(try Self.encode(older)).status == 409)
        #expect(received.count == 1)
    }
}
