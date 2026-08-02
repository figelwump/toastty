import CodexReconciliation
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct ManagedAgentNativeSessionObserverTests {
    @Test
    func resumeRecordAppliesCurrentScopedSessionScope() {
        let sessionRuntimeStore = SessionRuntimeStore()
        let panelID = UUID()
        let record = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: "/tmp/codex-session.jsonl",
            cwd: "/tmp/repo",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        sessionRuntimeStore.startSession(
            sessionID: "managed-1",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/tmp/repo",
            repoRoot: "/tmp/repo",
            scopedWorkspaceIDs: [],
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let scopedRecord = ManagedAgentNativeSessionObserverRegistry.resumeRecord(
            record,
            applyingScopeFrom: sessionRuntimeStore,
            managedSessionID: "managed-1",
            panelID: panelID
        )

        #expect(scopedRecord?.scopedWorkspaceIDs == Set<UUID>())
    }

    @Test
    func resumeRecordIsDroppedWhenManagedSessionIsMissing() {
        let sessionRuntimeStore = SessionRuntimeStore()
        let record = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: "/tmp/codex-session.jsonl",
            cwd: "/tmp/repo",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            scopedWorkspaceIDs: []
        )

        let scopedRecord = ManagedAgentNativeSessionObserverRegistry.resumeRecord(
            record,
            applyingScopeFrom: sessionRuntimeStore,
            managedSessionID: "managed-1",
            panelID: UUID()
        )

        #expect(scopedRecord == nil)
    }

    @Test
    func ownershipSnapshotClassifiesPersistedActiveAndPreviousOwners() throws {
        let fixture = makeResumeRecordAppState(
            nativeSessionIDs: ["019e2823-f520-7690-91b6-cd84eb52dd8a"]
        )
        let nativeSessionID = try #require(NativeSessionID("019e2823-f520-7690-91b6-cd84eb52dd8a"))
        let rolloutPath = try #require(RolloutPath("/tmp/codex-0.jsonl"))

        let persistedOnly = ManagedAgentNativeSessionObserverRegistry.codexOwnershipState(
            appState: fixture.appState,
            sessionRegistry: nil
        )
        #expect(
            persistedOnly.ownerByNativeSessionID[nativeSessionID]
                == .inactivePersistedClaim(rolloutPath: rolloutPath)
        )

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var sessionRegistry = SessionRegistry()
        sessionRegistry.startSession(
            sessionID: "managed-1",
            agent: .codex,
            panelID: fixture.panelIDs[0],
            windowID: UUID(),
            workspaceID: fixture.workspaceID,
            cwd: "/tmp/repo",
            repoRoot: "/tmp/repo",
            at: now
        )
        let active = ManagedAgentNativeSessionObserverRegistry.codexOwnershipState(
            appState: fixture.appState,
            sessionRegistry: sessionRegistry
        )
        #expect(
            active.ownerByNativeSessionID[nativeSessionID]
                == .activeManaged(
                    managedSessionID: ManagedSessionID("managed-1")!,
                    rolloutPath: rolloutPath
                )
        )

        sessionRegistry.stopSession(sessionID: "managed-1", at: now.addingTimeInterval(1))
        let inactive = ManagedAgentNativeSessionObserverRegistry.codexOwnershipState(
            appState: fixture.appState,
            sessionRegistry: sessionRegistry
        )
        #expect(
            inactive.ownerByNativeSessionID[nativeSessionID]
                == .inactivePreviousManaged(
                    managedSessionID: ManagedSessionID("managed-1")!,
                    rolloutPath: rolloutPath
                )
        )
    }

    @Test
    func ownershipSnapshotMarksDuplicatePersistedOwnersAsConflicted() throws {
        let nativeSessionID = "019e2823-f520-7690-91b6-cd84eb52dd8a"
        let fixture = makeResumeRecordAppState(nativeSessionIDs: [nativeSessionID, nativeSessionID])
        let typedNativeSessionID = try #require(NativeSessionID(nativeSessionID))

        let ownershipState = ManagedAgentNativeSessionObserverRegistry.codexOwnershipState(
            appState: fixture.appState,
            sessionRegistry: nil
        )

        #expect(ownershipState.ownerByNativeSessionID[typedNativeSessionID] == nil)
        #expect(ownershipState.conflictedNativeSessionIDs == [typedNativeSessionID])
    }

    @Test
    func ownershipSnapshotDoesNotMixProviderNamespaces() throws {
        let nativeSessionID = "shared-provider-spelling"
        var fixture = makeResumeRecordAppState(nativeSessionIDs: [nativeSessionID])
        let workspaceID = fixture.workspaceID
        var workspace = fixture.appState.workspacesByID[workspaceID]!
        let tabID = workspace.resolvedSelectedTabID!
        var tab = workspace.tabsByID[tabID]!
        tab.panels[UUID()] = .terminal(
            TerminalPanelState(
                title: "Claude",
                shell: "zsh",
                cwd: "/tmp/repo",
                resumeRecord: ManagedAgentResumeRecord(
                    agent: .claude,
                    nativeSessionID: nativeSessionID,
                    sessionFilePath: "/tmp/claude.jsonl",
                    cwd: "/tmp/repo",
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            )
        )
        workspace.tabsByID[tabID] = tab
        fixture.appState.workspacesByID[workspaceID] = workspace
        let typedNativeSessionID = try #require(NativeSessionID(nativeSessionID))

        let codexOwnership = ManagedAgentNativeSessionObserverRegistry.codexOwnershipState(
            appState: fixture.appState,
            sessionRegistry: nil
        )

        #expect(codexOwnership.conflictedNativeSessionIDs.isEmpty)
        #expect(
            codexOwnership.ownerByNativeSessionID[typedNativeSessionID]
                == .inactivePersistedClaim(rolloutPath: RolloutPath("/tmp/codex-0.jsonl"))
        )
    }

    @Test
    func observerCapturesCodexSessionFromShellSnapshot() async throws {
        let fixture = try makeNativeSessionScannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let launchStart = Date(timeIntervalSince1970: 1_700_000_000)
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_030)
        let panelID = UUID()
        let sessionID = "019e2823-f520-7690-91b6-cd84eb52dd8a"
        let sessionURL = fixture.codexSessionsURL
            .appendingPathComponent("2026/05/15", isDirectory: true)
            .appendingPathComponent("rollout-2026-05-15T10-00-00-\(sessionID).jsonl", isDirectory: false)
        try writeCodexSession(id: sessionID, cwd: fixture.cwdURL.path, to: sessionURL)
        try writeCodexShellSnapshot(
            id: sessionID,
            managedSessionID: "managed-1",
            panelID: panelID,
            to: fixture.codexShellSnapshotsURL
        )
        let snapshotURL = fixture.codexShellSnapshotsURL
            .appendingPathComponent("\(sessionID).1778990848959872000.sh")
        try FileManager.default.setAttributes(
            [.modificationDate: launchStart.addingTimeInterval(1)],
            ofItemAtPath: snapshotURL.path
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
            recordHandler: { _, panelID, record in
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
    func scannerNeverUsesCwdOnlyCodexSessionWithoutShellSnapshot() async throws {
        let fixture = try makeNativeSessionScannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let launchStart = Date().addingTimeInterval(-45)
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
            codexShellSnapshotsDirectory: fixture.codexShellSnapshotsURL
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
    func scannerReturnsNoCandidateWhenSnapshotRolloutIsMissing() async throws {
        let fixture = try makeNativeSessionScannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let launchStart = Date()
        let panelID = UUID()
        let snapshotSessionID = "019e6167-f149-7031-9229-aa24f9976928"
        let activeSameCWDSessionID = "019e6084-ab6d-7882-aa3b-20ea5f3507ec"
        let activeSameCWDSessionURL = fixture.codexSessionsURL
            .appendingPathComponent("rollout-\(activeSameCWDSessionID).jsonl")
        try writeCodexSession(id: activeSameCWDSessionID, cwd: fixture.cwdURL.path, to: activeSameCWDSessionURL)
        try FileManager.default.setAttributes(
            [.modificationDate: launchStart.addingTimeInterval(1)],
            ofItemAtPath: activeSameCWDSessionURL.path
        )
        try writeCodexShellSnapshot(
            id: snapshotSessionID,
            managedSessionID: "managed-1",
            panelID: panelID,
            to: fixture.codexShellSnapshotsURL
        )
        let snapshotURL = fixture.codexShellSnapshotsURL
            .appendingPathComponent("\(snapshotSessionID).1778990848959872000.sh")
        try FileManager.default.setAttributes(
            [.modificationDate: launchStart.addingTimeInterval(1)],
            ofItemAtPath: snapshotURL.path
        )

        let scanner = ManagedAgentNativeSessionFileScanner(
            codexSessionsDirectory: fixture.codexSessionsURL,
            claudeProjectsDirectory: fixture.claudeProjectsURL,
            codexShellSnapshotsDirectory: fixture.codexShellSnapshotsURL
        )
        let scan = await scanner.scan(
            for: ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-1",
                agent: .codex,
                panelID: panelID,
                cwd: fixture.cwdURL.path,
                launchStart: launchStart
            )
        )

        #expect(scan.candidates.isEmpty)
        #expect(scan.summary.codexSnapshotCandidateCount == 0)
    }

    @Test
    func scannerFindsCodexShellSnapshotWrittenLate() async throws {
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
    func scannerPrefersCodexShellSnapshotOverSameCwdSessionActivity() async throws {
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
            recordHandler: { _, _, _ in
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
            recordHandler: { _, _, _ in
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

    @Test
    func acceptedSiblingIsNotAppliedAfterRecordHandlerCancelsIt() async {
        let launchStart = Date(timeIntervalSince1970: 1_700_000_000)
        let candidates = [
            "managed-1": ManagedAgentNativeSessionCandidate(
                agent: .codex,
                nativeSessionID: "native-1",
                sessionFilePath: "/tmp/codex-1.jsonl",
                cwd: "/tmp/repo",
                updatedAt: launchStart.addingTimeInterval(1)
            ),
            "managed-2": ManagedAgentNativeSessionCandidate(
                agent: .codex,
                nativeSessionID: "native-2",
                sessionFilePath: "/tmp/codex-2.jsonl",
                cwd: "/tmp/repo",
                updatedAt: launchStart.addingTimeInterval(1)
            ),
        ]
        let scanner = StubNativeSessionScanner(
            candidatesByManagedSessionID: candidates.mapValues { [$0] }
        )
        var recordCount = 0
        let registryBox = ManagedAgentNativeSessionObserverRegistryBox()
        let registry = ManagedAgentNativeSessionObserverRegistry(
            scanner: scanner,
            nowProvider: { launchStart.addingTimeInterval(2) },
            recordHandler: { acceptedSessionID, _, _ in
                recordCount += 1
                let siblingSessionID = acceptedSessionID == "managed-1" ? "managed-2" : "managed-1"
                registryBox.value?.cancelObservation(sessionID: siblingSessionID)
            }
        )
        registryBox.value = registry
        for managedSessionID in candidates.keys {
            registry.startObservation(
                ManagedAgentNativeSessionObservationContext(
                    managedSessionID: managedSessionID,
                    agent: .codex,
                    panelID: UUID(),
                    cwd: "/tmp/repo",
                    launchStart: launchStart
                )
            )
        }

        await registry.evaluatePendingObservationsForTesting()

        #expect(recordCount == 1)
        #expect(registry.activeObservationCountForTesting == 0)
    }

    @Test
    func exactDuplicateCandidatesAreAppliedOnce() async {
        let launchStart = Date(timeIntervalSince1970: 1_700_000_000)
        let candidate = ManagedAgentNativeSessionCandidate(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: "/tmp/codex-session.jsonl",
            cwd: "/tmp/repo",
            updatedAt: launchStart.addingTimeInterval(1)
        )
        let scanner = StubNativeSessionScanner(
            candidatesByManagedSessionID: ["managed-1": [candidate, candidate]]
        )
        var recordCount = 0
        let registry = ManagedAgentNativeSessionObserverRegistry(
            scanner: scanner,
            nowProvider: { launchStart.addingTimeInterval(2) },
            recordHandler: { _, _, _ in recordCount += 1 }
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

        await registry.evaluatePendingObservationsForTesting()

        #expect(recordCount == 1)
        #expect(registry.activeObservationCountForTesting == 0)
    }

    @Test
    func claudeExactDuplicateCandidatesRemainOnLegacyAmbiguityPolicy() async {
        let launchStart = Date(timeIntervalSince1970: 1_700_000_000)
        let candidate = ManagedAgentNativeSessionCandidate(
            agent: .claude,
            nativeSessionID: "claude-session-1",
            sessionFilePath: "/tmp/claude-session.jsonl",
            cwd: "/tmp/repo",
            updatedAt: launchStart.addingTimeInterval(1)
        )
        let scanner = StubNativeSessionScanner(
            candidatesByManagedSessionID: ["managed-claude": [candidate, candidate]]
        )
        var recordCount = 0
        let registry = ManagedAgentNativeSessionObserverRegistry(
            scanner: scanner,
            nowProvider: { launchStart.addingTimeInterval(2) },
            recordHandler: { _, _, _ in recordCount += 1 }
        )
        registry.startObservation(
            ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-claude",
                agent: .claude,
                panelID: UUID(),
                cwd: "/tmp/repo",
                launchStart: launchStart
            )
        )

        await registry.evaluatePendingObservationsForTesting()

        #expect(recordCount == 0)
        #expect(registry.activeObservationCountForTesting == 1)
    }

    @Test
    func claudeExpectedResumeStillReclaimsLegacyStaleOwner() async {
        let launchStart = Date(timeIntervalSince1970: 1_700_000_000)
        let observedPanelID = UUID()
        let candidate = ManagedAgentNativeSessionCandidate(
            agent: .claude,
            nativeSessionID: "claude-session-1",
            sessionFilePath: "/tmp/claude-session.jsonl",
            cwd: "/tmp/repo",
            updatedAt: launchStart.addingTimeInterval(1)
        )
        let scanner = StubNativeSessionScanner(
            candidatesByManagedSessionID: ["managed-claude": [candidate]]
        )
        var recordCount = 0
        let registry = ManagedAgentNativeSessionObserverRegistry(
            scanner: scanner,
            nowProvider: { launchStart.addingTimeInterval(2) },
            resumeRecordOwnerResolver: { _, _ in
                ManagedAgentNativeSessionResumeRecordOwner(panelID: UUID())
            },
            recordHandler: { _, _, _ in recordCount += 1 }
        )
        registry.startObservation(
            ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-claude",
                agent: .claude,
                panelID: observedPanelID,
                cwd: "/tmp/repo",
                launchStart: launchStart,
                expectedNativeSessionID: candidate.nativeSessionID
            )
        )

        await registry.evaluatePendingObservationsForTesting()

        #expect(recordCount == 1)
        #expect(registry.activeObservationCountForTesting == 0)
    }

    @Test
    func conflictingCandidatePathsRejectWithoutPartialMutation() async {
        let launchStart = Date(timeIntervalSince1970: 1_700_000_000)
        let nativeSessionID = "019e2823-f520-7690-91b6-cd84eb52dd8a"
        let candidates = ["one", "two"].map { suffix in
            ManagedAgentNativeSessionCandidate(
                agent: .codex,
                nativeSessionID: nativeSessionID,
                sessionFilePath: "/tmp/codex-\(suffix).jsonl",
                cwd: "/tmp/repo",
                updatedAt: launchStart.addingTimeInterval(1)
            )
        }
        let scanner = StubNativeSessionScanner(
            candidatesByManagedSessionID: ["managed-1": candidates]
        )
        var recordCount = 0
        let registry = ManagedAgentNativeSessionObserverRegistry(
            scanner: scanner,
            nowProvider: { launchStart.addingTimeInterval(2) },
            recordHandler: { _, _, _ in recordCount += 1 }
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

        await registry.evaluatePendingObservationsForTesting()

        #expect(recordCount == 0)
        #expect(registry.activeObservationCountForTesting == 1)
    }

    @Test
    func conflictingPersistedOwnersRejectWithoutMutation() async {
        let launchStart = Date(timeIntervalSince1970: 1_700_000_000)
        let candidate = ManagedAgentNativeSessionCandidate(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: "/tmp/codex-session.jsonl",
            cwd: "/tmp/repo",
            updatedAt: launchStart.addingTimeInterval(1)
        )
        let nativeSessionID = NativeSessionID(candidate.nativeSessionID)!
        let scanner = StubNativeSessionScanner(candidatesByManagedSessionID: ["managed-1": [candidate]])
        var recordCount = 0
        let registry = ManagedAgentNativeSessionObserverRegistry(
            scanner: scanner,
            nowProvider: { launchStart.addingTimeInterval(2) },
            ownershipStateProvider: {
                ManagedAgentNativeSessionOwnershipState(
                    ownerByNativeSessionID: [:],
                    conflictedNativeSessionIDs: [nativeSessionID]
                )
            },
            recordHandler: { _, _, _ in recordCount += 1 }
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

        await registry.evaluatePendingObservationsForTesting()

        #expect(recordCount == 0)
        #expect(registry.activeObservationCountForTesting == 1)
    }

    @Test
    func observerIgnoresCandidateThatDoesNotMatchExpectedNativeSessionID() async {
        let launchStart = Date(timeIntervalSince1970: 1_700_000_000)
        let candidate = ManagedAgentNativeSessionCandidate(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: "/tmp/codex-session.jsonl",
            cwd: "/tmp/repo",
            updatedAt: launchStart.addingTimeInterval(1)
        )
        let scanner = StubNativeSessionScanner(candidatesByManagedSessionID: ["managed-1": [candidate]])
        var recordCount = 0
        let registry = ManagedAgentNativeSessionObserverRegistry(
            scanner: scanner,
            nowProvider: { launchStart.addingTimeInterval(2) },
            recordHandler: { _, _, _ in
                recordCount += 1
            }
        )

        registry.startObservation(
            ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-1",
                agent: .codex,
                panelID: UUID(),
                cwd: "/tmp/repo",
                launchStart: launchStart,
                expectedNativeSessionID: "0195ffff-0000-7000-8000-000000000000"
            )
        )
        await registry.evaluatePendingObservationsForTesting()

        #expect(recordCount == 0)
        #expect(registry.activeObservationCountForTesting == 1)
    }

    @Test
    func observerCapturesCandidateMatchingExpectedNativeSessionID() async {
        let launchStart = Date(timeIntervalSince1970: 1_700_000_000)
        let expectedSessionID = "019e2823-f520-7690-91b6-cd84eb52dd8a"
        let expectedCandidate = ManagedAgentNativeSessionCandidate(
            agent: .codex,
            nativeSessionID: expectedSessionID,
            sessionFilePath: "/tmp/codex-expected.jsonl",
            cwd: "/tmp/repo",
            updatedAt: launchStart.addingTimeInterval(1)
        )
        let otherCandidate = ManagedAgentNativeSessionCandidate(
            agent: .codex,
            nativeSessionID: "019e3419-94d0-7921-8db3-1118bc90998f",
            sessionFilePath: "/tmp/codex-other.jsonl",
            cwd: "/tmp/repo",
            updatedAt: launchStart.addingTimeInterval(2)
        )
        let scanner = StubNativeSessionScanner(
            candidatesByManagedSessionID: ["managed-1": [expectedCandidate, otherCandidate]]
        )
        var recordsByPanelID: [UUID: ManagedAgentResumeRecord] = [:]
        let registry = ManagedAgentNativeSessionObserverRegistry(
            scanner: scanner,
            nowProvider: { launchStart.addingTimeInterval(2) },
            recordHandler: { _, panelID, record in
                recordsByPanelID[panelID] = record
            }
        )

        let panelID = UUID()
        registry.startObservation(
            ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-1",
                agent: .codex,
                panelID: panelID,
                cwd: "/tmp/repo",
                launchStart: launchStart,
                expectedNativeSessionID: expectedSessionID
            )
        )
        await registry.evaluatePendingObservationsForTesting()

        #expect(recordsByPanelID[panelID]?.nativeSessionID == expectedSessionID)
        #expect(registry.activeObservationCountForTesting == 0)
    }

    @Test
    func observerRefusesCandidateOwnedByAnotherPanel() async {
        let launchStart = Date(timeIntervalSince1970: 1_700_000_000)
        let observedPanelID = UUID()
        let candidate = ManagedAgentNativeSessionCandidate(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: "/tmp/codex-session.jsonl",
            cwd: "/tmp/repo",
            updatedAt: launchStart.addingTimeInterval(1)
        )
        let scanner = StubNativeSessionScanner(candidatesByManagedSessionID: ["managed-1": [candidate]])
        var recordCount = 0
        let registry = ManagedAgentNativeSessionObserverRegistry(
            scanner: scanner,
            nowProvider: { launchStart.addingTimeInterval(2) },
            ownershipStateProvider: {
                ownershipState(
                    nativeSessionID: candidate.nativeSessionID,
                    owner: .inactivePersistedClaim(rolloutPath: nil)
                )
            },
            recordHandler: { _, _, _ in
                recordCount += 1
            }
        )

        registry.startObservation(
            ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-1",
                agent: .codex,
                panelID: observedPanelID,
                cwd: "/tmp/repo",
                launchStart: launchStart
            )
        )
        await registry.evaluatePendingObservationsForTesting()

        #expect(recordCount == 0)
        #expect(registry.activeObservationCountForTesting == 1)
    }

    @Test
    func observerCapturesCandidateOwnedByObservedPanel() async {
        let launchStart = Date(timeIntervalSince1970: 1_700_000_000)
        let panelID = UUID()
        let sessionID = "019e2823-f520-7690-91b6-cd84eb52dd8a"
        let candidate = ManagedAgentNativeSessionCandidate(
            agent: .codex,
            nativeSessionID: sessionID,
            sessionFilePath: "/tmp/codex-session.jsonl",
            cwd: "/tmp/repo",
            updatedAt: launchStart.addingTimeInterval(1)
        )
        let scanner = StubNativeSessionScanner(candidatesByManagedSessionID: ["managed-1": [candidate]])
        var recordsByPanelID: [UUID: ManagedAgentResumeRecord] = [:]
        let registry = ManagedAgentNativeSessionObserverRegistry(
            scanner: scanner,
            nowProvider: { launchStart.addingTimeInterval(2) },
            ownershipStateProvider: {
                ownershipState(
                    nativeSessionID: candidate.nativeSessionID,
                    owner: .activeManaged(
                        managedSessionID: ManagedSessionID("managed-1")!,
                        rolloutPath: nil
                    )
                )
            },
            recordHandler: { _, panelID, record in
                recordsByPanelID[panelID] = record
            }
        )

        registry.startObservation(
            ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-1",
                agent: .codex,
                panelID: panelID,
                cwd: "/tmp/repo",
                launchStart: launchStart
            )
        )
        await registry.evaluatePendingObservationsForTesting()

        #expect(recordsByPanelID[panelID]?.nativeSessionID == sessionID)
        #expect(registry.activeObservationCountForTesting == 0)
    }

    @Test
    func observerCapturesExpectedNativeSessionWhenOwnedByStalePanel() async {
        let launchStart = Date(timeIntervalSince1970: 1_700_000_000)
        let panelID = UUID()
        let sessionID = "019e2823-f520-7690-91b6-cd84eb52dd8a"
        let candidate = ManagedAgentNativeSessionCandidate(
            agent: .codex,
            nativeSessionID: sessionID,
            sessionFilePath: "/tmp/codex-session.jsonl",
            cwd: "/tmp/repo",
            updatedAt: launchStart.addingTimeInterval(1)
        )
        let scanner = StubNativeSessionScanner(candidatesByManagedSessionID: ["managed-1": [candidate]])
        var recordsByPanelID: [UUID: ManagedAgentResumeRecord] = [:]
        let registry = ManagedAgentNativeSessionObserverRegistry(
            scanner: scanner,
            nowProvider: { launchStart.addingTimeInterval(2) },
            ownershipStateProvider: {
                ownershipState(
                    nativeSessionID: candidate.nativeSessionID,
                    owner: .inactivePersistedClaim(rolloutPath: nil)
                )
            },
            recordHandler: { _, panelID, record in
                recordsByPanelID[panelID] = record
            }
        )

        registry.startObservation(
            ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-1",
                agent: .codex,
                panelID: panelID,
                cwd: "/tmp/repo",
                launchStart: launchStart,
                expectedNativeSessionID: sessionID
            )
        )
        await registry.evaluatePendingObservationsForTesting()

        #expect(recordsByPanelID[panelID]?.nativeSessionID == sessionID)
        #expect(registry.activeObservationCountForTesting == 0)
    }

    @Test
    func observerRefusesExpectedNativeSessionOwnedByActivePanel() async {
        let launchStart = Date(timeIntervalSince1970: 1_700_000_000)
        let panelID = UUID()
        let sessionID = "019e2823-f520-7690-91b6-cd84eb52dd8a"
        let candidate = ManagedAgentNativeSessionCandidate(
            agent: .codex,
            nativeSessionID: sessionID,
            sessionFilePath: "/tmp/codex-session.jsonl",
            cwd: "/tmp/repo",
            updatedAt: launchStart.addingTimeInterval(1)
        )
        let scanner = StubNativeSessionScanner(candidatesByManagedSessionID: ["managed-1": [candidate]])
        var recordCount = 0
        let registry = ManagedAgentNativeSessionObserverRegistry(
            scanner: scanner,
            nowProvider: { launchStart.addingTimeInterval(2) },
            ownershipStateProvider: {
                ownershipState(
                    nativeSessionID: candidate.nativeSessionID,
                    owner: .activeManaged(
                        managedSessionID: ManagedSessionID("managed-owner")!,
                        rolloutPath: nil
                    )
                )
            },
            recordHandler: { _, _, _ in
                recordCount += 1
            }
        )

        registry.startObservation(
            ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-1",
                agent: .codex,
                panelID: panelID,
                cwd: "/tmp/repo",
                launchStart: launchStart,
                expectedNativeSessionID: sessionID
            )
        )
        await registry.evaluatePendingObservationsForTesting()

        #expect(recordCount == 0)
        #expect(registry.activeObservationCountForTesting == 1)
    }

    @Test
    func observerDoesNotResurrectBookkeepingWhenCancelledDuringScan() async throws {
        let launchStart = Date(timeIntervalSince1970: 1_700_000_000)
        let scanner = GatedNativeSessionScanner()
        var recordCount = 0
        let registry = ManagedAgentNativeSessionObserverRegistry(
            scanner: scanner,
            nowProvider: { launchStart.addingTimeInterval(2) },
            recordHandler: { _, _, _ in
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
        try await waitForAsyncCondition {
            await scanner.scanStartCount >= 1
        }

        registry.cancelObservation(sessionID: "managed-1")
        await scanner.openGate()
        try await waitForAsyncCondition {
            await scanner.scanFinishCount >= 1
        }
        await Task.yield()
        await Task.yield()

        #expect(recordCount == 0)
        #expect(registry.activeObservationCountForTesting == 0)
        #expect(registry.scanBookkeepingEntryCountForTesting == 0)
    }

    @Test
    func observerKeepsNewerLoopTaskWhenCancelledLoopExits() async throws {
        let launchStart = Date(timeIntervalSince1970: 1_700_000_000)
        let scanner = GatedNativeSessionScanner()
        let registry = ManagedAgentNativeSessionObserverRegistry(
            scanner: scanner,
            nowProvider: { launchStart.addingTimeInterval(2) },
            recordHandler: { _, _, _ in }
        )
        defer {
            registry.cancelObservation(sessionID: "managed-2")
        }

        registry.startObservation(
            ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-1",
                agent: .codex,
                panelID: UUID(),
                cwd: "/tmp/repo",
                launchStart: launchStart
            )
        )
        try await waitForAsyncCondition {
            await scanner.scanStartCount >= 1
        }

        // Cancelling the only observation cancels loop task T1 (still
        // suspended in the gated scan) and clears the task reference.
        registry.cancelObservation(sessionID: "managed-1")
        // A new observation schedules loop task T2.
        registry.startObservation(
            ManagedAgentNativeSessionObservationContext(
                managedSessionID: "managed-2",
                agent: .codex,
                panelID: UUID(),
                cwd: "/tmp/repo",
                launchStart: launchStart
            )
        )
        #expect(registry.hasObservationLoopTaskForTesting)

        // Let T1 resume from the gated scan and exit; it must not clobber
        // the reference to the still-running T2.
        await scanner.openGate()
        try await waitForAsyncCondition {
            await scanner.scanFinishCount >= 1
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(registry.hasObservationLoopTaskForTesting)
        #expect(registry.activeObservationCountForTesting == 1)
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

private func makeResumeRecordAppState(
    nativeSessionIDs: [String]
) -> (appState: AppState, workspaceID: UUID, panelIDs: [UUID]) {
    var workspace = WorkspaceState.bootstrap()
    let tabID = workspace.resolvedSelectedTabID!
    var tab = workspace.tabsByID[tabID]!
    let originalPanelID = tab.panels.keys.first!
    var panelIDs: [UUID] = []

    for (index, nativeSessionID) in nativeSessionIDs.enumerated() {
        let panelID = index == 0 ? originalPanelID : UUID()
        let terminalState = TerminalPanelState(
            title: "Terminal \(index + 1)",
            shell: "zsh",
            cwd: "/tmp/repo",
            resumeRecord: ManagedAgentResumeRecord(
                agent: .codex,
                nativeSessionID: nativeSessionID,
                sessionFilePath: "/tmp/codex-\(index).jsonl",
                cwd: "/tmp/repo",
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        tab.panels[panelID] = .terminal(terminalState)
        panelIDs.append(panelID)
    }
    workspace.tabsByID[tabID] = tab
    let appState = AppState(
        windows: [],
        workspacesByID: [workspace.id: workspace],
        selectedWindowID: nil
    )
    return (appState, workspace.id, panelIDs)
}

private func ownershipState(
    nativeSessionID rawNativeSessionID: String,
    owner: NativeSessionOwnerSnapshot
) -> ManagedAgentNativeSessionOwnershipState {
    guard let nativeSessionID = NativeSessionID(rawNativeSessionID) else {
        fatalError("Test fixture native session ID must be non-empty")
    }
    return ManagedAgentNativeSessionOwnershipState(
        ownerByNativeSessionID: [nativeSessionID: owner],
        conflictedNativeSessionIDs: []
    )
}

@MainActor
private final class ManagedAgentNativeSessionObserverRegistryBox {
    weak var value: ManagedAgentNativeSessionObserverRegistry?
}

/// Scanner that suspends every scan until the gate opens, so tests can
/// interleave registry mutations with an in-flight scan deterministically.
private actor GatedNativeSessionScanner: ManagedAgentNativeSessionScanning {
    private(set) var scanStartCount = 0
    private(set) var scanFinishCount = 0
    private var gateOpen = false

    func candidates(for observation: ManagedAgentNativeSessionObservationContext) async -> [ManagedAgentNativeSessionCandidate] {
        scanStartCount += 1
        while gateOpen == false {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        scanFinishCount += 1
        return []
    }

    func openGate() {
        gateOpen = true
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

@MainActor
private func waitForAsyncCondition(
    timeout: TimeInterval = 2,
    condition: @escaping () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("condition did not become true before timeout")
}
