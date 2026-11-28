import CoreState
import Foundation
import RemoteProtocol

enum WorkspaceOverviewError: LocalizedError, Equatable {
    case noWorkspace
    case notAScratchpad
    case missingDocument(UUID)
    case unknownScratchpad(UUID)
    case noPinnableBrowserPage
    case browserNotPinned
    case couldNotOpenBrowser

    var errorDescription: String? {
        switch self {
        case .noWorkspace: "no open workspace holds that panel"
        case .notAScratchpad: "the panel is not a Scratchpad"
        case .missingDocument(let id): "Scratchpad document \(id.uuidString) is missing"
        case .unknownScratchpad(let id): "no workspace Scratchpad has documentID \(id.uuidString)"
        case .noPinnableBrowserPage: "Open a web page or local file in the right panel first."
        case .browserNotPinned: "That browser page is not pinned in this workspace."
        case .couldNotOpenBrowser: "The browser page could not be opened in the right panel."
        }
    }
}

/// Keeps Scratchpads and browser pins in their top-level workspace, follows a kept
/// Scratchpad's source while its task lives, and holds each workspace's
/// synopsis and its tasks' last replies. Linux-first (see
/// docs/plans/workspace-overview.md); the GTK workspace page and the
/// `workspace.*` socket commands both read it.
@MainActor
final class WorkspaceOverviewService {
    /// The running app's service, for the socket commands (the shared
    /// executor has no Linux-only dependencies of its own).
    static weak var current: WorkspaceOverviewService?

    let store: AppStore
    let documentStore: ScratchpadDocumentStore
    let overviewStore: WorkspaceOverviewStore
    weak var coordinator: TaskCoordinator?
    weak var board: TaskBoardStore?
    private var observerToken: UUID?
    private var changeHandlers: [UUID: @MainActor () -> Void] = [:]
    private let now: () -> Date

    init(
        store: AppStore,
        documentStore: ScratchpadDocumentStore,
        overviewStore: WorkspaceOverviewStore,
        coordinator: TaskCoordinator?,
        board: TaskBoardStore?,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.documentStore = documentStore
        self.overviewStore = overviewStore
        self.coordinator = coordinator
        self.board = board
        self.now = now
        observerToken = store.addActionAppliedObserver { [weak self] action, _, nextState in
            guard let self else { return }
            switch action {
            case .updateScratchpadPanelState(_, let scratchpad, _):
                self.sourceDidChange(documentID: scratchpad.documentID)
            case .closePanel, .closeRightAuxPanelTab, .closeWorkspaceTab, .closeWorkspace, .closeWindow,
                 .movePanelToWorkspace, .detachPanelToNewWindow:
                self.endLinks(in: nextState)
            default:
                break
            }
        }
    }

    // MARK: Change notification

    @discardableResult
    func observeChanges(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        changeHandlers[token] = handler
        return token
    }

    func removeObserver(_ token: UUID) {
        changeHandlers.removeValue(forKey: token)
    }

    private func notify() {
        for handler in changeHandlers.values { handler() }
    }

    private func write(_ change: (inout WorkspaceOverviewStore.Contents) -> Void) throws {
        let before = overviewStore.contents
        try overviewStore.update(change)
        if overviewStore.contents != before { notify() }
    }

    // MARK: Workspaces

    /// The top-level workspace that keeps things for `workspaceID`: its
    /// parent when it is a task space, else itself.
    func topLevelWorkspaceID(for workspaceID: UUID, state: AppState? = nil) -> UUID? {
        let state = state ?? store.state
        guard let workspace = state.workspacesByID[workspaceID] else { return nil }
        return workspace.parentWorkspaceID ?? workspaceID
    }

    /// The workspace's project folder: its saved root, else the folder
    /// Toastty would give a task there.
    func projectRoot(of workspaceID: UUID) -> String? {
        guard let workspace = store.state.workspacesByID[workspaceID] else { return nil }
        if let root = workspace.rootDirectory, root.isEmpty == false { return root }
        return try? coordinator?.resolvedProjectRoot(workspaceID: workspaceID).path
    }

    // MARK: Browser pins

    static func pinnableBrowserURL(_ web: WebPanelState) -> String? {
        guard web.definition == .browser, let address = web.restorableURL,
              let url = URL(string: address) else { return nil }
        switch url.scheme?.lowercased() {
        case "http", "https": return url.host?.isEmpty == false ? address : nil
        case "file": return url.path.hasPrefix("/") ? address : nil
        default: return nil
        }
    }

    func browserPins(forWorkspace workspaceID: UUID) -> [WorkspaceBrowserPin] {
        let root = projectRoot(of: workspaceID)
        return overviewStore.contents.browserPins.reversed().filter {
            $0.workspaceID == workspaceID || (root != nil && $0.projectRoot == root)
        }
    }

    /// Pins the current address, not the browser's history or future navigation.
    func pinBrowser(panelID: UUID) throws -> (workspaceID: UUID, created: Bool) {
        guard let selection = store.state.workspaceSelection(containingPanelID: panelID),
              let workspaceID = topLevelWorkspaceID(for: selection.workspaceID),
              case .web(let web)? = selection.workspace.allPanelsByID[panelID],
              let url = Self.pinnableBrowserURL(web) else { throw WorkspaceOverviewError.noPinnableBrowserPage }
        if browserPins(forWorkspace: workspaceID).contains(where: { $0.url == url }) {
            return (workspaceID, false)
        }
        let title = web.title == WebPanelDefinition.browser.defaultTitle ? (URL(string: url)?.host ?? url) : web.title
        let pin = WorkspaceBrowserPin(workspaceID: workspaceID, projectRoot: projectRoot(of: workspaceID), url: url, title: title)
        try write { $0.browserPins.append(pin) }
        return (workspaceID, true)
    }

    /// Removing the saved address does not close any browser tab.
    func unpinBrowser(_ pin: WorkspaceBrowserPin, in workspaceID: UUID) throws {
        guard browserPins(forWorkspace: workspaceID).contains(pin) else { throw WorkspaceOverviewError.browserNotPinned }
        try write { $0.browserPins.removeAll { $0 == pin } }
    }

    func openBrowser(_ pin: WorkspaceBrowserPin, in workspaceID: UUID) throws {
        guard let workspace = store.state.workspacesByID[workspaceID] else { throw WorkspaceOverviewError.noWorkspace }
        guard browserPins(forWorkspace: workspaceID).contains(pin) else { throw WorkspaceOverviewError.browserNotPinned }
        let panel = workspace.rightAuxPanel
        if let tab = panel.orderedTabs.first(where: {
            if case .web(let web) = $0.panelState { return web.definition == .browser && web.restorableURL == pin.url }
            return false
        }) {
            // Selecting a tab also reveals a hidden right panel. A no-op
            // here is fine when the matching tab already has focus.
            _ = store.sendNavigation(.selectRightAuxPanelTab(workspaceID: workspaceID, tabID: tab.id, focus: true))
        } else if !store.createBrowserPanel(
            workspaceID: workspaceID,
            request: BrowserPanelCreateRequest(initialURL: pin.url, placementOverride: .rightPanel)
        ) {
            throw WorkspaceOverviewError.couldNotOpenBrowser
        }
    }

    // MARK: Kept Scratchpads

    /// The workspace's kept Scratchpads, newest first: those kept under its
    /// ID, and those kept by an earlier workspace of the same project.
    func scratchpads(forWorkspace workspaceID: UUID) -> [WorkspaceScratchpadEntry] {
        let root = projectRoot(of: workspaceID)
        return overviewStore.contents.scratchpads
            .filter { $0.workspaceID == workspaceID || (root != nil && $0.projectRoot == root) }
            .sorted { $0.keptAt > $1.keptAt }
    }

    func entry(documentID: UUID) -> WorkspaceScratchpadEntry? {
        overviewStore.contents.scratchpads.first { $0.documentID == documentID }
    }

    /// The entry whose live link follows `sourceDocumentID`.
    func linkedEntry(sourceDocumentID: UUID) -> WorkspaceScratchpadEntry? {
        overviewStore.contents.scratchpads.first { $0.source?.documentID == sourceDocumentID && $0.source?.isLinked == true }
    }

    /// Keeps the Scratchpad open in `panelID` in its top-level workspace.
    func keep(panelID: UUID, keptBy: String?) throws -> (entry: WorkspaceScratchpadEntry, created: Bool) {
        let state = store.state
        guard let selection = state.workspaceSelection(containingPanelID: panelID) else { throw WorkspaceOverviewError.noWorkspace }
        guard case .web(let web)? = selection.workspace.allPanelsByID[panelID],
              web.definition == .scratchpad, let scratchpad = web.scratchpad else {
            throw WorkspaceOverviewError.notAScratchpad
        }
        return try keep(sourceDocumentID: scratchpad.documentID, sourceWorkspaceID: selection.workspaceID, keptBy: keptBy)
    }

    /// Keeps a Scratchpad document from `sourceWorkspaceID`'s tab in that
    /// workspace's top-level workspace. Keeping one that is already kept
    /// (the source, while linked, or a workspace copy) returns that entry.
    func keep(sourceDocumentID: UUID, sourceWorkspaceID: UUID, keptBy: String?) throws -> (entry: WorkspaceScratchpadEntry, created: Bool) {
        if let existing = linkedEntry(sourceDocumentID: sourceDocumentID) ?? entry(documentID: sourceDocumentID) {
            return (existing, false)
        }
        let state = store.state
        guard let workspaceID = topLevelWorkspaceID(for: sourceWorkspaceID, state: state) else { throw WorkspaceOverviewError.noWorkspace }
        guard let source = try documentStore.load(documentID: sourceDocumentID) else {
            throw WorkspaceOverviewError.missingDocument(sourceDocumentID)
        }
        let task = state.workspacesByID[sourceWorkspaceID]?.taskID.flatMap { coordinator?.records.record(id: $0) }
            ?? coordinator?.records.record(taskSpaceWorkspaceID: sourceWorkspaceID)
        let copy = try documentStore.createDocument(
            title: source.title,
            content: source.content,
            sessionLink: nil,
            purpose: source.purpose,
            now: now()
        )
        let entry = WorkspaceScratchpadEntry(
            documentID: copy.documentID,
            workspaceID: workspaceID,
            projectRoot: projectRoot(of: workspaceID),
            source: .init(
                documentID: sourceDocumentID,
                workspaceID: sourceWorkspaceID,
                taskID: task?.id,
                taskTitle: task?.title,
                linkEndedAt: nil,
                syncedRevision: source.revision
            ),
            keptAt: now(),
            keptBy: keptBy
        )
        try write { $0.scratchpads.append(entry) }
        return (entry, true)
    }

    /// Removes a kept Scratchpad from its workspace and deletes its copy.
    /// The task's own Scratchpad is not touched. Open panels showing the
    /// copy close.
    func delete(documentID: UUID) throws {
        guard entry(documentID: documentID) != nil else { throw WorkspaceOverviewError.unknownScratchpad(documentID) }
        try write { $0.scratchpads.removeAll { $0.documentID == documentID } }
        for panelID in panelIDs(showing: documentID) {
            _ = store.send(.closePanel(panelID: panelID))
        }
        try? FileManager.default.removeItem(at: documentStore.documentURL(for: documentID))
    }

    /// Opens a kept Scratchpad in `workspaceID`'s right panel, or selects
    /// the tab that already shows it.
    @discardableResult
    func open(documentID: UUID, in workspaceID: UUID) throws -> Bool {
        guard entry(documentID: documentID) != nil else { throw WorkspaceOverviewError.unknownScratchpad(documentID) }
        syncIfLinked(copyDocumentID: documentID)
        guard let document = try documentStore.load(documentID: documentID) else {
            throw WorkspaceOverviewError.missingDocument(documentID)
        }
        guard let workspace = store.state.workspacesByID[workspaceID] else { throw WorkspaceOverviewError.noWorkspace }
        let panel = workspace.rightAuxPanel
        if let tab = panel.orderedTabs.first(where: {
            if case .web(let web) = $0.panelState { return web.scratchpad?.documentID == documentID }
            return false
        }) {
            if panel.isVisible == false { _ = store.send(.toggleRightAuxPanel(workspaceID: workspaceID)) }
            return store.sendNavigation(.selectRightAuxPanelTab(workspaceID: workspaceID, tabID: tab.id, focus: true))
        }
        return store.sendNavigation(.createWebPanel(
            workspaceID: workspaceID,
            panel: WebPanelState(
                definition: .scratchpad,
                title: document.title,
                scratchpad: ScratchpadState(documentID: documentID, sessionLink: nil, revision: document.revision, purpose: document.purpose)
            ),
            placement: .rightPanel
        ))
    }

    func document(_ documentID: UUID) -> ScratchpadDocument? {
        try? documentStore.load(documentID: documentID)
    }

    // MARK: Following the source

    private func sourceDidChange(documentID: UUID) {
        guard let entry = linkedEntry(sourceDocumentID: documentID) else { return }
        sync(entry)
    }

    /// Brings a linked copy up to its source, as the workspace page does
    /// before showing it.
    func syncIfLinked(copyDocumentID: UUID) {
        guard let entry = entry(documentID: copyDocumentID), entry.source?.isLinked == true else { return }
        sync(entry)
    }

    func syncLinked(forWorkspace workspaceID: UUID) {
        endLinks(in: store.state)
        for entry in scratchpads(forWorkspace: workspaceID) where entry.source?.isLinked == true {
            sync(entry)
        }
    }

    private func sync(_ entry: WorkspaceScratchpadEntry) {
        guard let source = entry.source,
              let sourceDocument = try? documentStore.load(documentID: source.documentID),
              sourceDocument.revision != source.syncedRevision else { return }
        let copy: ScratchpadDocument
        do {
            copy = try documentStore.replaceContent(
                documentID: entry.documentID,
                title: sourceDocument.title,
                content: sourceDocument.content,
                expectedRevision: nil,
                sessionLink: nil,
                purpose: sourceDocument.purpose ?? "",
                now: now()
            )
            try write { contents in
                guard let index = contents.scratchpads.firstIndex(where: { $0.documentID == entry.documentID }) else { return }
                contents.scratchpads[index].source?.syncedRevision = sourceDocument.revision
            }
        } catch {
            ToasttyLog.warning(
                "Could not copy a Scratchpad into its workspace",
                category: .store,
                metadata: ["document_id": entry.documentID.uuidString, "error": error.localizedDescription]
            )
            return
        }
        refreshPanels(showing: copy)
    }

    /// Panels that show the copy reload when their state's revision moves.
    /// The store applies one action at a time: send after this one.
    private func refreshPanels(showing copy: ScratchpadDocument) {
        let panelIDs = panelIDs(showing: copy.documentID)
        guard panelIDs.isEmpty == false else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for panelID in panelIDs {
                guard let selection = self.store.state.workspaceSelection(containingPanelID: panelID),
                      case .web(let web)? = selection.workspace.allPanelsByID[panelID],
                      let current = web.scratchpad else { continue }
                _ = self.store.send(.updateScratchpadPanelState(
                    panelID: panelID,
                    scratchpad: ScratchpadState(documentID: copy.documentID, sessionLink: current.sessionLink, revision: copy.revision, purpose: copy.purpose),
                    title: copy.title
                ))
            }
        }
    }

    private func panelIDs(showing documentID: UUID) -> [UUID] {
        store.state.workspacesByID.values.flatMap { workspace in
            workspace.allPanelsByID.compactMap { panelID, panel -> UUID? in
                guard case .web(let web) = panel, web.scratchpad?.documentID == documentID else { return nil }
                return panelID
            }
        }
    }

    /// Ends the link of every kept Scratchpad whose source workspace closed
    /// or whose source document is gone, after one last copy.
    func endLinks(in state: AppState) {
        let ended = overviewStore.contents.scratchpads.filter { entry in
            guard let source = entry.source, source.isLinked else { return false }
            return state.workspacesByID[source.workspaceID] == nil
                || (try? documentStore.load(documentID: source.documentID)) == nil
        }
        guard ended.isEmpty == false else { return }
        for entry in ended { sync(entry) }
        let endedIDs = Set(ended.map(\.documentID))
        let at = now()
        try? write { contents in
            for index in contents.scratchpads.indices where endedIDs.contains(contents.scratchpads[index].documentID) {
                contents.scratchpads[index].source?.linkEndedAt = at
            }
        }
    }

    // MARK: Synopsis and outcomes

    func synopsis(forWorkspace workspaceID: UUID) -> WorkspaceSynopsis? {
        if let synopsis = overviewStore.contents.synopses[workspaceID.uuidString] { return synopsis }
        guard let root = projectRoot(of: workspaceID) else { return nil }
        return overviewStore.contents.synopses.values
            .filter { $0.projectRoot == root }
            .max { $0.updatedAt < $1.updatedAt }
    }

    /// Sets the workspace's synopsis; empty text clears it.
    func setSynopsis(_ text: String, forWorkspace workspaceID: UUID, sessionID: String?) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = projectRoot(of: workspaceID)
        try write { contents in
            if trimmed.isEmpty {
                contents.synopses.removeValue(forKey: workspaceID.uuidString)
                if let root {
                    contents.synopses = contents.synopses.filter { $0.value.projectRoot != root }
                }
            } else {
                contents.synopses[workspaceID.uuidString] = WorkspaceSynopsis(
                    text: WorkspaceOverviewStore.clipped(trimmed, to: WorkspaceOverviewStore.maxSynopsisCharacters),
                    updatedAt: now(),
                    sessionID: sessionID,
                    projectRoot: root
                )
            }
        }
    }

    func outcome(taskID: UUID) -> WorkspaceTaskOutcome? {
        overviewStore.contents.outcomes[taskID.uuidString]
    }

    /// The task's latest agent reply while its session lives, saved so the
    /// page can still show it after the session ends.
    func refreshOutcome(of record: TaskRecord) -> WorkspaceTaskOutcome? {
        guard let reply = coordinator?.lastReply(of: record) else { return outcome(taskID: record.id) }
        let text = WorkspaceOverviewStore.clipped(reply.text, to: WorkspaceOverviewStore.maxOutcomeCharacters)
        guard text.isEmpty == false else { return outcome(taskID: record.id) }
        let next = WorkspaceTaskOutcome(text: text, at: reply.at ?? now())
        if outcome(taskID: record.id)?.text != text {
            try? write { $0.outcomes[record.id.uuidString] = next }
        }
        return outcome(taskID: record.id) ?? next
    }

    // MARK: Task contexts

    func context(taskID: UUID) -> WorkspaceTaskContext? {
        overviewStore.contents.contexts[taskID.uuidString]
    }

    /// Sets what a task's agent wrote for whoever continues its work; empty
    /// text clears it.
    func setContext(_ text: String, for record: TaskRecord, sessionID: String?) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try write { contents in
            if trimmed.isEmpty {
                contents.contexts.removeValue(forKey: record.id.uuidString)
            } else {
                contents.contexts[record.id.uuidString] = WorkspaceTaskContext(
                    text: WorkspaceOverviewStore.clipped(trimmed, to: WorkspaceOverviewStore.maxContextCharacters),
                    at: now(),
                    sessionID: sessionID,
                    taskTitle: record.title
                )
            }
        }
    }

    /// The kept Scratchpads whose source was the task's.
    func scratchpads(fromTask taskID: UUID) -> [WorkspaceScratchpadEntry] {
        overviewStore.contents.scratchpads
            .filter { $0.source?.taskID == taskID }
            .sorted { $0.keptAt > $1.keptAt }
    }

    /// What **Continue as New Task** attaches to the new task: the facts
    /// Toastty knows about the earlier task, then the context its agent
    /// wrote, or without one its last reply.
    func continuation(of record: TaskRecord) -> TaskContinuation {
        let outcome = context(taskID: record.id) == nil ? refreshOutcome(of: record) : nil
        let scratchpads = scratchpads(fromTask: record.id).map { entry in
            (title: document(entry.documentID)?.title ?? "Scratchpad", documentID: entry.documentID)
        }
        return TaskContinuation.make(
            record: record,
            context: context(taskID: record.id),
            outcome: outcome,
            scratchpads: scratchpads
        )
    }
}

/// The file **Continue as New Task** attaches to the new task.
struct TaskContinuation: Equatable {
    var taskID: UUID
    var taskTitle: String
    var fileName: String
    var text: String
    /// The earlier task's agent wrote a context; otherwise the text holds
    /// its last reply or only its request.
    var hasWrittenContext: Bool

    static let requestCharacters = 1_500

    static func make(
        record: TaskRecord,
        context: WorkspaceTaskContext?,
        outcome: WorkspaceTaskOutcome?,
        scratchpads: [(title: String, documentID: UUID)]
    ) -> TaskContinuation {
        var facts = ["- Task: \(CoordinatorTaskLink.markdown(taskID: record.id, title: record.title))"]
        if let branch = record.worktree?.branch {
            let base = record.startWork?.base.map { " (from `\($0)`)" } ?? ""
            facts.append("- Branch: `\(branch)`\(base)")
        }
        if let url = record.pullRequestURL {
            var line = "- Pull request: \(url)"
            if record.mergedAt != nil {
                line += record.mergeCommit.map { ", merged as `\($0)`" } ?? ", merged"
            }
            facts.append(line)
        }
        if let projectRoot = record.projectRoot {
            facts.append("- Project folder: `\(projectRoot)`")
        }
        for scratchpad in scratchpads {
            facts.append(
                "- Kept Scratchpad: \(scratchpad.title) (`documentID=\(scratchpad.documentID.uuidString)`; "
                    + "read it with `workspace.scratchpad.export`)"
            )
        }

        var sections = [
            "# Continues \u{201C}\(record.title)\u{201D}",
            "This task continues an earlier Toastty task. Read this file before you start: it says what the earlier task did and where it stopped. The earlier task's worktree may be gone; start from this task's own worktree.",
            "## The earlier task\n\n" + facts.joined(separator: "\n"),
        ]
        let request = WorkspaceOverviewStore.clipped(record.text, to: requestCharacters)
        if request.isEmpty == false {
            sections.append("## Its request\n\n" + request.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }.joined(separator: "\n"))
        }
        if let context {
            sections.append("## Context from its agent\n\n" + nestedHeadings(context.text))
        } else if let outcome {
            sections.append("## Its agent's last reply\n\nIts agent wrote no context for the next task; this is its last reply.\n\n" + outcome.text)
        }
        let slug = record.slug.isEmpty ? "task" : record.slug
        return TaskContinuation(
            taskID: record.id,
            taskTitle: record.title,
            fileName: "continues-\(slug).md",
            text: sections.joined(separator: "\n\n") + "\n",
            hasWrittenContext: context != nil
        )
    }

    /// The agent's headings one level down, so they sit under Toastty's
    /// "Context from its agent". Lines in code fences stay as they are.
    static func nestedHeadings(_ text: String) -> String {
        var inFence = false
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle() }
            guard inFence == false, line.hasPrefix("#") else { return String(line) }
            return "#" + line
        }.joined(separator: "\n")
    }
}
