import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// `task.packet.publish` and `task.packet.get` through the app-control
/// executor, as the socket and the CLI reach them.
@MainActor
struct TaskPacketAppControlTests {
    private func makeExecutor(_ fixture: TaskCoordinatorTests.Fixture) -> AppControlExecutor {
        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let webPanelRuntimeRegistry = WebPanelRuntimeRegistry()
        webPanelRuntimeRegistry.bind(store: fixture.store)
        return AppControlExecutor(
            store: fixture.store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            focusedPanelCommandController: FocusedPanelCommandController(
                store: fixture.store,
                runtimeRegistry: terminalRuntimeRegistry,
                slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
            ),
            agentLaunchService: fixture.launcher,
            taskCoordinator: fixture.coordinator,
            reloadConfigurationAction: nil
        )
    }

    private let context = AutomationRequestContext(callerSessionID: nil, commandName: "app_control.run_action")

    private func startedTask(_ fixture: TaskCoordinatorTests.Fixture) async throws -> TaskRecord {
        let created = try await fixture.coordinator.create(TaskCreateRequest(text: "Fix totals", workspaceID: fixture.workspaceID, agent: "codex"))
        await fixture.waitForSetup(created.id)
        return try #require(fixture.record(created.id))
    }

    private func publish(
        _ executor: AppControlExecutor,
        taskID: UUID,
        packet: AutomationJSONValue,
        screenshots: [String] = []
    ) async throws -> [String: AutomationJSONValue] {
        var args: [String: AutomationJSONValue] = ["taskID": .string(taskID.uuidString), "packet": packet]
        if screenshots.isEmpty == false {
            args["screenshots"] = .array(screenshots.map(AutomationJSONValue.string))
        }
        return try #require(try await executor.runActionAsync(id: "task.packet.publish", args: args, context: context).result)
    }

    private func get(_ executor: AppControlExecutor, taskID: UUID, version: Int? = nil) async throws -> [String: AutomationJSONValue] {
        var args: [String: AutomationJSONValue] = ["taskID": .string(taskID.uuidString)]
        if let version { args["version"] = .int(version) }
        return try #require(try await executor.runActionAsync(id: "task.packet.get", args: args, context: context).result)
    }

    private func refusal(_ body: () async throws -> Void) async -> String? {
        do {
            try await body()
            return nil
        } catch AutomationSocketError.invalidPayload(let message) {
            return message
        } catch {
            return "\(error)"
        }
    }

    private func packetObject(summary: String, screenshots: [AutomationJSONValue] = []) -> AutomationJSONValue {
        .object([
            "summary": .string(summary),
            "look_at": .string("The totals bar at 390px"),
            "checks": .array([.object(["name": .string("npm test"), "ok": .bool(true), "log": .string("/tmp/t.log")])]),
            "not_verified": .array([.string("Safari")]),
            "screenshots": .array(screenshots),
        ])
    }

    @Test func publishingStoresVersionsAndPutsTheTaskInNeedsYou() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let executor = makeExecutor(fixture)
        let task = try await startedTask(fixture)
        let image = fixture.root.appendingPathComponent("after-390.png")
        try Data("png".utf8).write(to: image)
        #expect(task.readyForReviewAt == nil)

        let first = try await publish(
            executor,
            taskID: task.id,
            packet: packetObject(summary: "Moves the totals up", screenshots: [
                .object(["name": .string("after-390"), "pair": .string("after"), "width": .int(390)]),
            ]),
            screenshots: [image.path]
        )
        #expect(first["packetVersion"] == .int(1))
        #expect(fixture.record(task.id)?.readyForReviewAt != nil)
        #expect(fixture.record(task.id)?.packetVersion == 1)
        let storedImage = fixture.coordinator.packets.versionDirectoryURL(taskID: task.id, version: 1)
            .appendingPathComponent("after-390.png")
        #expect(FileManager.default.contents(atPath: storedImage.path) == Data("png".utf8))
        // The original may go; Toastty keeps its copy.
        try FileManager.default.removeItem(at: image)

        // The packet's text works as well as an object, as from key=value.
        let second = try await publish(
            executor,
            taskID: task.id,
            packet: .string(#"{"summary": "Addresses review notes", "look_at": "The coupon row", "not_verified": []}"#)
        )
        #expect(second["packetVersion"] == .int(2))

        let latest = try await get(executor, taskID: task.id)
        #expect(latest["version"] == .int(2))
        #expect(latest["latestVersion"] == .int(2))
        #expect(latest["summary"] == .string("Addresses review notes"))
        #expect(latest["not_verified"] == .array([]))
        // A task without a worktree has no commit to compare.
        #expect(latest["headCommit"] == .null)
        #expect(latest["stale"] == .bool(false))

        let older = try await get(executor, taskID: task.id, version: 1)
        #expect(older["summary"] == .string("Moves the totals up"))
        #expect(older["checks"] == .array([.object(["name": .string("npm test"), "ok": .bool(true), "log": .string("/tmp/t.log")])]))
        #expect(older["screenshots"] == .array([.object([
            "name": .string("after-390"),
            "pair": .string("after"),
            "width": .int(390),
            "path": .string(storedImage.path),
        ])]))

        let got = try executor.runQuery(id: "task.get", args: ["taskID": .string(task.id.uuidString)])
        #expect(got["packetVersion"] == .int(2))
        #expect(got["verifySkill"] == .string("toastty-task-verify"))

        try fixture.coordinator.delete(taskID: task.id)
        #expect(FileManager.default.fileExists(atPath: fixture.coordinator.packets.taskDirectoryURL(taskID: task.id).path) == false)
    }

    @Test func incompletePacketsAndMissingScreenshotsAreRefusedWithoutAVersion() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let executor = makeExecutor(fixture)
        let task = try await startedTask(fixture)

        #expect(await refusal {
            _ = try await publish(executor, taskID: task.id, packet: .string(#"{"summary": "s", "not_verified": []}"#))
        } == "The packet needs look_at as non-empty text.")
        #expect(await refusal {
            _ = try await publish(executor, taskID: task.id, packet: packetObject(summary: "s", screenshots: [.object(["name": .string("after-390")])]))
        } == "Screenshot \"after-390\" needs a file: pass --screenshot after-390.png.")
        let missing = fixture.root.appendingPathComponent("after-390.png").path
        #expect(await refusal {
            _ = try await publish(
                executor,
                taskID: task.id,
                packet: packetObject(summary: "s", screenshots: [.object(["name": .string("after-390")])]),
                screenshots: [missing]
            )
        } == "Screenshot \(missing) does not exist or is not a readable file.")
        #expect(await refusal {
            _ = try await publish(executor, taskID: task.id, packet: packetObject(summary: "s"), screenshots: ["after-390.png"])
        } == "screenshots must be absolute paths: after-390.png")
        #expect(await refusal {
            _ = try await get(executor, taskID: task.id)
        } == "Task Fix totals has no packet. Its agent publishes one with toastty task packet publish.")
        #expect(fixture.record(task.id)?.packetVersion == nil)
        #expect(fixture.record(task.id)?.readyForReviewAt == nil)

        _ = try await publish(executor, taskID: task.id, packet: packetObject(summary: "s"))
        #expect(await refusal { _ = try await get(executor, taskID: task.id, version: 2) } == "Task Fix totals has packets v1 to v1.")
        #expect(await refusal {
            _ = try await executor.runActionAsync(id: "task.packet.publish", args: ["packet": packetObject(summary: "s")], context: context)
        } == "taskID is required outside a task's agent session")

        // A task archived while git and the copies ran keeps no packet.
        let preparation = try fixture.coordinator.preparePacketPublish(
            taskID: task.id,
            packetJSON: Data(#"{"summary": "s", "look_at": "l", "not_verified": []}"#.utf8),
            screenshotPaths: []
        )
        _ = try fixture.coordinator.records.save(id: task.id) { $0.archivedAt = Date() }
        #expect(await refusal {
            do {
                _ = try await fixture.coordinator.finishPacketPublish(preparation)
            } catch let error as TaskError {
                throw AutomationSocketError.invalidPayload(error.message)
            }
        } == "Task Fix totals is archived.")
        #expect(fixture.coordinator.packets.versions(taskID: task.id) == [1])
        #expect(fixture.record(task.id)?.packetVersion == 1)
    }

    @Test func aPacketGoesStaleWhenTheWorktreeGetsNewCommits() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let executor = makeExecutor(fixture)
        let task = try await startedTask(fixture)
        let repository = try TaskGitTestRepository()
        let published = try TaskGitTestRepository.git(["rev-parse", "HEAD"], in: repository.project)
        _ = try fixture.coordinator.records.save(id: task.id) {
            $0.operation.worktree = TaskOperation.Worktree(
                path: repository.project,
                branch: "fix/totals",
                checkoutRoot: repository.project,
                added: true
            )
        }

        _ = try await publish(executor, taskID: task.id, packet: packetObject(summary: "s"))
        #expect(fixture.record(task.id)?.packetHeadCommit == published)
        var reading = try await get(executor, taskID: task.id)
        #expect(reading["headCommit"] == .string(published))
        #expect(reading["stale"] == .bool(false))

        let moved = try repository.commit("follow-up", in: repository.project)
        reading = try await get(executor, taskID: task.id)
        #expect(reading["currentHead"] == .string(moved))
        #expect(reading["stale"] == .bool(true))

        // A new packet at the new commit is current again.
        _ = try await publish(executor, taskID: task.id, packet: packetObject(summary: "s2"))
        reading = try await get(executor, taskID: task.id)
        #expect(reading["version"] == .int(2))
        #expect(reading["stale"] == .bool(false))
    }

    @Test func packetsGoWithTheAttachmentsAWeekAfterTheTaskFinishes() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let executor = makeExecutor(fixture)
        let task = try await startedTask(fixture)
        _ = try await publish(executor, taskID: task.id, packet: packetObject(summary: "s"))
        let packetFolder = fixture.coordinator.packets.taskDirectoryURL(taskID: task.id)
        let start = Date()
        func sweep(after interval: TimeInterval) {
            fixture.clock = start.addingTimeInterval(interval)
            fixture.coordinator.removeExpiredAttachments()
        }

        fixture.clock = start
        try fixture.coordinator.markDone(taskID: task.id)
        _ = fixture.store.send(.closeWorkspace(workspaceID: try #require(task.taskSpaceWorkspaceID)))
        sweep(after: 0)
        sweep(after: TaskAttachmentRetention.keepAfterFinish - 60)
        #expect(FileManager.default.fileExists(atPath: packetFolder.path))
        sweep(after: TaskAttachmentRetention.keepAfterFinish)
        #expect(FileManager.default.fileExists(atPath: packetFolder.path) == false)
        #expect(await refusal { _ = try await get(executor, taskID: task.id) }
            == "Toastty removed the packets of task Fix totals a week after it finished.")
        // Nothing would remove a packet published now, so none is taken.
        #expect(await refusal { _ = try await publish(executor, taskID: task.id, packet: packetObject(summary: "late")) }
            == "Task Fix totals finished more than a week ago, and Toastty removed its files.")
        #expect(FileManager.default.fileExists(atPath: packetFolder.path) == false)
    }
}
