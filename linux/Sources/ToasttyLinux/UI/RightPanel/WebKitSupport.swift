import CGtk
import CGtkShim
import CWebKitGtk
import CWebKitShim
import Foundation

// Swift glue for WebKitGTK 6.0: signal trampolines for WebKit-specific
// signatures, async JavaScript evaluation, the `toastty://` URI scheme,
// and the shared web contexts / network sessions.

private final class WebSignalBox<F>: @unchecked Sendable {
    let handler: F
    init(_ handler: F) { self.handler = handler }
}

private let releaseWebSignalBox: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
    guard let data else { return }
    Unmanaged<AnyObject>.fromOpaque(data).release()
}

@inline(__always)
private func webBox<F>(_ data: gpointer?) -> WebSignalBox<F> {
    Unmanaged<WebSignalBox<F>>.fromOpaque(data!).takeUnretainedValue()
}

typealias PolicyHandler = @MainActor (_ decision: OpaquePointer, _ type: UInt32) -> Bool
typealias CreateHandler = @MainActor (_ navigationAction: OpaquePointer?) -> WidgetPtr?
/// `error` is the GError's domain name (`g_quark_to_string`), code and message.
typealias LoadFailedHandler = @MainActor (_ event: UInt32, _ uri: String?, _ error: WebLoadError?) -> Bool

struct WebLoadError: Equatable {
    let domain: String
    let code: Int
    let message: String

    /// WebKit cancelled the load: superseded by a newer navigation, or stopped.
    var isCancellation: Bool { domain == "WebKitNetworkError" && code == Int(WEBKIT_NETWORK_ERROR_CANCELLED.rawValue) }
}

// WebKitWebView::decide-policy (view, decision, type, data) -> gboolean
private let policyTrampoline: @convention(c) (gpointer?, gpointer?, guint, gpointer?) -> gboolean = { _, decision, type, data in
    let b: WebSignalBox<PolicyHandler> = webBox(data)
    nonisolated(unsafe) let decision = decision
    return MainActor.assumeIsolated { b.handler(OpaquePointer(decision!), type) }.gboolean
}

// WebKitWebView::create (view, navigation_action, data) -> GtkWidget*
private let createTrampoline: @convention(c) (gpointer?, gpointer?, gpointer?) -> gpointer? = { _, action, data in
    let b: WebSignalBox<CreateHandler> = webBox(data)
    nonisolated(unsafe) let action = action
    nonisolated(unsafe) var result: gpointer?
    MainActor.assumeIsolated { result = b.handler(action.map(OpaquePointer.init)).map { UnsafeMutableRawPointer($0) } }
    return result
}

// WebKitWebView::load-failed (view, event, uri, GError*, data) -> gboolean
private let loadFailedTrampoline: @convention(c) (gpointer?, guint, UnsafePointer<CChar>?, UnsafeMutablePointer<GError>?, gpointer?) -> gboolean = {
    _, event, uri, error, data in
    let b: WebSignalBox<LoadFailedHandler> = webBox(data)
    let uriString = uri.map { String(cString: $0) }
    let loadError = error.map { error in
        WebLoadError(
            domain: g_quark_to_string(error.pointee.domain).map { String(cString: $0) } ?? "",
            code: Int(error.pointee.code),
            message: error.pointee.message.map { String(cString: $0) } ?? ""
        )
    }
    return MainActor.assumeIsolated { b.handler(event, uriString, loadError) }.gboolean
}

typealias FileMonitorHandler = @MainActor (_ eventType: UInt32) -> Void

// GFileMonitor::changed (monitor, file, other_file, event_type, data)
private let fileMonitorTrampoline: @convention(c) (gpointer?, gpointer?, gpointer?, guint, gpointer?) -> Void = { _, _, _, event, data in
    let b: WebSignalBox<FileMonitorHandler> = webBox(data)
    MainActor.assumeIsolated { b.handler(event) }
}

@MainActor
enum WebSignal {
    static func fileMonitorChanged(_ monitor: some GPointer, _ handler: @escaping FileMonitorHandler) {
        connect(monitor, "changed", unsafeBitCast(fileMonitorTrampoline, to: UnsafeMutableRawPointer.self), handler)
    }

    private static func connect<F>(_ instance: some GPointer, _ name: String, _ trampoline: UnsafeMutableRawPointer, _ handler: F) {
        let data = Unmanaged.passRetained(WebSignalBox(handler)).toOpaque()
        toastty_signal_connect(instance.rawGPointer, name, trampoline, data, releaseWebSignalBox, 0)
    }

    static func decidePolicy(_ view: some GPointer, _ handler: @escaping PolicyHandler) {
        connect(view, "decide-policy", unsafeBitCast(policyTrampoline, to: UnsafeMutableRawPointer.self), handler)
    }

    static func create(_ view: some GPointer, _ handler: @escaping CreateHandler) {
        connect(view, "create", unsafeBitCast(createTrampoline, to: UnsafeMutableRawPointer.self), handler)
    }

    static func loadFailed(_ view: some GPointer, _ handler: @escaping LoadFailedHandler) {
        connect(view, "load-failed", unsafeBitCast(loadFailedTrampoline, to: UnsafeMutableRawPointer.self), handler)
    }
}

// MARK: - JavaScript

public enum WebJavaScriptError: Error, Equatable, CustomStringConvertible {
    case evaluation(String)
    public var description: String {
        switch self { case .evaluation(let message): return message }
    }
}

private final class JSCallbackBox: @unchecked Sendable {
    let completion: @MainActor (Result<String?, WebJavaScriptError>) -> Void
    init(_ completion: @escaping @MainActor (Result<String?, WebJavaScriptError>) -> Void) { self.completion = completion }
}

private let evaluateCallback: GAsyncReadyCallback = { source, result, data in
    let box = Unmanaged<JSCallbackBox>.fromOpaque(data!).takeRetainedValue()
    var error: UnsafeMutablePointer<GError>?
    let value = webkit_web_view_evaluate_javascript_finish(
        UnsafeMutableRawPointer(source!).assumingMemoryBound(to: WebKitWebView.self), result, &error
    )
    let outcome: Result<String?, WebJavaScriptError>
    if let error {
        outcome = .failure(.evaluation(String(cString: error.pointee.message)))
        g_error_free(error)
    } else if let value {
        if jsc_value_is_undefined(value).bool || jsc_value_is_null(value).bool {
            outcome = .success(nil)
        } else if let json = jsc_value_to_json(value, 0) {
            outcome = .success(String(cString: json))
            g_free(json)
        } else {
            outcome = .success(nil)
        }
        g_object_unref(UnsafeMutableRawPointer(value))
    } else {
        outcome = .success(nil)
    }
    MainActor.assumeIsolated { box.completion(outcome) }
}

@MainActor
enum WebJavaScript {
    /// Evaluates `script` in the page's main world (or `world`); the
    /// completion receives the result serialized as JSON (`nil` for
    /// undefined/null).
    static func evaluate(
        _ view: UnsafeMutablePointer<WebKitWebView>,
        _ script: String,
        world: String? = nil,
        completion: @escaping @MainActor (Result<String?, WebJavaScriptError>) -> Void = { _ in }
    ) {
        let box = Unmanaged.passRetained(JSCallbackBox(completion)).toOpaque()
        webkit_web_view_evaluate_javascript(view, script, -1, world, nil, nil, evaluateCallback, box)
    }

    static func bool(_ json: String?) -> Bool { json == "true" }
}

/// A JSCValue message body serialized to JSON.
func jsonString(fromJSCValue value: UnsafeMutableRawPointer?) -> String? {
    guard let value else { return nil }
    let jsc = OpaquePointer(value)
    if jsc_value_is_string(jsc).bool, let raw = jsc_value_to_string(jsc) {
        defer { g_free(raw) }
        // Keep strings JSON-encoded so callers parse one format.
        let string = String(cString: raw)
        return (try? JSONSerialization.data(withJSONObject: [string], options: [])).flatMap {
            String(data: $0, encoding: .utf8).map { String($0.dropFirst().dropLast()) }
        }
    }
    guard let json = jsc_value_to_json(jsc, 0) else { return nil }
    defer { g_free(json) }
    return String(cString: json)
}

/// The string payload of a JSCValue (`postMessage("…")`).
func stringValue(fromJSCValue value: UnsafeMutableRawPointer?) -> String? {
    guard let value else { return nil }
    let jsc = OpaquePointer(value)
    guard jsc_value_is_string(jsc).bool, let raw = jsc_value_to_string(jsc) else { return nil }
    defer { g_free(raw) }
    return String(cString: raw)
}

// MARK: - Contexts, sessions, toastty:// scheme

/// Process-wide WebKit objects. The browser keeps cookies/storage in a
/// persistent session under `$XDG_DATA_HOME/toastty/webkit` (cache under
/// `$XDG_CACHE_HOME`); local-only panels (documents, Scratchpad) use an
/// ephemeral session, like macOS's `.nonPersistent()` data store.
@MainActor
public final class WebKitEnvironment {
    public static let shared = WebKitEnvironment()

    public let context: OpaquePointer
    public private(set) lazy var browserSession: OpaquePointer = {
        let environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        func base(_ key: String, _ fallback: String) -> String {
            if let value = environment[key], value.hasPrefix("/") { return value }
            return "\(home)/\(fallback)"
        }
        var dataDirectory = "\(base("XDG_DATA_HOME", ".local/share"))/toastty/webkit"
        var cacheDirectory = "\(base("XDG_CACHE_HOME", ".cache"))/toastty/webkit"
        if let runtimeHome = environment["TOASTTY_RUNTIME_HOME"], runtimeHome.hasPrefix("/") {
            // Isolated dev/test runtimes keep their own browser profile.
            dataDirectory = "\(runtimeHome)/webkit/data"
            cacheDirectory = "\(runtimeHome)/webkit/cache"
        }
        if environment["TOASTTY_LINUX_EPHEMERAL_BROWSER"] == "1" {
            return webkit_network_session_new_ephemeral()!
        }
        return webkit_network_session_new(dataDirectory, cacheDirectory)!
    }()

    public private(set) lazy var ephemeralSession: OpaquePointer = webkit_network_session_new_ephemeral()!

    /// `toastty://<host>/` page directories (getting-started, local-document,
    /// scratchpad), set from the resources locator.
    public var pageDirectories: [String: URL] = [:]

    private init() {
        context = webkit_web_context_get_default()!
        webkit_web_context_register_uri_scheme(context, ToasttyPageSchemeRouter.scheme, toasttySchemeCallback, nil, nil)
        if let security = webkit_web_context_get_security_manager(context) {
            webkit_security_manager_register_uri_scheme_as_secure(security, ToasttyPageSchemeRouter.scheme)
            webkit_security_manager_register_uri_scheme_as_cors_enabled(security, ToasttyPageSchemeRouter.scheme)
        }
    }

    fileprivate func respond(to request: OpaquePointer) {
        let uri = webkit_uri_scheme_request_get_uri(request).map { String(cString: $0) } ?? ""
        guard let url = URL(string: uri),
              let resource = ToasttyPageSchemeRouter.resolve(url: url, pageDirectories: pageDirectories),
              let data = try? Data(contentsOf: resource.fileURL, options: .mappedIfSafe) else {
            Self.finish(request, status: 404, mimeType: "text/html",
                        data: Data("<!doctype html><html><head><meta charset=\"utf-8\"><title>Page Not Found</title></head><body><h1>404 Not Found</h1></body></html>".utf8))
            return
        }
        Self.finish(request, status: 200, mimeType: resource.mimeType, data: data)
    }

    private static func finish(_ request: OpaquePointer, status: Int32, mimeType: String, data: Data) {
        let bytes = data.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }!
        let stream = g_memory_input_stream_new_from_bytes(bytes)!
        let response = webkit_uri_scheme_response_new(stream, gint64(data.count))!
        webkit_uri_scheme_response_set_status(response, guint(status), nil)
        webkit_uri_scheme_response_set_content_type(response, mimeType)
        if let headers = soup_message_headers_new(SOUP_MESSAGE_HEADERS_RESPONSE) {
            soup_message_headers_append(headers, "Cache-Control", "no-store")
            soup_message_headers_append(headers, "Content-Type", mimeType)
            webkit_uri_scheme_response_set_http_headers(response, headers)
        }
        webkit_uri_scheme_request_finish_with_response(request, response)
        g_object_unref(UnsafeMutableRawPointer(response))
        g_object_unref(UnsafeMutableRawPointer(stream))
        g_bytes_unref(bytes)
    }

    /// A web view with `settings` in the shared context.
    func makeWebView(
        session: OpaquePointer?,
        contentManager: OpaquePointer?,
        settings: OpaquePointer?
    ) -> WidgetPtr {
        toastty_webkit_web_view_new(cast(context), session.map { cast($0) }, contentManager.map { cast($0) }, settings.map { cast($0) }, nil)
    }

    static func settings(developerExtras: Bool, allowsFileAccess: Bool = false) -> OpaquePointer {
        let settings = webkit_settings_new()!
        webkit_settings_set_enable_developer_extras(settings, developerExtras.gboolean)
        webkit_settings_set_enable_back_forward_navigation_gestures(settings, 1)
        webkit_settings_set_javascript_can_access_clipboard(settings, 0)
        webkit_settings_set_allow_file_access_from_file_urls(settings, allowsFileAccess.gboolean)
        return settings
    }

    static var developerExtrasEnabled: Bool {
        ProcessInfo.processInfo.environment["TOASTTY_LINUX_WEB_INSPECTOR"] == "1"
    }
}

private let toasttySchemeCallback: WebKitURISchemeRequestCallback = { request, _ in
    guard let request else { return }
    nonisolated(unsafe) let pointer = request
    MainActor.assumeIsolated { WebKitEnvironment.shared.respond(to: cast(pointer)) }
}

// MARK: - Textures

/// PNG bytes of a `GdkTexture` (favicons, snapshots).
func pngData(fromTexture texture: OpaquePointer?) -> Data? {
    guard let texture, let bytes = gdk_texture_save_to_png_bytes(texture) else { return nil }
    defer { g_bytes_unref(bytes) }
    var size: gsize = 0
    guard let raw = g_bytes_get_data(bytes, &size) else { return nil }
    return Data(bytes: raw, count: Int(size))
}
