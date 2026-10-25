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
final class CoordinatorChatWebView: NSView, CoordinatorChatController.Page {
    static let messageHandlerName = "toasttyCoordinatorChat"
    static let pageURL = URL(string: "toastty://coordinator/")!

    private weak var controller: CoordinatorChatController?
    let webView: WKWebView
    private var isPageReady = false
    private var pendingPayload: Data?

    init(controller: CoordinatorChatController) {
        self.controller = controller
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(ToasttyPageSchemeHandler(), forURLScheme: "toastty")
        let userContent = WKUserContentController()
        configuration.userContentController = userContent
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        super.init(frame: .zero)
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

    func run(_ script: String) async -> Bool {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: (result as? Bool) == true)
            }
        }
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
            let body = message.body
            MainActor.assumeIsolated { view?.handle(body) }
        }
    }
}
