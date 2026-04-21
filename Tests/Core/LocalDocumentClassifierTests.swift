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
    func formatForPathExtensionRecognizesYamlAndTomlVariantsCaseInsensitively() {
        #expect(LocalDocumentClassifier.format(forPathExtension: "yaml") == .yaml)
        #expect(LocalDocumentClassifier.format(forPathExtension: "YML") == .yaml)
        #expect(LocalDocumentClassifier.format(forPathExtension: "toml") == .toml)
        #expect(LocalDocumentClassifier.format(forPathExtension: "TOML") == .toml)
        #expect(LocalDocumentClassifier.format(forPathExtension: "json") == .json)
        #expect(LocalDocumentClassifier.format(forPathExtension: "JSONC") == .json)
        #expect(LocalDocumentClassifier.format(forPathExtension: "jsonl") == .jsonl)
        #expect(LocalDocumentClassifier.format(forPathExtension: "ini") == .config)
        #expect(LocalDocumentClassifier.format(forPathExtension: "CONF") == .config)
        #expect(LocalDocumentClassifier.format(forPathExtension: "cfg") == .config)
        #expect(LocalDocumentClassifier.format(forPathExtension: "properties") == .config)
        #expect(LocalDocumentClassifier.format(forPathExtension: "csv") == .csv)
        #expect(LocalDocumentClassifier.format(forPathExtension: "TSV") == .tsv)
        #expect(LocalDocumentClassifier.format(forPathExtension: "xml") == .xml)
        #expect(LocalDocumentClassifier.format(forPathExtension: "sh") == .shell)
        #expect(LocalDocumentClassifier.format(forPathExtension: "BASH") == .shell)
        #expect(LocalDocumentClassifier.format(forPathExtension: "zsh") == .shell)
    }

    @Test
    func formatForFilePathSupportsSpacesAndRejectsUnsupportedOrExtensionlessPaths() {
        #expect(
            LocalDocumentClassifier.format(forFilePath: "/tmp/My Notes/README.MD") == .markdown
        )
        #expect(
            LocalDocumentClassifier.format(forFilePath: "/tmp/My Notes/README.MD:42") == .markdown
        )
        #expect(
            LocalDocumentClassifier.format(forFilePath: "/tmp/My Notes/README.MD:draft") == .markdown
        )
        #expect(LocalDocumentClassifier.format(forFilePath: "/tmp/config.yaml") == .yaml)
        #expect(LocalDocumentClassifier.format(forFilePath: "/tmp/Toastty.toml") == .toml)
        #expect(LocalDocumentClassifier.format(forFilePath: "/tmp/settings.JSON") == .json)
        #expect(LocalDocumentClassifier.format(forFilePath: "/tmp/logs/events.jsonl") == .jsonl)
        #expect(LocalDocumentClassifier.format(forFilePath: "/tmp/.toastty/config.properties") == .config)
        #expect(LocalDocumentClassifier.format(forFilePath: "/tmp/data/report.csv") == .csv)
        #expect(LocalDocumentClassifier.format(forFilePath: "/tmp/layout.xml") == .xml)
        #expect(LocalDocumentClassifier.format(forFilePath: "/tmp/scripts/bootstrap.zsh") == .shell)
        #expect(LocalDocumentClassifier.format(forFilePath: "/tmp/config.txt:42") == nil)
        #expect(LocalDocumentClassifier.format(forFilePath: "/tmp/notes") == nil)
        #expect(LocalDocumentClassifier.format(forFilePath: "   ") == nil)
    }
}
