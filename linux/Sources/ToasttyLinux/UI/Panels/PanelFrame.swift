import CGtk
import CoreState
import Foundation

/// Display data for one panel frame header.
public struct PanelFramePresentation: Equatable, Sendable {
    public var title: String
    public var subtitle: String?
    public var isFocused: Bool
    public var isUnread: Bool
    public var isZoomed: Bool
    public var isWeb: Bool
    /// More than one panel in the tab: dim unfocused frames slightly.
    public var hasSiblings: Bool

    public static func make(panelID: UUID, panel: PanelState, tab: WorkspaceTabState, plan: SplitLayoutPlan) -> PanelFramePresentation {
        var subtitle: String?
        var isWeb = false
        switch panel {
        case .terminal(let terminal):
            let home = NSHomeDirectory()
            var cwd = terminal.cwd
            if cwd.hasPrefix(home) { cwd = "~" + cwd.dropFirst(home.count) }
            subtitle = (cwd.isEmpty || cwd == panel.notificationLabel) ? nil : cwd
        case .web(let web):
            isWeb = true
            subtitle = web.restorableURL ?? web.localDocument?.filePath
        }
        return PanelFramePresentation(
            title: panel.notificationLabel,
            subtitle: subtitle,
            isFocused: plan.focusedPanelID == panelID,
            isUnread: tab.unreadPanelIDs.contains(panelID),
            isZoomed: plan.isZoomed,
            isWeb: isWeb,
            hasSiblings: tab.layoutTree.allSlotInfos.count > 1
        )
    }
}

/// Rounded card around a panel's content: header (unread dot, title, cwd,
/// zoom and close buttons) and the host-provided content widget. Clicking
/// or tabbing into it focuses the panel in state.
@MainActor
public final class PanelFrame {
    public let panelID: UUID
    public let root: WidgetPtr
    private let rootRef: GObjectRef
    private let titleLabel: WidgetPtr
    private let subtitleLabel: WidgetPtr
    private let unreadDot: WidgetPtr
    private let zoomButton: WidgetPtr
    private var presentation: PanelFramePresentation?

    public var onActivate: (() -> Void)?
    public var onClose: (() -> Void)?
    public var onToggleZoom: (() -> Void)?

    public init(panelID: UUID, content: WidgetPtr) {
        self.panelID = panelID
        root = Gtk.vbox(classes: ["panel-frame"])
        rootRef = GObjectRef(sinking: root)
        gtk_widget_set_overflow(root, GTK_OVERFLOW_HIDDEN)
        Gtk.expand(root)
        Gtk.setName(root, "panel-\(panelID.uuidString)")

        let header = Gtk.hbox(spacing: 6, classes: ["panel-header"])
        unreadDot = Gtk.box(GTK_ORIENTATION_HORIZONTAL, classes: ["unread-dot"])
        gtk_widget_set_valign(unreadDot, GTK_ALIGN_CENTER)
        Gtk.setVisible(unreadDot, false)
        titleLabel = Gtk.label("", classes: ["panel-title"])
        subtitleLabel = Gtk.label("", classes: ["panel-subtitle"])
        gtk_widget_set_hexpand(subtitleLabel, 1)
        gtk_label_set_ellipsize(cast(subtitleLabel), PANGO_ELLIPSIZE_START)
        zoomButton = Gtk.iconButton("view-fullscreen-symbolic", tooltip: "Focus Panel (\(ShortcutLabels.label(forCommand: "panel.focus-mode.toggle") ?? ""))")
        let closeButton = Gtk.iconButton("window-close-symbolic", tooltip: "Close Panel (\(ShortcutLabels.label(forCommand: "panel.close") ?? ""))")
        for child in [unreadDot, titleLabel, subtitleLabel, zoomButton, closeButton] {
            Gtk.append(header, child)
        }
        Gtk.append(root, header)

        Gtk.detachFromParent(content)
        Gtk.expand(content)
        Gtk.append(root, content)

        Signal.connect(zoomButton, "clicked") { [weak self] in self?.onToggleZoom?() }
        Signal.connect(closeButton, "clicked") { [weak self] in self?.onClose?() }

        let click = gtk_gesture_click_new()!
        gtk_event_controller_set_propagation_phase(cast(click), GTK_PHASE_CAPTURE)
        Signal.connectPress(click) { [weak self] _, _, _ in
            guard let self, self.presentation?.isFocused != true else { return }
            self.onActivate?()
        }
        gtk_widget_add_controller(root, cast(click))

        let focus = gtk_event_controller_focus_new()!
        Signal.connect(focus, "enter") { [weak self] in
            guard let self, self.presentation?.isFocused != true else { return }
            self.onActivate?()
        }
        gtk_widget_add_controller(root, focus)
    }

    public func update(_ presentation: PanelFramePresentation) {
        guard presentation != self.presentation else { return }
        self.presentation = presentation
        Gtk.setLabel(titleLabel, presentation.title)
        Gtk.setLabel(subtitleLabel, presentation.subtitle ?? "")
        Gtk.setVisible(unreadDot, presentation.isUnread)
        Gtk.setClass(root, "focused", presentation.isFocused)
        Gtk.setClass(root, "sibling-unfocused", presentation.hasSiblings && presentation.isFocused == false)
        Gtk.setClass(root, "web", presentation.isWeb)
        gtk_button_set_icon_name(cast(zoomButton), presentation.isZoomed ? "view-restore-symbolic" : "view-fullscreen-symbolic")
    }

    public var isFocused: Bool { presentation?.isFocused ?? false }

    /// What the header currently shows (automation and tests).
    public var currentPresentation: PanelFramePresentation? { presentation }
}
