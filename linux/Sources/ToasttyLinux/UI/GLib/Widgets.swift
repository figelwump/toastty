import CGtk
import CGtkShim

/// Small constructors and setters so view code reads as layout, not casts.
@MainActor
public enum Gtk {
    public static func box(_ orientation: GtkOrientation, spacing: Int32 = 0, classes: [String] = []) -> WidgetPtr {
        let box = gtk_box_new(orientation, spacing)!
        addClasses(box, classes)
        return box
    }

    public static func hbox(spacing: Int32 = 0, classes: [String] = []) -> WidgetPtr {
        box(GTK_ORIENTATION_HORIZONTAL, spacing: spacing, classes: classes)
    }

    public static func vbox(spacing: Int32 = 0, classes: [String] = []) -> WidgetPtr {
        box(GTK_ORIENTATION_VERTICAL, spacing: spacing, classes: classes)
    }

    public static func append(_ box: WidgetPtr, _ child: WidgetPtr) {
        gtk_box_append(cast(box), child)
    }

    public static func remove(_ box: WidgetPtr, _ child: WidgetPtr) {
        gtk_box_remove(cast(box), child)
    }

    public static func removeAllChildren(_ box: WidgetPtr) {
        while let child = gtk_widget_get_first_child(box) {
            gtk_box_remove(cast(box), child)
        }
    }

    public static func label(_ text: String, classes: [String] = [], xalign: Float = 0, ellipsize: Bool = true) -> WidgetPtr {
        let label = gtk_label_new(text)!
        gtk_label_set_xalign(cast(label), xalign)
        if ellipsize {
            gtk_label_set_ellipsize(cast(label), PANGO_ELLIPSIZE_END)
        }
        addClasses(label, classes)
        return label
    }

    public static func setLabel(_ label: WidgetPtr, _ text: String) {
        gtk_label_set_text(cast(label), text)
    }

    public static func iconButton(_ iconName: String, tooltip: String? = nil, action: String? = nil, classes: [String] = ["flat"]) -> WidgetPtr {
        let button = gtk_button_new_from_icon_name(iconName)!
        if let tooltip { gtk_widget_set_tooltip_text(button, tooltip) }
        if let action { gtk_actionable_set_action_name(cast(button), action) }
        addClasses(button, classes)
        return button
    }

    public static func button(_ title: String, action: String? = nil, classes: [String] = []) -> WidgetPtr {
        let button = gtk_button_new_with_label(title)!
        if let action { gtk_actionable_set_action_name(cast(button), action) }
        addClasses(button, classes)
        return button
    }

    public static func image(_ iconName: String, pixelSize: Int32 = 16, classes: [String] = []) -> WidgetPtr {
        let image = gtk_image_new_from_icon_name(iconName)!
        gtk_image_set_pixel_size(cast(image), pixelSize)
        addClasses(image, classes)
        return image
    }

    public static func addClasses(_ widget: WidgetPtr, _ classes: [String]) {
        for name in classes { gtk_widget_add_css_class(widget, name) }
    }

    public static func setClass(_ widget: WidgetPtr, _ name: String, _ enabled: Bool) {
        if enabled {
            gtk_widget_add_css_class(widget, name)
        } else {
            gtk_widget_remove_css_class(widget, name)
        }
    }

    public static func hasClass(_ widget: WidgetPtr, _ name: String) -> Bool {
        gtk_widget_has_css_class(widget, name).bool
    }

    public static func expand(_ widget: WidgetPtr, h: Bool = true, v: Bool = true) {
        gtk_widget_set_hexpand(widget, h.gboolean)
        gtk_widget_set_vexpand(widget, v.gboolean)
    }

    public static func margins(_ widget: WidgetPtr, _ all: Int32) {
        margins(widget, top: all, bottom: all, start: all, end: all)
    }

    public static func margins(_ widget: WidgetPtr, top: Int32 = 0, bottom: Int32 = 0, start: Int32 = 0, end: Int32 = 0) {
        gtk_widget_set_margin_top(widget, top)
        gtk_widget_set_margin_bottom(widget, bottom)
        gtk_widget_set_margin_start(widget, start)
        gtk_widget_set_margin_end(widget, end)
    }

    public static func setVisible(_ widget: WidgetPtr, _ visible: Bool) {
        if gtk_widget_get_visible(widget).bool != visible {
            gtk_widget_set_visible(widget, visible.gboolean)
        }
    }

    /// Removes `widget` from whatever container holds it. Handles the
    /// containers the frontend reparents between.
    public static func detachFromParent(_ widget: WidgetPtr) {
        guard let parent = gtk_widget_get_parent(widget) else { return }
        if isInstance(parent, of: gtk_paned_get_type()) {
            let paned: OpaquePointer = cast(parent)
            if gtk_paned_get_start_child(paned) == widget {
                gtk_paned_set_start_child(paned, nil)
            } else if gtk_paned_get_end_child(paned) == widget {
                gtk_paned_set_end_child(paned, nil)
            }
        } else if isInstance(parent, of: adw_bin_get_type()) {
            adw_bin_set_child(cast(parent), nil)
        } else if isInstance(parent, of: gtk_box_get_type()) {
            gtk_box_remove(cast(parent), widget)
        } else if isInstance(parent, of: gtk_stack_get_type()) {
            gtk_stack_remove(cast(parent), widget)
        } else {
            gtk_widget_unparent(widget)
        }
    }

    public static func children(_ widget: WidgetPtr) -> [WidgetPtr] {
        var result: [WidgetPtr] = []
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            result.append(current)
            child = gtk_widget_get_next_sibling(current)
        }
        return result
    }

    /// Depth-first search for a descendant by widget name (`gtk_widget_set_name`).
    public static func find(named name: String, in root: WidgetPtr) -> WidgetPtr? {
        if let current = gtk_widget_get_name(root), String(cString: current) == name { return root }
        for child in children(root) {
            if let found = find(named: name, in: child) { return found }
        }
        return nil
    }

    public static func setName(_ widget: WidgetPtr, _ name: String) {
        gtk_widget_set_name(widget, name)
    }

    public static func cursor(_ widget: WidgetPtr, _ name: String) {
        gtk_widget_set_cursor_from_name(widget, name)
    }
}
