import Foundation

public enum WebPanelDefinition: String, Codable, CaseIterable, Hashable, Sendable {
    case browser
    case markdown
    case scratchpad
    case diff

    public var defaultTitle: String {
        switch self {
        case .browser:
            return "Browser"
        case .markdown:
            return "Markdown"
        case .scratchpad:
            return "Scratchpad"
        case .diff:
            return "Diff"
        }
    }
}

public struct WebPanelState: Codable, Equatable, Sendable {
    public var definition: WebPanelDefinition
    public var title: String
    // `initialURL` captures creation intent while `currentURL` tracks the
    // browser's live/restorable location after runtime navigation.
    public var initialURL: String?
    public var currentURL: String?
    // Markdown keeps the selected file path in state for restore/reopen and
    // workspace-local dedupe. Revisit this flat shape before editing lands.
    public var filePath: String?

    public init(
        definition: WebPanelDefinition,
        title: String? = nil,
        initialURL: String? = nil,
        currentURL: String? = nil,
        filePath: String? = nil
    ) {
        self.definition = definition
        self.title = Self.resolvedTitle(
            definition: definition,
            title: title
        )
        self.initialURL = Self.normalizedInitialURL(initialURL)
        self.currentURL = Self.normalizedCurrentURL(currentURL)
        self.filePath = Self.normalizedFilePath(filePath)
    }

    public var displayPanelLabel: String {
        title
    }

    public var restorableURL: String? {
        currentURL ?? initialURL
    }

    public static func resolvedTitle(definition: WebPanelDefinition, title: String?) -> String {
        normalizedTitle(title) ?? definition.defaultTitle
    }

    public static func normalizedTitle(_ value: String?) -> String? {
        normalizedValue(value)
    }

    public static func normalizedInitialURL(_ value: String?) -> String? {
        guard let normalized = normalizedValue(value) else {
            return nil
        }
        if normalized.caseInsensitiveCompare("about:blank") == .orderedSame {
            return nil
        }
        return normalized
    }

    public static func normalizedCurrentURL(_ value: String?) -> String? {
        normalizedValue(value)
    }

    public static func normalizedFilePath(_ value: String?) -> String? {
        normalizedValue(value)
    }

    private static func normalizedValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return trimmed
    }
}

public enum WebPanelPlacement: String, Codable, Equatable, Sendable {
    case rootRight
    case newTab
    case splitRight
}
