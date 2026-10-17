import CoreState
import Darwin
import Foundation
import RemoteProtocol

extension AppControlActionID {
    var isTaskAction: Bool {
        switch self {
        case .taskCreate, .taskPlace, .taskRetry, .taskDelete: true
        default: false
        }
    }
}

/// The parsed parts of a `task.create` request, read before any await.
struct TaskCreatePreparation {
    var coordinator: TaskInboxCoordinator
    var text: String
    var attachments: [RemoteMessageAttachment]
    var pins: TaskInboxItem.Pins
}

extension AppControlExecutor {
    /// Quick tasks are not tied to one workspace, and triage may place a
    /// task anywhere, so a workspace-scoped session cannot use them.
    private func requireTaskCoordinator() throws -> TaskInboxCoordinator {
        guard let taskInboxCoordinator else {
            throw AutomationSocketError.invalidPayload("quick tasks are not available in this Toastty instance")
        }
        guard callerIsWorkspaceScoped() == false else {
            throw AutomationSocketError.invalidPayload("task actions are not available to workspace-scoped sessions")
        }
        return taskInboxCoordinator
    }

    func prepareTaskCreate(args: [String: AutomationJSONValue]) throws -> TaskCreatePreparation {
        let coordinator = try requireTaskCoordinator()
        let files = args.taskStrings("files")
        guard files.count <= RemoteAttachmentPolicy.maximumCount else {
            throw AutomationSocketError.invalidPayload("attach up to \(RemoteAttachmentPolicy.maximumCount) files")
        }
        let paths: [String]
        do {
            paths = try SocketEventNormalizer.normalizeFiles(files, cwd: args.taskString("cwd"))
        } catch SocketEventNormalizationError.missingCWDForRelativePath(let path) {
            throw AutomationSocketError.invalidPayload("cwd is required when files include relative path: \(path)")
        }
        let attachments = try paths.map(Self.readTaskAttachment)
        return TaskCreatePreparation(
            coordinator: coordinator,
            text: args.taskString("text") ?? "",
            attachments: attachments,
            pins: try taskPins(args: args)
        )
    }

    func runTaskCreate(_ preparation: TaskCreatePreparation) async throws -> AppControlActionOutcome {
        let item: TaskInboxItem
        do {
            item = try await preparation.coordinator.add(
                text: preparation.text,
                attachments: preparation.attachments,
                pins: preparation.pins,
                source: .cli
            )
        } catch let error as TaskInboxError {
            throw AutomationSocketError.invalidPayload(error.localizedDescription)
        }
        return .init(didMutateState: true, result: [
            "taskID": .string(item.id.uuidString),
            "phase": .string(item.phase.rawValue),
            "title": .string(item.displayTitle),
        ])
    }

    func runTaskAction(_ action: AppControlActionID, args: [String: AutomationJSONValue]) throws -> AppControlActionOutcome {
        let coordinator = try requireTaskCoordinator()
        guard let taskID = args.taskUUID("taskID") else {
            throw AutomationSocketError.invalidPayload("taskID must be an Inbox task ID")
        }
        do {
            switch action {
            case .taskPlace:
                guard let workspaceID = args.taskUUID("workspace") else {
                    throw AutomationSocketError.invalidPayload("workspace must be a workspace ID")
                }
                let pins = try taskPins(args: args)
                try coordinator.place(
                    taskID: taskID,
                    workspaceID: workspaceID,
                    profileID: pins.profileID,
                    model: pins.model,
                    effort: pins.effort
                )
            case .taskRetry:
                try coordinator.retry(taskID: taskID)
            case .taskDelete:
                guard coordinator.inbox.item(id: taskID) != nil else { throw TaskInboxError.taskNotFound }
                coordinator.delete(taskID: taskID)
                return .init(didMutateState: true, result: ["taskID": .string(taskID.uuidString), "deleted": .bool(true)])
            default:
                throw AutomationSocketError.invalidPayload("unsupported task action: \(action.rawValue)")
            }
        } catch let error as TaskInboxError {
            throw AutomationSocketError.invalidPayload(error.localizedDescription)
        }
        let item = coordinator.inbox.item(id: taskID)
        return .init(didMutateState: true, result: [
            "taskID": .string(taskID.uuidString),
            "phase": item.map { .string($0.phase.rawValue) } ?? .null,
        ])
    }

    func taskListSnapshot() throws -> [String: AutomationJSONValue] {
        let coordinator = try requireTaskCoordinator()
        return ["tasks": .array(coordinator.inbox.items.map(Self.taskSnapshot))]
    }

    private static func taskSnapshot(_ item: TaskInboxItem) -> AutomationJSONValue {
        func optional(_ value: String?) -> AutomationJSONValue { value.map(AutomationJSONValue.string) ?? .null }
        var object: [String: AutomationJSONValue] = [
            "taskID": .string(item.id.uuidString),
            "phase": .string(item.phase.rawValue),
            "title": .string(item.displayTitle),
            "text": .string(item.text),
            "source": .string(item.source.rawValue),
            "createdAt": .string(ISO8601DateFormatter().string(from: item.createdAt)),
            "files": .array(item.attachments.map { .string($0.displayName) }),
            "problem": optional(item.problem),
        ]
        if let suggestion = item.suggestion {
            object["suggestion"] = .object([
                "workspaceID": optional(suggestion.workspaceID?.uuidString),
                "profileID": optional(suggestion.profileID),
                "model": optional(suggestion.model),
                "effort": optional(suggestion.effort),
                "reason": optional(suggestion.reason),
            ])
        }
        if let plan = item.plan {
            object["plan"] = .object([
                "workspaceID": .string(plan.workspaceID.uuidString),
                "slug": .string(plan.slug),
                "branchPrefix": .string(plan.branchPrefix),
                "profileID": .string(plan.profileID),
                "model": optional(plan.model),
                "effort": optional(plan.effort),
            ])
        }
        if let taskSpace = item.taskSpace {
            object["taskSpaceID"] = .string(taskSpace.workspaceID.uuidString)
        }
        return .object(object)
    }

    private func taskPins(args: [String: AutomationJSONValue]) throws -> TaskInboxItem.Pins {
        var pins = TaskInboxItem.Pins()
        if let raw = args.taskString("workspace") {
            guard let workspaceID = UUID(uuidString: raw) else {
                throw AutomationSocketError.invalidPayload("workspace must be a workspace ID")
            }
            pins.workspaceID = workspaceID
        }
        pins.profileID = args.taskString("profileID")
        pins.model = args.taskString("model")
        pins.effort = args.taskString("reasoningEffort")
        return pins
    }

    /// Reads one file to attach, without following it into a FIFO or
    /// reading more than the attachment limit.
    private static func readTaskAttachment(path: String) throws -> RemoteMessageAttachment {
        let filename = (path as NSString).lastPathComponent
        guard RemoteAttachmentPolicy.supportedFilename(filename) else {
            throw AutomationSocketError.invalidPayload("\(filename): attach an image, a PDF or a supported text file")
        }
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw AutomationSocketError.invalidPayload("\(filename): \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw AutomationSocketError.invalidPayload("\(filename) is not a regular file")
        }
        guard info.st_size > 0, info.st_size <= RemoteAttachmentPolicy.maximumFileBytes else {
            throw AutomationSocketError.invalidPayload(
                "\(filename) must be nonempty and at most \(RemoteAttachmentPolicy.maximumFileBytes / 1024 / 1024) MiB"
            )
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = (try? handle.read(upToCount: RemoteAttachmentPolicy.maximumFileBytes + 1)) ?? nil
        guard let data, data.isEmpty == false, data.count <= RemoteAttachmentPolicy.maximumFileBytes else {
            throw AutomationSocketError.invalidPayload("\(filename) could not be read")
        }
        return RemoteMessageAttachment(filename: filename, data: data)
    }
}

private extension Dictionary where Key == String, Value == AutomationJSONValue {
    func taskString(_ key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func taskStrings(_ key: String) -> [String] {
        switch self[key] {
        case .string(let value): return [value]
        case .array(let values): return values.compactMap { if case .string(let value) = $0 { value } else { nil } }
        default: return []
        }
    }

    func taskUUID(_ key: String) -> UUID? {
        taskString(key).flatMap(UUID.init(uuidString:))
    }
}
