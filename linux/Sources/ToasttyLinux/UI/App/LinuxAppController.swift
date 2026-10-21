import CGtk
import CoreState
import Foundation

/// Owns the `AdwApplication`, the store binding, panel hosts and one
/// window controller per `WindowState`.
@MainActor
public final class LinuxAppController {
    public static let applicationID = "com.GiantThings.toastty"

    public let application: OpaquePointer
    public let store: any LinuxStoreBinding
    public let hosts: PanelHostRegistry
    public let preferences = LinuxUIPreferences()
    public private(set) var windows: [UUID: LinuxWindowController] = [:]
    private var windowOrder: [UUID] = []
    private var observation: LinuxObservation?
    private var sessionObservation: LinuxObservation?
    private var hasActivated = false
    public var automation: AutomationScript?

    public init(store: any LinuxStoreBinding, hosts: PanelHostRegistry = PanelHostRegistry(), nonUnique: Bool) {
        self.store = store
        self.hosts = hosts
        let flags = GApplicationFlags(rawValue: nonUnique ? 1 << 5 : 0) // G_APPLICATION_NON_UNIQUE
        application = OpaquePointer(adw_application_new(Self.applicationID, flags))

        Signal.connect(application, "startup") { [weak self] in self?.startup() }
        Signal.connect(application, "activate") { [weak self] in self?.activate() }
    }

    public func run(arguments: [String]) -> Int32 {
        var cArguments = arguments.map { strdup($0) }
        defer { cArguments.forEach { free($0) } }
        return cArguments.withUnsafeMutableBufferPointer { buffer in
            g_application_run(cast(application), Int32(buffer.count), buffer.baseAddress)
        }
    }

    private func startup() {
        LinuxTheme.install()
        AppIcon.install()
        LinuxTheme.apply(preferences.colorScheme)
        registerAccelerators()
    }

    private func activate() {
        if hasActivated {
            windowOrder.first.flatMap { windows[$0] }?.present()
            return
        }
        hasActivated = true
        observation = store.observe { [weak self] state in self?.stateChanged(state) }
        sessionObservation = store.sessions.observe { [weak self] in
            self?.windows.values.forEach { $0.scheduleRender() }
        }
        reconcileWindows(store.state)
        automation?.start(app: self)
    }

    /// Registers GTK accelerators for global shortcuts that are safe in any
    /// focus context (so menus show them and they work with GTK's own
    /// accelerator handling). Arrow, Page and Alt-only chords stay with the
    /// capture-phase controller, which steps aside while a dialog's text
    /// entry has focus.
    private func registerAccelerators() {
        for binding in LinuxCommandTable.globalBindings where Self.isSafeAccelerator(binding.accelerators) {
            var cStrings: [UnsafeMutablePointer<CChar>?] = binding.accelerators.map { strdup($0) }
            cStrings.append(nil)
            cStrings.withUnsafeBufferPointer { buffer in
                buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { pointer in
                    gtk_application_set_accels_for_action(cast(application), "win.\(binding.actionName)", pointer)
                }
            }
            cStrings.forEach { free($0) }
        }
    }

    public static func isSafeAccelerator(_ accelerators: [String]) -> Bool {
        accelerators.allSatisfy { accelerator in
            let unsafeKeys = ["Left", "Right", "Up", "Down", "Page_Up", "Page_Down", "Home", "End", "Insert"]
            if unsafeKeys.contains(where: { accelerator.hasSuffix(">\($0)") }) { return false }
            let usesControlOrFKey = accelerator.contains("<Control>") || accelerator.range(of: #"^(<Shift>)?F\d+$"#, options: .regularExpression) != nil
            return usesControlOrFKey
        }
    }

    // MARK: State → windows

    private func stateChanged(_ state: AppState) {
        reconcileWindows(state)
        for controller in windows.values { controller.scheduleRender() }
        collectClosedPanels(state)
        if state.windows.isEmpty, hasActivated {
            g_application_quit(cast(application))
        }
    }

    private func reconcileWindows(_ state: AppState) {
        let liveIDs = state.windows.map(\.id)
        for windowID in liveIDs where windows[windowID] == nil {
            let controller = LinuxWindowController(
                application: application,
                windowID: windowID,
                store: store,
                hosts: hosts,
                preferences: preferences
            )
            controller.onAppCommand = { [weak self] id, windowID in self?.performAppCommand(id, windowID: windowID) }
            windows[windowID] = controller
            windowOrder.append(windowID)
            controller.present()
        }
        for windowID in windowOrder where liveIDs.contains(windowID) == false {
            windows.removeValue(forKey: windowID)?.destroy()
        }
        windowOrder.removeAll { liveIDs.contains($0) == false }
    }

    /// Releases host widgets for panels that left state entirely (panels
    /// that only moved between windows keep their widget).
    private func collectClosedPanels(_ state: AppState) {
        var live = Set<UUID>()
        for workspace in state.workspacesByID.values {
            live.formUnion(workspace.allPanelsByID.keys)
        }
        for panelID in hosts.livePanelIDs where live.contains(panelID) == false {
            hosts.close(panelID: panelID)
        }
    }

    public func performAppCommand(_ id: String, windowID: UUID) {
        switch id {
        case "window.create":
            store.send(.createWindow(seed: nil, initialFrame: nil))
        case "window.close":
            if store.state.windows.count <= 1 {
                requestQuit(from: windowID)
            } else {
                store.send(.closeWindow(windowID: windowID))
            }
        case "app.quit":
            requestQuit(from: windowID)
        default:
            break
        }
    }

    private func requestQuit(from windowID: UUID) {
        let quit = { [weak self] in
            guard let self else { return }
            for controller in self.windows.values { controller.destroy() }
            self.windows.removeAll()
            g_application_quit(cast(self.application))
        }
        guard preferences.askBeforeQuitting, let controller = windows[windowID] else {
            quit()
            return
        }
        Dialogs.confirm(
            parent: controller.window,
            heading: "Quit Toastty?",
            body: "All terminals and running agents in every window will close.",
            confirmLabel: "_Quit",
            confirmIsDefault: true
        ) { quit() }
    }

    public var orderedWindows: [LinuxWindowController] {
        windowOrder.compactMap { windows[$0] }
    }

    public func selectedWindowController() -> LinuxWindowController? {
        if let id = store.state.selectedWindowID, let controller = windows[id] { return controller }
        return orderedWindows.first
    }
}
