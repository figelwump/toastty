import CGtk
import Foundation

/// A drag handle on the inner edge of an `AdwOverlaySplitView` sidebar
/// (the split view itself is not user-resizable). The left sidebar's handle
/// sits on its trailing edge, the right panel's on its leading edge; dragging
/// reports the new width, which the window controller stores in `AppState`
/// and applies on render.
@MainActor
final class SplitViewResizeHandle {
    /// Wraps `sidebar`; put `root` in the split view instead.
    let root: WidgetPtr
    var onWidthChanged: ((Double) -> Void)?

    private let sidebar: WidgetPtr
    private let leadingEdge: Bool
    private var startWidth: Double?

    init(sidebar: WidgetPtr, edge: GtkAlign) {
        self.sidebar = sidebar
        leadingEdge = edge == GTK_ALIGN_START
        root = gtk_overlay_new()!
        gtk_overlay_set_child(cast(root), sidebar)

        let handle = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_widget_add_css_class(handle, "split-resize-handle")
        gtk_widget_set_halign(handle, edge)
        gtk_widget_set_valign(handle, GTK_ALIGN_FILL)
        gtk_widget_set_size_request(handle, 6, -1)
        Gtk.cursor(handle, "col-resize")
        gtk_widget_set_tooltip_text(handle, "Drag to resize")
        gtk_overlay_add_overlay(cast(root), handle)

        let drag = gtk_gesture_drag_new()!
        Signal.connectDoubles(drag, "drag-begin") { [weak self] _, _ in
            guard let self else { return }
            gtk_gesture_set_state(cast(drag), GTK_EVENT_SEQUENCE_CLAIMED)
            self.startWidth = Double(gtk_widget_get_width(self.sidebar))
        }
        Signal.connectDoubles(drag, "drag-update") { [weak self] offsetX, _ in
            guard let self, let startWidth = self.startWidth else { return }
            self.onWidthChanged?(self.leadingEdge ? startWidth - offsetX : startWidth + offsetX)
        }
        Signal.connectDoubles(drag, "drag-end") { [weak self] _, _ in
            self?.startWidth = nil
        }
        gtk_widget_add_controller(handle, cast(drag))
    }
}
