@testable import CoreState
import Foundation
import RemoteProtocol
import Testing

/// The gateway side of the coordinator's quiet wake turns: the wire
/// contract, the capability and the device checks. Where the Mac takes the
/// marks from is in `CoordinatorChatSendPathTests`.
struct RemoteCoordinatorQuietDigestsGatewayTests {
    private typealias Support = RemoteGatewayRequestHandlerTests

    private static let identity = "owner@example.com"

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try ConversationEventCoding.makeEncoder().encode(value)
    }

    // MARK: - Codec

    @Test func theRevisionNamesTheSetAndTheWorkspaceCarriesItSafely() throws {
        let decoder = ConversationEventCoding.makeDecoder()
        let keys = ["a1", "b2"].map(CoordinatorWakeState.digestKey)
        let digests = RemoteCoordinatorQuietDigests(keys: keys)
        #expect(try decoder.decode(RemoteCoordinatorQuietDigests.self, from: Self.encode(digests)) == digests)
        // The same keys give the same revision, also in another run of the
        // Mac; any change of the set gives another one.
        #expect(digests.revision == RemoteCoordinatorQuietDigests(keys: keys).revision)
        #expect(digests.revision.count == 16)
        for other in [[], [keys[0]], [keys[1], keys[0]], keys + [CoordinatorWakeState.digestKey("c3")]] {
            #expect(RemoteCoordinatorQuietDigests(keys: other).revision != digests.revision)
        }

        // The coordinator's workspace carries the revision. An older Mac
        // omits it, and one this client cannot read is left out.
        let workspace = RemoteWorkspaceSummary(
            id: UUID(), title: "Coordinator", panels: [], isCoordinator: true,
            coordinatorQuietDigestsRevision: digests.revision
        )
        #expect(try decoder.decode(RemoteWorkspaceSummary.self, from: Self.encode(workspace)) == workspace)
        let plain = RemoteWorkspaceSummary(id: UUID(), title: "toastty", panels: [])
        #expect(String(decoding: try Self.encode(plain), as: UTF8.self).contains("coordinatorQuietDigests") == false)
        var object = try #require(try JSONSerialization.jsonObject(with: Self.encode(workspace)) as? [String: Any])
        object["coordinatorQuietDigestsRevision"] = 7
        let malformed = try decoder.decode(RemoteWorkspaceSummary.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(malformed.coordinatorQuietDigestsRevision == nil)
        #expect(malformed.isCoordinator)
    }

    // MARK: - Hello

    @Test func helloAdvertisesTheQuietDigestsOnlyWithAHandler() throws {
        let (handler, _, _) = Support.makeHandler()
        func capabilities() throws -> [RemoteGatewayCapability] {
            guard case .respond(let response) = handler.handle(
                Support.request("GET", "/api/hello", headerFields: [], body: Data()),
                at: Support.now
            ) else { throw CocoaError(.coderInvalidValue) }
            return try JSONDecoder().decode(RemoteGatewayHelloResponse.self, from: response.body).capabilities
        }
        #expect(try capabilities().contains(.coordinatorQuietDigests) == false)
        handler.coordinatorQuietDigestsHandler = { RemoteCoordinatorQuietDigests(keys: []) }
        #expect(try capabilities().contains(.coordinatorQuietDigests))
    }

    // MARK: - Read

    @Test func aPairedDeviceReadsTheKeysWithReadAccessAlone() throws {
        let (handler, store, _) = Support.makeHandler()
        let native = try Support.nativeCredential(handler: handler, store: store, identity: Self.identity)
        let headers = [("authorization", "Bearer \(native.credential)"), ("tailscale-user-login", Self.identity)]
        func respond(
            _ method: String = "GET",
            headers override: [(String, String)]? = nil
        ) throws -> RemoteGatewayHTTPResponse {
            guard case .respond(let response) = handler.handle(
                Support.request(method, RemoteCoordinatorQuietDigestsPolicy.path, headerFields: override ?? headers, body: Data()),
                at: Support.now
            ) else { throw CocoaError(.coderInvalidValue) }
            return response
        }
        func digests(_ response: RemoteGatewayHTTPResponse) throws -> RemoteCoordinatorQuietDigests {
            try ConversationEventCoding.makeDecoder().decode(RemoteCoordinatorQuietDigests.self, from: response.body)
        }

        // A Mac without the coordinator installs no handler: nothing is
        // quiet.
        let noHandler = try respond()
        #expect(noHandler.status == 200)
        #expect(try digests(noHandler) == RemoteCoordinatorQuietDigests(keys: []))

        let quiet = RemoteCoordinatorQuietDigests(keys: [CoordinatorWakeState.digestKey("a quiet digest")])
        var reads = 0
        handler.coordinatorQuietDigestsHandler = {
            reads += 1
            return quiet
        }
        // Showing the chat needs read access only.
        #expect(try store.setScopes([.read], forDevice: native.device.id) == true)
        let read = try respond()
        #expect(read.status == 200)
        #expect(try digests(read) == quiet)
        #expect(reads == 1)

        // Only a paired device, and only a GET.
        #expect(try respond(headers: [("tailscale-user-login", Self.identity)]).status == 401)
        #expect(try respond(headers: [("authorization", "Bearer unknown"), ("tailscale-user-login", Self.identity)]).status == 401)
        #expect(try respond("POST").status != 200)
        #expect(reads == 1)
    }
}
