import CGtk
import Foundation

/// Search state per terminal, driven by Ghostty's search actions exactly
/// like macOS `TerminalSearchState` (`start_search`, `search_total`,
/// `search_selected`, `end_search`).
public struct TerminalSearchModel: Equatable, Sendable {
    public var isPresented = false
    public var needle = ""
    public var total: Int?
    public var selected: Int?

    /// "3 of 12", "0 results", or nil while unknown (macOS `matchLabel`).
    public var matchLabel: String? {
        guard let total else { return nil }
        if total == 0 { return "0 results" }
        if let selected { return "\(selected + 1) of \(total)" }
        return "\(total) results"
    }
}

/// Find-in-scrollback bar overlaid at the top-right of a terminal: entry
/// (Enter next, Shift+Enter previous, Escape close), match count, previous,
/// next and close. Needles shorter than three characters are sent after a
/// 300 ms pause, like macOS (`scheduleSearchDispatch`).
@MainActor
final class TerminalSearchBar {
    let root: WidgetPtr
    private let entry: WidgetPtr
    private let countLabel: WidgetPtr
    private var dispatchSource: guint = 0
    private var isSyncing = false

    var onNeedleChanged: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    init() {
        root = Gtk.hbox(spacing: 2, classes: ["terminal-search-bar"])
        gtk_widget_set_halign(root, GTK_ALIGN_END)
        gtk_widget_set_valign(root, GTK_ALIGN_START)
        entry = gtk_search_entry_new()
        gtk_search_entry_set_placeholder_text(cast(entry), "Find in terminal")
        gtk_search_entry_set_search_delay(cast(entry), 0)
        countLabel = Gtk.label("", classes: ["match-count"], ellipsize: false)
        let previous = Gtk.iconButton("go-up-symbolic", tooltip: "Find Previous (\(ShortcutLabels.label(forCommand: "find.previous") ?? ""))")
        let next = Gtk.iconButton("go-down-symbolic", tooltip: "Find Next (\(ShortcutLabels.label(forCommand: "find.next") ?? ""))")
        let close = Gtk.iconButton("window-close-symbolic", tooltip: "Close Find (Escape)")
        for child in [entry, countLabel, previous, next, close] { Gtk.append(root, child) }
        Gtk.setVisible(root, false)

        Signal.connect(entry, "search-changed") { [weak self] in self?.textChanged() }
        Signal.connect(entry, "activate") { [weak self] in
            guard let self else { return }
            self.flushPendingNeedle()
            self.onNext?()
        }
        Signal.connect(entry, "stop-search") { [weak self] in self?.onClose?() }
        Signal.connect(previous, "clicked") { [weak self] in self?.onPrevious?() }
        Signal.connect(next, "clicked") { [weak self] in self?.onNext?() }
        Signal.connect(close, "clicked") { [weak self] in self?.onClose?() }

        // Shift+Enter → previous (GtkSearchEntry only emits activate).
        let keys = gtk_event_controller_key_new()!
        Signal.connectKeyPressed(keys) { [weak self] keyval, _, state in
            guard let self else { return false }
            let key = Int32(keyval)
            if (key == GDK_KEY_Return || key == GDK_KEY_KP_Enter), state.rawValue & GDK_SHIFT_MASK.rawValue != 0 {
                self.flushPendingNeedle()
                self.onPrevious?()
                return true
            }
            if key == GDK_KEY_Escape {
                self.onClose?()
                return true
            }
            return false
        }
        gtk_widget_add_controller(entry, keys)
    }

    var text: String { String(cString: gtk_editable_get_text(cast(entry))) }

    var entryHasFocus: Bool {
        guard let root = gtk_widget_get_root(entry), let focus = gtk_root_get_focus(root) else { return false }
        return focus == entry || gtk_widget_is_ancestor(focus, entry) != 0
    }

    func apply(_ model: TerminalSearchModel) {
        Gtk.setVisible(root, model.isPresented)
        if model.isPresented == false {
            cancelPendingDispatch()
        }
        if text != model.needle, entryHasFocus == false {
            isSyncing = true
            gtk_editable_set_text(cast(entry), model.needle)
            isSyncing = false
        }
        Gtk.setLabel(countLabel, model.matchLabel ?? "")
    }

    /// Sets the needle as if typed (emits `search-changed`).
    func setText(_ text: String) {
        gtk_editable_set_text(cast(entry), text)
    }

    func focusEntry() {
        _ = gtk_widget_grab_focus(entry)
        gtk_editable_select_region(cast(entry), 0, -1)
    }

    private func textChanged() {
        guard isSyncing == false else { return }
        cancelPendingDispatch()
        let needle = text
        if needle.isEmpty == false, needle.count < 3 {
            dispatchSource = MainLoop.timeout(milliseconds: 300) { [weak self] in
                self?.dispatchSource = 0
                self?.onNeedleChanged?(needle)
                return false
            }
        } else {
            onNeedleChanged?(needle)
        }
    }

    private func flushPendingNeedle() {
        guard dispatchSource != 0 else { return }
        cancelPendingDispatch()
        onNeedleChanged?(text)
    }

    private func cancelPendingDispatch() {
        if dispatchSource != 0 {
            MainLoop.cancel(dispatchSource)
            dispatchSource = 0
        }
    }
}
