import Darwin
import Foundation
import Testing
@testable import ToasttyApp

/// The write that tells Claude Code that the coordinator's folder is
/// trusted, with real files, the real lock directory and writers that follow
/// Claude Code's own rules for its config file.
struct ClaudeFolderTrustTests {
    // MARK: - The edit of the text

    private func edited(_ text: String, folder: String = "/work/coordinator") throws -> String? {
        switch try ClaudeConfigTrustEdit.trusting(folderKey: folder, in: Data(text.utf8)) {
        case .alreadyTrusted: return nil
        case .edited(let data): return String(decoding: data, as: UTF8.self)
        }
    }

    @Test func aNewFolderIsAddedAfterTheLastProjectAndNoOtherByteChanges() throws {
        // As Claude Code writes the file: two spaces, numbers of every
        // kind, and text that looks like the keys the edit searches for.
        let text = """
        {
          "numStartups": 412,
          "lastCost": 0.1,
          "large": 1e21,
          "exact": 12345678901234567890,
          "ratio": -0.0,
          "note": "\\"projects\\": {\\"/work/coordinator\\": {}} } ] \\\\",
          "nested": {
            "projects": {
              "/work/coordinator": {
                "hasTrustDialogAccepted": false
              }
            }
          },
          "projects": {
            "/work": {
              "allowedTools": [],
              "hasTrustDialogAccepted": true,
              "lastCost": 1.50
            },
            "/work/coordinator/attachments": {
              "hasTrustDialogAccepted": false
            }
          },
          "tipsHistory": {
            "a": 1
          }
        }

        """
        let expected = text.replacingOccurrences(of: """
            "/work/coordinator/attachments": {
              "hasTrustDialogAccepted": false
            }
          },
        """, with: """
            "/work/coordinator/attachments": {
              "hasTrustDialogAccepted": false
            },
            "/work/coordinator": {"hasTrustDialogAccepted": true}
          },
        """)
        #expect(expected != text)
        #expect(try edited(text) == expected)
    }

    @Test func aFolderWithAnEntryKeepsItsOtherFields() throws {
        let entry = """
        {
          "projects": {
            "/work/coordinator": {
              "allowedTools": ["Bash(git status)"],
              "lastSessionId": "abc"
            },
            "/other": {}
          }
        }
        """
        #expect(try edited(entry) == entry.replacingOccurrences(
            of: "\"lastSessionId\": \"abc\"",
            with: "\"lastSessionId\": \"abc\",\n      \"hasTrustDialogAccepted\": true"
        ))
        // An entry that says no gets the one word changed.
        let refused = #"{"projects":{"/work/coordinator":{"hasTrustDialogAccepted":false,"allowedTools":[]}}}"#
        #expect(try edited(refused)
            == #"{"projects":{"/work/coordinator":{"hasTrustDialogAccepted":true,"allowedTools":[]}}}"#)
        // An empty entry.
        #expect(try edited(#"{"projects":{"/work/coordinator":{}}}"#)
            == #"{"projects":{"/work/coordinator":{"hasTrustDialogAccepted": true}}}"#)
    }

    @Test func aFileWithoutProjectsGetsThem() throws {
        #expect(try edited("{}") == #"{"projects": {"/work/coordinator": {"hasTrustDialogAccepted": true}}}"#)
        #expect(try edited("{\n  \"numStartups\": 3\n}\n")
            == "{\n  \"numStartups\": 3,\n  \"projects\": {\"/work/coordinator\": {\"hasTrustDialogAccepted\": true}}\n}\n")
        #expect(try edited(#"{"projects":{}}"#)
            == #"{"projects":{"/work/coordinator": {"hasTrustDialogAccepted": true}}}"#)
    }

    @Test func aTrustedFolderNeedsNoEdit() throws {
        #expect(try edited(#"{"projects": {"/work/coordinator": {"hasTrustDialogAccepted": true}}}"#) == nil)
        // The same folder, with its key written in another way.
        #expect(try edited(#"{"projects": {"\/work\/coordinator": {"hasTrustDialogAccepted": true}}}"#) == nil)
    }

    @Test func onlyTheExactFolderCounts() throws {
        // A trusted folder above, a folder below and a folder with the
        // same start are other folders.
        let text = #"{"projects":{"/work":{"hasTrustDialogAccepted":true},"/work/coordinator2":{"hasTrustDialogAccepted":true},"/work/coordinator/x":{"hasTrustDialogAccepted":true}}}"#
        let result = try #require(try edited(text))
        let projects = try #require(
            (try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])?["projects"] as? [String: [String: Bool]]
        )
        #expect(projects == [
            "/work": ["hasTrustDialogAccepted": true],
            "/work/coordinator2": ["hasTrustDialogAccepted": true],
            "/work/coordinator/x": ["hasTrustDialogAccepted": true],
            "/work/coordinator": ["hasTrustDialogAccepted": true],
        ])
        #expect(result.hasPrefix(String(text.dropLast(2))))
    }

    @Test func aFolderNameIsWrittenAsJSON() throws {
        let folder = "/work/a \"quoted\" \\ name/caf\u{00E9}/\u{65E5}\u{672C}\n"
        let result = try #require(try edited(#"{"projects":{}}"#, folder: folder))
        let projects = try #require(
            (try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])?["projects"] as? [String: Any]
        )
        #expect(Array(projects.keys) == [folder])
        // A key that differs only in its Unicode form is another key, as
        // it is for Claude Code.
        let composed = "/work/caf\u{00E9}"
        let decomposed = "/work/cafe\u{0301}"
        let both = try #require(try edited(
            #"{"projects":{"\#(decomposed)":{"hasTrustDialogAccepted":true}}}"#, folder: composed
        ))
        #expect(both.unicodeScalars.elementsEqual(
            #"{"projects":{"\#(decomposed)":{"hasTrustDialogAccepted":true},"\#(composed)": {"hasTrustDialogAccepted": true}}}"#
                .unicodeScalars
        ))
    }

    @Test(arguments: [
        "",
        "[]",
        "\"text\"",
        "{\"projects\": {\"/work\": {}}",
        "{\"projects\": {}} trailing",
        "{\"projects\": []}",
        "{\"projects\": {\"/work/coordinator\": true}}",
        "{\"projects\": {}, \"projects\": {}}",
        "{\"projects\": {\"/work/coordinator\": {}, \"/work/coordinator\": {}}}",
        "{\"a\": 1,}",
        "{\"a\" 1}",
        "\u{FEFF}{}",
    ])
    func aFileThatIsNotAsExpectedIsRefused(text: String) {
        #expect(throws: ClaudeConfigTrustEdit.Failure.self) {
            try ClaudeConfigTrustEdit.trusting(folderKey: "/work/coordinator", in: Data(text.utf8))
        }
    }

    // MARK: - Which file

    @Test func theConfigFileIsWhereThisClaudeCodeKeepsIt() throws {
        let home = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path]
        #expect(ClaudeFolderTrust.configFileURL(profileArgv: ["claude"], environment: environment)?.path
            == home.path + "/.claude.json")
        // The folder the agent's terminal inherits.
        #expect(ClaudeFolderTrust.configFileURL(
            profileArgv: ["/opt/bin/claude", "--model", "opus"],
            environment: ["HOME": home.path, "CLAUDE_CONFIG_DIR": "/data/claude"]
        )?.path == "/data/claude/.claude.json")
        // The folder the profile sets wins.
        #expect(ClaudeFolderTrust.configFileURL(
            profileArgv: ["/usr/bin/env", "FOO=1", "CLAUDE_CONFIG_DIR=/profile/claude", "claude", "--verbose"],
            environment: ["HOME": home.path, "CLAUDE_CONFIG_DIR": "/data/claude"]
        )?.path == "/profile/claude/.claude.json")
        // An argument of the agent is not a variable of the profile.
        #expect(ClaudeFolderTrust.configFileURL(
            profileArgv: ["env", "FOO=1", "claude", "CLAUDE_CONFIG_DIR=/not/this"], environment: environment
        )?.path == home.path + "/.claude.json")

        // Not known: a path that depends on Claude Code's own folder, and
        // an environment that the profile changes in another way.
        #expect(ClaudeFolderTrust.configFileURL(
            profileArgv: ["env", "CLAUDE_CONFIG_DIR=relative/claude", "claude"], environment: environment
        ) == nil)
        #expect(ClaudeFolderTrust.configFileURL(
            profileArgv: ["env", "-u", "CLAUDE_CONFIG_DIR", "claude"],
            environment: ["HOME": home.path, "CLAUDE_CONFIG_DIR": "/data/claude"]
        ) == nil)
        // Not known: an old install that may still read `.config.json`.
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: home.appending(path: ".claude/.config.json"))
        #expect(ClaudeFolderTrust.configFileURL(profileArgv: ["claude"], environment: environment) == nil)
    }

    // MARK: - The write

    /// A home folder with a config file, and a coordinator's folder.
    private struct Home {
        let root: URL
        let config: URL
        let folder: URL
        let folderKey: String
        var lock: URL { URL(filePath: config.path + ".lock") }

        init(config text: String? = Home.config) throws {
            root = try ClaudeFolderTrustTests.temporaryDirectory()
            config = root.appending(path: ".claude.json")
            folder = root.appending(path: "runtime-home/coordinator", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            folderKey = try #require(ClaudeFolderTrust.folderKey(for: folder))
            if let text {
                try Data(text.utf8).write(to: config)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            }
        }

        static let config = """
        {
          "numStartups": 7,
          "oauthAccount": {
            "accountUuid": "0000"
          },
          "projects": {
            "/Users/someone/repos": {
              "allowedTools": [],
              "hasTrustDialogAccepted": true,
              "lastCost": 0.25
            }
          }
        }
        """

        var trust: ClaudeFolderTrust { ClaudeFolderTrust(configFileURL: config) }

        func text() throws -> String { try String(contentsOf: config, encoding: .utf8) }

        func document() throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        }

        func trustedFolders() throws -> [String] {
            let projects = try #require(try document()["projects"] as? [String: [String: Any]])
            return projects.filter { $0.value["hasTrustDialogAccepted"] as? Bool == true }.keys.sorted()
        }

        /// The names in the home folder, to see what a write left behind.
        func names() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func theWriteTrustsTheExactFolderAndKeepsTheRestOfTheFile() async throws {
        let home = try Home()
        defer { home.remove() }
        // The key is the folder's path without links, as Claude Code's
        // working directory reports it.
        #expect(home.folderKey.hasPrefix("/private/"))
        #expect(await home.trust.trust(folder: home.folder) == .trusted)

        let expected = Home.config.replacingOccurrences(
            of: "\"lastCost\": 0.25\n    }",
            with: "\"lastCost\": 0.25\n    },\n    \"\(home.folderKey)\": {\"hasTrustDialogAccepted\": true}"
        )
        #expect(try home.text() == expected)
        #expect(try home.trustedFolders() == ["/Users/someone/repos", home.folderKey].sorted())
        // Claude Code's own permissions, and nothing left beside the file.
        let permissions = try #require(
            try FileManager.default.attributesOfItem(atPath: home.config.path)[.posixPermissions] as? NSNumber
        )
        #expect(permissions.intValue == 0o600)
        #expect(try home.names() == [".claude.json", "runtime-home"])

        // A second start finds the folder trusted and writes nothing.
        let modified = try FileManager.default.attributesOfItem(atPath: home.config.path)[.modificationDate] as? Date
        #expect(await home.trust.trust(folder: home.folder) == .alreadyTrusted)
        #expect(try FileManager.default.attributesOfItem(atPath: home.config.path)[.modificationDate] as? Date == modified)
    }

    @Test func aConfigFileThatIsALinkStaysALink() async throws {
        let home = try Home()
        defer { home.remove() }
        let target = home.root.appending(path: "dotfiles/claude.json")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: home.config, to: target)
        try FileManager.default.createSymbolicLink(at: home.config, withDestinationURL: target)

        #expect(await home.trust.trust(folder: home.folder) == .trusted)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: home.config.path) == target.path)
        #expect(try home.trustedFolders().contains(home.folderKey))
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path) == ["claude.json"])
    }

    @Test func nothingIsWrittenWithoutAConfigFileOrIntoOneThatIsNotAsExpected() async throws {
        // Claude Code never ran here: its first run makes the file.
        let fresh = try Home(config: nil)
        defer { fresh.remove() }
        guard case .skipped = await fresh.trust.trust(folder: fresh.folder) else {
            Issue.record("A write without a config file")
            return
        }
        #expect(try fresh.names() == ["runtime-home"])

        // A file that the user or another tool broke stays as it is.
        let broken = try Home(config: "{\"projects\": {")
        defer { broken.remove() }
        guard case .skipped = await broken.trust.trust(folder: broken.folder) else {
            Issue.record("A write into a file that is not JSON")
            return
        }
        #expect(try broken.text() == "{\"projects\": {")
        #expect(try broken.names() == [".claude.json", "runtime-home"])

        // A folder that does not exist names nothing.
        let home = try Home()
        defer { home.remove() }
        guard case .skipped = await home.trust.trust(folder: home.root.appending(path: "missing")) else {
            Issue.record("A write for a folder that does not exist")
            return
        }
        #expect(try home.text() == Home.config)

        // A link in the folder's place leads to a folder that Toastty did
        // not make: that folder gets no trust.
        let elsewhere = home.root.appending(path: "someones-repository", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: home.folder)
        try FileManager.default.createSymbolicLink(at: home.folder, withDestinationURL: elsewhere)
        guard case .skipped = await home.trust.trust(folder: home.folder) else {
            Issue.record("A write for a link to another folder")
            return
        }
        #expect(try home.text() == Home.config)
    }

    @Test func aHeldLockIsWaitedForAndNeverTaken() async throws {
        let home = try Home()
        defer { home.remove() }
        // Another session holds the lock for the whole wait.
        try FileManager.default.createDirectory(at: home.lock, withIntermediateDirectories: false)
        var trust = home.trust
        trust.lockWaits = [.milliseconds(20), .milliseconds(20)]
        guard case .skipped = await trust.trust(folder: home.folder) else {
            Issue.record("A write under another session's lock")
            return
        }
        #expect(try home.text() == Home.config)
        // The lock is the other session's: it stays.
        #expect(FileManager.default.fileExists(atPath: home.lock.path))

        // The session lets go during the wait: the write goes in then.
        trust.lockWaits = Array(repeating: .milliseconds(50), count: 40)
        let lockPath = home.lock.path
        let release = Task.detached {
            try await Task.sleep(for: .milliseconds(200))
            rmdir(lockPath)
        }
        #expect(await trust.trust(folder: home.folder) == .trusted)
        try await release.value
        #expect(try home.trustedFolders().contains(home.folderKey))
        #expect(FileManager.default.fileExists(atPath: home.lock.path) == false)
    }

    /// One write as Claude Code makes it: the lock directory, a fresh read
    /// under the lock, a new file and a rename.
    private static func claudeCodeWrite(to config: URL, _ change: (inout [String: Any]) -> Void) throws {
        let lock = config.path + ".lock"
        while mkdir(lock, 0o777) != 0 {
            guard errno == EEXIST else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            usleep(500)
        }
        defer { rmdir(lock) }
        var document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        change(&document)
        let temporary = config.path + ".tmp.\(getpid()).\(UUID().uuidString.prefix(12))"
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(filePath: temporary))
        guard rename(temporary, config.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    @Test func sessionsThatWriteAtTheSameTimeKeepTheirWritesAndTheFolderIsTrusted() async throws {
        let home = try Home()
        defer { home.remove() }
        let config = home.config
        let sessions = 4
        let writesForEachSession = 60
        // Each session counts its own writes in the file, as a session
        // saves its costs, while the trust goes in.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for session in 0 ..< sessions {
                group.addTask {
                    for _ in 0 ..< writesForEachSession {
                        try Self.claudeCodeWrite(to: config) { document in
                            var projects = document["projects"] as? [String: Any] ?? [:]
                            var entry = projects["/session/\(session)"] as? [String: Any] ?? [:]
                            entry["writes"] = (entry["writes"] as? Int ?? 0) + 1
                            projects["/session/\(session)"] = entry
                            document["projects"] = projects
                            document["numStartups"] = (document["numStartups"] as? Int ?? 0) + 1
                        }
                        // A session does other work between two saves.
                        usleep(1_000)
                    }
                }
            }
            // The sessions here save far more often than real ones, so the
            // write tries for the lock more often than it does in the app.
            var trust = home.trust
            trust.lockWaits = Array(repeating: .milliseconds(2), count: 3_000)
            let folder = home.folder
            group.addTask { [trust] in
                try await Task.sleep(for: .milliseconds(5))
                let outcome = await trust.trust(folder: folder)
                #expect(outcome == .trusted)
            }
            try await group.waitForAll()
        }

        let document = try home.document()
        let projects = try #require(document["projects"] as? [String: [String: Any]])
        for session in 0 ..< sessions {
            #expect(projects["/session/\(session)"]?["writes"] as? Int == writesForEachSession)
        }
        #expect(document["numStartups"] as? Int == 7 + sessions * writesForEachSession)
        #expect(projects[home.folderKey]?["hasTrustDialogAccepted"] as? Bool == true)
        #expect(projects["/Users/someone/repos"]?["lastCost"] as? Double == 0.25)
        #expect((document["oauthAccount"] as? [String: String]) == ["accountUuid": "0000"])
        #expect(try home.names() == [".claude.json", "runtime-home"])
    }

    @Test func aWriterWithoutTheLockDuringTheWriteIsNotOverwritten() async throws {
        let home = try Home()
        defer { home.remove() }
        // A tool that takes no lock replaces the file after the read and
        // before the rename. Its version is the one that gets the trust.
        let config = home.config
        let replaced = Counter()
        var trust = home.trust
        trust.beforeReplace = {
            guard replaced.next() == 1 else { return }
            let text = Home.config.replacingOccurrences(of: "\"numStartups\": 7", with: "\"numStartups\": 8")
            let temporary = config.path + ".other"
            try? Data(text.utf8).write(to: URL(filePath: temporary))
            rename(temporary, config.path)
        }
        #expect(await trust.trust(folder: home.folder) == .trusted)
        let document = try home.document()
        #expect(document["numStartups"] as? Int == 8)
        #expect(try home.trustedFolders().contains(home.folderKey))
        #expect(try home.names() == [".claude.json", "runtime-home"])
    }

    @Test func onlyAClaudeProfileGetsTheWrite() async throws {
        let home = try Home()
        defer { home.remove() }
        let environment = ["HOME": home.root.path]
        await ClaudeFolderTrust.trustCoordinatorFolder(
            home.folder.path, profileID: "codex", profileArgv: ["codex"], environment: environment
        )
        #expect(try home.text() == Home.config)
        await ClaudeFolderTrust.trustCoordinatorFolder(
            home.folder.path, profileID: "claude", profileArgv: ["claude"], environment: environment
        )
        #expect(try home.trustedFolders() == ["/Users/someone/repos", home.folderKey].sorted())
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.withLock {
                value += 1
                return value
            }
        }
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "toastty-claude-trust-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
