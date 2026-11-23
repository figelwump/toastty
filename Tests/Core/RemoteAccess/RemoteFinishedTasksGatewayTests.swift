@testable import CoreState
import Foundation
import RemoteProtocol
import Testing

/// The gateway side of the finished tasks that a device reads for the chips
/// of links to them: the wire contract, a client's lenient reading, and the
/// device checks. Which tasks the Mac lists is in `RemoteTaskBoardTests`.
struct RemoteFinishedTasksGatewayTests {
    private typealias Support = RemoteGatewayRequestHandlerTests

    private static let identity = "owner@example.com"

    private static let merged = RemoteFinishedTask(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
        title: "Signup feedback", group: .done, stageTitle: "Done", stageReason: "merged", statusLine: "Done",
        projectTitle: "toastty",
        pullRequest: RemoteTaskPullRequest(
            number: 301, url: URL(string: "https://github.com/example/toastty/pull/301")!, state: .merged
        )
    )
    private static let archived = RemoteFinishedTask(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000402")!,
        title: "Old export spike", group: .archived, stageTitle: "Archived",
        stageReason: "closed without finishing", statusLine: "Archived"
    )

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try ConversationEventCoding.makeEncoder().encode(value)
    }

    // MARK: - Codec

    @Test func theRevisionNamesTheTasksAsADeviceShowsThem() throws {
        let finished = RemoteFinishedTasks(tasks: [Self.merged, Self.archived])
        let decoder = ConversationEventCoding.makeDecoder()
        #expect(try decoder.decode(RemoteFinishedTasks.self, from: Self.encode(finished)) == finished)
        // The same tasks give the same revision, also in another run of the
        // Mac; any change a chip or the detail shows gives another one.
        #expect(finished.revision == RemoteFinishedTasks(tasks: [Self.merged, Self.archived]).revision)
        #expect(finished.revision.count == 16)
        var renamed = Self.merged
        renamed.title = "Signup feedback form"
        var reopened = Self.merged
        reopened.pullRequest?.state = .closed
        for other in [[], [Self.merged], [Self.archived, Self.merged], [renamed, Self.archived], [reopened, Self.archived]] {
            #expect(RemoteFinishedTasks(tasks: other).revision != finished.revision)
        }

        // The board carries the revision. An older Mac omits it, and its
        // board still reads.
        let board = RemoteTaskBoard(doneCount: 2, finishedTasksRevision: finished.revision)
        #expect(try decoder.decode(RemoteTaskBoard.self, from: Self.encode(board)) == board)
        let older = try decoder.decode(RemoteTaskBoard.self, from: Self.encode(RemoteTaskBoard(doneCount: 2)))
        #expect(older.finishedTasksRevision == nil)
        #expect(String(decoding: try Self.encode(RemoteTaskBoard()), as: UTF8.self).contains("finishedTasks") == false)
    }

    /// When a task finished, for a device's mention list. A Mac from before
    /// the field sends none, and a device reads none; a done time this
    /// client cannot read reads as none and keeps the task. A phone from
    /// before the field reads the tasks without it.
    @Test func doneAtIsOptionalBothWays() throws {
        let doneAt = Date(timeIntervalSince1970: 1_786_200_000.125)
        var dated = Self.merged
        dated.doneAt = doneAt
        let finished = RemoteFinishedTasks(tasks: [dated, Self.archived])
        let decoder = ConversationEventCoding.makeDecoder()
        let decoded = try decoder.decode(RemoteFinishedTasks.self, from: Self.encode(finished))
        #expect(decoded == finished)
        #expect(decoded.tasks[0].doneAt == doneAt)
        #expect(decoded.tasks[1].doneAt == nil)
        // A task without the field sends no key, as an older Mac's.
        var object = try #require(try JSONSerialization.jsonObject(with: Self.encode(finished)) as? [String: Any])
        var tasks = try #require(object["tasks"] as? [[String: Any]])
        #expect(tasks[0]["doneAt"] as? String == "2026-08-08T14:40:00.125Z")
        #expect(tasks[1].keys.contains("doneAt") == false)

        tasks[0]["doneAt"] = "last Tuesday"
        object["tasks"] = tasks
        let unreadable = try decoder.decode(RemoteFinishedTasks.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(unreadable.tasks.map(\.id) == [Self.merged.id, Self.archived.id])
        #expect(unreadable.tasks[0].doneAt == nil)

        // The decoder from before the field, as an older phone has it.
        let older = try decoder.decode(FinishedTasksBeforeDoneAt.self, from: Self.encode(finished))
        #expect(older.revision == finished.revision)
        #expect(older.tasks.map(\.id) == [Self.merged.id, Self.archived.id])
        #expect(older.tasks.map(\.title) == ["Signup feedback", "Old export spike"])
    }

    /// `RemoteFinishedTasks` and `RemoteFinishedTask` as the phone decoded
    /// them before `doneAt`.
    private struct FinishedTasksBeforeDoneAt: Decodable {
        struct Entry: Decodable {
            enum CodingKeys: String, CodingKey {
                case id, title, group, stageTitle, stageReason, statusLine, projectTitle, pullRequest
            }

            let id: UUID
            let title: String
            let group: RemoteTaskGroup
            let stageTitle: String
            let stageReason: String
            let statusLine: String
            let projectTitle: String?
            let pullRequest: RemoteTaskPullRequest?

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(UUID.self, forKey: .id)
                title = try container.decode(String.self, forKey: .title)
                group = try container.decode(RemoteTaskGroup.self, forKey: .group)
                stageTitle = try container.decode(String.self, forKey: .stageTitle)
                stageReason = try container.decode(String.self, forKey: .stageReason)
                statusLine = try container.decode(String.self, forKey: .statusLine)
                projectTitle = try container.decodeIfPresent(String.self, forKey: .projectTitle)
                pullRequest = (try? container.decodeIfPresent(RemoteTaskPullRequest.self, forKey: .pullRequest)) ?? nil
            }
        }

        let protocolVersion: String
        let revision: String
        let tasks: [Entry]
    }

    /// A task this client cannot read is left out, and a pull request it
    /// cannot read reads as none; the other tasks stay.
    @Test func aClientReadsTheTasksLeniently() throws {
        let finished = RemoteFinishedTasks(tasks: [Self.merged, Self.archived])
        var object = try #require(try JSONSerialization.jsonObject(with: Self.encode(finished)) as? [String: Any])
        var tasks = try #require(object["tasks"] as? [[String: Any]])
        var laterState = tasks[0]
        var pullRequest = try #require(laterState["pullRequest"] as? [String: Any])
        pullRequest["state"] = "queued_for_merge"
        laterState["pullRequest"] = pullRequest
        var laterGroup = tasks[1]
        laterGroup["group"] = "snoozed"
        var noID = tasks[1]
        noID["id"] = nil
        tasks = [laterState, laterGroup, noID, tasks[1]]
        object["tasks"] = tasks
        object["addedLater"] = true

        let decoded = try ConversationEventCoding.makeDecoder().decode(
            RemoteFinishedTasks.self, from: JSONSerialization.data(withJSONObject: object)
        )
        var withoutPullRequest = Self.merged
        withoutPullRequest.pullRequest = nil
        #expect(decoded.tasks == [withoutPullRequest, Self.archived])
        #expect(decoded.revision == finished.revision)
    }

    // MARK: - Read

    @Test func aPairedDeviceWithReadAccessReadsTheTasks() throws {
        let (handler, store, _) = Support.makeHandler()
        let native = try Support.nativeCredential(handler: handler, store: store, identity: Self.identity)
        let headers = [("authorization", "Bearer \(native.credential)"), ("tailscale-user-login", Self.identity)]
        func respond(
            _ method: String = "GET",
            headers override: [(String, String)]? = nil
        ) throws -> RemoteGatewayHTTPResponse {
            guard case .respond(let response) = handler.handle(
                Support.request(method, RemoteFinishedTasksPolicy.path, headerFields: override ?? headers, body: Data()),
                at: Support.now
            ) else { throw CocoaError(.coderInvalidValue) }
            return response
        }
        func finished(_ response: RemoteGatewayHTTPResponse) throws -> RemoteFinishedTasks {
            try ConversationEventCoding.makeDecoder().decode(RemoteFinishedTasks.self, from: response.body)
        }

        // Without the task system no task is finished.
        let noHandler = try respond()
        #expect(noHandler.status == 200)
        #expect(try finished(noHandler) == RemoteFinishedTasks(tasks: []))

        let tasks = RemoteFinishedTasks(tasks: [Self.merged, Self.archived])
        var reads = 0
        handler.finishedTasksHandler = {
            reads += 1
            return tasks
        }
        // The board needs read access only, and so do these.
        #expect(try store.setScopes([.read], forDevice: native.device.id) == true)
        let read = try respond()
        #expect(read.status == 200)
        #expect(try finished(read) == tasks)
        #expect(reads == 1)

        // An unpaired device and a revoked one read nothing; only a GET
        // reads. Every paired device has read access.
        #expect(try respond(headers: [("tailscale-user-login", Self.identity)]).status == 401)
        #expect(try respond(headers: [("authorization", "Bearer unknown"), ("tailscale-user-login", Self.identity)]).status == 401)
        #expect(try respond("POST").status == 405)
        #expect(try store.revokeDevice(native.device.id, at: Support.now) == true)
        #expect(try respond().status == 401)
        #expect(reads == 1)
    }
}
