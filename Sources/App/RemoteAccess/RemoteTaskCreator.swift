import CoreState
import Foundation
import RemoteProtocol

/// The part of the task coordinator that a remote create uses. A protocol
/// so tests can run the create flow without task setup.
@MainActor
protocol RemoteTaskCreating: AnyObject {
    /// The task a caller already made with this request ID, if any.
    func existingTask(clientRequestID: String, source: TaskSource) -> TaskRecord?
    /// `beforeSave` runs after the files are copied, directly before the
    /// record is saved; a throw there saves nothing.
    func create(
        _ request: TaskCreateRequest,
        caller: TaskCaller,
        beforeSave: (@MainActor () throws -> Void)?
    ) async throws -> TaskRecord
}

extension TaskCoordinator: RemoteTaskCreating {
    func existingTask(clientRequestID: String, source: TaskSource) -> TaskRecord? {
        records.record(clientRequestID: clientRequestID, source: source)
    }
}

/// Creates tasks for a paired remote device, with the choices the Mac's
/// quick entry panel offers.
///
/// The device names an open top-level workspace and an agent preset. This
/// type checks them against what quick entry offers now, stores any
/// uploaded files, and calls the same `TaskCoordinator.create` that quick
/// entry and `toastty task create` use. The device's request ID becomes the
/// task's request ID, so a repeated request returns the first task.
@MainActor
final class RemoteTaskCreator {
    private struct RequestKey: Hashable {
        var deviceID: UUID
        var clientRequestID: String
    }

    /// The device lost its permission while the task's files were copied.
    private struct PermissionRevoked: Error {}

    private weak var coordinator: (any RemoteTaskCreating)?
    /// Quick entry's choices, limited to agents the device can follow.
    private let choices: () -> QuickEntryChoices
    private let recordCreatedTask: (QuickEntryPreset?, UUID) -> Void
    private let attachmentStore: RemoteMessageAttachmentStore?
    /// Whether the device may still create a task at this instant: remote
    /// access is on, and the device is unrevoked and permitted.
    private let deviceMayCreate: (UUID) -> Bool
    /// A create that is still saving, so a repeat of it waits for its answer
    /// instead of making a second task.
    private var inFlight: [RequestKey: Task<RemoteTaskCreateResult, Never>] = [:]

    init(
        coordinator: (any RemoteTaskCreating)?,
        choices: @escaping () -> QuickEntryChoices,
        recordCreatedTask: @escaping (QuickEntryPreset?, UUID) -> Void,
        attachmentStore: RemoteMessageAttachmentStore?,
        deviceMayCreate: @escaping (UUID) -> Bool
    ) {
        self.coordinator = coordinator
        self.choices = choices
        self.recordCreatedTask = recordCreatedTask
        self.attachmentStore = attachmentStore
        self.deviceMayCreate = deviceMayCreate
    }

    /// Only providers that the remote session list can show are offered. A
    /// task for any other provider would start a session that never
    /// appears on the device.
    static func offersProfile(_ summary: AgentLaunchProfileSummary) -> Bool {
        ProviderTranscriptSupport.isManagedProvider(summary.agent)
    }

    // MARK: - Options

    func options(device: RemoteDeviceRecord) -> RemoteTaskCreateOptionsResponse {
        let choices = choices()
        let workspaces = choices.workspaces.prefix(RemoteTaskCreatePolicy.maximumWorkspaceCount).map {
            RemoteTaskCreateWorkspace(id: $0.id, title: String($0.title.prefix(RemoteTaskCreatePolicy.maximumWorkspaceTitleLength)))
        }
        let agents = choices.profiles.map { profile in
            RemoteSessionStartAgent(
                profileID: profile.id,
                displayName: profile.displayName,
                availability: .available,
                supportsModel: profile.supportsModel,
                recentModels: profile.supportsModel
                    ? Array(profile.models.filter(Self.isValidModel).prefix(RemoteTaskCreatePolicy.maximumModelCount))
                    : [],
                reasoningEfforts: profile.efforts
            )
        }
        return RemoteTaskCreateOptionsResponse(
            permission: RemoteGatewayRequestHandler.sessionStartPermission(for: device),
            workspaces: Array(workspaces),
            defaultWorkspaceID: choices.initialWorkspaceID.flatMap { id in
                workspaces.contains { $0.id == id } ? id : nil
            },
            agents: agents,
            frequentPresets: choices.frequentPresets
                .compactMap(Self.wirePreset)
                .prefix(RemoteTaskCreatePolicy.maximumFrequentPresetCount)
                .map { $0 },
            defaultPreset: choices.initialPreset.flatMap(Self.wirePreset),
            supportsAttachments: attachmentStore != nil
        )
    }

    /// A preset the device could send back: its model and effort pass the
    /// create checks.
    private static func wirePreset(_ preset: QuickEntryPreset) -> RemoteTaskPreset? {
        if let model = preset.model, isValidModel(model) == false { return nil }
        if let effort = preset.effort,
           RemoteSessionStartPolicy.isValidSelectionValue(
               effort,
               maximumLength: RemoteSessionStartPolicy.maximumReasoningEffortLength
           ) == false {
            return nil
        }
        return RemoteTaskPreset(profileID: preset.agent, model: preset.model, effort: preset.effort)
    }

    private static func isValidModel(_ model: String) -> Bool {
        RemoteSessionStartPolicy.isValidSelectionValue(model, maximumLength: RemoteSessionStartPolicy.maximumModelLength)
    }

    // MARK: - Create

    func create(_ request: RemoteTaskCreateRequest, device: RemoteDeviceRecord) async -> RemoteTaskCreateResult {
        let key = RequestKey(deviceID: device.id, clientRequestID: request.clientRequestID)
        if let task = inFlight[key] {
            return await task.value
        }
        guard inFlight.keys.contains(where: { $0.deviceID == device.id }) == false else {
            return .rejected(reason: .busy, message: nil)
        }
        // Not a child of the request's task: if the device disconnects, the
        // create still finishes and a repeat of the request finds its task.
        let task = Task { @MainActor [weak self] () -> RemoteTaskCreateResult in
            guard let self else { return .rejected(reason: .createFailed, message: nil) }
            return await self.performCreate(request, deviceID: device.id)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private func performCreate(_ request: RemoteTaskCreateRequest, deviceID: UUID) async -> RemoteTaskCreateResult {
        guard let coordinator else { return .rejected(reason: .createFailed, message: nil) }
        // A repeat of a saved request returns that task, whatever changed
        // since, such as the workspace closing. Nothing is uploaded again.
        if let existing = coordinator.existingTask(
            clientRequestID: request.clientRequestID,
            source: .remoteDevice(deviceID: deviceID)
        ) {
            return .created(taskID: existing.id)
        }
        let choices = choices()
        guard choices.workspaces.contains(where: { $0.id == request.workspaceID }) else {
            return .rejected(reason: .workspaceNotFound, message: nil)
        }
        if let profileID = request.profileID {
            guard let profile = choices.profiles.first(where: { $0.id == profileID }) else {
                return .rejected(reason: .agentUnavailable, message: nil)
            }
            if request.model != nil, profile.supportsModel == false {
                return .rejected(reason: .invalidRequest, message: nil)
            }
            if let effort = request.effort, profile.efforts.contains(effort) == false {
                return .rejected(reason: .invalidRequest, message: nil)
            }
        }
        guard deviceMayCreate(deviceID) else { return .rejected(reason: .permissionDenied, message: nil) }

        let staged: RemoteMessageAttachmentStore.Staged?
        if request.attachments.isEmpty {
            staged = nil
        } else {
            guard let attachmentStore else { return .rejected(reason: .attachmentStorageUnavailable, message: nil) }
            do { staged = try await attachmentStore.stage(request.attachments) }
            catch RemoteMessageAttachmentStore.StorageError.invalidAttachments {
                return .rejected(reason: .invalidAttachments, message: nil)
            } catch {
                return .rejected(reason: .attachmentStorageUnavailable, message: nil)
            }
        }
        // The coordinator copies the files into the task, so the uploads are
        // removed whatever the outcome.
        func discardStaged() async {
            if let staged { await attachmentStore?.discard(staged) }
        }
        guard deviceMayCreate(deviceID) else {
            await discardStaged()
            return .rejected(reason: .permissionDenied, message: nil)
        }

        let createRequest = TaskCreateRequest(
            text: request.text,
            files: staged?.files.map { $0.path(percentEncoded: false) } ?? [],
            fileDisplayNames: staged.map { _ in request.attachments.map { RemoteAttachmentPolicy.displayFilename($0.filename) } },
            clientRequestID: request.clientRequestID,
            workspaceID: request.workspaceID,
            agent: request.profileID,
            model: request.model,
            effort: request.effort
        )
        let record: TaskRecord
        do {
            // Copying the files suspends, so the permission is read once
            // more directly before the record is saved.
            record = try await coordinator.create(createRequest, caller: .remoteDevice(deviceID)) { [deviceMayCreate] in
                guard deviceMayCreate(deviceID) else { throw PermissionRevoked() }
            }
        } catch is PermissionRevoked {
            await discardStaged()
            return .rejected(reason: .permissionDenied, message: nil)
        } catch {
            await discardStaged()
            ToasttyLog.info("A paired device's task was refused", category: .tasks, metadata: [
                "device_id": deviceID.uuidString,
            ])
            return .rejected(reason: .createFailed, message: Self.failureMessage(error))
        }
        await discardStaged()
        recordCreatedTask(
            request.profileID.map { QuickEntryPreset(agent: $0, model: request.model, effort: request.effort) },
            request.workspaceID
        )
        ToasttyLog.info("Created a task from a paired device", category: .tasks, metadata: [
            "task_id": record.id.uuidString,
            "device_id": deviceID.uuidString,
        ])
        return .created(taskID: record.id)
    }

    /// The coordinator's explanation, as the CLI shows it, bounded and on
    /// one line. Only the coordinator's own messages go to the device;
    /// another error's text can carry system detail, so it sends none.
    static func failureMessage(_ error: any Error) -> String? {
        guard let raw = (error as? TaskError)?.message else { return nil }
        let scalars = raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
        let line = String(scalars).trimmingCharacters(in: .whitespaces)
        guard line.count > RemoteTaskCreatePolicy.maximumFailureMessageLength else { return line }
        return String(line.prefix(RemoteTaskCreatePolicy.maximumFailureMessageLength - 1)) + "…"
    }
}
