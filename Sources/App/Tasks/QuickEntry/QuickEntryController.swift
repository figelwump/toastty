import AppKit
import Combine
import CoreState
import Foundation
import RemoteProtocol

/// Opens the quick entry panel from the global shortcut and from Toastty's
/// own entry points. While a coordinator exists, the panel sends its text
/// to the coordinator, and a second key creates the task directly. With no
/// coordinator, it creates the task through `task.create`.
///
/// This file is the shared core. The windows (panel, pickers, toast), the
/// focus handoff, the file chooser and the global key are the platform's:
/// `QuickEntryPresentation` in `QuickEntryController+Mac.swift`, and in
/// linux/Sources/ToasttyAppLogic/Tasks for the GTK frontend.
@MainActor
final class QuickEntryController: ObservableObject {
    /// The configured shortcut, shown on File ▸ New Task…; nil when
    /// `tasks.toml` turns it off.
    @Published private(set) var shortcut: QuickEntryShortcut? = .default
    /// True while macOS delivers the shortcut from every app. It is false
    /// when another app holds the keys: the shortcut then works only in
    /// Toastty's menu.
    @Published private(set) var isShortcutGlobal = false

    private let store: AppStore
    /// The profiles in agents.toml, as a launch resolves them.
    private let agentProfiles: @MainActor () -> [AgentLaunchProfileSummary]
    /// The presets the user picks, for the Agent picker's Frequent list,
    /// and the workspace last used.
    private let presetUsage: QuickEntryPresetUsage?
    private let create: @MainActor (TaskCreateRequest) async throws -> TaskRecord
    private let configLoader: @MainActor () throws -> TasksConfig
    private let stagingRootURL: URL
    private let registersGlobalHotKey: Bool
    let toastDuration: Duration
    /// The platform's windows and focus state.
    let presentation: QuickEntryPresentation

    private(set) var model: QuickEntryModel?
    private(set) var picker: QuickEntryPicker?
    /// Models that live sessions of a provider reported recently, most
    /// recent first: the list the iPhone's start-session screen offers. It
    /// comes from remote access, which is set up after this controller.
    var recentModels: @MainActor (AgentKind) -> [String] = { _ in [] }
    /// The app's coordinator, which is set up after this controller. While
    /// its workspace exists, a new panel sends to it.
    weak var coordinatorController: CoordinatorController?
    /// Optional CLI catalog lookup. The composition root supplies background
    /// I/O; tests and other providers need no installed Codex or remote access.
    var loadCodexModels: (@MainActor () async throws -> [String])?
    private(set) var modelLoadTask: Task<Void, Never>?
    private var cachedCodexModels: [String] = []
    private var codexCatalogGeneration = 0
    private var codexCatalogStatus: QuickEntryCodexCatalogStatus? {
        didSet { picker?.codexCatalogStatus = picker?.kind == .agent ? codexCatalogStatus : nil }
    }
    /// Whether `tasks.toml` has been read without error since launch.
    private var hasLoadedShortcut = false
    /// Why the shortcut did not work as configured at launch, such as an
    /// error in `tasks.toml`, until a window shows it.
    private(set) var launchMessage: String?
    /// The Workspace list's folder checks, by what the state said about
    /// each folder. A new panel checks again, so a repository made since
    /// then shows.
    private var workspaceFolderResolutions: [QuickEntryWorkspaceFolders.Source: QuickEntryWorkspaceFolders.Resolution] = [:]
    private var workspaceFolderSources: [String: QuickEntryWorkspaceFolders.Source] = [:]
    private var workspaceFolderCheck: Task<Void, Never>?
    /// Whether Toastty may take the default shortcut when `tasks.toml`
    /// does not set one: the What's new sheet asks the user first. Set by
    /// the app; without it, the default applies.
    var defaultShortcutPermission: @MainActor () -> QuickEntryShortcutPermission = { .allowed }
    /// Whether `launchMessage` waits for the What's new sheet: the key is
    /// read again when the sheet ends, and that message replaces this one,
    /// so the user sees it once. Set by the app; without it, the message
    /// shows at once.
    var launchMessageWaits: @MainActor () -> Bool = { false }
    // Removed in deinit, which is not main-actor isolated.
    nonisolated(unsafe) private var terminationObserver: (any NSObjectProtocol)?
    /// What the last toast said.
    private(set) var lastToastMessage: String?

    /// A draft is open in the panel.
    var isPresented: Bool { model != nil }

    init(
        store: AppStore,
        agentProfiles: @escaping @MainActor () -> [AgentLaunchProfileSummary],
        presetUsage: QuickEntryPresetUsage? = nil,
        create: @escaping @MainActor (TaskCreateRequest) async throws -> TaskRecord,
        configLoader: @escaping @MainActor () throws -> TasksConfig,
        stagingRootURL: URL = FileManager.default.temporaryDirectory
            .appending(path: "toastty-quick-entry", directoryHint: .isDirectory),
        registersGlobalHotKey: Bool,
        toastDuration: Duration = .milliseconds(1600),
        frontmostApplication: @escaping @MainActor () -> QuickEntryFrontmostApplication? = QuickEntryPresentation.frontmostApplication
    ) {
        self.store = store
        self.agentProfiles = agentProfiles
        self.presetUsage = presetUsage
        self.create = create
        self.configLoader = configLoader
        self.stagingRootURL = stagingRootURL
        self.registersGlobalHotKey = registersGlobalHotKey
        self.toastDuration = toastDuration
        presentation = QuickEntryPresentation(frontmostApplication: frontmostApplication)
        // Linux calls `handleTermination()` from its shutdown instead:
        // corelibs runs a queue-targeted observer by enqueueing it and
        // waiting, which deadlocks a main-actor poster that is not
        // `OperationQueue.current` (Swift Testing's main actor).
        #if !os(Linux)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleTermination()
            }
        }
        #endif
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    /// Quitting with the panel open discards the draft's staged files.
    func handleTermination() {
        model?.removeStagingDirectoryNow()
    }

    // MARK: - Shortcut

    /// Reads the shortcut at launch, before any window is up, and again
    /// when the What's new sheet ends. A message waits in `launchMessage`
    /// until `presentLaunchMessageIfNeeded` shows it.
    func loadShortcutAtLaunch() {
        launchMessage = reloadShortcut()
    }

    /// Shows the launch message once, over the window that got the
    /// keyboard. `present` returns false when that window cannot show it
    /// now, and the message then waits for the next window.
    func presentLaunchMessageIfNeeded(
        windowID: UUID,
        present: @MainActor (_ windowID: UUID, _ message: String) -> Bool
    ) {
        guard let launchMessage, launchMessageWaits() == false,
              present(windowID, launchMessage) else { return }
        self.launchMessage = nil
    }

    /// Reads `[quick_entry] shortcut` and registers it. Returns a message
    /// when the shortcut could not be set up.
    @discardableResult
    func reloadShortcut() -> String? {
        // A reload shows its own message, so a launch message that no
        // window showed yet is out of date.
        launchMessage = nil
        let configured: QuickEntryShortcut?
        var message: String?
        do {
            let quickEntry = try configLoader().quickEntry
            // A shortcut written in the file wins; otherwise the default
            // applies only once the user allowed it.
            configured = quickEntry.isShortcutSet || defaultShortcutPermission() == .allowed ? quickEntry.shortcut : nil
            hasLoadedShortcut = true
        } catch {
            guard hasLoadedShortcut else {
                // At launch there is no earlier setting: use the default,
                // if the user allowed it, rather than leave the user with
                // no way in.
                configured = defaultShortcutPermission() == .allowed ? .default : nil
                message = "\(error.localizedDescription). The quick entry shortcut is \(configured?.symbolLabel ?? "off") until the file is fixed."
                return applyShortcut(configured, message: message)
            }
            // A typo must not change the shortcut: keep the one in use,
            // including no shortcut at all.
            return "\(error.localizedDescription). The quick entry shortcut stays \(shortcut?.symbolLabel ?? "off") until the file is fixed."
        }
        return applyShortcut(configured, message: message)
    }

    private func applyShortcut(_ configured: QuickEntryShortcut?, message: String?) -> String? {
        var message = message
        shortcut = configured
        guard registersGlobalHotKey else {
            isShortcutGlobal = false
            return message
        }

        let registration = presentation.registerHotKey(configured) { [weak self] in
            self?.handleHotKey()
        }
        if case .registered = registration {
            isShortcutGlobal = true
        } else {
            isShortcutGlobal = false
        }
        switch registration {
        case .registered(let shortcut):
            ToasttyLog.info("Registered the quick entry shortcut", category: .tasks, metadata: [
                "shortcut": shortcut.symbolLabel,
            ])
        case .off:
            ToasttyLog.info("The quick entry shortcut is off", category: .tasks)
        case .failed(let shortcut, let status):
            ToasttyLog.warning("Could not register the quick entry shortcut", category: .tasks, metadata: [
                "shortcut": shortcut.symbolLabel,
                "status": String(status),
            ])
            // Another app that holds the keys does not make this fail:
            // Carbon refuses a hot key only when both apps register it
            // exclusively, and the Linux portal names no cause either. So
            // the message names no cause.
            message = message ?? "Toastty could not register the quick entry shortcut \(shortcut.symbolLabel). Set another one with [quick_entry] shortcut in ~/.toastty/tasks.toml."
        }
        return message
    }

    func handleHotKey() {
        present(prefill: .empty)
    }

    // MARK: - Present

    /// Opens the panel, or brings an open one forward and adds the prefill.
    func present(prefill: QuickEntryPrefill) {
        if let model {
            model.apply(prefill)
            // An opener that names a workspace, such as "New Task from
            // Selection…", names the project the message is about.
            if let workspaceID = prefill.workspaceID {
                model.setSelectedProject(project(workspaceID))
            }
            presentation.bringPanelForward()
            model.requestFocus()
            return
        }

        presentation.rememberFocusBeforePresenting()

        let stagingDirectoryURL = stagingRootURL.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        // A broken tasks.toml shows its error at once, since the Agent pill
        // may then have no preset and Create Task stays off.
        let config = Result { try configLoader() }
        let defaults = (try? config.get())?.defaults
        let profiles = quickEntryAgentProfiles(defaults: defaults)
        workspaceFolderResolutions = [:]
        let options = workspaceOptions()
        let frequent = frequentPresets(defaults: defaults, profiles: profiles)
        // Read before the workspace is filled in: an opener that names a
        // workspace, such as "New Task from Selection…", names the hint.
        let coordinator = coordinator(hintWorkspaceID: prefill.workspaceID ?? selectedProjectID())
        var prefill = prefill
        prefill.workspaceID = prefill.workspaceID ?? Self.initialWorkspaceID(
            selectedProject: selectedProjectID(),
            lastUsed: presetUsage?.lastWorkspaceID,
            options: options
        )
        let model = QuickEntryModel(
            prefill: prefill,
            // Restore the last successful choice independently of Frequent
            // ranking. Before the first task, use the configured defaults.
            preset: presetUsage?.lastUsed(agents: Set(profiles.map(\.id))) ?? frequent.first,
            workspaceOptions: options,
            agentProfiles: profiles,
            frequentPresets: frequent,
            stagingDirectoryURL: stagingDirectoryURL,
            coordinator: coordinator,
            create: create,
            onCreated: { [weak self] record in
                self?.finish(created: record)
            },
            onSent: { [weak self] result in
                self?.finish(sent: result)
            },
            onCancel: { [weak self] in
                self?.dismiss()
            }
        )
        if case .failure(let error) = config {
            model.showError(error.localizedDescription)
        }
        self.model = model

        presentation.showPanel(for: model, controller: self)
        model.requestFocus()
        refreshCodexModels()
        ToasttyLog.info("Opened the quick entry panel", category: .tasks, metadata: [
            "sends_to": coordinator == nil ? "task" : "coordinator",
        ].merging(presentation.logMetadata) { first, _ in first })
    }

    /// Closes the panel without creating a task.
    func dismiss() {
        close()
        presentation.restoreFocus()
    }

    private func finish(created record: TaskRecord) {
        recordCreatedTask(preset: model?.preset, workspaceID: model?.workspaceID)
        close()
        presentation.restoreFocus()
        showToast("Task created")
        ToasttyLog.info("Created a task from quick entry", category: .tasks, metadata: [
            "task_id": record.id.uuidString,
        ])
    }

    /// The coordinator has the message, or keeps it until its prompt opens.
    /// The staged files are copied, so the draft can end.
    private func finish(sent result: CoordinatorController.SendResult) {
        close()
        presentation.restoreFocus()
        showToast(Self.toastMessage(for: result))
        ToasttyLog.info("Sent a quick entry message to the coordinator", category: .tasks, metadata: [
            "typed": result.wasTyped ? "true" : "false",
        ])
    }

    /// What the toast says after a send: that the coordinator has the
    /// message, or why the message waits.
    static func toastMessage(for result: CoordinatorController.SendResult) -> String {
        switch result {
        // Quick entry never steers: its message waits for an open prompt.
        case .sent, .sentUnconfirmed, .steered, .steeredUnconfirmed:
            "Sent to the coordinator"
        case .queued(_, let hold), .held(let hold):
            switch hold {
            case .noSession: "Waits: the coordinator is not running"
            case .agentStarting: "Waits: the coordinator is starting"
            case .userDraft: "Waits: text is in the coordinator's terminal"
            case .terminalDialog: "Waits for your answer in the coordinator's terminal"
            case .busy, .awaitingTurn, .settling: "Waits: the coordinator is working"
            case .terminalUnavailable, .promptNotOpen: "Waits for the coordinator's prompt"
            case .notSaved: "Waits: Toastty could not save it"
            }
        }
    }

    /// The coordinator as a new panel uses it, or `nil` when there is none:
    /// the panel then creates the task itself.
    private func coordinator(hintWorkspaceID: UUID?) -> QuickEntryCoordinator? {
        guard let controller = coordinatorController, let status = controller.status else { return nil }
        let hint: String?
        switch status.agentState {
        case .notRunning:
            hint = "Coordinator is not running · your message waits"
        case .starting:
            hint = "Coordinator is starting · your message waits"
        case .running:
            hint = status.queuedCount == 0 ? nil
                : (status.queuedCount == 1 ? "1 message waits for the coordinator"
                    : "\(status.queuedCount) messages wait for the coordinator")
        }
        return QuickEntryCoordinator(
            hint: hint,
            selectedProject: hintWorkspaceID.flatMap(project),
            send: { [weak controller] message in
                guard let controller else { throw CoordinatorError("Toastty is quitting.") }
                return try await controller.sendUserMessage(message)
            }
        )
    }

    /// Ends the draft; the model removes its staged files once no copy is
    /// still writing them. After a create, `task.create` has made its own
    /// copies. The platform remembers where the panel was, for the next
    /// panel and for the toast that may follow.
    private func close() {
        guard let model else { return }
        closePicker(refocusText: false)
        // Clear the draft before the platform closes its window, which can
        // call back.
        self.model = nil
        presentation.closePanel()
        model.close()
    }

    /// **Attach**: the platform's file chooser, then back to the text.
    func chooseFiles() {
        guard let model else { return }
        closePicker(refocusText: false)
        presentation.chooseFiles { [weak self, weak model] urls in
            guard let self, let model else { return }
            if urls.isEmpty == false {
                model.attachFiles(urls)
            }
            if self.model === model {
                self.presentation.focusPanel()
                model.requestFocus()
            }
        }
    }

    /// A workspace as a message names it. The coordinator's own workspace
    /// is not a project.
    private func project(_ workspaceID: UUID) -> CoordinatorMessageHeader.Workspace? {
        let state = store.state
        guard state.isCoordinatorWorkspace(workspaceID) == false,
              let workspace = state.workspacesByID[workspaceID] else { return nil }
        return CoordinatorMessageHeader.Workspace(id: workspaceID, title: workspace.title)
    }

    private func showToast(_ message: String) {
        lastToastMessage = message
        presentation.showToast(message, duration: toastDuration)
    }

    // MARK: - Pickers

    /// ⌘1, ⌘2 or a click on a pill: opens its picker, or closes it when
    /// it is the one open.
    func togglePicker(_ kind: QuickEntryPickerKind) {
        if let picker, picker.kind == kind {
            closePicker(refocusText: true)
            return
        }
        // The click on the pill that just closed this picker.
        if presentation.consumePillClickThatClosedPicker(kind) {
            return
        }
        openPicker(kind)
    }

    func openPicker(_ kind: QuickEntryPickerKind) {
        guard let model, model.isEditable else { return }
        closePicker(refocusText: false)

        if kind == .workspace {
            // The draft can stay open while workspaces change in another window.
            model.workspaceOptions = workspaceOptions()
            if let selected = model.workspaceID,
               model.workspaceOptions.contains(where: { $0.id == selected.uuidString }) == false {
                model.workspaceClosed()
            }
        }

        // With a coordinator, a pill the user has not set shows no choice,
        // and the picker offers to leave it so.
        let sendsToCoordinator = model.sendsToCoordinator
        let picker = switch kind {
        case .workspace:
            QuickEntryPicker(
                workspaces: model.workspaceOptions,
                current: sendsToCoordinator && model.choseWorkspace == false ? nil : model.workspaceID,
                offersCoordinatorChoice: sendsToCoordinator
            )
        case .agent:
            QuickEntryPicker(
                profiles: model.agentProfiles,
                frequent: model.frequentPresets,
                current: sendsToCoordinator && model.chosePreset == false ? nil : model.preset,
                offersCoordinatorChoice: sendsToCoordinator
            )
        }
        picker.codexCatalogStatus = kind == .agent ? codexCatalogStatus : nil
        picker.onRetryCodexModels = { [weak self] in self?.refreshCodexModels() }
        picker.onChoose = { [weak self, weak model] choice in
            switch choice {
            case .workspace(let workspaceID):
                model?.chooseWorkspace(workspaceID)
            case .agent(let preset):
                model?.choosePreset(preset)
            case .coordinatorDecides:
                switch kind {
                case .workspace: model?.chooseWorkspace(nil)
                case .agent: model?.choosePreset(nil)
                }
            }
            self?.closePicker(refocusText: true)
        }
        picker.onClose = { [weak self] in
            self?.closePicker(refocusText: true)
        }

        self.picker = picker
        model.openPicker = kind
        presentation.showPicker(picker, for: model, controller: self)
        ToasttyLog.debug("Opened a quick entry picker", category: .tasks, metadata: [
            "picker": kind == .workspace ? "workspace" : "agent",
        ])
    }

    /// Closes the open picker. With `refocusText`, the caret goes back to
    /// the task text; otherwise focus stays where the user put it.
    func closePicker(refocusText: Bool) {
        guard picker != nil else { return }
        picker = nil
        model?.openPicker = nil
        presentation.hidePicker()
        if refocusText, let model {
            presentation.focusPanel()
            model.requestFocus()
        }
    }

    /// ⌘↩ and ⌥⌘↩ in the picker's list: choose the row, then act as in the
    /// panel. Only once the choice is made; a row that opens the columns
    /// leaves the picker open.
    func submitFromPicker(createsTask: Bool) {
        guard let picker else { return }
        picker.submit()
        guard self.picker == nil else { return }
        if createsTask {
            model?.createTask()
        } else {
            model?.submit()
        }
    }

    // MARK: - Choices for other entry points

    /// What the panel would offer if it opened now, for a task created
    /// elsewhere with the same choices: Toastty Mobile's New Task sheet.
    /// `includeProfile` narrows the agents, and with them the presets.
    func currentChoices(
        includeProfile: (AgentLaunchProfileSummary) -> Bool = { _ in true }
    ) -> QuickEntryChoices {
        let defaults = (try? configLoader())?.defaults
        let profiles = quickEntryAgentProfiles(defaults: defaults, includeProfile: includeProfile)
        let frequent = frequentPresets(defaults: defaults, profiles: profiles)
        let workspaces = Self.taskWorkspaces(in: store.state)
        return QuickEntryChoices(
            workspaces: workspaces,
            initialWorkspaceID: Self.initialWorkspaceID(
                selectedProject: selectedProjectID(),
                lastUsed: presetUsage?.lastWorkspaceID,
                options: workspaces.map { QuickEntryModel.Option(id: $0.id.uuidString, title: $0.title) }
            ),
            profiles: profiles,
            frequentPresets: frequent,
            initialPreset: presetUsage?.lastUsed(agents: Set(profiles.map(\.id))) ?? frequent.first
        )
    }

    /// Counts a created task's preset for Frequent and remembers its
    /// workspace, as Create Task in the panel does.
    func recordCreatedTask(preset: QuickEntryPreset?, workspaceID: UUID?) {
        if let preset {
            presetUsage?.record(preset)
        }
        if let workspaceID {
            presetUsage?.recordWorkspace(workspaceID)
        }
    }

    /// The installed profiles that can take a task as their first message,
    /// each with its models and efforts.
    private func quickEntryAgentProfiles(
        defaults: TasksConfig.Defaults?,
        includeProfile: (AgentLaunchProfileSummary) -> Bool = { _ in true }
    ) -> [QuickEntryAgentProfile] {
        agentProfiles()
            .filter { $0.isInstalled && $0.acceptsInitialPrompt && includeProfile($0) }
            .map { summary in
                var models: [String] = []
                if summary.supportsModel {
                    let saved = presetUsage?.recent(agents: [summary.profileID]).compactMap(\.model) ?? []
                    var seen: Set<String> = []
                    models = Array((saved + recentModels(summary.agent))
                        .filter { seen.insert($0).inserted }
                        .prefix(RemoteSessionStartPolicy.maximumRecentModelCount))
                    // `[defaults]` names a model even when no live session
                    // has reported one, as when remote access is off.
                    if defaults?.agent == summary.profileID, let model = defaults?.model, models.contains(model) == false {
                        models.append(model)
                    }
                    if summary.profileID == AgentKind.codex.rawValue {
                        var seen = Set(models)
                        models += cachedCodexModels.filter { seen.insert($0).inserted }
                    }
                }
                return QuickEntryAgentProfile(
                    id: summary.profileID,
                    displayName: summary.displayName,
                    supportsModel: summary.supportsModel,
                    efforts: RemoteSessionStarter.reasoningEfforts(for: summary),
                    models: models
                )
            }
    }

    /// The presets used most, recent use counting more; `[defaults]` before
    /// the first successful task.
    private func frequentPresets(defaults: TasksConfig.Defaults?, profiles: [QuickEntryAgentProfile]) -> [QuickEntryPreset] {
        let used = presetUsage?.frequent(agents: Set(profiles.map(\.id))) ?? []
        guard used.isEmpty else { return used }
        return Self.defaultPreset(defaults, profiles: profiles).map { [$0] } ?? []
    }

    /// `[defaults]` as a preset, when its agent is offered. A model or
    /// effort the agent cannot take is left out, as the coordinator does.
    /// With no agent there, the first agent offered, as a task created with
    /// no agent gets. `nil` defaults, from a tasks.toml that cannot be read,
    /// give no preset.
    static func defaultPreset(_ defaults: TasksConfig.Defaults?, profiles: [QuickEntryAgentProfile]) -> QuickEntryPreset? {
        guard let defaults else { return nil }
        guard let agent = defaults.agent else {
            return profiles.first.map { QuickEntryPreset(agent: $0.id) }
        }
        guard let profile = profiles.first(where: { $0.id == agent }) else { return nil }
        return QuickEntryPreset(
            agent: agent,
            model: profile.supportsModel ? defaults.model : nil,
            effort: profile.efforts.isEmpty ? nil : defaults.effort
        )
    }

    // MARK: - Options

    /// A reloaded profile or PATH must not reuse choices or results from
    /// the previous CLI. Choices already in an open draft stay usable.
    func invalidateCodexModels() {
        codexCatalogGeneration += 1
        modelLoadTask?.cancel()
        modelLoadTask = nil
        cachedCodexModels = []
        codexCatalogStatus = nil
        refreshCodexModels()
    }

    private func refreshCodexModels() {
        guard modelLoadTask == nil, let loadCodexModels,
              model?.agentProfiles.contains(where: { $0.id == AgentKind.codex.rawValue && $0.supportsModel }) == true else { return }
        let generation = codexCatalogGeneration
        let requestID = UUID().uuidString
        let startedAt = Date()
        codexCatalogStatus = cachedCodexModels.isEmpty ? .loading : nil
        ToasttyLog.info("Loading the Codex model catalog", category: .tasks, metadata: ["request_id": requestID])
        // Coalesce close/reopen and Retry. Cache a late success even with
        // no draft; update only the current draft, never a dismissed one.
        modelLoadTask = Task { [weak self] in
            let result: Result<[String], any Error>
            do {
                result = .success(try await loadCodexModels())
            } catch {
                result = .failure(error)
            }
            var metadata = [
                "request_id": requestID,
                "duration_ms": String(Int(Date().timeIntervalSince(startedAt) * 1_000)),
            ]
            guard let self, self.codexCatalogGeneration == generation else {
                metadata["outcome"] = "stale"
                ToasttyLog.info("Finished the Codex model catalog lookup", category: .tasks, metadata: metadata)
                return
            }
            self.modelLoadTask = nil
            let models: [String]
            switch result {
            case .success(let loaded):
                models = loaded
                // An empty response supplies no replacement suggestions.
                // Keep the last usable catalog, as on a failed refresh.
                if models.isEmpty == false { self.cachedCodexModels = models }
                self.codexCatalogStatus = self.cachedCodexModels.isEmpty ? .unavailable : nil
                metadata["outcome"] = models.isEmpty ? "empty" : "success"
                metadata["model_count"] = String(models.count)
            case .failure(let error):
                self.codexCatalogStatus = self.cachedCodexModels.isEmpty ? .unavailable : nil
                // CLI stderr can contain private configuration. Record
                // categories and exit status, never the command's output.
                switch error {
                case CodexPluginCLIError.timedOut:
                    metadata["outcome"] = "timeout"
                case CodexPluginCLIError.commandFailed(_, let status, _):
                    metadata["outcome"] = "command_failed"
                    metadata["exit_status"] = String(status)
                case is DecodingError, CodexPluginCLIError.malformedJSON:
                    metadata["outcome"] = "invalid_json"
                default:
                    metadata["outcome"] = "unavailable"
                }
                ToasttyLog.info("Finished the Codex model catalog lookup", category: .tasks, metadata: metadata)
                return
            }
            ToasttyLog.info("Finished the Codex model catalog lookup", category: .tasks, metadata: metadata)
            guard let model = self.model else { return }
            let profiles = model.agentProfiles.map { profile in
                guard profile.id == AgentKind.codex.rawValue, profile.supportsModel else { return profile }
                var profile = profile
                var seen = Set(profile.models)
                profile.models += models.filter { seen.insert($0).inserted }
                return profile
            }
            guard profiles != model.agentProfiles else { return }
            model.agentProfiles = profiles
            self.picker?.updateProfiles(model.agentProfiles)
        }
    }

    /// Each workspace with its folder, and the git mark once the folder
    /// check below has run. Starts the check for folders not checked yet.
    private func workspaceOptions() -> [QuickEntryModel.Option] {
        let workspaces = Self.taskWorkspaces(in: store.state)
        let sources = QuickEntryWorkspaceFolders.sources(for: workspaces.map(\.id), in: store.state)
        workspaceFolderSources = Dictionary(sources.map { ($0.workspaceID.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        checkWorkspaceFolders(sources)
        return workspaces.map { workspace in
            let source = workspaceFolderSources[workspace.id.uuidString]
            return QuickEntryWorkspaceFolders.option(
                id: workspace.id,
                title: workspace.title,
                source: source,
                resolution: source.flatMap { workspaceFolderResolutions[$0] }
            )
        }
    }

    /// Checks off the main thread whether each folder is in a git
    /// repository, then marks the open list.
    private func checkWorkspaceFolders(_ sources: [QuickEntryWorkspaceFolders.Source]) {
        let unchecked = sources.filter { $0.folder != nil && workspaceFolderResolutions[$0] == nil }
        guard unchecked.isEmpty == false else { return }
        workspaceFolderCheck?.cancel()
        workspaceFolderCheck = Task { [weak self] in
            let resolved = await Task.detached(priority: .userInitiated) {
                unchecked.compactMap { source in QuickEntryWorkspaceFolders.resolve(source).map { (source, $0) } }
            }.value
            guard let self, Task.isCancelled == false else { return }
            for (source, resolution) in resolved {
                workspaceFolderResolutions[source] = resolution
            }
            markWorkspaceFolders()
        }
    }

    private func markWorkspaceFolders() {
        guard let model else { return }
        model.workspaceOptions = model.workspaceOptions.map { option in
            guard let source = workspaceFolderSources[option.id] else { return option }
            return QuickEntryWorkspaceFolders.option(
                id: source.workspaceID,
                title: option.title,
                source: source,
                resolution: workspaceFolderResolutions[source]
            )
        }
        if let picker, picker.kind == .workspace {
            picker.updateWorkspaces(model.workspaceOptions)
        }
    }

    /// Waits for the folder check that runs now. Test seam.
    func waitForWorkspaceFolderCheck() async {
        await workspaceFolderCheck?.value
    }

    /// Top-level workspaces in sidebar order, window by window. A task
    /// belongs to a top-level workspace, so subspaces are not offered.
    static func taskWorkspaces(in state: AppState) -> [QuickEntryChoices.Workspace] {
        var seen: Set<UUID> = []
        var workspaces: [QuickEntryChoices.Workspace] = []
        for window in state.windows {
            for workspaceID in state.topLevelWorkspaceIDs(in: window.id) where seen.insert(workspaceID).inserted {
                guard let workspace = state.workspacesByID[workspaceID] else { continue }
                workspaces.append(QuickEntryChoices.Workspace(id: workspaceID, title: workspace.title))
            }
        }
        return workspaces
    }

    /// The project of the workspace selected in Toastty's main window; a
    /// task space counts as its project.
    private func selectedProjectID() -> UUID? {
        let state = store.state
        guard let selected = state.selectedWorkspaceSelection()?.workspaceID else { return nil }
        return state.subspaceParentIDsByWorkspaceID()[selected] ?? selected
    }

    /// The workspace the panel starts on: the workspace last used in quick
    /// entry, wherever the panel opens, so a choice sticks until the user
    /// changes it. The selected project when that one closed or before the
    /// first task. nil when neither is open.
    static func initialWorkspaceID(
        selectedProject: UUID?,
        lastUsed: UUID?,
        options: [QuickEntryModel.Option]
    ) -> UUID? {
        [lastUsed, selectedProject].compactMap { $0 }.first { id in options.contains { $0.id == id.uuidString } }
    }

    /// The top-level workspace that holds a panel, for "New Task from
    /// Selection…".
    func topLevelWorkspaceID(containingPanelID panelID: UUID) -> UUID? {
        let state = store.state
        guard let workspaceID = state.workspaceSelection(containingPanelID: panelID)?.workspaceID else {
            return nil
        }
        let rootID = state.subspaceParentIDsByWorkspaceID()[workspaceID] ?? workspaceID
        // The coordinator's workspace is not a project.
        return state.isCoordinatorWorkspace(rootID) ? nil : rootID
    }

    /// Opens the panel with text selected in a terminal attached and that
    /// terminal's workspace chosen.
    func presentFromSelection(_ selectionText: String, panelID: UUID) {
        present(prefill: QuickEntryPrefill(
            workspaceID: topLevelWorkspaceID(containingPanelID: panelID),
            selectionText: selectionText
        ))
    }
}

/// What the platform's hot key registration did.
enum QuickEntryShortcutRegistration: Equatable {
    case registered(QuickEntryShortcut)
    /// `tasks.toml` turns the shortcut off.
    case off
    /// The system refused it, usually because another app holds it.
    case failed(QuickEntryShortcut, Int32)
}

/// The workspaces and agent choices quick entry offers at one moment.
struct QuickEntryChoices: Equatable {
    struct Workspace: Equatable {
        var id: UUID
        var title: String
    }

    var workspaces: [Workspace]
    /// The workspace the panel would start on, when one is open.
    var initialWorkspaceID: UUID?
    var profiles: [QuickEntryAgentProfile]
    var frequentPresets: [QuickEntryPreset]
    /// The preset the panel would start on.
    var initialPreset: QuickEntryPreset?
}
