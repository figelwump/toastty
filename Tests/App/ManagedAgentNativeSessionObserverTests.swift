import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct ManagedAgentNativeSessionObserverTests {
    @Test
    func scannerFindsExistingCodexSessionDuringCatchUp() async throws {
        let fixture = try makeNativeSessionScannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let launchStart = Date(timeIntervalSince1970: 1_700_000_000)
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_030)
        let panelID = UUID()
        let sessionID = "019e2823-f520-7690-91b6-cd84eb52dd8a"
        let sessionURL = fixture.codexSessionsURL
            .appendingPathComponent("2026/05/15", isDirectory: true)
            .appendingPathComponent("rollout-2026-05-15T10-00-00-\(sessionID).jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: sessionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            #"{"type":"session_meta","payload":{"id":"\#(sessionID)","cwd":"\#(fixture.cwdURL.path)"}}"#.utf8
        ).write(to: sessionURL)
        try FileManager.default.setAttributes(
            [.modificationDate: launchStart.addingTimeInterval(1)],
            ofItemAtPath: sessionURL.path
        )

        let scanner = ManagedAgentNativeSessionFileScanner(
            codexSessionsDirectory: fixture.codexSessionsURL,
            claudeProjectsDirectory: fixture.claudeProjectsURL
        )
        var recordsByPanelID: [UUID: ManagedAgentResumeRecord] = [:]
        let registry = ManagedAgentNativeSessionObserverRegistry(
            scanner: scanner,
            timing: ManagedAgentNativeSessionObserverTiming(
                pollIntervalNanoseconds: 10_000_000,
                timeout: 10
            ),
            nowProvider: { capturedAt },
            recordHandler: { panelID, record in
                recordsByPanelID[panelID] = record
            }
        )

        registry.startObservation(
            ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-1",
                agent: .codex,
                panelID: panelID,
                cwd: fixture.cwdURL.path,
                launchStart: launchStart
            )
        )

        try await waitForCondition {
            recordsByPanelID[panelID] != nil
        }

        let record = try #require(recordsByPanelID[panelID])
        #expect(record.agent == .codex)
        #expect(record.nativeSessionID == sessionID)
        #expect(record.sessionFilePath == sessionURL.path)
        #expect(record.cwd == fixture.cwdURL.path)
        #expect(record.capturedAt == capturedAt)
    }

    @Test
    func scannerFindsExistingClaudeSessionDuringCatchUp() async throws {
        let fixture = try makeNativeSessionScannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let launchStart = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionID = "db4f311b-12d0-4f61-ba81-0ae44ed10492"
        let projectDirectoryName = fixture.cwdURL.path.replacingOccurrences(of: "/", with: "-")
        let sessionURL = fixture.claudeProjectsURL
            .appendingPathComponent(projectDirectoryName, isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: sessionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            #"{"type":"permission-mode","sessionId":"\#(sessionID)","permissionMode":"default"}"#.utf8
        ).write(to: sessionURL)
        try FileManager.default.setAttributes(
            [.modificationDate: launchStart.addingTimeInterval(1)],
            ofItemAtPath: sessionURL.path
        )

        let scanner = ManagedAgentNativeSessionFileScanner(
            codexSessionsDirectory: fixture.codexSessionsURL,
            claudeProjectsDirectory: fixture.claudeProjectsURL
        )
        let candidates = await scanner.candidates(
            for: ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-1",
                agent: .claude,
                panelID: UUID(),
                cwd: fixture.cwdURL.path,
                launchStart: launchStart
            )
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?.agent == .claude)
        #expect(candidates.first?.nativeSessionID == sessionID)
        #expect(candidates.first?.sessionFilePath == sessionURL.path)
    }

    @Test
    func observerTimeoutPreservesExistingRecord() {
        let launchStart = Date(timeIntervalSince1970: 1_700_000_000)
        let scanner = StubNativeSessionScanner(candidatesByManagedSessionID: [:])
        var recordCount = 0
        let registry = ManagedAgentNativeSessionObserverRegistry(
            scanner: scanner,
            timing: ManagedAgentNativeSessionObserverTiming(
                pollIntervalNanoseconds: 1_000_000,
                timeout: 30
            ),
            nowProvider: { launchStart.addingTimeInterval(31) },
            recordHandler: { _, _ in
                recordCount += 1
            }
        )

        registry.startObservation(
            ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-1",
                agent: .codex,
                panelID: UUID(),
                cwd: "/tmp/repo",
                launchStart: launchStart
            )
        )
        registry.expireTimedOutObservationsForTesting()

        #expect(recordCount == 0)
        #expect(registry.activeObservationCountForTesting == 0)
    }

    @Test
    func sameNativeSessionFileIsNotDoubleClaimedBySimultaneousObservers() async {
        let launchStart = Date(timeIntervalSince1970: 1_700_000_000)
        let candidate = ManagedAgentNativeSessionCandidate(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: "/tmp/codex-session.jsonl",
            cwd: "/tmp/repo",
            updatedAt: launchStart.addingTimeInterval(1)
        )
        let scanner = StubNativeSessionScanner(
            candidatesByManagedSessionID: [
                "managed-1": [candidate],
                "managed-2": [candidate],
            ]
        )
        var recordCount = 0
        let registry = ManagedAgentNativeSessionObserverRegistry(
            scanner: scanner,
            nowProvider: { launchStart.addingTimeInterval(2) },
            recordHandler: { _, _ in
                recordCount += 1
            }
        )

        registry.startObservation(
            ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-1",
                agent: .codex,
                panelID: UUID(),
                cwd: "/tmp/repo",
                launchStart: launchStart
            )
        )
        registry.startObservation(
            ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-2",
                agent: .codex,
                panelID: UUID(),
                cwd: "/tmp/repo",
                launchStart: launchStart
            )
        )
        await registry.evaluatePendingObservationsForTesting()

        #expect(recordCount == 0)
        #expect(registry.activeObservationCountForTesting == 2)
    }
}

private actor StubNativeSessionScanner: ManagedAgentNativeSessionScanning {
    let candidatesByManagedSessionID: [String: [ManagedAgentNativeSessionCandidate]]

    init(candidatesByManagedSessionID: [String: [ManagedAgentNativeSessionCandidate]]) {
        self.candidatesByManagedSessionID = candidatesByManagedSessionID
    }

    func candidates(for observation: ManagedAgentNativeSessionObservationContext) async -> [ManagedAgentNativeSessionCandidate] {
        candidatesByManagedSessionID[observation.managedSessionID] ?? []
    }
}

private func makeNativeSessionScannerFixture() throws -> (
    rootURL: URL,
    cwdURL: URL,
    codexSessionsURL: URL,
    claudeProjectsURL: URL
) {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("toastty-native-session-observer-\(UUID().uuidString)", isDirectory: true)
    let cwdURL = rootURL.appendingPathComponent("repo", isDirectory: true)
    let codexSessionsURL = rootURL.appendingPathComponent("codex-sessions", isDirectory: true)
    let claudeProjectsURL = rootURL.appendingPathComponent("claude-projects", isDirectory: true)
    try FileManager.default.createDirectory(at: cwdURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: codexSessionsURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: claudeProjectsURL, withIntermediateDirectories: true)
    return (rootURL, cwdURL, codexSessionsURL, claudeProjectsURL)
}

@MainActor
private func waitForCondition(
    timeout: TimeInterval = 2,
    condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("condition did not become true before timeout")
}
