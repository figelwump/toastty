import CGtk
import CoreState
import Foundation

/// Supplies the content widget for main-layout panels. The frontend wraps
/// it in a panel frame (header, focus ring) and moves it between
/// `GtkPaned`s as the split tree changes, so a host must return the *same*
/// widget for a panel ID for as long as the panel exists, and must keep its
/// own strong reference (`GObjectRef`) to it.
@MainActor
public protocol PanelContentHosting: AnyObject {
    /// Content widget for `panelID`, created on first request.
    func contentWidget(for panelID: UUID, panel: PanelState, workspaceID: UUID, windowID: UUID) -> WidgetPtr
    /// Called when panel state changes (title, cwd, URL) without a rebuild.
    func update(panelID: UUID, panel: PanelState)
    /// Moves keyboard focus into the panel's content.
    func focus(panelID: UUID)
    /// The panel left state; release its widget and runtime.
    func close(panelID: UUID)
    /// Panel-scoped commands from `LinuxCommandTable` (`find.*`,
    /// `browser.*`, `local-document.*`, `terminal.copy`/`paste`). Return
    /// false when the panel does not handle `commandID`.
    func perform(commandID: String, panelID: UUID) -> Bool
    /// Asks before closing a panel with unsaved work (a local-document
    /// draft) or a running process (a terminal). Returns true when the host
    /// took over: it calls `proceed` once the user confirms. False means
    /// close right away.
    func confirmClose(panelID: UUID, parent: WidgetPtr, proceed: @escaping @MainActor () -> Void) -> Bool
}

extension PanelContentHosting {
    public func confirmClose(panelID: UUID, parent: WidgetPtr, proceed: @escaping @MainActor () -> Void) -> Bool { false }
}

/// Terminal panels. The Ghostty-backed implementation (terminal-integration
/// workstream) wraps `ToasttyGhosttySurface`; until then
/// `PlaceholderTerminalHost` draws a styled stand-in.
@MainActor
public protocol TerminalPanelHosting: PanelContentHosting {
    /// Effective font size for every terminal in a window.
    func setFontSize(points: Double, windowID: UUID)
}

/// Right-panel tabs (browser, local document, Scratchpad, diff). The
/// WebKitGTK implementation (`WebPanelHost`, UI/RightPanel) belongs to the
/// panels-remote workstream.
@MainActor
public protocol RightPanelContentHosting: PanelContentHosting {
    /// Live tab decoration (favicon, loading spinner) for a panel's tab.
    func tabDecoration(panelID: UUID) -> PanelTabDecoration?
    /// `handler` runs when a panel's decoration changes.
    func observeTabDecorations(_ handler: @escaping @MainActor (UUID) -> Void)
}

extension RightPanelContentHosting {
    public func tabDecoration(panelID: UUID) -> PanelTabDecoration? { nil }
    public func observeTabDecorations(_ handler: @escaping @MainActor (UUID) -> Void) {}
}

/// Favicon and loading state shown on a right-panel tab.
public struct PanelTabDecoration: Equatable {
    /// A `GIcon` (a favicon `GdkTexture`), borrowed: valid until the next change.
    public var icon: OpaquePointer?
    public var isLoading: Bool

    public init(icon: OpaquePointer? = nil, isLoading: Bool = false) {
        self.icon = icon
        self.isLoading = isLoading
    }
}

/// Window-level commands a workstream implements outside the reducer
/// (file dialogs, the Remote Access window). Consulted before
/// `CommandRouter`; return true when handled.
@MainActor
public protocol WindowCommandHandling: AnyObject {
    func perform(commandID: String, windowID: UUID, window: WidgetPtr) -> Bool
}

/// Routes each panel to the host for its kind.
@MainActor
public final class PanelHostRegistry {
    public var terminal: any TerminalPanelHosting
    public var web: any PanelContentHosting
    public var rightPanel: any RightPanelContentHosting

    /// Window commands handled outside `CommandRouter` (see `WindowCommandHandling`).
    public var windowCommandHandlers: [any WindowCommandHandling] = []

    private var hostByPanelID: [UUID: any PanelContentHosting] = [:]

    public func performWindowCommand(_ commandID: String, windowID: UUID, window: WidgetPtr) -> Bool {
        windowCommandHandlers.contains { $0.perform(commandID: commandID, windowID: windowID, window: window) }
    }

    public init(
        terminal: any TerminalPanelHosting = PlaceholderTerminalHost(),
        web: any PanelContentHosting = PlaceholderWebHost(),
        rightPanel: any RightPanelContentHosting = PlaceholderWebHost()
    ) {
        self.terminal = terminal
        self.web = web
        self.rightPanel = rightPanel
    }

    public func host(for panel: PanelState) -> any PanelContentHosting {
        switch panel {
        case .terminal: return terminal
        case .web: return web
        }
    }

    public func contentWidget(for panelID: UUID, panel: PanelState, workspaceID: UUID, windowID: UUID, inRightPanel: Bool = false) -> WidgetPtr {
        let host: any PanelContentHosting = inRightPanel ? rightPanel : self.host(for: panel)
        hostByPanelID[panelID] = host
        return host.contentWidget(for: panelID, panel: panel, workspaceID: workspaceID, windowID: windowID)
    }

    public func update(panelID: UUID, panel: PanelState) {
        hostByPanelID[panelID]?.update(panelID: panelID, panel: panel)
    }

    public func focus(panelID: UUID) {
        hostByPanelID[panelID]?.focus(panelID: panelID)
    }

    public func close(panelID: UUID) {
        hostByPanelID.removeValue(forKey: panelID)?.close(panelID: panelID)
    }

    public func perform(commandID: String, panelID: UUID) -> Bool {
        hostByPanelID[panelID]?.perform(commandID: commandID, panelID: panelID) ?? false
    }

    /// Closes `panelID` through `close` after its host's confirmation, if any
    /// (terminal with a running process, unsaved document draft).
    public func requestClose(panelID: UUID, parent: WidgetPtr, close: @escaping @MainActor () -> Void) {
        if hostByPanelID[panelID]?.confirmClose(panelID: panelID, parent: parent, proceed: close) == true { return }
        close()
    }

    public var livePanelIDs: Set<UUID> { Set(hostByPanelID.keys) }
}

// MARK: - Placeholders

/// Styled stand-in for a Ghostty surface: a focusable monospace box that
/// shows the panel's cwd and title, so layout, focus and zoom can be
/// exercised before the terminal widget lands.
@MainActor
public final class PlaceholderTerminalHost: TerminalPanelHosting {
    private struct Entry {
        let root: GObjectRef
        let cwdLabel: WidgetPtr
        let titleLabel: WidgetPtr
    }

    private var entries: [UUID: Entry] = [:]
    public private(set) var fontPointsByWindow: [UUID: Double] = [:]
    public private(set) var performedCommands: [(String, UUID)] = []

    public init() {}

    public func contentWidget(for panelID: UUID, panel: PanelState, workspaceID: UUID, windowID: UUID) -> WidgetPtr {
        if let entry = entries[panelID] { return entry.root.widgetPointer }

        let root = Gtk.vbox(spacing: 4, classes: ["terminal-placeholder", "panel-content"])
        Gtk.expand(root)
        gtk_widget_set_focusable(root, 1)
        gtk_widget_set_focus_on_click(root, 1)

        let promptLine = Gtk.hbox(spacing: 6)
        let cwdLabel = Gtk.label("", classes: ["prompt"], ellipsize: false)
        Gtk.append(promptLine, cwdLabel)
        Gtk.append(promptLine, Gtk.label("❯", ellipsize: false))
        let cursor = Gtk.box(GTK_ORIENTATION_HORIZONTAL, classes: ["cursor"])
        gtk_widget_set_valign(cursor, GTK_ALIGN_CENTER)
        Gtk.append(promptLine, cursor)
        Gtk.append(root, promptLine)

        let titleLabel = Gtk.label("", classes: ["note"])
        Gtk.append(root, titleLabel)

        let entry = Entry(root: GObjectRef(sinking: root), cwdLabel: cwdLabel, titleLabel: titleLabel)
        entries[panelID] = entry
        update(panelID: panelID, panel: panel)
        return root
    }

    public func update(panelID: UUID, panel: PanelState) {
        guard let entry = entries[panelID], case .terminal(let terminal) = panel else { return }
        let home = NSHomeDirectory()
        var cwd = terminal.cwd
        if cwd.hasPrefix(home) { cwd = "~" + cwd.dropFirst(home.count) }
        Gtk.setLabel(entry.cwdLabel, cwd.isEmpty ? "~" : cwd)
        Gtk.setLabel(entry.titleLabel, "Ghostty terminal placeholder · \(terminal.title)")
    }

    public func focus(panelID: UUID) {
        guard let entry = entries[panelID] else { return }
        gtk_widget_grab_focus(entry.root.widgetPointer)
    }

    public func close(panelID: UUID) {
        guard let entry = entries.removeValue(forKey: panelID) else { return }
        Gtk.detachFromParent(entry.root.widgetPointer)
    }

    public func perform(commandID: String, panelID: UUID) -> Bool {
        performedCommands.append((commandID, panelID))
        return commandID.hasPrefix("find.") || commandID.hasPrefix("terminal.")
    }

    public func setFontSize(points: Double, windowID: UUID) {
        fontPointsByWindow[windowID] = points
    }
}

/// Stand-in for WebKitGTK browser, local-document and Scratchpad panels.
@MainActor
public final class PlaceholderWebHost: RightPanelContentHosting {
    private var roots: [UUID: GObjectRef] = [:]
    private var pages: [UUID: OpaquePointer] = [:]

    public init() {}

    public func contentWidget(for panelID: UUID, panel: PanelState, workspaceID: UUID, windowID: UUID) -> WidgetPtr {
        if let root = roots[panelID] { return root.widgetPointer }
        let page = adw_status_page_new()!
        Gtk.addClasses(page, ["compact", "panel-content"])
        Gtk.expand(page)
        gtk_widget_set_focusable(page, 1)
        roots[panelID] = GObjectRef(sinking: page)
        pages[panelID] = cast(page)
        update(panelID: panelID, panel: panel)
        return page
    }

    public func update(panelID: UUID, panel: PanelState) {
        guard let page = pages[panelID], case .web(let web) = panel else { return }
        let icon: String
        let description: String
        switch web.definition {
        case .browser:
            icon = "web-browser-symbolic"
            description = web.restorableURL ?? "WebKitGTK browser lands with the right-panel workstream."
        case .localDocument:
            icon = "text-x-generic-symbolic"
            description = web.localDocument?.filePath ?? "Local document"
        case .scratchpad:
            icon = "applications-graphics-symbolic"
            description = "Scratchpad"
        case .diff:
            icon = "document-edit-symbolic"
            description = "Diff"
        }
        adw_status_page_set_icon_name(page, icon)
        adw_status_page_set_title(page, web.title)
        adw_status_page_set_description(page, description)
    }

    public func focus(panelID: UUID) {
        guard let root = roots[panelID] else { return }
        gtk_widget_grab_focus(root.widgetPointer)
    }

    public func close(panelID: UUID) {
        pages.removeValue(forKey: panelID)
        guard let root = roots.removeValue(forKey: panelID) else { return }
        Gtk.detachFromParent(root.widgetPointer)
    }

    public func perform(commandID: String, panelID: UUID) -> Bool { false }
}
