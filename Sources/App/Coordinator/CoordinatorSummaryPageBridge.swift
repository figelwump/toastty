import AppKit
import CoreState
import SwiftUI
import WebKit

extension WebPanelState {
    /// These shipped pages provide their own navigation. Reports and normal
    /// browser pages retain the browser controls.
    var isCoordinatorSummary: Bool {
        definition == .browser && CoordinatorSummaryPageBridge.isSummaryURL(restorableURL.flatMap(URL.init(string:)))
    }

    var usesCoordinatorSummaryChrome: Bool {
        isCoordinatorSummary && CoordinatorSummaryPageBridge.isSummaryURL(initialURL.flatMap(URL.init(string:)))
    }
}

/// Gives only the bundled summary documents the chat controller's live
/// state and task actions. A committed report cannot gain this bridge by
/// changing its URL with history.pushState.
@MainActor
final class CoordinatorSummaryPageBridge: NSObject, CoordinatorChatController.Page, WKScriptMessageHandler, NSPopoverDelegate {
    private weak var webView: WKWebView?
    private weak var controller: CoordinatorChatController?
    private var committedSummary = false
    private var isNavigating = false
    private var isReady = false
    private var generation = 0
    private var setupPopover: NSPopover?

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        webView.configuration.userContentController.add(self, name: CoordinatorChatWebView.messageHandlerName)
    }

    nonisolated static func isSummaryURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "toastty" && url.host == "coordinator" && url.user == nil && url.password == nil
            && url.port == nil && ["/today", "/tasks"].contains(url.path(percentEncoded: true)) && url.query == nil
    }

    nonisolated static func accepts(_ event: CoordinatorChatPageEvent, isSummary: Bool) -> Bool {
        switch event {
        case .ready: true
        case .rendered(_, let view, _), .activate(let view, _): isSummary == (view != .chat)
        case .taskAction, .showView: isSummary
        case .projectFilter, .send, .reply, .ask, .merge, .openTaskSpace, .openURL, .openReport, .openRouting, .openTerminal: !isSummary
        }
    }

    var windowID: UUID? { (webView?.window?.identifier?.rawValue).flatMap(UUID.init(uuidString:)) }
    var isSummary: Bool { true }
    private var isLive: Bool { committedSummary && !isNavigating && isReady && Self.isSummaryURL(webView?.url) }

    func navigationStarted() {
        generation += 1
        isNavigating = true
        controller?.detach(self)
        setupPopover?.performClose(nil)
    }

    func navigationCommitted(_ url: URL?, isCurrent: Bool) {
        generation += 1
        committedSummary = isCurrent && Self.isSummaryURL(url)
        isNavigating = false
        isReady = false
        controller?.detach(self)
    }

    func navigationFailed() {
        isNavigating = false
        if committedSummary && isReady && Self.isSummaryURL(webView?.url) { controller?.attach(self) }
    }

    func detach() {
        generation += 1
        controller?.detach(self)
        committedSummary = false
        isReady = false
        setupPopover?.performClose(nil)
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard committedSummary, !isNavigating, let webView, message.webView === webView,
              Self.isSummaryURL(webView.url), Self.isSummaryURL(message.frameInfo.request.url),
              message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "toastty",
              message.frameInfo.securityOrigin.host == "coordinator",
              let event = CoordinatorChatPageEvent(body: message.body), Self.accepts(event, isSummary: true) else { return }
        if event == .ready {
            isReady = true
            controller = CoordinatorChatController.shared
        }
        guard isReady, let controller else { return }
        let generation = generation
        // No token-bearing sends are allowed from the summary.
        Task {
            guard self.generation == generation, self.isLive, self.controller === controller else { return }
            await controller.handle(event, from: self)
        }
    }

    func receive(_ payload: Data) {
        guard isLive,
              let json = String(data: payload, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.toasttyCoordinatorChat && window.toasttyCoordinatorChat.receive(\(json))")
    }

    func run(_ script: String) async -> Bool {
        guard isLive, let webView else { return false }
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in continuation.resume(returning: (result as? Bool) == true) }
        }
    }

    func inspection() async -> [String: AutomationJSONValue] {
        guard isLive, let webView else { return [:] }
        return await CoordinatorPageInspection.read(webView)
    }

    func takeKeyboardFocus() {
        guard isLive, let webView, let window = webView.window, !webView.isHiddenOrHasHiddenAncestor, !webView.visibleRect.isEmpty else { return }
        window.makeFirstResponder(webView)
        webView.evaluateJavaScript("document.getElementById('dashboard')?.focus()")
    }

    func showSetup(taskID: UUID, coordinator: TaskCoordinator) -> Bool {
        guard let webView, webView.window != nil, !webView.isHiddenOrHasHiddenAncestor else { return false }
        setupPopover?.performClose(nil)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        let host = NSHostingController(rootView:
            TaskSetupCard(taskID: taskID, records: coordinator.records, coordinator: coordinator) { [weak popover] in
                popover?.performClose(nil)
            }.setupPopoverChrome()
        )
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        setupPopover = popover
        // Anchor to the stable page, just as the center chat did. Rows can
        // move during setup while the native controls stay open.
        popover.show(relativeTo: NSRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 1, height: 1), of: webView, preferredEdge: .minX)
        return popover.isShown
    }

    func popoverDidClose(_ notification: Notification) {
        if notification.object as? NSPopover === setupPopover { setupPopover = nil }
    }
}

/// Fixed DOM reads for automation, with no caller-supplied JavaScript.
@MainActor
enum CoordinatorPageInspection {
    static func read(_ webView: WKWebView) async -> [String: AutomationJSONValue] {
        let script = #"""
        (() => {
          const shown = e => !!e && !e.closest('.hidden') && e.getClientRects().length > 0;
          const ids = selector => [...document.querySelectorAll(selector)].filter(shown).map(e => e.dataset.rowId || e.dataset.id || e.dataset.item);
          const tab = document.querySelector('[data-view].on');
          const count = group => Number(document.querySelector('#today-stat-' + group + ' .n')?.textContent || 0);
          const confirmation = document.querySelector('.task-row .confirm');
          return JSON.stringify({
            url: location.href,
            documentToken: performance.timeOrigin,
            documentHasFocus: document.hasFocus(),
            viewportWidth: window.innerWidth,
            projectFilterVisible: shown(document.querySelector('.chead .pfilter')),
            focusedElementID: document.activeElement?.id || null,
            view: document.body.dataset.view || (document.getElementById('composer') ? 'chat' : tab?.dataset.view || 'today'),
            headerText: document.getElementById('header')?.textContent || '',
            visibleItemIDs: ids('[data-item]'),
            visibleTaskRowIDs: ids('.task-row, [data-row-id]'),
            todayCounts: {needsYou:count('needsYou'),running:count('running'),toShip:count('toShip')},
            todaySections: {needsYou:ids('#today-needsYou [data-row-id]'),running:ids('#today-running [data-row-id]'),completed:ids('#today-completed [data-row-id]')},
            intakeVisible: shown(document.getElementById('today-intake')),
            confirming: confirmation ? {rowID:confirmation.closest('.task-row').dataset.id,text:confirmation.firstElementChild?.textContent || ''} : null,
            openGroupIDs: [...document.querySelectorAll('[data-act="task-group"][aria-expanded="true"]')].filter(shown).map(e=>e.dataset.group),
            projectFilter: document.body.dataset.projectFilter || null
          });
        })()
        """#
        let json: String? = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in continuation.resume(returning: result as? String) }
        }
        guard let data = json?.data(using: .utf8), let decoded = try? JSONDecoder().decode([String: AutomationJSONValue].self, from: data) else { return [:] }
        return decoded
    }
}
