import CoreState
import Foundation

// Pure routing rules for the WebKitGTK panels, ported from macOS
// (Sources/App/WebPanels/BrowserLinkRoutingRules.swift,
// BrowserPanelRuntime.normalizedUserEnteredURLString,
// ToasttyPageSchemeHandler.swift) without WebKit/AppKit types so they are
// unit-tested on Linux. The Ctrl key plays macOS's Command role for
// "open link in a new tab"; a middle click does the same.

public enum BrowserNavigationDecision: Equatable, Sendable {
    case allow
    /// Cancel the in-place navigation and hand the URL to Toastty's router
    /// (new right-panel browser tab, local document panel, or the desktop).
    case openSecondary(URL)
    /// A `toastty://action/<name>` link from the trusted Getting Started page.
    case dispatchAction(GettingStartedAction)
    case ignore
}

public enum GettingStartedAction: String, Equatable, Sendable, CaseIterable {
    case openAgentProfiles = "open-agent-profiles"
    case openSkillsManagement = "open-skills-management"
    case openShortcutReference = "open-shortcut-reference"

    /// The Linux command (`LinuxCommandTable` ID) each action runs.
    public var commandID: String {
        switch self {
        case .openAgentProfiles: return "agent.profiles.manage"
        case .openSkillsManagement: return "agent.toastty-skills.manage"
        case .openShortcutReference: return "app.shortcuts"
        }
    }
}

public enum BrowserLinkRouting {
    public static let gettingStartedURL = "toastty://getting-started/"

    /// Navigation-action policy for the browser's main view.
    ///
    /// - `isLinkActivation`: WebKit reports `LINK_CLICKED`.
    /// - `opensNewWindow`: a `target=_blank` / `window.open` request
    ///   (`NEW_WINDOW_ACTION`).
    /// - `ctrlOrMiddleClick`: Ctrl held or middle mouse button.
    public static func decision(
        url: URL?,
        isLinkActivation: Bool,
        opensNewWindow: Bool,
        ctrlOrMiddleClick: Bool,
        sourceFrameURL: URL?,
        sourceIsMainFrame: Bool
    ) -> BrowserNavigationDecision {
        if let url, isToasttyAction(url) {
            guard sourceIsMainFrame, isTrustedGettingStartedPage(sourceFrameURL) else { return .ignore }
            let components = url.pathComponents.filter { $0 != "/" }
            guard components.count == 1, let action = GettingStartedAction(rawValue: components[0]) else { return .ignore }
            return .dispatchAction(action)
        }
        if opensNewWindow {
            guard let target = popupCaptureURL(url) else { return .allow }
            return .openSecondary(target)
        }
        guard isLinkActivation, let url else { return .allow }
        if ctrlOrMiddleClick { return .openSecondary(url) }
        if isNavigableInPlace(url) == false { return .openSecondary(url) }
        return .allow
    }

    /// A popup's first usable URL (`nil`/`about:blank` means "wait for the
    /// popup to navigate").
    public static func popupCaptureURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        let value = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false, value.caseInsensitiveCompare("about:blank") != .orderedSame else { return nil }
        return url
    }

    public static func isNavigableInPlace(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "toastty"
    }

    static func isToasttyAction(_ url: URL) -> Bool {
        url.scheme?.caseInsensitiveCompare("toastty") == .orderedSame
            && url.host?.caseInsensitiveCompare("action") == .orderedSame
    }

    static func isTrustedGettingStartedPage(_ url: URL?) -> Bool {
        guard let url, url.scheme?.caseInsensitiveCompare("toastty") == .orderedSame,
              url.host?.caseInsensitiveCompare("getting-started") == .orderedSame else { return false }
        return url.path.isEmpty || url.path == "/"
    }

    /// Location-bar input → URL string (macOS
    /// `BrowserPanelRuntime.normalizedUserEnteredURLString`): explicit
    /// schemes pass through, local hosts/IPs/ports get `http://`, dotted
    /// hosts get `https://`, and absolute or `~` paths become `file://`.
    public static func normalizedUserEnteredURLString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") || trimmed == "~" {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded).absoluteString
        }
        let lowercased = trimmed.lowercased()
        if trimmed.contains("://") || lowercased.hasPrefix("about:") || lowercased.hasPrefix("data:")
            || lowercased.hasPrefix("file:") || lowercased.hasPrefix("toastty:") {
            return trimmed
        }
        if trimmed.contains(where: \.isWhitespace) { return trimmed }
        let host = hostCandidate(from: trimmed)
        if host.isEmpty { return trimmed }
        if hasNumericPort(host) { return "http://\(trimmed)" }
        if isLocalHost(host) || isIPv4Address(host) || isBracketedIPv6Address(host) { return "http://\(trimmed)" }
        if hasExplicitScheme(trimmed) { return trimmed }
        if host.contains(".") { return "https://\(trimmed)" }
        return trimmed
    }

    private static func hostCandidate(from value: String) -> String {
        let scalars = value.unicodeScalars
        let endIndex = scalars.firstIndex(where: { "/?#".unicodeScalars.contains($0) }) ?? scalars.endIndex
        return String(scalars[..<endIndex])
    }

    private static func hasNumericPort(_ value: String) -> Bool {
        guard let colonIndex = value.lastIndex(of: ":") else { return false }
        let suffix = value[value.index(after: colonIndex)...]
        guard suffix.isEmpty == false else { return false }
        return suffix.allSatisfy(\.isNumber)
    }

    private static func hasExplicitScheme(_ value: String) -> Bool {
        guard let colonIndex = value.firstIndex(of: ":") else { return false }
        let scheme = value[..<colonIndex]
        guard let first = scheme.unicodeScalars.first, CharacterSet.letters.contains(first) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+-."))
        return scheme.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isLocalHost(_ value: String) -> Bool {
        value.caseInsensitiveCompare("localhost") == .orderedSame
    }

    private static func isBracketedIPv6Address(_ value: String) -> Bool {
        value.hasPrefix("[") && value.hasSuffix("]")
    }

    private static func isIPv4Address(_ value: String) -> Bool {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in Int(octet).map { (0...255).contains($0) } ?? false }
    }
}

/// Where a URL handed to Toastty's router should go when the app-logic
/// `AppURLRouter` is not attached: web URLs open a right-panel browser tab,
/// supported local files a local-document panel, everything else the
/// desktop's default handler.
public enum LinuxSecondaryURLTarget: Equatable, Sendable {
    case browser(String)
    case localDocument(filePath: String, format: LocalDocumentFormat)
    case external(URL)

    public static func resolve(_ url: URL) -> LinuxSecondaryURLTarget {
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" || scheme == "toastty" {
            return .browser(url.absoluteString)
        }
        if url.isFileURL {
            let path = url.standardizedFileURL.path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue == false,
               let format = LocalDocumentClassifier.format(forFilePath: path) {
                return .localDocument(filePath: path, format: format)
            }
            if path.lowercased().hasSuffix(".html") || path.lowercased().hasSuffix(".htm") {
                return .browser(url.absoluteString)
            }
        }
        return .external(url)
    }
}

/// `toastty://<page>/<path>` → a file inside a bundled page directory
/// (macOS `ToasttyPageSchemeRouter`), rejecting traversal and paths that
/// resolve outside the page directory.
public enum ToasttyPageSchemeRouter {
    public static let scheme = "toastty"

    public struct Resource: Equatable, Sendable {
        public let fileURL: URL
        public let mimeType: String
    }

    public static func resolve(url: URL, pageDirectories: [String: URL]) -> Resource? {
        guard url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame,
              let host = url.host?.lowercased(),
              let directory = pageDirectories[host] else { return nil }
        let encoded = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var components: [String] = []
        for piece in encoded {
            guard let decoded = piece.removingPercentEncoding,
                  decoded != "..", decoded != ".", decoded.contains("/") == false, decoded.contains("\\") == false else { return nil }
            components.append(decoded)
        }
        if components.isEmpty { components = ["index.html"] }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = components.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path.hasPrefix(rootPath) else { return nil }
        return Resource(fileURL: resolved, mimeType: mimeType(forExtension: resolved.pathExtension))
    }

    public static func mimeType(forExtension pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js", "mjs": return "text/javascript"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "wasm": return "application/wasm"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}
