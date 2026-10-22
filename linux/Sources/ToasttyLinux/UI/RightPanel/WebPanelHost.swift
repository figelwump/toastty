import CGtk
import CWebKitGtk
import CoreState
import Foundation

/// WebKitGTK host for every web panel (right-panel tabs and web panels in
/// splits): browser, local document, Scratchpad, plus window commands that
/// need native UI (Open Local File, Get Started).
///
/// Entry points for other workstreams:
/// - `openURLInRightPanelBrowser(_:workspaceID:)` / `openURL(_:windowID:)`:
///   open a link (terminal link clicks) the Toastty way: web pages in a
///   right-panel browser tab, supported local files in a local-document
///   panel, anything else with the desktop handler.
/// - `controller(for:)`: the live panel (automation, app-logic seams).
@MainActor
public final class WebPanelHost: RightPanelContentHosting, WindowCommandHandling {
    public let services: any WebPanelServices
    public private(set) var controllers: [UUID: WebPanelController] = [:]
    private var decorationObservers: [@MainActor (UUID) -> Void] = []
    private var styleObserver: gulong = 0

    public init(services: any WebPanelServices) {
        self.services = services
        let resources = WebPanelResources.resourcesDirectory()
        // First use creates the shared web context.
        let environment = WebKitRendererSelection.withDMABufRenderer { WebKitEnvironment.shared }
        environment.pageDirectories = WebPanelResources.pageDirectories(resources: resources)
        if resources == nil {
            FileHandle.standardError.write(Data("toastty-linux: web panel resources not found; set TOASTTY_APP_RESOURCES_PATH\n".utf8))
        }
        if let manager = adw_style_manager_get_default() {
            styleObserver = Signal.notify(manager, "dark") { [weak self] in
                guard let self else { return }
                let dark = adw_style_manager_get_dark(manager).bool
                for controller in self.controllers.values { controller.applyTheme(isDark: dark) }
            }
        }
    }

    public convenience init(store: any LinuxStoreBinding) {
        self.init(services: StoreWebPanelServices(store: store))
    }

    public func controller(for panelID: UUID) -> WebPanelController? { controllers[panelID] }

    // MARK: PanelContentHosting

    public func contentWidget(for panelID: UUID, panel: PanelState, workspaceID: UUID, windowID: UUID) -> WidgetPtr {
        if let existing = controllers[panelID] {
            if case .web(let web) = panel { existing.update(web, windowID: windowID) }
            return existing.root
        }
        guard case .web(let web) = panel else {
            // Not a web panel: an empty box keeps the frame valid.
            let box = Gtk.vbox()
            return box
        }
        let controller: WebPanelController
        switch web.definition {
        case .browser:
            controller = BrowserPanelController(panelID: panelID, webState: web, windowID: windowID, services: services)
        case .localDocument:
            controller = LocalDocumentPanelController(panelID: panelID, webState: web, windowID: windowID, services: services)
            if let path = web.localDocument?.filePath { Self.addRecentFile(path) }
        case .scratchpad:
            controller = ScratchpadPanelController(panelID: panelID, webState: web, windowID: windowID, services: services)
        case .diff:
            controller = UnsupportedWebPanelController(panelID: panelID, webState: web, windowID: windowID, services: services)
        }
        controller.onDecorationChange = { [weak self] id in
            self?.decorationObservers.forEach { $0(id) }
        }
        controllers[panelID] = controller
        (services as? StoreWebPanelServices)?.hooks.panelDidAttach?(panelID, controller)
        return controller.root
    }

    public func update(panelID: UUID, panel: PanelState) {
        guard let controller = controllers[panelID], case .web(let web) = panel else { return }
        let windowID = services.state.workspaceSelection(containingPanelID: panelID)?.windowID ?? controller.windowID
        if web != controller.webState || windowID != controller.windowID || web.definition == .localDocument {
            controller.update(web, windowID: windowID)
        }
    }

    public func focus(panelID: UUID) {
        controllers[panelID]?.focusContent()
    }

    public func close(panelID: UUID) {
        guard let controller = controllers.removeValue(forKey: panelID) else { return }
        (services as? StoreWebPanelServices)?.hooks.panelWillDetach?(panelID, controller)
        controller.close()
    }

    public func perform(commandID: String, panelID: UUID) -> Bool {
        controllers[panelID]?.perform(commandID: commandID) ?? false
    }

    // MARK: RightPanelContentHosting

    public func tabDecoration(panelID: UUID) -> PanelTabDecoration? {
        controllers[panelID]?.decoration
    }

    public func observeTabDecorations(_ handler: @escaping @MainActor (UUID) -> Void) {
        decorationObservers.append(handler)
    }

    public func confirmClose(panelID: UUID, parent: WidgetPtr, proceed: @escaping @MainActor () -> Void) -> Bool {
        guard let message = controllers[panelID]?.closeConfirmationMessage else { return false }
        Dialogs.confirm(parent: gtk_widget_get_root(parent).map { widget($0) } ?? parent, heading: message.heading, body: message.body, confirmLabel: "_Discard") {
            proceed()
        }
        return true
    }

    // MARK: WindowCommandHandling

    public func perform(commandID: String, windowID: UUID, window: WidgetPtr) -> Bool {
        switch commandID {
        case "local-document.open", "local-document.open-tab", "local-document.open-split":
            let placement: WebPanelPlacement = commandID.hasSuffix("tab") ? .newTab : commandID.hasSuffix("split") ? .splitRight : .rightPanel
            LocalDocumentOpenDialog.present(parent: window, initialDirectory: focusedTerminalDirectory(windowID: windowID)) { [weak self] path in
                self?.openLocalDocument(path: path, windowID: windowID, placement: placement)
            }
            return true
        case "help.getting-started":
            guard let workspaceID = services.state.workspaceSelection(in: windowID)?.workspaceID else { return true }
            openGettingStarted(workspaceID: workspaceID)
            return true
        default:
            return false
        }
    }

    /// The focused terminal's working directory (the open dialog starts there).
    func focusedTerminalDirectory(windowID: UUID) -> String? {
        guard let workspace = services.state.workspaceSelection(in: windowID)?.workspace,
              let tab = workspace.selectedTab, let panelID = tab.resolvedFocusedPanelID,
              case .terminal(let terminal)? = tab.panels[panelID], terminal.cwd.isEmpty == false else { return nil }
        return (terminal.cwd as NSString).expandingTildeInPath
    }

    // MARK: Entry points

    /// Opens a local file in a local-document panel.
    @discardableResult
    public func openLocalDocument(path: String, windowID: UUID, placement: WebPanelPlacement = .rightPanel) -> Bool {
        guard let workspaceID = services.state.workspaceSelection(in: windowID)?.workspaceID else { return false }
        let format = LocalDocumentClassifier.format(forFilePath: path) ?? .code
        Self.addRecentFile(path)
        return services.send(.createWebPanel(
            workspaceID: workspaceID,
            panel: WebPanelState(definition: .localDocument, localDocument: LocalDocumentState(filePath: path, format: format)),
            placement: placement
        ))
    }

    /// Opens `url` in a new right-panel browser tab of `workspaceID`.
    @discardableResult
    public func openURLInRightPanelBrowser(_ url: String, workspaceID: UUID) -> Bool {
        services.send(.createWebPanel(
            workspaceID: workspaceID,
            panel: WebPanelState(definition: .browser, initialURL: url),
            placement: .rightPanel
        ))
    }

    /// Routes a link the Toastty way (see `LinuxSecondaryURLTarget`) in the
    /// selected workspace of `windowID`. Terminal link clicks call this.
    @discardableResult
    public func openURL(_ url: URL, windowID: UUID?) -> Bool {
        let state = services.state
        let resolvedWindow = windowID ?? state.selectedWindowID ?? state.windows.first?.id
        guard let resolvedWindow, let workspaceID = state.workspaceSelection(in: resolvedWindow)?.workspaceID else {
            return services.openExternally(url, parent: nil)
        }
        switch LinuxSecondaryURLTarget.resolve(url) {
        case .browser(let value):
            return openURLInRightPanelBrowser(value, workspaceID: workspaceID)
        case .localDocument(let path, let format):
            Self.addRecentFile(path)
            return services.send(.createWebPanel(
                workspaceID: workspaceID,
                panel: WebPanelState(definition: .localDocument, localDocument: LocalDocumentState(filePath: path, format: format)),
                placement: .rightPanel
            ))
        case .external(let url):
            return services.openExternally(url, parent: nil)
        }
    }

    /// Shows the Getting Started page, reusing an open one.
    public func openGettingStarted(workspaceID: UUID) {
        guard let workspace = services.state.workspacesByID[workspaceID] else { return }
        if let tab = workspace.rightAuxPanel.orderedTabs.first(where: { tab in
            guard case .web(let web) = tab.panelState, web.definition == .browser else { return false }
            return (web.currentURL ?? web.initialURL)?.hasPrefix(BrowserLinkRouting.gettingStartedURL) == true
        }) {
            services.send(.selectRightAuxPanelTab(workspaceID: workspaceID, tabID: tab.id, focus: true))
            return
        }
        services.send(.createWebPanel(
            workspaceID: workspaceID,
            panel: WebPanelState(definition: .browser, title: "Get Started", initialURL: BrowserLinkRouting.gettingStartedURL),
            placement: .rightPanel
        ))
    }

    /// Adds a file to GTK's recent files (shown in the open dialog's Recent
    /// list and the desktop's recent documents).
    static func addRecentFile(_ path: String) {
        guard let manager = gtk_recent_manager_get_default() else { return }
        let uri = URL(fileURLWithPath: path).absoluteString
        _ = gtk_recent_manager_add_item(manager, uri)
    }
}

extension LinuxAppController {
    /// Installs the WebKitGTK panel host for right-panel tabs and web
    /// panels in splits. Call before `run`.
    @discardableResult
    public func installWebPanels() -> WebPanelHost {
        if let existing = hosts.rightPanel as? WebPanelHost { return existing }
        let host = WebPanelHost(store: store)
        hosts.web = host
        hosts.rightPanel = host
        hosts.windowCommandHandlers.append(host)
        WebPanelAutomation.install(host: host)
        installDesktopAutomation()
        return host
    }

    public var webPanelHost: WebPanelHost? { hosts.rightPanel as? WebPanelHost }
}
