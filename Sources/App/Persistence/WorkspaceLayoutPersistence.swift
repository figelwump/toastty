import AppKit
import CoreState
import Foundation

struct WorkspaceLayoutPersistenceContext {
    let profileID: String
    let fileURL: URL
    let shouldMigrateLegacyStore: Bool

    static func resolve(processInfo: ProcessInfo = .processInfo) -> WorkspaceLayoutPersistenceContext {
        let runtimePaths = ToasttyRuntimePaths.resolve(environment: processInfo.environment)
        return WorkspaceLayoutPersistenceContext(
            profileID: WorkspaceLayoutProfileResolver.resolve(processInfo: processInfo),
            fileURL: WorkspaceLayoutPersistenceLocation.fileURL(environment: processInfo.environment),
            shouldMigrateLegacyStore: runtimePaths.isRuntimeHomeEnabled == false
        )
    }

    func loadState() -> (state: AppState, layout: WorkspaceLayoutSnapshot, resolvedProfileID: String)? {
        migrateLegacyStoreIfNeeded()
        let store = WorkspaceLayoutPersistenceStore(fileURL: fileURL)
        guard let loadResult = store.loadLayout(
            for: profileID,
            fallbackProfileID: WorkspaceLayoutProfileResolver.fallbackProfileID
        ) else {
            return nil
        }
        return (loadResult.layout.makeAppState(), loadResult.layout, loadResult.resolvedProfileID)
    }

    private func migrateLegacyStoreIfNeeded() {
        guard shouldMigrateLegacyStore else { return }
        let legacyURL = WorkspaceLayoutPersistenceLocation.legacyFileURL()
        guard legacyURL.standardizedFileURL != fileURL.standardizedFileURL else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) == false else { return }
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: legacyURL, to: fileURL)
            ToasttyLog.info(
                "Migrated workspace layout store to ~/.toastty",
                category: .state,
                metadata: [
                    "path": fileURL.path,
                ]
            )
        } catch {
            ToasttyLog.warning(
                "Failed to migrate legacy workspace layout store",
                category: .state,
                metadata: [
                    "path": fileURL.path,
                    "legacy_path": legacyURL.path,
                    "error": error.localizedDescription,
                ]
            )
        }
    }
}

@MainActor
final class WorkspaceLayoutPersistenceCoordinator {
    private static let persistDebounceNanoseconds: UInt64 = 250_000_000

    private let context: WorkspaceLayoutPersistenceContext
    private let store: WorkspaceLayoutPersistenceStore
    private let persistDropAuditLogger: @MainActor ([String: String]) -> Void
    private let layoutLifecycleLogger: @MainActor (String, [String: String]) -> Void
    private var pendingPersistTask: Task<Void, Never>?
    private var lastPersistedLayout: WorkspaceLayoutSnapshot?
    private var pendingPersistBaselineLayout: WorkspaceLayoutSnapshot?
    private var pendingPersistDropTrigger: String?

    init(
        context: WorkspaceLayoutPersistenceContext,
        persistDropAuditLogger: @escaping @MainActor ([String: String]) -> Void = { metadata in
            ToasttyLog.info(
                "Persisted workspace layout after window/workspace drop",
                category: .state,
                metadata: metadata
            )
        },
        layoutLifecycleLogger: @escaping @MainActor (String, [String: String]) -> Void = { message, metadata in
            ToasttyLog.info(
                message,
                category: .state,
                metadata: metadata
            )
        }
    ) {
        self.context = context
        self.persistDropAuditLogger = persistDropAuditLogger
        self.layoutLifecycleLogger = layoutLifecycleLogger
        store = WorkspaceLayoutPersistenceStore(fileURL: context.fileURL)
    }

    deinit {
        pendingPersistTask?.cancel()
    }

    func handleAppliedAction(_ action: AppAction, previousState: AppState, nextState: AppState) {
        let previousLayout = WorkspaceLayoutSnapshot(state: previousState)
        let nextLayout = WorkspaceLayoutSnapshot(state: nextState)
        guard previousLayout != nextLayout else { return }
        logTopologyMutationIfNeeded(
            action,
            previousLayout: previousLayout,
            nextLayout: nextLayout
        )
        logResumeRecordMutationIfNeeded(
            action,
            previousLayout: previousLayout,
            nextLayout: nextLayout
        )
        schedulePersist(
            layout: nextLayout,
            reason: "action_\(action.logName)",
            baselineLayout: previousLayout,
            baselineTrigger: "action_\(action.logName)"
        )
    }

    func flushCurrentState(_ state: AppState, reason: String) {
        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        let baselineLayout = pendingPersistBaselineLayout
        let dropTrigger = pendingPersistDropTrigger
        pendingPersistBaselineLayout = nil
        pendingPersistDropTrigger = nil
        persistNow(
            layout: WorkspaceLayoutSnapshot(state: state),
            reason: reason,
            baselineLayout: baselineLayout,
            dropTrigger: dropTrigger
        )
    }

    private func schedulePersist(
        layout: WorkspaceLayoutSnapshot,
        reason: String,
        baselineLayout: WorkspaceLayoutSnapshot,
        baselineTrigger: String
    ) {
        let pendingBaselineLayout: WorkspaceLayoutSnapshot
        if pendingPersistBaselineLayout == nil {
            pendingPersistBaselineLayout = baselineLayout
            pendingBaselineLayout = baselineLayout
        } else {
            pendingBaselineLayout = pendingPersistBaselineLayout ?? baselineLayout
        }
        if pendingPersistDropTrigger == nil,
           LayoutAuditDiff(
               before: LayoutAuditSummary(layout: pendingBaselineLayout),
               after: LayoutAuditSummary(layout: layout)
           ).didDropContainerLayout {
            pendingPersistDropTrigger = baselineTrigger
        }
        pendingPersistTask?.cancel()
        pendingPersistTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.persistDebounceNanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            guard Task.isCancelled == false else { return }
            let baselineLayout = self.pendingPersistBaselineLayout
            let dropTrigger = self.pendingPersistDropTrigger
            self.pendingPersistBaselineLayout = nil
            self.pendingPersistDropTrigger = nil
            self.persistNow(
                layout: layout,
                reason: reason,
                baselineLayout: baselineLayout,
                dropTrigger: dropTrigger
            )
        }
    }

    private func persistNow(
        layout: WorkspaceLayoutSnapshot,
        reason: String,
        baselineLayout: WorkspaceLayoutSnapshot?,
        dropTrigger: String?
    ) {
        guard layout != lastPersistedLayout else { return }
        let baselineDropMetadata = baselineLayout.flatMap {
            persistDropMetadata(
                previousLayout: $0,
                nextLayout: layout,
                trigger: dropTrigger ?? "pending_persist_drop"
            )
        }
        let lastPersistedDropMetadata = lastPersistedLayout.flatMap {
            persistDropMetadata(
                previousLayout: $0,
                nextLayout: layout,
                trigger: "last_persisted_layout"
            )
        }
        let effectiveDropMetadata = baselineDropMetadata ?? lastPersistedDropMetadata

        let previousResumeRecordSummary = (
            baselineLayout ?? lastPersistedLayout
        )?.managedAgentResumeRecordSummary() ?? "none"
        let nextResumeRecordSummary = layout.managedAgentResumeRecordSummary()
        let nextResumeRecordCount = layout.managedAgentResumeRecordCount

        guard store.persistLayout(layout, for: context.profileID) else {
            return
        }

        lastPersistedLayout = layout
        ToasttyLog.debug(
            "Persisted workspace layout",
            category: .state,
            metadata: [
                "profile_id": context.profileID,
                "reason": reason,
                "path": context.fileURL.path,
                "managed_agent_resume_record_count": String(nextResumeRecordCount),
                "managed_agent_resume_records": nextResumeRecordSummary,
            ]
        )

        logResumeRecordPersistenceIfNeeded(
            reason: reason,
            previousSummary: previousResumeRecordSummary,
            nextSummary: nextResumeRecordSummary,
            nextCount: nextResumeRecordCount
        )

        if let effectiveDropMetadata {
            var metadata = effectiveDropMetadata
            metadata["profile_id"] = context.profileID
            metadata["reason"] = reason
            metadata["path"] = context.fileURL.path
            metadata["mutation"] = "persist_layout_drop"
            persistDropAuditLogger(metadata)
        }
    }

    private func logTopologyMutationIfNeeded(
        _ action: AppAction,
        previousLayout: WorkspaceLayoutSnapshot,
        nextLayout: WorkspaceLayoutSnapshot
    ) {
        let previousTabsByID = Dictionary(
            previousLayout.tabLogEntries.map { ($0.tabID, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let nextTabsByID = Dictionary(
            nextLayout.tabLogEntries.map { ($0.tabID, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let previousPanelEntriesByID = Dictionary(
            previousLayout.panelLogEntries.map { ($0.panelID, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let nextPanelEntriesByID = Dictionary(
            nextLayout.panelLogEntries.map { ($0.panelID, $0) },
            uniquingKeysWith: { current, _ in current }
        )

        for tabID in sortedUnion(previousTabsByID.keys, nextTabsByID.keys) {
            let previousEntry = previousTabsByID[tabID]
            let nextEntry = nextTabsByID[tabID]

            switch (previousEntry, nextEntry) {
            case (nil, let nextEntry?):
                logTopologyMutation(
                    action: action,
                    mutation: "workspace_tab_created",
                    metadata: nextEntry.metadata
                )

            case (let previousEntry?, nil):
                logTopologyMutation(
                    action: action,
                    mutation: "workspace_tab_removed",
                    metadata: previousEntry.metadata
                )

            case (let previousEntry?, let nextEntry?)
                where previousEntry.locationKey != nextEntry.locationKey:
                var metadata = nextEntry.metadata
                metadata.merge(previousEntry.metadata(prefix: "previous_")) { current, _ in current }
                logTopologyMutation(
                    action: action,
                    mutation: "workspace_tab_moved",
                    metadata: metadata
                )

            default:
                break
            }
        }

        for panelID in sortedUnion(previousPanelEntriesByID.keys, nextPanelEntriesByID.keys) {
            let previousEntry = previousPanelEntriesByID[panelID]
            let nextEntry = nextPanelEntriesByID[panelID]

            switch (previousEntry, nextEntry) {
            case (nil, let nextEntry?):
                var metadata = nextEntry.metadata
                if let sourcePanelID = sourcePanelID(
                    for: action,
                    previousLayout: previousLayout,
                    nextEntry: nextEntry
                ) {
                    metadata["source_panel_id"] = sourcePanelID.uuidString
                }
                logTopologyMutation(
                    action: action,
                    mutation: "panel_created",
                    metadata: metadata
                )

            case (let previousEntry?, nil):
                logTopologyMutation(
                    action: action,
                    mutation: "panel_removed",
                    metadata: previousEntry.metadata
                )

            case (let previousEntry?, let nextEntry?)
                where previousEntry.locationKey != nextEntry.locationKey:
                var metadata = nextEntry.metadata
                metadata.merge(previousEntry.metadata(prefix: "previous_")) { current, _ in current }
                logTopologyMutation(
                    action: action,
                    mutation: "panel_moved",
                    metadata: metadata
                )

            default:
                break
            }
        }
    }

    private func logTopologyMutation(
        action: AppAction,
        mutation: String,
        metadata: [String: String]
    ) {
        var metadata = metadata
        metadata["action"] = action.logName
        metadata["mutation"] = mutation
        layoutLifecycleLogger("Workspace layout topology changed", metadata)
    }

    private func logResumeRecordMutationIfNeeded(
        _ action: AppAction,
        previousLayout: WorkspaceLayoutSnapshot,
        nextLayout: WorkspaceLayoutSnapshot
    ) {
        let explicitResumeRecordAction: (panelID: UUID, resumeRecord: ManagedAgentResumeRecord?)?
        if case .updateTerminalPanelResumeRecord(let panelID, let resumeRecord) = action {
            explicitResumeRecordAction = (panelID, resumeRecord)
        } else {
            explicitResumeRecordAction = nil
        }

        let previousEntriesByPanelID = Dictionary(
            previousLayout.panelLogEntries.map { ($0.panelID, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let nextEntriesByPanelID = Dictionary(
            nextLayout.panelLogEntries.map { ($0.panelID, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let changedPanelIDs = sortedUnion(previousEntriesByPanelID.keys, nextEntriesByPanelID.keys)
            .filter { panelID in
                let previousEntry = previousEntriesByPanelID[panelID]
                let nextEntry = nextEntriesByPanelID[panelID]
                return previousEntry?.resumeRecord != nextEntry?.resumeRecord
            }

        guard changedPanelIDs.isEmpty == false || explicitResumeRecordAction != nil else {
            return
        }

        let previousCount = String(previousLayout.managedAgentResumeRecordCount)
        let nextCount = String(nextLayout.managedAgentResumeRecordCount)
        let previousSummary = previousLayout.managedAgentResumeRecordSummary()
        let nextSummary = nextLayout.managedAgentResumeRecordSummary()
        for panelID in changedPanelIDs {
            let previousEntry = previousEntriesByPanelID[panelID]
            let nextEntry = nextEntriesByPanelID[panelID]
            var metadata = (nextEntry ?? previousEntry)?.metadata ?? ["panel_id": panelID.uuidString]
            metadata["action"] = action.logName
            metadata["mutation"] = "managed_agent_resume_record_changed"
            metadata["resume_record_action"] = resumeRecordAction(
                previousEntry: previousEntry,
                nextEntry: nextEntry
            )
            metadata["explicit_update_panel_id"] = explicitResumeRecordAction?.panelID.uuidString ?? "none"
            metadata["previous_count"] = previousCount
            metadata["next_count"] = nextCount
            metadata["previous_records"] = previousSummary
            metadata["next_records"] = nextSummary
            if let previousRecord = previousEntry?.resumeRecord {
                metadata["previous_agent"] = previousRecord.agent.rawValue
                metadata["previous_native_session_id"] = previousRecord.nativeSessionID
                metadata["previous_session_file_basename"] = (previousRecord.sessionFilePath as NSString).lastPathComponent
                metadata["previous_cwd"] = previousRecord.cwd
                metadata["previous_workspace_scope"] = resumeRecordScopeMetadata(previousRecord.scopedWorkspaceIDs)
            }
            if let nextRecord = nextEntry?.resumeRecord {
                metadata["agent"] = nextRecord.agent.rawValue
                metadata["native_session_id"] = nextRecord.nativeSessionID
                metadata["session_file_basename"] = (nextRecord.sessionFilePath as NSString).lastPathComponent
                metadata["cwd"] = nextRecord.cwd
            }

            layoutLifecycleLogger("Managed agent resume record changed", metadata)
        }
    }

    private func logResumeRecordPersistenceIfNeeded(
        reason: String,
        previousSummary: String,
        nextSummary: String,
        nextCount: Int
    ) {
        guard reason == "application_will_terminate"
            || reason == "action_updateTerminalPanelResumeRecord"
            || previousSummary != nextSummary else {
            return
        }

        ToasttyLog.info(
            "Persisted workspace layout managed agent resume record state",
            category: .state,
            metadata: [
                "profile_id": context.profileID,
                "reason": reason,
                "path": context.fileURL.path,
                "previous_records": previousSummary,
                "next_records": nextSummary,
                "next_count": String(nextCount),
            ]
        )
    }

    private func resumeRecordAction(
        previousEntry: WorkspaceLayoutPanelLogEntry?,
        nextEntry: WorkspaceLayoutPanelLogEntry?
    ) -> String {
        switch (previousEntry?.resumeRecord, nextEntry?.resumeRecord) {
        case (nil, .some(_)):
            return "attach"
        case (.some(_), nil):
            return nextEntry == nil ? "remove_with_panel" : "clear"
        case (.some(_), .some(_)):
            return "change"
        case (nil, nil):
            return "none"
        }
    }

    private func resumeRecordScopeMetadata(_ scope: Set<UUID>?) -> String {
        guard let scope else { return "unrestricted" }
        if scope.isEmpty { return "own_workspace_only" }
        return scope
            .map(\.uuidString)
            .sorted()
            .joined(separator: ",")
    }

    private func sourcePanelID(
        for action: AppAction,
        previousLayout: WorkspaceLayoutSnapshot,
        nextEntry: WorkspaceLayoutPanelLogEntry
    ) -> UUID? {
        switch action {
        case .splitFocusedSlot(let workspaceID, _),
             .splitFocusedSlotInDirection(let workspaceID, _),
             .splitFocusedSlotInDirectionWithWorkingDirectory(let workspaceID, _, _),
             .splitFocusedSlotInDirectionWithTerminalProfile(let workspaceID, _, _):
            guard workspaceID == nextEntry.workspaceID,
                  let workspace = previousLayout.workspacesByID[workspaceID],
                  let selectedTabID = workspace.resolvedSelectedTabID,
                  selectedTabID == nextEntry.tabID,
                  let selectedTab = workspace.tabsByID[selectedTabID] else {
                return nil
            }
            return selectedTab.focusedPanelID

        case .createTerminalPanel(let workspaceID, let slotID):
            guard workspaceID == nextEntry.workspaceID,
                  let workspace = previousLayout.workspacesByID[workspaceID] else {
                return nil
            }
            for tab in workspace.orderedTabs {
                guard let slot = tab.layoutTree.slotNode(slotID: slotID),
                      case .slot(_, let panelID) = slot else {
                    continue
                }
                return panelID
            }
            return nil

        default:
            return nil
        }
    }

    private func sortedUnion<S: Sequence>(_ lhs: S, _ rhs: S) -> [UUID] where S.Element == UUID {
        Set(lhs).union(Set(rhs)).sorted { $0.uuidString < $1.uuidString }
    }

    private func persistDropMetadata(
        previousLayout: WorkspaceLayoutSnapshot,
        nextLayout: WorkspaceLayoutSnapshot,
        trigger: String
    ) -> [String: String]? {
        let diff = LayoutAuditDiff(
            before: LayoutAuditSummary(layout: previousLayout),
            after: LayoutAuditSummary(layout: nextLayout)
        )
        guard diff.didDropContainerLayout else { return nil }
        var metadata = diff.metadata
        metadata["trigger"] = trigger
        return metadata
    }
}

enum WorkspaceLayoutPersistenceLocation {
    private static let configDirectoryName = ".toastty"
    private static let legacyConfigDirectoryName = ".config/toastty"
    private static let fileName = "workspace-layout-profiles.json"

    static func fileURL(
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        ).workspaceLayoutsFileURL
    }

    static func legacyFileURL(homeDirectoryPath: String = NSHomeDirectory()) -> URL {
        URL(filePath: homeDirectoryPath)
            .appending(path: legacyConfigDirectoryName, directoryHint: .isDirectory)
            .appending(path: fileName, directoryHint: .notDirectory)
    }
}

enum WorkspaceLayoutProfileResolver {
    static let fallbackProfileID = "default"
    private static let profileOverrideEnvironmentKey = "TOASTTY_LAYOUT_PROFILE"

    static func resolve(processInfo: ProcessInfo = .processInfo) -> String {
        if let override = normalizedOverride(from: processInfo.environment[profileOverrideEnvironmentKey]) {
            return override
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return fallbackProfileID
        }

        let pixelWidth = max(1, Int((screen.frame.width * screen.backingScaleFactor).rounded()))
        let pixelHeight = max(1, Int((screen.frame.height * screen.backingScaleFactor).rounded()))
        let scaleLabel = formattedScale(screen.backingScaleFactor)
        return "display-\(pixelWidth)x\(pixelHeight)@\(scaleLabel)x"
    }

    private static func normalizedOverride(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let normalized = trimmed.lowercased().map { character -> Character in
            switch character {
            case "a"..."z", "0"..."9", "-", "_", ".":
                return character
            default:
                return "-"
            }
        }

        let collapsed = String(normalized)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")

        guard collapsed.isEmpty == false else {
            return nil
        }

        return String(collapsed.prefix(80))
    }

    private static func formattedScale(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(rounded - value) < 0.0001 {
            return String(Int(rounded))
        }
        return String(format: "%.2f", value)
    }
}
