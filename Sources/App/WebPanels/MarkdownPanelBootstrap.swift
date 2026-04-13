import Foundation

enum MarkdownPanelMode: String, Codable, Sendable {
    case view
}

struct MarkdownPanelBootstrap: Codable, Equatable, Sendable {
    let contractVersion: Int
    let mode: MarkdownPanelMode
    let filePath: String
    let displayName: String
    let content: String

    init(
        contractVersion: Int = 1,
        mode: MarkdownPanelMode = .view,
        filePath: String,
        displayName: String,
        content: String
    ) {
        self.contractVersion = contractVersion
        self.mode = mode
        self.filePath = filePath
        self.displayName = displayName
        self.content = content
    }
}
