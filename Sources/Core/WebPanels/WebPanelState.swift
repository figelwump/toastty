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
    public var url: String?

    public init(
        definition: WebPanelDefinition,
        title: String? = nil,
        url: String? = nil
    ) {
        self.definition = definition
        self.title = Self.normalizedTitle(title) ?? definition.defaultTitle
        self.url = Self.normalizedValue(url)
    }

    public var displayPanelLabel: String {
        title
    }

    private static func normalizedTitle(_ value: String?) -> String? {
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
    case newTab
    case splitRight
}
