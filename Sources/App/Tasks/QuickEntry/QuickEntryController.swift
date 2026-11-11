import AppKit
import CoreState
import Foundation
import RemoteProtocol
import SwiftUI

/// Opens the quick entry panel from the global shortcut and from Toastty's
/// own entry points. While a coordinator exists, the panel sends its text
/// to the coordinator, and a second key creates the task directly. With no
/// coordinator, it creates the task through `task.create`.
@MainActor
final class QuickEntryController: ObservableObject {
    /// The configured shortcut, shown on File ▸ New Task…; nil when
    /// `tasks.toml` turns it off.
    @Published private(set) var shortcut: QuickEntryShortcut? = .default

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
    private let toastDuration: Duration
    private let frontmostApplication: @MainActor () -> NSRunningApplication?
    private var hotKey: QuickEntryHotKey?

    private(set) var panel: QuickEntryPanel?
    private(set) var model: QuickEntryModel?
    private(set) var picker: QuickEntryPicker?
    private(set) var pickerPanel: QuickEntryPickerPanel?
    /// The pill whose mouse-down just closed its picker, and that click's
    /// event number, so its mouse-up does not open the picker again.
    private var pickerClosedByPillClick: (kind: QuickEntryPickerKind, eventNumber: Int)?
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
    // Removed in deinit, which is not main-actor isolated.
    nonisolated(unsafe) private var terminationObserver: (any NSObjectProtocol)?
    /// The app in front when the panel opened, if not Toastty.
    private var previousApplication: NSRunningApplication?
    private weak var previousKeyWindow: NSWindow?
    private weak var previousFirstResponder: NSResponder?
    /// Where the last panel was, so the next one opens there when it opens
    /// on the same screen. The top stays put because the height follows the
    /// text.
    private var lastPanelPlacement: QuickEntryPlacement.Remembered?
    private(set) var toastPanel: QuickEntryToastPanel?
    /// What the last toast said.
    private(set) var lastToastMessage: String?
    private var toastTask: Task<Void, Never>?

    var isPresented: Bool { panel != nil }

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
        frontmostApplication: @escaping @MainActor () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    ) {
        self.store = store
        self.agentProfiles = agentProfiles
        self.presetUsage = presetUsage
        self.create = create
        self.configLoader = configLoader
        self.stagingRootURL = stagingRootURL
        self.registersGlobalHotKey = registersGlobalHotKey
        self.toastDuration = toastDuration
        self.frontmostApplication = frontmostApplication
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleTermination()
            }
        }
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

    /// Reads `[quick_entry] shortcut` and registers it. Returns a message
    /// when the shortcut could not be set up.
    @discardableResult
    func reloadShortcut() -> String? {
        let configured: QuickEntryShortcut?
        var message: String?
        do {
            configured = try configLoader().quickEntry.shortcut
            hasLoadedShortcut = true
        } catch {
            guard hasLoadedShortcut else {
                // At launch there is no earlier setting: use the default
                // rather than leave the user with no way in.
                configured = .default
                message = "tasks.toml: \(error.localizedDescription). The quick entry shortcut is \(QuickEntryShortcut.default.symbolLabel) until the file is fixed."
                return applyShortcut(configured, message: message)
            }
            // A typo must not change the shortcut: keep the one in use,
            // including no shortcut at all.
            return "tasks.toml: \(error.localizedDescription). The quick entry shortcut stays \(shortcut?.symbolLabel ?? "off") until the file is fixed."
        }
        return applyShortcut(configured, message: message)
    }

    private func applyShortcut(_ configured: QuickEntryShortcut?, message: String?) -> String? {
        var message = message
        shortcut = configured
        guard registersGlobalHotKey else { return message }

        let hotKey = self.hotKey ?? QuickEntryHotKey { [weak self] in
            self?.handleHotKey()
        }
        self.hotKey = hotKey
        let registration = hotKey.register(configured)
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
            message = message ?? "The quick entry shortcut \(shortcut.symbolLabel) is in use by another app. Set another one with [quick_entry] shortcut in ~/.toastty/tasks.toml."
        }
        return message
    }

    func handleHotKey() {
        present(prefill: .empty)
    }

    // MARK: - Present

    /// Opens the panel, or brings an open one forward and adds the prefill.
    func present(prefill: QuickEntryPrefill) {
        if let panel, let model {
            model.apply(prefill)
            // An opener that names a workspace, such as "New Task from
            // Selection…", names the project the message is about.
            if let workspaceID = prefill.workspaceID {
                model.setSelectedProject(project(workspaceID))
            }
            panel.orderFrontRegardless()
            panel.makeKey()
            model.requestFocus()
            return
        }

        let frontmost = frontmostApplication()
        previousApplication = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        // The main window rather than the key window: opened from the
        // command palette, the key window is the palette, which is closing.
        previousKeyWindow = NSApp.isActive ? (NSApp.mainWindow ?? NSApp.keyWindow) : nil
        previousFirstResponder = previousKeyWindow?.firstResponder

        let stagingDirectoryURL = stagingRootURL.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        // A broken tasks.toml shows its error at once, since the Agent pill
        // may then have no preset and Create Task stays off.
        let config = Result { try configLoader() }
        let defaults = (try? config.get())?.defaults
        let profiles = quickEntryAgentProfiles(defaults: defaults)
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
            model.showError("tasks.toml: \(error.localizedDescription)")
        }
        self.model = model

        let dropTarget = AttachmentDropTarget(attachments: model.attachmentDraft)
        let panel = QuickEntryPanel()
        panel.onSubmit = { [weak model] in model?.submit() }
        panel.onCreateTask = { [weak model] in model?.createTask() }
        panel.onCancel = { [weak model] in model?.cancel() }
        panel.onPicker = { [weak self] kind in self?.togglePicker(kind) }
        panel.contentView = QuickEntryContentView(
            rootView: QuickEntryView(
                model: model,
                dropTarget: dropTarget,
                attachFiles: { [weak self] in self?.chooseFiles() },
                togglePicker: { [weak self] kind in self?.togglePicker(kind) },
                onHeightChange: { [weak self, weak panel] height in
                    // Called during SwiftUI layout; resizing the window there
                    // would start a layout pass inside the current one.
                    DispatchQueue.main.async { [weak self, weak panel] in
                        guard let self, let panel, self.panel === panel else { return }
                        panel.fitContentHeight(height)
                    }
                }
            ),
            dropTarget: dropTarget
        )
        var size = QuickEntryPanel.defaultSize
        if let fittingHeight = panel.contentView?.fittingSize.height, fittingHeight > 0 {
            size.height = fittingHeight.rounded(.up)
        }
        // The screen of the window the user is working in, not the one with
        // Toastty's window or the last panel.
        let frame: NSRect
        if let screen = QuickEntryPanel.focusedScreen() ?? NSScreen.main {
            frame = QuickEntryPlacement.frame(
                size: size,
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                remembered: lastPanelPlacement
            )
        } else {
            frame = NSRect(origin: .zero, size: size)
        }
        panel.setFrame(frame, display: false)
        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
        model.requestFocus()
        refreshCodexModels()
        ToasttyLog.info("Opened the quick entry panel", category: .tasks, metadata: [
            "sends_to": coordinator == nil ? "task" : "coordinator",
            "from_app": previousApplication?.bundleIdentifier ?? "toastty",
            "window_number": String(panel.windowNumber),
            "is_key_window": String(panel.isKeyWindow),
        ])
    }

    /// Closes the panel without creating a task.
    func dismiss() {
        close()
        restoreFocus()
    }

    private func finish(created record: TaskRecord) {
        recordCreatedTask(preset: model?.preset, workspaceID: model?.workspaceID)
        let frame = panel?.frame
        close()
        restoreFocus()
        showToast("Task created", near: frame)
        ToasttyLog.info("Created a task from quick entry", category: .tasks, metadata: [
            "task_id": record.id.uuidString,
        ])
    }

    /// The coordinator has the message, or keeps it until its prompt opens.
    /// The staged files are copied, so the draft can end.
    private func finish(sent result: CoordinatorController.SendResult) {
        let frame = panel?.frame
        close()
        restoreFocus()
        showToast(Self.toastMessage(for: result), near: frame)
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
    /// copies.
    private func close() {
        guard let panel else { return }
        closePicker(refocusText: false)
        lastPanelPlacement = panel.screen.map {
            QuickEntryPlacement.Remembered(
                topLeft: NSPoint(x: panel.frame.minX, y: panel.frame.maxY),
                screenFrame: $0.frame
            )
        }
        let model = self.model
        let windowNumber = panel.windowNumber
        // Clear presentation before AppKit sends window-close callbacks.
        self.panel = nil
        self.model = nil
        panel.close()
        panel.contentView = nil
        model?.close()
        ToasttyLog.info("Closed the quick entry panel", category: .tasks, metadata: [
            "window_number": String(windowNumber),
            "is_visible": String(panel.isVisible),
        ])
    }

    /// Gives focus back: to the app that was in front, or to the Toastty
    /// window and field that had it.
    private func restoreFocus() {
        let previousApplication = self.previousApplication
        let previousKeyWindow = self.previousKeyWindow
        let previousFirstResponder = self.previousFirstResponder
        self.previousApplication = nil
        self.previousKeyWindow = nil
        self.previousFirstResponder = nil

        if let previousApplication {
            // Toastty became active only if the user chose files to attach.
            if NSApp.isActive {
                previousApplication.activate(options: [])
            }
            return
        }
        if let previousKeyWindow, previousKeyWindow.isVisible {
            previousKeyWindow.makeKey()
            if let previousFirstResponder {
                previousKeyWindow.makeFirstResponder(previousFirstResponder)
            }
        }
    }

    private func chooseFiles() {
        guard let panel, let model else { return }
        closePicker(refocusText: false)
        let openPanel = DraftAttachments.makeOpenPanel()
        // Above the floating quick entry panel. A modal panel needs Toastty
        // to be the active app; focus goes back when the quick entry closes.
        openPanel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        NSApp.activate()
        let response = openPanel.runModal()
        if response == .OK {
            model.attachFiles(openPanel.urls)
        }
        if self.panel === panel {
            panel.makeKey()
            model.requestFocus()
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

    private func showToast(_ message: String, near frame: NSRect?) {
        toastTask?.cancel()
        toastPanel?.orderOut(nil)
        let toast = QuickEntryToastPanel(message: message)
        lastToastMessage = message
        let anchor = frame ?? QuickEntryPanel.defaultFrame(screen: QuickEntryPanel.focusedScreen())
        toast.setFrameOrigin(NSPoint(
            x: (anchor.midX - toast.frame.width / 2).rounded(),
            y: (anchor.midY - toast.frame.height / 2).rounded()
        ))
        toast.orderFrontRegardless()
        toastPanel = toast
        let duration = toastDuration
        toastTask = Task { @MainActor [weak self, weak toast] in
            try? await Task.sleep(for: duration)
            guard Task.isCancelled == false, let toast else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                toast.animator().alphaValue = 0
            }
            toast.orderOut(nil)
            if self?.toastPanel === toast {
                self?.toastPanel = nil
            }
        }
    }

    // MARK: - Pickers

    /// ⌘1, ⌘2 or a click on a pill: opens its picker, or closes it when
    /// it is the one open.
    func togglePicker(_ kind: QuickEntryPickerKind) {
        if let picker, picker.kind == kind {
            closePicker(refocusText: true)
            return
        }
        if let closed = pickerClosedByPillClick {
            pickerClosedByPillClick = nil
            // The mouse-down on the pill took focus from the picker and
            // closed it; this is the same click's mouse-up, which shares
            // its event number.
            if closed.kind == kind, let event = NSApp.currentEvent, event.type == .leftMouseUp,
               event.eventNumber == closed.eventNumber {
                return
            }
        }
        openPicker(kind)
    }

    func openPicker(_ kind: QuickEntryPickerKind) {
        guard let panel, let model, model.isEditable else { return }
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

        let pickerPanel = QuickEntryPickerPanel()
        pickerPanel.onPickerShortcut = { [weak self] kind in self?.togglePicker(kind) }
        pickerPanel.onClose = { [weak picker] in picker?.cancel() }
        // ⌘↩ and ⌥⌘↩ in the list: choose the row, then act as in the panel.
        // Only once the choice is made; a row that opens the columns
        // leaves the picker open.
        pickerPanel.onSubmitTask = { [weak self, weak picker] in
            guard let self, let picker else { return }
            picker.submit()
            if self.picker == nil {
                self.model?.submit()
            }
        }
        pickerPanel.onCreateTask = { [weak self, weak picker] in
            guard let self, let picker else { return }
            picker.submit()
            if self.picker == nil {
                self.model?.createTask()
            }
        }
        pickerPanel.onCommandRight = { [weak picker] in
            guard let picker, picker.kind == .agent, picker.columns == nil else { return false }
            picker.openColumns()
            return true
        }
        pickerPanel.onRetryCodexModels = { [weak picker] in
            guard let picker, picker.showsCodexCatalogStatus, picker.codexCatalogStatus == .unavailable else { return false }
            picker.onRetryCodexModels()
            return true
        }
        pickerPanel.currentQuery = { [weak picker] in picker?.query ?? "" }
        pickerPanel.onNumberKey = { [weak picker] number in
            guard let picker, picker.query.isEmpty else { return false }
            return picker.chooseFrequent(number: number)
        }
        pickerPanel.onResignKey = { [weak self, weak pickerPanel] in
            guard let self, let pickerPanel, self.pickerPanel === pickerPanel else { return }
            self.pickerResignedKey(kind: kind)
        }
        let hostingView = NSHostingView(rootView: QuickEntryPickerView(picker: picker) { [weak pickerPanel] size in
            // Called during SwiftUI layout; see the quick entry panel.
            DispatchQueue.main.async { pickerPanel?.fit(size) }
        })
        pickerPanel.contentView = hostingView
        let pill = model.pillFrames[kind].map {
            QuickEntryPickerPlacement.screenFrame(of: $0, inPanelFrame: panel.frame)
        } ?? NSRect(x: panel.frame.minX + 14, y: panel.frame.minY + 10, width: 1, height: 26)
        pickerPanel.place(
            size: hostingView.fittingSize,
            pill: pill,
            visibleFrame: (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        )
        self.picker = picker
        self.pickerPanel = pickerPanel
        model.openPicker = kind
        panel.addChildWindow(pickerPanel, ordered: .above)
        pickerPanel.makeKey()
        ToasttyLog.debug("Opened a quick entry picker", category: .tasks, metadata: [
            "picker": kind == .workspace ? "workspace" : "agent",
        ])
    }

    /// Closes the open picker. With `refocusText`, the caret goes back to
    /// the task text; otherwise focus stays where the user put it.
    func closePicker(refocusText: Bool) {
        guard let pickerPanel else { return }
        self.pickerPanel = nil
        picker = nil
        model?.openPicker = nil
        pickerPanel.parent?.removeChildWindow(pickerPanel)
        pickerPanel.orderOut(nil)
        pickerPanel.contentView = nil
        if refocusText, let panel {
            panel.makeKey()
            model?.requestFocus()
        }
    }

    /// A click outside the picker, or another app in front, closes it.
    private func pickerResignedKey(kind: QuickEntryPickerKind) {
        if let event = NSApp.currentEvent, event.type == .leftMouseDown, let panel, event.window === panel,
           let pill = model?.pillFrames[kind] {
            let point = event.locationInWindow
            let flipped = NSPoint(x: point.x, y: panel.frame.height - point.y)
            if pill.contains(flipped) {
                pickerClosedByPillClick = (kind, event.eventNumber)
            }
        }
        closePicker(refocusText: false)
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
    static func defaultPreset(_ defaults: TasksConfig.Defaults?, profiles: [QuickEntryAgentProfile]) -> QuickEntryPreset? {
        guard let defaults, let agent = defaults.agent,
              let profile = profiles.first(where: { $0.id == agent }) else { return nil }
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

    private func workspaceOptions() -> [QuickEntryModel.Option] {
        Self.taskWorkspaces(in: store.state).map { QuickEntryModel.Option(id: $0.id.uuidString, title: $0.title) }
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
