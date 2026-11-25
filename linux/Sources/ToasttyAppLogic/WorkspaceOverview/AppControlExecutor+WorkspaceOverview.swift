import CoreState
import Foundation

// The `workspace.overview`, `workspace.scratchpad.*` and
// `workspace.synopsis.set` socket commands. Linux-only: the catalog lists
// them under `#if os(Linux)` (Sources/App/AppControl/AppControlCatalog.swift).

extension AppControlActionID {
    var isWorkspaceOverviewAction: Bool {
        switch self {
        case .workspaceScratchpadKeep, .workspaceScratchpadOpen, .workspaceScratchpadExport,
             .workspaceScratchpadDelete, .workspaceSynopsisSet: true
        default: false
        }
    }
}

extension AppControlQueryID {
    var isWorkspaceOverviewQuery: Bool {
        switch self {
        case .workspaceOverview, .workspaceScratchpadList: true
        default: false
        }
    }
}

extension AppControlExecutor {
    private func requiredWorkspaceOverview() throws -> WorkspaceOverviewService {
        guard let service = WorkspaceOverviewService.current else {
            throw AutomationSocketError.invalidPayload("the workspace page is not available")
        }
        return service
    }

    /// The top-level workspace a command names, or the caller's own.
    private func overviewWorkspaceID(args: [String: AutomationJSONValue], service: WorkspaceOverviewService) throws -> UUID {
        let workspaceID = try workspaceIDDefaultingToCallerSession(args)
        guard let topLevel = service.topLevelWorkspaceID(for: workspaceID) else {
            throw AutomationSocketError.invalidPayload("workspaceID does not exist")
        }
        try enforceWorkspaceAutomationAccess(topLevel)
        return topLevel
    }

    /// A kept Scratchpad named by documentID, in a workspace the caller may use.
    private func keptScratchpad(args: [String: AutomationJSONValue], service: WorkspaceOverviewService) throws -> WorkspaceScratchpadEntry {
        guard let documentID = try scratchpadDocumentIDArgument(args, required: true) else {
            throw AutomationSocketError.invalidPayload("documentID is required")
        }
        guard let entry = service.entry(documentID: documentID) else {
            throw AutomationSocketError.invalidPayload(WorkspaceOverviewError.unknownScratchpad(documentID).localizedDescription)
        }
        if try requiredStore().state.workspacesByID[entry.workspaceID] != nil {
            try enforceWorkspaceAutomationAccess(entry.workspaceID)
        }
        return entry
    }

    func runWorkspaceOverviewAction(_ action: AppControlActionID, args: [String: AutomationJSONValue]) throws -> AppControlActionOutcome {
        let service = try requiredWorkspaceOverview()
        do {
            switch action {
            case .workspaceScratchpadKeep:
                let kept: (entry: WorkspaceScratchpadEntry, created: Bool)
                if let panelID = try optionalUUIDParameter("panelID", args: args) {
                    if let workspaceID = try requiredStore().state.workspaceSelection(containingPanelID: panelID)?.workspaceID {
                        try enforceWorkspaceAutomationAccess(workspaceID)
                    }
                    kept = try service.keep(panelID: panelID, keptBy: requestContext().callerSessionID ?? "user")
                } else {
                    guard case .string? = args["sessionID"] else {
                        throw AutomationSocketError.invalidPayload("panelID or sessionID is required")
                    }
                    let sessionID = try scratchpadSessionIDArgument(args)
                    guard let target = try boundScratchpad(sessionID: sessionID, documentID: try scratchpadDocumentIDArgument(args, required: false)) else {
                        throw AutomationSocketError.invalidPayload("sessionID has no bound Scratchpad")
                    }
                    kept = try service.keep(sourceDocumentID: target.documentID, sourceWorkspaceID: target.workspaceID, keptBy: sessionID)
                }
                var result = Self.scratchpadSnapshot(kept.entry, service: service)
                result["created"] = .bool(kept.created)
                return .init(didMutateState: kept.created, result: result)

            case .workspaceScratchpadOpen:
                let entry = try keptScratchpad(args: args, service: service)
                let workspaceID = try workspaceIDDefaultingToCallerSession(args)
                let opened = try service.open(documentID: entry.documentID, in: workspaceID)
                return .init(didMutateState: opened, result: [
                    "documentID": .string(entry.documentID.uuidString),
                    "workspaceID": .string(workspaceID.uuidString),
                ])

            case .workspaceScratchpadExport:
                let entry = try keptScratchpad(args: args, service: service)
                service.syncIfLinked(copyDocumentID: entry.documentID)
                let export = try ScratchpadDocumentExporter.exportToDefaultLocation(
                    documentID: entry.documentID,
                    documentStore: service.documentStore
                )
                return .init(didMutateState: false, result: [
                    "filePath": .string(export.fileURL.path),
                    "documentID": .string(export.documentID.uuidString),
                    "revision": .int(export.revision),
                    "title": export.title.map { .string($0) } ?? .null,
                    "workspaceID": .string(entry.workspaceID.uuidString),
                ])

            case .workspaceScratchpadDelete:
                let entry = try keptScratchpad(args: args, service: service)
                try service.delete(documentID: entry.documentID)
                return .init(didMutateState: true, result: [
                    "documentID": .string(entry.documentID.uuidString),
                    "deleted": .bool(true),
                ])

            case .workspaceSynopsisSet:
                guard case .string(let text)? = args["text"] else {
                    throw AutomationSocketError.invalidPayload("text is required")
                }
                let workspaceID = try overviewWorkspaceID(args: args, service: service)
                try service.setSynopsis(text, forWorkspace: workspaceID, sessionID: requestContext().callerSessionID)
                let synopsis = service.synopsis(forWorkspace: workspaceID)
                return .init(didMutateState: true, result: [
                    "workspaceID": .string(workspaceID.uuidString),
                    "synopsis": synopsis.map { .string($0.text) } ?? .null,
                ])

            default:
                throw AutomationSocketError.invalidPayload("unsupported action: \(action.rawValue)")
            }
        } catch let error as WorkspaceOverviewError {
            throw AutomationSocketError.invalidPayload(error.localizedDescription)
        } catch let error as ScratchpadDocumentStoreError {
            throw AutomationSocketError.invalidPayload(error.localizedDescription)
        }
    }

    func runWorkspaceOverviewQuery(_ query: AppControlQueryID, args: [String: AutomationJSONValue]) throws -> [String: AutomationJSONValue] {
        let service = try requiredWorkspaceOverview()
        let workspaceID = try overviewWorkspaceID(args: args, service: service)
        switch query {
        case .workspaceScratchpadList:
            service.syncLinked(forWorkspace: workspaceID)
            return [
                "workspaceID": .string(workspaceID.uuidString),
                "scratchpads": .array(service.scratchpads(forWorkspace: workspaceID).map { .object(Self.scratchpadSnapshot($0, service: service)) }),
            ]
        default:
            guard let model = WorkspaceOverviewModel.make(workspaceID: workspaceID, service: service) else {
                throw AutomationSocketError.invalidPayload("workspaceID does not exist")
            }
            return Self.overviewSnapshot(model, service: service)
        }
    }

    private static func date(_ date: Date?) -> AutomationJSONValue {
        date.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null
    }

    static func scratchpadSnapshot(_ entry: WorkspaceScratchpadEntry, service: WorkspaceOverviewService) -> [String: AutomationJSONValue] {
        let document = service.document(entry.documentID)
        var source: AutomationJSONValue = .null
        if let link = entry.source {
            source = .object([
                "documentID": .string(link.documentID.uuidString),
                "workspaceID": .string(link.workspaceID.uuidString),
                "taskID": link.taskID.map { .string($0.uuidString) } ?? .null,
                "taskTitle": link.taskTitle.map { .string($0) } ?? .null,
                "linkEndedAt": date(link.linkEndedAt),
            ])
        }
        return [
            "documentID": .string(entry.documentID.uuidString),
            "workspaceID": .string(entry.workspaceID.uuidString),
            "title": .string(document?.title ?? "Scratchpad"),
            "purpose": document?.purpose.map { .string($0) } ?? .null,
            "revision": document.map { .int($0.revision) } ?? .null,
            "updatedAt": date(document?.updatedAt),
            "keptAt": date(entry.keptAt),
            "keptBy": entry.keptBy.map { .string($0) } ?? .null,
            "linked": .bool(entry.source?.isLinked == true),
            "missing": .bool(document == nil),
            "source": source,
        ]
    }

    static func overviewSnapshot(_ model: WorkspaceOverviewModel, service: WorkspaceOverviewService) -> [String: AutomationJSONValue] {
        func task(_ item: TaskBoardItem) -> [String: AutomationJSONValue] {
            [
                "taskID": item.taskID.map { .string($0.uuidString) } ?? .null,
                "taskSpaceWorkspaceID": item.taskSpaceWorkspaceID.map { .string($0.uuidString) } ?? .null,
                "title": .string(item.title),
                "stage": .string(TaskBoardPresentation.stageDescription(item).stage),
                "group": .string("\(item.stage.group)"),
                "pullRequest": item.pullRequest.map { .string($0.url) } ?? .null,
                "activityAt": date(item.activityAt > .distantPast ? item.activityAt : nil),
            ]
        }
        return [
            "workspaceID": .string(model.workspaceID.uuidString),
            "title": .string(model.title),
            "projectRoot": model.projectRoot.map { .string($0) } ?? .null,
            "synopsis": .object([
                "text": .string(model.synopsis.text),
                "source": .string(model.synopsis.isWritten ? "agent" : "toastty"),
                "updatedAt": date(model.synopsis.updatedAt),
            ]),
            "openTaskCount": .int(model.openCount),
            "finishedTaskCount": .int(model.finishedCount),
            "recent": .array(model.recent.map { recent in
                var entry = task(recent.item)
                entry["outcome"] = recent.outcome.map { .string($0) } ?? .null
                entry["outcomeSource"] = .string(recent.outcomeIsRequest ? "request" : "reply")
                return .object(entry)
            }),
            "tasks": .array(model.items.map { .object(task($0)) }),
            "scratchpads": .array(model.scratchpads.map { .object(scratchpadSnapshot($0.entry, service: service)) }),
        ]
    }
}
