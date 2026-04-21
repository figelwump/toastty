import CoreState
import Foundation

enum CommandPaletteFileOpenRouting {
    private static let browserExtensions: Set<String> = ["html", "htm"]

    static func destination(forNormalizedFilePath normalizedFilePath: String) -> PaletteFileOpenDestination? {
        let fileURL = URL(fileURLWithPath: normalizedFilePath)
        let pathExtension = fileURL.pathExtension.lowercased()

        if browserExtensions.contains(pathExtension) {
            return .browser(fileURLString: fileURL.absoluteString)
        }

        guard LocalDocumentClassifier.format(forPathExtension: pathExtension) != nil else {
            return nil
        }

        return .localDocument(filePath: normalizedFilePath)
    }

    static var supportedPathExtensions: Set<String> {
        Set(LocalDocumentClassifier.supportedFilenameExtensions).union(browserExtensions)
    }
}
