import AppKit
import CoreState

enum LocalDocumentOpenPanel {
    // The local-document surface is intentionally extension-driven. UTType
    // resolution is ambiguous for some supported extensions (`.ts`, `.mts`)
    // and synthetic text-compatible UTTypes do not necessarily match the
    // filesystem-reported content types for files we already support.
    private static let allowedPathExtensions = Set(LocalDocumentClassifier.supportedFilenameExtensions)

    @MainActor
    static func chooseFile(
        title: String = "Open Local File",
        directoryURL: URL? = nil
    ) -> URL? {
        let panel = NSOpenPanel()
        let delegate = SelectionFilterDelegate()
        panel.title = title
        panel.prompt = "Open"
        panel.message = "Choose a local file to open in Toastty."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.delegate = delegate
        panel.directoryURL = directoryURL
        guard panel.runModal() == .OK,
              let url = panel.url,
              allowsSelection(at: url) else {
            return nil
        }
        return url
    }

    static func allowsSelection(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return true
        }

        return allowedPathExtensions.contains(url.pathExtension.lowercased())
    }

    private final class SelectionFilterDelegate: NSObject, NSOpenSavePanelDelegate {
        func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
            LocalDocumentOpenPanel.allowsSelection(at: url)
        }
    }
}
