import CoreState
import Foundation
import Testing

struct SessionRegistryTests {
    @Test
    func startSessionReplacesExistingActiveSessionForPanel() throws {
        var registry = SessionRegistry()
        let now = Date(timeIntervalSince1970: 1000)
        let panelID = UUID()

        registry.startSession(
            sessionID: "session-1",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )

        registry.startSession(
            sessionID: "session-2",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: now.addingTimeInterval(10)
        )

        let active = try #require(registry.activeSession(for: panelID))
        #expect(active.sessionID == "session-2")

        let previous = try #require(registry.sessionsByID["session-1"])
        #expect(previous.isActive == false)
    }

    @Test
    func updateFilesMergesWithoutDuplicates() throws {
        var registry = SessionRegistry()
        let panelID = UUID()
        let now = Date(timeIntervalSince1970: 2000)

        registry.startSession(
            sessionID: "session-merge",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )

        registry.updateFiles(
            sessionID: "session-merge",
            files: ["/repo/a.swift", "/repo/b.swift"],
            cwd: nil,
            repoRoot: nil,
            at: now.addingTimeInterval(5)
        )

        registry.updateFiles(
            sessionID: "session-merge",
            files: ["/repo/b.swift", "/repo/c.swift"],
            cwd: "/repo/subdir",
            repoRoot: nil,
            at: now.addingTimeInterval(10)
        )

        let record = try #require(registry.sessionsByID["session-merge"])
        #expect(record.touchedFiles == ["/repo/a.swift", "/repo/b.swift", "/repo/c.swift"])
        #expect(record.cwd == "/repo/subdir")
    }

    @Test
    func pruneStoppedSessionsRemovesOldEntries() throws {
        var registry = SessionRegistry()
        let panelID = UUID()
        let t0 = Date(timeIntervalSince1970: 100)

        registry.startSession(
            sessionID: "old",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: nil,
            repoRoot: nil,
            at: t0
        )
        registry.stopSession(sessionID: "old", at: t0.addingTimeInterval(5))

        registry.startSession(
            sessionID: "new",
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: nil,
            repoRoot: nil,
            at: t0.addingTimeInterval(50)
        )

        registry.pruneStoppedSessions(olderThan: t0.addingTimeInterval(10))

        #expect(registry.sessionsByID["old"] == nil)
        #expect(registry.sessionsByID["new"] != nil)
    }

    @Test
    func startSessionWithDuplicateSessionIDRebindsActivePanelMapping() throws {
        var registry = SessionRegistry()
        let panelA = UUID()
        let panelB = UUID()
        let now = Date(timeIntervalSince1970: 500)

        registry.startSession(
            sessionID: "dup",
            agent: .claude,
            panelID: panelA,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: nil,
            repoRoot: nil,
            at: now
        )

        registry.startSession(
            sessionID: "dup",
            agent: .codex,
            panelID: panelB,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: nil,
            repoRoot: nil,
            at: now.addingTimeInterval(1)
        )

        #expect(registry.activeSession(for: panelA) == nil)
        let activeForPanelB = try #require(registry.activeSession(for: panelB))
        #expect(activeForPanelB.sessionID == "dup")
        #expect(activeForPanelB.panelID == panelB)
    }

    @Test
    func updateFilesIgnoresStoppedSession() throws {
        var registry = SessionRegistry()
        let panelID = UUID()
        let now = Date(timeIntervalSince1970: 600)

        registry.startSession(
            sessionID: "stopped",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )
        registry.stopSession(sessionID: "stopped", at: now.addingTimeInterval(1))

        let before = try #require(registry.sessionsByID["stopped"])
        registry.updateFiles(
            sessionID: "stopped",
            files: ["/repo/new.swift"],
            cwd: "/repo/changed",
            repoRoot: nil,
            at: now.addingTimeInterval(2)
        )
        let after = try #require(registry.sessionsByID["stopped"])

        #expect(after.touchedFiles == before.touchedFiles)
        #expect(after.cwd == before.cwd)
        #expect(after.updatedAt == before.updatedAt)
    }

    @Test
    func updateStatusStoresStructuredSessionStatus() throws {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let panelID = UUID()
        let now = Date(timeIntervalSince1970: 700)

        registry.startSession(
            sessionID: "status",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )

        registry.updateStatus(
            sessionID: "status",
            status: SessionStatus(
                kind: .working,
                summary: "editing 3 files",
                detail: "Refactoring dashboard to server components"
            ),
            at: now.addingTimeInterval(1)
        )

        let record = try #require(registry.sessionsByID["status"])
        #expect(record.status == SessionStatus(
            kind: .working,
            summary: "editing 3 files",
            detail: "Refactoring dashboard to server components"
        ))

        let workspaceStatuses = registry.workspaceStatuses(for: workspaceID)
        #expect(workspaceStatuses.count == 1)
        let workspaceStatus = try #require(workspaceStatuses.first)
        #expect(workspaceStatus.status.kind == .working)
        #expect(workspaceStatus.status.summary == "editing 3 files")
        #expect(workspaceStatus.status.detail == "Refactoring dashboard to server components")
        #expect(workspaceStatus.cwd == "/repo")
        #expect(workspaceStatus.isActive)
    }

    @Test
    func workspaceStatusesIncludeAllActiveSessionsSortedByPriorityAndRecency() throws {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 800)

        registry.startSession(
            sessionID: "working",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.updateStatus(
            sessionID: "working",
            status: SessionStatus(kind: .working, summary: "editing", detail: "Updating API handlers"),
            at: now.addingTimeInterval(1)
        )

        registry.startSession(
            sessionID: "error",
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now.addingTimeInterval(2)
        )
        registry.updateStatus(
            sessionID: "error",
            status: SessionStatus(kind: .error, summary: "error", detail: "Deploy failed"),
            at: now.addingTimeInterval(3)
        )

        registry.startSession(
            sessionID: "latest-working",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now.addingTimeInterval(4)
        )
        registry.updateStatus(
            sessionID: "latest-working",
            status: SessionStatus(kind: .working, summary: "exploring", detail: "Reading the current reducers"),
            at: now.addingTimeInterval(5)
        )

        let workspaceStatuses = registry.workspaceStatuses(for: workspaceID)
        #expect(workspaceStatuses.map(\.sessionID) == ["error", "latest-working", "working"])
        #expect(workspaceStatuses.map(\.status.kind) == [.error, .working, .working])
    }

    @Test
    func workspaceStatusesFallBackToMostRecentStoppedSession() throws {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 900)

        registry.startSession(
            sessionID: "older-error",
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.updateStatus(
            sessionID: "older-error",
            status: SessionStatus(kind: .error, summary: "error", detail: "Missing env var"),
            at: now.addingTimeInterval(1)
        )
        registry.stopSession(sessionID: "older-error", at: now.addingTimeInterval(2))

        registry.startSession(
            sessionID: "latest-ready",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now.addingTimeInterval(3)
        )
        registry.updateStatus(
            sessionID: "latest-ready",
            status: SessionStatus(kind: .ready, summary: "ready", detail: "Added auth middleware"),
            at: now.addingTimeInterval(4)
        )
        registry.stopSession(sessionID: "latest-ready", at: now.addingTimeInterval(5))

        let workspaceStatus = try #require(registry.workspaceStatuses(for: workspaceID).first)
        #expect(workspaceStatus.sessionID == "latest-ready")
        #expect(workspaceStatus.status.kind == .ready)
        #expect(workspaceStatus.status.detail == "Added auth middleware")
        #expect(workspaceStatus.isActive == false)
    }

    @Test
    func workspaceStatusesDoNotReuseStoppedStatusWhileNewActiveSessionHasNoStatusYet() {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 1000)

        registry.startSession(
            sessionID: "completed",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.updateStatus(
            sessionID: "completed",
            status: SessionStatus(kind: .ready, summary: "ready", detail: "Added auth middleware"),
            at: now.addingTimeInterval(1)
        )
        registry.stopSession(sessionID: "completed", at: now.addingTimeInterval(2))

        registry.startSession(
            sessionID: "new-active",
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now.addingTimeInterval(3)
        )

        #expect(registry.workspaceStatuses(for: workspaceID).isEmpty)
    }

    @Test
    func workspaceStatusesIgnoreStatuslessActiveSessionsWhenOtherActiveStatusesExist() throws {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 1100)

        registry.startSession(
            sessionID: "working",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.updateStatus(
            sessionID: "working",
            status: SessionStatus(kind: .working, summary: "editing", detail: "Updating reducers"),
            at: now.addingTimeInterval(1)
        )

        registry.startSession(
            sessionID: "no-status",
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now.addingTimeInterval(2)
        )

        let workspaceStatuses = registry.workspaceStatuses(for: workspaceID)
        #expect(workspaceStatuses.map(\.sessionID) == ["working"])
    }
}
