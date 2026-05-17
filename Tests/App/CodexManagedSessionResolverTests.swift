import CoreState
import Foundation
import Testing
@testable import ToasttyApp

struct CodexManagedSessionResolverTests {
    @Test
    func resolvesReportedRolloutPathWithoutModificationTimeFilter() async throws {
        let fixture = try makeCodexResolverFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let launchStart = Date(timeIntervalSince1970: 1_800_000_100)
        let threadID = "019e316e-9f7f-7a33-aad9-33fe27b0f2cd"
        let rolloutURL = fixture.codexSessionsURL
            .appendingPathComponent("2026/05/16", isDirectory: true)
            .appendingPathComponent("rollout-2026-05-16T09-00-00-\(threadID).jsonl", isDirectory: false)
        try writeCodexSession(
            id: threadID,
            cwd: fixture.cwdURL.path,
            to: rolloutURL,
            modifiedAt: launchStart.addingTimeInterval(-60)
        )

        let resolver = CodexManagedSessionResolver(codexSessionsDirectory: fixture.codexSessionsURL)
        let record = await resolver.resumeRecord(
            threadID: threadID,
            rolloutPath: rolloutURL.path,
            expectedCWD: fixture.cwdURL.path,
            capturedAt: capturedAt
        )

        #expect(record?.agent == .codex)
        #expect(record?.nativeSessionID == threadID)
        #expect(record?.sessionFilePath == rolloutURL.path)
        #expect(record?.cwd == fixture.cwdURL.path)
        #expect(record?.capturedAt == capturedAt)
    }

    @Test
    func rejectsReportedRolloutPathWhenWorkingDirectoryDoesNotMatch() async throws {
        let fixture = try makeCodexResolverFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let threadID = "019e316e-9f7f-7a33-aad9-33fe27b0f2cd"
        let otherCWDURL = fixture.rootURL.appendingPathComponent("other-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: otherCWDURL, withIntermediateDirectories: true)
        let rolloutURL = fixture.codexSessionsURL
            .appendingPathComponent("rollout-\(threadID).jsonl", isDirectory: false)
        try writeCodexSession(id: threadID, cwd: otherCWDURL.path, to: rolloutURL)

        let resolver = CodexManagedSessionResolver(codexSessionsDirectory: fixture.codexSessionsURL)
        let record = await resolver.resumeRecord(
            threadID: threadID,
            rolloutPath: rolloutURL.path,
            expectedCWD: fixture.cwdURL.path,
            capturedAt: Date()
        )

        #expect(record == nil)
    }

    @Test
    func searchesCodexSessionDirectoryWhenRolloutPathIsUnavailable() async throws {
        let fixture = try makeCodexResolverFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let threadID = "019e316e-9f7f-7a33-aad9-33fe27b0f2cd"
        let rolloutURL = fixture.codexSessionsURL
            .appendingPathComponent("rollout-\(threadID).jsonl", isDirectory: false)
        try writeCodexSession(id: threadID, cwd: fixture.cwdURL.path, to: rolloutURL)

        let resolver = CodexManagedSessionResolver(codexSessionsDirectory: fixture.codexSessionsURL)
        let record = await resolver.resumeRecord(
            threadID: threadID,
            rolloutPath: nil,
            expectedCWD: fixture.cwdURL.path,
            capturedAt: capturedAt
        )

        #expect(record?.nativeSessionID == threadID)
        #expect(record?.sessionFilePath == rolloutURL.path)
        #expect(record?.capturedAt == capturedAt)
    }

    @Test
    func rejectsAmbiguousDirectorySearchMatches() async throws {
        let fixture = try makeCodexResolverFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let threadID = "019e316e-9f7f-7a33-aad9-33fe27b0f2cd"
        try writeCodexSession(
            id: threadID,
            cwd: fixture.cwdURL.path,
            to: fixture.codexSessionsURL.appendingPathComponent("a-\(threadID).jsonl", isDirectory: false)
        )
        try writeCodexSession(
            id: threadID,
            cwd: fixture.cwdURL.path,
            to: fixture.codexSessionsURL.appendingPathComponent("b-\(threadID).jsonl", isDirectory: false)
        )

        let resolver = CodexManagedSessionResolver(codexSessionsDirectory: fixture.codexSessionsURL)
        let record = await resolver.resumeRecord(
            threadID: threadID,
            rolloutPath: nil,
            expectedCWD: fixture.cwdURL.path,
            capturedAt: Date()
        )

        #expect(record == nil)
    }
}

private func makeCodexResolverFixture() throws -> (
    rootURL: URL,
    cwdURL: URL,
    codexSessionsURL: URL
) {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("toastty-codex-resolver-\(UUID().uuidString)", isDirectory: true)
    let cwdURL = rootURL.appendingPathComponent("repo", isDirectory: true)
    let codexSessionsURL = rootURL.appendingPathComponent("codex-sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: cwdURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: codexSessionsURL, withIntermediateDirectories: true)
    return (rootURL, cwdURL, codexSessionsURL)
}

private func writeCodexSession(
    id: String,
    cwd: String,
    to url: URL,
    modifiedAt: Date? = nil
) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(
        #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)"}}"#.utf8
    ).write(to: url)
    if let modifiedAt {
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }
}
