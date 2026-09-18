import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain

struct ToasttyPreviewService: Sendable {
    var content: @Sendable (RemotePreviewTarget) async throws -> RemotePreviewContent = { _ in
        throw RemotePreviewError.unsupported
    }
    var resource: @Sendable (RemoteHTMLResourceRequest) async throws -> RemoteHTMLResourceResponse = { _ in
        throw RemotePreviewError.unsupported
    }
}

private struct ToasttyPreviewServiceKey: EnvironmentKey {
    static let defaultValue = ToasttyPreviewService()
}

extension EnvironmentValues {
    var toasttyPreviewService: ToasttyPreviewService {
        get { self[ToasttyPreviewServiceKey.self] }
        set { self[ToasttyPreviewServiceKey.self] = newValue }
    }
}

struct ToasttyPreviewSelection: Identifiable {
    let id: UUID
    let target: RemotePreviewTarget
    let title: String

    init(target: RemotePreviewTarget, title: String, id: UUID = UUID()) {
        self.id = id
        self.target = target
        self.title = title
    }
}

struct ToasttyPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selection: ToasttyPreviewSelection
    var detents: Set<PresentationDetent> = [.medium, .large]

    var body: some View {
        NavigationStack {
            ToasttyPreviewPage(selection: selection)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                            .accessibilityIdentifier("toastty-preview-close")
                    }
                }
        }
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
    }
}

struct ToasttyPreviewPage: View {
    @Environment(\.toasttyPreviewService) private var service
    let selection: ToasttyPreviewSelection
    @State private var content: RemotePreviewContent?
    @State private var loadedTarget: RemotePreviewTarget?
    @State private var errorMessage: String?
    @State private var attempt = 0
    @State private var fitRequest = 0

    var body: some View {
        ZStack {
            if let content {
                ToasttyPreviewContentView(content: content, target: selection.target,
                                          service: service, fitRequest: fitRequest)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Preview unavailable", systemImage: "doc.badge.ellipsis")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") { attempt += 1 }
                }
            } else {
                ProgressView("Loading preview…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ToasttyDesignTokens.background)
        .navigationTitle(selection.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if case .scratchpad = content {
                    Button("Fit") { fitRequest += 1 }
                        .accessibilityIdentifier("toastty-scratchpad-fit")
                }
            }
        }
        .task(id: "\(selection.id)-\(attempt)") {
            // Returning from a session keeps the already-loaded Scratchpad and
            // its local interactions. Closing and reopening creates a new page.
            guard content == nil || loadedTarget != selection.target else { return }
            content = nil
            errorMessage = nil
            do {
                let loaded = try await service.content(selection.target)
                try Task.checkCancellation()
                content = loaded
                loadedTarget = selection.target
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = Self.message(for: error)
            }
        }
        .accessibilityIdentifier("toastty-preview")
    }

    static func message(for error: Error) -> String {
        if case .operationCompatibility(.missingCapability)? = error as? GatewayFailure {
            return "This preview is not supported by the connected Mac. Update Toastty on your Mac and try again."
        }
        return switch error as? RemotePreviewError {
        case .unsupported: "This file type or panel cannot be previewed on your iPhone."
        case .denied: "This file is outside the workspace files available to your iPhone."
        case .missing: "This content is no longer available on your Mac."
        case .tooLarge: "This file is too large to preview."
        case .stale: "The panel changed on your Mac. Close this preview and open it again."
        case .busy: "Your Mac is busy preparing previews. Try again shortly."
        case nil: "Couldn’t load this preview. Check the connection to your Mac and try again."
        }
    }
}

private struct ToasttyPreviewContentView: View {
    let content: RemotePreviewContent
    let target: RemotePreviewTarget
    let service: ToasttyPreviewService
    let fitRequest: Int

    var body: some View {
        switch content {
        case .document(let document):
            ToasttyBundledPreviewWebView(content: .document(document), fitRequest: fitRequest)
        case .scratchpad(let scratchpad):
            ToasttyBundledPreviewWebView(content: .scratchpad(scratchpad), fitRequest: fitRequest)
        case .html(let html):
            ToasttyHTMLPreviewWebView(document: html, target: target, resource: service.resource)
        case .webURL(let url):
            ToasttyWebURLPreview(url: url)
        }
    }
}

/// Loads a web address in the in-app browser, or explains why an address that
/// only resolves on the Mac cannot load on the phone.
struct ToasttyWebURLPreview: View {
    let url: URL

    var body: some View {
        if ToasttyPreviewURLPolicy.isReachableWebURL(url) {
            ToasttyBrowserPreview(url: url)
        } else {
            ContentUnavailableView("Browser unavailable", systemImage: "network.slash",
                description: Text("This address belongs to your Mac or uses an unsupported scheme. Open it on your Mac."))
        }
    }
}

enum ToasttyPreviewURLPolicy {
    static func isReachableWebURL(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return false }
        return host != "localhost" && !host.hasSuffix(".localhost")
            && host != "::1" && host != "[::1]" && !host.hasPrefix("127.")
            && host != "0.0.0.0"
    }

    /// Only actual link destinations are routed here. Plain transcript prose is never scanned.
    static func localFileReference(_ url: URL) -> String? {
        let scheme = url.scheme?.lowercased()
        if scheme != nil && scheme != "file" {
            // URL parses a bare filename followed by :line as a scheme. This
            // narrow exception applies only to an existing Markdown link.
            let raw = url.absoluteString
            guard raw.range(of: #"^[^\s/:]+\.[A-Za-z0-9]+:[1-9][0-9]*(?::[1-9][0-9]*)?(?:#L[1-9][0-9]*)?$"#,
                            options: .regularExpression) != nil else { return nil }
            return raw
        }
        guard url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
        let reference = scheme == "file" ? url.path : url.relativeString.components(separatedBy: "#")[0]
        guard !reference.isEmpty, !reference.hasPrefix("#") else { return nil }
        let decoded = scheme == "file" ? reference : (reference.removingPercentEncoding ?? reference)
        return decoded + (url.fragment.map { "#" + $0 } ?? "")
    }
}
