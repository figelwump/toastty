@testable import CoreState
import Foundation
import RemoteProtocol
import Testing

struct RemoteSessionStartGatewayTests {
    private typealias Support = RemoteGatewayRequestHandlerTests

    private static let identity = "owner@example.com"
    private static let workspaceID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    private static func startRequest(
        text: String = "Fix the flaky test",
        model: String? = "claude-opus-5-5",
        clientRequestID: String = "request-1"
    ) -> RemoteSessionStartRequest {
        RemoteSessionStartRequest(
            clientRequestID: clientRequestID,
            workspaceID: workspaceID,
            profileID: "claude",
            model: model,
            reasoningEffort: "high",
            text: text
        )
    }

    private static func result(_ response: RemoteGatewayHTTPResponse) throws -> RemoteSessionStartResult {
        try ConversationEventCoding.makeDecoder()
            .decode(RemoteSessionStartResponse.self, from: response.body).result
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

    @Test func optionsReportThisDevicesPermissionAndNeedOnlyReadAccess() throws {
        let client = try Self.makeClient()
        var seenDevices: [RemoteDeviceRecord] = []
        client.handler.sessionStartOptionsHandler = { request, device in
            seenDevices.append(device)
            return RemoteSessionStartOptionsResponse(
                permission: RemoteGatewayRequestHandler.sessionStartPermission(for: device),
                workspace: request.workspaceID == Self.workspaceID ? .available : .notFound,
                launchDirectory: "/Users/me/project",
                agents: [RemoteSessionStartAgent(
                    profileID: "claude", displayName: "Claude Code", availability: .available,
                    supportsModel: true, recentModels: ["claude-opus-5-5"], reasoningEfforts: ["low", "high"]
                )]
            )
        }
        let body = try Self.encode(RemoteSessionStartOptionsRequest(workspaceID: Self.workspaceID))
        func options() throws -> RemoteSessionStartOptionsResponse {
            let response = try client.response(RemoteSessionStartPolicy.optionsPath, body: body)
            #expect(response.status == 200)
            return try ConversationEventCoding.makeDecoder()
                .decode(RemoteSessionStartOptionsResponse.self, from: response.body)
        }

        // A device paired before the permission existed may start.
        let allowed = try options()
        #expect(allowed.permission == .allowed)
        #expect(allowed.workspace == .available)
        #expect(allowed.agents.map(\.profileID) == ["claude"])

        #expect(try client.store.setSessionStartDisabled(true, forDevice: client.deviceID))
        #expect(try options().permission == .startDisabled)

        // Without send access the device can still read why it cannot start.
        #expect(try client.store.setSessionStartDisabled(false, forDevice: client.deviceID))
        #expect(try client.store.setScopes([.read], forDevice: client.deviceID))
        #expect(try options().permission == .sendDisabled)
        #expect(seenDevices.count == 3)

        #expect(try client.response(RemoteSessionStartPolicy.optionsPath, body: Data("{}".utf8)).status == 400)
        var unsupported = RemoteSessionStartOptionsRequest(workspaceID: Self.workspaceID)
        unsupported.protocolVersion = "99.0"
        #expect(try client.response(RemoteSessionStartPolicy.optionsPath, body: Self.encode(unsupported)).status == 409)
        #expect(try client.response(
            RemoteSessionStartPolicy.optionsPath, body: body,
            headers: [("cookie", Support.pairedDeviceCookie(client.store)), ("origin", Support.origin)]
        ).status == 401)
    }

    @Test func validStartIsDeferredAndInvalidOrUnpermittedStartsAreRefusedWithATypedResult() throws {
        let client = try Self.makeClient()
        let valid = Self.startRequest()

        guard case .deferredSessionStart(let deviceID, let deferred) = client.handle(
            RemoteSessionStartPolicy.startPath, body: try Self.encode(valid)
        ) else {
            Issue.record("Expected a deferred start")
            return
        }
        #expect(deviceID == client.deviceID)
        #expect(deferred == valid)

        // Every refusal is HTTP 200 with a result the native client decodes.
        func refusal(_ request: RemoteSessionStartRequest) throws -> RemoteSessionStartResult {
            let response = try client.response(RemoteSessionStartPolicy.startPath, body: try Self.encode(request))
            #expect(response.status == 200)
            return try Self.result(response)
        }
        #expect(try refusal(Self.startRequest(text: "  \n ")) == .rejected(reason: .invalidRequest))
        #expect(try refusal(Self.startRequest(model: "--dangerously-skip-permissions")) == .rejected(reason: .invalidRequest))
        #expect(try refusal(Self.startRequest(model: "opus 5.5")) == .rejected(reason: .invalidRequest))
        #expect(try refusal(Self.startRequest(clientRequestID: "")) == .rejected(reason: .invalidRequest))
        #expect(try refusal(Self.startRequest(clientRequestID: String(repeating: "a", count: 65))) == .rejected(reason: .invalidRequest))
        #expect(client.audit.entries.last?.action == .sessionStartRejected)
        #expect(client.audit.entries.last?.detail == "invalid_request")

        #expect(try client.store.setSessionStartDisabled(true, forDevice: client.deviceID))
        #expect(try refusal(valid) == .rejected(reason: .permissionDenied))

        #expect(try client.store.setSessionStartDisabled(false, forDevice: client.deviceID))
        #expect(try client.store.setScopes([.read], forDevice: client.deviceID))
        #expect(try refusal(valid) == .rejected(reason: .permissionDenied))
        #expect(client.audit.entries.last?.detail == "permission_denied")
    }

    @Test func startRejectsMalformedOversizedMismatchedAndBrowserRequests() throws {
        let client = try Self.makeClient()
        let body = try Self.encode(Self.startRequest())
        let path = RemoteSessionStartPolicy.startPath

        #expect(try client.response(path, body: Data("{}".utf8)).status == 400)
        var unsupported = Self.startRequest()
        unsupported.protocolVersion = "99.0"
        #expect(try client.response(path, body: Self.encode(unsupported)).status == 409)
        let oversized = Self.startRequest(
            text: String(repeating: "a", count: RemoteGatewayProtocol.maximumRequestBodyBytes)
        )
        #expect(try client.response(path, body: Self.encode(oversized)).status == 413)
        #expect(try client.response(path, body: body, headers: [client.headers[0]]).status == 401)
        #expect(try client.response(path, body: body, headers: client.headers + [("origin", "https://hostile.example")]).status == 403)
        #expect(try client.response(
            path, body: body,
            headers: [("cookie", Support.pairedDeviceCookie(client.store)), ("origin", Support.origin)]
        ).status == 401)
    }

    @MainActor
    @Test func resolvingAStartChecksTheDeviceAgainAndAuditsTheOutcome() async throws {
        let client = try Self.makeClient()
        let request = Self.startRequest()
        let conversationID = RemoteConversationID()
        var launches = 0
        client.handler.sessionStartHandler = { _, _ in
            launches += 1
            return .started(conversationID: conversationID)
        }

        let started = await client.handler.resolveSessionStart(deviceID: client.deviceID, request: request)
        #expect(try Self.result(started) == .started(conversationID: conversationID))
        #expect(client.audit.entries.last?.action == .sessionStartAccepted)

        // Permission removed after the request was accepted, before launch.
        #expect(try client.store.setSessionStartDisabled(true, forDevice: client.deviceID))
        let denied = await client.handler.resolveSessionStart(deviceID: client.deviceID, request: request)
        #expect(try Self.result(denied) == .rejected(reason: .permissionDenied))

        #expect(try client.store.setSessionStartDisabled(false, forDevice: client.deviceID))
        #expect(try client.store.revokeDevice(client.deviceID, at: Support.now))
        let revoked = await client.handler.resolveSessionStart(deviceID: client.deviceID, request: request)
        #expect(try Self.result(revoked) == .rejected(reason: .permissionDenied))
        #expect(launches == 1)
        #expect(client.audit.entries.last?.action == .sessionStartRejected)
    }

    @Test func deviceRecordTreatsAMissingStartFieldAsAllowedAndKeepsAnOptOut() throws {
        // A record written before the permission existed.
        let legacy = Data(#"{"id":"66666666-6666-6666-6666-666666666666","name":"Phone","scopes":["read","send"],"authKind":"native","tailscaleLogin":"owner@example.com","createdAt":0}"#.utf8)
        var device = try JSONDecoder().decode(RemoteDeviceRecord.self, from: legacy)
        #expect(device.sessionStartDisabled == false)
        #expect(device.canStartSessions)

        // An allowed device writes no new key, so an older Mac reads the
        // record unchanged.
        let allowedJSON = try #require(String(data: JSONEncoder().encode(device), encoding: .utf8))
        #expect(allowedJSON.contains("sessionStartDisabled") == false)

        device.sessionStartDisabled = true
        let restored = try JSONDecoder().decode(RemoteDeviceRecord.self, from: JSONEncoder().encode(device))
        #expect(restored.sessionStartDisabled)
        #expect(restored.canStartSessions == false)

        var browser = device
        browser.sessionStartDisabled = false
        browser.authKind = .browser
        #expect(browser.canStartSessions == false)
    }

    @Test func startResponseDecodesUnknownStatusAndReasonAsANonStart() throws {
        let decoder = ConversationEventCoding.makeDecoder()
        let futureReason = Data(#"{"protocolVersion":"1.0","status":"rejected","reason":"quota_exceeded"}"#.utf8)
        #expect(try decoder.decode(RemoteSessionStartResponse.self, from: futureReason).result == .rejected(reason: .unknown))
        let futureStatus = Data(#"{"protocolVersion":"1.0","status":"queued"}"#.utf8)
        // Not a refusal: the client cannot tell whether a session started.
        #expect(try decoder.decode(RemoteSessionStartResponse.self, from: futureStatus).result == .unrecognized)

        let conversationID = RemoteConversationID()
        let started = RemoteSessionStartResponse(result: .started(conversationID: conversationID))
        #expect(try decoder.decode(
            RemoteSessionStartResponse.self,
            from: ConversationEventCoding.makeEncoder().encode(started)
        ) == started)

        let futureOptions = Data(#"{"protocolVersion":"1.0","permission":"needs_review","workspace":"archived","agents":[{"profileID":"claude","displayName":"Claude","availability":"updating"}]}"#.utf8)
        let options = try decoder.decode(RemoteSessionStartOptionsResponse.self, from: futureOptions)
        #expect(options.permission == .unknown)
        #expect(options.workspace == .unknown)
        #expect(options.agents.first?.availability == .unknown)
    }
}
