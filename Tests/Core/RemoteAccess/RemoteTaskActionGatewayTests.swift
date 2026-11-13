@testable import CoreState
import Foundation
import RemoteProtocol
import Testing

/// The gateway's task routes: only a native device with send access and its
/// Task actions switch on reaches the Mac's task code, the switch is read
/// again when the deferred request runs, and the wire shapes stay readable
/// by clients that do not know a newer status or reason.
struct RemoteTaskActionGatewayTests {
    private typealias Support = RemoteGatewayRequestHandlerTests

    private static let identity = "owner@example.com"
    private static let taskID = UUID(uuidString: "30000000-0000-0000-0000-000000000302")!

    private struct Client {
        var handler: RemoteGatewayRequestHandler
        var store: RemoteDeviceStore
        var audit: RemoteAccessAuditLog
        var deviceID: UUID
        var headers: [(String, String)]

        func handle(_ path: String, body: Data) -> RemoteGatewayRequestHandler.Outcome {
            handler.handle(Support.request("POST", path, headerFields: headers, body: body), at: Support.now)
        }

        func response(_ path: String, body: Data) throws -> RemoteGatewayHTTPResponse {
            guard case .respond(let response) = handle(path, body: body) else {
                throw CocoaError(.coderInvalidValue)
            }
            return response
        }
    }

    private static func makeClient(taskActions: Bool) throws -> Client {
        let (handler, store, audit) = Support.makeHandler()
        let native = try Support.nativeCredential(handler: handler, store: store, identity: identity)
        try store.setTaskActionsEnabled(taskActions, forDevice: native.device.id)
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

    private static func actionResult(_ response: RemoteGatewayHTTPResponse) throws -> RemoteTaskActionResult {
        try ConversationEventCoding.makeDecoder().decode(RemoteTaskActionResponse.self, from: response.body).result
    }

    private static func checkResult(_ response: RemoteGatewayHTTPResponse) throws -> RemoteTaskArchiveCheckResult {
        try ConversationEventCoding.makeDecoder().decode(RemoteTaskArchiveCheckResponse.self, from: response.body).result
    }

    private static func mergeRequest(id: String = "merge-1", closePullRequest: Bool = false) -> RemoteTaskActionRequest {
        RemoteTaskActionRequest(
            taskID: taskID,
            action: closePullRequest ? .archive : .merge,
            clientRequestID: id,
            expectedPullRequestNumber: 263,
            closePullRequest: closePullRequest
        )
    }

    @Test func onlyADeviceWithTaskActionsOnReachesTheMac() throws {
        let client = try Self.makeClient(taskActions: false)
        let body = try Self.encode(Self.mergeRequest())

        // Turning the switch off overrides the default, even with send access.
        var response = try client.response(RemoteTaskActionPolicy.actionPath, body: body)
        #expect(response.status == 200)
        #expect(try Self.actionResult(response) == .rejected(reason: .permissionDenied, message: nil))
        #expect(client.audit.entries.last?.action == .taskActionRejected)
        #expect(client.audit.entries.last?.detail == "merge:permission_denied")
        let checkBody = try Self.encode(RemoteTaskArchiveCheckRequest(taskID: Self.taskID))
        response = try client.response(RemoteTaskActionPolicy.archiveCheckPath, body: checkBody)
        #expect(try Self.checkResult(response) == .rejected(reason: .permissionDenied, message: nil))

        try client.store.setTaskActionsEnabled(true, forDevice: client.deviceID)
        guard case .deferredTaskAction(let deviceID, let deferred) = client.handle(RemoteTaskActionPolicy.actionPath, body: body) else {
            Issue.record("Expected a deferred task action")
            return
        }
        #expect(deviceID == client.deviceID)
        #expect(deferred == Self.mergeRequest())
        guard case .deferredTaskArchiveCheck(_, let check) = client.handle(RemoteTaskActionPolicy.archiveCheckPath, body: checkBody) else {
            Issue.record("Expected a deferred archive check")
            return
        }
        #expect(check.taskID == Self.taskID)

        // Without send access the switch means nothing.
        try client.store.setScopes([.read], forDevice: client.deviceID)
        response = try client.response(RemoteTaskActionPolicy.actionPath, body: body)
        #expect(try Self.actionResult(response) == .rejected(reason: .permissionDenied, message: nil))
        #expect(client.audit.entries.last?.detail == "send_scope_denied")
        response = try client.response(RemoteTaskActionPolicy.archiveCheckPath, body: checkBody)
        #expect(try Self.checkResult(response) == .rejected(reason: .permissionDenied, message: nil))
    }

    @MainActor
    @Test func aDeferredActionReadsTheSwitchAgainBeforeItRuns() async throws {
        let client = try Self.makeClient(taskActions: true)
        var calls: [RemoteTaskActionRequest] = []
        client.handler.taskActionHandler = { request, _ in
            calls.append(request)
            return .performed
        }
        client.handler.taskArchiveCheckHandler = { _, _ in
            Issue.record("The archive check ran without permission")
            return .unrecognized
        }

        var response = await client.handler.resolveTaskAction(deviceID: client.deviceID, request: Self.mergeRequest())
        #expect(try Self.actionResult(response) == .performed)
        #expect(calls.count == 1)
        #expect(client.audit.entries.last?.action == .taskActionPerformed)
        #expect(client.audit.entries.last?.detail == "merge")

        // Turned off on the Mac while the request waited.
        try client.store.setTaskActionsEnabled(false, forDevice: client.deviceID)
        response = await client.handler.resolveTaskAction(deviceID: client.deviceID, request: Self.mergeRequest(id: "merge-2"))
        #expect(try Self.actionResult(response) == .rejected(reason: .permissionDenied, message: nil))
        #expect(calls.count == 1)
        response = await client.handler.resolveTaskArchiveCheck(
            deviceID: client.deviceID, request: RemoteTaskArchiveCheckRequest(taskID: Self.taskID)
        )
        #expect(try Self.checkResult(response) == .rejected(reason: .permissionDenied, message: nil))

        // A revoked device is refused too.
        try client.store.setTaskActionsEnabled(true, forDevice: client.deviceID)
        try client.store.revokeDevice(client.deviceID, at: Support.now)
        response = await client.handler.resolveTaskAction(deviceID: client.deviceID, request: Self.mergeRequest(id: "merge-3"))
        #expect(try Self.actionResult(response) == .rejected(reason: .permissionDenied, message: nil))
        #expect(calls.count == 1)
    }

    @Test func malformedRequestsNeverReachTheMac() throws {
        let client = try Self.makeClient(taskActions: true)
        func result(_ request: RemoteTaskActionRequest) throws -> RemoteTaskActionResult {
            try Self.actionResult(client.response(RemoteTaskActionPolicy.actionPath, body: Self.encode(request)))
        }
        var request = Self.mergeRequest(id: "has spaces")
        #expect(try result(request) == .rejected(reason: .invalidRequest, message: nil))
        request = Self.mergeRequest(id: String(repeating: "a", count: 65))
        #expect(try result(request) == .rejected(reason: .invalidRequest, message: nil))
        // Only an archive closes a pull request.
        request = Self.mergeRequest()
        request.closePullRequest = true
        #expect(try result(request) == .rejected(reason: .invalidRequest, message: nil))
        request = Self.mergeRequest()
        request.expectedPullRequestNumber = 0
        #expect(try result(request) == .rejected(reason: .invalidRequest, message: nil))

        var mismatched = Self.mergeRequest()
        mismatched.protocolVersion = "2.0"
        #expect(try client.response(RemoteTaskActionPolicy.actionPath, body: Self.encode(mismatched)).status == 409)
        let unknownAction = Data(#"{"protocolVersion":"1.0","taskID":"\#(Self.taskID)","action":"release","clientRequestID":"r1"}"#.utf8)
        #expect(try client.response(RemoteTaskActionPolicy.actionPath, body: unknownAction).status == 400)
        let oversized = Data(repeating: 0x20, count: RemoteTaskActionPolicy.maximumBodyBytes + 1)
        #expect(try client.response(RemoteTaskActionPolicy.actionPath, body: oversized).status == 400)
        // A browser credential has no task routes.
        let browser = try client.handler.handle(
            Support.request(
                "POST", RemoteTaskActionPolicy.actionPath,
                headerFields: [("cookie", Support.pairedDeviceCookie(client.store)), ("origin", Support.origin)],
                body: Self.encode(Self.mergeRequest())
            ),
            at: Support.now
        )
        guard case .respond(let denied) = browser else {
            Issue.record("Expected a refusal")
            return
        }
        #expect(denied.status == 401)
    }

    @Test func responsesStayReadableAcrossVersions() throws {
        let decoder = ConversationEventCoding.makeDecoder()
        for result in [
            RemoteTaskActionResult.performed,
            .rejected(reason: .notOffered, message: "Merging…"),
            .rejected(reason: .failed, message: nil),
        ] {
            let data = try Self.encode(RemoteTaskActionResponse(result: result))
            #expect(try decoder.decode(RemoteTaskActionResponse.self, from: data).result == result)
        }
        // A status or reason from a newer Mac is not mistaken for success.
        let newerStatus = Data(#"{"protocolVersion":"1.0","status":"queued"}"#.utf8)
        #expect(try decoder.decode(RemoteTaskActionResponse.self, from: newerStatus).result == .unrecognized)
        let newerReason = Data(#"{"protocolVersion":"1.0","status":"rejected","reason":"quota"}"#.utf8)
        #expect(try decoder.decode(RemoteTaskActionResponse.self, from: newerReason).result == .rejected(reason: .unknown, message: nil))
        // The Mac bounds its message.
        let long = try Self.encode(RemoteTaskActionResponse(result: .rejected(reason: .failed, message: String(repeating: "x", count: 400))))
        guard case .rejected(_, let message?) = try decoder.decode(RemoteTaskActionResponse.self, from: long).result else {
            Issue.record("Expected a message")
            return
        }
        #expect(message.count == RemoteTaskActionPolicy.maximumMessageLength)

        // A request without the optional fields reads with their defaults.
        let minimal = Data(#"{"protocolVersion":"1.0","taskID":"\#(Self.taskID)","action":"cancel_merge","clientRequestID":"r1"}"#.utf8)
        let request = try decoder.decode(RemoteTaskActionRequest.self, from: minimal)
        #expect(request.action == .cancelMerge && request.expectedPullRequestNumber == nil && request.closePullRequest == false)

        // Old records adopt the default, but browser devices cannot act.
        let legacy = Data(#"{"id":"\#(UUID())","name":"Phone","scopes":["read","send"],"authKind":"browser","createdAt":0}"#.utf8)
        let device = try JSONDecoder().decode(RemoteDeviceRecord.self, from: legacy)
        #expect(device.taskActionsEnabled == true)
        #expect(device.canActOnTasks == false)

        // A task summary from before slice 2 reads with no actions.
        let summary = Data(#"""
        {"id":"\#(Self.taskID)","hasRecord":true,"title":"T","group":"idle","statusLine":"Idle","stageTitle":"Idle",
         "stageReason":"","activityAt":"2026-11-06T10:00:00Z"}
        """#.utf8)
        let decoded = try decoder.decode(RemoteTaskSummary.self, from: summary)
        #expect(decoded.actions.isEmpty && decoded.mergeControl == nil && decoded.offers(.archive) == false)
    }
}
