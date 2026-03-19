import CoreState
import Foundation
import Testing

struct AgentProfilesFileTests {
    @Test
    func templateContentsParsesAsEmptyCatalog() throws {
        let fileManager = InMemoryFileManager(templateContents: AgentProfilesFile.templateContents())
        let catalog = try AgentProfilesFile.load(
            fileManager: fileManager.fileManager,
            homeDirectoryPath: fileManager.rootURL.path
        )

        #expect(catalog.profiles.isEmpty)
    }

    @Test
    func loadParsesProfilesInFileOrder() throws {
        let contents = """
        [codex]
        displayName = "Codex"
        argv = ["codex"]

        [gemini]
        displayName = "Gemini"
        argv = [
          "gemini",
          "--sandbox"
        ]
        """

        let fileManager = InMemoryFileManager(templateContents: contents)
        let catalog = try AgentProfilesFile.load(
            fileManager: fileManager.fileManager,
            homeDirectoryPath: fileManager.rootURL.path
        )

        #expect(catalog.profiles.map(\.id) == ["codex", "gemini"])
        #expect(catalog.profiles.map(\.displayName) == ["Codex", "Gemini"])
        #expect(catalog.profiles[1].argv == ["gemini", "--sandbox"])
    }

    @Test
    func loadPreservesQuotedArgvEntriesWithSpaces() throws {
        let contents = """
        [claude]
        displayName = "Claude Code"
        argv = ["cc", "--append-system-prompt=review only"]
        """

        let fileManager = InMemoryFileManager(templateContents: contents)
        let catalog = try AgentProfilesFile.load(
            fileManager: fileManager.fileManager,
            homeDirectoryPath: fileManager.rootURL.path
        )

        #expect(catalog.profiles.first?.argv == ["cc", "--append-system-prompt=review only"])
    }

    @Test
    func loadParsesShortcutKeyAndNormalizesUppercase() throws {
        let contents = """
        [codex]
        displayName = "Codex"
        argv = ["codex"]
        shortcutKey = "C"
        """

        let fileManager = InMemoryFileManager(templateContents: contents)
        let catalog = try AgentProfilesFile.load(
            fileManager: fileManager.fileManager,
            homeDirectoryPath: fileManager.rootURL.path
        )

        #expect(catalog.profiles.first?.shortcutKey == Character("c"))
    }

    @Test
    func ensureTemplateExistsCreatesCommentOnlyFileOnce() throws {
        let fileManager = InMemoryFileManager(templateContents: nil)

        try AgentProfilesFile.ensureTemplateExists(
            fileManager: fileManager.fileManager,
            homeDirectoryPath: fileManager.rootURL.path
        )
        let createdContents = try #require(fileManager.contents(at: AgentProfilesFile.fileURL(homeDirectoryPath: fileManager.rootURL.path).path))

        try AgentProfilesFile.ensureTemplateExists(
            fileManager: fileManager.fileManager,
            homeDirectoryPath: fileManager.rootURL.path
        )
        let secondContents = try #require(fileManager.contents(at: AgentProfilesFile.fileURL(homeDirectoryPath: fileManager.rootURL.path).path))

        #expect(createdContents == AgentProfilesFile.templateContents())
        #expect(secondContents == createdContents)
    }

    @Test
    func loadRejectsMissingArgv() throws {
        let contents = """
        [codex]
        displayName = "Codex"
        """
        let fileManager = InMemoryFileManager(templateContents: contents)

        #expect(throws: AgentProfilesParseError(line: 1, message: "[codex] is missing argv")) {
            _ = try AgentProfilesFile.load(
                fileManager: fileManager.fileManager,
                homeDirectoryPath: fileManager.rootURL.path
            )
        }
    }

    @Test
    func loadRejectsProfileIDsThatLookLikeCLIFlags() throws {
        let contents = """
        [--session]
        displayName = "Broken"
        argv = ["codex"]
        """
        let fileManager = InMemoryFileManager(templateContents: contents)

        #expect(throws: AgentProfilesParseError(line: 1, message: "invalid agent ID '--session'")) {
            _ = try AgentProfilesFile.load(
                fileManager: fileManager.fileManager,
                homeDirectoryPath: fileManager.rootURL.path
            )
        }
    }

    @Test
    func loadRejectsDuplicateShortcutKeys() throws {
        let contents = """
        [codex]
        displayName = "Codex"
        argv = ["codex"]
        shortcutKey = "c"

        [claude]
        displayName = "Claude"
        argv = ["claude"]
        shortcutKey = "c"
        """
        let fileManager = InMemoryFileManager(templateContents: contents)

        #expect(
            throws: AgentProfilesParseError(
                line: 6,
                message: "[claude] shortcutKey 'c' is already used by [codex]"
            )
        ) {
            _ = try AgentProfilesFile.load(
                fileManager: fileManager.fileManager,
                homeDirectoryPath: fileManager.rootURL.path
            )
        }
    }
}

private final class InMemoryFileManager {
    let fileManager: FileManager
    let rootURL: URL

    init(templateContents: String?) {
        fileManager = FileManager()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-agent-file-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        if let templateContents {
            let fileURL = AgentProfilesFile.fileURL(homeDirectoryPath: rootURL.path)
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? templateContents.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    func contents(at path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }
}
