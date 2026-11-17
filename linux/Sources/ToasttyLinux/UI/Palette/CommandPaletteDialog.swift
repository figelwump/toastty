import CGtk
import Foundation

/// Centered command palette: an `AdwDialog` with a search entry and a
/// fuzzy-filtered command list showing shortcut labels.
@MainActor
public final class CommandPaletteDialog {
    public let dialog: WidgetPtr
    private let dialogRef: GObjectRef
    private let entry: WidgetPtr
    private let list: WidgetPtr
    private let footer: WidgetPtr
    private let catalog: [PaletteItem]
    private var results: [PaletteItem] = []
    private let onExecute: (String) -> Void
    private var didExecute = false

    public init(catalog: [PaletteItem], initialQuery: String = "", onExecute: @escaping (String) -> Void) {
        self.catalog = catalog
        self.onExecute = onExecute

        dialog = widget(adw_dialog_new())
        dialogRef = GObjectRef(sinking: dialog)
        adw_dialog_set_title(cast(dialog), "Command Palette")
        adw_dialog_set_content_width(cast(dialog), 580)
        adw_dialog_set_content_height(cast(dialog), 440)
        Gtk.addClasses(dialog, ["command-palette"])

        let content = Gtk.vbox()
        entry = gtk_search_entry_new()
        Gtk.addClasses(entry, ["palette-search"])
        gtk_search_entry_set_placeholder_text(cast(entry), "Type a command…")
        gtk_search_entry_set_search_delay(cast(entry), 0)
        Gtk.append(content, entry)

        list = gtk_list_box_new()
        gtk_list_box_set_selection_mode(cast(list), GTK_SELECTION_BROWSE)
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(cast(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(cast(scroller), list)
        Gtk.expand(scroller)
        Gtk.append(content, scroller)

        footer = Gtk.label("", classes: ["palette-footer"])
        Gtk.append(content, footer)
        adw_dialog_set_child(cast(dialog), content)

        Signal.connect(entry, "search-changed") { [weak self] in self?.refresh() }
        Signal.connect(entry, "activate") { [weak self] in self?.executeSelected() }
        Signal.connect(entry, "stop-search") { [weak self] in self?.close() }
        Signal.connectPointer(list, "row-activated") { [weak self] row in
            guard let self, let row else { return }
            self.execute(index: Int(gtk_list_box_row_get_index(cast(row))))
        }

        let keys = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        Signal.connectKeyPressed(keys) { [weak self] keyval, _, _ in
            guard let self else { return false }
            switch Int32(keyval) {
            case GDK_KEY_Down, GDK_KEY_KP_Down: self.moveSelection(1); return true
            case GDK_KEY_Up, GDK_KEY_KP_Up: self.moveSelection(-1); return true
            case GDK_KEY_Page_Down: self.moveSelection(8); return true
            case GDK_KEY_Page_Up: self.moveSelection(-8); return true
            default: return false
            }
        }
        gtk_widget_add_controller(entry, keys)

        if initialQuery.isEmpty == false {
            gtk_editable_set_text(cast(entry), initialQuery)
        }
        refresh()
    }

    public func present(over parent: WidgetPtr) {
        adw_dialog_present(cast(dialog), parent)
        gtk_widget_grab_focus(entry)
    }

    public func close() {
        adw_dialog_close(cast(dialog))
    }

    /// Visible result IDs, for tests and automation.
    public var resultIDs: [String] { results.map(\.id) }

    public func setQuery(_ query: String) {
        gtk_editable_set_text(cast(entry), query)
        refresh()
    }

    private func refresh() {
        let query = String(cString: gtk_editable_get_text(cast(entry)))
        results = PaletteModel.filter(catalog, query: query)
        gtk_list_box_remove_all(cast(list))
        for item in results {
            gtk_list_box_append(cast(list), makeRow(item))
        }
        if let first = gtk_list_box_get_row_at_index(cast(list), 0) {
            gtk_list_box_select_row(cast(list), first)
        }
        let count = results.count
        Gtk.setLabel(footer, count == 0
            ? "No matching commands — try a broader query."
            : "\(count) \(count == 1 ? "command" : "commands") · Enter to run · Esc to close")
    }

    private func makeRow(_ item: PaletteItem) -> WidgetPtr {
        let row = Gtk.hbox(spacing: 12)
        let text = Gtk.vbox()
        gtk_widget_set_hexpand(text, 1)
        Gtk.append(text, Gtk.label(item.title))
        if let subtitle = item.subtitle {
            Gtk.append(text, Gtk.label(subtitle, classes: ["palette-subtitle"]))
        }
        Gtk.append(row, text)
        if let accelerator = item.accelerator {
            let shortcut = adw_shortcut_label_new(accelerator)!
            gtk_widget_set_valign(shortcut, GTK_ALIGN_CENTER)
            Gtk.append(row, shortcut)
        }
        return row
    }

    private func moveSelection(_ delta: Int) {
        guard results.isEmpty == false else { return }
        let current = gtk_list_box_get_selected_row(cast(list)).map { Int(gtk_list_box_row_get_index($0)) } ?? 0
        let next = min(max(current + delta, 0), results.count - 1)
        if let row = gtk_list_box_get_row_at_index(cast(list), Int32(next)) {
            gtk_list_box_select_row(cast(list), row)
            gtk_widget_grab_focus(widget(row))
            gtk_widget_grab_focus(entry)
        }
    }

    private func executeSelected() {
        guard let row = gtk_list_box_get_selected_row(cast(list)) else { return }
        execute(index: Int(gtk_list_box_row_get_index(row)))
    }

    private func execute(index: Int) {
        guard didExecute == false, results.indices.contains(index) else { return }
        didExecute = true
        let id = results[index].id
        close()
        MainLoop.idle { [onExecute] in onExecute(id) }
    }
}
