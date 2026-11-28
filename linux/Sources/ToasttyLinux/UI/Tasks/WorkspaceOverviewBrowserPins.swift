#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CGtkShim
import Foundation
@testable import ToasttyAppLogic

/// A separate section so browser pins don't change the Scratchpad preview or selection.
@MainActor
final class WorkspaceOverviewBrowserPins {
    let root = Gtk.vbox()
    private let rows = Gtk.vbox(spacing: 2)
    private var workspaceID: UUID?
    private var pins: [WorkspaceBrowserPin] = []
    var onOpen: ((WorkspaceBrowserPin) -> Void)?
    var onRemove: ((WorkspaceBrowserPin) -> Void)?

    init() {
        Gtk.append(root, Gtk.label("Pinned Browsers", classes: ["tasks-card-title"]))
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(cast(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(cast(scroller), 1)
        gtk_scrolled_window_set_max_content_height(cast(scroller), 160)
        Gtk.margins(scroller, top: 0, bottom: 6, start: 8, end: 8)
        gtk_scrolled_window_set_child(cast(scroller), rows)
        Gtk.append(root, scroller)
        Gtk.append(root, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))
        Gtk.setVisible(root, false)
    }

    func render(workspaceID: UUID, pins: [WorkspaceBrowserPin]) {
        guard self.workspaceID != workspaceID || self.pins != pins else { return }
        self.workspaceID = workspaceID
        self.pins = pins
        Gtk.setVisible(root, !pins.isEmpty)
        Gtk.removeAllChildren(rows)
        for (index, pin) in pins.enumerated() {
            let line = Gtk.hbox(spacing: 4)
            let open = gtk_button_new()!
            Gtk.addClasses(open, ["flat"])
            Gtk.setName(open, "workspace.overview.browser.\(index).open")
            Gtk.expand(open, v: false)
            gtk_widget_set_tooltip_text(open, "Open \(pin.title) in the right panel")
            let content = Gtk.hbox(spacing: 8)
            Gtk.append(content, Gtk.image("web-browser-symbolic", pixelSize: 14))
            let labels = Gtk.vbox(spacing: 2)
            Gtk.expand(labels, v: false)
            Gtk.append(labels, Gtk.label(pin.title, classes: ["tasks-row-title"]))
            Gtk.append(labels, Gtk.label(pin.url, classes: ["tasks-row-status"]))
            Gtk.append(content, labels)
            Gtk.append(content, Gtk.image("view-dual-symbolic", pixelSize: 14))
            gtk_button_set_child(cast(open), content)
            Signal.connect(open, "clicked") { [weak self] in self?.onOpen?(pin) }
            Gtk.append(line, open)
            let remove = Gtk.iconButton("window-close-symbolic", tooltip: "Unpin \(pin.title)")
            Gtk.setName(remove, "workspace.overview.browser.\(index).unpin")
            Signal.connect(remove, "clicked") { [weak self] in self?.onRemove?(pin) }
            Gtk.append(line, remove)
            Gtk.append(rows, line)
        }
    }
}
#endif
