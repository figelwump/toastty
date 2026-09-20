import Combine
import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

@MainActor
struct SessionRuntimeStoreTests {
    /// `/clear` rebinds a live panel to a new provider conversation while
    /// keeping the same managed session and the same `bindingID`, so the name
    /// read from the old transcript must not survive onto the new one.
    @Test
    func rebindingToANewConversationDropsTheNameReadFromTheOldOne() async throws {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let sessionID = "sess-claude-rebind"
        let date = Date(timeIntervalSince1970: 1_786_000_000)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("provider-name-rebind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func writeTranscript(nativeSessionID: String, title: String) throws -> String {
            let url = directory.appendingPathComponent("\(nativeSessionID).jsonl", isDirectory: false)
            let line = #"{"type":"ai-title","aiTitle":"\#(title)","sessionId":"\#(nativeSessionID)"}"#
            try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }

        store.startSession(
            sessionID: sessionID,
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: date
        )

        let firstPath = try writeTranscript(nativeSessionID: "native-first", title: "First conversation")
        #expect(store.confirmNativeSessionBinding(
            managedSessionID: sessionID,
            panelID: panelID,
            record: ManagedAgentResumeRecord(
                agent: .claude,
                nativeSessionID: "native-first",
                sessionFilePath: firstPath,
                cwd: "/repo",
                capturedAt: date
            )
        ))
        try await waitForProviderSessionName(
            "First conversation",
            sessionID: sessionID,
            store: store
        )

        // The rebind carries a different native session and transcript under
        // the same bindingID, which is exactly what the stale guard must catch.
        let secondPath = try writeTranscript(nativeSessionID: "native-second", title: "Second conversation")
        #expect(store.confirmNativeSessionBinding(
            managedSessionID: sessionID,
            panelID: panelID,
            record: ManagedAgentResumeRecord(
                agent: .claude,
                nativeSessionID: "native-second",
                sessionFilePath: secondPath,
                cwd: "/repo",
                capturedAt: date.addingTimeInterval(1)
            )
        ))
        try await waitForProviderSessionName(
            "Second conversation",
            sessionID: sessionID,
            store: store
        )
    }

    /// A rebind to a conversation the provider has not named yet must leave the
    /// row unnamed rather than keeping the previous conversation's name, even
    /// though a failed read deliberately preserves an existing name.
    @Test
    func rebindingToAnUnnamedConversationLeavesTheRowUnnamed() async throws {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let sessionID = "sess-claude-rebind-unnamed"
        let date = Date(timeIntervalSince1970: 1_786_000_000)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("provider-name-unnamed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let namedPath = directory.appendingPathComponent("named.jsonl", isDirectory: false)
        try (#"{"type":"ai-title","aiTitle":"Named conversation","sessionId":"native-named"}"# + "\n")
            .write(to: namedPath, atomically: true, encoding: .utf8)
        let unnamedPath = directory.appendingPathComponent("unnamed.jsonl", isDirectory: false)
        try #"{"type":"user","message":"hello"}"#
            .appending("\n")
            .write(to: unnamedPath, atomically: true, encoding: .utf8)

        store.startSession(
            sessionID: sessionID,
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: date
        )
        #expect(store.confirmNativeSessionBinding(
            managedSessionID: sessionID,
            panelID: panelID,
            record: ManagedAgentResumeRecord(
                agent: .claude,
                nativeSessionID: "native-named",
                sessionFilePath: namedPath.path,
                cwd: "/repo",
                capturedAt: date
            )
        ))
        try await waitForProviderSessionName("Named conversation", sessionID: sessionID, store: store)

        #expect(store.confirmNativeSessionBinding(
            managedSessionID: sessionID,
            panelID: panelID,
            record: ManagedAgentResumeRecord(
                agent: .claude,
                nativeSessionID: "native-unnamed",
                sessionFilePath: unnamedPath.path,
                cwd: "/repo",
                capturedAt: date.addingTimeInterval(1)
            )
        ))
        try await waitForProviderSessionName(nil, sessionID: sessionID, store: store)
    }

    /// Cursor writes the title shortly after the first prompt, so the row
    /// picks it up at the turn's end. When Cursor ends that chat and starts
    /// another under the same managed session, the new chat must not inherit
    /// the first one's name.
    @Test
    func cursorRowReadsTheChatTitleAndDropsItWhenClearStartsANewChat() async throws {
        let configDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("provider-name-cursor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: configDirectory) }
        let store = SessionRuntimeStore(
            providerSessionNameEnvironment: ["CURSOR_CONFIG_DIR": configDirectory.path]
        )
        let sessionID = "sess-cursor-name"
        let date = Date(timeIntervalSince1970: 1_786_000_000)
        let firstChatID = "3e07b331-74ec-4fdf-87c5-d2d099cb6df8"
        let secondChatID = "8d755ac8-c0bf-4508-8732-1adcc086ed70"

        func writeMetadata(conversationID: String, title: String?) throws {
            let chatDirectory = configDirectory
                .appendingPathComponent("chats/a6e29e34d16798e9b79c77d2f8197ecb", isDirectory: true)
                .appendingPathComponent(conversationID, isDirectory: true)
            try FileManager.default.createDirectory(at: chatDirectory, withIntermediateDirectories: true)
            let titleField = title.map { #","title":"\#($0)""# } ?? ""
            try #"{"schemaVersion":1,"hasConversation":true\#(titleField)}"#
                .write(
                    to: chatDirectory.appendingPathComponent("meta.json", isDirectory: false),
                    atomically: true,
                    encoding: .utf8
                )
        }
        func send(_ hookEventName: String, conversationID: String, generationID: String? = nil, status: SessionStatus?) {
            _ = store.handleCursorHookEvent(
                sessionID: sessionID,
                event: CursorHookEvent(
                    hookEventName: hookEventName,
                    conversationID: conversationID,
                    generationID: generationID,
                    status: status
                ),
                at: date
            )
        }
        func runTurn(conversationID: String, generationID: String, title: String) throws {
            send("beforeSubmitPrompt", conversationID: conversationID, generationID: generationID,
                 status: SessionStatus(kind: .working, summary: "Working"))
            try writeMetadata(conversationID: conversationID, title: title)
            send("stop", conversationID: conversationID, generationID: generationID,
                 status: SessionStatus(kind: .ready, summary: "Ready"))
        }

        store.startSession(
            sessionID: sessionID,
            agent: .cursor,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: date
        )
        try writeMetadata(conversationID: firstChatID, title: nil)
        send("sessionStart", conversationID: firstChatID, status: SessionStatus(kind: .idle, summary: "Waiting"))
        try runTurn(conversationID: firstChatID, generationID: "generation-1", title: "Blue Sky Explanation")
        try await waitForProviderSessionName("Blue Sky Explanation", sessionID: sessionID, store: store)

        send("sessionEnd", conversationID: firstChatID, status: nil)
        try writeMetadata(conversationID: secondChatID, title: nil)
        send("sessionStart", conversationID: secondChatID, status: SessionStatus(kind: .idle, summary: "Waiting"))
        try await waitForProviderSessionName(nil, sessionID: sessionID, store: store)

        try runTurn(conversationID: secondChatID, generationID: "generation-2", title: "Docs Start Page")
        try await waitForProviderSessionName("Docs Start Page", sessionID: sessionID, store: store)
    }

    /// opencode, MiMo Code and pi report their name through Toastty's plugin
    /// or extension. The name must belong to the conversation the session is
    /// bound to, and the untitled placeholder must not replace a real name.
    @Test
    func reportedProviderSessionNameAppliesOnlyToTheBoundConversation() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let sessionID = "sess-opencode-name"
        let date = Date(timeIntervalSince1970: 1_786_000_000)
        func bind(_ nativeSessionID: String) -> Bool {
            store.confirmNativeSessionBinding(
                managedSessionID: sessionID,
                panelID: panelID,
                record: ManagedAgentResumeRecord(
                    agent: .opencode,
                    nativeSessionID: nativeSessionID,
                    sessionFilePath: "/runtime/managed-agent-resume/\(nativeSessionID).json",
                    cwd: "/repo",
                    capturedAt: date
                )
            )
        }
        func report(_ name: String, nativeSessionID: String = "ses_first", agent: AgentKind = .opencode) -> Bool {
            store.applyReportedProviderSessionName(
                sessionID: sessionID,
                agent: agent,
                nativeSessionID: nativeSessionID,
                name: name
            )
        }
        var providerSessionName: String? {
            store.sessionRegistry.sessionsByID[sessionID]?.providerSessionName
        }

        store.startSession(
            sessionID: sessionID,
            agent: .opencode,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: date
        )
        #expect(report("Early name") == false, "No conversation is bound yet")

        #expect(bind("ses_first"))
        #expect(report("New session - 2026-09-18T05:08:03.123Z") == false)
        #expect(report("Other conversation", nativeSessionID: "ses_other") == false)
        #expect(report("Wrong agent", agent: .mimocode) == false)
        #expect(providerSessionName == nil)

        #expect(report("Build system explanation"))
        #expect(providerSessionName == "Build system explanation")
        #expect(report("New session - 2026-09-18T05:08:03.123Z") == false)
        #expect(providerSessionName == "Build system explanation")

        #expect(bind("ses_second"))
        #expect(providerSessionName == nil, "A rebind drops the previous conversation's name")
        #expect(report("Build system explanation") == false)
    }

    private func waitForProviderSessionName(
        _ expected: String?,
        sessionID: String,
        store: SessionRuntimeStore
    ) async throws {
        for _ in 0 ..< 100 {
            let current = store.sessionRegistry.sessionsByID[sessionID]?.providerSessionName
            if current == expected { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let current = store.sessionRegistry.sessionsByID[sessionID]?.providerSessionName
        Issue.record("providerSessionName settled on \(current ?? "nil"), expected \(expected ?? "nil")")
    }

    @Test
    func managedProviderConversationFeedRequiresConfirmedBindingAndDeduplicates() throws {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let sessionID = "sess-opencode-feed"
        let date = Date(timeIntervalSince1970: 1_786_000_000)
        let record = ManagedAgentResumeRecord(
            agent: .opencode,
            nativeSessionID: "native-opencode",
            sessionFilePath: "/tmp/opencode-marker.json",
            cwd: "/repo",
            capturedAt: date
        )
        store.startSession(
            sessionID: sessionID,
            agent: .opencode,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: date
        )

        #expect(store.resetProviderConversationFeed(
            managedSessionID: sessionID,
            provider: .opencode,
            nativeSessionID: record.nativeSessionID,
            snapshotID: "snapshot-1",
            at: date
        ) == false)
        #expect(store.confirmNativeSessionBinding(
            managedSessionID: sessionID,
            panelID: panelID,
            record: record
        ))
        #expect(store.resetProviderConversationFeed(
            managedSessionID: sessionID,
            provider: .opencode,
            nativeSessionID: record.nativeSessionID,
            snapshotID: "snapshot-1",
            at: date
        ))

        let observation = ProviderTranscriptObservation(
            timestamp: date.addingTimeInterval(1),
            fingerprint: "managed:opencode:message-1",
            payload: .transcript(.assistantMessage(.init(text: "Done"))),
            mayAuthorizeCurrentRuntime: false
        )
        #expect(store.ingestProviderConversationObservation(
            managedSessionID: sessionID,
            provider: .opencode,
            nativeSessionID: record.nativeSessionID,
            snapshotID: "snapshot-1",
            observation: observation
        ))
        #expect(store.ingestProviderConversationObservation(
            managedSessionID: sessionID,
            provider: .opencode,
            nativeSessionID: record.nativeSessionID,
            snapshotID: "snapshot-1",
            observation: observation
        ) == false)

        let feed = try #require(store.providerConversationFeed(managedSessionID: sessionID))
        #expect(feed.provider == .opencode)
        #expect(feed.observations.count == 2)
        #expect(feed.observations.last == observation)
    }

    @Test
    func nativeSessionBindingConfirmationIsCurrentLaunchAndActiveSessionScoped() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let sessionID = "sess-native-confirmation"
        let confirmedAt = Date(timeIntervalSince1970: 1_786_000_000)
        let record = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: "/tmp/current-rollout.jsonl",
            cwd: "/repo",
            capturedAt: confirmedAt
        )

        store.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: confirmedAt
        )

        #expect(store.confirmNativeSessionBinding(
            managedSessionID: sessionID,
            panelID: UUID(),
            record: record
        ) == false)
        #expect(store.nativeSessionBindingConfirmation(for: sessionID) == nil)

        #expect(store.confirmNativeSessionBinding(
            managedSessionID: sessionID,
            panelID: panelID,
            record: record
        ))
        let confirmation = store.nativeSessionBindingConfirmation(for: sessionID)
        #expect(confirmation?.managedSessionID == sessionID)
        #expect(confirmation?.agent == .codex)
        #expect(confirmation?.panelID == panelID)
        #expect(confirmation?.nativeSessionID == record.nativeSessionID)
        #expect(confirmation?.sessionFilePath == record.sessionFilePath)
        #expect(confirmation?.confirmedAt == confirmedAt)
        if let confirmation {
            #expect(store.isNativeSessionBindingInputClean(confirmation))
        }

        var repeatedRecord = record
        repeatedRecord.capturedAt = confirmedAt.addingTimeInterval(1)
        #expect(store.confirmNativeSessionBinding(
            managedSessionID: sessionID,
            panelID: panelID,
            record: repeatedRecord
        ))
        #expect(store.nativeSessionBindingConfirmation(for: sessionID) == confirmation)

        store.noteLocalInputForActiveSession(panelID: panelID)
        if let confirmation {
            #expect(store.isNativeSessionBindingInputClean(confirmation) == false)
        }

        store.stopSession(sessionID: sessionID, at: confirmedAt.addingTimeInterval(1))
        #expect(store.nativeSessionBindingConfirmation(for: sessionID) == nil)
    }

    @Test
    func scopeMutationUpdatesWorkspaceStatusProjection() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let workspaceID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-scope",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.updateStatus(
            sessionID: "sess-scope",
            status: SessionStatus(kind: .idle, summary: "Waiting"),
            at: startedAt
        )

        #expect(store.workspaceStatuses(for: workspaceID).first?.isWorkspaceScoped == false)

        #expect(store.setScope(sessionID: "sess-scope", workspaceIDs: []))
        #expect(store.workspaceStatuses(for: workspaceID).first?.isWorkspaceScoped == true)

        #expect(store.clearScope(sessionID: "sess-scope"))
        #expect(store.workspaceStatuses(for: workspaceID).first?.isWorkspaceScoped == false)
    }

    @Test
    func scopeMutationUpdatesPersistedResumeRecordScope() throws {
        let appStore = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let panelID = try #require(selection.workspace.focusedPanelID)
        let scopedWorkspaceID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let resumeRecord = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: "/tmp/codex-session.jsonl",
            cwd: "/repo",
            capturedAt: startedAt
        )

        #expect(appStore.send(.updateTerminalPanelResumeRecord(panelID: panelID, resumeRecord: resumeRecord)))

        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        sessionStore.startSession(
            sessionID: "sess-scope-record",
            agent: .codex,
            panelID: panelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        #expect(sessionStore.setScope(sessionID: "sess-scope-record", workspaceIDs: []))
        #expect(persistedResumeRecord(panelID: panelID, in: appStore.state)?.scopedWorkspaceIDs == Set<UUID>())

        #expect(sessionStore.addScope(sessionID: "sess-scope-record", workspaceIDs: [scopedWorkspaceID]))
        #expect(
            persistedResumeRecord(panelID: panelID, in: appStore.state)?.scopedWorkspaceIDs ==
                Set([scopedWorkspaceID])
        )

        #expect(sessionStore.clearScope(sessionID: "sess-scope-record"))
        #expect(persistedResumeRecord(panelID: panelID, in: appStore.state)?.scopedWorkspaceIDs == nil)
    }

    @Test
    func stoppingSessionClearsPersistedResumeRecordScope() throws {
        let appStore = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let panelID = try #require(selection.workspace.focusedPanelID)
        let scopedWorkspaceID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let resumeRecord = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: "/tmp/codex-session.jsonl",
            cwd: "/repo",
            capturedAt: startedAt,
            scopedWorkspaceIDs: [scopedWorkspaceID]
        )

        #expect(appStore.send(.updateTerminalPanelResumeRecord(panelID: panelID, resumeRecord: resumeRecord)))

        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        sessionStore.startSession(
            sessionID: "sess-stop-record",
            agent: .codex,
            panelID: panelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            scopedWorkspaceIDs: [scopedWorkspaceID],
            at: startedAt
        )

        sessionStore.stopSession(sessionID: "sess-stop-record", at: startedAt.addingTimeInterval(1))

        #expect(persistedResumeRecord(panelID: panelID, in: appStore.state) == nil)
    }

    @Test
    func stopSessionForPanelIfActiveStopsCurrentSession() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-active",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        let didStop = store.stopSessionForPanelIfActive(
            panelID: panelID,
            reason: .explicit,
            at: startedAt.addingTimeInterval(1)
        )

        #expect(didStop)
        #expect(store.sessionRegistry.activeSession(for: panelID) == nil)
    }

    @Test
    func stopSessionForPanelIfOlderThanStopsEligibleSession() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-older",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        let didStop = store.stopSessionForPanelIfOlderThan(
            panelID: panelID,
            minimumRuntime: 2,
            reason: .explicit,
            at: startedAt.addingTimeInterval(3)
        )

        #expect(didStop)
        #expect(store.sessionRegistry.activeSession(for: panelID) == nil)
    }

    @Test
    func stopSessionForPanelIfOlderThanKeepsRecentSessionAlive() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-recent",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        let didStop = store.stopSessionForPanelIfOlderThan(
            panelID: panelID,
            minimumRuntime: 2,
            reason: .explicit,
            at: startedAt.addingTimeInterval(1)
        )

        #expect(didStop == false)
        #expect(store.sessionRegistry.activeSession(for: panelID)?.sessionID == "sess-recent")
    }

    @Test
    func bindStopsActiveSessionWhenPanelCloses() throws {
        let appStore = AppStore(persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)

        let workspace = try #require(appStore.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-panel-close",
            agent: .codex,
            panelID: panelID,
            windowID: try #require(appStore.state.windows.first?.id),
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        _ = appStore.send(.closePanel(panelID: panelID))

        #expect(sessionStore.sessionRegistry.activeSession(for: panelID) == nil)
    }

    @Test
    func bindKeepsActiveSessionWhenOwningPanelMovesToBackgroundTab() throws {
        let appStore = AppStore(persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)

        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let workspaceID = selection.workspaceID
        let originalTabID = try #require(selection.workspace.resolvedSelectedTabID)
        let originalPanelID = try #require(selection.workspace.focusedPanelID)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-background-tab",
            agent: .codex,
            panelID: originalPanelID,
            windowID: selection.windowID,
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-background-tab",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Editing"),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(appStore.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil)))
        let backgroundedWorkspace = try #require(appStore.state.workspacesByID[workspaceID])
        let backgroundTabID = try #require(backgroundedWorkspace.resolvedSelectedTabID)
        #expect(backgroundTabID != originalTabID)

        #expect(sessionStore.sessionRegistry.activeSession(for: originalPanelID)?.sessionID == "sess-background-tab")
        #expect(sessionStore.workspaceStatuses(for: workspaceID).map(\.panelID).contains(originalPanelID))

        #expect(appStore.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: originalTabID)))
        #expect(sessionStore.panelStatus(for: originalPanelID)?.status.kind == .working)
    }

    @Test
    func workspaceStatusesFollowSessionCreationOrder() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let orderedPanelIDs = selection.workspace.terminalPanelIDsInDisplayOrder
        let leftPanelID = try #require(orderedPanelIDs.first)
        let rightPanelID = try #require(orderedPanelIDs.last)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-right",
            agent: .codex,
            panelID: rightPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo/right",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-right",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Right panel"),
            at: startedAt.addingTimeInterval(2)
        )

        sessionStore.startSession(
            sessionID: "sess-left",
            agent: .claude,
            panelID: leftPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo/left",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-left",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Left panel"),
            at: startedAt.addingTimeInterval(1)
        )

        let statuses = sessionStore.workspaceStatuses(for: selection.workspaceID)
        #expect(statuses.map(\.panelID) == [rightPanelID, leftPanelID])
    }

    @Test
    func workspaceStatusesStayStableWhenSelectedTabChanges() throws {
        let appStore = AppStore(persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)

        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let workspaceID = selection.workspaceID
        let originalTabID = try #require(selection.workspace.resolvedSelectedTabID)
        let originalPanelID = try #require(selection.workspace.focusedPanelID)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-original-tab",
            agent: .codex,
            panelID: originalPanelID,
            windowID: selection.windowID,
            workspaceID: workspaceID,
            cwd: "/repo/original",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-original-tab",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Original tab"),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(appStore.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil)))
        let workspaceWithNewTab = try #require(appStore.state.workspacesByID[workspaceID])
        let newSelectedTabID = try #require(workspaceWithNewTab.resolvedSelectedTabID)
        #expect(newSelectedTabID != originalTabID)
        let newSelectedPanelID = try #require(workspaceWithNewTab.focusedPanelID)

        sessionStore.startSession(
            sessionID: "sess-new-tab",
            agent: .claude,
            panelID: newSelectedPanelID,
            windowID: selection.windowID,
            workspaceID: workspaceID,
            cwd: "/repo/new",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-new-tab",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "New tab"),
            at: startedAt.addingTimeInterval(3)
        )

        #expect(sessionStore.workspaceStatuses(for: workspaceID).map(\.sessionID) == ["sess-original-tab", "sess-new-tab"])

        #expect(appStore.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: originalTabID)))
        #expect(sessionStore.workspaceStatuses(for: workspaceID).map(\.sessionID) == ["sess-original-tab", "sess-new-tab"])

        #expect(appStore.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: newSelectedTabID)))
        #expect(sessionStore.workspaceStatuses(for: workspaceID).map(\.sessionID) == ["sess-original-tab", "sess-new-tab"])
    }

    @Test
    func handleLocalInterruptResetsWorkingClaudeSession() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-working",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding"),
            at: startedAt.addingTimeInterval(1)
        )

        let didReset = sessionStore.handleLocalInterruptForPanelIfActive(
            panelID: panelID,
            kind: .escape,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didReset)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt")
        )
    }

    @Test
    func handleLocalInterruptDoesNotResetFallbackTrackedWorkingCodexSessionOnEscape() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-codex-working",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .sessionLogFallback(reason: "test"),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-codex-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding"),
            at: startedAt.addingTimeInterval(1)
        )

        let didReset = sessionStore.handleLocalInterruptForPanelIfActive(
            panelID: panelID,
            kind: .escape,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didReset == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .working, summary: "Working", detail: "Responding")
        )
    }

    @Test
    func handleLocalInterruptResetsHookTrackedWorkingCodexSessionOnEscape() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-codex-hook-working",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-codex-hook-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding"),
            at: startedAt.addingTimeInterval(1)
        )

        let didReset = sessionStore.handleLocalInterruptForPanelIfActive(
            panelID: panelID,
            kind: .escape,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didReset)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt")
        )
    }

    @Test
    func handleLocalInterruptResetsHookTrackedNeedsApprovalCodexSessionOnEscape() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-codex-hook-approval",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-codex-hook-approval",
            status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
            at: startedAt.addingTimeInterval(1)
        )

        let didReset = sessionStore.handleLocalInterruptForPanelIfActive(
            panelID: panelID,
            kind: .escape,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didReset)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt")
        )
    }

    @Test
    func handleLocalInterruptKeepsCodexControlCResetBehavior() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-codex-control-c",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-codex-control-c",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding"),
            at: startedAt.addingTimeInterval(1)
        )

        let didReset = sessionStore.handleLocalInterruptForPanelIfActive(
            panelID: panelID,
            kind: .controlC,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didReset)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt")
        )
    }

    @Test
    func handleLocalInterruptDoesNotResetCodexSessionForDifferentPanelEscape() {
        let sessionStore = SessionRuntimeStore()
        let codexPanelID = UUID()
        let otherPanelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-codex-focused-panel",
            agent: .codex,
            panelID: codexPanelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-codex-focused-panel",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding"),
            at: startedAt.addingTimeInterval(1)
        )

        let didReset = sessionStore.handleLocalInterruptForPanelIfActive(
            panelID: otherPanelID,
            kind: .escape,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didReset == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: codexPanelID)?.status ==
                SessionStatus(kind: .working, summary: "Working", detail: "Responding")
        )
    }

}
