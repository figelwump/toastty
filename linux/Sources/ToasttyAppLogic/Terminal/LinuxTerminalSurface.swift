import CoreState
import Foundation

// MARK: - Terminal runtime seam (Linux)
//
// The shared `TerminalRuntimeRegistry` (compiled without
// TOASTTY_HAS_GHOSTTY_KIT on Linux) owns one `TerminalSurfaceController` per
// terminal panel. On macOS that controller hosts an AppKit `TerminalHostView`
// and a `ghostty_surface_t`. On Linux this file replaces it: the controller
// keeps the registry-facing API and forwards terminal operations to a
// `LinuxTerminalSurface` the frontend attaches once its Ghostty GTK widget
// exists. See docs/linux.md "Terminal runtime seam".

/// What a terminal panel's prompt is doing (mirrors `TerminalPromptState`).
public enum LinuxTerminalPromptState: Sendable, Equatable {
    /// Unknown: no shell integration signal yet.
    case unavailable
    /// The shell's child process exited.
    case exited
    /// The shell is idle at a prompt (OSC 133 / Ghostty `is_at_prompt`).
    case idleAtPrompt
    /// A command is running.
    case busy
}

/// One live terminal surface (a Ghostty GTK widget), driven by the app layer.
///
/// Every method runs on the main thread. Text goes in as paste-style input;
/// `sendReturn`/`sendEscape` must be real key presses so bracketed paste and
/// agent TUIs see the same events as keyboard input.
@MainActor
public protocol LinuxTerminalSurface: AnyObject {
    /// The widget is realized, mapped, and its Ghostty surface exists.
    var isReadyForInput: Bool { get }

    /// Paste-style text input (`ghostty_surface_text`). No newline is added.
    func sendText(_ text: String)

    /// A Return key press. Returns false if the surface rejected it.
    func sendReturn() -> Bool

    /// An Escape key press (the interrupt key for Claude Code and Codex).
    func sendEscape() -> Bool

    /// Viewport text, or the whole screen including scrollback.
    func readText(includeScrollback: Bool) -> String?

    /// A Ghostty binding action such as `start_search`, `search:<needle>`,
    /// `navigate_search:next`, `end_search`, `increase_font_size:1`.
    func performBindingAction(_ action: String) -> Bool

    /// Gives the widget keyboard focus. Returns whether it has focus after.
    func grabFocus() -> Bool

    /// Prompt state for agent launch / remote send gating.
    var promptState: LinuxTerminalPromptState { get }

    /// Whether closing the panel should ask first (a process is running).
    /// `nil` when unknown.
    var needsCloseConfirmation: Bool? { get }

    /// The panel was removed from the app state; release the surface.
    func invalidate()
}

/// How the frontend creates a terminal surface for a panel.
public struct LinuxTerminalLaunchConfiguration: Sendable, Equatable {
    /// Environment the shell must be started with (Toastty socket, panel ID,
    /// CLI path, agent shim PATH, profile variables).
    public var environment: [String: String]
    /// Initial working directory, if any.
    public var workingDirectory: String?
    /// Text typed into the shell once it starts (profile startup command or a
    /// restored agent resume command), or nil.
    public var initialInput: String?
    /// Font size override for this window, in points.
    public var fontSizePoints: Double?
}

/// Linux `TerminalSurfaceController`: same name and registry-facing API as
/// the macOS class (`Sources/App/Terminal/TerminalSurfaceController.swift`).
@MainActor
final class TerminalSurfaceController: PanelHostLifecycleControlling {
    let panelID: UUID
    private weak var delegate: (any TerminalSurfaceControllerDelegate)?
    private(set) var surface: (any LinuxTerminalSurface)?
    private var attachment: PanelHostAttachmentToken?
    private var lastAttachmentTransitionAt: Date?
    /// The shell exited (Ghostty child-exited); closing needs no confirmation.
    private(set) var hasExited = false
    private static let requiredAutomationInputStabilityInterval: TimeInterval = 0.05

    init(panelID: UUID, delegate: any TerminalSurfaceControllerDelegate) {
        self.panelID = panelID
        self.delegate = delegate
    }

    // MARK: Frontend attachment

    /// Called by the frontend when its widget for this panel is live.
    func attach(surface: any LinuxTerminalSurface) {
        self.surface = surface
        let token = PanelHostAttachmentToken.next()
        attachment = token
        lastAttachmentTransitionAt = Date()
    }

    /// Called when the widget is destroyed or moved out of the window.
    func detachSurface() {
        surface = nil
        attachment = nil
        lastAttachmentTransitionAt = Date()
    }

    /// Local keyboard/paste input reached the widget (remote-access draft gate).
    func noteLocalInput(kind: TerminalLocalInputKind) {
        delegate?.handleLocalInput(for: panelID, kind: kind)
    }

    func markExited() {
        hasExited = true
    }

    func noteLocalInterruptKey(kind: TerminalLocalInterruptKind) {
        delegate?.handleLocalInterruptKey(for: panelID, kind: kind)
    }

    // MARK: PanelHostLifecycleControlling

    var lifecycleState: PanelHostLifecycleState {
        guard let attachment else { return .detached }
        return surface?.isReadyForInput == true ? .ready(attachment) : .attached(attachment)
    }

    func attachHost(to container: NSView, attachment: PanelHostAttachmentToken) {
        _ = container
        if let current = self.attachment, attachment.generation < current.generation { return }
        self.attachment = attachment
        lastAttachmentTransitionAt = Date()
    }

    func detachHost(attachment: PanelHostAttachmentToken) {
        guard self.attachment == attachment else { return }
        self.attachment = nil
        lastAttachmentTransitionAt = Date()
    }

    // MARK: Registry-facing API

    func invalidate() {
        surface?.invalidate()
        surface = nil
        attachment = nil
    }

    func armFocusModeResizeTrace(workspaceID: UUID) {
        _ = workspaceID
    }

    func applyGhosttyScrollbarPreferenceChange() {}

    @discardableResult
    func focusHostViewIfNeeded() -> Bool {
        surface?.grabFocus() ?? false
    }

    func automationSendText(
        _ text: String,
        submit: Bool,
        focusPolicy: TerminalInputFocusPolicy
    ) -> Bool {
        automationSendTextResult(text, submit: submit, focusPolicy: focusPolicy) == .delivered
    }

    func automationSendTextResult(
        _ text: String,
        submit: Bool,
        focusPolicy: TerminalInputFocusPolicy
    ) -> TerminalInputDeliveryResult {
        guard let surface, isReadyForAutomationInput() else {
            logInputUnavailable(reason: surface == nil ? "no_surface" : "not_ready")
            return .unavailable
        }
        return TerminalAutomationInputDelivery(
            focusPolicy: focusPolicy,
            focusHostViewIfNeeded: { [weak self] in self?.focusHostViewIfNeeded() ?? false },
            sendText: { surface.sendText($0) },
            sendSubmit: { surface.sendReturn() },
            logFocusFailure: { [weak self] in self?.logInputUnavailable(reason: "focus_host_failed") }
        )
        .deliverResult(text: text, submit: submit)
    }

    func automationSendInterruptResult(
        focusPolicy: TerminalInputFocusPolicy
    ) -> TerminalInputDeliveryResult {
        guard let surface, isReadyForAutomationInput() else {
            return .unavailable
        }
        if focusPolicy == .focusTarget, focusHostViewIfNeeded() == false {
            return .unavailable
        }
        return surface.sendEscape() ? .delivered : .unavailable
    }

    func isReadyForAutomationInput(now: Date = Date()) -> Bool {
        guard lifecycleState.isReadyForFocus else { return false }
        if let lastAttachmentTransitionAt,
           now.timeIntervalSince(lastAttachmentTransitionAt) < Self.requiredAutomationInputStabilityInterval {
            return false
        }
        return true
    }

    func automationReadVisibleText(includeScrollback: Bool = false) -> String? {
        surface?.readText(includeScrollback: includeScrollback)
    }

    @discardableResult
    func performSearchAction(_ action: String) -> Bool {
        surface?.performBindingAction(action) ?? false
    }

    func canAcceptFileDrop() -> Bool {
        surface != nil
    }

    func renderAttachmentSnapshot() -> TerminalPanelRenderAttachmentSnapshot {
        let hasSurface = surface != nil
        return TerminalPanelRenderAttachmentSnapshot(
            panelID: panelID,
            controllerExists: true,
            hostHasSuperview: hasSurface,
            hostAttachedToWindow: hasSurface,
            sourceContainerExists: hasSurface,
            sourceContainerAttachedToWindow: hasSurface,
            hostSuperviewMatchesSourceContainer: hasSurface,
            lifecycleState: lifecycleState,
            ghosttySurfaceAvailable: hasSurface
        )
    }

    func handleFileDrop(_ fileURLs: [URL]) -> Bool {
        guard let surface else { return false }
        let filePaths = fileURLs.map { $0.path(percentEncoded: false) }
        guard let payload = TerminalDropPayloadBuilder.shellEscapedPathPayload(forFilePaths: filePaths) else {
            return false
        }
        surface.sendText(payload)
        return true
    }

    var promptState: TerminalPromptState {
        if hasExited { return .exited }
        switch surface?.promptState ?? .unavailable {
        case .unavailable: return .unavailable
        case .exited: return .exited
        case .idleAtPrompt: return .idleAtPrompt
        case .busy: return .busy
        }
    }

    var closeConfirmationAssessment: TerminalCloseConfirmationAssessment? {
        if hasExited { return TerminalCloseConfirmationAssessment(requiresConfirmation: false) }
        guard let needsConfirmation = surface?.needsCloseConfirmation else { return nil }
        return TerminalCloseConfirmationAssessment(requiresConfirmation: needsConfirmation)
    }

    private func logInputUnavailable(reason: String) {
        ToasttyLog.debug(
            "Automation terminal input unavailable",
            category: .terminal,
            metadata: ["panel_id": panelID.uuidString, "reason": reason]
        )
    }
}

/// Linux has no AppKit annotation comment editor; the focus policy only
/// needs the type to exist (`TerminalFocusCoordinator`).
@MainActor
final class BrowserAnnotationCommentInputView: NSTextView {}
