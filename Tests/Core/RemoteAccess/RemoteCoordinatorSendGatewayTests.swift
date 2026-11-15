@testable import CoreState
import Foundation
import RemoteProtocol
import Testing

/// The gateway side of a quick entry message to the coordinator: the wire
/// contract, the capability, admission, and the device checks. The Mac's
/// send itself is in `RemoteCoordinatorSenderTests`.
struct RemoteCoordinatorSendGatewayTests {
    private typealias Support = RemoteGatewayRequestHandlerTests

    private static let identity = "owner@example.com"
    private static let workspaceID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    private static func sendRequest(
        text: String = "Unread dot stays on after reading on the phone",
        workspaceID: UUID? = nil,
        profileID: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        clientRequestID: String = "request-1",
        attachments: [RemoteMessageAttachment] = []
    ) -> RemoteCoordinatorSendRequest {
        RemoteCoordinatorSendRequest(
            clientRequestID: clientRequestID,
            workspaceID: workspaceID,
            profileID: profileID,
            model: model,
            effort: effort,
            text: text,
            attachments: attachments
        )
    }

    private static func result(_ response: RemoteGatewayHTTPResponse) throws -> RemoteCoordinatorSendResult {
        try ConversationEventCoding.makeDecoder()
            .decode(RemoteCoordinatorSendResponse.self, from: response.body).result
    }

    private struct Client {
        var handler: RemoteGatewayRequestHandler
        var store: RemoteDeviceStore
        var audit: RemoteAccessAuditLog
        var deviceID: UUID
        var headers: [(String, String)]

        func handle(_ path: String, body: Data, headers override: [(String, String)]? = nil) -> RemoteGatewayRequestHandler.Outcome {
            handler.handle(
                Support.request("POST", path, headerFields: override ?? headers, body: body),
                at: Support.now
            )
        }

        func response(_ path: String, body: Data, headers override: [(String, String)]? = nil) throws -> RemoteGatewayHTTPResponse {
            guard case .respond(let response) = handle(path, body: body, headers: override) else {
                throw CocoaError(.coderInvalidValue)
            }
            return response
        }
    }

    private static func makeClient() throws -> Client {
        let (handler, store, audit) = Support.makeHandler()
        let native = try Support.nativeCredential(handler: handler, store: store, identity: identity)
        return Client(
            handler: handler,
            store: store,
            audit: audit,
            deviceID: native.device.id,
            headers: [("authorization", "Bearer \(native.credential)"), ("tailscale-user-login", identity)]
        )
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try ConversationEventCoding.makeEncoder().encode(value)
    }

    // MARK: - Codec

    @Test func codecRoundTripsAndLeavesOutAutoChoices() throws {
        let decoder = ConversationEventCoding.makeDecoder()
        let auto = Self.sendRequest()
        let autoJSON = String(decoding: try auto.encodedForTransport(), as: UTF8.self)
        for key in ["workspaceID", "profileID", "model", "effort", "attachments"] {
            #expect(autoJSON.contains(key) == false, "\(key) is left out on Auto")
        }
        #expect(try decoder.decode(RemoteCoordinatorSendRequest.self, from: auto.encodedForTransport()) == auto)

        let attachment = RemoteMessageAttachment(filename: "screen.png", data: Data([137, 80, 78, 71, 13, 10, 26, 10, 1]))
        let chosen = Self.sendRequest(
            workspaceID: Self.workspaceID, profileID: "codex", model: "gpt-6.1-sol", effort: "high", attachments: [attachment]
        )
        #expect(try decoder.decode(RemoteCoordinatorSendRequest.self, from: chosen.encodedForTransport()) == chosen)

        for result in [
            RemoteCoordinatorSendResult.sent,
            .waiting(reason: .working),
            .waiting(reason: .notRunning),
            .rejected(reason: .sendFailed, message: "The coordinator already has 50 messages waiting."),
            .rejected(reason: .noCoordinator, message: nil),
        ] {
            let encoded = try Self.encode(RemoteCoordinatorSendResponse(result: result))
            #expect(try decoder.decode(RemoteCoordinatorSendResponse.self, from: encoded).result == result)
        }
        // The bytes a phone reads, so both apps keep the same names.
        #expect(String(decoding: try Self.encode(RemoteCoordinatorSendResponse(result: .waiting(reason: .notRunning))), as: UTF8.self)
            .contains(#""reason":"not_running""#))
    }

    @Test func answersAndOptionsFromANewerMacDecodeSafely() throws {
        let decoder = ConversationEventCoding.makeDecoder()
        let futureReason = Data(#"{"protocolVersion":"1.0","status":"waiting","reason":"paused_by_user"}"#.utf8)
        #expect(try decoder.decode(RemoteCoordinatorSendResponse.self, from: futureReason).result
            == .waiting(reason: .unknown))
        let futureRefusal = Data(#"{"protocolVersion":"1.0","status":"rejected","reason":"quota_exceeded"}"#.utf8)
        #expect(try decoder.decode(RemoteCoordinatorSendResponse.self, from: futureRefusal).result
            == .rejected(reason: .unknown, message: nil))
        // Not a refusal: the phone cannot tell whether the message went.
        let futureStatus = Data(#"{"protocolVersion":"1.0","status":"forwarded"}"#.utf8)
        #expect(try decoder.decode(RemoteCoordinatorSendResponse.self, from: futureStatus).result == .unrecognized)

        // The options carry the coordinator's state; an older Mac omits it.
        let options = Data(#"""
        {"protocolVersion":"1.0","permission":"allowed","coordinator":{"agent":"starting","waitingCount":2}}
        """#.utf8)
        #expect(try decoder.decode(RemoteTaskCreateOptionsResponse.self, from: options).coordinator
            == RemoteCoordinatorSendState(agent: .starting, waitingCount: 2))
        let future = Data(#"{"protocolVersion":"1.0","permission":"allowed","coordinator":{"agent":"asleep"}}"#.utf8)
        #expect(try decoder.decode(RemoteTaskCreateOptionsResponse.self, from: future).coordinator
            == RemoteCoordinatorSendState(agent: .unknown, waitingCount: 0))
        let malformed = Data(#"{"protocolVersion":"1.0","permission":"allowed","coordinator":"yes"}"#.utf8)
        #expect(try decoder.decode(RemoteTaskCreateOptionsResponse.self, from: malformed).coordinator == nil)
        let older = Data(#"{"protocolVersion":"1.0","permission":"allowed"}"#.utf8)
        #expect(try decoder.decode(RemoteTaskCreateOptionsResponse.self, from: older).coordinator == nil)
    }

    // MARK: - Hello

    @Test func helloAdvertisesTheSendOnlyWithAHandler() throws {
        let client = try Self.makeClient()
        func capabilities() throws -> [RemoteGatewayCapability] {
            guard case .respond(let response) = client.handler.handle(
                Support.request("GET", "/api/hello", headerFields: [], body: Data()),
                at: Support.now
            ) else { throw CocoaError(.coderInvalidValue) }
            return try JSONDecoder().decode(RemoteGatewayHelloResponse.self, from: response.body).capabilities
        }
        #expect(try capabilities().contains(.coordinatorSend) == false)
        client.handler.coordinatorSendHandler = { _, _ in .sent }
        #expect(try capabilities().contains(.coordinatorSend))
    }

    // MARK: - Send

    @Test func validSendIsDeferredAndInvalidOrUnpermittedSendsAreRefusedWithATypedResult() throws {
        let client = try Self.makeClient()
        let path = RemoteCoordinatorSendPolicy.sendPath
        let valid = Self.sendRequest()
        guard case .deferredCoordinatorSend(let deviceID, let deferred) = client.handle(path, body: try Self.encode(valid)) else {
            Issue.record("Expected a deferred send")
            return
        }
        #expect(deviceID == client.deviceID)
        #expect(deferred == valid)
        let chosen = Self.sendRequest(workspaceID: Self.workspaceID, profileID: "codex", model: "gpt-6.1-sol", effort: "high")
        guard case .deferredCoordinatorSend(_, let deferredChoice) = client.handle(path, body: try Self.encode(chosen)) else {
            Issue.record("Expected a deferred send with choices")
            return
        }
        #expect(deferredChoice == chosen)

        // Every refusal is HTTP 200 with a result the native client decodes.
        func refusal(_ request: RemoteCoordinatorSendRequest) throws -> RemoteCoordinatorSendResult {
            let response = try client.response(path, body: try Self.encode(request))
            #expect(response.status == 200)
            return try Self.result(response)
        }
        let invalid = RemoteCoordinatorSendResult.rejected(reason: .invalidRequest, message: nil)
        #expect(try refusal(Self.sendRequest(text: "  \n ")) == invalid)
        #expect(try refusal(Self.sendRequest(text: "nul\u{0}")) == invalid)
        #expect(try refusal(Self.sendRequest(profileID: "codex", model: "--dangerously-skip-permissions")) == invalid)
        #expect(try refusal(Self.sendRequest(profileID: "codex", effort: "very high")) == invalid)
        #expect(try refusal(Self.sendRequest(profileID: "")) == invalid)
        #expect(try refusal(Self.sendRequest(model: "gpt-6.1-sol")) == invalid, "A model needs its agent")
        #expect(try refusal(Self.sendRequest(clientRequestID: "")) == invalid)
        #expect(try refusal(Self.sendRequest(clientRequestID: "has space")) == invalid)
        // Files go only to the upload route, which reads its body last.
        let attachment = RemoteMessageAttachment(filename: "note.txt", data: Data("Read me".utf8))
        #expect(try refusal(Self.sendRequest(attachments: [attachment])) == .rejected(reason: .invalidAttachments, message: nil))
        #expect(client.audit.entries.last?.action == .coordinatorSendRejected)
        #expect(client.audit.entries.last?.detail == "invalid_attachments")

        // The coordinator makes a task from the message: the device needs
        // the permission a task create needs.
        let denied = RemoteCoordinatorSendResult.rejected(reason: .permissionDenied, message: nil)
        #expect(try client.store.setSessionStartDisabled(true, forDevice: client.deviceID))
        #expect(try refusal(valid) == denied)
        #expect(try client.store.setSessionStartDisabled(false, forDevice: client.deviceID))
        #expect(try client.store.setScopes([.read], forDevice: client.deviceID))
        #expect(try refusal(valid) == denied)
        #expect(client.audit.entries.last?.detail == "permission_denied")

        // Malformed, mismatched, oversized and browser requests.
        #expect(try client.store.setScopes([.read, .send], forDevice: client.deviceID))
        #expect(try client.response(path, body: Data("{}".utf8)).status == 400)
        var unsupported = valid
        unsupported.protocolVersion = "99.0"
        #expect(try client.response(path, body: Self.encode(unsupported)).status == 409)
        let oversized = Self.sendRequest(text: String(repeating: "a", count: RemoteGatewayProtocol.maximumRequestBodyBytes))
        #expect(try client.response(path, body: Self.encode(oversized)).status == 413)
        let body = try Self.encode(valid)
        #expect(try client.response(path, body: body, headers: [client.headers[0]]).status == 401)
        #expect(try client.response(path, body: body, headers: client.headers + [("origin", "https://hostile.example")]).status == 403)
        #expect(try client.response(
            path, body: body,
            headers: [("cookie", Support.pairedDeviceCookie(client.store)), ("origin", Support.origin)]
        ).status == 401)
    }

    @MainActor
    @Test func resolvingASendChecksTheDeviceAgainAndAuditsTheOutcome() async throws {
        let client = try Self.makeClient()
        let request = Self.sendRequest()
        // A Mac that advertises nothing has no coordinator to send to.
        let unhandled = await client.handler.resolveCoordinatorSend(deviceID: client.deviceID, request: request)
        #expect(try Self.result(unhandled) == .rejected(reason: .noCoordinator, message: nil))

        var sends = 0
        client.handler.coordinatorSendHandler = { _, _ in
            sends += 1
            return .waiting(reason: .working)
        }
        let waiting = await client.handler.resolveCoordinatorSend(deviceID: client.deviceID, request: request)
        #expect(try Self.result(waiting) == .waiting(reason: .working))
        #expect(client.audit.entries.last?.action == .coordinatorSendAccepted)
        #expect(client.audit.entries.last?.detail == "waiting_working")

        // Permission removed after the request was accepted, before sending.
        #expect(try client.store.setSessionStartDisabled(true, forDevice: client.deviceID))
        let denied = await client.handler.resolveCoordinatorSend(deviceID: client.deviceID, request: request)
        #expect(try Self.result(denied) == .rejected(reason: .permissionDenied, message: nil))
        #expect(try client.store.setSessionStartDisabled(false, forDevice: client.deviceID))
        #expect(try client.store.revokeDevice(client.deviceID, at: Support.now))
        let revoked = await client.handler.resolveCoordinatorSend(deviceID: client.deviceID, request: request)
        #expect(try Self.result(revoked) == .rejected(reason: .permissionDenied, message: nil))
        #expect(sends == 1)
        #expect(client.audit.entries.last?.action == .coordinatorSendRejected)
    }

    // MARK: - Attachments

    @Test func attachmentSendAuthorizesHeadersBeforeAcceptingTheBody() throws {
        let client = try Self.makeClient()
        let path = RemoteCoordinatorSendPolicy.sendWithAttachmentsPath
        let request = Self.sendRequest(attachments: [.init(filename: "note.txt", data: Data("Read me".utf8))])
        let body = try request.encodedForTransport()
        #expect(RemoteGatewayHTTPRequest.isAttachmentUploadPath(path))
        let headers = Support.request("POST", path, headerFields: client.headers, body: Data())
        guard case .attachmentUploadAuthorized(let deviceID) = client.handler.authorizeAttachmentUpload(headers, at: Support.now) else {
            Issue.record("Expected native coordinator-send upload admission")
            return
        }
        #expect(deviceID == client.deviceID)
        guard case .deferredCoordinatorSendAttachments(let finalDeviceID, let deferredBody) = client.handle(path, body: body) else {
            Issue.record("Expected a deferred attachment send")
            return
        }
        #expect(finalDeviceID == client.deviceID)
        #expect(deferredBody == body)
        #expect(try client.response(path, body: Data(), headers: [client.headers[0]]).status == 401)

        func deniedAdmission() throws -> RemoteCoordinatorSendResult {
            guard case .respond(let response) = client.handler.authorizeAttachmentUpload(headers, at: Support.now) else {
                throw CocoaError(.coderInvalidValue)
            }
            #expect(response.status == 200)
            return try Self.result(response)
        }
        #expect(try client.store.setSessionStartDisabled(true, forDevice: client.deviceID))
        #expect(try deniedAdmission() == .rejected(reason: .permissionDenied, message: nil))
        #expect(try client.store.setSessionStartDisabled(false, forDevice: client.deviceID))
        #expect(try client.store.setScopes([.read], forDevice: client.deviceID))
        #expect(try deniedAdmission() == .rejected(reason: .permissionDenied, message: nil))
    }

    @MainActor
    @Test func attachmentSendValidatesDecodedFilesAndFieldsThenChecksLiveAuthorization() async throws {
        let client = try Self.makeClient()
        let attachment = RemoteMessageAttachment(filename: "note.txt", data: Data("Read me".utf8))
        let request = Self.sendRequest(text: "See the attached note", attachments: [attachment])
        let body = try request.encodedForTransport()
        var received: [RemoteCoordinatorSendRequest] = []
        client.handler.coordinatorSendHandler = { request, _ in
            received.append(request)
            return .sent
        }
        var decodedCalls = 0
        let sent = await client.handler.resolveCoordinatorSendAttachments(deviceID: client.deviceID, body: body) {
            decodedCalls += 1
        }
        #expect(try Self.result(sent) == .sent)
        #expect(received == [request])
        #expect(decodedCalls == 1)

        // The task-create upload checks: a file whose bytes do not match
        // its name, a type the Mac does not take, a repeated file, none.
        for invalid in [
            Self.sendRequest(attachments: [.init(filename: "fake.png", data: attachment.data)]),
            Self.sendRequest(attachments: [.init(filename: "tool.exe", data: attachment.data)]),
            Self.sendRequest(attachments: [attachment, attachment]),
            Self.sendRequest(),
        ] {
            let response = await client.handler.resolveCoordinatorSendAttachments(
                deviceID: client.deviceID, body: try invalid.encodedForTransport()
            )
            #expect(try Self.result(response) == .rejected(reason: .invalidAttachments, message: nil))
        }
        for invalid in [
            Self.sendRequest(text: " ", attachments: [attachment]),
            Self.sendRequest(profileID: "codex", model: "--help", attachments: [attachment]),
            Self.sendRequest(clientRequestID: "", attachments: [attachment]),
        ] {
            let response = await client.handler.resolveCoordinatorSendAttachments(
                deviceID: client.deviceID, body: try invalid.encodedForTransport()
            )
            #expect(try Self.result(response) == .rejected(reason: .invalidRequest, message: nil))
        }
        #expect(try client.store.setSessionStartDisabled(true, forDevice: client.deviceID))
        let disabled = await client.handler.resolveCoordinatorSendAttachments(deviceID: client.deviceID, body: body)
        #expect(try Self.result(disabled) == .rejected(reason: .permissionDenied, message: nil))
        #expect(received.count == 1)
    }
}
