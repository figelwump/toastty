import AppKit
import CoreState
import Foundation
import RemoteProtocol
import SwiftUI

/// Opens the quick entry panel from the global shortcut and from Toastty's
/// own entry points, and creates the task through `task.create`.
@MainActor
final class QuickEntryController: ObservableObject {
    /// The configured shortcut, shown on File ▸ New Task…; nil when
    /// `tasks.toml` turns it off.
    @Published private(set) var shortcut: QuickEntryShortcut? = .default

    private let store: AppStore
    /// The profiles in agents.toml, as a launch resolves them.
    private let agentProfiles: @MainActor () -> [AgentLaunchProfileSummary]
    /// The presets the user picks, for the Agent picker's Frequent list.
    private let presetUsage: QuickEntryPresetUsage?
    private let create: @MainActor (TaskCreateRequest) async throws -> TaskRecord
    private let configLoader: @MainActor () throws -> TasksConfig
    private let stagingRootURL: URL
    private let registersGlobalHotKey: Bool
    private let toastDuration: Duration
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
    private var toastPanel: QuickEntryToastPanel?
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
        toastDuration: Duration = .milliseconds(1600)
    ) {
        self.store = store
        self.agentProfiles = agentProfiles
        self.presetUsage = presetUsage
        self.create = create
        self.configLoader = configLoader
        self.stagingRootURL = stagingRootURL
        self.registersGlobalHotKey = registersGlobalHotKey
        self.toastDuration = toastDuration
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
            panel.orderFrontRegardless()
            panel.makeKey()
            model.requestFocus()
            return
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApplication = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        // The main window rather than the key window: opened from the
        // command palette, the key window is the palette, which is closing.
        previousKeyWindow = NSApp.isActive ? (NSApp.mainWindow ?? NSApp.keyWindow) : nil
        previousFirstResponder = previousKeyWindow?.firstResponder

        let stagingDirectoryURL = stagingRootURL.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        // A broken tasks.toml shows its error at Create Task; the pickers
        // then offer no `[defaults]` preset.
        let defaults = (try? configLoader())?.defaults
        let profiles = quickEntryAgentProfiles(defaults: defaults)
        let model = QuickEntryModel(
            prefill: prefill,
            workspaceOptions: workspaceOptions(),
            agentProfiles: profiles,
            frequentPresets: frequentPresets(defaults: defaults, profiles: profiles),
            stagingDirectoryURL: stagingDirectoryURL,
            create: create,
            onCreated: { [weak self] record in
                self?.finish(created: record)
            },
            onCancel: { [weak self] in
                self?.dismiss()
            }
        )
        self.model = model

        let dropTarget = QuickEntryDropTarget(model: model)
        let panel = QuickEntryPanel()
        panel.onSubmit = { [weak model] in model?.submit() }
        panel.onCancel = { [weak model] in model?.cancel() }
        panel.onPicker = { [weak self] kind in self?.togglePicker(kind) }
        panel.contentView = QuickEntryContentView(
            rootView: QuickEntryView(
                model: model,
                dropTarget: dropTarget,
                attachFiles: { [weak self] in self?.chooseFiles() },
                togglePicker: { [weak self] kind in self?.togglePicker(kind) },
                onHeightChange: { [weak panel] height in
                    // Called during SwiftUI layout; resizing the window there
                    // would start a layout pass inside the current one.
                    DispatchQueue.main.async { panel?.fitContentHeight(height) }
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
        ToasttyLog.info("Opened the quick entry panel", category: .tasks, metadata: [
            "from_app": previousApplication?.bundleIdentifier ?? "toastty",
        ])
    }

    /// Closes the panel without creating a task.
    func dismiss() {
        close()
        restoreFocus()
    }

    private func finish(created record: TaskRecord) {
        // Only a preset the user chose counts; Auto leaves it to triage.
        if let preset = model?.preset {
            presetUsage?.record(preset)
        }
        let frame = panel?.frame
        close()
        restoreFocus()
        showToast(near: frame)
        ToasttyLog.info("Created a task from quick entry", category: .tasks, metadata: [
            "task_id": record.id.uuidString,
        ])
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
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        model?.close()
        model = nil
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
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.prompt = "Attach"
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

    private func showToast(near frame: NSRect?) {
        toastTask?.cancel()
        toastPanel?.orderOut(nil)
        let toast = QuickEntryToastPanel(message: "Task created · in the Inbox")
        let anchor = frame ?? QuickEntryPanel.defaultFrame(screen: QuickEntryPanel.focusedScreen())
        toast.setFrameOrigin(NSPoint(
            x: (anchor.midX - QuickEntryToastPanel.size.width / 2).rounded(),
            y: (anchor.midY - QuickEntryToastPanel.size.height / 2).rounded()
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

        let picker = switch kind {
        case .workspace:
            QuickEntryPicker(workspaces: model.workspaceOptions, current: model.workspaceID)
        case .agent:
            QuickEntryPicker(profiles: model.agentProfiles, frequent: model.frequentPresets, current: model.preset)
        }
        picker.onChoose = { [weak self, weak model] choice in
            switch choice {
            case .workspace(let workspaceID):
                model?.workspaceID = workspaceID
            case .agent(let preset):
                model?.preset = preset
            }
            self?.closePicker(refocusText: true)
        }
        picker.onClose = { [weak self] in
            self?.closePicker(refocusText: true)
        }

        let pickerPanel = QuickEntryPickerPanel()
        pickerPanel.onPickerShortcut = { [weak self] kind in self?.togglePicker(kind) }
        pickerPanel.onClose = { [weak picker] in picker?.cancel() }
        pickerPanel.onSubmitTask = { [weak self, weak picker] in
            guard let self, let picker else { return }
            picker.submit()
            // Create only once the choice is made; a row that opens the
            // columns leaves the picker open.
            if self.picker == nil {
                self.model?.submit()
            }
        }
        pickerPanel.onCommandRight = { [weak picker] in
            guard let picker, picker.kind == .agent, picker.columns == nil else { return false }
            picker.openColumns()
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

    /// The installed profiles that can take a task as their first message,
    /// as triage offers them, each with its models and efforts.
    private func quickEntryAgentProfiles(defaults: TasksConfig.Defaults?) -> [QuickEntryAgentProfile] {
        agentProfiles()
            .filter { $0.isInstalled && $0.acceptsInitialPrompt }
            .map { summary in
                var models: [String] = []
                if summary.supportsModel {
                    models = Array(recentModels(summary.agent).prefix(RemoteSessionStartPolicy.maximumRecentModelCount))
                    // `[defaults]` names a model even when no live session
                    // has reported one, as when remote access is off.
                    if defaults?.agent == summary.profileID, let model = defaults?.model, models.contains(model) == false {
                        models.append(model)
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

    /// The presets used most, recent use counting more; `[defaults]` until
    /// one has been used twice.
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

    /// Top-level workspaces in sidebar order, window by window. A task
    /// belongs to a top-level workspace, so subspaces are not offered.
    private func workspaceOptions() -> [QuickEntryModel.Option] {
        let state = store.state
        var seen: Set<UUID> = []
        var options: [QuickEntryModel.Option] = []
        for window in state.windows {
            for workspaceID in state.topLevelWorkspaceIDs(in: window.id) where seen.insert(workspaceID).inserted {
                guard let workspace = state.workspacesByID[workspaceID] else { continue }
                options.append(QuickEntryModel.Option(id: workspaceID.uuidString, title: workspace.title))
            }
        }
        return options
    }

    /// The top-level workspace that holds a panel, for "New Task from
    /// Selection…".
    func topLevelWorkspaceID(containingPanelID panelID: UUID) -> UUID? {
        let state = store.state
        guard let workspaceID = state.workspaceSelection(containingPanelID: panelID)?.workspaceID else {
            return nil
        }
        return state.subspaceParentIDsByWorkspaceID()[workspaceID] ?? workspaceID
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
