import CoreState
import CryptoKit
import Foundation
import RemoteProtocol

/// Sends a paired device's message to the coordinator, as the Mac's quick
/// entry panel does while a coordinator exists.
///
/// The device sends the text, its files, and the Workspace and Agent
/// choices it made; an absent choice is Auto. This type checks the choices
/// against what quick entry offers now, stores any uploaded files, and
/// calls `CoordinatorController.sendUserMessage` with a quick entry
/// message: Toastty's first line with the choices, the files copied into
/// the coordinator's folder, saved until the coordinator's prompt takes
/// it, and never typed into a running turn.
///
/// The phone sends no project hint. The Mac's panel names the project
/// selected in Toastty when it opened, but the phone's sheet opens from
/// Home or the Tasks tab, which show every project, and the Mac's
/// selection says where the user last worked on the Mac, not what they look
/// at on the phone.
@MainActor
final class RemoteCoordinatorSender {
    private struct RequestKey: Hashable {
        var deviceID: UUID
        var clientRequestID: String
    }

    /// The device lost its permission while the message's files were copied.
    private struct PermissionRevoked: Error {}

    /// The answers that this run remembers for repeats, for each device. A
    /// phone repeats only the draft of its one open sheet, so neither its
    /// own nor another device's later sends push that answer out. A repeat
    /// after a Mac relaunch finds its message by ID while the message still
    /// waits, or by its copies when it had files.
    static let maximumRememberedAnswers = 200

    private let coordinator: () -> CoordinatorController?
    /// Quick entry's choices, limited to agents the device can follow.
    private let choices: () -> QuickEntryChoices
    private let attachmentStore: RemoteMessageAttachmentStore?
    /// Whether the device may still send at this instant: remote access is
    /// on, and the device is unrevoked and permitted.
    private let deviceMaySend: (UUID) -> Bool
    /// A send that is still under way, so a repeat of it waits for its
    /// answer instead of sending a second message.
    private var inFlight: [RequestKey: Task<RemoteCoordinatorSendResult, Never>] = [:]
    /// The answer to each request that sent or saved its message, so a
    /// repeat gets it again and sends nothing new.
    private var answers: [RequestKey: RemoteCoordinatorSendResult] = [:]
    /// Each device's remembered requests, oldest first.
    private var answerOrder: [UUID: [RequestKey]] = [:]

    init(
        coordinator: @escaping () -> CoordinatorController?,
        choices: @escaping () -> QuickEntryChoices,
        attachmentStore: RemoteMessageAttachmentStore?,
        deviceMaySend: @escaping (UUID) -> Bool
    ) {
        self.coordinator = coordinator
        self.choices = choices
        self.attachmentStore = attachmentStore
        self.deviceMaySend = deviceMaySend
    }

    /// The coordinator as the New Task sheet shows it before a send, or
    /// `nil` when the Mac has no coordinator workspace.
    func state() -> RemoteCoordinatorSendState? {
        guard let status = coordinator()?.status else { return nil }
        let agent: RemoteCoordinatorAgentState = switch status.agentState {
        case .running: .running
        case .starting: .starting
        case .notRunning: .notRunning
        }
        return RemoteCoordinatorSendState(agent: agent, waitingCount: status.queuedCount)
    }

    // MARK: - Send

    func send(_ request: RemoteCoordinatorSendRequest, device: RemoteDeviceRecord) async -> RemoteCoordinatorSendResult {
        let key = RequestKey(deviceID: device.id, clientRequestID: request.clientRequestID)
        if let answer = answers[key] {
            return answer
        }
        if let task = inFlight[key] {
            return await task.value
        }
        guard inFlight.keys.contains(where: { $0.deviceID == device.id }) == false else {
            return .rejected(reason: .busy, message: nil)
        }
        // Not a child of the request's task: if the device disconnects, the
        // send still finishes and a repeat of the request gets its answer.
        let task = Task { @MainActor [weak self] () -> RemoteCoordinatorSendResult in
            guard let self else { return .rejected(reason: .noCoordinator, message: nil) }
            let result = await self.performSend(request, deviceID: device.id)
            switch result {
            case .sent, .waiting: self.remember(result, for: key)
            case .rejected, .unrecognized: break
            }
            return result
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private func remember(_ result: RemoteCoordinatorSendResult, for key: RequestKey) {
        answers[key] = result
        var order = answerOrder[key.deviceID, default: []]
        order.append(key)
        while order.count > Self.maximumRememberedAnswers {
            answers[order.removeFirst()] = nil
        }
        answerOrder[key.deviceID] = order
    }

    private func performSend(_ request: RemoteCoordinatorSendRequest, deviceID: UUID) async -> RemoteCoordinatorSendResult {
        guard let controller = coordinator(), controller.status != nil else {
            return .rejected(reason: .noCoordinator, message: nil)
        }
        let messageID = Self.messageID(deviceID: deviceID, clientRequestID: request.clientRequestID)
        // A repeat after a Mac relaunch: the saved message is back in the
        // queue under the same ID.
        if let waiting = Self.waitingAnswer(messageID: messageID.uuidString, in: controller) {
            return waiting
        }
        // A message with files that the coordinator took before the
        // relaunch: its copies stay in the coordinator's folder.
        if request.attachments.isEmpty == false, controller.attachments.hasCopies(messageID: messageID.uuidString) {
            return .sent
        }
        let choices = choices()
        var project: CoordinatorMessageHeader.Workspace?
        if let workspaceID = request.workspaceID {
            guard let workspace = choices.workspaces.first(where: { $0.id == workspaceID }) else {
                return .rejected(reason: .workspaceNotFound, message: nil)
            }
            project = CoordinatorMessageHeader.Workspace(id: workspace.id, title: workspace.title)
        }
        switch RemoteTaskCreator.checkAgentChoice(
            profileID: request.profileID,
            model: request.model,
            effort: request.effort,
            in: choices
        ) {
        case .usable: break
        case .unavailable: return .rejected(reason: .agentUnavailable, message: nil)
        case .invalid: return .rejected(reason: .invalidRequest, message: nil)
        }
        guard deviceMaySend(deviceID) else { return .rejected(reason: .permissionDenied, message: nil) }

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
        // The coordinator copies the files into its own folder, so the
        // uploads are removed whatever the outcome.
        func discardStaged() async {
            if let staged { await attachmentStore?.discard(staged) }
        }
        guard deviceMaySend(deviceID) else {
            await discardStaged()
            return .rejected(reason: .permissionDenied, message: nil)
        }

        let message = CoordinatorUserMessage(
            id: messageID,
            text: request.text,
            files: staged?.files ?? [],
            // An upload is stored under a random name. Its copy for the
            // coordinator takes the name the user gave the file.
            fileNames: staged.map { _ in request.attachments.map { RemoteAttachmentPolicy.displayFilename($0.filename) } },
            quickEntry: CoordinatorMessageHeader.QuickEntry(
                project: project,
                agent: request.profileID,
                model: request.model,
                effort: request.effort
            )
        )
        let result: CoordinatorController.SendResult
        do {
            // Copying the files suspends, so the permission is read once
            // more directly before the message is typed or saved.
            result = try await controller.sendUserMessage(message) { [deviceMaySend] in
                guard deviceMaySend(deviceID) else { throw PermissionRevoked() }
            }
        } catch is PermissionRevoked {
            await discardStaged()
            return .rejected(reason: .permissionDenied, message: nil)
        } catch {
            await discardStaged()
            ToasttyLog.info("A paired device's message for the coordinator was refused", category: .tasks, metadata: [
                "device_id": deviceID.uuidString,
            ])
            // The coordinator closed while the files were copied.
            guard coordinator()?.status != nil else { return .rejected(reason: .noCoordinator, message: nil) }
            return .rejected(reason: .sendFailed, message: Self.failureMessage(error))
        }
        await discardStaged()
        let answer = Self.wireResult(result)
        ToasttyLog.info("Sent a paired device's message to the coordinator", category: .tasks, metadata: [
            "device_id": deviceID.uuidString,
            "message_id": messageID.uuidString,
            "typed": result.wasTyped ? "true" : "false",
            "file_count": String(request.attachments.count),
        ])
        return answer
    }

    // MARK: - Helpers

    /// The message's ID: the same for each repeat of one request from one
    /// device, so a repeat after a relaunch finds the saved message.
    static func messageID(deviceID: UUID, clientRequestID: String) -> UUID {
        let digest = SHA256.hash(data: Data("toastty.coordinator-send|\(deviceID.uuidString)|\(clientRequestID)".utf8))
        var bytes = Array(digest.prefix(16))
        // A name-based UUID (version 5, RFC 4122 variant).
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// The answer for a message that still waits in the coordinator's
    /// queue, or `nil` when no message has this ID.
    private static func waitingAnswer(messageID: String, in controller: CoordinatorController) -> RemoteCoordinatorSendResult? {
        if controller.queuedEntries.contains(where: { $0.id == messageID }) {
            return .waiting(reason: wireReason(controller.status?.hold ?? .awaitingTurn))
        }
        // Set aside by a Stop, or by a quit while it was typed. It waits
        // until the user sends it again on the Mac.
        if controller.pausedEntries.contains(where: { $0.id == messageID }) {
            return .waiting(reason: .promptNotOpen)
        }
        return nil
    }

    /// The coordinator's answer as the device reads it, with the reasons
    /// the Mac's quick entry toast gives.
    static func wireResult(_ result: CoordinatorController.SendResult) -> RemoteCoordinatorSendResult {
        switch result {
        // Quick entry never steers: its message waits for an open prompt.
        case .sent, .sentUnconfirmed, .steered, .steeredUnconfirmed:
            .sent
        case .queued(_, let hold), .held(let hold):
            .waiting(reason: wireReason(hold))
        }
    }

    static func wireReason(_ hold: CoordinatorSendHold) -> RemoteCoordinatorWaitReason {
        switch hold {
        case .noSession: .notRunning
        case .agentStarting: .starting
        case .userDraft: .userDraft
        case .busy, .awaitingTurn, .settling: .working
        case .terminalUnavailable, .terminalDialog, .promptNotOpen: .promptNotOpen
        case .notSaved: .notSaved
        }
    }

    /// The coordinator's own explanation, as the Mac's panel shows it,
    /// bounded and on one line. Another error's text can carry system
    /// detail, so it sends none.
    static func failureMessage(_ error: any Error) -> String? {
        guard let raw = (error as? CoordinatorError)?.message else { return nil }
        return RemoteTaskCreator.oneLine(raw, maximumLength: RemoteCoordinatorSendPolicy.maximumFailureMessageLength)
    }
}
