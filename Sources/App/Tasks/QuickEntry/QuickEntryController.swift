import AppKit
import CoreState
import Foundation

/// Opens the quick entry panel from the global shortcut and from Toastty's
/// own entry points, and creates the task through `task.create`.
@MainActor
final class QuickEntryController: ObservableObject {
    /// The configured shortcut, shown on File ▸ New Task…; nil when
    /// `tasks.toml` turns it off.
    @Published private(set) var shortcut: QuickEntryShortcut? = .default

    private let store: AppStore
    private let agentCatalogProvider: any AgentCatalogProviding
    private let create: @MainActor (TaskCreateRequest) async throws -> TaskRecord
    private let configLoader: @MainActor () throws -> TasksConfig
    private let stagingRootURL: URL
    private let registersGlobalHotKey: Bool
    private let toastDuration: Duration
    private var hotKey: QuickEntryHotKey?

    private(set) var panel: QuickEntryPanel?
    private(set) var model: QuickEntryModel?
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
        agentCatalogProvider: any AgentCatalogProviding,
        create: @escaping @MainActor (TaskCreateRequest) async throws -> TaskRecord,
        configLoader: @escaping @MainActor () throws -> TasksConfig,
        stagingRootURL: URL = FileManager.default.temporaryDirectory
            .appending(path: "toastty-quick-entry", directoryHint: .isDirectory),
        registersGlobalHotKey: Bool,
        toastDuration: Duration = .milliseconds(1600)
    ) {
        self.store = store
        self.agentCatalogProvider = agentCatalogProvider
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
        let model = QuickEntryModel(
            prefill: prefill,
            workspaceOptions: workspaceOptions(),
            agentOptions: agentCatalogProvider.catalog.profiles.map {
                QuickEntryModel.Option(id: $0.id, title: $0.displayName)
            },
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
        panel.contentView = QuickEntryContentView(
            rootView: QuickEntryView(
                model: model,
                dropTarget: dropTarget,
                attachFiles: { [weak self] in self?.chooseFiles() },
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
