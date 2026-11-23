@testable import CoreState
import Foundation
import RemoteProtocol
import Testing

struct RemoteTaskCreateGatewayTests {
    private typealias Support = RemoteGatewayRequestHandlerTests

    private static let identity = "owner@example.com"
    private static let workspaceID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private static let taskID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

    private static func createRequest(
        text: String = "Fix the flaky test",
        profileID: String? = "codex",
        model: String? = "gpt-6.1-sol",
        effort: String? = "high",
        clientRequestID: String = "request-1",
        attachments: [RemoteMessageAttachment] = []
    ) -> RemoteTaskCreateRequest {
        RemoteTaskCreateRequest(
            clientRequestID: clientRequestID,
            workspaceID: workspaceID,
            profileID: profileID,
            model: model,
            effort: effort,
            text: text,
            attachments: attachments
        )
    }

    private static func result(_ response: RemoteGatewayHTTPResponse) throws -> RemoteTaskCreateResult {
        try ConversationEventCoding.makeDecoder()
            .decode(RemoteTaskCreateResponse.self, from: response.body).result
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

    @Test func createCodecRoundTripsAndOmitsAbsentFields() throws {
        let decoder = ConversationEventCoding.makeDecoder()
        let bare = Self.createRequest(profileID: nil, model: nil, effort: nil)
        let bareJSON = String(decoding: try bare.encodedForTransport(), as: UTF8.self)
        for key in ["profileID", "model", "effort", "attachments"] {
            #expect(bareJSON.contains(key) == false, "\(key) is left out when absent")
        }
        #expect(try decoder.decode(RemoteTaskCreateRequest.self, from: bare.encodedForTransport()) == bare)

        let attachment = RemoteMessageAttachment(filename: "screen.png", data: Data([137, 80, 78, 71, 13, 10, 26, 10, 1]))
        let full = Self.createRequest(attachments: [attachment])
        #expect(try decoder.decode(RemoteTaskCreateRequest.self, from: full.encodedForTransport()) == full)

        for result in [
            RemoteTaskCreateResult.created(taskID: Self.taskID),
            .rejected(reason: .createFailed, message: "tasks.toml: line 3: unknown key"),
            .rejected(reason: .busy, message: nil),
        ] {
            let encoded = try Self.encode(RemoteTaskCreateResponse(result: result))
            #expect(try decoder.decode(RemoteTaskCreateResponse.self, from: encoded).result == result)
        }
    }

    @Test func responsesFromANewerMacDecodeSafely() throws {
        let decoder = ConversationEventCoding.makeDecoder()
        let futureReason = Data(#"{"protocolVersion":"1.0","status":"rejected","reason":"quota_exceeded"}"#.utf8)
        #expect(try decoder.decode(RemoteTaskCreateResponse.self, from: futureReason).result
            == .rejected(reason: .unknown, message: nil))
        // Not a refusal: the client cannot tell whether a task was saved.
        let futureStatus = Data(#"{"protocolVersion":"1.0","status":"queued"}"#.utf8)
        #expect(try decoder.decode(RemoteTaskCreateResponse.self, from: futureStatus).result == .unrecognized)

        // Options with only the required fields, as a smaller Mac sends them.
        let minimal = Data(#"{"protocolVersion":"1.0","permission":"start_disabled"}"#.utf8)
        let options = try decoder.decode(RemoteTaskCreateOptionsResponse.self, from: minimal)
        #expect(options.permission == .startDisabled)
        #expect(options.workspaces.isEmpty && options.agents.isEmpty && options.frequentPresets.isEmpty)
        #expect(options.defaultPreset == nil && options.supportsAttachments == false)
    }

    // MARK: - Hello

    @Test func helloAdvertisesTaskCreateOnlyWithAHandler() throws {
        let client = try Self.makeClient()
        func capabilities() throws -> [RemoteGatewayCapability] {
            guard case .respond(let response) = client.handler.handle(
                Support.request("GET", "/api/hello", headerFields: [], body: Data()),
                at: Support.now
            ) else { throw CocoaError(.coderInvalidValue) }
            return try JSONDecoder().decode(RemoteGatewayHelloResponse.self, from: response.body).capabilities
        }
        #expect(try capabilities().contains(.taskCreate) == false)
        client.handler.taskCreateHandler = { _, _ in .created(taskID: Self.taskID) }
        #expect(try capabilities().contains(.taskCreate))
    }

    // MARK: - Options

    @Test func optionsReportThisDevicesPermissionAndNeedOnlyReadAccess() throws {
        let client = try Self.makeClient()
        client.handler.taskCreateOptionsHandler = { _, device in
            RemoteTaskCreateOptionsResponse(
                permission: RemoteGatewayRequestHandler.sessionStartPermission(for: device),
                workspaces: [RemoteTaskCreateWorkspace(id: Self.workspaceID, title: "toastty")],
                defaultWorkspaceID: Self.workspaceID,
                frequentPresets: [RemoteTaskPreset(profileID: "codex", model: "gpt-6.1-sol", effort: "high")]
            )
        }
        let body = try Self.encode(RemoteTaskCreateOptionsRequest())
        func options() throws -> RemoteTaskCreateOptionsResponse {
            let response = try client.response(RemoteTaskCreatePolicy.optionsPath, body: body)
            #expect(response.status == 200)
            return try ConversationEventCoding.makeDecoder()
                .decode(RemoteTaskCreateOptionsResponse.self, from: response.body)
        }
        let allowed = try options()
        #expect(allowed.permission == .allowed)
        #expect(allowed.workspaces.map(\.id) == [Self.workspaceID])
        #expect(allowed.frequentPresets.first?.profileID == "codex")

        #expect(try client.store.setSessionStartDisabled(true, forDevice: client.deviceID))
        #expect(try options().permission == .startDisabled)
        #expect(try client.store.setSessionStartDisabled(false, forDevice: client.deviceID))
        #expect(try client.store.setScopes([.read], forDevice: client.deviceID))
        #expect(try options().permission == .sendDisabled)

        #expect(try client.response(RemoteTaskCreatePolicy.optionsPath, body: Data("[]".utf8)).status == 400)
        #expect(try client.response(
            RemoteTaskCreatePolicy.optionsPath, body: Self.encode(RemoteTaskCreateOptionsRequest(protocolVersion: "99.0"))
        ).status == 409)
        #expect(try client.response(
            RemoteTaskCreatePolicy.optionsPath, body: body,
            headers: [("cookie", Support.pairedDeviceCookie(client.store)), ("origin", Support.origin)]
        ).status == 401)
    }

    // MARK: - Create

    @Test func validCreateIsDeferredAndInvalidOrUnpermittedCreatesAreRefusedWithATypedResult() throws {
        let client = try Self.makeClient()
        let valid = Self.createRequest()
        guard case .deferredTaskCreate(let deviceID, let deferred) = client.handle(
            RemoteTaskCreatePolicy.createPath, body: try Self.encode(valid)
        ) else {
            Issue.record("Expected a deferred create")
            return
        }
        #expect(deviceID == client.deviceID)
        #expect(deferred == valid)
        // No agent at all lets tasks.toml's [defaults] choose.
        guard case .deferredTaskCreate = client.handle(
            RemoteTaskCreatePolicy.createPath,
            body: try Self.encode(Self.createRequest(profileID: nil, model: nil, effort: nil))
        ) else {
            Issue.record("Expected a deferred create without an agent")
            return
        }

        // Every refusal is HTTP 200 with a result the native client decodes.
        func refusal(_ request: RemoteTaskCreateRequest) throws -> RemoteTaskCreateResult {
            let response = try client.response(RemoteTaskCreatePolicy.createPath, body: try Self.encode(request))
            #expect(response.status == 200)
            return try Self.result(response)
        }
        let invalid = RemoteTaskCreateResult.rejected(reason: .invalidRequest, message: nil)
        #expect(try refusal(Self.createRequest(text: "  \n ")) == invalid)
        #expect(try refusal(Self.createRequest(text: "nul\u{0}")) == invalid)
        #expect(try refusal(Self.createRequest(model: "--dangerously-skip-permissions")) == invalid)
        #expect(try refusal(Self.createRequest(effort: "very high")) == invalid)
        #expect(try refusal(Self.createRequest(profileID: "")) == invalid)
        #expect(try refusal(Self.createRequest(profileID: nil)) == invalid, "A model needs its agent")
        #expect(try refusal(Self.createRequest(clientRequestID: "")) == invalid)
        #expect(try refusal(Self.createRequest(clientRequestID: "has space")) == invalid)
        #expect(try refusal(Self.createRequest(clientRequestID: String(repeating: "a", count: 65))) == invalid)
        // Files go only to the upload route, which reads its body last.
        let attachment = RemoteMessageAttachment(filename: "note.txt", data: Data("Read me".utf8))
        #expect(try refusal(Self.createRequest(attachments: [attachment])) == .rejected(reason: .invalidAttachments, message: nil))
        #expect(client.audit.entries.last?.action == .taskCreateRejected)
        #expect(client.audit.entries.last?.detail == "invalid_attachments")

        let denied = RemoteTaskCreateResult.rejected(reason: .permissionDenied, message: nil)
        #expect(try client.store.setSessionStartDisabled(true, forDevice: client.deviceID))
        #expect(try refusal(valid) == denied)
        #expect(try client.store.setSessionStartDisabled(false, forDevice: client.deviceID))
        #expect(try client.store.setScopes([.read], forDevice: client.deviceID))
        #expect(try refusal(valid) == denied)
        #expect(client.audit.entries.last?.detail == "permission_denied")
    }

    @Test func createRejectsMalformedOversizedMismatchedAndBrowserRequests() throws {
        let client = try Self.makeClient()
        let body = try Self.encode(Self.createRequest())
        let path = RemoteTaskCreatePolicy.createPath
        #expect(try client.response(path, body: Data("{}".utf8)).status == 400)
        var unsupported = Self.createRequest()
        unsupported.protocolVersion = "99.0"
        #expect(try client.response(path, body: Self.encode(unsupported)).status == 409)
        let oversized = Self.createRequest(text: String(repeating: "a", count: RemoteGatewayProtocol.maximumRequestBodyBytes))
        #expect(try client.response(path, body: Self.encode(oversized)).status == 413)
        #expect(try client.response(path, body: body, headers: [client.headers[0]]).status == 401)
        #expect(try client.response(path, body: body, headers: client.headers + [("origin", "https://hostile.example")]).status == 403)
        #expect(try client.response(
            path, body: body,
            headers: [("cookie", Support.pairedDeviceCookie(client.store)), ("origin", Support.origin)]
        ).status == 401)
    }

    @MainActor
    @Test func resolvingACreateChecksTheDeviceAgainAndAuditsTheOutcome() async throws {
        let client = try Self.makeClient()
        let request = Self.createRequest()
        var creates = 0
        client.handler.taskCreateHandler = { _, _ in
            creates += 1
            return .created(taskID: Self.taskID)
        }
        let created = await client.handler.resolveTaskCreate(deviceID: client.deviceID, request: request)
        #expect(try Self.result(created) == .created(taskID: Self.taskID))
        #expect(client.audit.entries.last?.action == .taskCreateAccepted)

        // Permission removed after the request was accepted, before saving.
        #expect(try client.store.setSessionStartDisabled(true, forDevice: client.deviceID))
        let denied = await client.handler.resolveTaskCreate(deviceID: client.deviceID, request: request)
        #expect(try Self.result(denied) == .rejected(reason: .permissionDenied, message: nil))
        #expect(try client.store.setSessionStartDisabled(false, forDevice: client.deviceID))
        #expect(try client.store.revokeDevice(client.deviceID, at: Support.now))
        let revoked = await client.handler.resolveTaskCreate(deviceID: client.deviceID, request: request)
        #expect(try Self.result(revoked) == .rejected(reason: .permissionDenied, message: nil))
        #expect(creates == 1)
        #expect(client.audit.entries.last?.action == .taskCreateRejected)
    }

    // MARK: - Attachments

    @Test func attachmentCreateAuthorizesHeadersBeforeAcceptingTheBody() throws {
        let client = try Self.makeClient()
        let path = RemoteTaskCreatePolicy.createWithAttachmentsPath
        let request = Self.createRequest(attachments: [.init(filename: "note.txt", data: Data("Read me".utf8))])
        let body = try request.encodedForTransport()
        #expect(RemoteGatewayHTTPRequest.isAttachmentUploadPath(path))
        let headers = Support.request("POST", path, headerFields: client.headers, body: Data())
        guard case .attachmentUploadAuthorized(let deviceID) = client.handler.authorizeAttachmentUpload(headers, at: Support.now) else {
            Issue.record("Expected native task-create upload admission")
            return
        }
        #expect(deviceID == client.deviceID)
        guard case .deferredTaskCreateAttachments(let finalDeviceID, let deferredBody) = client.handle(path, body: body) else {
            Issue.record("Expected a deferred attachment create")
            return
        }
        #expect(finalDeviceID == client.deviceID)
        #expect(deferredBody == body)
        #expect(try client.response(path, body: Data(), headers: [client.headers[0]]).status == 401)
        #expect(try client.response(path, body: Data(), headers: client.headers + [("origin", "https://hostile.example")]).status == 403)

        func deniedAdmission() throws -> RemoteTaskCreateResult {
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
    @Test func attachmentCreateValidatesDecodedFilesAndFieldsThenChecksLiveAuthorization() async throws {
        let client = try Self.makeClient()
        let attachment = RemoteMessageAttachment(filename: "note.txt", data: Data("Read me".utf8))
        let request = Self.createRequest(text: "See the attached note", attachments: [attachment])
        let body = try request.encodedForTransport()
        var received: [RemoteTaskCreateRequest] = []
        client.handler.taskCreateHandler = { request, _ in
            received.append(request)
            return .created(taskID: Self.taskID)
        }
        var decodedCalls = 0
        let created = await client.handler.resolveTaskCreateAttachments(deviceID: client.deviceID, body: body) {
            decodedCalls += 1
        }
        #expect(try Self.result(created) == .created(taskID: Self.taskID))
        #expect(received == [request])
        #expect(decodedCalls == 1)

        for invalid in [
            Self.createRequest(attachments: [.init(filename: "fake.png", data: attachment.data)]),
            Self.createRequest(attachments: [.init(filename: "tool.exe", data: attachment.data)]),
            Self.createRequest(attachments: [attachment, attachment]),
            Self.createRequest(),
        ] {
            let response = await client.handler.resolveTaskCreateAttachments(
                deviceID: client.deviceID, body: try invalid.encodedForTransport()
            )
            #expect(try Self.result(response) == .rejected(reason: .invalidAttachments, message: nil))
        }
        for invalid in [
            // Files alone do not make a task: its title comes from the text.
            Self.createRequest(text: " ", attachments: [attachment]),
            Self.createRequest(text: "nul\u{0}", attachments: [attachment]),
            Self.createRequest(model: "--help", attachments: [attachment]),
            Self.createRequest(clientRequestID: "", attachments: [attachment]),
        ] {
            let response = await client.handler.resolveTaskCreateAttachments(
                deviceID: client.deviceID, body: try invalid.encodedForTransport()
            )
            #expect(try Self.result(response) == .rejected(reason: .invalidRequest, message: nil))
        }
        #expect(try client.store.setSessionStartDisabled(true, forDevice: client.deviceID))
        let disabled = await client.handler.resolveTaskCreateAttachments(deviceID: client.deviceID, body: body)
        #expect(try Self.result(disabled) == .rejected(reason: .permissionDenied, message: nil))
        #expect(received.count == 1)
        #expect(client.audit.entries.last?.detail == "permission_denied")
    }
}
