import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyApp

final class ProviderSessionNameReaderTests: XCTestCase {
    private static let claudeSessionID = "9f6c1b2e-4d55-4a71-9b0a-2f0c7d5e8a31"
    private static let codexThreadID = "019993ea-7c41-7b5a-9d2f-5b1c8e4a6d07"

    // MARK: - Claude transcript parsing

    func testClaudeTranscriptTailUsesLastTitleRecordForTheBoundSession() {
        let tail = """
        {"type":"user","message":{"role":"user","content":"rebuild the sidebar rows"}}
        \(claudeTitleLine(name: "Sidebar work", sessionID: Self.claudeSessionID))
        {"type":"assistant","message":{"role":"assistant","content":"Reading SidebarView."}}
        \(claudeTitleLine(name: "Sidebar session row rebuild", sessionID: Self.claudeSessionID))
        """

        XCTAssertEqual(
            ProviderSessionNameParser.claudeSessionName(
                inTranscriptTail: tail,
                nativeSessionID: Self.claudeSessionID
            ),
            "Sidebar session row rebuild"
        )
    }

    func testClaudeTranscriptTailIgnoresOtherSessionsAndMissingRecords() {
        let otherSessionTail = claudeTitleLine(
            name: "Someone else's session",
            sessionID: "11111111-2222-3333-4444-555555555555"
        )

        XCTAssertNil(
            ProviderSessionNameParser.claudeSessionName(
                inTranscriptTail: otherSessionTail,
                nativeSessionID: Self.claudeSessionID
            )
        )
        XCTAssertNil(
            ProviderSessionNameParser.claudeSessionName(
                inTranscriptTail: """
                {"type":"user","message":{"role":"user","content":"hello"}}
                {"type":"summary","summary":"Sidebar session row rebuild"}
                """,
                nativeSessionID: Self.claudeSessionID
            )
        )
        XCTAssertNil(
            ProviderSessionNameParser.claudeSessionName(
                inTranscriptTail: "",
                nativeSessionID: Self.claudeSessionID
            )
        )
        XCTAssertNil(
            ProviderSessionNameParser.claudeSessionName(
                inTranscriptTail: claudeTitleLine(name: "Named", sessionID: Self.claudeSessionID),
                nativeSessionID: "  "
            )
        )
    }

    func testClaudeTranscriptTailSkipsTruncatedRecordWithoutLosingALaterName() {
        // A transcript is read while the provider is still appending, so the
        // tail can hold a half-written record.
        let truncated = #"{"type":"ai-title","aiTitle":"Half written","sessi"#
        let tail = """
        \(claudeTitleLine(name: "Earlier name", sessionID: Self.claudeSessionID))
        \(truncated)
        \(claudeTitleLine(name: "Later name", sessionID: Self.claudeSessionID))
        """

        XCTAssertEqual(
            ProviderSessionNameParser.claudeSessionName(
                inTranscriptTail: tail,
                nativeSessionID: Self.claudeSessionID
            ),
            "Later name"
        )
        // A trailing truncated record must not blank the name found before it.
        XCTAssertEqual(
            ProviderSessionNameParser.claudeSessionName(
                inTranscriptTail: """
                \(claudeTitleLine(name: "Earlier name", sessionID: Self.claudeSessionID))
                \(truncated)
                """,
                nativeSessionID: Self.claudeSessionID
            ),
            "Earlier name"
        )
    }

    func testProviderNameRejectsOversizedAndControlCharacterNames() {
        let cap = ProviderSessionNameParser.maximumNameScalarCount
        let atCap = String(repeating: "a", count: cap)
        let overCap = String(repeating: "a", count: cap + 1)

        XCTAssertEqual(
            ProviderSessionNameParser.claudeSessionName(
                inTranscriptTail: claudeTitleLine(name: atCap, sessionID: Self.claudeSessionID),
                nativeSessionID: Self.claudeSessionID
            ),
            atCap
        )
        XCTAssertNil(
            ProviderSessionNameParser.claudeSessionName(
                inTranscriptTail: claudeTitleLine(name: overCap, sessionID: Self.claudeSessionID),
                nativeSessionID: Self.claudeSessionID
            )
        )
        // A name lands in a one-line row and a persisted record, so an
        // embedded control character counts as malformed, not as something to
        // sanitize into a plausible-looking name.
        XCTAssertNil(
            ProviderSessionNameParser.claudeSessionName(
                inTranscriptTail: #"{"type":"ai-title","aiTitle":"Sidebar\nrebuild","sessionId":"\#(Self.claudeSessionID)"}"#,
                nativeSessionID: Self.claudeSessionID
            )
        )
        // A JSON-escaped control character that is not whitespace, so nothing
        // trims it away before the check.
        let bellEscape = "\\u0007"
        XCTAssertNil(
            ProviderSessionNameParser.codexThreadName(
                inIndex: #"{"id":"\#(Self.codexThreadID)","thread_name":"Sidebar\#(bellEscape)rebuild","updated_at":"2026-09-17T20:00:00Z"}"#,
                threadID: Self.codexThreadID
            )
        )
    }

    // MARK: - Codex thread index parsing

    func testCodexThreadIndexUsesLastMatchingRecordAndIgnoresOtherThreads() {
        let index = """
        \(codexThreadLine(name: "Another thread", threadID: "019993ea-0000-0000-0000-000000000000"))
        \(codexThreadLine(name: "Sidebar work", threadID: Self.codexThreadID))
        \(codexThreadLine(name: "Sidebar rows and hover cards", threadID: Self.codexThreadID))
        \(codexThreadLine(name: "Yet another thread", threadID: "019993ea-1111-1111-1111-111111111111"))
        """

        XCTAssertEqual(
            ProviderSessionNameParser.codexThreadName(inIndex: index, threadID: Self.codexThreadID),
            "Sidebar rows and hover cards"
        )
        XCTAssertNil(
            ProviderSessionNameParser.codexThreadName(
                inIndex: index,
                threadID: "019993ea-9999-9999-9999-999999999999"
            )
        )
        XCTAssertNil(
            ProviderSessionNameParser.codexThreadName(inIndex: index, threadID: " ")
        )
    }

    func testCodexThreadIndexSkipsMalformedRecordWithoutLosingALaterName() {
        let index = """
        \(codexThreadLine(name: "Earlier name", threadID: Self.codexThreadID))
        {"id":"\(Self.codexThreadID)","thread_name":"Half writ
        \(codexThreadLine(name: "Later name", threadID: Self.codexThreadID))
        """

        XCTAssertEqual(
            ProviderSessionNameParser.codexThreadName(inIndex: index, threadID: Self.codexThreadID),
            "Later name"
        )
    }

    // MARK: - Reader file access

    func testReadNameReturnsNilForMissingEmptyAndNonRegularPaths() async throws {
        let directory = try makeTemporaryDirectory()
        let reader = ProviderSessionNameReader()

        let missingPath = directory.appendingPathComponent("absent.jsonl").path
        let missingTranscriptName = await reader.readName(
            from: .claudeTranscript(path: missingPath, nativeSessionID: Self.claudeSessionID)
        )
        let missingIndexName = await reader.readName(
            from: .codexThreadIndex(path: missingPath, threadID: Self.codexThreadID)
        )
        XCTAssertNil(missingTranscriptName)
        XCTAssertNil(missingIndexName)

        let emptyPath = try write("", named: "empty.jsonl", in: directory)
        let emptyTranscriptName = await reader.readName(
            from: .claudeTranscript(path: emptyPath, nativeSessionID: Self.claudeSessionID)
        )
        let emptyIndexName = await reader.readName(
            from: .codexThreadIndex(path: emptyPath, threadID: Self.codexThreadID)
        )
        XCTAssertNil(emptyTranscriptName)
        XCTAssertNil(emptyIndexName)

        // Opening a directory (or a FIFO) here would stall every later refresh
        // for the session, so a non-regular path resolves to "no name".
        let directoryName = await reader.readName(
            from: .claudeTranscript(path: directory.path, nativeSessionID: Self.claudeSessionID)
        )
        XCTAssertNil(directoryName)
    }

    func testReadNameFindsWholeFileRecordsForBothProviders() async throws {
        let directory = try makeTemporaryDirectory()
        let reader = ProviderSessionNameReader()

        let transcriptPath = try write(
            """
            {"type":"user","message":{"role":"user","content":"rebuild the sidebar rows"}}
            \(claudeTitleLine(name: "Sidebar session row rebuild", sessionID: Self.claudeSessionID))

            """,
            named: "transcript.jsonl",
            in: directory
        )
        let indexPath = try write(
            """
            \(codexThreadLine(name: "Another thread", threadID: "019993ea-0000-0000-0000-000000000000"))
            \(codexThreadLine(name: "Sidebar rows and hover cards", threadID: Self.codexThreadID))

            """,
            named: "session_index.jsonl",
            in: directory
        )

        let claudeName = await reader.readName(
            from: .claudeTranscript(path: transcriptPath, nativeSessionID: Self.claudeSessionID)
        )
        let codexName = await reader.readName(
            from: .codexThreadIndex(path: indexPath, threadID: Self.codexThreadID)
        )

        XCTAssertEqual(claudeName, "Sidebar session row rebuild")
        XCTAssertEqual(codexName, "Sidebar rows and hover cards")
    }

    func testClaudeTailReadDiscardsThePartialFirstLineItStartsIn() async throws {
        let directory = try makeTemporaryDirectory()
        let reader = ProviderSessionNameReader()
        // The fragment is a complete title record for one session that only
        // exists because the tail read cuts its line in half. Parsing it would
        // hand the row a name the transcript never recorded on its own line.
        let fragment = claudeTitleLine(name: "Fragment name", sessionID: Self.claudeSessionID)
        let otherSessionID = "11111111-2222-3333-4444-555555555555"
        let laterPrefix = #"{"type":"ai-title","aiTitle":"Other session","sessionId":"\#(otherSessionID)","pad":""#
        let laterSuffix = #""}"#
        // Place the fragment's opening brace exactly on the tail boundary.
        let padCount = ProviderSessionNameParser.maximumClaudeTranscriptTailBytes
            - (fragment.utf8.count + 1 + laterPrefix.utf8.count + laterSuffix.utf8.count + 1)
        XCTAssertGreaterThan(padCount, 0)
        let laterLine = laterPrefix + String(repeating: "x", count: padCount) + laterSuffix
        let leading = #"{"type":"assistant","message":{"role":"assistant","content":"Reading."}} "#
        let transcriptPath = try write(
            leading + fragment + "\n" + laterLine + "\n",
            named: "long-transcript.jsonl",
            in: directory
        )

        let fragmentSessionName = await reader.readName(
            from: .claudeTranscript(path: transcriptPath, nativeSessionID: Self.claudeSessionID)
        )
        let laterSessionName = await reader.readName(
            from: .claudeTranscript(path: transcriptPath, nativeSessionID: otherSessionID)
        )

        XCTAssertNil(
            fragmentSessionName,
            "The line the tail read starts inside must be discarded, not parsed"
        )
        XCTAssertEqual(
            laterSessionName,
            "Other session",
            "Dropping the partial first line must not lose a later complete record"
        )
    }

    // MARK: - Source resolution

    func testSourceUsesTheReportedTranscriptForClaude() {
        XCTAssertEqual(
            ProviderSessionNameReader.source(
                agent: .claude,
                nativeSessionID: "  \(Self.claudeSessionID)  ",
                sessionFilePath: "  /transcripts/project/\(Self.claudeSessionID).jsonl  ",
                environment: [:],
                homeDirectoryPath: "/Users/tester"
            ),
            .claudeTranscript(
                path: "/transcripts/project/\(Self.claudeSessionID).jsonl",
                nativeSessionID: Self.claudeSessionID
            )
        )
        XCTAssertNil(
            ProviderSessionNameReader.source(
                agent: .claude,
                nativeSessionID: Self.claudeSessionID,
                sessionFilePath: "   ",
                environment: [:],
                homeDirectoryPath: "/Users/tester"
            )
        )
    }

    func testSourceResolvesCodexThreadIndexFromCodexHomeAndIgnoresTheRolloutPath() {
        // The rollout file the hook reports does not carry the thread name.
        XCTAssertEqual(
            ProviderSessionNameReader.source(
                agent: .codex,
                nativeSessionID: Self.codexThreadID,
                sessionFilePath: "/rollouts/2026/09/17/rollout-\(Self.codexThreadID).jsonl",
                environment: ["CODEX_HOME": "/Volumes/work/.codex-alt"],
                homeDirectoryPath: "/Users/tester"
            ),
            .codexThreadIndex(
                path: "/Volumes/work/.codex-alt/session_index.jsonl",
                threadID: Self.codexThreadID
            )
        )
        for codexHome in ["", "   ", "relative/.codex"] {
            XCTAssertEqual(
                ProviderSessionNameReader.source(
                    agent: .codex,
                    nativeSessionID: Self.codexThreadID,
                    sessionFilePath: "",
                    environment: ["CODEX_HOME": codexHome],
                    homeDirectoryPath: "/Users/tester"
                ),
                .codexThreadIndex(
                    path: "/Users/tester/.codex/session_index.jsonl",
                    threadID: Self.codexThreadID
                ),
                "A CODEX_HOME that is not an absolute path must fall back to ~/.codex"
            )
        }
        XCTAssertEqual(
            ProviderSessionNameReader.source(
                agent: .codex,
                nativeSessionID: Self.codexThreadID,
                sessionFilePath: "",
                environment: [:],
                homeDirectoryPath: "/Users/tester"
            ),
            .codexThreadIndex(
                path: "/Users/tester/.codex/session_index.jsonl",
                threadID: Self.codexThreadID
            )
        )
    }

    func testSourceIsAbsentForUnsupportedAgentsAndBlankSessionIDs() {
        for agent in [AgentKind.opencode, .cursor, .pi, .processWatch] {
            XCTAssertNil(
                ProviderSessionNameReader.source(
                    agent: agent,
                    nativeSessionID: Self.codexThreadID,
                    sessionFilePath: "/transcripts/session.jsonl",
                    environment: [:],
                    homeDirectoryPath: "/Users/tester"
                ),
                "\(agent.rawValue) generates no session name"
            )
        }
        for agent in [AgentKind.claude, .codex] {
            XCTAssertNil(
                ProviderSessionNameReader.source(
                    agent: agent,
                    nativeSessionID: "   ",
                    sessionFilePath: "/transcripts/session.jsonl",
                    environment: [:],
                    homeDirectoryPath: "/Users/tester"
                )
            )
        }
    }

    // MARK: - Fixtures

    private func claudeTitleLine(name: String, sessionID: String) -> String {
        #"{"type":"ai-title","aiTitle":"\#(name)","sessionId":"\#(sessionID)","timestamp":"2026-09-17T20:00:00.000Z"}"#
    }

    private func codexThreadLine(name: String, threadID: String) -> String {
        #"{"id":"\#(threadID)","thread_name":"\#(name)","updated_at":"2026-09-17T20:00:00Z"}"#
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-session-name-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func write(_ contents: String, named name: String, in directory: URL) throws -> String {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try Data(contents.utf8).write(to: url)
        return url.path
    }
}
