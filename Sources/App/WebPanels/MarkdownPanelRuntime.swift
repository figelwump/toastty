import AppKit
import CoreState
import Foundation
import WebKit

enum MarkdownPanelAssetLocator {
    private static let directory = "WebPanels/markdown-panel"
    private static let fileName = "index"
    private static let fileExtension = "html"

    static func entryURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: fileName, withExtension: fileExtension, subdirectory: directory)
    }

    static func directoryURL(bundle: Bundle = .main) -> URL? {
        entryURL(bundle: bundle)?.deletingLastPathComponent()
    }
}

struct MarkdownPanelRuntimeAutomationState: Equatable, Sendable {
    let lifecycleState: PanelHostLifecycleState
    let currentTheme: MarkdownPanelTheme
    let hasPendingBootstrapScript: Bool
    let currentAssetPath: String?
    let currentBootstrap: MarkdownPanelBootstrap?
}

@MainActor
final class MarkdownPanelRuntime: NSObject, ObservableObject, PanelHostLifecycleControlling {
    typealias BootstrapProvider = @Sendable (WebPanelState, MarkdownPanelTheme) async -> MarkdownPanelBootstrap

    private let panelID: UUID
    private let metadataDidChange: @MainActor (UUID, String?, String?) -> Void
    private let webView: FocusAwareWKWebView
    private let entryURL: URL?
    private let assetDirectoryURL: URL?
    private let bootstrapProvider: BootstrapProvider
    private let reloadDebounceNanoseconds: UInt64
    private weak var activeSourceContainer: NSView?
    private var activeAttachment: PanelHostAttachmentToken?
    private var pendingDetachAttachment: PanelHostAttachmentToken?
    private var pendingDetachTask: Task<Void, Never>?
    private var currentWebState: WebPanelState?
    private var fileObserver: FilePathObserver?
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration: UInt64 = 0
    private var pendingBootstrapScript: String?
    private var currentAssetURL: URL?
    private var currentBootstrap: MarkdownPanelBootstrap?
    private var currentTheme: MarkdownPanelTheme = .dark

    init(
        panelID: UUID,
        metadataDidChange: @escaping @MainActor (UUID, String?, String?) -> Void,
        interactionDidRequestFocus: @escaping @MainActor (UUID) -> Void,
        bundle: Bundle = .main,
        entryURL: URL? = nil,
        bootstrapProvider: @escaping BootstrapProvider = { await MarkdownPanelRuntime.bootstrap(for: $0, theme: $1) },
        reloadDebounceNanoseconds: UInt64 = 150_000_000
    ) {
        self.panelID = panelID
        self.metadataDidChange = metadataDidChange
        self.entryURL = entryURL ?? MarkdownPanelAssetLocator.entryURL(bundle: bundle)
        self.assetDirectoryURL = (entryURL ?? MarkdownPanelAssetLocator.entryURL(bundle: bundle))?.deletingLastPathComponent()
        self.bootstrapProvider = bootstrapProvider
        self.reloadDebounceNanoseconds = reloadDebounceNanoseconds

        let configuration = Self.makeWebViewConfiguration(
            for: WebPanelDefinition.localDocument.capabilityProfile
        )
        let webView = FocusAwareWKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        self.webView = webView

        super.init()

        webView.interactionDidRequestFocus = { [panelID] in
            interactionDidRequestFocus(panelID)
        }
        webView.navigationDelegate = self
    }

    deinit {
        pendingDetachTask?.cancel()
        reloadTask?.cancel()
        let webView = webView
        Task { @MainActor in
            webView.interactionDidRequestFocus = nil
            webView.navigationDelegate = nil
            webView.removeFromSuperview()
        }
    }

    var lifecycleState: PanelHostLifecycleState {
        guard let activeAttachment else {
            return .detached
        }
        let sourceContainer = activeSourceContainer
        let attachedToContainer = sourceContainer != nil && webView.superview === sourceContainer
        let attachedToWindow = webView.window != nil && sourceContainer?.window != nil
        if pendingDetachAttachment == activeAttachment {
            return .attached(activeAttachment)
        }
        return attachedToContainer && attachedToWindow ? .ready(activeAttachment) : .attached(activeAttachment)
    }

    func automationState() -> MarkdownPanelRuntimeAutomationState {
        MarkdownPanelRuntimeAutomationState(
            lifecycleState: lifecycleState,
            currentTheme: currentTheme,
            hasPendingBootstrapScript: pendingBootstrapScript != nil,
            currentAssetPath: currentAssetURL?.path,
            currentBootstrap: currentBootstrap
        )
    }

    func attachHost(to container: NSView, attachment: PanelHostAttachmentToken) {
        if let activeAttachment, attachment.generation < activeAttachment.generation {
            return
        }

        pendingDetachTask?.cancel()
        pendingDetachTask = nil
        pendingDetachAttachment = nil
        activeAttachment = attachment
        activeSourceContainer = container
        applyEffectiveAppearance(container.effectiveAppearance)

        guard webView.superview !== container else { return }
        container.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    func detachHost(attachment: PanelHostAttachmentToken) {
        guard let activeAttachment else { return }
        guard attachment == activeAttachment else { return }

        pendingDetachTask?.cancel()
        pendingDetachAttachment = attachment
        pendingDetachTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  self.pendingDetachAttachment == attachment,
                  self.activeAttachment == attachment else {
                return
            }
            self.pendingDetachTask = nil
            self.pendingDetachAttachment = nil
            self.activeAttachment = nil
            self.activeSourceContainer = nil
            self.webView.removeFromSuperview()
        }
    }

    func apply(webState: WebPanelState) {
        precondition(
            webState.definition == .localDocument,
            "MarkdownPanelRuntime cannot host \(webState.definition.rawValue) panels."
        )
        let didChangeState = currentWebState != webState
        currentWebState = webState
        synchronizeFileObservation(with: webState.filePath)

        guard didChangeState else { return }
        requestReload(debounced: false)
    }

    func applyEffectiveAppearance(_ appearance: NSAppearance?) {
        webView.appearance = appearance

        let nextTheme = Self.theme(for: appearance)
        guard nextTheme != currentTheme else { return }
        currentTheme = nextTheme
        pushThemeUpdateIfPossible()
    }

    nonisolated static func theme(for appearance: NSAppearance?) -> MarkdownPanelTheme {
        switch appearance?.bestMatch(from: [.darkAqua, .aqua]) {
        case .aqua:
            return .light
        case .darkAqua, nil:
            return .dark
        default:
            return .dark
        }
    }

    nonisolated static func bootstrap(
        for webState: WebPanelState,
        theme: MarkdownPanelTheme = .dark
    ) async -> MarkdownPanelBootstrap {
        precondition(
            webState.definition == .localDocument,
            "MarkdownPanelRuntime cannot host \(webState.definition.rawValue) panels."
        )
        let filePath = webState.filePath ?? ""
        let displayName = resolvedDisplayName(for: webState, filePath: filePath)

        guard filePath.isEmpty == false else {
            return MarkdownPanelBootstrap(
                filePath: filePath,
                displayName: displayName,
                content: missingFileDocument(
                    title: displayName,
                    filePath: nil,
                    message: "Toastty could not determine which markdown file this panel should render."
                ),
                theme: theme
            )
        }

        do {
            let content = try await readMarkdownContent(at: filePath)
            return MarkdownPanelBootstrap(
                filePath: filePath,
                displayName: displayName,
                content: content,
                theme: theme
            )
        } catch {
            return MarkdownPanelBootstrap(
                filePath: filePath,
                displayName: displayName,
                content: missingFileDocument(
                    title: displayName,
                    filePath: filePath,
                    message: error.localizedDescription
                ),
                theme: theme
            )
        }
    }

    nonisolated static func bootstrapJavaScript(for bootstrap: MarkdownPanelBootstrap) -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(bootstrap),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return "window.ToasttyMarkdownPanel?.receiveBootstrap(\(json));"
    }

    static func makeWebViewConfiguration(
        for capabilityProfile: WebPanelCapabilityProfile
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        if capabilityProfile == .localOnly {
            configuration.websiteDataStore = .nonPersistent()
        }
        return configuration
    }
}

private extension MarkdownPanelRuntime {
    func synchronizeFileObservation(with filePath: String?) {
        guard let normalizedFilePath = WebPanelState.normalizedFilePath(filePath) else {
            fileObserver?.invalidate()
            fileObserver = nil
            return
        }

        if let fileObserver {
            fileObserver.update(path: normalizedFilePath)
            return
        }

        fileObserver = FilePathObserver(path: normalizedFilePath) { [weak self] in
            Task { @MainActor [weak self] in
                self?.requestReload(debounced: true)
            }
        }
    }

    func requestReload(debounced: Bool) {
        guard let webState = currentWebState else { return }

        reloadGeneration &+= 1
        let generation = reloadGeneration
        let bootstrapProvider = bootstrapProvider
        let reloadDelayNanoseconds = debounced ? reloadDebounceNanoseconds : 0
        let requestedTheme = currentTheme

        reloadTask?.cancel()
        pendingBootstrapScript = nil

        reloadTask = Task { [weak self] in
            if reloadDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: reloadDelayNanoseconds)
            }

            var bootstrap = await bootstrapProvider(webState, requestedTheme)
            guard let self else { return }
            defer {
                if generation == self.reloadGeneration {
                    self.reloadTask = nil
                }
            }
            guard Task.isCancelled == false, generation == self.reloadGeneration else {
                return
            }

            bootstrap = bootstrap.setting(theme: self.currentTheme)
            self.currentBootstrap = bootstrap
            self.metadataDidChange(self.panelID, bootstrap.displayName, nil)
            guard let script = Self.bootstrapJavaScript(for: bootstrap) else {
                return
            }
            self.pendingBootstrapScript = script
            self.ensurePanelAppLoaded()
        }
    }

    func ensurePanelAppLoaded() {
        guard let entryURL, let assetDirectoryURL else {
            let fallbackHTML = Self.fallbackHTML(
                title: "Markdown assets unavailable",
                detail: "Toastty could not load the bundled markdown panel resources."
            )
            webView.loadHTMLString(fallbackHTML, baseURL: nil)
            currentAssetURL = nil
            return
        }

        if currentAssetURL == entryURL {
            pushPendingBootstrapIfPossible()
            return
        }

        currentAssetURL = entryURL
        webView.loadFileURL(entryURL, allowingReadAccessTo: assetDirectoryURL)
    }

    func pushPendingBootstrapIfPossible() {
        guard let pendingBootstrapScript else { return }
        webView.evaluateJavaScript(pendingBootstrapScript) { [weak self] _, error in
            guard let self else { return }
            if error == nil {
                self.pendingBootstrapScript = nil
            }
        }
    }

    func pushThemeUpdateIfPossible() {
        guard let currentBootstrap else { return }

        let themedBootstrap = currentBootstrap.setting(theme: currentTheme)
        guard themedBootstrap != currentBootstrap else { return }

        self.currentBootstrap = themedBootstrap
        guard let script = Self.bootstrapJavaScript(for: themedBootstrap) else {
            return
        }
        pendingBootstrapScript = script
        ensurePanelAppLoaded()
    }

    nonisolated static func readMarkdownContent(at filePath: String) async throws -> String {
        try await Task.detached(priority: .utility) {
            let fileURL = URL(fileURLWithPath: filePath)
            var encoding = String.Encoding.utf8
            return try String(contentsOf: fileURL, usedEncoding: &encoding)
        }.value
    }

    nonisolated static func resolvedDisplayName(for webState: WebPanelState, filePath: String) -> String {
        if webState.title.isEmpty == false,
           webState.title != webState.definition.defaultTitle {
            return webState.title
        }

        let fileName = URL(fileURLWithPath: filePath).lastPathComponent
        return fileName.isEmpty ? webState.definition.defaultTitle : fileName
    }

    nonisolated static func missingFileDocument(title: String, filePath: String?, message: String) -> String {
        var lines = [
            "# \(title)",
            "",
            "Toastty could not load this markdown file.",
        ]

        if let filePath, filePath.isEmpty == false {
            lines += [
                "",
                "**Path**",
                "",
                "`\(filePath)`",
            ]
        }

        lines += [
            "",
            "**Reason**",
            "",
            message,
        ]

        return lines.joined(separator: "\n")
    }

    nonisolated static func fallbackHTML(title: String, detail: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(title)</title>
          <style>
            body {
              margin: 0;
              min-height: 100vh;
              display: flex;
              align-items: center;
              justify-content: center;
              background: #f8f4ee;
              color: #25180f;
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            }
            main {
              max-width: 32rem;
              padding: 1.5rem;
              border: 1px solid rgba(90, 53, 25, 0.12);
              border-radius: 18px;
              background: rgba(255, 251, 246, 0.95);
            }
            p { line-height: 1.6; color: #6f533a; }
          </style>
        </head>
        <body>
          <main>
            <h1>\(title)</h1>
            <p>\(detail)</p>
          </main>
        </body>
        </html>
        """
    }
}

extension MarkdownPanelRuntime: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushPendingBootstrapIfPossible()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let requestURL = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if requestURL.isFileURL == false {
            decisionHandler(.cancel)
            return
        }

        guard let currentAssetURL else {
            decisionHandler(.allow)
            return
        }

        let requestedPath = requestURL.standardizedFileURL.path
        let currentPath = currentAssetURL.standardizedFileURL.path
        decisionHandler(requestedPath == currentPath ? .allow : .cancel)
    }
}
