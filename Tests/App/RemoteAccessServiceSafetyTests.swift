import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

struct RemoteAccessServiceSafetyTests {
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

    @Test func desktopSessionStatusMapsExactlyToRemotePresentationStatus() {
        let cases: [(SessionStatusKind, RemoteSessionPresentationStatus)] = [
            (.idle, .idle),
            (.working, .working),
            (.needsApproval, .needsApproval),
            (.ready, .ready),
            (.error, .error),
        ]

        for (desktop, remote) in cases {
            #expect(RemoteAccessService.remotePresentationStatus(for: desktop) == remote)
        }
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
        let service = RemoteAccessService(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            runtimePaths: ToasttyRuntimePaths.resolve(
                homeDirectoryPath: "/tmp/toastty-remote-access-test-home",
                environment: [ToasttyRuntimePaths.environmentKey: runtimeHome]
            ),
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
private final class RemoteAccessGatewayServerSpy: RemoteAccessGatewayServing {
    var onWebSocketCountsChanged: ((RemoteAccessWebSocketCounts) -> Void)?
    var onDeviceRevoked: ((UUID) -> Void)?
    var onListenerReady: ((UInt16) -> Void)?
    var onListenerFailed: (() -> Void)?

    private(set) var startedPorts: [UInt16] = []
    private(set) var stopCallCount = 0

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
    func broadcast(_: RemoteGatewayStreamMessage) {}

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
