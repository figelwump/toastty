import AppKit
import CoreState
import UniformTypeIdentifiers

enum LocalDocumentOpenPanel {
    @MainActor
    static func chooseFile(
        title: String = "Open Markdown File",
        directoryURL: URL? = nil
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Open"
        panel.message = "Choose a markdown file to open in Toastty."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = allowedContentTypes()
        panel.directoryURL = directoryURL
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func allowedContentTypes() -> [UTType] {
        var types: [UTType] = []
        for fileExtension in LocalDocumentClassifier.markdownFilenameExtensions {
            if let type = UTType(filenameExtension: fileExtension, conformingTo: .plainText),
               types.contains(type) == false {
                types.append(type)
            }
        }
        return types
    }
}
