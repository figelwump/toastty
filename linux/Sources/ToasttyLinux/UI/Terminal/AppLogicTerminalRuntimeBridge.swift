#if TOASTTY_LINUX_APP_LOGIC
import CoreState
import Foundation
import ToasttyAppLogic

/// `TerminalRuntimeBridge` over the app-logic facade (`LinuxAppLogic`,
/// docs/linux.md "Terminal runtime seam"). Compiled when `ToasttyLinuxUI`
/// depends on `ToasttyAppLogic` and defines `TOASTTY_LINUX_APP_LOGIC`.
///
/// Wiring (in the app-logic frontend bootstrap):
///
///     app.installTerminals { app in AppLogicTerminalRuntimeBridge(logic: logic, store: app.store) }
///
/// With this bridge the automation socket (`terminal_send_text`,
/// `terminal_visible_text`, `terminal_state`), managed agent launches,
/// remote send/interrupt, restore/resume and profile startup commands reach
/// the Ghostty surfaces through `LinuxTerminalSurface`.
@MainActor
public final class AppLogicTerminalRuntimeBridge: TerminalRuntimeBridge {
    public let logic: LinuxAppLogic
    private var adapters: [UUID: GhosttyLinuxTerminalSurface] = [:]
    private let standalone: StandaloneTerminalRuntimeBridge

    public init(logic: LinuxAppLogic, store: any LinuxStoreBinding) {
        self.logic = logic
        standalone = StandaloneTerminalRuntimeBridge(store: store)
        standalone.openExternally = { openURIExternally($0) }
    }

    public var state: AppState { logic.state }

    @discardableResult
    public func send(_ action: AppAction) -> Bool { logic.send(action, source: "linux_terminal") }

    public func launchSpec(panelID: UUID, terminal: TerminalPanelState, windowID: UUID) -> TerminalLaunchSpec {
        guard let configuration = logic.terminalLaunchConfiguration(panelID: panelID) else {
            return standalone.launchSpec(panelID: panelID, terminal: terminal, windowID: windowID)
        }
        return TerminalLaunchSpec(
            environment: configuration.environment,
            workingDirectory: configuration.workingDirectory,
            initialInput: configuration.initialInput,
            fontPoints: configuration.fontSizePoints ?? logic.state.effectiveTerminalFontPoints(for: windowID)
        )
    }

    public func surfaceDidAttach(_ surface: GhosttyTerminalSurface, panelID: UUID) {
        let adapter = GhosttyLinuxTerminalSurface(surface)
        adapters[panelID] = adapter
        logic.attachTerminalSurface(adapter, panelID: panelID)
    }

    public func surfaceDidDetach(panelID: UUID) {
        adapters.removeValue(forKey: panelID)
        logic.detachTerminalSurface(panelID: panelID)
    }

    public func surfaceDidLaunch(panelID: UUID) {
        logic.terminalSurfaceDidLaunch(panelID: panelID)
    }

    public func handle(_ event: TerminalRuntimeEvent, panelID: UUID) {
        let appEvent: LinuxTerminalRuntimeEvent
        switch event {
        case .title(let title): appEvent = .title(title)
        case .workingDirectory(let cwd): appEvent = .workingDirectory(cwd)
        case .bell: appEvent = .bell
        case .commandFinished(let exitCode, let duration):
            appEvent = .commandFinished(exitCode: exitCode, durationNanoseconds: duration)
        case .childExited(let exitCode, let runtime):
            appEvent = .childExited(exitCode: exitCode, runtimeMilliseconds: runtime)
        case .programStatus(let status): appEvent = .programStatus(status)
        case .desktopNotification(let title, let body): appEvent = .desktopNotification(title: title, body: body)
        }
        // Same metadata/session/notification path as macOS
        // (TerminalMetadataService, SessionRuntimeStore).
        logic.handleTerminalRuntimeEvent(panelID: panelID, event: appEvent)
    }

    public func noteLocalInput(_ input: TerminalLocalInput, panelID: UUID) {
        switch input {
        case .key: logic.terminalDidReceiveLocalInput(panelID: panelID, isPaste: false)
        case .paste: logic.terminalDidReceiveLocalInput(panelID: panelID, isPaste: true)
        case .controlC:
            logic.terminalDidReceiveLocalInput(panelID: panelID, isPaste: false)
            logic.terminalDidReceiveInterruptKey(panelID: panelID, isEscape: false)
        case .escape:
            logic.terminalDidReceiveLocalInput(panelID: panelID, isPaste: false)
            logic.terminalDidReceiveInterruptKey(panelID: panelID, isEscape: true)
        }
    }

    public func setGhosttyConfiguredFontPoints(_ points: Double?) {
        logic.setGhosttyConfiguredFontPoints(points)
    }

    public func openLink(_ url: URL, panelID: UUID, alternate: Bool) -> Bool {
        logic.openTerminalLink(panelID: panelID, url: url, alternate: alternate)
    }

    public func closePanel(panelID: UUID) {
        // The UI already asked (GhosttyTerminalHost.confirmClose); a plain
        // close avoids a second prompt from FocusedPanelCommandController.
        _ = logic.send(.closePanel(panelID: panelID), source: "linux_terminal")
    }
}

/// `LinuxTerminalSurface` for a Ghostty surface (one-to-one forwarding).
@MainActor
final class GhosttyLinuxTerminalSurface: LinuxTerminalSurface {
    let surface: GhosttyTerminalSurface

    init(_ surface: GhosttyTerminalSurface) {
        self.surface = surface
    }

    var isReadyForInput: Bool { surface.isReadyForInput }
    func sendText(_ text: String) { surface.sendText(text) }
    func sendReturn() -> Bool { surface.sendReturn() }
    func sendEscape() -> Bool { surface.sendEscape() }
    func readText(includeScrollback: Bool) -> String? { surface.readText(includeScrollback: includeScrollback) }
    func performBindingAction(_ action: String) -> Bool { surface.performBindingAction(action) }
    func grabFocus() -> Bool { surface.grabFocus() }

    var promptState: LinuxTerminalPromptState {
        switch surface.promptState {
        case .unavailable: .unavailable
        case .exited: .exited
        case .idleAtPrompt: .idleAtPrompt
        case .busy: .busy
        }
    }

    var needsCloseConfirmation: Bool? { surface.needsCloseConfirmation }
    func invalidate() { surface.invalidate() }
}
#endif
