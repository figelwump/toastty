import Foundation

public enum ToasttyShellIntegrationMarkers {
    public static let managedSourceCommentLines = [
        "# Added by Toastty terminal profile shell integration",
        "# Keep this near the end of this file, after other PATH, history, and prompt-hook changes,",
        "# so Toastty can restore its shim directory and prompt-time title/journal hooks.",
    ]

    public static func managedSnippetRelativePath(fileName: String) -> String {
        ".toastty/shell/\(fileName)"
    }

    public static func sourceLine(managedSnippetFileName: String) -> String {
        "source \"$HOME/\(managedSnippetRelativePath(fileName: managedSnippetFileName))\""
    }

    public static func referenceMarkers(
        managedSnippetPath: String,
        managedSnippetFileName: String,
        sourceLine: String
    ) -> [String] {
        [
            sourceLine,
            managedSnippetPath,
            "$HOME/.toastty/shell/\(managedSnippetFileName)",
            "~/.toastty/shell/\(managedSnippetFileName)",
        ]
    }
}
