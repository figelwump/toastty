import AppKit
import CoreState
import UniformTypeIdentifiers

enum LocalDocumentOpenPanel {
    @MainActor
    static func chooseFile(
        title: String = "Open Local File",
        directoryURL: URL? = nil
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Open"
        panel.message = "Choose a local file to open in Toastty."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = allowedContentTypes()
        panel.directoryURL = directoryURL
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func allowedContentTypes() -> [UTType] {
        var types: [UTType] = []
        for fileExtension in LocalDocumentClassifier.supportedFilenameExtensions {
            guard let type = UTType(filenameExtension: fileExtension) else {
                continue
            }
            if types.contains(type) == false {
                types.append(type)
            }
        }
        return types
    }
}
