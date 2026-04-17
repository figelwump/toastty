import Foundation

public enum WebPanelCapabilityProfile: String, Hashable, Sendable {
    case localOnly
    case networkAllowed
}

public enum WebPanelDefinition: String, Codable, CaseIterable, Hashable, Sendable {
    case browser
    case localDocument
    case scratchpad
    case diff

    public var defaultTitle: String {
        switch self {
        case .browser:
            return "Browser"
        case .localDocument:
            return "Document"
        case .scratchpad:
            return "Scratchpad"
        case .diff:
            return "Diff"
        }
    }

    public var capabilityProfile: WebPanelCapabilityProfile {
        switch self {
        case .browser:
            return .networkAllowed
        case .localDocument:
            return .localOnly
        case .scratchpad, .diff:
            // Keep placeholder built-ins least-privilege until their concrete
            // runtime requirements are real enough to justify more access.
            return .localOnly
        }
    }
}

extension WebPanelDefinition {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        switch rawValue {
        case Self.browser.rawValue:
            self = .browser
        case "markdown", Self.localDocument.rawValue:
            self = .localDocument
        case Self.scratchpad.rawValue:
            self = .scratchpad
        case Self.diff.rawValue:
            self = .diff
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown web panel definition: \(rawValue)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum LocalDocumentFormat: String, Codable, Equatable, Sendable {
    case markdown
    case yaml
    case toml
}

public struct LocalDocumentState: Codable, Equatable, Sendable {
    public var filePath: String?
    public var format: LocalDocumentFormat

    public init(
        filePath: String? = nil,
        format: LocalDocumentFormat = .markdown
    ) {
        self.filePath = normalizedWebPanelValue(filePath)
        self.format = format
    }
}

extension LocalDocumentState {
    private enum CodingKeys: String, CodingKey {
        case filePath
        case format
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            filePath: try container.decodeIfPresent(String.self, forKey: .filePath),
            format: try container.decodeIfPresent(LocalDocumentFormat.self, forKey: .format) ?? .markdown
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(filePath, forKey: .filePath)
        try container.encode(format, forKey: .format)
    }
}

public struct WebPanelState: Codable, Equatable, Sendable {
    public static let defaultBrowserPageZoom: Double = 1
    public static let minBrowserPageZoom: Double = 0.5
    public static let maxBrowserPageZoom: Double = 3
    public static let browserPageZoomComparisonEpsilon: Double = 0.0001
    public static let browserPageZoomSteps: [Double] = [
        0.5,
        0.67,
        0.8,
        0.9,
        1.0,
        1.1,
        1.25,
        1.5,
        1.75,
        2.0,
        2.5,
        3.0,
    ]

    public var definition: WebPanelDefinition
    public var title: String
    // `initialURL` captures creation intent while `currentURL` tracks the
    // browser's live/restorable location after runtime navigation.
    public var initialURL: String?
    public var currentURL: String?
    public var localDocument: LocalDocumentState?
    public var browserPageZoom: Double?

    public init(
        definition: WebPanelDefinition,
        title: String? = nil,
        initialURL: String? = nil,
        currentURL: String? = nil,
        filePath: String? = nil,
        localDocument: LocalDocumentState? = nil,
        browserPageZoom: Double? = nil
    ) {
        self.definition = definition
        self.title = Self.resolvedTitle(
            definition: definition,
            title: title
        )
        self.initialURL = Self.normalizedInitialURL(initialURL)
        self.currentURL = Self.normalizedCurrentURL(currentURL)
        self.localDocument = Self.resolvedLocalDocumentState(
            definition: definition,
            filePath: filePath,
            localDocument: localDocument
        )
        self.browserPageZoom = Self.resolvedBrowserPageZoom(
            definition: definition,
            browserPageZoom: browserPageZoom
        )
    }

    public var displayPanelLabel: String {
        title
    }

    // Temporary compatibility shim while app/runtime call sites migrate from
    // the old flat markdown shape to typed local-document state.
    public var filePath: String? {
        localDocument?.filePath
    }

    public var restorableURL: String? {
        currentURL ?? initialURL
    }

    public var effectiveBrowserPageZoom: Double {
        guard definition == .browser else {
            return Self.defaultBrowserPageZoom
        }
        return browserPageZoom ?? Self.defaultBrowserPageZoom
    }

    public static func resolvedTitle(definition: WebPanelDefinition, title: String?) -> String {
        normalizedTitle(title) ?? definition.defaultTitle
    }

    public static func normalizedTitle(_ value: String?) -> String? {
        normalizedWebPanelValue(value)
    }

    public static func normalizedInitialURL(_ value: String?) -> String? {
        guard let normalized = normalizedWebPanelValue(value) else {
            return nil
        }
        if normalized.caseInsensitiveCompare("about:blank") == .orderedSame {
            return nil
        }
        return normalized
    }

    public static func normalizedCurrentURL(_ value: String?) -> String? {
        normalizedWebPanelValue(value)
    }

    public static func normalizedFilePath(_ value: String?) -> String? {
        normalizedWebPanelValue(value)
    }

    public static func clampedBrowserPageZoom(_ value: Double) -> Double {
        min(max(value, minBrowserPageZoom), maxBrowserPageZoom)
    }

    public static func normalizedBrowserPageZoom(_ value: Double?) -> Double? {
        guard let value else { return nil }
        let clampedZoom = clampedBrowserPageZoom(value)
        guard abs(clampedZoom - defaultBrowserPageZoom) >= browserPageZoomComparisonEpsilon else {
            return nil
        }
        return clampedZoom
    }

    public static func increasedBrowserPageZoom(from currentZoom: Double) -> Double {
        let normalizedZoom = clampedBrowserPageZoom(currentZoom)
        for step in browserPageZoomSteps {
            if step > normalizedZoom + browserPageZoomComparisonEpsilon {
                return step
            }
        }
        return browserPageZoomSteps.last ?? maxBrowserPageZoom
    }

    public static func decreasedBrowserPageZoom(from currentZoom: Double) -> Double {
        let normalizedZoom = clampedBrowserPageZoom(currentZoom)
        for step in browserPageZoomSteps.reversed() {
            if step < normalizedZoom - browserPageZoomComparisonEpsilon {
                return step
            }
        }
        return browserPageZoomSteps.first ?? minBrowserPageZoom
    }

    private static func resolvedLocalDocumentState(
        definition: WebPanelDefinition,
        filePath: String?,
        localDocument: LocalDocumentState?
    ) -> LocalDocumentState? {
        let normalizedLegacyFilePath = normalizedFilePath(filePath)

        guard definition == .localDocument else {
            assert(
                localDocument == nil && normalizedLegacyFilePath == nil,
                "Only localDocument panels may carry local document state."
            )
            return nil
        }

        if let localDocument {
            return LocalDocumentState(
                filePath: localDocument.filePath,
                format: localDocument.format
            )
        }

        guard let normalizedLegacyFilePath else {
            return nil
        }

        return LocalDocumentState(filePath: normalizedLegacyFilePath)
    }

    private static func resolvedBrowserPageZoom(
        definition: WebPanelDefinition,
        browserPageZoom: Double?
    ) -> Double? {
        guard definition == .browser else {
            assert(browserPageZoom == nil, "Only browser panels may carry browser zoom state.")
            return nil
        }

        return normalizedBrowserPageZoom(browserPageZoom)
    }
}

extension WebPanelState {
    private enum CodingKeys: String, CodingKey {
        case definition
        case title
        case initialURL
        case currentURL
        case localDocument
        case filePath
        case browserPageZoom
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let definition = try container.decode(WebPanelDefinition.self, forKey: .definition)
        let decodedLocalDocument = try container.decodeIfPresent(LocalDocumentState.self, forKey: .localDocument)
        let legacyFilePath = try container.decodeIfPresent(String.self, forKey: .filePath)

        self.init(
            definition: definition,
            title: try container.decodeIfPresent(String.self, forKey: .title),
            initialURL: try container.decodeIfPresent(String.self, forKey: .initialURL),
            currentURL: try container.decodeIfPresent(String.self, forKey: .currentURL),
            localDocument: decodedLocalDocument ?? Self.legacyLocalDocumentState(
                definition: definition,
                filePath: legacyFilePath
            ),
            browserPageZoom: try container.decodeIfPresent(Double.self, forKey: .browserPageZoom)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(definition, forKey: .definition)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(initialURL, forKey: .initialURL)
        try container.encodeIfPresent(currentURL, forKey: .currentURL)
        try container.encodeIfPresent(localDocument, forKey: .localDocument)
        try container.encodeIfPresent(browserPageZoom, forKey: .browserPageZoom)
    }

    private static func legacyLocalDocumentState(
        definition: WebPanelDefinition,
        filePath: String?
    ) -> LocalDocumentState? {
        // The custom definition decoder has already mapped persisted
        // `definition: "markdown"` payloads to `.localDocument`.
        guard definition == .localDocument,
              let normalizedFilePath = normalizedFilePath(filePath) else {
            return nil
        }

        return LocalDocumentState(filePath: normalizedFilePath)
    }
}

public enum WebPanelPlacement: String, Codable, Equatable, Sendable {
    case rootRight
    case newTab
    case splitRight
}

private func normalizedWebPanelValue(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return nil }
    return trimmed
}
