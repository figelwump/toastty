import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

/// Runs a remote create through quick entry's choices and the real task
/// coordinator, with a fake terminal in place of Ghostty.
@MainActor
struct RemoteTaskCreatorTests {
    /// Holds each create until the test opens the gate, so a test can send
    /// a repeat while the first is still saving.
    @MainActor
    private final class GatedCoordinator: RemoteTaskCreating {
        let real: TaskCoordinator
        var isOpen = true
        private(set) var createCount = 0

        init(real: TaskCoordinator) {
            self.real = real
        }

        func existingTask(clientRequestID: String, source: TaskSource) -> TaskRecord? {
            real.existingTask(clientRequestID: clientRequestID, source: source)
        }

        func create(_ request: TaskCreateRequest, caller: TaskCaller) async throws -> TaskRecord {
            createCount += 1
            while isOpen == false { try await Task.sleep(for: .milliseconds(10)) }
            return try await real.create(request, caller: caller)
        }
    }

    @MainActor
    private final class Harness {
        let fixture: TaskCoordinatorTests.Fixture
        let coordinator: GatedCoordinator
        let quickEntry: QuickEntryController
        let attachmentRoot: URL
        let creator: RemoteTaskCreator
        var deviceMayCreate = true
        let device = RemoteDeviceRecord(
            name: "Phone", scopes: [.read, .send], authKind: .native,
            tailscaleLogin: "owner@example.com", createdAt: Date(timeIntervalSince1970: 0)
        )

        init() throws {
            let fixture = try TaskCoordinatorTests.Fixture()
            fixture.config.defaults.agent = "codex"
            fixture.config.defaults.model = "gpt-6.1-sol"
            fixture.config.defaults.effort = "high"
            self.fixture = fixture
            coordinator = GatedCoordinator(real: fixture.coordinator)
            quickEntry = QuickEntryController(
                store: fixture.store,
                agentProfiles: { [unowned fixture] in fixture.launcher.launchProfileSummaries() },
                presetUsage: QuickEntryPresetUsage(runtimePaths: .resolve(homeDirectoryPath: fixture.root.path, environment: [:])),
                create: { _ in throw TaskError("not used") },
                configLoader: { [unowned fixture] in
                    if let configError = fixture.configError { throw configError }
                    return fixture.config
                },
                stagingRootURL: fixture.root.appendingPathComponent("quick-entry", isDirectory: true),
                registersGlobalHotKey: false,
                frontmostApplication: { nil }
            )
            attachmentRoot = fixture.root.appendingPathComponent("remote-attachments", isDirectory: true)
            var deviceMayCreate: () -> Bool = { true }
            creator = RemoteTaskCreator(
                coordinator: coordinator,
                choices: { [unowned quickEntry] in
                    quickEntry.currentChoices(includeProfile: RemoteTaskCreator.offersProfile)
                },
                recordCreatedTask: { [unowned quickEntry] preset, workspaceID in
                    quickEntry.recordCreatedTask(preset: preset, workspaceID: workspaceID)
                },
                attachmentStore: RemoteMessageAttachmentStore(root: attachmentRoot),
                deviceMayCreate: { _ in deviceMayCreate() }
            )
            deviceMayCreate = { [unowned self] in self.deviceMayCreate }
        }

        func request(
            _ clientRequestID: String = "phone-request-1",
            text: String = "Composer keeps a blank line after send",
            workspaceID: UUID? = nil,
            profileID: String? = "codex",
            model: String? = "gpt-6.1-sol",
            effort: String? = "high",
            attachments: [RemoteMessageAttachment] = []
        ) -> RemoteTaskCreateRequest {
            RemoteTaskCreateRequest(
                clientRequestID: clientRequestID,
                workspaceID: workspaceID ?? fixture.workspaceID,
                profileID: profileID,
                model: model,
                effort: effort,
                text: text,
                attachments: attachments
            )
        }

        var records: [TaskRecord] { fixture.coordinator.records.records }

        func uploadDirectories() -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: attachmentRoot, includingPropertiesForKeys: nil)) ?? []
        }
    }

    private static let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13])

    @Test func optionsOfferQuickEntrysWorkspacesAgentsAndDefaults() throws {
        let harness = try Harness()
        let options = harness.creator.options(device: harness.device)
        #expect(options.permission == .allowed)
        #expect(options.workspaces == [RemoteTaskCreateWorkspace(id: harness.fixture.workspaceID, title: "toastty")])
        #expect(options.defaultWorkspaceID == harness.fixture.workspaceID)
        #expect(options.agents.map(\.profileID) == ["claude", "codex"])
        #expect(options.agents.allSatisfy { $0.availability == .available })
        #expect(options.agents.first { $0.profileID == "codex" }?.reasoningEfforts.contains("high") == true)
        // Before the first task, Frequent is tasks.toml's [defaults].
        let defaults = RemoteTaskPreset(profileID: "codex", model: "gpt-6.1-sol", effort: "high")
        #expect(options.frequentPresets == [defaults])
        #expect(options.defaultPreset == defaults)
        #expect(options.supportsAttachments)

        var disabled = harness.device
        disabled.sessionStartDisabled = true
        #expect(harness.creator.options(device: disabled).permission == .startDisabled)
    }

    @Test func createSavesATaskUnderTheDevicesRequestIDAndARepeatReturnsIt() async throws {
        let harness = try Harness()
        let request = harness.request(profileID: "claude", model: "claude-opus-5-5", effort: "xhigh")
        guard case .created(let taskID) = await harness.creator.create(request, device: harness.device) else {
            Issue.record("Expected a created task")
            return
        }
        let record = try #require(harness.fixture.record(taskID))
        #expect(record.source == .remoteDevice(deviceID: harness.device.id))
        #expect(record.clientRequestID == "phone-request-1")
        #expect(record.workspaceID == harness.fixture.workspaceID)
        #expect(record.pinned.agent == "claude")
        #expect(record.pinned.model == "claude-opus-5-5")
        #expect(record.pinned.effort == "xhigh")
        #expect(record.text == "Composer keeps a blank line after send")
        await harness.fixture.waitForSetup(taskID)

        // A retry after a lost answer returns the same task.
        #expect(await harness.creator.create(request, device: harness.device) == .created(taskID: taskID))
        #expect(harness.records.count == 1)
        #expect(harness.coordinator.createCount == 1)

        // Request IDs belong to their device.
        var otherDevice = harness.device
        otherDevice.id = UUID()
        guard case .created(let otherTaskID) = await harness.creator.create(request, device: otherDevice) else {
            Issue.record("Expected a second device's task")
            return
        }
        #expect(otherTaskID != taskID)
        await harness.fixture.waitForSetup(otherTaskID)

        // The phone's pick counts for quick entry's Frequent list, as a
        // Create Task in the panel does.
        let options = harness.creator.options(device: harness.device)
        #expect(options.frequentPresets.first == RemoteTaskPreset(profileID: "claude", model: "claude-opus-5-5", effort: "xhigh"))
        #expect(options.defaultPreset == options.frequentPresets.first)
    }

    @Test func aRepeatWhileTheFirstIsSavingWaitsForItAndAnotherRequestIsBusy() async throws {
        let harness = try Harness()
        harness.coordinator.isOpen = false
        let request = harness.request()
        let first = Task { await harness.creator.create(request, device: harness.device) }
        await harness.fixture.waitUntil("the first create reaches the coordinator") { harness.coordinator.createCount == 1 }
        let repeated = Task { await harness.creator.create(request, device: harness.device) }
        let other = await harness.creator.create(harness.request("phone-request-2"), device: harness.device)
        #expect(other == .rejected(reason: .busy, message: nil))

        harness.coordinator.isOpen = true
        let firstResult = await first.value
        guard case .created(let taskID) = firstResult else {
            Issue.record("Expected a created task, got \(firstResult)")
            return
        }
        #expect(await repeated.value == .created(taskID: taskID))
        #expect(harness.coordinator.createCount == 1)
        #expect(harness.records.count == 1)
        await harness.fixture.waitForSetup(taskID)
    }

    @Test func refusesChoicesQuickEntryWouldNotOfferAndSavesNothing() async throws {
        let harness = try Harness()
        let unknownWorkspace = harness.request(workspaceID: UUID())
        #expect(await harness.creator.create(unknownWorkspace, device: harness.device)
            == .rejected(reason: .workspaceNotFound, message: nil))
        #expect(await harness.creator.create(harness.request(profileID: "grok", model: nil, effort: nil), device: harness.device)
            == .rejected(reason: .agentUnavailable, message: nil))
        #expect(await harness.creator.create(harness.request(effort: "max"), device: harness.device)
            == .rejected(reason: .invalidRequest, message: nil))

        harness.deviceMayCreate = false
        let attachment = RemoteMessageAttachment(filename: "screen.png", data: Self.png)
        #expect(await harness.creator.create(harness.request(attachments: [attachment]), device: harness.device)
            == .rejected(reason: .permissionDenied, message: nil))
        #expect(harness.records.isEmpty)
        #expect(harness.coordinator.createCount == 0)
        #expect(harness.uploadDirectories().isEmpty)
    }

    @Test func aCoordinatorRefusalCarriesItsMessageOnOneLine() async throws {
        let harness = try Harness()
        // A broken tasks.toml leaves Frequent empty, and the create fails
        // with the coordinator's own explanation.
        harness.fixture.configError = TaskError("tasks.toml: line 3:\nunknown key \"agnet\"")
        let result = await harness.creator.create(harness.request(), device: harness.device)
        #expect(result == .rejected(reason: .createFailed, message: "tasks.toml: line 3: unknown key \"agnet\""))
        #expect(harness.records.isEmpty)
        #expect(RemoteTaskCreator.failureMessage(TaskError(String(repeating: "a", count: 400))).count
            == RemoteTaskCreatePolicy.maximumFailureMessageLength)
    }

    @Test func uploadedFilesBecomeTaskAttachmentsWithTheirNamesAndTheUploadsAreRemoved() async throws {
        let harness = try Harness()
        let screenshot = RemoteMessageAttachment(filename: "Shared screenshot.png", data: Self.png)
        let notes = RemoteMessageAttachment(filename: "notes.txt", data: Data("Steps to reproduce".utf8))
        let request = harness.request(text: "Composer blank line. Screenshot attached.", attachments: [screenshot, notes])
        guard case .created(let taskID) = await harness.creator.create(request, device: harness.device) else {
            Issue.record("Expected a created task")
            return
        }
        let record = try #require(harness.fixture.record(taskID))
        #expect(record.attachments.map(\.displayName) == ["Shared screenshot.png", "notes.txt"])
        for (attachment, sent) in zip(record.attachments, [screenshot, notes]) {
            #expect(attachment.path.hasPrefix(harness.fixture.attachmentsDirectory.path))
            #expect(FileManager.default.contents(atPath: attachment.path) == sent.data)
        }
        #expect(harness.uploadDirectories().isEmpty, "The task keeps its own copies")
        await harness.fixture.waitForSetup(taskID)
    }
}
