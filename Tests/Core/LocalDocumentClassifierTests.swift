import CoreState
import Foundation
import Testing

struct LocalDocumentClassifierTests {
    @Test
    func formatForPathExtensionRecognizesMarkdownVariantsCaseInsensitively() {
        let supportedExtensions = [
            "md",
            "markdown",
            "mdown",
            "mkd",
            "MD",
            "MARKDOWN",
        ]

        for pathExtension in supportedExtensions {
            #expect(LocalDocumentClassifier.format(forPathExtension: pathExtension) == .markdown)
        }
    }

    @Test
    func formatForFilePathSupportsSpacesAndRejectsUnsupportedOrExtensionlessPaths() {
        #expect(
            LocalDocumentClassifier.format(forFilePath: "/tmp/My Notes/README.MD") == .markdown
        )
        #expect(LocalDocumentClassifier.format(forFilePath: "/tmp/config.yaml") == nil)
        #expect(LocalDocumentClassifier.format(forFilePath: "/tmp/notes") == nil)
        #expect(LocalDocumentClassifier.format(forFilePath: "   ") == nil)
    }
}
