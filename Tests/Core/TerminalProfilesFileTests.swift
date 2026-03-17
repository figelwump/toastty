import CoreState
import Foundation
import Testing

struct TerminalProfilesFileTests {
    @Test
    func templateContentsParsesAsEmptyCatalog() throws {
        let fileManager = InMemoryTerminalProfilesFileManager(templateContents: TerminalProfilesFile.templateContents())
        let catalog = try TerminalProfilesFile.load(
            fileManager: fileManager.fileManager,
            homeDirectoryPath: fileManager.rootURL.path
        )

        #expect(catalog.profiles.isEmpty)
    }

    @Test
    func loadParsesProfilesInFileOrderAndDefaultsBadgeToDisplayName() throws {
        let contents = """
        [zmx]
        displayName = "ZMX"
        startupCommand = "zmx attach toastty.$TOASTTY_PANEL_ID"

        [ssh-prod]
        displayName = "SSH Prod"
        badge = "SSH"
        startupCommand = "ssh prod"
        """

        let fileManager = InMemoryTerminalProfilesFileManager(templateContents: contents)
        let catalog = try TerminalProfilesFile.load(
            fileManager: fileManager.fileManager,
            homeDirectoryPath: fileManager.rootURL.path
        )

        #expect(catalog.profiles.map(\.id) == ["zmx", "ssh-prod"])
        #expect(catalog.profiles.map(\.displayName) == ["ZMX", "SSH Prod"])
        #expect(catalog.profiles.map(\.badgeLabel) == ["ZMX", "SSH"])
    }

    @Test
    func ensureTemplateExistsCreatesCommentOnlyFileOnce() throws {
        let fileManager = InMemoryTerminalProfilesFileManager(templateContents: nil)

        try TerminalProfilesFile.ensureTemplateExists(
            fileManager: fileManager.fileManager,
            homeDirectoryPath: fileManager.rootURL.path
        )
        let createdContents = try #require(
            fileManager.contents(at: TerminalProfilesFile.fileURL(homeDirectoryPath: fileManager.rootURL.path).path)
        )

        try TerminalProfilesFile.ensureTemplateExists(
            fileManager: fileManager.fileManager,
            homeDirectoryPath: fileManager.rootURL.path
        )
        let secondContents = try #require(
            fileManager.contents(at: TerminalProfilesFile.fileURL(homeDirectoryPath: fileManager.rootURL.path).path)
        )

        #expect(createdContents == TerminalProfilesFile.templateContents())
        #expect(secondContents == createdContents)
    }

    @Test
    func ensureTemplateExistsSkipsWritingWhenOverridePathIsSet() throws {
        let fileManager = InMemoryTerminalProfilesFileManager(templateContents: nil)
        let overrideURL = fileManager.rootURL
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("custom-profiles.toml", isDirectory: false)

        try TerminalProfilesFile.ensureTemplateExists(
            fileManager: fileManager.fileManager,
            homeDirectoryPath: fileManager.rootURL.path,
            environment: [TerminalProfilesFile.environmentOverrideKey: overrideURL.path]
        )

        #expect(fileManager.fileManager.fileExists(atPath: overrideURL.path) == false)
    }

    @Test
    func loadRejectsMissingStartupCommand() throws {
        let contents = """
        [zmx]
        displayName = "ZMX"
        """
        let fileManager = InMemoryTerminalProfilesFileManager(templateContents: contents)

        #expect(throws: TerminalProfilesParseError(line: 1, message: "[zmx] is missing startupCommand")) {
            _ = try TerminalProfilesFile.load(
                fileManager: fileManager.fileManager,
                homeDirectoryPath: fileManager.rootURL.path
            )
        }
    }

    @Test
    func loadRejectsProfileIDsThatLookLikeCLIFlags() throws {
        let contents = """
        [--ssh]
        displayName = "Broken"
        startupCommand = "ssh prod"
        """
        let fileManager = InMemoryTerminalProfilesFileManager(templateContents: contents)

        #expect(throws: TerminalProfilesParseError(line: 1, message: "invalid profile ID '--ssh'")) {
            _ = try TerminalProfilesFile.load(
                fileManager: fileManager.fileManager,
                homeDirectoryPath: fileManager.rootURL.path
            )
        }
    }

    @Test
    func loadPreservesHashCharactersInsideQuotedStringsAndWindowsLineEndings() throws {
        let contents = "[ssh-prod]\r\n" +
            "displayName = \"SSH # Prod\"\r\n" +
            "startupCommand = \"printf '# keep me'\"\r\n"
        let fileManager = InMemoryTerminalProfilesFileManager(templateContents: contents)

        let catalog = try TerminalProfilesFile.load(
            fileManager: fileManager.fileManager,
            homeDirectoryPath: fileManager.rootURL.path
        )

        #expect(catalog.profiles.map(\.displayName) == ["SSH # Prod"])
        #expect(catalog.profiles.map(\.startupCommand) == ["printf '# keep me'"])
    }

    @Test
    func loadUsesOverridePathWhenEnvironmentProvidesCustomFileLocation() throws {
        let fileManager = InMemoryTerminalProfilesFileManager(templateContents: nil)
        let overrideURL = fileManager.rootURL
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("custom-profiles.toml", isDirectory: false)
        try FileManager.default.createDirectory(
            at: overrideURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [smoke]
        displayName = "Smoke"
        startupCommand = "printf 'ok'"
        """.write(to: overrideURL, atomically: true, encoding: .utf8)

        let catalog = try TerminalProfilesFile.load(
            fileManager: fileManager.fileManager,
            homeDirectoryPath: fileManager.rootURL.path,
            environment: [TerminalProfilesFile.environmentOverrideKey: overrideURL.path]
        )

        #expect(catalog.profiles.map(\.id) == ["smoke"])
    }

    @Test
    func loadParsesShortcutKeyAndNormalizesToLowercase() throws {
        let contents = """
        [zmx]
        displayName = "ZMX"
        startupCommand = "zmx attach"
        shortcutKey = "Z"

        [ssh-prod]
        displayName = "SSH Prod"
        startupCommand = "ssh prod"
        shortcutKey = "s"
        """
        let fileManager = InMemoryTerminalProfilesFileManager(templateContents: contents)
        let catalog = try TerminalProfilesFile.load(
            fileManager: fileManager.fileManager,
            homeDirectoryPath: fileManager.rootURL.path
        )

        #expect(catalog.profiles.map(\.shortcutKey) == [Character("z"), Character("s")])
    }

    @Test
    func loadAllowsProfilesWithoutShortcutKey() throws {
        let contents = """
        [zmx]
        displayName = "ZMX"
        startupCommand = "zmx attach"
        shortcutKey = "z"

        [ssh-prod]
        displayName = "SSH Prod"
        startupCommand = "ssh prod"
        """
        let fileManager = InMemoryTerminalProfilesFileManager(templateContents: contents)
        let catalog = try TerminalProfilesFile.load(
            fileManager: fileManager.fileManager,
            homeDirectoryPath: fileManager.rootURL.path
        )

        #expect(catalog.profiles[0].shortcutKey == Character("z"))
        #expect(catalog.profiles[1].shortcutKey == nil)
    }

    @Test
    func loadRejectsShortcutKeyLongerThanOneCharacter() throws {
        let contents = """
        [zmx]
        displayName = "ZMX"
        startupCommand = "zmx attach"
        shortcutKey = "zz"
        """
        let fileManager = InMemoryTerminalProfilesFileManager(templateContents: contents)

        #expect(throws: TerminalProfilesParseError(
            line: 1,
            message: "[zmx] shortcutKey must be a single letter or digit"
        )) {
            _ = try TerminalProfilesFile.load(
                fileManager: fileManager.fileManager,
                homeDirectoryPath: fileManager.rootURL.path
            )
        }
    }

    @Test
    func loadRejectsDuplicateShortcutKeysAcrossProfiles() throws {
        let contents = """
        [zmx]
        displayName = "ZMX"
        startupCommand = "zmx attach"
        shortcutKey = "z"

        [other]
        displayName = "Other"
        startupCommand = "other cmd"
        shortcutKey = "z"
        """
        let fileManager = InMemoryTerminalProfilesFileManager(templateContents: contents)

        #expect(throws: TerminalProfilesParseError(
            line: 6,
            message: "[other] shortcutKey 'z' is already used by [zmx]"
        )) {
            _ = try TerminalProfilesFile.load(
                fileManager: fileManager.fileManager,
                homeDirectoryPath: fileManager.rootURL.path
            )
        }
    }

    @Test
    func loadRejectsNonAlphanumericShortcutKey() throws {
        let contents = """
        [zmx]
        displayName = "ZMX"
        startupCommand = "zmx attach"
        shortcutKey = "!"
        """
        let fileManager = InMemoryTerminalProfilesFileManager(templateContents: contents)

        #expect(throws: TerminalProfilesParseError(
            line: 1,
            message: "[zmx] shortcutKey must be a single letter or digit"
        )) {
            _ = try TerminalProfilesFile.load(
                fileManager: fileManager.fileManager,
                homeDirectoryPath: fileManager.rootURL.path
            )
        }
    }

    @Test
    func loadReturnsEmptyCatalogWhenOverridePathDoesNotExist() throws {
        let fileManager = InMemoryTerminalProfilesFileManager(templateContents: nil)
        let overrideURL = fileManager.rootURL
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("missing-profiles.toml", isDirectory: false)

        let catalog = try TerminalProfilesFile.load(
            fileManager: fileManager.fileManager,
            homeDirectoryPath: fileManager.rootURL.path,
            environment: [TerminalProfilesFile.environmentOverrideKey: overrideURL.path]
        )

        #expect(catalog.profiles.isEmpty)
    }
}

private final class InMemoryTerminalProfilesFileManager {
    let fileManager: FileManager
    let rootURL: URL

    init(templateContents: String?) {
        fileManager = FileManager()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-terminal-profiles-file-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        if let templateContents {
            let fileURL = TerminalProfilesFile.fileURL(homeDirectoryPath: rootURL.path)
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? templateContents.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    func contents(at path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }
}
