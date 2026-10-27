import AppKit
import SwiftUI
import WebKit

/// The coordinator chat over the coordinator workspace's terminal. It
/// hosts the `toastty://coordinator/` page; the page renders the state the
/// controller pushes and sends its actions back.
struct CoordinatorChatView: NSViewRepresentable {
    let controller: CoordinatorChatController

    func makeNSView(context: Context) -> CoordinatorChatWebView {
        CoordinatorChatWebView(controller: controller)
    }

    func updateNSView(_ view: CoordinatorChatWebView, context: Context) {}

    static func dismantleNSView(_ view: CoordinatorChatWebView, coordinator: ()) {
        view.detach()
    }
}

@MainActor
final class CoordinatorChatWebView: NSView, CoordinatorChatController.Page, NSPopoverDelegate, WKNavigationDelegate {
    static let messageHandlerName = "toasttyCoordinatorChat"
    static let pageURL = URL(string: "toastty://coordinator/")!

    private weak var controller: CoordinatorChatController?
    let webView: WKWebView
    private var isPageReady = false
    private var pendingPayload: Data?
    private var setupPopover: NSPopover?
    private var isTaskMenuPending = false

    init(controller: CoordinatorChatController) {
        self.controller = controller
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(ToasttyPageSchemeHandler(), forURLScheme: "toastty")
        let userContent = WKUserContentController()
        configuration.userContentController = userContent
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        super.init(frame: .zero)
        webView.navigationDelegate = self
        userContent.add(MessageProxy(view: self), name: Self.messageHandlerName)
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        webView.load(URLRequest(url: Self.pageURL))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func detach() {
        setupPopover?.performClose(nil)
        controller?.detach(self)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
    }

    func receive(_ payload: Data) {
        guard isPageReady else {
            pendingPayload = payload
            return
        }
        guard let json = String(data: payload, encoding: .utf8) else { return }
        // The payload is JSON, so it is a valid JavaScript expression.
        webView.evaluateJavaScript("window.toasttyCoordinatorChat && window.toasttyCoordinatorChat.receive(\(json))")
    }

    func takeKeyboardFocus() {
        // A workspace keeps its other tabs mounted; only the page on screen
        // takes the keyboard.
        guard let window, window.firstResponder !== webView,
              isHiddenOrHasHiddenAncestor == false, visibleRect.isEmpty == false else { return }
        window.makeFirstResponder(webView)
    }

    func showSetup(taskID: UUID, coordinator: TaskCoordinator) -> Bool {
        guard window != nil, isHiddenOrHasHiddenAncestor == false else { return false }
        setupPopover?.performClose(nil)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        let host = NSHostingController(rootView:
            TaskSetupCard(taskID: taskID, records: coordinator.records, coordinator: coordinator) { [weak popover] in
                popover?.performClose(nil)
            }
            .setupPopoverChrome()
        )
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        setupPopover = popover
        // The page can refresh and move the row between groups. Use the
        // stable page as the anchor; Start and Retry dismiss the card.
        popover.show(relativeTo: NSRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1), of: self, preferredEdge: .maxX)
        return popover.isShown
    }

    /// Uses the same native task menu and action guard as the sidebar.
    func showTaskMenu(sections: [[TaskBoardPresentation.MenuItem]], rect: CGRect, run: @escaping (TaskBoardPresentation.MenuItem) -> Void) -> Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        guard !isTaskMenuPending else { return true }
        let offered = sections.filter { !$0.isEmpty }
        guard !offered.isEmpty else { return false }
        let scale = CGFloat(webView.pageZoom) * webView.magnification
        let scaled = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        let pageRect = webView.isFlipped ? scaled : CGRect(x: scaled.minX, y: webView.bounds.height - scaled.maxY, width: scaled.width, height: scaled.height)
        let anchor = pageRect.intersection(webView.bounds)
        guard !anchor.isNull, !anchor.isEmpty else { return false }
        let point = NSPoint(x: anchor.minX, y: webView.isFlipped ? anchor.maxY : anchor.minY)
        // Finish the WebKit bridge callback before AppKit enters its menu
        // tracking loop. A menu action can remove this page from its window.
        isTaskMenuPending = true
        // The main-actor action owns all non-Sendable UI state. The queue
        // captures only that actor-isolated object, across SDK versions.
        let presentation = TaskMenuAction { [weak self] in
            guard let self else { return }
            defer { self.isTaskMenuPending = false }
            let webView = self.webView
            guard webView.window != nil, !self.isHiddenOrHasHiddenAncestor else { return }
            let menu = NSMenu()
            for (index, section) in offered.enumerated() {
                if index > 0 { menu.addItem(.separator()) }
                for item in section {
                    let action = TaskMenuAction { run(item) }
                    let native = NSMenuItem(title: item.title, action: #selector(TaskMenuAction.invoke), keyEquivalent: "")
                    native.target = action
                    // NSMenuItem.target is weak; representedObject owns it
                    // for the whole menu lifetime without a nested closure.
                    native.representedObject = action
                    if item.isDestructive {
                        native.attributedTitle = NSAttributedString(string: item.title, attributes: [.foregroundColor: NSColor.systemRed])
                    }
                    menu.addItem(native)
                }
            }
            menu.popUp(positioning: nil, at: point, in: webView)
        }
        DispatchQueue.main.async { presentation.invoke() }
        return true
    }

    @MainActor
    private final class TaskMenuAction: NSObject {
        let run: @MainActor () -> Void
        init(run: @escaping @MainActor () -> Void) { self.run = run }
        @objc func invoke() { run() }
    }

    func popoverDidClose(_ notification: Notification) {
        if notification.object as? NSPopover === setupPopover { setupPopover = nil }
    }

    func run(_ script: String) async -> Bool {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: (result as? Bool) == true)
            }
        }
    }

    /// The chat is one page. Its links open in the right panel through the
    /// bridge, so anything else that would load here, such as a dropped file
    /// or a link's context menu, must not replace the chat.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(Self.isChatPage(navigationAction.request.url) ? .allow : .cancel)
    }

    static func isChatPage(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == pageURL.scheme && url.host == pageURL.host && url.path == pageURL.path && url.query == nil
    }

    fileprivate func handle(_ body: Any) {
        guard let event = CoordinatorChatPageEvent(body: body) else { return }
        if event == .ready {
            isPageReady = true
            if let pendingPayload {
                self.pendingPayload = nil
                receive(pendingPayload)
            }
        }
        guard let controller else { return }
        let token = ((body as? [String: Any])?["token"] as? NSNumber)?.intValue
        Task { await controller.handle(event, token: token, from: self) }
    }

    /// The chat covers a terminal that may hold keyboard focus; typing goes
    /// to the chat once it shows.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.webView)
            self.webView.evaluateJavaScript("document.querySelector('#composer textarea')?.focus()")
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(webView) ?? false
    }

    /// The message handler holds the view weakly, so the page does not keep
    /// the view alive.
    private final class MessageProxy: NSObject, WKScriptMessageHandler {
        weak var view: CoordinatorChatWebView?

        init(view: CoordinatorChatWebView) {
            self.view = view
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            // Only the chat page itself acts through the bridge.
            let frame = message.frameInfo
            let body = message.body
            MainActor.assumeIsolated {
                let page = CoordinatorChatWebView.pageURL
                guard frame.isMainFrame, frame.securityOrigin.protocol == page.scheme,
                      frame.securityOrigin.host == page.host else { return }
                view?.handle(body)
            }
        }
    }
}
