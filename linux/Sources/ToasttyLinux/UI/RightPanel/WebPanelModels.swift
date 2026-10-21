import CoreState
import Foundation

// Native ⇄ web-app bridge models for the generated web panel bundles under
// Sources/App/Resources/WebPanels. Field names and message shapes match the
// macOS contract (Sources/App/WebPanels/LocalDocumentPanelBootstrap.swift,
// ScratchpadPanelBootstrap.swift, LocalDocumentPanelModels.swift) and the
// bundles' TypeScript (WebPanels/LocalDocumentApp/src/bootstrap.ts,
// nativeBridge.ts; WebPanels/ScratchpadApp/src/nativeBridge.ts). Those macOS
// types are module-internal to the App layer, so the Linux frontend carries
// its own copy; keep both in step when the contract version changes.

// MARK: - Local document

public enum LocalDocumentPanelTheme: String, Codable, Equatable, Sendable {
    case light
    case dark
}

public enum LocalDocumentHighlightState: String, Codable, Equatable, Sendable {
    case enabled
    case disabledForLargeFile
    case plainText
    case unsupportedFormat
    case unavailable
}

/// `window.ToasttyLocalDocumentPanel.receiveBootstrap(...)` payload
/// (contract version 7).
public struct LocalDocumentPanelBootstrap: Codable, Equatable, Sendable {
    public static let contractVersion = 7
    /// Bytes above which syntax highlighting turns off (macOS
    /// `LocalDocumentPanelRuntime.syntaxHighlightThresholdBytes`).
    public static let syntaxHighlightThresholdBytes = 512 * 1024

    public let contractVersion: Int
    public let filePath: String?
    public let displayName: String
    public let format: LocalDocumentFormat
    public let syntaxLanguage: LocalDocumentSyntaxLanguage?
    public let formatLabel: String
    public let shouldHighlight: Bool
    public let highlightState: LocalDocumentHighlightState
    public let content: String
    public let contentRevision: Int
    public let isEditing: Bool
    public let isDirty: Bool
    public let hasExternalConflict: Bool
    public let isSaving: Bool
    public let saveErrorMessage: String?
    public let theme: LocalDocumentPanelTheme
    public let textScale: Double

    /// Same derivation as macOS `LocalDocumentPanelRuntime.makeBootstrap`.
    public init(session: LocalDocumentEditingSession, theme: LocalDocumentPanelTheme, textScale: Double) {
        let classification = LocalDocumentClassifier.classification(format: session.format, filePath: session.filePath)
        let highlight = Self.highlightState(
            classification: classification,
            content: session.visibleContent,
            hasDiskRevision: session.diskRevision != nil
        )
        contractVersion = Self.contractVersion
        filePath = session.filePath
        displayName = session.displayName
        format = session.format
        syntaxLanguage = classification.syntaxLanguage
        formatLabel = classification.formatLabel
        highlightState = highlight
        shouldHighlight = highlight == .enabled
        content = session.visibleContent
        contentRevision = session.contentRevision
        isEditing = session.isEditing
        isDirty = session.isDirty
        hasExternalConflict = session.hasExternalConflict
        isSaving = session.isSaving
        saveErrorMessage = session.saveErrorMessage
        self.theme = theme
        self.textScale = textScale
    }

    public static func highlightState(
        classification: LocalDocumentClassification,
        content: String,
        hasDiskRevision: Bool
    ) -> LocalDocumentHighlightState {
        guard hasDiskRevision else { return .unavailable }
        if classification.warnsWhenSyntaxHighlightUnavailable == false { return .plainText }
        let supported: Bool
        switch classification.format {
        case .markdown: supported = true
        default: supported = classification.syntaxLanguage != nil
        }
        guard supported else { return .unsupportedFormat }
        if content.utf8.count > syntaxHighlightThresholdBytes { return .disabledForLargeFile }
        return .enabled
    }

    /// The JavaScript that delivers this bootstrap; evaluates to `true` once
    /// the page's bridge exists.
    public func deliveryJavaScript() -> String? {
        guard let data = try? JSONEncoder().encode(self), let json = String(data: data, encoding: .utf8) else { return nil }
        return LocalDocumentBridgeScript.command("bridge.receiveBootstrap(\(json));")
    }
}

public enum LocalDocumentBridgeScript {
    public static func command(_ command: String) -> String {
        """
        (() => {
            const bridge = window.ToasttyLocalDocumentPanel;
            if (!bridge) {
                return false;
            }
            \(command)
            return true;
        })();
        """
    }

    public static func textScale(_ scale: Double) -> String {
        command("bridge.setTextScale(\(String(format: "%.4f", scale)));")
    }

    public static func revealLine(_ line: Int) -> String {
        command("bridge.revealLine(\(line));")
    }

    /// Search command; evaluates to the page's search state (`{query,
    /// matchCount, activeMatchIndex, matchFound}`) or `null`.
    public static func search(_ command: LocalDocumentSearchCommand) -> String {
        let payload: [String: String]
        switch command {
        case .setQuery(let query): payload = ["type": "setQuery", "query": query]
        case .findNext(let query): payload = ["type": "next", "query": query]
        case .findPrevious(let query): payload = ["type": "previous", "query": query]
        case .clear: payload = ["type": "clear"]
        }
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"type\":\"clear\"}"
        return """
        (() => {
          const panel = window.ToasttyLocalDocumentPanel;
          if (!panel?.performSearchCommand) {
            return null;
          }
          return panel.performSearchCommand(\(json));
        })();
        """
    }
}

public enum LocalDocumentSearchCommand: Equatable, Sendable {
    case setQuery(String)
    case findNext(String)
    case findPrevious(String)
    case clear
}

/// Result of a page search command.
public struct LocalDocumentSearchResult: Decodable, Equatable, Sendable {
    public var query: String
    public var matchCount: Int
    public var activeMatchIndex: Int?
    public var matchFound: Bool
}

/// Messages the local-document bundle posts to
/// `window.webkit.messageHandlers.toasttyLocalDocumentPanel`.
public enum LocalDocumentBridgeEvent: Equatable, Sendable {
    public static let handlerName = "toasttyLocalDocumentPanel"

    case bridgeReady
    case consoleMessage(level: String, message: String)
    case javascriptError(message: String, source: String?, line: Int?, column: Int?, stack: String?)
    case unhandledRejection(reason: String, stack: String?)
    case renderReady(displayName: String, contentRevision: Int, isEditing: Bool)
    case searchControllerReady
    case searchControllerUnavailable
    case enterEdit
    case copyFullPath
    case openInDefaultApp
    case draftDidChange(content: String, baseContentRevision: Int)
    case save(baseContentRevision: Int)
    case cancelEdit(baseContentRevision: Int)
    case overwriteAfterConflict(baseContentRevision: Int)

    /// Decodes a message body (the JSON a `JSCValue` serializes to).
    public init?(json: String) {
        guard let data = json.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        self.init(body: body)
    }

    public init?(body: [String: Any]) {
        func string(_ key: String) -> String? { body[key] as? String }
        func int(_ key: String) -> Int? {
            if let value = body[key] as? Int { return value }
            if let value = body[key] as? Double, value.rounded() == value { return Int(value) }
            return nil
        }
        func bool(_ key: String) -> Bool? { body[key] as? Bool }

        switch string("type") {
        case "bridgeReady": self = .bridgeReady
        case "consoleMessage":
            guard let level = string("level"), ["info", "warn", "error"].contains(level) else { return nil }
            self = .consoleMessage(level: level, message: string("message") ?? "")
        case "javascriptError":
            self = .javascriptError(
                message: string("message") ?? "", source: string("source"),
                line: int("line"), column: int("column"), stack: string("stack")
            )
        case "unhandledRejection":
            self = .unhandledRejection(reason: string("reason") ?? "", stack: string("stack"))
        case "renderReady":
            guard let displayName = string("displayName"), let revision = int("contentRevision") else { return nil }
            self = .renderReady(displayName: displayName, contentRevision: revision, isEditing: bool("isEditing") ?? false)
        case "searchControllerReady": self = .searchControllerReady
        case "searchControllerUnavailable": self = .searchControllerUnavailable
        case "enterEdit": self = .enterEdit
        case "copyFullPath": self = .copyFullPath
        case "openInDefaultApp": self = .openInDefaultApp
        case "draftDidChange":
            guard let content = string("content"), let revision = int("baseContentRevision") else { return nil }
            self = .draftDidChange(content: content, baseContentRevision: revision)
        case "save":
            guard let revision = int("baseContentRevision") else { return nil }
            self = .save(baseContentRevision: revision)
        case "cancelEdit":
            guard let revision = int("baseContentRevision") else { return nil }
            self = .cancelEdit(baseContentRevision: revision)
        case "overwriteAfterConflict":
            guard let revision = int("baseContentRevision") else { return nil }
            self = .overwriteAfterConflict(baseContentRevision: revision)
        default:
            return nil
        }
    }
}

public struct LocalDocumentDiskRevision: Equatable, Sendable {
    public var fileNumber: UInt64?
    public var modificationDate: Date?
    public var size: UInt64?

    public init(fileNumber: UInt64?, modificationDate: Date?, size: UInt64?) {
        self.fileNumber = fileNumber
        self.modificationDate = modificationDate
        self.size = size
    }
}

public struct LocalDocumentSnapshot: Equatable, Sendable {
    public var filePath: String?
    public var displayName: String
    public var format: LocalDocumentFormat
    public var content: String
    public var diskRevision: LocalDocumentDiskRevision?

    public init(filePath: String?, displayName: String, format: LocalDocumentFormat, content: String, diskRevision: LocalDocumentDiskRevision?) {
        self.filePath = filePath
        self.displayName = displayName
        self.format = format
        self.content = content
        self.diskRevision = diskRevision
    }

    /// Reads a document from disk; a read failure becomes the macOS
    /// "could not load this document" text with no disk revision.
    public static func load(filePath: String?, displayName: String, format: LocalDocumentFormat) -> LocalDocumentSnapshot {
        guard let filePath else {
            return LocalDocumentSnapshot(
                filePath: nil, displayName: displayName, format: format,
                content: missingFileText(filePath: nil, message: "Toastty could not determine which local document this panel should render."),
                diskRevision: nil
            )
        }
        do {
            var encoding = String.Encoding.utf8
            let content = try String(contentsOfFile: filePath, usedEncoding: &encoding)
            let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
            return LocalDocumentSnapshot(
                filePath: filePath, displayName: displayName, format: format, content: content,
                diskRevision: LocalDocumentDiskRevision(
                    fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                    modificationDate: attributes[.modificationDate] as? Date,
                    size: (attributes[.size] as? NSNumber)?.uint64Value
                )
            )
        } catch {
            return LocalDocumentSnapshot(
                filePath: filePath, displayName: displayName, format: format,
                content: missingFileText(filePath: filePath, message: error.localizedDescription),
                diskRevision: nil
            )
        }
    }

    public static func missingFileText(filePath: String?, message: String) -> String {
        var lines = ["Toastty could not load this document."]
        if let filePath, filePath.isEmpty == false {
            lines += ["", "Path:", filePath]
        }
        lines += ["", "Reason:", message]
        return lines.joined(separator: "\n")
    }

    /// macOS `LocalDocumentPanelRuntime.resolvedDisplayName`.
    public static func displayName(for webState: WebPanelState) -> String {
        if webState.title.isEmpty == false, webState.title != webState.definition.defaultTitle {
            return webState.title
        }
        let name = URL(fileURLWithPath: webState.localDocument?.filePath ?? "").lastPathComponent
        return name.isEmpty ? webState.definition.defaultTitle : name
    }
}

public struct LocalDocumentSaveRequest: Equatable, Sendable {
    public let filePath: String
    public let displayName: String
    public let content: String
    public let baseContentRevision: Int
}

/// The edit/save state machine for one local-document panel. A direct port
/// of macOS `LocalDocumentEditingSession` (LocalDocumentPanelModels.swift).
public struct LocalDocumentEditingSession: Equatable, Sendable {
    public var filePath: String?
    public var displayName: String
    public var format: LocalDocumentFormat
    public var loadedContent: String
    public var draftContent: String
    public var contentRevision: Int
    public var diskRevision: LocalDocumentDiskRevision?
    public var isEditing: Bool
    public var hasExternalConflict: Bool
    public var isSaving: Bool
    public var saveErrorMessage: String?

    public var isDirty: Bool { draftContent != loadedContent }
    public var visibleContent: String { isEditing ? draftContent : loadedContent }

    /// Close confirmation needed for an unsaved draft or a save in flight.
    public var needsCloseConfirmation: Bool { isEditing && (isSaving || isDirty) }

    public var canSave: Bool { filePath != nil && isEditing && isSaving == false && hasExternalConflict == false }
    public var canEnterEdit: Bool { filePath != nil && isEditing == false }
    public var canCancelEdit: Bool { isEditing && isSaving == false }

    public init(document: LocalDocumentSnapshot) {
        filePath = document.filePath
        displayName = document.displayName
        format = document.format
        loadedContent = document.content
        draftContent = document.content
        contentRevision = 1
        diskRevision = document.diskRevision
        isEditing = false
        hasExternalConflict = false
        isSaving = false
        saveErrorMessage = nil
    }

    public mutating func replaceCleanBaseline(with document: LocalDocumentSnapshot) {
        let shouldAdvanceRevision = contentRevision == 0 || filePath != document.filePath
            || format != document.format || loadedContent != document.content
        let shouldReplaceDraft = isEditing == false || isDirty == false
        filePath = document.filePath
        displayName = document.displayName
        format = document.format
        loadedContent = document.content
        diskRevision = document.diskRevision
        hasExternalConflict = false
        isSaving = false
        saveErrorMessage = nil
        if shouldReplaceDraft { draftContent = document.content }
        if shouldAdvanceRevision { contentRevision += 1 }
    }

    @discardableResult
    public mutating func beginEditing() -> Bool {
        guard filePath != nil, isEditing == false else { return false }
        draftContent = loadedContent
        isEditing = true
        saveErrorMessage = nil
        return true
    }

    @discardableResult
    public mutating func updateDraft(_ content: String, baseContentRevision: Int) -> Bool {
        guard isEditing, isSaving == false, baseContentRevision == contentRevision else { return false }
        draftContent = content
        saveErrorMessage = nil
        return true
    }

    @discardableResult
    public mutating func cancelEditing(baseContentRevision: Int) -> Bool {
        guard isEditing, baseContentRevision == contentRevision else { return false }
        draftContent = loadedContent
        isEditing = false
        hasExternalConflict = false
        isSaving = false
        saveErrorMessage = nil
        contentRevision += 1
        return true
    }

    public mutating func beginSave(baseContentRevision: Int, allowConflictOverwrite: Bool) -> LocalDocumentSaveRequest? {
        guard let filePath, isEditing, isSaving == false, baseContentRevision == contentRevision else { return nil }
        guard allowConflictOverwrite ? hasExternalConflict : hasExternalConflict == false else { return nil }
        saveErrorMessage = nil
        isSaving = true
        return LocalDocumentSaveRequest(filePath: filePath, displayName: displayName, content: draftContent, baseContentRevision: baseContentRevision)
    }

    @discardableResult
    public mutating func finishNoOpSave(baseContentRevision: Int) -> Bool {
        guard isEditing, isDirty == false, hasExternalConflict == false, isSaving == false,
              baseContentRevision == contentRevision else { return false }
        isEditing = false
        saveErrorMessage = nil
        contentRevision += 1
        return true
    }

    @discardableResult
    public mutating func settleSave(with document: LocalDocumentSnapshot, expectedContent: String, baseContentRevision: Int) -> Bool {
        guard isSaving, baseContentRevision == contentRevision else { return false }
        let savedContentMatchesDisk = document.content == expectedContent
        filePath = document.filePath
        displayName = document.displayName
        format = document.format
        loadedContent = document.content
        diskRevision = document.diskRevision
        isSaving = false
        saveErrorMessage = nil
        if savedContentMatchesDisk {
            draftContent = document.content
            isEditing = false
            hasExternalConflict = false
            contentRevision += 1
        } else {
            hasExternalConflict = true
        }
        return true
    }

    @discardableResult
    public mutating func failSave(message: String, baseContentRevision: Int) -> Bool {
        guard isSaving, baseContentRevision == contentRevision else { return false }
        isSaving = false
        saveErrorMessage = message
        return true
    }

    public mutating func applyExternalConflict(with document: LocalDocumentSnapshot) {
        filePath = document.filePath
        displayName = document.displayName
        format = document.format
        loadedContent = document.content
        diskRevision = document.diskRevision
        hasExternalConflict = true
        isSaving = false
        saveErrorMessage = nil
    }

    /// A reload from disk: an edited dirty draft whose baseline changed
    /// becomes a conflict, everything else takes the new baseline (macOS
    /// `requestReload`). Returns false when the reload must be dropped (save
    /// in flight).
    @discardableResult
    public mutating func applyReload(_ document: LocalDocumentSnapshot) -> Bool {
        if isSaving { return false }
        let replacedContent = filePath != document.filePath || loadedContent != document.content
        if isEditing, isDirty, replacedContent {
            applyExternalConflict(with: document)
        } else {
            replaceCleanBaseline(with: document)
        }
        return true
    }
}

// MARK: - Scratchpad

public enum ScratchpadPanelTheme: String, Codable, Equatable, Sendable {
    case light
    case dark
}

/// `window.ToasttyScratchpadPanel.receiveBootstrap(...)` payload (contract 1).
public struct ScratchpadPanelBootstrap: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let documentID: UUID?
    public let displayName: String
    public let revision: Int?
    public let contentHTML: String?
    public let missingDocument: Bool
    public let sessionLinked: Bool
    public let message: String?
    public let theme: ScratchpadPanelTheme

    public init(
        documentID: UUID?,
        displayName: String,
        revision: Int?,
        contentHTML: String?,
        missingDocument: Bool = false,
        sessionLinked: Bool = false,
        message: String? = nil,
        theme: ScratchpadPanelTheme
    ) {
        contractVersion = 1
        self.documentID = documentID
        self.displayName = displayName
        self.revision = revision
        self.contentHTML = contentHTML
        self.missingDocument = missingDocument
        self.sessionLinked = sessionLinked
        self.message = message
        self.theme = theme
    }

    /// macOS `ScratchpadPanelRuntime.bootstrap(for:documentStore:theme:)`.
    public static func make(
        webState: WebPanelState,
        theme: ScratchpadPanelTheme,
        load: (UUID) throws -> ScratchpadDocumentRecord?
    ) -> ScratchpadPanelBootstrap {
        guard let scratchpad = webState.scratchpad else {
            return ScratchpadPanelBootstrap(
                documentID: nil, displayName: webState.title, revision: nil, contentHTML: nil, missingDocument: true,
                message: "Toastty could not determine which Scratchpad document this panel should render.", theme: theme
            )
        }
        do {
            guard let document = try load(scratchpad.documentID) else {
                return ScratchpadPanelBootstrap(
                    documentID: scratchpad.documentID, displayName: webState.title, revision: scratchpad.revision,
                    contentHTML: nil, missingDocument: true, sessionLinked: scratchpad.sessionLink != nil,
                    message: "The Scratchpad document is missing from Toastty's document store.", theme: theme
                )
            }
            return ScratchpadPanelBootstrap(
                documentID: document.documentID, displayName: document.title ?? webState.title, revision: document.revision,
                contentHTML: document.content, sessionLinked: scratchpad.sessionLink != nil || document.hasSessionLink,
                theme: theme
            )
        } catch {
            return ScratchpadPanelBootstrap(
                documentID: scratchpad.documentID, displayName: webState.title, revision: scratchpad.revision,
                contentHTML: nil, missingDocument: true, sessionLinked: scratchpad.sessionLink != nil,
                message: "Toastty could not load this Scratchpad document: \(error.localizedDescription)", theme: theme
            )
        }
    }

    public func deliveryJavaScript() -> String? {
        guard let data = try? JSONEncoder().encode(self), let json = String(data: data, encoding: .utf8) else { return nil }
        return ScratchpadBridgeScript.command("bridge.receiveBootstrap(\(json));")
    }
}

public enum ScratchpadBridgeScript {
    public static let handlerName = "toasttyScratchpadPanel"
    public static let externalLinkHandlerName = "toasttyScratchpadExternalLink"
    /// Isolated script world for the external-link handler, so generated
    /// HTML cannot reach it (macOS uses `WKContentWorld.defaultClient`).
    public static let externalLinkWorldName = "toastty-scratchpad-links"

    public static func command(_ command: String) -> String {
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

    public static var focusActiveContent: String { command("return bridge.focusActiveContent();") }

    /// Trusted http(s) link clicks → native (runs in the isolated world).
    public static let externalLinkJavaScript = """
    (() => {
      window.addEventListener("click", (event) => {
        if (!event.isTrusted || event.defaultPrevented || event.button !== 0) return;
        const anchor = event.composedPath().find((node) =>
          node instanceof Element && node.matches("a[href]")
        );
        if (!anchor) return;
        const href = anchor.getAttribute("href")?.trim();
        if (!href || href.startsWith("#")) return;
        let url;
        try { url = new URL(href, document.baseURI); } catch { return; }
        if (url.protocol !== "https:" && url.protocol !== "http:") return;
        event.preventDefault();
        window.webkit.messageHandlers.\(externalLinkHandlerName).postMessage(url.href);
      });
    })();
    """

    /// Validates an external-link message body (http/https with a host).
    public static func externalLinkURL(fromMessage body: String?) -> URL? {
        guard let body, let url = URL(string: body), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, host.isEmpty == false else { return nil }
        return url
    }
}

/// The fields of a stored Scratchpad document (`ScratchpadDocument`) the
/// panel renders.
public struct ScratchpadDocumentRecord: Decodable, Equatable, Sendable {
    public var documentID: UUID
    public var revision: Int
    public var title: String?
    public var content: String
    public var hasSessionLink: Bool

    private enum CodingKeys: String, CodingKey {
        case documentID, revision, title, content, sessionLink
    }

    public init(documentID: UUID, revision: Int, title: String?, content: String, hasSessionLink: Bool = false) {
        self.documentID = documentID
        self.revision = revision
        self.title = title
        self.content = content
        self.hasSessionLink = hasSessionLink
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        documentID = try container.decode(UUID.self, forKey: .documentID)
        revision = try container.decode(Int.self, forKey: .revision)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        hasSessionLink = container.contains(.sessionLink) && (try? container.decodeNil(forKey: .sessionLink)) == false
    }

    /// Reads `<scratchpad documents>/<id>.json` (the `ScratchpadDocumentStore`
    /// layout) directly; used until the app-logic store is attached.
    public static func loadFromDisk(documentID: UUID, directory: URL) throws -> ScratchpadDocumentRecord? {
        let url = directory.appendingPathComponent("\(documentID.uuidString).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ScratchpadDocumentRecord.self, from: Data(contentsOf: url))
    }
}
