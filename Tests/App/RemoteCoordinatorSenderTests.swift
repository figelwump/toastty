import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

/// A paired phone's message for the coordinator, through the Mac's real
/// coordinator controller, store, session store and quick entry choices,
/// with a fake terminal that records what is typed. The phone's New Task
/// sheet sends it as the Mac's quick entry panel does.
@MainActor
struct RemoteCoordinatorSenderTests {
    @MainActor
    private final class Harness {
        let quickEntry: QuickEntryCoordinatorTests.Harness
        let attachmentRoot: URL
        var deviceMaySend = true
        /// The permission check, counted from 1, that answers no: the
        /// device loses its permission at that moment.
        var revokesAtCheck: Int?
        private(set) var permissionChecks = 0
        /// Set to nil to stand in for a Mac with no coordinator controller.
        var coordinatorIsAvailable = true
        let device = RemoteDeviceRecord(
            name: "Phone", scopes: [.read, .send], authKind: .native,
            tailscaleLogin: "owner@example.com", createdAt: Date(timeIntervalSince1970: 0)
        )
        private(set) var sender: RemoteCoordinatorSender!

        init() throws {
            let quickEntry = try QuickEntryCoordinatorTests.Harness()
            quickEntry.tasks.config.defaults.agent = "codex"
            quickEntry.tasks.config.defaults.model = "gpt-6.1-sol"
            quickEntry.tasks.config.defaults.effort = "high"
            self.quickEntry = quickEntry
            attachmentRoot = quickEntry.tasks.root.appendingPathComponent("remote-attachments", isDirectory: true)
            sender = makeSender()
        }

        /// A new sender, as the Mac makes after a relaunch: it remembers no
        /// answer.
        func makeSender() -> RemoteCoordinatorSender {
            RemoteCoordinatorSender(
                coordinator: { [unowned self] in
                    coordinatorIsAvailable ? quickEntry.coordinator.controller : nil
                },
                choices: { [unowned self] in
                    quickEntry.controller.currentChoices(includeProfile: RemoteTaskCreator.offersProfile)
                },
                attachmentStore: RemoteMessageAttachmentStore(root: attachmentRoot),
                deviceMaySend: { [unowned self] _ in
                    permissionChecks += 1
                    return deviceMaySend && permissionChecks != revokesAtCheck
                }
            )
        }

        func relaunchSender() {
            sender = makeSender()
        }

        var coordinator: CoordinatorControllerTests.Fixture { quickEntry.coordinator }
        var tasks: TaskCoordinatorTests.Fixture { quickEntry.tasks }
        var typedTexts: [String] { quickEntry.typedTexts }

        func send(_ request: RemoteCoordinatorSendRequest) async -> RemoteCoordinatorSendResult {
            await sender.send(request, device: device)
        }

        func request(
            _ clientRequestID: String = "phone-request-1",
            text: String = "Unread dot stays on after reading on the phone",
            workspaceID: UUID? = nil,
            profileID: String? = nil,
            model: String? = nil,
            effort: String? = nil,
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

        /// A coordinator workspace whose agent does not run.
        func openWithoutAgent() throws {
            let windowID = try #require(tasks.store.state.windows.first?.id)
            #expect(tasks.store.send(.createCoordinatorWorkspace(
                windowID: windowID, workspaceID: UUID(), panelID: UUID(), terminalCWD: coordinator.directory.path
            )))
        }

        var uploads: [URL] {
            (try? FileManager.default.contentsOfDirectory(at: attachmentRoot, includingPropertiesForKeys: nil)) ?? []
        }

        var savedQueue: CoordinatorQueueSnapshot? {
            CoordinatorQueueSnapshot.load(from: coordinator.queueFileURL)
        }
    }

    private static let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13])

    private func firstLine(_ text: String?) -> String? {
        text?.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init)
    }

    // MARK: - Send

    @Test func aSendAtThePromptIsTypedAsAQuickEntryMessageWithNoHint() async throws {
        let harness = try Harness()
        try await harness.quickEntry.openCoordinatorAndReturnToTheProject()
        #expect(harness.sender.state() == RemoteCoordinatorSendState(agent: .running, waitingCount: 0))

        #expect(await harness.send(harness.request()) == .sent)
        // Toastty's first line, and no project as a hint: the phone has no
        // selected project, and the Mac's selection is not the user's now.
        #expect(harness.typedTexts == ["""
        [Toastty] Quick entry from the user
        Unread dot stays on after reading on the phone
        """])
        // The coordinator makes the task; the send made none.
        #expect(harness.tasks.coordinator.records.records.isEmpty)
        #expect(harness.coordinator.controller.queuedEntries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: harness.coordinator.queueFileURL.path) == false)
    }

    @Test func choicesAndFilesTravelAsTheMacsQuickEntrySendsThem() async throws {
        let harness = try Harness()
        let emptyosID = try harness.quickEntry.addWorkspace("emptyos")
        try await harness.quickEntry.openCoordinatorAndReturnToTheProject()
        let request = harness.request(
            text: "Fix the computer update",
            workspaceID: emptyosID,
            profileID: "codex",
            model: "gpt-6.1-sol",
            effort: "high",
            attachments: [
                RemoteMessageAttachment(filename: "screen shot.png", data: Self.png),
                // A name with a path keeps only its last part.
                RemoteMessageAttachment(filename: "../../notes.txt", data: Data("Steps".utf8)),
            ]
        )
        #expect(await harness.send(request) == .sent)

        let typed = try #require(harness.typedTexts.first)
        #expect(firstLine(typed)
            == "[Toastty] Quick entry from the user | project chosen: \"emptyos\" (workspace \(emptyosID.uuidString)) | agent chosen: codex, model gpt-6.1-sol, effort high")
        #expect(typed.contains("Fix the computer update"))
        // The copies are in the coordinator's folder under the message's
        // ID, with the names the user gave the files, and the message ends
        // with their paths.
        let messageID = RemoteCoordinatorSender.messageID(deviceID: harness.device.id, clientRequestID: request.clientRequestID)
        let folder = harness.coordinator.directory.appendingPathComponent("attachments/\(messageID.uuidString)")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["notes.txt", "screen-shot.png"])
        #expect(try Data(contentsOf: folder.appendingPathComponent("screen-shot.png")) == Self.png)
        for name in names {
            #expect(typed.contains(folder.appendingPathComponent(name).path))
        }
        #expect(harness.uploads.isEmpty, "The uploads are removed once the coordinator has its copies")

        // A repeat after a relaunch, of a message the coordinator took: its
        // copies say so, and nothing is sent again.
        harness.relaunchSender()
        #expect(await harness.send(request) == .sent)
        #expect(harness.typedTexts.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == names)
        #expect(harness.uploads.isEmpty)
    }

    @Test func whileTheCoordinatorWorksTheMessageWaitsForTheTurnsEnd() async throws {
        let harness = try Harness()
        try await harness.quickEntry.openCoordinatorAndReturnToTheProject()
        try harness.coordinator.setStatus(.working)

        #expect(await harness.send(harness.request()) == .waiting(reason: .working))
        #expect(harness.typedTexts.isEmpty, "A quick entry message never goes into a running turn")
        #expect(harness.savedQueue?.queued.count == 1, "Saved until the coordinator's prompt takes it")
        #expect(harness.sender.state() == RemoteCoordinatorSendState(agent: .running, waitingCount: 1))

        try harness.coordinator.setStatus(.idle)
        await harness.tasks.waitUntil("the message is typed at the turn's end") { harness.typedTexts.count == 1 }
        #expect(firstLine(harness.typedTexts.first) == "[Toastty] Quick entry from the user")
        #expect(FileManager.default.fileExists(atPath: harness.coordinator.queueFileURL.path) == false)
    }

    @Test func withNoAgentTheMessageWaitsSavedAndARepeatAfterARelaunchSendsNothingNew() async throws {
        let harness = try Harness()
        try harness.openWithoutAgent()
        #expect(harness.sender.state() == RemoteCoordinatorSendState(agent: .notRunning, waitingCount: 0))

        let request = harness.request()
        #expect(await harness.send(request) == .waiting(reason: .notRunning))
        #expect(harness.typedTexts.isEmpty)
        let messageID = RemoteCoordinatorSender.messageID(deviceID: harness.device.id, clientRequestID: request.clientRequestID)
        #expect(harness.savedQueue?.queued.map(\.id) == [messageID.uuidString])

        // A new sender remembers no answer, as after a relaunch. The saved
        // message has the same ID, so the repeat finds it.
        harness.relaunchSender()
        #expect(await harness.send(request) == .waiting(reason: .notRunning))
        #expect(harness.coordinator.controller.queuedEntries.count == 1)

        // Open Coordinator starts the agent, and the message goes in once.
        try await harness.coordinator.openAtPrompt()
        await harness.tasks.waitUntil("the message is typed") { harness.typedTexts.count == 1 }
        await harness.coordinator.settle()
        #expect(harness.typedTexts.count == 1)
    }

    @Test func aRepeatedRequestGetsTheFirstResultAndSendsNothingNew() async throws {
        let harness = try Harness()
        try await harness.quickEntry.openCoordinatorAndReturnToTheProject()
        let attachment = RemoteMessageAttachment(filename: "screen.png", data: Self.png)
        let request = harness.request(attachments: [attachment])

        // A repeat while the first copies its files waits for its answer.
        async let first = harness.send(request)
        async let repeated = harness.send(request)
        #expect(await [first, repeated] == [.sent, .sent])
        // A repeat after the answer gets it again, also once the
        // coordinator works.
        try harness.coordinator.setStatus(.working)
        #expect(await harness.send(request) == .sent)
        #expect(harness.typedTexts.count == 1)
        #expect(harness.quickEntry.attachmentFolders.count == 1)

        // Another request from the same device while one is under way.
        async let busyFirst = harness.send(harness.request("phone-request-2", attachments: [attachment]))
        async let busySecond = harness.send(harness.request("phone-request-3"))
        let answers = await [busyFirst, busySecond]
        #expect(answers.contains(.rejected(reason: .busy, message: nil)))
        #expect(answers.contains(.waiting(reason: .working)))
    }

    @Test func aDeviceWithoutPermissionSendsNothing() async throws {
        let harness = try Harness()
        try await harness.quickEntry.openCoordinatorAndReturnToTheProject()
        harness.deviceMaySend = false
        let request = harness.request(attachments: [RemoteMessageAttachment(filename: "screen.png", data: Self.png)])
        #expect(await harness.send(request) == .rejected(reason: .permissionDenied, message: nil))
        #expect(harness.typedTexts.isEmpty)
        #expect(harness.uploads.isEmpty)
        #expect(harness.quickEntry.attachmentFolders.isEmpty)

        // Revoked while the coordinator copied the files: the check
        // directly before the send refuses it, and the copies go.
        harness.deviceMaySend = true
        harness.revokesAtCheck = harness.permissionChecks + 3
        #expect(await harness.send(request) == .rejected(reason: .permissionDenied, message: nil))
        #expect(harness.permissionChecks == harness.revokesAtCheck)
        #expect(harness.typedTexts.isEmpty)
        #expect(harness.coordinator.controller.queuedEntries.isEmpty)
        #expect(harness.uploads.isEmpty)
        #expect(harness.quickEntry.attachmentFolders.isEmpty)

        // A refusal sent nothing, so the same request may go once allowed.
        harness.revokesAtCheck = nil
        #expect(await harness.send(request) == .sent)
        #expect(harness.typedTexts.count == 1)
    }

    @Test func aMacWithoutACoordinatorRefusesAndChoicesItDoesNotOfferAreRefused() async throws {
        let harness = try Harness()
        // The coordinator's controller, but no coordinator workspace.
        #expect(harness.sender.state() == nil)
        #expect(await harness.send(harness.request()) == .rejected(reason: .noCoordinator, message: nil))
        harness.coordinatorIsAvailable = false
        #expect(harness.sender.state() == nil)
        #expect(await harness.send(harness.request()) == .rejected(reason: .noCoordinator, message: nil))
        harness.coordinatorIsAvailable = true

        try await harness.quickEntry.openCoordinatorAndReturnToTheProject()
        #expect(await harness.send(harness.request(workspaceID: UUID()))
            == .rejected(reason: .workspaceNotFound, message: nil))
        // The coordinator's own workspace is not a project.
        let coordinatorWorkspaceID = try #require(harness.coordinator.controller.location?.workspaceID)
        #expect(await harness.send(harness.request(workspaceID: coordinatorWorkspaceID))
            == .rejected(reason: .workspaceNotFound, message: nil))
        #expect(await harness.send(harness.request(profileID: "grok"))
            == .rejected(reason: .agentUnavailable, message: nil))
        #expect(await harness.send(harness.request(profileID: "codex", effort: "ludicrous"))
            == .rejected(reason: .invalidRequest, message: nil))
        #expect(harness.typedTexts.isEmpty)
    }

    @Test func theCoordinatorsWaitReasonsReadAsTheMacsToastSaysThem() {
        #expect(RemoteCoordinatorSender.wireResult(.sentUnconfirmed) == .sent)
        #expect(RemoteCoordinatorSender.wireResult(.queued(position: 2, hold: .busy)) == .waiting(reason: .working))
        #expect(RemoteCoordinatorSender.wireResult(.queued(position: 1, hold: .noSession)) == .waiting(reason: .notRunning))
        #expect(RemoteCoordinatorSender.wireResult(.queued(position: 1, hold: .agentStarting)) == .waiting(reason: .starting))
        #expect(RemoteCoordinatorSender.wireResult(.queued(position: 1, hold: .userDraft)) == .waiting(reason: .userDraft))
        #expect(RemoteCoordinatorSender.wireResult(.queued(position: 1, hold: .promptNotOpen)) == .waiting(reason: .promptNotOpen))
        #expect(RemoteCoordinatorSender.wireResult(.queued(position: 1, hold: .notSaved)) == .waiting(reason: .notSaved))
        // One ID per request and device, and a valid name-based UUID.
        let device = UUID()
        let id = RemoteCoordinatorSender.messageID(deviceID: device, clientRequestID: "a")
        #expect(id == RemoteCoordinatorSender.messageID(deviceID: device, clientRequestID: "a"))
        #expect(id != RemoteCoordinatorSender.messageID(deviceID: device, clientRequestID: "b"))
        #expect(id != RemoteCoordinatorSender.messageID(deviceID: UUID(), clientRequestID: "a"))
        #expect(UUID(uuidString: id.uuidString) == id)
    }
}
