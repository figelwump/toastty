import CGtk
import CoreState
import Foundation
import GhosttyKit

/// One live Ghostty terminal (`ToasttyGhosttySurface`) and the operations
/// the app layer drives: the Linux equivalent of the Ghostty half of macOS
/// `TerminalSurfaceController`. Its API matches app-logic's
/// `LinuxTerminalSurface` one to one, so the app-logic adapter only forwards.
@MainActor
public final class GhosttyTerminalSurface {
    public enum PromptState: String, Sendable {
        case unavailable, exited, idleAtPrompt, busy
    }

    public let panelID: UUID
    /// `ToasttyGhosttySurface *`.
    let terminal: OpaquePointer
    let widgetRef: GObjectRef
    private(set) var isInvalidated = false
    /// Set when Ghostty reports the child process exited.
    var childExited = false

    init(panelID: UUID, widget: WidgetPtr) {
        self.panelID = panelID
        self.widgetRef = GObjectRef(sinking: widget)
        self.terminal = OpaquePointer(widget)
    }

    public var widget: WidgetPtr { widgetRef.widgetPointer }

    var surface: ghostty_surface_t? {
        isInvalidated ? nil : toastty_ghostty_surface_get_surface(terminal)
    }

    // MARK: LinuxTerminalSurface

    public var isReadyForInput: Bool {
        guard let surface else { return false }
        return ghostty_surface_process_exited(surface) == false
    }

    /// Paste-style input (`ghostty_surface_text`); no newline is added.
    public func sendText(_ text: String) {
        guard let surface, text.isEmpty == false else { return }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { pointer in
                ghostty_surface_text(surface, pointer, UInt(buffer.count))
            }
        }
    }

    /// Typed input through the widget's IME commit path (what a user's
    /// keyboard produces), unlike paste-style `sendText`.
    public func typeText(_ text: String) {
        guard isInvalidated == false else { return }
        toastty_ghostty_surface_commit_text(terminal, text)
    }

    /// A real key press + release through the widget's key translation.
    @discardableResult
    public func sendKey(keyval: UInt32, state: GdkModifierType = GdkModifierType(rawValue: 0)) -> Bool {
        guard isInvalidated == false else { return false }
        let consumed = toastty_ghostty_surface_send_key(terminal, keyval, 0, state, 1) != 0
        _ = toastty_ghostty_surface_send_key(terminal, keyval, 0, state, 0)
        return consumed
    }

    public func sendReturn() -> Bool { sendKey(keyval: UInt32(GDK_KEY_Return)) }

    public func sendEscape() -> Bool { sendKey(keyval: UInt32(GDK_KEY_Escape)) }

    /// Viewport text, or the whole screen including scrollback. Like macOS,
    /// the scrollback read ends at the screen bottom.
    public func readText(includeScrollback: Bool) -> String? {
        guard let surface else { return nil }
        let tag = includeScrollback ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_VIEWPORT
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text else { return "" }
        let buffer = UnsafeRawBufferPointer(start: UnsafeRawPointer(pointer), count: Int(text.text_len))
        return String(decoding: buffer, as: UTF8.self)
    }

    /// A Ghostty binding action (`start_search`, `search:<needle>`,
    /// `navigate_search:next`, `end_search`, `set_font_size:13`, `copy_to_clipboard`, ...).
    @discardableResult
    public func performBindingAction(_ action: String) -> Bool {
        guard let surface, action.isEmpty == false else { return false }
        let bytes = Array(action.utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { pointer in
                ghostty_surface_binding_action(surface, pointer, UInt(buffer.count))
            }
        }
    }

    public func grabFocus() -> Bool {
        guard isInvalidated == false else { return false }
        if gtk_widget_has_focus(widget) != 0 { return true }
        _ = gtk_widget_grab_focus(widget)
        return gtk_widget_has_focus(widget) != 0
    }

    public var hasFocus: Bool { gtk_widget_has_focus(widget) != 0 }

    public var promptState: PromptState {
        guard let surface else { return .unavailable }
        if childExited || ghostty_surface_process_exited(surface) { return .exited }
        return ghostty_surface_is_at_prompt(surface) ? .idleAtPrompt : .busy
    }

    /// Whether closing should ask first (`ghostty_surface_needs_confirm_quit`,
    /// which honors `confirm-close-surface` and shell-integration prompt state).
    public var needsCloseConfirmation: Bool? {
        guard let surface else { return nil }
        if childExited || ghostty_surface_process_exited(surface) { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    public func invalidate() {
        isInvalidated = true
    }

    // MARK: Extras

    public var title: String? { toastty_ghostty_surface_get_title(terminal).map { String(cString: $0) } }
    public var pwd: String? { toastty_ghostty_surface_get_pwd(terminal).map { String(cString: $0) } }

    public var rendererName: String {
        toastty_ghostty_surface_get_renderer(terminal) == TOASTTY_GHOSTTY_RENDERER_GL ? "gl" : "offscreen"
    }

    public var hasSelection: Bool { surface.map { ghostty_surface_has_selection($0) } ?? false }

    /// Grid size in cells.
    public var gridSize: (columns: Int, rows: Int)? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        return (Int(size.columns), Int(size.rows))
    }

    public var foregroundPID: Int? {
        guard let surface else { return nil }
        let pid = ghostty_surface_foreground_pid(surface)
        return pid > 0 ? Int(pid) : nil
    }
}
