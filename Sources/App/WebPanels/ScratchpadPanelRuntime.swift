import AppKit
import CoreState
import Foundation
import WebKit

enum ScratchpadPanelAssetLocator {
    private static let directory = "WebPanels/scratchpad-panel"
    private static let fileName = "index"
    private static let fileExtension = "html"

    static func entryURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: fileName, withExtension: fileExtension, subdirectory: directory)
    }

    static func directoryURL(bundle: Bundle = .main) -> URL? {
        entryURL(bundle: bundle)?.deletingLastPathComponent()
    }
}

struct ScratchpadPanelRuntimeAutomationState: Equatable, Sendable {
    let lifecycleState: PanelHostLifecycleState
    let currentTheme: ScratchpadPanelTheme
    let hasPendingBootstrapScript: Bool
    let currentAssetPath: String?
    let currentBootstrap: ScratchpadPanelBootstrap?
    let recentDiagnostics: [ScratchpadPanelDiagnostic]
}

struct ScratchpadPanelDiagnostic: Equatable, Sendable {
    let sequence: Int
    let source: String
    let kind: String
    let level: String?
    let message: String
    let metadata: [String: String]
}

@MainActor
final class ScratchpadPanelRuntime: NSObject, ObservableObject, PanelHostLifecycleControlling {
    typealias BridgeScriptCompletion = @MainActor @Sendable (Any?, Error?) -> Void
    typealias BridgeScriptEvaluator = @MainActor (String, @escaping BridgeScriptCompletion) -> Void
    typealias DiagnosticLogger = @MainActor @Sendable (ToasttyLogLevel, String, [String: String]) -> Void

    private static let scriptMessageHandlerName = "toasttyScratchpadPanel"
    private static let maxRecentDiagnostics = 20

    private let panelID: UUID
    private let metadataDidChange: @MainActor (UUID, String?, String?) -> Void
    private let webView: FocusAwareWKWebView
    private let entryURL: URL?
    private let assetDirectoryURL: URL?
    private let documentStore: ScratchpadDocumentStore
    private let bridgeScriptEvaluator: BridgeScriptEvaluator
    private let diagnosticLogger: DiagnosticLogger

    private weak var activeSourceContainer: NSView?
    private var activeAttachment: PanelHostAttachmentToken?
    private var pendingDetachAttachment: PanelHostAttachmentToken?
    private var pendingDetachTask: Task<Void, Never>?
    private var currentWebState: WebPanelState?
    private var currentAssetURL: URL?
    private var currentBootstrap: ScratchpadPanelBootstrap?
    private var pendingBootstrapScript: String?
    private var currentTheme: ScratchpadPanelTheme = .dark
    private var isPanelBridgeReady = false
    private var nextDiagnosticSequence = 0
    private var recentDiagnostics: [ScratchpadPanelDiagnostic] = []

    init(
        panelID: UUID,
        documentStore: ScratchpadDocumentStore,
        metadataDidChange: @escaping @MainActor (UUID, String?, String?) -> Void,
        interactionDidRequestFocus: @escaping @MainActor (UUID) -> Void,
        bundle: Bundle = .main,
        entryURL: URL? = nil,
        bridgeScriptEvaluator: BridgeScriptEvaluator? = nil,
        diagnosticLogger: @escaping DiagnosticLogger = { level, message, metadata in
            switch level {
            case .debug:
                ToasttyLog.debug(message, category: .state, metadata: metadata)
            case .info:
                ToasttyLog.info(message, category: .state, metadata: metadata)
            case .warning:
                ToasttyLog.warning(message, category: .state, metadata: metadata)
            case .error:
                ToasttyLog.error(message, category: .state, metadata: metadata)
            }
        }
    ) {
        self.panelID = panelID
        self.documentStore = documentStore
        self.metadataDidChange = metadataDidChange
        self.entryURL = entryURL ?? ScratchpadPanelAssetLocator.entryURL(bundle: bundle)
        self.assetDirectoryURL = (entryURL ?? ScratchpadPanelAssetLocator.entryURL(bundle: bundle))?.deletingLastPathComponent()
        self.diagnosticLogger = diagnosticLogger

        let configuration = Self.makeWebViewConfiguration(
            for: WebPanelDefinition.scratchpad.capabilityProfile
        )
        let webView = FocusAwareWKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        webView.isInspectable = true
        #endif
        self.webView = webView
        self.bridgeScriptEvaluator = bridgeScriptEvaluator ?? { script, completion in
            webView.evaluateJavaScript(script, completionHandler: completion)
        }

        super.init()

        webView.interactionDidRequestFocus = { [panelID] in
            interactionDidRequestFocus(panelID)
        }
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: Self.scriptMessageHandlerName)
    }

    deinit {
        pendingDetachTask?.cancel()
        let webView = webView
        Task { @MainActor in
            webView.interactionDidRequestFocus = nil
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.scriptMessageHandlerName)
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

    func automationState() -> ScratchpadPanelRuntimeAutomationState {
        ScratchpadPanelRuntimeAutomationState(
            lifecycleState: lifecycleState,
            currentTheme: currentTheme,
            hasPendingBootstrapScript: pendingBootstrapScript != nil,
            currentAssetPath: currentAssetURL?.path,
            currentBootstrap: currentBootstrap,
            recentDiagnostics: recentDiagnostics
        )
    }

    #if DEBUG
    func simulateBridgeReadyForTesting() {
        handleBridgeEvent(.bridgeReady)
    }

    func simulateBridgeMessageForTesting(_ body: [String: Any], isMainFrame: Bool = true) {
        guard isMainFrame,
              let event = BridgeEvent(messageBody: body) else {
            return
        }
        handleBridgeEvent(event)
    }
    #endif

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
        guard let activeAttachment, attachment == activeAttachment else { return }

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
            webState.definition == .scratchpad,
            "ScratchpadPanelRuntime cannot host \(webState.definition.rawValue) panels."
        )

        guard currentWebState != webState else {
            return
        }

        currentWebState = webState
        reloadBootstrap(for: webState)
    }

    @discardableResult
    func focusWebView() -> Bool {
        guard let window = webView.window else {
            return false
        }
        return window.makeFirstResponder(webView)
    }

    func setEffectivelyVisible(_ visible: Bool) {
        let shouldHideWebView = !visible
        guard webView.isHidden != shouldHideWebView else {
            return
        }
        webView.isHidden = shouldHideWebView
    }

    func applyEffectiveAppearance(_ appearance: NSAppearance?) {
        if Self.shouldApplyWebViewAppearance(current: webView.appearance, next: appearance) {
            webView.appearance = appearance
        }

        let nextTheme = Self.theme(for: appearance)
        guard nextTheme != currentTheme else { return }
        currentTheme = nextTheme
        if let currentBootstrap {
            self.currentBootstrap = currentBootstrap.setting(theme: nextTheme)
            pendingBootstrapScript = nil
            pushPendingBootstrapIfPossible()
        }
    }

    nonisolated static func theme(for appearance: NSAppearance?) -> ScratchpadPanelTheme {
        switch appearance?.bestMatch(from: [.darkAqua, .aqua]) {
        case .aqua:
            return .light
        case .darkAqua, nil:
            return .dark
        default:
            return .dark
        }
    }

    nonisolated static func shouldApplyWebViewAppearance(
        current: NSAppearance?,
        next: NSAppearance?
    ) -> Bool {
        current?.name != next?.name
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

    nonisolated static func bootstrapJavaScript(for bootstrap: ScratchpadPanelBootstrap) -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(bootstrap),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return bridgeCommandJavaScript(command: "bridge.receiveBootstrap(\(json));")
    }

    nonisolated static func bridgeCommandJavaScript(command: String) -> String {
        """
        (() => {
            const bridge = window.ToasttyScratchpadPanel;
            if (!bridge) {
                return false;
            }
            \(command)
            return true;
        })();
        """
    }

    nonisolated static func bridgeCommandWasDelivered(_ result: Any?) -> Bool {
        if let result = result as? Bool {
            return result
        }
        if let result = result as? NSNumber {
            return result.boolValue
        }
        return false
    }
}

extension ScratchpadPanelRuntime {
    enum JavaScriptConsoleLevel: String {
        case info
        case warn
        case error
    }

    enum BridgeEvent {
        case bridgeReady
        case consoleMessage(
            level: JavaScriptConsoleLevel,
            message: String,
            diagnosticSource: String
        )
        case javascriptError(
            message: String,
            source: String?,
            line: Int?,
            column: Int?,
            stack: String?,
            diagnosticSource: String
        )
        case unhandledRejection(reason: String, stack: String?, diagnosticSource: String)
        case cspViolation(
            violatedDirective: String,
            effectiveDirective: String,
            blockedURI: String?,
            sourceFile: String?,
            line: Int?,
            column: Int?,
            disposition: String?,
            diagnosticSource: String
        )
        case renderReady(displayName: String, revision: Int?)

        init?(messageBody: Any) {
            guard let body = messageBody as? [String: Any],
                  let type = body["type"] as? String else {
                return nil
            }

            func optionalString(_ key: String) -> String? {
                body[key] as? String
            }

            func optionalInt(_ key: String) -> Int? {
                if let intValue = body[key] as? Int {
                    return intValue
                }
                return (body[key] as? NSNumber)?.intValue
            }

            let diagnosticSource = optionalString("diagnosticSource") ?? "panel"

            switch type {
            case "bridgeReady":
                self = .bridgeReady
            case "consoleMessage":
                guard let rawLevel = body["level"] as? String,
                      let level = JavaScriptConsoleLevel(rawValue: rawLevel),
                      let message = body["message"] as? String else {
                    return nil
                }
                self = .consoleMessage(
                    level: level,
                    message: message,
                    diagnosticSource: diagnosticSource
                )
            case "javascriptError":
                guard let message = body["message"] as? String else {
                    return nil
                }
                self = .javascriptError(
                    message: message,
                    source: optionalString("source"),
                    line: optionalInt("line"),
                    column: optionalInt("column"),
                    stack: optionalString("stack"),
                    diagnosticSource: diagnosticSource
                )
            case "unhandledRejection":
                guard let reason = body["reason"] as? String else {
                    return nil
                }
                self = .unhandledRejection(
                    reason: reason,
                    stack: optionalString("stack"),
                    diagnosticSource: diagnosticSource
                )
            case "cspViolation":
                guard let violatedDirective = body["violatedDirective"] as? String,
                      let effectiveDirective = body["effectiveDirective"] as? String else {
                    return nil
                }
                self = .cspViolation(
                    violatedDirective: violatedDirective,
                    effectiveDirective: effectiveDirective,
                    blockedURI: optionalString("blockedURI"),
                    sourceFile: optionalString("sourceFile"),
                    line: optionalInt("line"),
                    column: optionalInt("column"),
                    disposition: optionalString("disposition"),
                    diagnosticSource: diagnosticSource
                )
            case "renderReady":
                guard let displayName = body["displayName"] as? String else {
                    return nil
                }
                self = .renderReady(displayName: displayName, revision: optionalInt("revision"))
            default:
                return nil
            }
        }
    }

    func reloadBootstrap(for webState: WebPanelState) {
        resetDiagnostics()
        currentBootstrap = Self.bootstrap(
            for: webState,
            documentStore: documentStore,
            theme: currentTheme
        )
        pendingBootstrapScript = nil
        if let currentBootstrap {
            metadataDidChange(panelID, currentBootstrap.displayName, nil)
        }
        pushPendingBootstrapIfPossible()
    }

    static func bootstrap(
        for webState: WebPanelState,
        documentStore: ScratchpadDocumentStore,
        theme: ScratchpadPanelTheme
    ) -> ScratchpadPanelBootstrap {
        guard let scratchpad = webState.scratchpad else {
            return ScratchpadPanelBootstrap(
                documentID: nil,
                displayName: webState.title,
                revision: nil,
                contentHTML: nil,
                missingDocument: true,
                message: "Toastty could not determine which Scratchpad document this panel should render.",
                theme: theme
            )
        }

        do {
            guard let document = try documentStore.load(documentID: scratchpad.documentID) else {
                return ScratchpadPanelBootstrap(
                    documentID: scratchpad.documentID,
                    displayName: webState.title,
                    revision: scratchpad.revision,
                    contentHTML: nil,
                    missingDocument: true,
                    message: "The Scratchpad document is missing from Toastty's document store.",
                    theme: theme
                )
            }

            return ScratchpadPanelBootstrap(
                documentID: document.documentID,
                displayName: document.title ?? webState.title,
                revision: document.revision,
                contentHTML: document.content,
                theme: theme
            )
        } catch {
            return ScratchpadPanelBootstrap(
                documentID: scratchpad.documentID,
                displayName: webState.title,
                revision: scratchpad.revision,
                contentHTML: nil,
                missingDocument: true,
                message: "Toastty could not load this Scratchpad document: \(error.localizedDescription)",
                theme: theme
            )
        }
    }

    func ensurePanelAppLoaded() {
        guard let entryURL, let assetDirectoryURL else {
            let fallbackHTML = Self.fallbackHTML(
                title: "Scratchpad assets unavailable",
                detail: "Toastty could not load the bundled Scratchpad panel resources."
            )
            logDiagnostic(.error, "Scratchpad assets unavailable")
            isPanelBridgeReady = false
            webView.loadHTMLString(fallbackHTML, baseURL: nil)
            currentAssetURL = nil
            return
        }

        if currentAssetURL == entryURL {
            pushPendingBootstrapIfPossible()
            return
        }

        isPanelBridgeReady = false
        currentAssetURL = entryURL
        logDiagnostic(
            .debug,
            "Loading Scratchpad panel app",
            metadata: [
                "entry_path": entryURL.path,
                "read_access_path": assetDirectoryURL.path,
            ]
        )
        webView.loadFileURL(entryURL, allowingReadAccessTo: assetDirectoryURL)
    }

    func pushPendingBootstrapIfPossible() {
        guard let entryURL else {
            ensurePanelAppLoaded()
            return
        }

        if currentAssetURL != entryURL {
            ensurePanelAppLoaded()
            return
        }

        guard isPanelBridgeReady else {
            return
        }

        if pendingBootstrapScript == nil {
            guard let currentBootstrap else { return }
            pendingBootstrapScript = Self.bootstrapJavaScript(for: currentBootstrap)
        }
        guard let pendingBootstrapScript else { return }

        bridgeScriptEvaluator(pendingBootstrapScript) { [weak self] result, error in
            guard let self else { return }
            if error == nil, Self.bridgeCommandWasDelivered(result) {
                self.pendingBootstrapScript = nil
                self.logDiagnostic(.debug, "Delivered Scratchpad bootstrap to page")
                return
            }

            var metadata: [String: String] = [:]
            if let error {
                metadata["error"] = self.clampedDiagnosticValue(error.localizedDescription) ?? "unknown"
            } else {
                metadata["delivery_result"] = String(describing: result)
            }
            self.logDiagnostic(.debug, "Scratchpad bootstrap delivery deferred", metadata: metadata)
        }
    }

    func handleBridgeEvent(_ event: BridgeEvent) {
        switch event {
        case .bridgeReady:
            isPanelBridgeReady = true
            logDiagnostic(.debug, "Scratchpad bridge ready")
            pushPendingBootstrapIfPossible()
        case .consoleMessage(let level, let message, let diagnosticSource):
            let source = normalizedDiagnosticSource(diagnosticSource)
            let metadata = [
                "diagnostic_source": source,
                "console_level": level.rawValue,
                "console_message": clampedDiagnosticValue(message) ?? "<empty>",
            ]
            recordDiagnostic(
                kind: "console-message",
                source: source,
                level: level.rawValue,
                message: message
            )
            switch level {
            case .info:
                logDiagnostic(.info, "Scratchpad JavaScript console info", metadata: metadata)
            case .warn:
                logDiagnostic(.warning, "Scratchpad JavaScript console warning", metadata: metadata)
            case .error:
                logDiagnostic(.error, "Scratchpad JavaScript console error", metadata: metadata)
            }
        case .javascriptError(let message, let scriptSource, let line, let column, let stack, let diagnosticSource):
            let source = normalizedDiagnosticSource(diagnosticSource)
            var metadata = [
                "diagnostic_source": source,
                "javascript_message": clampedDiagnosticValue(message) ?? "<empty>",
            ]
            var diagnosticMetadata: [String: String] = [:]
            if let scriptSource = clampedDiagnosticValue(scriptSource) {
                metadata["javascript_source"] = scriptSource
                diagnosticMetadata["source"] = scriptSource
            }
            if let line {
                metadata["javascript_line"] = String(line)
                diagnosticMetadata["line"] = String(line)
            }
            if let column {
                metadata["javascript_column"] = String(column)
                diagnosticMetadata["column"] = String(column)
            }
            if let stack = clampedDiagnosticValue(stack) {
                metadata["javascript_stack"] = stack
                diagnosticMetadata["stack"] = stack
            }
            recordDiagnostic(
                kind: "javascript-error",
                source: source,
                level: "error",
                message: message,
                metadata: diagnosticMetadata
            )
            logDiagnostic(.error, "Scratchpad JavaScript error", metadata: metadata)
        case .unhandledRejection(let reason, let stack, let diagnosticSource):
            let source = normalizedDiagnosticSource(diagnosticSource)
            var metadata = [
                "diagnostic_source": source,
                "javascript_reason": clampedDiagnosticValue(reason) ?? "<empty>",
            ]
            var diagnosticMetadata: [String: String] = [:]
            if let stack = clampedDiagnosticValue(stack) {
                metadata["javascript_stack"] = stack
                diagnosticMetadata["stack"] = stack
            }
            recordDiagnostic(
                kind: "unhandled-rejection",
                source: source,
                level: "error",
                message: reason,
                metadata: diagnosticMetadata
            )
            logDiagnostic(.error, "Scratchpad JavaScript unhandled rejection", metadata: metadata)
        case .cspViolation(
            let violatedDirective,
            let effectiveDirective,
            let blockedURI,
            let sourceFile,
            let line,
            let column,
            let disposition,
            let diagnosticSource
        ):
            let source = normalizedDiagnosticSource(diagnosticSource)
            let blockedDescription = blockedURI.flatMap { clampedDiagnosticValue($0) } ?? "<inline>"
            let message = "Blocked \(blockedDescription) by \(violatedDirective)"
            var metadata = [
                "diagnostic_source": source,
                "violated_directive": clampedDiagnosticValue(violatedDirective) ?? "<empty>",
                "effective_directive": clampedDiagnosticValue(effectiveDirective) ?? "<empty>",
                "blocked_uri": blockedDescription,
            ]
            var diagnosticMetadata = [
                "violatedDirective": clampedDiagnosticValue(violatedDirective) ?? "<empty>",
                "effectiveDirective": clampedDiagnosticValue(effectiveDirective) ?? "<empty>",
                "blockedURI": blockedDescription,
            ]
            if let sourceFile = clampedDiagnosticValue(sourceFile) {
                metadata["source_file"] = sourceFile
                diagnosticMetadata["sourceFile"] = sourceFile
            }
            if let line {
                metadata["line"] = String(line)
                diagnosticMetadata["line"] = String(line)
            }
            if let column {
                metadata["column"] = String(column)
                diagnosticMetadata["column"] = String(column)
            }
            if let disposition = clampedDiagnosticValue(disposition) {
                metadata["disposition"] = disposition
                diagnosticMetadata["disposition"] = disposition
            }
            recordDiagnostic(
                kind: "csp-violation",
                source: source,
                level: "warn",
                message: message,
                metadata: diagnosticMetadata
            )
            logDiagnostic(.warning, "Scratchpad content security policy violation", metadata: metadata)
        case .renderReady(let displayName, let revision):
            logDiagnostic(
                .debug,
                "Scratchpad render ready",
                metadata: [
                    "render_display_name": clampedDiagnosticValue(displayName) ?? "<empty>",
                    "render_revision": revision.map(String.init) ?? "<none>",
                ]
            )
        }
    }

    func diagnosticMetadata(extra: [String: String] = [:]) -> [String: String] {
        var metadata: [String: String] = [
            "panel_id": panelID.uuidString,
            "host_lifecycle_state": String(describing: lifecycleState),
            "bridge_ready": isPanelBridgeReady ? "true" : "false",
            "has_bootstrap": currentBootstrap != nil ? "true" : "false",
            "has_pending_bootstrap_script": pendingBootstrapScript != nil ? "true" : "false",
        ]

        if let documentID = currentBootstrap?.documentID ?? currentWebState?.scratchpad?.documentID {
            metadata["document_id"] = documentID.uuidString
        }
        if let revision = currentBootstrap?.revision ?? currentWebState?.scratchpad?.revision {
            metadata["revision"] = String(revision)
        }
        if let currentAssetPath = currentAssetURL?.path, currentAssetPath.isEmpty == false {
            metadata["asset_path"] = currentAssetPath
        }

        for (key, value) in extra where value.isEmpty == false {
            metadata[key] = value
        }

        return metadata
    }

    func resetDiagnostics() {
        nextDiagnosticSequence = 0
        recentDiagnostics.removeAll()
    }

    func recordDiagnostic(
        kind: String,
        source: String,
        level: String?,
        message: String,
        metadata: [String: String] = [:]
    ) {
        nextDiagnosticSequence += 1
        let clampedMetadata = metadata.reduce(into: [String: String]()) { result, entry in
            result[entry.key] = clampedDiagnosticValue(entry.value) ?? "<empty>"
        }
        recentDiagnostics.append(
            ScratchpadPanelDiagnostic(
                sequence: nextDiagnosticSequence,
                source: normalizedDiagnosticSource(source),
                kind: kind,
                level: level,
                message: clampedDiagnosticValue(message) ?? "<empty>",
                metadata: clampedMetadata
            )
        )
        if recentDiagnostics.count > Self.maxRecentDiagnostics {
            recentDiagnostics.removeFirst(recentDiagnostics.count - Self.maxRecentDiagnostics)
        }
    }

    func normalizedDiagnosticSource(_ source: String?) -> String {
        clampedDiagnosticValue(source) ?? "panel"
    }

    func logDiagnostic(
        _ level: ToasttyLogLevel,
        _ message: String,
        metadata: [String: String] = [:]
    ) {
        diagnosticLogger(level, message, diagnosticMetadata(extra: metadata))
    }

    func clampedDiagnosticValue(_ value: String?, limit: Int = 2_000) -> String? {
        guard let value, value.isEmpty == false else {
            return nil
        }
        guard value.count > limit else {
            return value
        }
        let endIndex = value.index(value.startIndex, offsetBy: limit - 1)
        return "\(value[..<endIndex])..."
    }

    static func fallbackHTML(title: String, detail: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            html, body { height: 100%; margin: 0; }
            body {
              display: grid;
              place-items: center;
              color: #d7dde8;
              background: #171a21;
              font: 13px -apple-system, BlinkMacSystemFont, sans-serif;
            }
            main { max-width: 460px; padding: 24px; }
            h1 { font-size: 15px; margin: 0 0 8px; }
            p { color: #9aa4b2; line-height: 1.45; margin: 0; }
          </style>
        </head>
        <body><main><h1>\(title)</h1><p>\(detail)</p></main></body>
        </html>
        """
    }
}

extension ScratchpadPanelRuntime: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        logDiagnostic(
            .debug,
            "Scratchpad web view finished navigation",
            metadata: ["navigated_url": webView.url?.absoluteString ?? "<none>"]
        )
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

        if navigationAction.targetFrame?.isMainFrame == false {
            let scheme = requestURL.scheme?.lowercased()
            decisionHandler(scheme == "about" || requestURL.isFileURL ? .allow : .cancel)
            return
        }

        guard requestURL.isFileURL else {
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

extension ScratchpadPanelRuntime: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.scriptMessageHandlerName,
              message.frameInfo.isMainFrame,
              let event = BridgeEvent(messageBody: message.body) else {
            return
        }

        handleBridgeEvent(event)
    }
}
