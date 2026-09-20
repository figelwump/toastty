import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

struct RemoteAccessServiceSafetyTests {
    @MainActor
    @Test func rootModelSwitchesPublishWithoutTranscriptOrInputChanges() async throws {
        let fixture = try RemoteBootstrapFixture()
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.confirmCurrentLaunchBinding())
        let original = fixture.summary
        #expect(original.executionProfile == nil)

        let transcript = try FileHandle(forWritingTo: URL(filePath: fixture.resumeRecord.sessionFilePath))
        defer { try? transcript.close() }
        // Repeated values with the same timestamp are distinct reports in
        // file order. The third report must not be deduplicated against A.
        for model in ["model-A", "model-B", "model-A"] {
            fixture.server.removeAllBroadcasts()
            let line = #"{"timestamp":"2026-08-07T10:00:05.200Z","type":"turn_context","payload":{"model":"\#(model)","effort":"high"}}"# + "\n"
            try transcript.write(contentsOf: Data(line.utf8))
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline,
                  !fixture.server.sessionListSnapshots.contains(where: { snapshot in
                      snapshot.conversations.contains {
                          $0.conversationID == fixture.conversationID && $0.executionProfile?.modelIdentifier == model
                      }
                  }) {
                try await Task.sleep(for: .milliseconds(20))
            }
            let delivered = try #require(fixture.server.sessionListSnapshots.last?.conversations.first {
                $0.conversationID == fixture.conversationID
            })
            #expect(delivered.executionProfile == .init(modelIdentifier: model, reasoningEffort: "high"))
            #expect(delivered.latestSequence == original.latestSequence)
            #expect(delivered.inputAvailability == original.inputAvailability)
            #expect(delivered.state == original.state)
            #expect(fixture.summary.executionProfile == delivered.executionProfile)
            #expect(!fixture.server.broadcasts.contains {
                if case .conversationEvents = $0 { return true }
                return false
            })
        }
    }

    @MainActor
    @Test func workspaceInventoryCarriesSortedAnnotationsWithResolvedColors() throws {
        var state = AppState.bootstrap()
        let workspaceID = try #require(state.selectedWorkspaceSelection()?.workspaceID)
        state.workspacesByID[workspaceID]?.annotations = [
            "task-status": WorkspaceAnnotation(text: "Working"),
            "github-pr": WorkspaceAnnotation(text: "PR #12", url: "https://github.com/example/repo/pull/12"),
            "edited": WorkspaceAnnotation(text: "Hand edited", url: "file:///etc/hosts"),
        ]

        let inventory = RemoteAccessService.workspaceInventory(
            state: state, annotationColorTokens: ["github-pr": .named(.green)])
        let annotations = try #require(inventory.first { $0.id == workspaceID }?.annotations)

        #expect(annotations.map(\.key) == ["edited", "github-pr", "task-status"])
        #expect(annotations[0].url == nil, "A link the sidebar would not open is not sent")
        #expect(annotations[1].url == URL(string: "https://github.com/example/repo/pull/12"))
        #expect(annotations[1].color == "#5BA08A")
        #expect(annotations[2].color == WorkspaceAnnotationChipPalette.hexString(
            AnnotationStyleStore.fallbackColorToken(forKey: "task-status").baseHexValue))
    }

    @MainActor
    @Test func annotationSetColorChangeAndClearEachRebroadcastTheSessionList() async throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let workspaceID = try #require(store.state.selectedWorkspaceSelection()?.workspaceID)
        let server = RemoteAccessGatewayServerSpy()
        let runtimeHome = "/tmp/toastty-remote-access-annotations-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: runtimeHome) }
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/toastty-remote-access-test-home",
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome]
        )
        let annotationStyleStore = AnnotationStyleStore(runtimePaths: runtimePaths)
        // No sessions exist, so nothing else keeps publishing session lists
        // after setup; without the style-store subscription the color step
        // times out.
        let service = RemoteAccessService(
            store: store,
            annotationStyleStore: annotationStyleStore,
            sessionRuntimeStore: SessionRuntimeStore(),
            terminalRuntimeRegistry: TerminalRuntimeRegistry(),
            runtimePaths: runtimePaths,
            port: 42_995,
            initiallyEnabled: false,
            gatewayServerFactory: { _ in server }
        )
        defer { service.setEnabled(false, persist: false) }
        service.setEnabled(true, persist: false)
        server.reportReady(port: 42_995)

        server.removeAllBroadcasts()
        #expect(store.send(.setWorkspaceAnnotation(
            workspaceID: workspaceID,
            key: "github-pr",
            annotation: WorkspaceAnnotation(text: "PR #12", url: "https://github.com/example/repo/pull/12")
        )))
        let set = try await Self.deliveredAnnotations(in: workspaceID, from: server) { !$0.isEmpty }
        #expect(set.map(\.text) == ["PR #12"])

        // A color-only change never touches AppState.
        server.removeAllBroadcasts()
        #expect(try annotationStyleStore.setColor(.named(.red), forKey: "github-pr"))
        let recolored = try await Self.deliveredAnnotations(in: workspaceID, from: server) { !$0.isEmpty }
        #expect(recolored.map(\.color) == ["#E55C5C"])

        server.removeAllBroadcasts()
        #expect(store.send(.clearWorkspaceAnnotation(workspaceID: workspaceID, key: "github-pr")))
        let cleared = try await Self.deliveredAnnotations(in: workspaceID, from: server) { $0.isEmpty }
        #expect(cleared.isEmpty)
    }

    /// Waits for a broadcast session list whose annotations for the workspace
    /// satisfy `isExpected`.
    @MainActor
    private static func deliveredAnnotations(
        in workspaceID: UUID,
        from server: RemoteAccessGatewayServerSpy,
        where isExpected: ([RemoteWorkspaceAnnotation]) -> Bool
    ) async throws -> [RemoteWorkspaceAnnotation] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let annotations = server.sessionListSnapshots.last?
                .workspaces.first(where: { $0.id == workspaceID })?.annotations,
               isExpected(annotations) {
                return annotations
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("No session_list broadcast delivered the expected annotations")
        return []
    }

    @Test func readAcknowledgementAcceptsAuthoritativeEmptyAndRejectsStaleBoundaries() {
        let runID = RemoteProjectionRunID()
        let empty = RemoteConversationReadAcknowledgementRequest(
            conversationID: RemoteConversationID(),
            projectionRunID: runID,
            projectionGeneration: 2,
            observedThroughSequence: 0
        )
        let matching = RemoteConversationReadAcknowledgementRequest(
            conversationID: RemoteConversationID(),
            projectionRunID: runID,
            projectionGeneration: 2,
            observedThroughSequence: 8
        )

        #expect(RemoteAccessService.readAcknowledgementResult(
            request: empty,
            currentProjectionRunID: runID,
            currentProjectionGeneration: 2,
            currentLatestSequence: 0,
            isUnread: true
        ) == .acknowledged)
        #expect(RemoteAccessService.readAcknowledgementResult(
            request: matching,
            currentProjectionRunID: runID,
            currentProjectionGeneration: 2,
            currentLatestSequence: 0,
            isUnread: true
        ) == .staleBoundary)
        #expect(RemoteAccessService.readAcknowledgementResult(
            request: matching,
            currentProjectionRunID: RemoteProjectionRunID(),
            currentProjectionGeneration: 2,
            currentLatestSequence: 8,
            isUnread: true
        ) == .staleBoundary)
        #expect(RemoteAccessService.readAcknowledgementResult(
            request: matching,
            currentProjectionRunID: runID,
            currentProjectionGeneration: 3,
            currentLatestSequence: 8,
            isUnread: true
        ) == .staleBoundary)
        #expect(RemoteAccessService.readAcknowledgementResult(
            request: matching,
            currentProjectionRunID: runID,
            currentProjectionGeneration: 2,
            currentLatestSequence: 9,
            isUnread: true
        ) == .staleBoundary)
        #expect(RemoteAccessService.readAcknowledgementResult(
            request: matching,
            currentProjectionRunID: runID,
            currentProjectionGeneration: 2,
            currentLatestSequence: 7,
            isUnread: true
        ) == .staleBoundary)
    }

    @Test func readAcknowledgementIsIdempotentAfterCurrentBoundaryIsRead() {
        let runID = RemoteProjectionRunID()
        let request = RemoteConversationReadAcknowledgementRequest(
            conversationID: RemoteConversationID(),
            projectionRunID: runID,
            projectionGeneration: 2,
            observedThroughSequence: 8
        )

        #expect(RemoteAccessService.readAcknowledgementResult(
            request: request,
            currentProjectionRunID: runID,
            currentProjectionGeneration: 2,
            currentLatestSequence: 8,
            isUnread: true
        ) == .acknowledged)
        #expect(RemoteAccessService.readAcknowledgementResult(
            request: request,
            currentProjectionRunID: runID,
            currentProjectionGeneration: 2,
            currentLatestSequence: 8,
            isUnread: false
        ) == .alreadyRead)
    }

    @Test func desktopSessionStatusMapsToRemotePresentationStatusWithUnreadReadySemantics() {
        let cases: [(SessionStatusKind, RemoteSessionPresentationStatus)] = [
            (.idle, .idle),
            (.working, .working),
            (.needsApproval, .needsApproval),
            (.error, .error),
        ]

        for (desktop, remote) in cases {
            #expect(RemoteAccessService.remotePresentationStatus(
                for: desktop,
                isUnread: false
            ) == remote)
            #expect(RemoteAccessService.remotePresentationStatus(
                for: desktop,
                isUnread: true
            ) == remote)
        }
        #expect(RemoteAccessService.remotePresentationStatus(
            for: .ready,
            isUnread: true
        ) == .ready)
        #expect(RemoteAccessService.remotePresentationStatus(
            for: .ready,
            isUnread: false
        ) == .idle)
    }

    @MainActor
    @Test func readAcknowledgementPublishesReadReadyConversationAsIdle() throws {
        let fixture = try RemoteBootstrapFixture(agent: .claude, statusKind: .ready)
        defer { fixture.removeRuntimeFiles() }
        let workspaceID = try #require(fixture.summary.placement.workspaceID)

        #expect(fixture.store.send(.recordDesktopNotification(
            workspaceID: workspaceID,
            panelID: fixture.panelID
        )))
        let before = fixture.service.facadeSessionList(at: fixture.confirmedAt)
        let beforeSummary = try #require(before.conversations.first {
            $0.conversationID == fixture.conversationID
        })
        #expect(beforeSummary.presentationStatus == .ready)

        let result = fixture.service.acknowledgeConversationRead(
            RemoteConversationReadAcknowledgementRequest(
                conversationID: fixture.conversationID,
                projectionRunID: before.projectionRunID,
                projectionGeneration: beforeSummary.projectionGeneration,
                observedThroughSequence: beforeSummary.latestSequence
            ),
            device: RemoteDeviceRecord(
                name: "Test iPhone",
                scopes: [.read],
                createdAt: fixture.confirmedAt
            )
        )

        #expect(result == .acknowledged)
        #expect(fixture.summary.presentationStatus == .idle)
        #expect(fixture.server.sessionListSnapshots.last?.conversations.first {
            $0.conversationID == fixture.conversationID
        }?.presentationStatus == .idle)
    }

    @MainActor
    @Test func readReadyRestorableClaudeConversationProjectsIdleAfterRead() throws {
        let fixture = try RemoteBootstrapFixture(agent: .claude, statusKind: .ready)
        defer { fixture.removeRuntimeFiles() }
        let workspaceID = try #require(fixture.summary.placement.workspaceID)

        #expect(fixture.store.send(.recordDesktopNotification(
            workspaceID: workspaceID,
            panelID: fixture.panelID
        )))
        fixture.sessionRuntimeStore.stopSession(
            sessionID: fixture.sessionID,
            at: fixture.confirmedAt.addingTimeInterval(1)
        )
        #expect(fixture.publishResumeRecord())
        #expect(fixture.summary.presentationStatus == .ready)

        #expect(fixture.store.send(.markPanelNotificationsRead(
            workspaceID: workspaceID,
            panelID: fixture.panelID
        )))

        #expect(fixture.summary.presentationStatus == .idle)
    }

    @MainActor
    @Test func restorableClaudeSessionsRemainVisibleAcrossWorkspaceTabSelection() throws {
        let workspaceID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let tabAID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let tabBID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        let panelAID = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
        let panelBID = UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!
        let conversationA = RemoteConversationID(
            rawValue: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        )
        let conversationB = RemoteConversationID(
            rawValue: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        )
        let capturedAt = Date(timeIntervalSince1970: 1_787_500_000)
        let runtimeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-remote-access-background-tabs-\(UUID().uuidString)")
        let transcriptA = runtimeHome.appendingPathComponent("claude-a.jsonl")
        let transcriptB = runtimeHome.appendingPathComponent("claude-b.jsonl")
        try FileManager.default.createDirectory(at: runtimeHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeHome) }
        try #"{"type":"user","sessionId":"native-claude-a","uuid":"user-a","parentUuid":null,"isSidechain":false,"timestamp":"2026-08-24T12:00:00Z","message":{"role":"user","content":"Resume A"}}"#
            .write(to: transcriptA, atomically: true, encoding: .utf8)
        try #"{"type":"user","sessionId":"native-claude-b","uuid":"user-b","parentUuid":null,"isSidechain":false,"timestamp":"2026-08-24T12:00:00Z","message":{"role":"user","content":"Resume B"}}"#
            .write(to: transcriptB, atomically: true, encoding: .utf8)

        let resumeRecordA = ManagedAgentResumeRecord(
            agent: .claude,
            nativeSessionID: "native-claude-a",
            sessionFilePath: transcriptA.path,
            cwd: "/repo/a",
            capturedAt: capturedAt
        )
        let resumeRecordB = ManagedAgentResumeRecord(
            agent: .claude,
            nativeSessionID: "native-claude-b",
            sessionFilePath: transcriptB.path,
            cwd: "/repo/b",
            capturedAt: capturedAt.addingTimeInterval(1)
        )
        let tabA = WorkspaceTabState(
            id: tabAID,
            layoutTree: .slot(slotID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!, panelID: panelAID),
            panels: [
                panelAID: .terminal(TerminalPanelState(
                    title: "Claude A",
                    shell: "zsh",
                    cwd: "/repo/a",
                    resumeRecord: resumeRecordA,
                    remoteConversationID: conversationA
                )),
            ],
            focusedPanelID: panelAID
        )
        let tabB = WorkspaceTabState(
            id: tabBID,
            layoutTree: .slot(slotID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!, panelID: panelBID),
            panels: [
                panelBID: .terminal(TerminalPanelState(
                    title: "Claude B",
                    shell: "zsh",
                    cwd: "/repo/b",
                    resumeRecord: resumeRecordB,
                    remoteConversationID: conversationB
                )),
            ],
            focusedPanelID: panelBID
        )
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Claude Workspace",
            selectedTabID: tabAID,
            tabIDs: [tabAID, tabBID],
            tabsByID: [tabAID: tabA, tabBID: tabB]
        )
        let windowID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let state = AppState(
            windows: [WindowState(
                id: windowID,
                frame: CGRectCodable(x: 120, y: 120, width: 1280, height: 760),
                workspaceIDs: [workspaceID],
                selectedWorkspaceID: workspaceID
            )],
            workspacesByID: [workspaceID: workspace],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let server = RemoteAccessGatewayServerSpy()
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: runtimeHome.path,
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome.path]
        )
        let service = RemoteAccessService(
            store: store,
            annotationStyleStore: AnnotationStyleStore(runtimePaths: runtimePaths),
            sessionRuntimeStore: sessionRuntimeStore,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            runtimePaths: runtimePaths,
            port: 42_996,
            initiallyEnabled: false,
            gatewayServerFactory: { _ in server }
        )
        defer { service.setEnabled(false, persist: false) }

        service.setEnabled(true, persist: false)
        server.reportReady(port: 42_996)

        let initialSnapshot = service.facadeSessionList(at: capturedAt)
        #expect(store.state.workspacesByID[workspaceID]?.selectedTabID == tabAID)
        #expect(initialSnapshot.conversations.count == 2)
        #expect(Set(initialSnapshot.conversations.map(\.conversationID)) == Set([conversationA, conversationB]))

        #expect(store.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: tabBID)))
        let afterSelectionSnapshot = service.facadeSessionList(at: capturedAt.addingTimeInterval(2))
        #expect(store.state.workspacesByID[workspaceID]?.selectedTabID == tabBID)
        #expect(afterSelectionSnapshot.conversations.count == 2)
        #expect(Set(afterSelectionSnapshot.conversations.map(\.conversationID)) == Set([conversationA, conversationB]))
    }

    @MainActor
    @Test func scratchpadAssociationsRequireExactLiveSessionAndMatchingSummary() throws {
        let fixture = try RemoteBootstrapFixture(agent: .claude)
        defer { fixture.removeRuntimeFiles() }
        var state = fixture.store.state
        let summary = fixture.summary
        let workspaceID = try #require(summary.placement.workspaceID)
        let tabID = try #require(state.workspacesByID[workspaceID]?.selectedTabID)
        let link = ScratchpadSessionLink(
            sessionID: fixture.sessionID, agent: .claude,
            sourcePanelID: UUID(), sourceWorkspaceID: UUID())
        let firstID = UUID()
        let secondID = UUID()
        let standaloneID = UUID()
        for panelID in [firstID, secondID, standaloneID] {
            let documentID = UUID()
            state.workspacesByID[workspaceID]?.tabsByID[tabID]?.rightAuxPanel.appendTab(
                .init(
                    id: UUID(), identity: .scratchpad(id: documentID), panelID: panelID,
                    panelState: .web(.init(
                        definition: .scratchpad,
                        scratchpad: .init(documentID: documentID,
                            sessionLink: panelID == standaloneID ? nil : link, revision: 1)))))
        }
        var registry = fixture.sessionRuntimeStore.sessionRegistry
        let associations = RemoteAccessService.scratchpadConversationAssociations(
            state: state, registry: registry, conversations: [summary])
        #expect(associations == [firstID: fixture.conversationID, secondID: fixture.conversationID])
        let inventory = RemoteAccessService.workspaceInventory(state: state, associations: associations)
        #expect(inventory.flatMap(\.panels).filter { $0.associatedConversationID == fixture.conversationID }.count == 2)
        #expect(RemoteAccessService.scratchpadConversationAssociations(
            state: state, registry: registry, conversations: []).isEmpty)
        var staleSummary = summary
        staleSummary.conversationID = RemoteConversationID()
        #expect(RemoteAccessService.scratchpadConversationAssociations(
            state: state, registry: registry, conversations: [staleSummary]).isEmpty)
        for summaries in [[summary, staleSummary], [staleSummary, summary]] {
            #expect(RemoteAccessService.scratchpadConversationAssociations(
                state: state, registry: registry, conversations: summaries) == associations)
        }
        var wrongProvider = summary
        wrongProvider.provider = .codex
        #expect(RemoteAccessService.scratchpadConversationAssociations(
            state: state, registry: registry, conversations: [wrongProvider]).isEmpty)
        registry.stopSession(sessionID: fixture.sessionID, at: .now)
        #expect(RemoteAccessService.scratchpadConversationAssociations(
            state: state, registry: registry, conversations: [summary]).isEmpty)
        registry.startSession(
            sessionID: "replacement", agent: .claude, panelID: fixture.panelID,
            windowID: UUID(), workspaceID: workspaceID, cwd: nil, repoRoot: nil, at: .now)
        #expect(RemoteAccessService.scratchpadConversationAssociations(
            state: state, registry: registry, conversations: [summary]).isEmpty)
    }

    @MainActor
    @Test func scratchpadLinkOnlyChangeBroadcastsAssociationWithoutRevisionChange() async throws {
        let fixture = try RemoteBootstrapFixture(agent: .claude)
        defer { fixture.removeRuntimeFiles() }
        let workspaceID = try #require(fixture.summary.placement.workspaceID)
        let documentID = UUID()
        let scratchpad = ScratchpadState(documentID: documentID, revision: 1)
        #expect(fixture.store.send(.createWebPanel(
            workspaceID: workspaceID,
            panel: .init(definition: .scratchpad, scratchpad: scratchpad), placement: .rightPanel)))
        let panelID = try #require(fixture.service.facadeSessionList(at: .now).workspaces
            .flatMap(\.panels).first { $0.kind == "scratchpad" }?.panelID)
        await SessionRuntimeStoreTestSupport.waitUntil {
            fixture.server.sessionListSnapshots.last?.workspaces.flatMap(\.panels)
                .contains { $0.panelID == panelID } == true
        }
        fixture.server.removeAllBroadcasts()
        var linked = scratchpad
        linked.sessionLink = .init(
            sessionID: fixture.sessionID, agent: .claude,
            sourcePanelID: fixture.panelID, sourceWorkspaceID: workspaceID)
        #expect(fixture.store.send(.updateScratchpadPanelState(
            panelID: panelID, scratchpad: linked, title: nil)))
        await SessionRuntimeStoreTestSupport.waitUntil {
            fixture.server.sessionListSnapshots.last?.workspaces.flatMap(\.panels)
                .first { $0.panelID == panelID }?.associatedConversationID == fixture.conversationID
        }
        let panel = try #require(fixture.server.sessionListSnapshots.last?.workspaces.flatMap(\.panels)
            .first { $0.panelID == panelID })
        #expect(panel.associatedConversationID == fixture.conversationID)
        #expect(panel.revision == 1)
    }

    @MainActor
    @Test func desktopReadTransitionSchedulesFreshIdleSessionList() async throws {
        let fixture = try RemoteBootstrapFixture(agent: .claude, statusKind: .ready)
        defer { fixture.removeRuntimeFiles() }
        let workspaceID = try #require(fixture.summary.placement.workspaceID)

        #expect(fixture.store.send(.recordDesktopNotification(
            workspaceID: workspaceID,
            panelID: fixture.panelID
        )))
        fixture.server.removeAllBroadcasts()
        #expect(fixture.store.send(.markPanelNotificationsRead(
            workspaceID: workspaceID,
            panelID: fixture.panelID
        )))

        await SessionRuntimeStoreTestSupport.waitUntil {
            fixture.server.sessionListSnapshots.last?.conversations.first {
                $0.conversationID == fixture.conversationID
            }?.presentationStatus == .idle
        }
        #expect(fixture.server.sessionListSnapshots.count == 1)
    }

    @MainActor
    @Test func desktopUnreadTransitionSchedulesFreshReadySessionList() async throws {
        let fixture = try RemoteBootstrapFixture(agent: .claude, statusKind: .ready)
        defer { fixture.removeRuntimeFiles() }
        let workspaceID = try #require(fixture.summary.placement.workspaceID)

        #expect(fixture.summary.presentationStatus == .idle)
        fixture.server.removeAllBroadcasts()
        #expect(fixture.store.send(.recordDesktopNotification(
            workspaceID: workspaceID,
            panelID: fixture.panelID
        )))

        await SessionRuntimeStoreTestSupport.waitUntil {
            fixture.server.sessionListSnapshots.last?.conversations.first {
                $0.conversationID == fixture.conversationID
            }?.presentationStatus == .ready
        }
        #expect(fixture.server.sessionListSnapshots.count == 1)
    }

    @Test func desktopSessionDetailProjectsThroughSharedWireNormalization() {
        #expect(RemoteAccessService.remoteStatusDetail(from: nil) == nil)
        #expect(RemoteAccessService.remoteStatusDetail(from: " \n ") == nil)
        #expect(RemoteAccessService.remoteStatusDetail(
            from: "  Indexing\u{0000} workspace\u{202E}  "
        ) == "Indexing workspace")

        let grapheme = "👩🏽‍💻"
        let projected = RemoteAccessService.remoteStatusDetail(
            from: String(
                repeating: grapheme,
                count: RemoteConversationSummary.maximumStatusDetailLength + 1
            )
        )
        #expect(projected?.count == RemoteConversationSummary.maximumStatusDetailLength)
        #expect(projected == String(
            repeating: grapheme,
            count: RemoteConversationSummary.maximumStatusDetailLength
        ))
    }

    @Test func transcriptReplacementExpiresPendingSendBeforeIdenticalHistoryReplay() throws {
        let conversationID = RemoteConversationID()
        let unaffectedConversationID = RemoteConversationID()
        let pendingText = "Please run the focused tests."
        var correlator = RemotePendingSendCorrelator()
        correlator.record(RemoteMessageSendRequest(
            conversationID: conversationID,
            clientRequestID: "new-request",
            expectedInputEpoch: RemoteInputEpoch(bindingID: UUID(), counter: 1),
            text: pendingText
        ))
        correlator.record(RemoteMessageSendRequest(
            conversationID: unaffectedConversationID,
            clientRequestID: "unaffected-request",
            expectedInputEpoch: RemoteInputEpoch(bindingID: UUID(), counter: 1),
            text: pendingText
        ))

        // `.fileReplaced` replays the transcript from byte zero. The service
        // invokes this expiration before it starts the replacement tailer.
        correlator.discard(for: conversationID)
        let replayed = correlator.stamp(
            [Self.userObservation(text: pendingText, fingerprint: "historical")],
            for: conversationID
        )
        let replayedPayload = try #require(Self.userPayload(from: replayed[0]))

        #expect(replayedPayload.origin == .unknown)
        #expect(replayedPayload.clientRequestID == nil)

        // Expiration is conversation-scoped, not a global correlation reset.
        let unaffected = correlator.stamp(
            [Self.userObservation(text: pendingText, fingerprint: "current")],
            for: unaffectedConversationID
        )
        let unaffectedPayload = try #require(Self.userPayload(from: unaffected[0]))
        #expect(unaffectedPayload.origin == .remote)
        #expect(unaffectedPayload.clientRequestID == "unaffected-request")
        #expect(unaffectedPayload.text == pendingText)
    }

    @Test func pendingSendCorrelationRemainsFIFOAndExpiresOldestMismatch() throws {
        let conversationID = RemoteConversationID()
        var correlator = RemotePendingSendCorrelator()
        correlator.record(Self.request(
            conversationID: conversationID,
            clientRequestID: "first-request",
            text: "first text"
        ))
        correlator.record(Self.request(
            conversationID: conversationID,
            clientRequestID: "second-request",
            text: "second text"
        ))

        let firstObservation = correlator.stamp(
            [Self.userObservation(text: "second text", fingerprint: "first-observation")],
            for: conversationID
        )
        let firstPayload = try #require(Self.userPayload(from: firstObservation[0]))
        #expect(firstPayload.origin == .unknown)
        #expect(firstPayload.clientRequestID == nil)

        let secondObservation = correlator.stamp(
            [Self.userObservation(text: "second text", fingerprint: "second-observation")],
            for: conversationID
        )
        let secondPayload = try #require(Self.userPayload(from: secondObservation[0]))
        #expect(secondPayload.origin == .remote)
        #expect(secondPayload.clientRequestID == "second-request")
    }

    @Test func pendingSendCorrelationRetainsOnlyNewestThirtyTwoRequests() throws {
        let conversationID = RemoteConversationID()
        var correlator = RemotePendingSendCorrelator()
        for index in 1...33 {
            correlator.record(Self.request(
                conversationID: conversationID,
                clientRequestID: "request-\(index)",
                text: "text \(index)"
            ))
        }

        let observation = correlator.stamp(
            [Self.userObservation(text: "text 2", fingerprint: "oldest-retained")],
            for: conversationID
        )
        let payload = try #require(Self.userPayload(from: observation[0]))
        #expect(payload.origin == .remote)
        #expect(payload.clientRequestID == "request-2")
    }

    @Test func finalPendingConsumptionRemovesConversationTrackingForMatchAndMismatch() {
        let matchingConversationID = RemoteConversationID()
        let mismatchingConversationID = RemoteConversationID()
        var correlator = RemotePendingSendCorrelator()
        correlator.record(Self.request(
            conversationID: matchingConversationID,
            clientRequestID: "matching-request",
            text: "matching text"
        ))
        correlator.record(Self.request(
            conversationID: mismatchingConversationID,
            clientRequestID: "mismatching-request",
            text: "expected text"
        ))

        _ = correlator.stamp(
            [Self.userObservation(text: "matching text", fingerprint: "match")],
            for: matchingConversationID
        )
        #expect(correlator.conversationIDs == Set([mismatchingConversationID]))

        _ = correlator.stamp(
            [Self.userObservation(text: "different text", fingerprint: "mismatch")],
            for: mismatchingConversationID
        )
        #expect(correlator.conversationIDs.isEmpty)
    }

    @MainActor
    @Test func persistedResumeRecordStaysLockedUntilCurrentLaunchOwnershipIsConfirmed() throws {
        let fixture = try RemoteBootstrapFixture()
        defer { fixture.removeRuntimeFiles() }

        #expect(fixture.summary.inputAvailability ==
            .unavailable(reason: .unknownProviderState))

        #expect(fixture.confirmCurrentLaunchBinding())
        guard case .openPrompt(let epoch) = fixture.summary.inputAvailability else {
            Issue.record("Expected current-launch Codex ownership to open the resumed prompt")
            return
        }
        #expect(epoch.counter == 1)

        // Re-publishing the same ownership fact must not mint a second epoch.
        #expect(fixture.publishResumeRecord(
            capturedAt: fixture.confirmedAt.addingTimeInterval(1)
        ))
        #expect(fixture.summary.inputAvailability == .openPrompt(epoch: epoch))
    }

    @MainActor
    @Test func localInputBeforeCurrentLaunchConfirmationPreventsPromptBootstrap() throws {
        let fixture = try RemoteBootstrapFixture()
        defer { fixture.removeRuntimeFiles() }

        fixture.terminalRuntimeRegistry.localInputObserver?(fixture.panelID)
        #expect(fixture.confirmCurrentLaunchBinding())

        #expect(fixture.summary.inputAvailability ==
            .unavailable(reason: .unknownProviderState))
    }

    @MainActor
    @Test func currentLaunchConfirmationBootstrapsEveryReadyManagedProviderButNotWorking() throws {
        let workingFixture = try RemoteBootstrapFixture(statusKind: .working)
        defer { workingFixture.removeRuntimeFiles() }
        #expect(workingFixture.confirmCurrentLaunchBinding())
        #expect(workingFixture.summary.inputAvailability ==
            .unavailable(reason: .unknownProviderState))

        for provider in [AgentKind.claude, .opencode, .mimocode, .pi] {
            let fixture = try RemoteBootstrapFixture(agent: provider)
            defer { fixture.removeRuntimeFiles() }
            #expect(fixture.confirmCurrentLaunchBinding(), "\(provider.rawValue)")
            guard case .openPrompt = fixture.summary.inputAvailability else {
                Issue.record("Expected current-launch \(provider.rawValue) prompt")
                continue
            }
        }
    }

    /// Remote clients title a conversation the way the sidebar names its row,
    /// so a provider's generated name replaces the panel label.
    @MainActor
    @Test func providerSessionNameTitlesTheRemoteConversation() throws {
        let fixture = try RemoteBootstrapFixture(agent: .opencode)
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.confirmCurrentLaunchBinding())
        let panelLabelTitle = fixture.summary.title

        #expect(fixture.sessionRuntimeStore.applyReportedProviderSessionName(
            sessionID: fixture.sessionID,
            agent: .opencode,
            nativeSessionID: fixture.resumeRecord.nativeSessionID,
            name: "Build system explanation"
        ))

        #expect(panelLabelTitle != "Build system explanation")
        #expect(fixture.summary.title == "Build system explanation")
    }

    @MainActor
    @Test func bootstrappedPromptClosesWhenDesktopStartsWorking() async throws {
        let fixture = try RemoteBootstrapFixture()
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.confirmCurrentLaunchBinding())
        guard case .openPrompt(let epoch) = fixture.summary.inputAvailability else {
            Issue.record("Expected confirmed Codex prompt")
            return
        }

        fixture.sessionRuntimeStore.updateStatus(
            sessionID: fixture.sessionID,
            status: SessionStatus(kind: .working, summary: "Working"),
            at: fixture.confirmedAt.addingTimeInterval(1)
        )
        try await Task.sleep(for: .milliseconds(250))
        #expect(fixture.summary.state == .working)
        #expect(fixture.summary.inputAvailability == .unavailable(reason: .working))

        let result = fixture.service.performRemoteSend(
            RemoteMessageSendRequest(
                conversationID: fixture.conversationID,
                clientRequestID: "status-race",
                expectedInputEpoch: epoch,
                text: "Do not deliver"
            ),
            device: RemoteDeviceRecord(
                name: "Test iPhone",
                scopes: [.read, .send],
                createdAt: fixture.confirmedAt
            )
        )

        #expect(result == .rejected(reason: .surfaceUnavailable))
    }

    @MainActor
    @Test func providerFeedProjectsPiConversationContentWithoutGrantingHistoricalAuthority() throws {
        let fixture = try RemoteBootstrapFixture(agent: .pi)
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.confirmCurrentLaunchBinding())
        #expect(fixture.sessionRuntimeStore.resetProviderConversationFeed(
            managedSessionID: fixture.sessionID,
            provider: .pi,
            nativeSessionID: fixture.resumeRecord.nativeSessionID,
            snapshotID: "pi-snapshot-1",
            at: fixture.confirmedAt
        ))
        #expect(fixture.sessionRuntimeStore.ingestProviderConversationObservation(
            managedSessionID: fixture.sessionID,
            provider: .pi,
            nativeSessionID: fixture.resumeRecord.nativeSessionID,
            snapshotID: "pi-snapshot-1",
            observation: ProviderTranscriptObservation(
                timestamp: fixture.confirmedAt.addingTimeInterval(1),
                fingerprint: "managed:pi:assistant-1",
                payload: .transcript(.assistantMessage(.init(text: "Pi finished the work"))),
                mayAuthorizeCurrentRuntime: false
            )
        ))

        guard case .page(let page) = fixture.service.facadeConversationEvents(
            for: fixture.conversationID,
            after: nil,
            limit: 100
        ) else {
            Issue.record("Expected Pi conversation event page")
            return
        }
        #expect(page.events.contains { event in
            guard case .assistantMessage(let payload) = event.payload else { return false }
            return payload.text == "Pi finished the work"
        })
        guard case .openPrompt = fixture.summary.inputAvailability else {
            Issue.record("Historical feed replay closed the confirmed current prompt")
            return
        }
    }

    @MainActor
    @Test func claudeProviderFeedStabilizationSurvivesLatePassiveObservation() async throws {
        let fixture = try RemoteBootstrapFixture(
            agent: .claude,
            claudePromptStabilizationDelay: .milliseconds(40)
        )
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.confirmCurrentLaunchBinding())
        #expect(fixture.sessionRuntimeStore.resetProviderConversationFeed(
            managedSessionID: fixture.sessionID,
            provider: .claude,
            nativeSessionID: fixture.resumeRecord.nativeSessionID,
            snapshotID: "claude-stabilization",
            at: fixture.confirmedAt
        ))
        #expect(fixture.sessionRuntimeStore.ingestProviderConversationObservation(
            managedSessionID: fixture.sessionID,
            provider: .claude,
            nativeSessionID: fixture.resumeRecord.nativeSessionID,
            snapshotID: "claude-stabilization",
            observation: ProviderTranscriptObservation(
                timestamp: fixture.confirmedAt.addingTimeInterval(1),
                fingerprint: "managed:claude:user-1",
                payload: .transcript(.userMessage(.init(text: "Run it")))
            )
        ))
        #expect(fixture.sessionRuntimeStore.ingestProviderConversationObservation(
            managedSessionID: fixture.sessionID,
            provider: .claude,
            nativeSessionID: fixture.resumeRecord.nativeSessionID,
            snapshotID: "claude-stabilization",
            observation: ProviderTranscriptObservation(
                timestamp: fixture.confirmedAt.addingTimeInterval(2),
                fingerprint: "managed:claude:turn-end-1",
                payload: .turnEnded(turnID: "turn-1", reason: .completed)
            )
        ))

        #expect(fixture.summary.state == .awaitingInput)
        #expect(fixture.summary.inputAvailability ==
            .unavailable(reason: .unknownProviderState))

        #expect(fixture.sessionRuntimeStore.ingestProviderConversationObservation(
            managedSessionID: fixture.sessionID,
            provider: .claude,
            nativeSessionID: fixture.resumeRecord.nativeSessionID,
            snapshotID: "claude-stabilization",
            observation: ProviderTranscriptObservation(
                timestamp: fixture.confirmedAt.addingTimeInterval(2.1),
                turnID: "turn-1",
                fingerprint: "managed:claude:assistant-late",
                payload: .transcript(.assistantMessage(.init(text: "Done")))
            )
        ))
        #expect(fixture.summary.inputAvailability ==
            .unavailable(reason: .unknownProviderState))

        await SessionRuntimeStoreTestSupport.waitUntil {
            fixture.summary.inputAvailability.allowsRemoteSend
        }
        #expect(fixture.summary.inputAvailability.allowsRemoteSend)
    }

    @MainActor
    @Test func acceptedSendWithoutProviderEchoEmitsUnconfirmedReceipt() async throws {
        let fixture = try RemoteBootstrapFixture(
            sendConfirmationTimeout: .milliseconds(40)
        )
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.confirmCurrentLaunchBinding())
        guard case .openPrompt(let epoch) = fixture.summary.inputAvailability else {
            Issue.record("Expected confirmed prompt")
            return
        }
        fixture.terminalRuntimeRegistry.setAutomationPromptStateHandlerForTesting { _ in
            .idleAtPrompt
        }
        let panelID = fixture.panelID
        fixture.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting {
            _, _, deliveredPanelID, _ in deliveredPanelID == panelID
        }

        let request = RemoteMessageSendRequest(
            conversationID: fixture.conversationID,
            clientRequestID: "missing-provider-echo",
            expectedInputEpoch: epoch,
            text: "Please continue"
        )
        #expect(fixture.service.performRemoteSend(
            request,
            device: RemoteDeviceRecord(
                name: "Test iPhone",
                scopes: [.read, .send],
                createdAt: fixture.confirmedAt
            )
        ).isAccepted)

        await SessionRuntimeStoreTestSupport.waitUntil {
            guard case .page(let page) = fixture.service.facadeConversationEvents(
                for: fixture.conversationID,
                after: nil,
                limit: 100
            ) else {
                return false
            }
            return page.events.contains { event in
                guard case .sendDeliveryUnconfirmed(let payload) = event.payload else {
                    return false
                }
                return payload.clientRequestID == request.clientRequestID
            }
        }
        guard case .page(let page) = fixture.service.facadeConversationEvents(
            for: fixture.conversationID,
            after: nil,
            limit: 100
        ) else {
            Issue.record("Expected conversation event page")
            return
        }
        #expect(page.events.contains { event in
            guard case .sendDeliveryUnconfirmed(let payload) = event.payload else {
                return false
            }
            return payload.clientRequestID == request.clientRequestID
        })
    }

    @MainActor
    @Test func activationMintsIdentityBeforeListeningAndDisableRemovesLiveTracking() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let selection = try #require(store.state.selectedWorkspaceSelection())
        let panelID = try #require(selection.workspace.focusedPanelID)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.startSession(
            sessionID: "remote-lifecycle-session",
            agent: .codex,
            panelID: panelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: Date(timeIntervalSince1970: 1_786_000_000)
        )
        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let server = RemoteAccessGatewayServerSpy()
        let runtimeHome = "/tmp/toastty-remote-access-lifecycle-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: runtimeHome) }
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/toastty-remote-access-test-home",
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome]
        )
        let service = RemoteAccessService(
            store: store,
            annotationStyleStore: AnnotationStyleStore(runtimePaths: runtimePaths),
            sessionRuntimeStore: sessionRuntimeStore,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            runtimePaths: runtimePaths,
            port: 42_999,
            initiallyEnabled: false,
            gatewayServerFactory: { _ in server }
        )

        #expect(service.activationState == .off)
        #expect(terminalRuntimeRegistry.localInputObserver == nil)
        #expect(Self.remoteConversationID(panelID: panelID, in: store) == nil)
        #expect(server.startCallCount == 0)

        service.setEnabled(true, persist: false)

        let conversationID = try #require(Self.remoteConversationID(panelID: panelID, in: store))
        #expect(service.activationState == .starting)
        #expect(service.isEnabled)
        #expect(service.isReady == false)
        #expect(service.listeningPort == nil)
        #expect(terminalRuntimeRegistry.localInputObserver != nil)
        #expect(server.startedPorts == [42_999])
        service.issuePairingCode()
        #expect(service.currentPairingCode == nil)
        #expect(service.facadeConversationEvents(
            for: conversationID,
            after: nil,
            limit: 10
        ) != .conversationNotFound)

        server.reportReady(port: 42_999)

        #expect(service.activationState == .ready(port: 42_999))
        #expect(service.isReady)
        #expect(service.listeningPort == 42_999)

        server.reportWebSocketCounts(total: 2, native: 1)
        #expect(service.connectedClientCount == 2)
        #expect(service.connectedNativeClientCount == 1)

        service.setEnabled(false, persist: false)

        #expect(service.activationState == .off)
        #expect(service.isEnabled == false)
        #expect(service.connectedClientCount == 0)
        #expect(service.connectedNativeClientCount == 0)
        #expect(terminalRuntimeRegistry.localInputObserver == nil)
        #expect(server.stopCallCount == 1)
        #expect(Self.remoteConversationID(panelID: panelID, in: store) == conversationID)
        #expect(service.facadeConversationEvents(
            for: conversationID,
            after: nil,
            limit: 10
        ) == .conversationNotFound)

        // A delayed callback from a cancelled listener cannot reopen access.
        server.reportReady(port: 42_999)
        #expect(service.activationState == .off)
        #expect(server.stopCallCount == 2)

        server.reportFailure()
        #expect(service.activationState == .off)
        #expect(server.stopCallCount == 2)
    }

    @MainActor
    @Test func listenerFailureReturnsToNonPairableStateAndRemovesObservers() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let server = RemoteAccessGatewayServerSpy()
        let runtimeHome = "/tmp/toastty-remote-access-failure-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: runtimeHome) }
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/toastty-remote-access-test-home",
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome]
        )
        let service = RemoteAccessService(
            store: store,
            annotationStyleStore: AnnotationStyleStore(runtimePaths: runtimePaths),
            sessionRuntimeStore: sessionRuntimeStore,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            runtimePaths: runtimePaths,
            port: 42_998,
            initiallyEnabled: false,
            gatewayServerFactory: { _ in server }
        )

        service.setEnabled(true, persist: false)
        #expect(service.activationState == .starting)
        #expect(terminalRuntimeRegistry.localInputObserver != nil)

        server.reportFailure()

        #expect(service.isEnabled == false)
        #expect(service.isReady == false)
        #expect(service.startupError != nil)
        #expect(terminalRuntimeRegistry.localInputObserver == nil)
        #expect(server.stopCallCount == 1)

        service.setEnabled(true, persist: false)
        #expect(service.activationState == .starting)
        #expect(terminalRuntimeRegistry.localInputObserver != nil)
        #expect(server.startCallCount == 2)

        server.reportReady(port: 42_998)
        #expect(service.activationState == .ready(port: 42_998))

        server.reportFailure()
        #expect(service.isEnabled == false)
        #expect(service.isReady == false)
        #expect(service.startupError != nil)
        #expect(terminalRuntimeRegistry.localInputObserver == nil)
        #expect(server.stopCallCount == 2)
    }

    @MainActor
    private static func remoteConversationID(panelID: UUID, in store: AppStore) -> RemoteConversationID? {
        for workspace in store.state.workspacesByID.values {
            guard case .terminal(let terminalState) = workspace.panels[panelID] else { continue }
            return terminalState.remoteConversationID
        }
        return nil
    }

    private static func request(
        conversationID: RemoteConversationID,
        clientRequestID: String,
        text: String
    ) -> RemoteMessageSendRequest {
        RemoteMessageSendRequest(
            conversationID: conversationID,
            clientRequestID: clientRequestID,
            expectedInputEpoch: RemoteInputEpoch(bindingID: UUID(), counter: 1),
            text: text
        )
    }

    private static func userObservation(
        text: String,
        fingerprint: String
    ) -> ProviderTranscriptObservation {
        ProviderTranscriptObservation(
            timestamp: Date(timeIntervalSince1970: 1_786_000_000),
            fingerprint: fingerprint,
            payload: .transcript(.userMessage(ConversationUserMessagePayload(
                text: text,
                origin: .unknown
            )))
        )
    }

    private static func userPayload(
        from observation: ProviderTranscriptObservation
    ) -> ConversationUserMessagePayload? {
        guard case .transcript(.userMessage(let payload)) = observation.payload else {
            return nil
        }
        return payload
    }
}

@MainActor
private final class RemoteBootstrapFixture {
    let store: AppStore
    let sessionRuntimeStore: SessionRuntimeStore
    let terminalRuntimeRegistry: TerminalRuntimeRegistry
    let server: RemoteAccessGatewayServerSpy
    let gatewayHandler: RemoteGatewayRequestHandler
    let service: RemoteAccessService
    let panelID: UUID
    let sessionID: String
    let conversationID: RemoteConversationID
    let resumeRecord: ManagedAgentResumeRecord
    let confirmedAt: Date
    let runtimeHome: String

    init(
        agent: AgentKind = .codex,
        statusKind: SessionStatusKind = .idle,
        claudePromptStabilizationDelay: Duration = .milliseconds(500),
        sendConfirmationTimeout: Duration = .seconds(10)
    ) throws {
        store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let selection = try #require(store.state.selectedWorkspaceSelection())
        panelID = try #require(selection.workspace.focusedPanelID)
        sessionID = "remote-bootstrap-\(UUID().uuidString)"
        confirmedAt = Date(timeIntervalSince1970: 1_786_000_000)
        runtimeHome = "/tmp/toastty-remote-bootstrap-\(UUID().uuidString)"
        let transcriptURL = URL(filePath: runtimeHome + "-transcript.jsonl")
        try Data().write(to: transcriptURL)
        resumeRecord = ManagedAgentResumeRecord(
            agent: agent,
            nativeSessionID: "native-\(UUID().uuidString)",
            sessionFilePath: transcriptURL.path,
            cwd: "/repo",
            capturedAt: confirmedAt
        )

        sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.startSession(
            sessionID: sessionID,
            agent: agent,
            panelID: panelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: confirmedAt
        )
        sessionRuntimeStore.updateStatus(
            sessionID: sessionID,
            status: SessionStatus(kind: statusKind, summary: String(describing: statusKind)),
            at: confirmedAt
        )
        terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let gatewayServer = RemoteAccessGatewayServerSpy()
        server = gatewayServer
        var capturedHandler: RemoteGatewayRequestHandler?
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/toastty-remote-access-test-home",
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome]
        )
        service = RemoteAccessService(
            store: store,
            annotationStyleStore: AnnotationStyleStore(runtimePaths: runtimePaths),
            sessionRuntimeStore: sessionRuntimeStore,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            runtimePaths: runtimePaths,
            port: 42_997,
            initiallyEnabled: false,
            claudePromptStabilizationDelay: claudePromptStabilizationDelay,
            sendConfirmationTimeout: sendConfirmationTimeout,
            gatewayServerFactory: { handler in
                capturedHandler = handler
                return gatewayServer
            }
        )
        gatewayHandler = try #require(capturedHandler)
        service.setEnabled(true, persist: false)
        server.reportReady(port: 42_997)
        conversationID = try #require(Self.remoteConversationID(panelID: panelID, in: store))
        guard publishResumeRecord(
            capturedAt: confirmedAt.addingTimeInterval(-60)
        ) else {
            throw RemoteBootstrapFixtureError.couldNotPublishResumeRecord
        }
    }

    var summary: RemoteConversationSummary {
        service.facadeSessionList(at: confirmedAt).conversations.first {
            $0.conversationID == conversationID
        }!
    }

    func confirmCurrentLaunchBinding() -> Bool {
        let confirmed = sessionRuntimeStore.confirmNativeSessionBinding(
            managedSessionID: sessionID,
            panelID: panelID,
            record: resumeRecord
        )
        let published = publishResumeRecord()
        return confirmed && published
    }

    var currentResumeRecord: ManagedAgentResumeRecord? {
        for workspace in store.state.workspacesByID.values {
            guard case .terminal(let terminalState) = workspace.panels[panelID] else { continue }
            return terminalState.resumeRecord
        }
        return nil
    }

    func publishResumeRecord(capturedAt: Date? = nil) -> Bool {
        var record = resumeRecord
        if let capturedAt {
            record.capturedAt = capturedAt
        }
        return store.send(.updateTerminalPanelResumeRecord(
            panelID: panelID,
            resumeRecord: record
        ))
    }

    func removeRuntimeFiles() {
        service.setEnabled(false, persist: false)
        try? FileManager.default.removeItem(atPath: runtimeHome)
        try? FileManager.default.removeItem(atPath: resumeRecord.sessionFilePath)
    }

    private static func remoteConversationID(
        panelID: UUID,
        in store: AppStore
    ) -> RemoteConversationID? {
        for workspace in store.state.workspacesByID.values {
            guard case .terminal(let terminalState) = workspace.panels[panelID] else { continue }
            return terminalState.remoteConversationID
        }
        return nil
    }
}

private enum RemoteBootstrapFixtureError: Error {
    case couldNotPublishResumeRecord
}

@MainActor
private final class RemoteAccessGatewayServerSpy: RemoteAccessGatewayServing {
    var onWebSocketCountsChanged: ((RemoteAccessWebSocketCounts) -> Void)?
    var onDeviceRevoked: ((UUID) -> Void)?
    var onListenerReady: ((UInt16) -> Void)?
    var onListenerFailed: (() -> Void)?

    private(set) var startedPorts: [UInt16] = []
    private(set) var stopCallCount = 0
    private(set) var broadcasts: [RemoteGatewayStreamMessage] = []

    var sessionListSnapshots: [RemoteSessionListSnapshot] {
        broadcasts.compactMap { message in
            guard case .sessionList(let snapshot) = message else { return nil }
            return snapshot
        }
    }

    var startCallCount: Int {
        startedPorts.count
    }

    func start(port: UInt16) throws {
        startedPorts.append(port)
    }

    func stop() {
        stopCallCount += 1
    }

    func disconnectWebSockets(for _: UUID) {}
    func disconnectAllWebSockets() {}
    func broadcast(_ message: RemoteGatewayStreamMessage) {
        broadcasts.append(message)
    }

    func removeAllBroadcasts() {
        broadcasts.removeAll()
    }

    func reportReady(port: UInt16) {
        onListenerReady?(port)
    }

    func reportFailure() {
        onListenerFailed?()
    }

    func reportWebSocketCounts(total: Int, native: Int) {
        onWebSocketCountsChanged?(RemoteAccessWebSocketCounts(total: total, native: native))
    }
}

extension RemoteAccessServiceSafetyTests {
    @MainActor
    @Test func claudeQuestionAnswerUsesExactPendingEpochAndWritePolicyWithoutTerminalInput() throws {
        let fixture = try RemoteBootstrapFixture(agent: .claude, statusKind: .working)
        defer { fixture.removeRuntimeFiles(); fixture.sessionRuntimeStore.reset() }
        #expect(fixture.confirmCurrentLaunchBinding())
        let questions = [RemoteInteractionQuestion(id: "q0", header: "Choice", question: "Choose a color",
            options: [.init(id: "q0:o0", label: "Blue"), .init(id: "q0:o1", label: "Green")])]
        let responseID = UUID().uuidString
        let now = Date()
        func hook(_ phase: ClaudeQuestionHookRequest.Phase, name: ClaudeQuestionHookEvent.EventName) -> ClaudeQuestionHookRequest {
            .init(phase: phase, sessionID: fixture.sessionID, panelID: fixture.panelID,
                event: .init(eventName: name, nativeSessionID: fixture.resumeRecord.nativeSessionID,
                    promptID: "prompt", transcriptPath: fixture.resumeRecord.sessionFilePath,
                    providerCallID: name == .preToolUse ? "question-call" : nil, questions: questions, timestamp: now),
                responseID: phase == .begin ? responseID : nil)
        }
        #expect(fixture.sessionRuntimeStore.handleClaudeQuestion(hook(.observe, name: .preToolUse), at: now).status == .observed)
        #expect(fixture.sessionRuntimeStore.handleClaudeQuestion(hook(.begin, name: .permissionRequest), at: now).status == .pending)
        let snapshot = try #require(fixture.service.facadeConversationSnapshot(for: fixture.conversationID, at: now))
        let interaction = try #require(snapshot.pendingInteractions.first)
        #expect(interaction.responseID == responseID)
        #expect(snapshot.summary.presentationStatus == .needsApproval)
        let request = RemoteQuestionAnswerRequest(conversationID: fixture.conversationID, interactionID: interaction.id,
            responseID: responseID, expectedInputEpoch: interaction.inputEpoch, clientRequestID: "mobile",
            answers: [.init(questionID: "q0", selectedOptionIDs: ["q0:o0"])])
        let device = RemoteDeviceRecord(name: "Phone", scopes: [.read, .send], createdAt: now)
        var readOnlyDevice = device
        readOnlyDevice.scopes = [.read]
        #expect(fixture.service.performQuestionAnswer(request, device: readOnlyDevice) == .rejected(reason: .sendScopeDenied))
        fixture.service.setSessionWriteEnabled(false, for: fixture.conversationID)
        #expect(fixture.service.performQuestionAnswer(request, device: device) == .rejected(reason: .sessionWritesDisabled))
        fixture.service.setSessionWriteEnabled(true, for: fixture.conversationID)
        var stale = request
        stale.expectedInputEpoch = .init(bindingID: UUID(), counter: 99)
        #expect(fixture.service.performQuestionAnswer(stale, device: device) == .rejected(reason: .epochMismatch))
        // Exercise the actual native authorization -> service -> broker bridge.
        let originalOrigin = fixture.service.tailnetOrigin
        defer { fixture.service.tailnetOrigin = originalOrigin }
        fixture.service.tailnetOrigin = "https://question-test.ts.net"
        fixture.service.issueNativePairingOffer(at: now)
        let offer = try #require(fixture.service.currentNativePairingOffer)
        let exchange = RemoteGatewayNativePairingExchangeRequest(deviceName: "Question Phone",
            offerID: offer.id, secret: offer.qrPayload.secret)
        guard case .respond(let pairingResponse) = fixture.gatewayHandler.handle(.init(method: "POST",
            path: "/v1/native-pairing/exchange", headers: ["tailscale-user-login": "owner@example.com"],
            body: try ConversationEventCoding.makeEncoder().encode(exchange)), at: now) else {
            Issue.record("Expected native pairing response")
            return
        }
        #expect(pairingResponse.status == 200)
        let pairing = try ConversationEventCoding.makeDecoder().decode(RemoteGatewayNativePairingExchangeResponse.self, from: pairingResponse.body)
        let gatewayRequest = RemoteGatewayHTTPRequest(method: "POST", path: "/api/conversation.question.answer",
            headers: ["authorization": "Bearer \(pairing.credential)", "tailscale-user-login": "owner@example.com"],
            body: try ConversationEventCoding.makeEncoder().encode(request))
        // Typing in the native modal must not use the free-form send draft gate.
        fixture.service.noteLocalInput(panelID: fixture.panelID)
        for expected in [RemoteQuestionAnswerResult.submitted, .duplicate] {
            guard case .respond(let response) = fixture.gatewayHandler.handle(gatewayRequest, at: now) else {
                Issue.record("Expected question answer response")
                return
            }
            #expect(response.status == 200)
            #expect(try ConversationEventCoding.makeDecoder().decode(RemoteQuestionAnswerResult.self, from: response.body) == expected)
        }
        let poll = ClaudeQuestionHookRequest(phase: .poll, sessionID: fixture.sessionID,
            panelID: fixture.panelID, responseID: responseID)
        #expect(fixture.sessionRuntimeStore.handleClaudeQuestion(poll, at: now).answers == request.answers)
        let completed = ClaudeQuestionHookRequest(phase: .observe, sessionID: fixture.sessionID, panelID: fixture.panelID,
            event: .init(eventName: .postToolUse, nativeSessionID: fixture.resumeRecord.nativeSessionID,
                promptID: "prompt", transcriptPath: fixture.resumeRecord.sessionFilePath, providerCallID: "question-call",
                answers: ["Choose a color": "Blue"], timestamp: now.addingTimeInterval(1)))
        #expect(fixture.sessionRuntimeStore.handleClaudeQuestion(completed, at: now.addingTimeInterval(1)).status == .observed)
        let finished = try #require(fixture.service.facadeConversationSnapshot(for: fixture.conversationID, at: now.addingTimeInterval(1)))
        #expect(finished.pendingInteractions.isEmpty)
        let feed = try #require(fixture.sessionRuntimeStore.providerConversationFeed(managedSessionID: fixture.sessionID))
        guard case .transcript(.interactionResolved(let resolution)) = try #require(feed.observations.last).payload else {
            Issue.record("Expected accepted answers in provider feed")
            return
        }
        #expect(resolution.answers == request.answers)
    }
}
