import Foundation

enum MarkdownPanelMode: String, Codable, Sendable {
    case view
}

enum MarkdownPanelTheme: String, Codable, Equatable, Sendable {
    case light
    case dark
}

struct MarkdownPanelBootstrap: Codable, Equatable, Sendable {
    let contractVersion: Int
    let mode: MarkdownPanelMode
    let filePath: String
    let displayName: String
    let content: String
    let theme: MarkdownPanelTheme

    init(
        contractVersion: Int = 2,
        mode: MarkdownPanelMode = .view,
        filePath: String,
        displayName: String,
        content: String,
        theme: MarkdownPanelTheme
    ) {
        self.contractVersion = contractVersion
        self.mode = mode
        self.filePath = filePath
        self.displayName = displayName
        self.content = content
        self.theme = theme
    }
}

extension MarkdownPanelBootstrap {
    func setting(theme: MarkdownPanelTheme) -> Self {
        Self(
            contractVersion: contractVersion,
            mode: mode,
            filePath: filePath,
            displayName: displayName,
            content: content,
            theme: theme
        )
    }
}
