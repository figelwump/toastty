#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CoreState
import Foundation
import ToasttyAppKitShim
import ToasttyAppLogic

/// `LinuxStoreBinding` over the app-logic layer's `AppStore`
/// (`LinuxAppLogic`): every UI action goes through `AppStore.send`, so
/// persistence, terminal/web runtimes, the automation socket, sessions and
/// Remote Access see the same state as the window.
@MainActor
public final class AppLogicStoreBinding: LinuxStoreBinding, LinuxSessionSource, LinuxAppCommandHandling {
    public let logic: LinuxAppLogic
    /// Commands not handled here fall through to these (UI-level commands).
    public var fallbackCommands: any LinuxAppCommandHandling = UnavailableAppCommands()

    public init(logic: LinuxAppLogic) {
        self.logic = logic
    }

    // MARK: LinuxStoreBinding

    /// State with live terminal titles folded in (macOS shows live titles
    /// in tabs and headers; they are display-only and not persisted).
    public var state: AppState { logic.displayState }

    @discardableResult
    public func send(_ action: AppAction) -> Bool {
        logic.send(action, source: "linux_ui")
    }

    public func observe(_ handler: @escaping @MainActor (AppState) -> Void) -> LinuxObservation {
        // observeState fires immediately; LinuxStoreBinding observers expect
        // only changes, so skip the initial value.
        var isInitial = true
        let subscription = logic.observeDisplayState { state in
            if isInitial {
                isInitial = false
                return
            }
            handler(state)
        }
        return LinuxObservation { MainActor.assumeIsolated { subscription.cancel() } }
    }

    public var sessions: any LinuxSessionSource { self }
    public var commands: any LinuxAppCommandHandling { self }

    // MARK: LinuxSessionSource

    public func sessions(workspaceID: UUID) -> [WorkspaceSessionStatus] {
        logic.sessionStatuses(workspaceID: workspaceID)
    }

    public func isFlaggedForLater(sessionID: String) -> Bool {
        logic.isLaterFlagged(sessionID: sessionID)
    }

    public func setFlaggedForLater(sessionID: String, flagged: Bool) {
        logic.setLaterFlag(sessionID: sessionID, isFlagged: flagged)
    }

    public func observe(_ handler: @escaping @MainActor () -> Void) -> LinuxObservation {
        let subscription = logic.observeSessions(handler)
        return LinuxObservation { MainActor.assumeIsolated { subscription.cancel() } }
    }

    // MARK: LinuxAppCommandHandling

    public func perform(commandID: String, windowID: UUID?) -> LinuxCommandResult {
        switch logic.performAppCommand(commandID, windowID: windowID) {
        case .handled: return .handled
        case .failed(let message): return .failed(message)
        case .notHandled: return fallbackCommands.perform(commandID: commandID, windowID: windowID)
        }
    }
}

/// Drives libdispatch's main queue and `RunLoop.main` timers from the GLib
/// main loop (docs/linux.md "Main loop integration").
@MainActor
enum AppLogicMainLoop {
    private static var channel: OpaquePointer?
    private static var isInstalled = false

    static func install() {
        guard isInstalled == false else { return }
        isInstalled = true
        if let fd = LinuxMainLoopIntegration.mainQueueFileDescriptor {
            let ioChannel = g_io_channel_unix_new(fd)
            channel = OpaquePointer(ioChannel)
            let callback: GIOFunc = { _, _, _ in
                MainActor.assumeIsolated { LinuxMainLoopIntegration.drainMainQueue() }
                return 1
            }
            g_io_add_watch(ioChannel, G_IO_IN, callback, nil)
        } else {
            FileHandle.standardError.write(Data("toastty-linux: libdispatch main-queue handle unavailable; polling\n".utf8))
        }
        pumpRunLoop()
    }

    /// Fires due RunLoop timers, then re-arms for the next one (at most 50 ms
    /// later, so timers scheduled meanwhile are not late by much).
    private static func pumpRunLoop() {
        if LinuxMainLoopIntegration.mainQueueFileDescriptor == nil {
            LinuxMainLoopIntegration.drainMainQueue()
        }
        let next = LinuxMainLoopIntegration.serviceRunLoop()
        let delay = next.map { max(1, min(50, Int($0.timeIntervalSinceNow * 1000))) } ?? 50
        MainLoop.timeout(milliseconds: UInt32(delay)) {
            pumpRunLoop()
            return false
        }
    }
}

extension ToasttyLinuxMain {
    /// The app-logic frontend: real AppStore, automation socket, managed
    /// agents, persistence and Remote Access behind the GTK UI.
    @MainActor
    static func runWithAppLogic(arguments: [String], automation: AutomationScript?, nonUnique: Bool) -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        if automation != nil {
            // Scripted UI runs (Broadway tests) are automation sessions: no
            // layout persistence, and an isolated runtime home unless the
            // caller chose one.
            if environment["TOASTTY_AUTOMATION"] == nil { setenv("TOASTTY_AUTOMATION", "1", 1) }
            if environment["TOASTTY_RUNTIME_HOME"] == nil, environment["TOASTTY_DEV_WORKTREE_ROOT"] == nil {
                let home = FileManager.default.temporaryDirectory
                    .appendingPathComponent("toastty-linux-automation-\(getpid())", isDirectory: true)
                try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
                setenv("TOASTTY_RUNTIME_HOME", home.path, 1)
            }
        }
        // Main-loop hooks first: bootstrap schedules main-actor work.
        AppLogicMainLoop.install()
        var options = LinuxAppLogic.Options()
        // Scripted runs only: a fake Tailscale Serve so Remote Access pairing
        // can be driven on Broadway (TOASTTY_LINUX_FAKE_TAILNET_PORT picks the
        // loopback gateway port).
        if automation != nil, let origin = environment["TOASTTY_LINUX_FAKE_TAILNET_ORIGIN"] {
            options.simulateTailnet(origin: origin, port: environment["TOASTTY_LINUX_FAKE_TAILNET_PORT"].flatMap { UInt16($0) })
        }
        let logic = LinuxAppLogic(options: options)
        let binding = AppLogicStoreBinding(logic: logic)
        let app = LinuxAppController(store: binding, nonUnique: nonUnique)
        app.automation = automation
        // Real desktop services once the application exists (alerts, URLs,
        // clipboard, notifications, dock badge, windows).
        LinuxPlatform.install(GtkPlatformServices(app: app))
        let webPanels = app.installWebPanels()
        webPanels.attach(logic: logic)
        logic.setBrowserHostMaterializer { [weak app] panelID in app?.materializeWebPanel(panelID: panelID) }
        app.installTerminals { app in AppLogicTerminalRuntimeBridge(logic: logic, store: app.store) }
        app.installRemoteAccessUI(logic: logic)
        // Agent profiles: header buttons, "Run Agent" palette entries and
        // Ctrl+Alt+key launches through the macOS AgentLaunchUI path.
        let agentLauncher = AppLogicAgentLauncher(logic: logic)
        let profiles = TerminalProfileShortcuts.shared
        profiles.agentLauncher = agentLauncher
        profiles.setAgentCatalog(logic.agentCatalog, filePath: logic.agentProfilesFilePath)
        let agentCatalogSubscription = logic.observeAgentCatalog {
            profiles.setAgentCatalog(logic.agentCatalog, filePath: logic.agentProfilesFilePath)
        }
        defer { withExtendedLifetime((agentLauncher, agentCatalogSubscription)) {} }
        // `expect sessions=working` in scripted runs: the selected workspace's
        // session statuses, in sidebar order.
        AutomationScript.summaryContributors.append { [weak logic] app in
            guard let logic, let window = app.selectedWindowController(),
                  let workspaceID = logic.state.workspaceSelection(in: window.windowID)?.workspaceID else { return [:] }
            return ["sessions": logic.sessionStatuses(workspaceID: workspaceID).map(\.status.kind.rawValue).joined(separator: ",")]
        }
        Signal.connect(app.application, "activate", after: true) {
            MainLoop.idle { logic.markAutomationReady() }
        }
        Signal.connect(app.application, "shutdown") {
            logic.shutdown()
        }
        // SIGTERM/SIGINT quit through GApplication so layout persistence
        // flushes (macOS flushes on applicationWillTerminate).
        var signalSources: [DispatchSourceSignal] = []
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    // Tear the windows (and their Ghostty surfaces) down
                    // first, like the Quit command, so renderer threads stop
                    // before the process exits.
                    for controller in app.orderedWindows { controller.destroy() }
                    g_application_quit(cast(app.application))
                }
            }
            source.resume()
            signalSources.append(source)
        }
        let status = app.run(arguments: arguments)
        logic.shutdown()
        signalSources.forEach { $0.cancel() }
        return status
    }
}
#endif

#if TOASTTY_LINUX_APP_LOGIC
@MainActor
final class AppLogicAgentLauncher: TerminalProfileShortcuts.AgentLaunching {
    private let logic: LinuxAppLogic
    init(logic: LinuxAppLogic) { self.logic = logic }

    func canLaunchAgent(profileID: String, windowID: UUID) -> Bool {
        logic.canLaunchAgent(profileID: profileID, windowID: windowID)
    }

    func launchAgent(profileID: String, windowID: UUID) -> Bool {
        logic.launchAgentFromUI(profileID: profileID, windowID: windowID)
    }
}
#endif
