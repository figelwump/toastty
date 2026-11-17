import CoreState
import Foundation

// MARK: - Browser annotation mode (facade)

extension LinuxAppLogic {
    /// Installs the frontend's screenshot renderer (cairo in the GTK app).
    /// Without one, sends fail with "Couldn't send annotations".
    public static func installAnnotationScreenshotRenderer(_ renderer: LinuxAnnotationScreenshotRendering?) {
        BrowserAnnotatedScreenshotRenderer.renderer = renderer
    }

    /// The annotation controller of a browser panel (created on first use;
    /// lives as long as the panel's runtime).
    public func browserAnnotationController(panelID: UUID) -> LinuxWebPanelAnnotationController {
        let runtime = webPanelRuntimeRegistry.browserRuntime(for: panelID)
        if let controller = runtime.annotationController { return controller }
        let controller = LinuxWebPanelAnnotationController(
            runtime: runtime,
            dependencies: .init(
                candidates: { [weak self] in self?.browserAnnotationSendCandidates(panelID: panelID) ?? [] },
                availability: { [weak self] candidate in
                    self?.browserAnnotationSendAvailability(for: candidate) ?? .blocked(reason: "unavailable")
                },
                sendPayload: { [weak self] payload, candidate in
                    self?.sendBrowserAnnotationPayload(payload, to: candidate) ?? false
                }
            )
        )
        runtime.annotationController = controller
        return controller
    }

    /// A main-frame navigation committed in a browser panel.
    public func browserDidCommitNavigation(panelID: UUID, url: String?) {
        webPanelRuntimeRegistry.browserRuntime(for: panelID).hostDidCommitNavigation(urlString: url)
    }

    /// The browser's URI changed (same-document routes included).
    public func browserDidObserveURL(panelID: UUID, url: String?, isLoading: Bool) {
        webPanelRuntimeRegistry.browserRuntime(for: panelID).handleObservedURLChange(url, isPageLoading: isLoading)
    }

    // MARK: WorkspaceView's annotation send closures

    /// macOS `WorkspaceView.browserScreenshotSendCandidates`: live managed
    /// sessions visible in the browser's workspace tab.
    func browserAnnotationSendCandidates(panelID: UUID) -> [BrowserScreenshotSendCandidate] {
        guard let workspaceID = store.state.workspaceSelection(containingPanelID: panelID)?.workspaceID,
              let workspace = store.state.workspacesByID[workspaceID] else {
            return []
        }
        return BrowserScreenshotSendCandidateBuilder.candidates(
            workspace: workspace,
            browserPanelID: panelID,
            sessionRegistry: sessionRuntimeStore.sessionRegistry
        )
    }

    func browserAnnotationSendAvailability(for candidate: BrowserScreenshotSendCandidate) -> BrowserAnnotationSendAvailability {
        BrowserAnnotationSendGate.availability(
            for: sessionRuntimeStore.sessionRegistry.panelStatus(for: candidate.panelID)?.status.kind
        )
    }

    /// macOS `WorkspaceView.sendBrowserAnnotationPayload`: types the payload
    /// into the agent's terminal, submits it, and focuses that panel.
    func sendBrowserAnnotationPayload(_ payload: String, to candidate: BrowserScreenshotSendCandidate) -> Bool {
        guard browserAnnotationSendAvailability(for: candidate).isAvailable else { return false }
        guard terminalRuntimeRegistry.sendText(payload, submit: true, panelID: candidate.panelID) else { return false }
        if let workspaceID = store.state.workspaceSelection(containingPanelID: candidate.panelID)?.workspaceID {
            _ = store.sendNavigation(.focusPanel(workspaceID: workspaceID, panelID: candidate.panelID))
        }
        return true
    }
}
