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
            claudeProjectsDirectory: fixture.claudeProjectsURL,
            codexShellSnapshotsDirectory: fixture.codexShellSnapshotsURL
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
    func scannerFindsCodexResumeFromShellSnapshotWhenRolloutIsOldAndCwdDiffers() async throws {
        let fixture = try makeNativeSessionScannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let launchStart = Date().addingTimeInterval(-5)
        let sessionID = "019da2ea-82fe-7842-9e86-b15a403e8352"
        let panelID = UUID()
        let otherCWDURL = fixture.rootURL.appendingPathComponent("other-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: otherCWDURL, withIntermediateDirectories: true)
        let sessionURL = fixture.codexSessionsURL
            .appendingPathComponent("2026/04/18", isDirectory: true)
            .appendingPathComponent("rollout-2026-04-18T16-26-11-\(sessionID).jsonl", isDirectory: false)
        try writeCodexSession(id: sessionID, cwd: otherCWDURL.path, to: sessionURL)
        try writeCodexShellSnapshot(id: sessionID, managedSessionID: "managed-1", panelID: panelID, to: fixture.codexShellSnapshotsURL)

        let scanner = ManagedAgentNativeSessionFileScanner(
            codexSessionsDirectory: fixture.codexSessionsURL,
            claudeProjectsDirectory: fixture.claudeProjectsURL,
            codexShellSnapshotsDirectory: fixture.codexShellSnapshotsURL
        )
        let candidates = await scanner.candidates(
            for: ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-1",
                agent: .codex,
                panelID: panelID,
                cwd: fixture.cwdURL.path,
                launchStart: launchStart
            )
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?.agent == .codex)
        #expect(candidates.first?.nativeSessionID == sessionID)
        #expect(candidates.first?.sessionFilePath == sessionURL.path)
        #expect(candidates.first?.cwd == fixture.cwdURL.path)
    }

    @Test
    func scannerIgnoresStaleCodexShellSnapshot() async throws {
        let fixture = try makeNativeSessionScannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let launchStart = Date().addingTimeInterval(60)
        let sessionID = "019da2ea-82fe-7842-9e86-b15a403e8352"
        let panelID = UUID()
        let sessionURL = fixture.codexSessionsURL.appendingPathComponent("rollout-\(sessionID).jsonl")
        try writeCodexSession(id: sessionID, cwd: fixture.cwdURL.path, to: sessionURL)
        try writeCodexShellSnapshot(id: sessionID, managedSessionID: "managed-1", panelID: panelID, to: fixture.codexShellSnapshotsURL)

        let scanner = ManagedAgentNativeSessionFileScanner(
            codexSessionsDirectory: fixture.codexSessionsURL,
            claudeProjectsDirectory: fixture.claudeProjectsURL,
            codexShellSnapshotsDirectory: fixture.codexShellSnapshotsURL
        )
        let candidates = await scanner.candidates(
            for: ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-1",
                agent: .codex,
                panelID: panelID,
                cwd: fixture.cwdURL.path,
                launchStart: launchStart
            )
        )

        #expect(candidates.isEmpty)
    }

    @Test
    func scannerDefersDirectCodexSessionBeforeFallbackDelay() async throws {
        let fixture = try makeNativeSessionScannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let launchStart = Date()
        let sessionID = "019da2ea-82fe-7842-9e86-b15a403e8352"
        let sessionURL = fixture.codexSessionsURL.appendingPathComponent("rollout-\(sessionID).jsonl")
        try writeCodexSession(id: sessionID, cwd: fixture.cwdURL.path, to: sessionURL)
        try FileManager.default.setAttributes(
            [.modificationDate: launchStart.addingTimeInterval(1)],
            ofItemAtPath: sessionURL.path
        )

        let scanner = ManagedAgentNativeSessionFileScanner(
            codexSessionsDirectory: fixture.codexSessionsURL,
            claudeProjectsDirectory: fixture.claudeProjectsURL,
            codexShellSnapshotsDirectory: fixture.codexShellSnapshotsURL,
            nowProvider: { launchStart.addingTimeInterval(5) }
        )
        let candidates = await scanner.candidates(
            for: ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-1",
                agent: .codex,
                panelID: UUID(),
                cwd: fixture.cwdURL.path,
                launchStart: launchStart
            )
        )

        #expect(candidates.isEmpty)
    }

    @Test
    func scannerUsesDirectCodexSessionAfterFallbackDelay() async throws {
        let fixture = try makeNativeSessionScannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let launchStart = Date()
        let sessionID = "019da2ea-82fe-7842-9e86-b15a403e8352"
        let sessionURL = fixture.codexSessionsURL.appendingPathComponent("rollout-\(sessionID).jsonl")
        try writeCodexSession(id: sessionID, cwd: fixture.cwdURL.path, to: sessionURL)
        try FileManager.default.setAttributes(
            [.modificationDate: launchStart.addingTimeInterval(1)],
            ofItemAtPath: sessionURL.path
        )

        let scanner = ManagedAgentNativeSessionFileScanner(
            codexSessionsDirectory: fixture.codexSessionsURL,
            claudeProjectsDirectory: fixture.claudeProjectsURL,
            codexShellSnapshotsDirectory: fixture.codexShellSnapshotsURL,
            nowProvider: { launchStart.addingTimeInterval(31) }
        )
        let candidates = await scanner.candidates(
            for: ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-1",
                agent: .codex,
                panelID: UUID(),
                cwd: fixture.cwdURL.path,
                launchStart: launchStart
            )
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?.nativeSessionID == sessionID)
        #expect(candidates.first?.sessionFilePath == sessionURL.path)
    }

    @Test
    func scannerFindsCodexShellSnapshotAfterDirectFallbackDelay() async throws {
        let fixture = try makeNativeSessionScannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let launchStart = Date()
        let sessionID = "019da2ea-82fe-7842-9e86-b15a403e8352"
        let panelID = UUID()
        let otherCWDURL = fixture.rootURL.appendingPathComponent("other-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: otherCWDURL, withIntermediateDirectories: true)
        let sessionURL = fixture.codexSessionsURL.appendingPathComponent("rollout-\(sessionID).jsonl")
        try writeCodexSession(id: sessionID, cwd: otherCWDURL.path, to: sessionURL)
        try writeCodexShellSnapshot(id: sessionID, managedSessionID: "managed-1", panelID: panelID, to: fixture.codexShellSnapshotsURL)
        let snapshotURL = fixture.codexShellSnapshotsURL
            .appendingPathComponent("\(sessionID).1778990848959872000.sh")
        try FileManager.default.setAttributes(
            [.modificationDate: launchStart.addingTimeInterval(45)],
            ofItemAtPath: snapshotURL.path
        )

        let scanner = ManagedAgentNativeSessionFileScanner(
            codexSessionsDirectory: fixture.codexSessionsURL,
            claudeProjectsDirectory: fixture.claudeProjectsURL,
            codexShellSnapshotsDirectory: fixture.codexShellSnapshotsURL,
            nowProvider: { launchStart.addingTimeInterval(45) }
        )
        let candidates = await scanner.candidates(
            for: ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-1",
                agent: .codex,
                panelID: panelID,
                cwd: fixture.cwdURL.path,
                launchStart: launchStart
            )
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?.nativeSessionID == sessionID)
        #expect(candidates.first?.sessionFilePath == sessionURL.path)
        #expect(candidates.first?.cwd == fixture.cwdURL.path)
    }

    @Test
    func scannerIgnoresCodexShellSnapshotFromDifferentManagedSession() async throws {
        let fixture = try makeNativeSessionScannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let sessionID = "019da2ea-82fe-7842-9e86-b15a403e8352"
        let panelID = UUID()
        let otherCWDURL = fixture.rootURL.appendingPathComponent("other-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: otherCWDURL, withIntermediateDirectories: true)
        let sessionURL = fixture.codexSessionsURL.appendingPathComponent("rollout-\(sessionID).jsonl")
        try writeCodexSession(id: sessionID, cwd: otherCWDURL.path, to: sessionURL)
        try writeCodexShellSnapshot(
            id: sessionID,
            managedSessionID: "other-managed-session",
            panelID: panelID,
            to: fixture.codexShellSnapshotsURL
        )

        let scanner = ManagedAgentNativeSessionFileScanner(
            codexSessionsDirectory: fixture.codexSessionsURL,
            claudeProjectsDirectory: fixture.claudeProjectsURL,
            codexShellSnapshotsDirectory: fixture.codexShellSnapshotsURL
        )
        let candidates = await scanner.candidates(
            for: ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-1",
                agent: .codex,
                panelID: panelID,
                cwd: fixture.cwdURL.path,
                launchStart: Date().addingTimeInterval(-5)
            )
        )

        #expect(candidates.isEmpty)
    }

    @Test
    func scannerIgnoresMalformedCodexShellSnapshotFilename() async throws {
        let fixture = try makeNativeSessionScannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let sessionID = "019da2ea-82fe-7842-9e86-b15a403e8352"
        let otherCWDURL = fixture.rootURL.appendingPathComponent("other-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: otherCWDURL, withIntermediateDirectories: true)
        let sessionURL = fixture.codexSessionsURL.appendingPathComponent("rollout-\(sessionID).jsonl")
        try writeCodexSession(id: sessionID, cwd: otherCWDURL.path, to: sessionURL)
        try FileManager.default.createDirectory(at: fixture.codexShellSnapshotsURL, withIntermediateDirectories: true)
        try Data("# Snapshot file\n".utf8).write(
            to: fixture.codexShellSnapshotsURL.appendingPathComponent("not-a-session.123.sh")
        )

        let scanner = ManagedAgentNativeSessionFileScanner(
            codexSessionsDirectory: fixture.codexSessionsURL,
            claudeProjectsDirectory: fixture.claudeProjectsURL,
            codexShellSnapshotsDirectory: fixture.codexShellSnapshotsURL
        )
        let candidates = await scanner.candidates(
            for: ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-1",
                agent: .codex,
                panelID: UUID(),
                cwd: fixture.cwdURL.path,
                launchStart: Date().addingTimeInterval(-5)
            )
        )

        #expect(candidates.isEmpty)
    }

    @Test
    func scannerLeavesMultipleCodexShellSnapshotMatchesAmbiguous() async throws {
        let fixture = try makeNativeSessionScannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let launchStart = Date().addingTimeInterval(-5)
        let panelID = UUID()
        let sessionIDs = [
            "019da2ea-82fe-7842-9e86-b15a403e8352",
            "019e3419-94d0-7921-8db3-1118bc90998f",
        ]
        let otherCWDURL = fixture.rootURL.appendingPathComponent("other-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: otherCWDURL, withIntermediateDirectories: true)

        for sessionID in sessionIDs {
            try writeCodexSession(
                id: sessionID,
                cwd: otherCWDURL.path,
                to: fixture.codexSessionsURL.appendingPathComponent("rollout-\(sessionID).jsonl")
            )
            try writeCodexShellSnapshot(
                id: sessionID,
                managedSessionID: "managed-1",
                panelID: panelID,
                to: fixture.codexShellSnapshotsURL
            )
        }

        let scanner = ManagedAgentNativeSessionFileScanner(
            codexSessionsDirectory: fixture.codexSessionsURL,
            claudeProjectsDirectory: fixture.claudeProjectsURL,
            codexShellSnapshotsDirectory: fixture.codexShellSnapshotsURL
        )
        let candidates = await scanner.candidates(
            for: ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-1",
                agent: .codex,
                panelID: panelID,
                cwd: fixture.cwdURL.path,
                launchStart: launchStart
            )
        )

        #expect(candidates.count == 2)
    }

    @Test
    func scannerPrefersCodexShellSnapshotOverDirectSession() async throws {
        let fixture = try makeNativeSessionScannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let launchStart = Date().addingTimeInterval(-5)
        let directSessionID = "019da2ea-82fe-7842-9e86-b15a403e8352"
        let snapshotSessionID = "019e3419-94d0-7921-8db3-1118bc90998f"
        let panelID = UUID()
        let directSessionURL = fixture.codexSessionsURL.appendingPathComponent("rollout-\(directSessionID).jsonl")
        try writeCodexSession(id: directSessionID, cwd: fixture.cwdURL.path, to: directSessionURL)
        try FileManager.default.setAttributes(
            [.modificationDate: launchStart.addingTimeInterval(1)],
            ofItemAtPath: directSessionURL.path
        )

        let otherCWDURL = fixture.rootURL.appendingPathComponent("other-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: otherCWDURL, withIntermediateDirectories: true)
        let snapshotSessionURL = fixture.codexSessionsURL.appendingPathComponent("rollout-\(snapshotSessionID).jsonl")
        try writeCodexSession(id: snapshotSessionID, cwd: otherCWDURL.path, to: snapshotSessionURL)
        try writeCodexShellSnapshot(
            id: snapshotSessionID,
            managedSessionID: "managed-1",
            panelID: panelID,
            to: fixture.codexShellSnapshotsURL
        )

        let scanner = ManagedAgentNativeSessionFileScanner(
            codexSessionsDirectory: fixture.codexSessionsURL,
            claudeProjectsDirectory: fixture.claudeProjectsURL,
            codexShellSnapshotsDirectory: fixture.codexShellSnapshotsURL,
            nowProvider: { launchStart.addingTimeInterval(31) }
        )
        let candidates = await scanner.candidates(
            for: ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-1",
                agent: .codex,
                panelID: panelID,
                cwd: fixture.cwdURL.path,
                launchStart: launchStart
            )
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?.nativeSessionID == snapshotSessionID)
        #expect(candidates.first?.sessionFilePath == snapshotSessionURL.path)
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
            claudeProjectsDirectory: fixture.claudeProjectsURL,
            codexShellSnapshotsDirectory: fixture.codexShellSnapshotsURL
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
    codexShellSnapshotsURL: URL,
    claudeProjectsURL: URL
) {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("toastty-native-session-observer-\(UUID().uuidString)", isDirectory: true)
    let cwdURL = rootURL.appendingPathComponent("repo", isDirectory: true)
    let codexSessionsURL = rootURL.appendingPathComponent("codex-sessions", isDirectory: true)
    let codexShellSnapshotsURL = rootURL.appendingPathComponent("codex-shell-snapshots", isDirectory: true)
    let claudeProjectsURL = rootURL.appendingPathComponent("claude-projects", isDirectory: true)
    try FileManager.default.createDirectory(at: cwdURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: codexSessionsURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: codexShellSnapshotsURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: claudeProjectsURL, withIntermediateDirectories: true)
    return (rootURL, cwdURL, codexSessionsURL, codexShellSnapshotsURL, claudeProjectsURL)
}

private func writeCodexSession(id: String, cwd: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(
        #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)"}}"#.utf8
    ).write(to: url)
}

private func writeCodexShellSnapshot(
    id: String,
    managedSessionID: String,
    panelID: UUID,
    to directoryURL: URL
) throws {
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    try Data(
        """
        # Snapshot file
        export TOASTTY_SESSION_ID=\(managedSessionID)
        export TOASTTY_PANEL_ID=\(panelID.uuidString)

        """.utf8
    ).write(
        to: directoryURL.appendingPathComponent("\(id).1778990848959872000.sh")
    )
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
