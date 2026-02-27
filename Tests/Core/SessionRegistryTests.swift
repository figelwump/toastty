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
}
