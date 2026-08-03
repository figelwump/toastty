import CoreState
import Foundation
import Testing

struct SessionRegistryTests {
    @Test
    func startSessionStoresManagedNotificationPreference() throws {
        var registry = SessionRegistry()
        let panelID = UUID()
        let now = Date(timeIntervalSince1970: 999)

        registry.startSession(
            sessionID: "managed",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )

        let record = try #require(registry.activeSession(for: panelID))
        #expect(record.usesSessionStatusNotifications)
    }

    @Test
    func sessionRecordDecodesLegacyPayloadWithoutDisplayTitleOverrideKey() throws {
        let record = SessionRecord(
            sessionID: "legacy-title",
            agent: .processWatch,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            status: SessionStatus(kind: .working, summary: "Working", detail: "Running"),
            displayTitleOverride: "bundle exec rspec",
            repoRoot: "/repo",
            cwd: "/repo",
            startedAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_001)
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(record)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "displayTitleOverride")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try decoder.decode(SessionRecord.self, from: legacyData)

        #expect(decoded.displayTitleOverride == nil)
        #expect(decoded.sessionID == record.sessionID)
        #expect(decoded.agent == record.agent)
        #expect(decoded.status == record.status)
    }

    @Test
    func sessionRecordDecodesLegacyPayloadWithoutManagedNotificationKey() throws {
        let record = SessionRecord(
            sessionID: "legacy",
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            isFlaggedForLater: true,
            usesSessionStatusNotifications: true,
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Done"),
            repoRoot: "/repo",
            cwd: "/repo",
            startedAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_001)
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(record)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "isFlaggedForLater")
        object.removeValue(forKey: "usesSessionStatusNotifications")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try decoder.decode(SessionRecord.self, from: legacyData)

        #expect(decoded.isFlaggedForLater == false)
        #expect(decoded.usesSessionStatusNotifications == false)
        #expect(decoded.sessionID == record.sessionID)
        #expect(decoded.agent == record.agent)
        #expect(decoded.panelID == record.panelID)
        #expect(decoded.workspaceID == record.workspaceID)
        #expect(decoded.status == record.status)
    }

    @Test
    func sessionRecordDecodesLegacyPayloadWithoutScopeKeyAsUnrestricted() throws {
        let record = SessionRecord(
            sessionID: "legacy-scope",
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            scopedWorkspaceIDs: [UUID()],
            startedAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_001)
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(record)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "scopedWorkspaceIDs")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try decoder.decode(SessionRecord.self, from: legacyData)

        #expect(decoded.scopedWorkspaceIDs == nil)
        #expect(decoded.sessionID == record.sessionID)
        #expect(decoded.workspaceID == record.workspaceID)
    }

    @Test
    func sessionRecordDoesNotPersistRuntimeBackgroundActivity() throws {
        let now = Date(timeIntervalSince1970: 1_010)
        let record = SessionRecord(
            sessionID: "runtime-activity",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            statusUpdatedAt: now.addingTimeInterval(1),
            backgroundActivitiesByID: [
                "child-1": SessionBackgroundActivity(
                    id: "child-1",
                    kind: .childAgent,
                    displayName: "Codex",
                    command: "codex review",
                    processID: 12_345,
                    startedAt: now,
                    lastUpdatedAt: now
                ),
            ],
            pendingBackgroundTaskCount: 2,
            lastActivityFinishedAt: now.addingTimeInterval(2),
            startedAt: now,
            updatedAt: now
        )

        let data = try JSONEncoder().encode(record)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: data)

        #expect(object["backgroundActivitiesByID"] == nil)
        #expect(decoded.backgroundActivitiesByID.isEmpty)
        #expect(object["pendingBackgroundTaskCount"] == nil)
        #expect(decoded.pendingBackgroundTaskCount == 0)
        #expect(object["statusUpdatedAt"] == nil)
        #expect(decoded.statusUpdatedAt == nil)
        #expect(object["lastActivityFinishedAt"] == nil)
        #expect(decoded.lastActivityFinishedAt == nil)
    }

    @Test
    func sessionRecordPersistsParentSessionID() throws {
        let now = Date(timeIntervalSince1970: 1_011)
        let record = SessionRecord(
            sessionID: "child",
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            parentSessionID: "parent",
            startedAt: now,
            updatedAt: now
        )

        let data = try JSONEncoder().encode(record)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: data)

        #expect(object["parentSessionID"] as? String == "parent")
        #expect(decoded.parentSessionID == "parent")
    }

    @Test
    func sessionRegistryRoundTripPreservesParentSessionID() throws {
        var registry = SessionRegistry()
        let now = Date(timeIntervalSince1970: 1_012)
        let childPanelID = UUID()

        registry.startSession(
            sessionID: "parent",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.startSession(
            sessionID: "child",
            agent: .codex,
            panelID: childPanelID,
            windowID: UUID(),
            workspaceID: UUID(),
            parentSessionID: "parent",
            cwd: nil,
            repoRoot: nil,
            at: now.addingTimeInterval(1)
        )

        let decoded = try JSONDecoder().decode(
            SessionRegistry.self,
            from: JSONEncoder().encode(registry)
        )

        #expect(decoded.activeSession(for: childPanelID)?.parentSessionID == "parent")
    }

    @Test
    func workspaceScopeAccessFollowsCooperativeTruthTable() throws {
        var registry = SessionRegistry()
        let now = Date(timeIntervalSince1970: 1_200)
        let scopedWorkspaceID = UUID()
        let movedWorkspaceID = UUID()
        let explicitWorkspaceID = UUID()
        let outOfScopeWorkspaceID = UUID()
        let scopedPanelID = UUID()

        registry.startSession(
            sessionID: "unscoped",
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.startSession(
            sessionID: "scoped",
            agent: .codex,
            panelID: scopedPanelID,
            windowID: UUID(),
            workspaceID: scopedWorkspaceID,
            cwd: nil,
            repoRoot: nil,
            scopedWorkspaceIDs: [explicitWorkspaceID],
            at: now
        )
        registry.startSession(
            sessionID: "own-only",
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: scopedWorkspaceID,
            cwd: nil,
            repoRoot: nil,
            scopedWorkspaceIDs: [],
            at: now
        )

        #expect(registry.allowsWorkspaceAutomation(callerSessionID: nil, of: outOfScopeWorkspaceID))
        #expect(registry.allowsWorkspaceAutomation(callerSessionID: "missing", of: outOfScopeWorkspaceID))
        #expect(registry.allowsWorkspaceAutomation(callerSessionID: "unscoped", of: outOfScopeWorkspaceID))
        #expect(registry.allowsWorkspaceAutomation(callerSessionID: "scoped", of: scopedWorkspaceID))
        #expect(registry.allowsWorkspaceAutomation(callerSessionID: "scoped", of: explicitWorkspaceID))
        #expect(registry.allowsWorkspaceAutomation(callerSessionID: "scoped", of: outOfScopeWorkspaceID) == false)
        #expect(registry.allowsWorkspaceAutomation(callerSessionID: "own-only", of: scopedWorkspaceID))
        #expect(registry.allowsWorkspaceAutomation(callerSessionID: "own-only", of: explicitWorkspaceID) == false)

        registry.updatePanelLocation(
            panelID: scopedPanelID,
            windowID: UUID(),
            workspaceID: movedWorkspaceID,
            at: now.addingTimeInterval(1)
        )

        #expect(registry.allowsWorkspaceAutomation(callerSessionID: "scoped", of: movedWorkspaceID))
        #expect(registry.allowsWorkspaceAutomation(callerSessionID: "scoped", of: scopedWorkspaceID) == false)
        #expect(registry.effectiveWorkspaceScope(sessionID: "scoped") == [explicitWorkspaceID, movedWorkspaceID])

        registry.stopSession(sessionID: "scoped", at: now.addingTimeInterval(2))
        #expect(registry.allowsWorkspaceAutomation(callerSessionID: "scoped", of: outOfScopeWorkspaceID))
    }

    @Test
    func clearingScopeRestoresUnrestrictedWhileEmptyScopeStaysOwnOnly() throws {
        var registry = SessionRegistry()
        let now = Date(timeIntervalSince1970: 1_250)
        let ownWorkspaceID = UUID()
        let otherWorkspaceID = UUID()

        registry.startSession(
            sessionID: "session",
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: ownWorkspaceID,
            cwd: nil,
            repoRoot: nil,
            scopedWorkspaceIDs: [],
            at: now
        )

        #expect(registry.isWorkspaceScoped(sessionID: "session"))
        #expect(registry.effectiveWorkspaceScope(sessionID: "session") == [ownWorkspaceID])
        #expect(registry.allowsWorkspaceAutomation(callerSessionID: "session", of: ownWorkspaceID))
        #expect(registry.allowsWorkspaceAutomation(callerSessionID: "session", of: otherWorkspaceID) == false)

        let didClearScope = registry.clearScope(sessionID: "session")
        #expect(didClearScope)
        #expect(registry.isWorkspaceScoped(sessionID: "session") == false)
        #expect(registry.scope(ofSessionID: "session") == nil)
        #expect(registry.effectiveWorkspaceScope(sessionID: "session") == nil)
        #expect(registry.allowsWorkspaceAutomation(callerSessionID: "session", of: otherWorkspaceID))
    }

    @Test
    func laterFlagMutatorsAreNoOpForProcessWatchSessions() throws {
        var registry = SessionRegistry()
        let panelID = UUID()
        let now = Date(timeIntervalSince1970: 1_200)

        registry.startSession(
            sessionID: "watched",
            agent: .processWatch,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )

        registry.setLaterFlag(sessionID: "watched", isFlagged: true)
        #expect(registry.isLaterFlagged(sessionID: "watched") == false)
        #expect(try #require(registry.activeSession(for: panelID)).isFlaggedForLater == false)

        registry.toggleLaterFlag(sessionID: "watched")
        #expect(registry.isLaterFlagged(sessionID: "watched") == false)
    }

    @Test
    func laterFlagMutatorsOnlyAffectActiveSessions() throws {
        var registry = SessionRegistry()
        let panelID = UUID()
        let now = Date(timeIntervalSince1970: 1_100)

        registry.startSession(
            sessionID: "flagged",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )

        registry.setLaterFlag(sessionID: "flagged", isFlagged: true)
        #expect(registry.isLaterFlagged(sessionID: "flagged"))
        #expect(try #require(registry.activeSession(for: panelID)).isFlaggedForLater)

        registry.toggleLaterFlag(sessionID: "flagged")
        #expect(registry.isLaterFlagged(sessionID: "flagged") == false)

        registry.stopSession(sessionID: "flagged", at: now.addingTimeInterval(1))
        registry.setLaterFlag(sessionID: "flagged", isFlagged: true)
        #expect(registry.sessionsByID["flagged"]?.isFlaggedForLater == false)
    }

    @Test
    func sessionRegistryDecodesLegacyPayloadWithoutSessionOrder() throws {
        var registry = SessionRegistry()
        let now = Date(timeIntervalSince1970: 1_000)
        let workspaceID = UUID()

        registry.startSession(
            sessionID: "later",
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now.addingTimeInterval(1)
        )
        registry.updateStatus(
            sessionID: "later",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Later"),
            at: now.addingTimeInterval(2)
        )

        registry.startSession(
            sessionID: "earlier",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.updateStatus(
            sessionID: "earlier",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Earlier"),
            at: now.addingTimeInterval(3)
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(registry)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "sessionOrder")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try decoder.decode(SessionRegistry.self, from: legacyData)
        #expect(decoded.workspaceStatuses(for: workspaceID).map(\.sessionID) == ["earlier", "later"])
    }

    @Test
    func workspaceStatusesCarryDisplayTitleOverride() throws {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let panelID = UUID()
        let now = Date(timeIntervalSince1970: 1_000)

        registry.startSession(
            sessionID: "watcher",
            agent: .processWatch,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            usesSessionStatusNotifications: true,
            displayTitleOverride: "bundle exec rspec",
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )
        registry.updateStatus(
            sessionID: "watcher",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Running"),
            at: now.addingTimeInterval(1)
        )

        let status = try #require(registry.workspaceStatuses(for: workspaceID).first)
        #expect(status.displayTitleOverride == "bundle exec rspec")
        #expect(status.displayTitle == "bundle exec rspec")
    }

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
    func backgroundActivityProjectsReadyAndStatuslessSessionsAsWorking() throws {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let readyPanelID = UUID()
        let statuslessPanelID = UUID()
        let now = Date(timeIntervalSince1970: 710)

        registry.startSession(
            sessionID: "ready-parent",
            agent: .claude,
            panelID: readyPanelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )
        registry.updateStatus(
            sessionID: "ready-parent",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Root turn ended"),
            at: now.addingTimeInterval(1)
        )
        let didUpdateReadyActivity = registry.updateBackgroundActivity(
            sessionID: "ready-parent",
            activity: SessionBackgroundActivity(
                id: "child-1",
                kind: .childAgent,
                displayName: "Codex",
                command: "codex review",
                startedAt: now.addingTimeInterval(2),
                lastUpdatedAt: now.addingTimeInterval(2)
            ),
            at: now.addingTimeInterval(2)
        )
        #expect(didUpdateReadyActivity)

        registry.startSession(
            sessionID: "statusless-parent",
            agent: .claude,
            panelID: statuslessPanelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: now.addingTimeInterval(3)
        )
        let didUpdateStatuslessActivity = registry.updateBackgroundActivity(
            sessionID: "statusless-parent",
            activity: SessionBackgroundActivity(
                id: "child-2",
                kind: .childAgent,
                displayName: "Claude Code",
                startedAt: now.addingTimeInterval(4),
                lastUpdatedAt: now.addingTimeInterval(4)
            ),
            at: now.addingTimeInterval(4)
        )
        #expect(didUpdateStatuslessActivity)

        let statuses = registry.workspaceStatuses(for: workspaceID)
        #expect(statuses.map(\.sessionID) == ["ready-parent", "statusless-parent"])
        #expect(statuses.map(\.status.kind) == [.working, .working])
        #expect(statuses.first?.status.detail == "Root turn ended")
        #expect(statuses.first?.projection == .waitingOnChildren(
            childCount: 1,
            pendingBackgroundTaskCount: 0
        ))
        #expect(statuses.last?.status.detail == nil)
        #expect(statuses.last?.projection == .waitingOnChildren(
            childCount: 1,
            pendingBackgroundTaskCount: 0
        ))
        #expect(registry.sessionsByID["ready-parent"]?.status?.kind == .ready)
        #expect(registry.panelStatus(for: readyPanelID)?.status.kind == .working)
        #expect(registry.panelStatus(for: readyPanelID)?.projection == .waitingOnChildren(
            childCount: 1,
            pendingBackgroundTaskCount: 0
        ))
    }

    @Test
    func codexSubagentActivityProjectsRawReadyAsWaitingOnChildren() throws {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 715)

        registry.startSession(
            sessionID: "codex-parent",
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )
        registry.updateStatus(
            sessionID: "codex-parent",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Root turn ended"),
            at: now.addingTimeInterval(1)
        )
        let didUpdateActivity = registry.updateBackgroundActivity(
            sessionID: "codex-parent",
            activity: SessionBackgroundActivity(
                id: "agent-1",
                kind: .subagent,
                displayName: "Herschel",
                command: "Inspect the diff",
                startedAt: now.addingTimeInterval(2),
                lastUpdatedAt: now.addingTimeInterval(2)
            ),
            at: now.addingTimeInterval(2)
        )
        #expect(didUpdateActivity)

        let status = try #require(registry.workspaceStatuses(for: workspaceID).first)
        #expect(status.sessionID == "codex-parent")
        #expect(status.status.kind == .working)
        #expect(status.status.detail == "Root turn ended")
        #expect(status.projection == .waitingOnChildren(
            childCount: 1,
            pendingBackgroundTaskCount: 0
        ))
        #expect(registry.sessionsByID["codex-parent"]?.status?.kind == .ready)
    }

    @Test
    func backgroundActivityDoesNotOverrideActionableOrWorkingStatuses() throws {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 720)

        for (sessionID, kind) in [
            ("approval", SessionStatusKind.needsApproval),
            ("error", SessionStatusKind.error),
            ("working", SessionStatusKind.working),
        ] {
            registry.startSession(
                sessionID: sessionID,
                agent: .claude,
                panelID: UUID(),
                windowID: UUID(),
                workspaceID: workspaceID,
                cwd: nil,
                repoRoot: nil,
                at: now
            )
            registry.updateStatus(
                sessionID: sessionID,
                status: SessionStatus(kind: kind, summary: kind.rawValue, detail: "base"),
                at: now.addingTimeInterval(1)
            )
            registry.updateBackgroundActivity(
                sessionID: sessionID,
                activity: SessionBackgroundActivity(
                    id: "child-\(sessionID)",
                    kind: .childAgent,
                    startedAt: now.addingTimeInterval(2),
                    lastUpdatedAt: now.addingTimeInterval(2)
                ),
                at: now.addingTimeInterval(2)
            )
        }

        #expect(registry.workspaceStatuses(for: workspaceID).map(\.status.kind) == [
            .needsApproval,
            .error,
            .working,
        ])
        #expect(registry.workspaceStatuses(for: workspaceID).map(\.projection) == [
            .none,
            .none,
            .none,
        ])
    }

    @Test
    func subagentSyncReplacesOnlySubagentActivitiesAndPreservesStartedAt() throws {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 725)

        registry.startSession(
            sessionID: "parent",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.updateStatus(
            sessionID: "parent",
            status: SessionStatus(kind: .ready, summary: "Ready"),
            at: now.addingTimeInterval(1)
        )
        let didUpdateChildActivity = registry.updateBackgroundActivity(
            sessionID: "parent",
            activity: SessionBackgroundActivity(
                id: "child-1",
                kind: .childAgent,
                displayName: "Codex",
                startedAt: now.addingTimeInterval(2),
                lastUpdatedAt: now.addingTimeInterval(2)
            ),
            at: now.addingTimeInterval(2)
        )
        #expect(didUpdateChildActivity)

        let didSyncInitialSubagent = registry.syncBackgroundActivities(
            sessionID: "parent",
            kind: .subagent,
            entries: [
                SessionBackgroundActivity(
                    id: "subagent-1",
                    kind: .subagent,
                    displayName: "general-purpose",
                    startedAt: now.addingTimeInterval(3),
                    lastUpdatedAt: now.addingTimeInterval(3)
                ),
            ],
            pendingBackgroundTaskCount: 1,
            at: now.addingTimeInterval(3)
        )
        #expect(didSyncInitialSubagent)

        var record = try #require(registry.sessionsByID["parent"])
        #expect(Set(record.backgroundActivitiesByID.keys) == Set(["child-1", "subagent-1"]))
        #expect(record.backgroundActivitiesByID["subagent-1"]?.startedAt == now.addingTimeInterval(3))
        #expect(record.pendingBackgroundTaskCount == 1)

        let didSyncMergedSubagent = registry.syncBackgroundActivities(
            sessionID: "parent",
            kind: .subagent,
            entries: [
                SessionBackgroundActivity(
                    id: "subagent-1",
                    kind: .subagent,
                    command: "Run review",
                    startedAt: now.addingTimeInterval(4),
                    lastUpdatedAt: now.addingTimeInterval(4)
                ),
            ],
            pendingBackgroundTaskCount: 0,
            at: now.addingTimeInterval(4)
        )
        #expect(didSyncMergedSubagent)

        record = try #require(registry.sessionsByID["parent"])
        let mergedSubagent = try #require(record.backgroundActivitiesByID["subagent-1"])
        #expect(mergedSubagent.startedAt == now.addingTimeInterval(3))
        #expect(mergedSubagent.displayName == "general-purpose")
        #expect(mergedSubagent.command == "Run review")
        #expect(mergedSubagent.lastUpdatedAt == now.addingTimeInterval(4))
        #expect(record.pendingBackgroundTaskCount == 0)

        let didAddLifecycleSubagent = registry.updateBackgroundActivity(
            sessionID: "parent",
            activity: SessionBackgroundActivity(
                id: "workflow-subagent-1",
                kind: .subagent,
                preserveWhenUnlisted: true,
                startedAt: now.addingTimeInterval(5),
                lastUpdatedAt: now.addingTimeInterval(5)
            ),
            at: now.addingTimeInterval(5)
        )
        #expect(didAddLifecycleSubagent)

        let didPreserveUnlistedSubagents = registry.syncBackgroundActivities(
            sessionID: "parent",
            kind: .subagent,
            entries: [],
            pendingBackgroundTaskCount: 1,
            preserveUnlistedActivities: true,
            at: now.addingTimeInterval(6)
        )
        #expect(didPreserveUnlistedSubagents)

        record = try #require(registry.sessionsByID["parent"])
        #expect(Set(record.backgroundActivitiesByID.keys) == Set([
            "child-1",
            "workflow-subagent-1",
        ]))
        #expect(record.pendingBackgroundTaskCount == 1)

        let didClearSubagents = registry.syncBackgroundActivities(
            sessionID: "parent",
            kind: .subagent,
            entries: [],
            pendingBackgroundTaskCount: 0,
            at: now.addingTimeInterval(7)
        )
        #expect(didClearSubagents)

        record = try #require(registry.sessionsByID["parent"])
        #expect(Set(record.backgroundActivitiesByID.keys) == Set(["child-1"]))
        #expect(record.pendingBackgroundTaskCount == 0)
    }

    @Test
    func subagentStartUpsertsAndMergesExistingSubagentActivity() throws {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 727)

        registry.startSession(
            sessionID: "parent",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        let didSyncMinimalSubagent = registry.syncBackgroundActivities(
            sessionID: "parent",
            kind: .subagent,
            entries: [
                SessionBackgroundActivity(
                    id: "subagent-1",
                    kind: .subagent,
                    startedAt: now.addingTimeInterval(1),
                    lastUpdatedAt: now.addingTimeInterval(1)
                ),
            ],
            pendingBackgroundTaskCount: 0,
            at: now.addingTimeInterval(1)
        )
        #expect(didSyncMinimalSubagent)

        let didMergeSubagentStart = registry.updateBackgroundActivity(
            sessionID: "parent",
            activity: SessionBackgroundActivity(
                id: "subagent-1",
                kind: .subagent,
                displayName: "general-purpose",
                command: "Review diff",
                startedAt: now.addingTimeInterval(2),
                lastUpdatedAt: now.addingTimeInterval(2)
            ),
            at: now.addingTimeInterval(2)
        )
        #expect(didMergeSubagentStart)

        let activity = try #require(registry.sessionsByID["parent"]?.backgroundActivitiesByID["subagent-1"])
        #expect(activity.startedAt == now.addingTimeInterval(1))
        #expect(activity.displayName == "general-purpose")
        #expect(activity.command == "Review diff")
        #expect(activity.lastUpdatedAt == now.addingTimeInterval(2))
    }

    @Test
    func pendingBackgroundTaskCountProjectsWaitingWithoutActivities() throws {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 729)

        registry.startSession(
            sessionID: "parent",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.updateStatus(
            sessionID: "parent",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Root turn completed"),
            at: now.addingTimeInterval(1)
        )
        let didSetPendingCount = registry.syncBackgroundActivities(
            sessionID: "parent",
            kind: .subagent,
            entries: [],
            pendingBackgroundTaskCount: 1,
            at: now.addingTimeInterval(2)
        )
        #expect(didSetPendingCount)

        let waitingStatus = try #require(registry.workspaceStatuses(for: workspaceID).first?.status)
        #expect(waitingStatus.kind == .working)
        #expect(waitingStatus.detail == "Root turn completed")
        #expect(registry.workspaceStatuses(for: workspaceID).first?.projection == .waitingOnChildren(
            childCount: 0,
            pendingBackgroundTaskCount: 1
        ))
        #expect(registry.sessionsByID["parent"]?.status?.kind == .ready)

        let didClearPendingCount = registry.syncBackgroundActivities(
            sessionID: "parent",
            kind: .subagent,
            entries: [],
            pendingBackgroundTaskCount: 0,
            at: now.addingTimeInterval(3)
        )
        #expect(didClearPendingCount)
        let resumingStatus = try #require(
            registry.workspaceStatuses(for: workspaceID, at: now.addingTimeInterval(4)).first
        )
        #expect(resumingStatus.status.kind == .working)
        #expect(resumingStatus.status.detail == "Resuming…")
        #expect(resumingStatus.projection == .resuming)
    }

    @Test
    func lastFinishedActivityProjectsStaleReadyAsResumingInsideGraceWindow() throws {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 731)

        registry.startSession(
            sessionID: "parent",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.updateStatus(
            sessionID: "parent",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Root turn completed"),
            at: now.addingTimeInterval(1)
        )
        registry.updateBackgroundActivity(
            sessionID: "parent",
            activity: SessionBackgroundActivity(
                id: "subagent-1",
                kind: .subagent,
                startedAt: now.addingTimeInterval(2),
                lastUpdatedAt: now.addingTimeInterval(2)
            ),
            at: now.addingTimeInterval(2)
        )
        registry.finishBackgroundActivity(
            sessionID: "parent",
            activityID: "subagent-1",
            at: now.addingTimeInterval(3)
        )

        let status = try #require(registry.workspaceStatuses(
            for: workspaceID,
            at: now.addingTimeInterval(4)
        ).first)
        #expect(status.status == SessionStatus(kind: .working, summary: "Working", detail: "Resuming…"))
        #expect(status.projection == .resuming)
    }

    @Test
    func resumingProjectionExpiresToRawReadyAfterGraceWindow() throws {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 732)

        registry.startSession(
            sessionID: "parent",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.updateStatus(
            sessionID: "parent",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Root turn completed"),
            at: now.addingTimeInterval(1)
        )
        registry.updateBackgroundActivity(
            sessionID: "parent",
            activity: SessionBackgroundActivity(
                id: "subagent-1",
                kind: .subagent,
                startedAt: now.addingTimeInterval(2),
                lastUpdatedAt: now.addingTimeInterval(2)
            ),
            at: now.addingTimeInterval(2)
        )
        registry.finishBackgroundActivity(
            sessionID: "parent",
            activityID: "subagent-1",
            at: now.addingTimeInterval(3)
        )

        let status = try #require(registry.workspaceStatuses(
            for: workspaceID,
            at: now.addingTimeInterval(3 + SessionRegistry.resumeProjectionGraceInterval)
        ).first)
        #expect(status.status == SessionStatus(kind: .ready, summary: "Ready", detail: "Root turn completed"))
        #expect(status.projection == .none)
    }

    @Test
    func freshRawStatusEndsResumingProjectionImmediately() throws {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 733)

        registry.startSession(
            sessionID: "parent",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.updateStatus(
            sessionID: "parent",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Stale ready"),
            at: now.addingTimeInterval(1)
        )
        registry.updateBackgroundActivity(
            sessionID: "parent",
            activity: SessionBackgroundActivity(
                id: "subagent-1",
                kind: .subagent,
                startedAt: now.addingTimeInterval(2),
                lastUpdatedAt: now.addingTimeInterval(2)
            ),
            at: now.addingTimeInterval(2)
        )
        registry.finishBackgroundActivity(
            sessionID: "parent",
            activityID: "subagent-1",
            at: now.addingTimeInterval(3)
        )
        #expect(registry.workspaceStatuses(
            for: workspaceID,
            at: now.addingTimeInterval(4)
        ).first?.projection == .resuming)

        registry.updateStatus(
            sessionID: "parent",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Fresh ready"),
            at: now.addingTimeInterval(5)
        )

        let status = try #require(registry.workspaceStatuses(
            for: workspaceID,
            at: now.addingTimeInterval(6)
        ).first)
        #expect(status.status == SessionStatus(kind: .ready, summary: "Ready", detail: "Fresh ready"))
        #expect(status.projection == .none)
    }

    @Test
    func backgroundActivitiesFinishIndependentlyAndClearOnStop() throws {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 730)

        registry.startSession(
            sessionID: "parent",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.updateStatus(
            sessionID: "parent",
            status: SessionStatus(kind: .ready, summary: "Ready"),
            at: now.addingTimeInterval(1)
        )
        for id in ["child-1", "child-2"] {
            registry.updateBackgroundActivity(
                sessionID: "parent",
                activity: SessionBackgroundActivity(
                    id: id,
                    kind: .childAgent,
                    startedAt: now.addingTimeInterval(2),
                    lastUpdatedAt: now.addingTimeInterval(2)
                ),
                at: now.addingTimeInterval(2)
            )
        }

        let waitingStatus = try #require(registry.workspaceStatuses(for: workspaceID).first)
        #expect(waitingStatus.status.detail == nil)
        #expect(waitingStatus.projection == .waitingOnChildren(
            childCount: 2,
            pendingBackgroundTaskCount: 0
        ))
        let didFinishMissing = registry.finishBackgroundActivity(
            sessionID: "parent",
            activityID: "missing",
            at: now.addingTimeInterval(3)
        )
        #expect(didFinishMissing == false)
        let didFinishFirst = registry.finishBackgroundActivity(
            sessionID: "parent",
            activityID: "child-1",
            at: now.addingTimeInterval(4)
        )
        #expect(didFinishFirst)
        #expect(registry.workspaceStatuses(for: workspaceID).first?.status.kind == .working)
        #expect(registry.workspaceStatuses(for: workspaceID).first?.projection == .waitingOnChildren(
            childCount: 1,
            pendingBackgroundTaskCount: 0
        ))
        let didFinishSecond = registry.finishBackgroundActivity(
            sessionID: "parent",
            activityID: "child-2",
            at: now.addingTimeInterval(5)
        )
        #expect(didFinishSecond)
        #expect(registry.workspaceStatuses(for: workspaceID, at: now.addingTimeInterval(30)).first?.status.kind == .ready)

        registry.updateBackgroundActivity(
            sessionID: "parent",
            activity: SessionBackgroundActivity(
                id: "child-3",
                kind: .childAgent,
                startedAt: now.addingTimeInterval(6),
                lastUpdatedAt: now.addingTimeInterval(6)
            ),
            at: now.addingTimeInterval(6)
        )
        registry.stopSession(sessionID: "parent", at: now.addingTimeInterval(7))

        #expect(registry.sessionsByID["parent"]?.backgroundActivitiesByID.isEmpty == true)
        #expect(registry.workspaceStatuses(for: workspaceID).isEmpty)
    }

    @Test
    func workspaceStatusesAssembleChildRowsFromActivitiesAndSessionsInStableOrder() throws {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let parentPanelID = UUID()
        let childPanelID = UUID()
        let now = Date(timeIntervalSince1970: 760)

        registry.startSession(
            sessionID: "parent",
            agent: .claude,
            panelID: parentPanelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.updateStatus(
            sessionID: "parent",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Orchestrating"),
            at: now.addingTimeInterval(1)
        )
        registry.updateBackgroundActivity(
            sessionID: "parent",
            activity: SessionBackgroundActivity(
                id: "activity-later",
                kind: .subagent,
                displayName: "Explore",
                command: "find session callers",
                startedAt: now.addingTimeInterval(30),
                lastUpdatedAt: now.addingTimeInterval(30)
            ),
            at: now.addingTimeInterval(30)
        )
        registry.startSession(
            sessionID: "child-earlier",
            agent: .codex,
            panelID: childPanelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            parentSessionID: "parent",
            displayTitleOverride: "Codex Review",
            cwd: nil,
            repoRoot: nil,
            at: now.addingTimeInterval(10)
        )
        registry.updateStatus(
            sessionID: "child-earlier",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Running check.sh"),
            at: now.addingTimeInterval(11)
        )

        let parentStatus = try #require(registry.workspaceStatuses(for: workspaceID).first)
        #expect(parentStatus.children.map(\.id) == ["child-earlier", "activity-later"])
        #expect(parentStatus.children.map(\.source) == [.session, .activity])
        #expect(parentStatus.children[0].displayName == "Codex Review")
        #expect(parentStatus.children[0].context == "Running check.sh")
        #expect(parentStatus.children[0].statusKind == .working)
        #expect(parentStatus.children[0].panelID == childPanelID)
        #expect(parentStatus.children[0].workspaceID == workspaceID)
        #expect(parentStatus.children[0].sessionID == "child-earlier")
        #expect(parentStatus.children[1].displayName == "Explore")
        #expect(parentStatus.children[1].context == "find session callers")
        #expect(parentStatus.children[1].statusKind == nil)
    }

    @Test
    func sameWorkspaceChildSessionsAreSuppressedAndPromotedWhenParentStops() throws {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 770)

        registry.startSession(
            sessionID: "parent",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.updateStatus(
            sessionID: "parent",
            status: SessionStatus(kind: .ready, summary: "Ready"),
            at: now.addingTimeInterval(1)
        )
        registry.startSession(
            sessionID: "child",
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            parentSessionID: "parent",
            cwd: nil,
            repoRoot: nil,
            at: now.addingTimeInterval(2)
        )
        registry.updateStatus(
            sessionID: "child",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Done"),
            at: now.addingTimeInterval(3)
        )

        let nestedStatuses = registry.workspaceStatuses(for: workspaceID)
        #expect(nestedStatuses.map(\.sessionID) == ["parent"])
        #expect(nestedStatuses.first?.children.compactMap(\.sessionID) == ["child"])

        registry.stopSession(sessionID: "parent", at: now.addingTimeInterval(4))

        #expect(registry.workspaceStatuses(for: workspaceID).map(\.sessionID) == ["child"])
    }

    @Test
    func crossWorkspaceChildSessionsStayTopLevelInHomeWorkspaceAndMirrorUnderParent() throws {
        var registry = SessionRegistry()
        let parentWorkspaceID = UUID()
        let childWorkspaceID = UUID()
        let now = Date(timeIntervalSince1970: 780)

        registry.startSession(
            sessionID: "parent",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: parentWorkspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.updateStatus(
            sessionID: "parent",
            status: SessionStatus(kind: .ready, summary: "Ready"),
            at: now.addingTimeInterval(1)
        )
        registry.startSession(
            sessionID: "child",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: childWorkspaceID,
            parentSessionID: "parent",
            cwd: nil,
            repoRoot: nil,
            at: now.addingTimeInterval(2)
        )
        registry.updateStatus(
            sessionID: "child",
            status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve git push"),
            at: now.addingTimeInterval(3)
        )

        let parentStatus = try #require(registry.workspaceStatuses(for: parentWorkspaceID).first)
        #expect(parentStatus.children.compactMap(\.sessionID) == ["child"])
        #expect(parentStatus.children.first?.workspaceID == childWorkspaceID)
        #expect(parentStatus.children.first?.statusKind == .needsApproval)

        let childHomeStatuses = registry.workspaceStatuses(for: childWorkspaceID)
        #expect(childHomeStatuses.map(\.sessionID) == ["child"])
        #expect(childHomeStatuses.first?.parentSessionID == "parent")
    }

    @Test
    func workspaceStatusesDoNotSuppressOrNestSessionCycles() throws {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 790)

        registry.startSession(
            sessionID: "a",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            parentSessionID: "b",
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.updateStatus(
            sessionID: "a",
            status: SessionStatus(kind: .ready, summary: "Ready"),
            at: now.addingTimeInterval(1)
        )
        registry.startSession(
            sessionID: "b",
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            parentSessionID: "a",
            cwd: nil,
            repoRoot: nil,
            at: now.addingTimeInterval(2)
        )
        registry.updateStatus(
            sessionID: "b",
            status: SessionStatus(kind: .working, summary: "Working"),
            at: now.addingTimeInterval(3)
        )

        let statuses = registry.workspaceStatuses(for: workspaceID)
        #expect(statuses.map(\.sessionID) == ["a", "b"])
        #expect(statuses.flatMap(\.children).isEmpty)
    }

    @Test
    func workspaceStatusesCarryExplicitAndEffectiveWorkspaceScope() throws {
        var registry = SessionRegistry()
        let ownWorkspaceID = UUID()
        let extraWorkspaceID = UUID()
        let panelID = UUID()
        let now = Date(timeIntervalSince1970: 701)

        registry.startSession(
            sessionID: "scoped-status",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: ownWorkspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            scopedWorkspaceIDs: [extraWorkspaceID],
            at: now
        )
        registry.updateStatus(
            sessionID: "scoped-status",
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready"),
            at: now.addingTimeInterval(1)
        )

        let workspaceStatus = try #require(registry.workspaceStatuses(for: ownWorkspaceID).first)
        #expect(workspaceStatus.scopedWorkspaceIDs == [extraWorkspaceID])
        #expect(workspaceStatus.effectiveScopedWorkspaceIDs == [ownWorkspaceID, extraWorkspaceID])
        #expect(workspaceStatus.effectiveScopedWorkspaceIDs == registry.effectiveWorkspaceScope(sessionID: "scoped-status"))
        #expect(workspaceStatus.isWorkspaceScoped)
    }

    @Test
    func workspaceStatusesRemainInCreationOrderAcrossStatusUpdates() throws {
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

        #expect(registry.workspaceStatuses(for: workspaceID).map(\.sessionID) == ["working", "error", "latest-working"])

        registry.updateStatus(
            sessionID: "working",
            status: SessionStatus(kind: .error, summary: "error", detail: "Tests failed"),
            at: now.addingTimeInterval(6)
        )
        registry.updateStatus(
            sessionID: "latest-working",
            status: SessionStatus(kind: .ready, summary: "ready", detail: "Ready for review"),
            at: now.addingTimeInterval(7)
        )

        let workspaceStatuses = registry.workspaceStatuses(for: workspaceID)
        #expect(workspaceStatuses.map(\.sessionID) == ["working", "error", "latest-working"])
        #expect(workspaceStatuses.map(\.status.kind) == [.error, .error, .ready])
    }

    @Test
    func workspaceStatusesPreserveInsertionOrderWhenSessionsShareStartedAt() {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 850)

        registry.startSession(
            sessionID: "zeta",
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.updateStatus(
            sessionID: "zeta",
            status: SessionStatus(kind: .working, summary: "Working", detail: "First"),
            at: now.addingTimeInterval(1)
        )

        registry.startSession(
            sessionID: "alpha",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.updateStatus(
            sessionID: "alpha",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Second"),
            at: now.addingTimeInterval(2)
        )

        #expect(registry.workspaceStatuses(for: workspaceID).map(\.sessionID) == ["zeta", "alpha"])
    }

    @Test
    func workspaceStatusesHideStoppedSessions() {
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

        #expect(registry.workspaceStatuses(for: workspaceID).isEmpty)
    }

    @Test
    func workspaceStatusesIgnoreStoppedSessionsWhenActiveStatusesExist() throws {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 950)

        registry.startSession(
            sessionID: "stopped",
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.updateStatus(
            sessionID: "stopped",
            status: SessionStatus(kind: .ready, summary: "ready", detail: "Finished cleanup"),
            at: now.addingTimeInterval(1)
        )
        registry.stopSession(sessionID: "stopped", at: now.addingTimeInterval(2))

        registry.startSession(
            sessionID: "active",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now.addingTimeInterval(3)
        )
        registry.updateStatus(
            sessionID: "active",
            status: SessionStatus(kind: .working, summary: "editing", detail: "Updating sidebar state"),
            at: now.addingTimeInterval(4)
        )

        let workspaceStatuses = registry.workspaceStatuses(for: workspaceID)
        #expect(workspaceStatuses.map(\.sessionID) == ["active"])
        #expect(workspaceStatuses.map(\.isActive) == [true])
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

    @Test
    func panelStatusReturnsLatestStoppedStatusWhenNoActiveSessionRemains() throws {
        var registry = SessionRegistry()
        let panelID = UUID()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 1200)

        registry.startSession(
            sessionID: "stopped",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )
        registry.updateStatus(
            sessionID: "stopped",
            status: SessionStatus(kind: .ready, summary: "ready", detail: "Applied the migration"),
            at: now.addingTimeInterval(1)
        )
        registry.stopSession(sessionID: "stopped", at: now.addingTimeInterval(2))

        let panelStatus = try #require(registry.panelStatus(for: panelID))
        #expect(panelStatus.sessionID == "stopped")
        #expect(panelStatus.status.kind == .ready)
        #expect(panelStatus.isActive == false)
    }

    @Test
    func panelStatusPrefersMostRecentStoppedStatusForPanel() throws {
        var registry = SessionRegistry()
        let panelID = UUID()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 1250)

        registry.startSession(
            sessionID: "older",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.updateStatus(
            sessionID: "older",
            status: SessionStatus(kind: .needsApproval, summary: "needs approval", detail: "Approve deploy"),
            at: now.addingTimeInterval(1)
        )
        registry.stopSession(sessionID: "older", at: now.addingTimeInterval(2))

        registry.startSession(
            sessionID: "latest",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now.addingTimeInterval(3)
        )
        registry.updateStatus(
            sessionID: "latest",
            status: SessionStatus(kind: .error, summary: "error", detail: "Tests failed"),
            at: now.addingTimeInterval(4)
        )
        registry.stopSession(sessionID: "latest", at: now.addingTimeInterval(5))

        let panelStatus = try #require(registry.panelStatus(for: panelID))
        #expect(panelStatus.sessionID == "latest")
        #expect(panelStatus.status.kind == .error)
    }

    @Test
    func panelStatusDoesNotReuseStoppedStatusWhenActiveSessionHasNoStatusYet() {
        var registry = SessionRegistry()
        let panelID = UUID()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 1300)

        registry.startSession(
            sessionID: "stopped",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.updateStatus(
            sessionID: "stopped",
            status: SessionStatus(kind: .error, summary: "error", detail: "Tests failed"),
            at: now.addingTimeInterval(1)
        )
        registry.stopSession(sessionID: "stopped", at: now.addingTimeInterval(2))

        registry.startSession(
            sessionID: "active",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now.addingTimeInterval(3)
        )

        #expect(registry.panelStatus(for: panelID) == nil)
    }

    @Test
    func workspaceStatusesIncludeIdleSessionsAfterLaunch() throws {
        var registry = SessionRegistry()
        let workspaceID = UUID()
        let panelID = UUID()
        let now = Date(timeIntervalSince1970: 1400)

        registry.startSession(
            sessionID: "idle",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )
        registry.updateStatus(
            sessionID: "idle",
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt"),
            at: now.addingTimeInterval(1)
        )

        let workspaceStatus = try #require(registry.workspaceStatuses(for: workspaceID).first)
        #expect(workspaceStatus.sessionID == "idle")
        #expect(workspaceStatus.status.kind == .idle)
        #expect(workspaceStatus.isActive)
    }

    @Test
    func panelStatusHidesStoppedIdleSessions() {
        var registry = SessionRegistry()
        let panelID = UUID()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 1450)

        registry.startSession(
            sessionID: "idle",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.updateStatus(
            sessionID: "idle",
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt"),
            at: now.addingTimeInterval(1)
        )
        registry.stopSession(sessionID: "idle", at: now.addingTimeInterval(2))

        #expect(registry.panelStatus(for: panelID) == nil)
    }

    @Test
    func panelStatusHidesStoppedWorkingSessions() {
        var registry = SessionRegistry()
        let panelID = UUID()
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 1500)

        registry.startSession(
            sessionID: "working",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )
        registry.updateStatus(
            sessionID: "working",
            status: SessionStatus(kind: .working, summary: "Editing", detail: "Applying diff"),
            at: now.addingTimeInterval(1)
        )
        registry.stopSession(sessionID: "working", at: now.addingTimeInterval(2))

        #expect(registry.panelStatus(for: panelID) == nil)
    }
}
