import CGtk
import CoreState
import Foundation

/// What the WebKitGTK panels need from the rest of the app. The default
/// implementation (`StoreWebPanelServices`) works on any `LinuxStoreBinding`
/// with plain reducer actions; once the app-logic layer is attached,
/// `hooks` route the same calls through `LinuxAppLogic` (the shared
/// `WebPanelRuntimeRegistry`, `AppURLRouter`, `ScratchpadDocumentStore`).
@MainActor
public protocol WebPanelServices: AnyObject {
    var state: AppState { get }
    @discardableResult func send(_ action: AppAction) -> Bool

    /// Page title / URL observed in a panel (persists `currentURL`).
    func webPanelMetadataDidChange(panelID: UUID, title: String?, url: String?)
    /// The user clicked or tabbed into a panel's page.
    func webPanelDidRequestFocus(panelID: UUID)
    /// A link the panel will not navigate in place (Ctrl/middle click,
    /// `target=_blank`, non-web schemes, Scratchpad links). Returns whether
    /// it was routed.
    @discardableResult func openSecondaryURL(_ url: URL, fromPanelID panelID: UUID) -> Bool
    /// Opens with the desktop's default handler.
    @discardableResult func openExternally(_ url: URL, parent: WidgetPtr?) -> Bool
    func copyToClipboard(_ text: String)
    /// Stored Scratchpad document for a panel.
    func scratchpadDocument(documentID: UUID) throws -> ScratchpadDocumentRecord?
    /// Runs a `LinuxCommandTable` command in the window that hosts `widget`.
    func runCommand(_ commandID: String, from widget: WidgetPtr)
}

/// App-logic overrides for `StoreWebPanelServices`. Each returns `nil` (or
/// false) to fall back to the store-only behavior.
@MainActor
public struct WebPanelServiceHooks {
    public var metadataDidChange: ((UUID, String?, String?) -> Bool)?
    public var didRequestFocus: ((UUID) -> Bool)?
    public var openSecondaryURL: ((URL, UUID) -> Bool)?
    public var scratchpadDocument: ((UUID) -> ScratchpadDocumentRecord?)?
    /// Panel lifecycle, so app-logic runtimes can attach the live panel
    /// (`LinuxAppLogic.attachBrowserHost` and friends).
    public var panelDidAttach: ((UUID, WebPanelController) -> Void)?
    public var panelWillDetach: ((UUID, WebPanelController) -> Void)?

    public init() {}
}

@MainActor
public final class StoreWebPanelServices: WebPanelServices {
    public let store: any LinuxStoreBinding
    public var hooks = WebPanelServiceHooks()
    private let runtimePaths: ToasttyRuntimePaths

    public init(store: any LinuxStoreBinding, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.store = store
        runtimePaths = ToasttyRuntimePaths.resolve(environment: environment)
    }

    public var state: AppState { store.state }

    @discardableResult
    public func send(_ action: AppAction) -> Bool { store.send(action) }

    public func webPanelMetadataDidChange(panelID: UUID, title: String?, url: String?) {
        if hooks.metadataDidChange?(panelID, title, url) == true { return }
        store.send(.updateWebPanelMetadata(panelID: panelID, title: title, url: url))
    }

    public func webPanelDidRequestFocus(panelID: UUID) {
        if hooks.didRequestFocus?(panelID) == true { return }
        let state = store.state
        for (workspaceID, workspace) in state.workspacesByID {
            if let tab = workspace.rightAuxPanel.tabID(containingPanelID: panelID) {
                _ = tab
                if workspace.rightAuxPanel.focusedPanelID != panelID {
                    store.send(.focusRightAuxPanel(workspaceID: workspaceID, panelID: panelID))
                }
                return
            }
            if workspace.selectedTab?.panels[panelID] != nil {
                if workspace.focusedPanelID != panelID || workspace.rightAuxPanel.focusedPanelID != nil {
                    store.send(.focusPanel(workspaceID: workspaceID, panelID: panelID))
                }
                return
            }
        }
    }

    @discardableResult
    public func openSecondaryURL(_ url: URL, fromPanelID panelID: UUID) -> Bool {
        if let hook = hooks.openSecondaryURL { return hook(url, panelID) }
        guard let workspaceID = store.state.workspaceSelection(containingPanelID: panelID)?.workspaceID
            ?? store.state.selectedWorkspaceSelection()?.workspaceID else { return false }
        switch LinuxSecondaryURLTarget.resolve(url) {
        case .browser(let urlString):
            return store.send(.createWebPanel(
                workspaceID: workspaceID,
                panel: WebPanelState(definition: .browser, initialURL: urlString),
                placement: .rightPanel
            ))
        case .localDocument(let filePath, let format):
            return store.send(.createWebPanel(
                workspaceID: workspaceID,
                panel: WebPanelState(definition: .localDocument, localDocument: LocalDocumentState(filePath: filePath, format: format)),
                placement: .rightPanel
            ))
        case .external(let url):
            return openExternally(url, parent: nil)
        }
    }

    @discardableResult
    public func openExternally(_ url: URL, parent: WidgetPtr?) -> Bool {
        DesktopLauncher.open(url, parent: parent)
    }

    public func copyToClipboard(_ text: String) {
        DesktopLauncher.copyToClipboard(text)
    }

    public func scratchpadDocument(documentID: UUID) throws -> ScratchpadDocumentRecord? {
        if let hook = hooks.scratchpadDocument { return hook(documentID) }
        return try ScratchpadDocumentRecord.loadFromDisk(
            documentID: documentID,
            directory: runtimePaths.scratchpadDocumentsDirectoryURL
        )
    }

    public func runCommand(_ commandID: String, from widget: WidgetPtr) {
        _ = gtk_widget_activate_action_variant(widget, "win.\(commandID)", nil)
    }
}

/// Desktop helpers shared by the panels: default-app launching, clipboard,
/// toasts from any widget.
@MainActor
public enum DesktopLauncher {
    /// Launches `url` with the desktop's handler (`GtkFileLauncher` for
    /// files, `GtkUriLauncher` otherwise; both go through the portal when
    /// sandboxed).
    @discardableResult
    public static func open(_ url: URL, parent: WidgetPtr?) -> Bool {
        let window: UnsafeMutablePointer<GtkWindow>? = parent.flatMap { gtk_widget_get_root($0) }.map { cast($0) }
        if url.isFileURL {
            let file = g_file_new_for_path(url.path)!
            let launcher = gtk_file_launcher_new(file)!
            gtk_file_launcher_launch(launcher, window, nil, nil, nil)
            g_object_unref(UnsafeMutableRawPointer(launcher))
            g_object_unref(UnsafeMutableRawPointer(file))
        } else {
            let launcher = gtk_uri_launcher_new(url.absoluteString)!
            gtk_uri_launcher_launch(launcher, window, nil, nil, nil)
            g_object_unref(UnsafeMutableRawPointer(launcher))
        }
        return true
    }

    public static func copyToClipboard(_ text: String) {
        guard let display = gdk_display_get_default(), let clipboard = gdk_display_get_clipboard(display) else { return }
        gdk_clipboard_set_text(clipboard, text)
    }

    /// Shows an `AdwToast` in the window that contains `widget`.
    public static func toast(_ message: String, from widget: WidgetPtr?, buttonLabel: String? = nil, action: String? = nil) {
        guard let widget, let overlay = ancestor(of: widget, type: adw_toast_overlay_get_type()) else { return }
        let toast = adw_toast_new(message)!
        adw_toast_set_timeout(toast, 4)
        if let buttonLabel, let action {
            adw_toast_set_button_label(toast, buttonLabel)
            adw_toast_set_action_name(toast, action)
        }
        adw_toast_overlay_add_toast(cast(overlay), toast)
    }

    static func ancestor(of widget: WidgetPtr, type: GType) -> WidgetPtr? {
        var current: WidgetPtr? = widget
        while let node = current {
            if isInstance(node, of: type) { return node }
            current = gtk_widget_get_parent(node)
        }
        // The overlay is the window's content; reach it from the root too.
        if let root = gtk_widget_get_root(widget), isInstance(root, of: adw_application_window_get_type()),
           let content = adw_application_window_get_content(cast(root)), isInstance(content, of: type) {
            return content
        }
        return nil
    }
}

/// Locates the generated web panel bundles (`Sources/App/Resources/WebPanels`
/// in a checkout, `<prefix>/share/toastty/Resources/WebPanels` when
/// installed), with the same search order as `LinuxAppLogic`.
public enum WebPanelResources {
    public static func resourcesDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fileManager = FileManager.default
        func usable(_ path: String) -> URL? {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        if let explicit = environment["TOASTTY_APP_RESOURCES_PATH"], let url = usable(explicit) { return url }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath().deletingLastPathComponent()
        let exeFromProc = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe"))
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        for directory in [exeFromProc, executable].compactMap({ $0 }) {
            for candidate in ["../share/toastty/Resources", "Resources"] {
                if let url = usable(directory.appendingPathComponent(candidate).path) { return url }
            }
            var current = directory
            for _ in 0..<6 {
                current = current.deletingLastPathComponent()
                if fileManager.fileExists(atPath: current.appendingPathComponent("linux/Package.swift").path),
                   let url = usable(current.appendingPathComponent("Sources/App/Resources").path) {
                    return url
                }
            }
        }
        if let root = environment["TOASTTY_DEV_WORKTREE_ROOT"], let url = usable("\(root)/Sources/App/Resources") { return url }
        return nil
    }

    /// `toastty://<host>/` → bundle directory.
    public static func pageDirectories(resources: URL?) -> [String: URL] {
        guard let base = resources?.appendingPathComponent("WebPanels") else { return [:] }
        return [
            "getting-started": base.appendingPathComponent("getting-started-panel"),
            "local-document": base.appendingPathComponent("local-document-panel"),
            "scratchpad": base.appendingPathComponent("scratchpad-panel"),
        ]
    }
}
