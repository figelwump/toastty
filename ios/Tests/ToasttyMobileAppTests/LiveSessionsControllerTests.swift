import ConversationUI
import Foundation
import RemoteProtocol
import SwiftUI
import UIKit
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

@MainActor
final class LiveSessionsControllerTests: XCTestCase {
    func testLiveSnapshotReordersAndUpdatesCurrentPresentation() throws {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: MobileHomeSnapshot(hostName: "toastty.test.ts.net", workspaces: []),
            connectionState: .offline
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home
        )

        subject.consumeSessionsState(SessionsRuntime.State(
            connectionGeneration: 7,
            snapshot: snapshot(titles: ["Zulu", "Alpha"]),
            phase: .live
        ))
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7,
            phase: .live
        ))

        XCTAssertEqual(home.freshness, .live)
        XCTAssertEqual(home.connectionState, .live)
        XCTAssertEqual(home.snapshot.workspaces.map(\.title), ["Alpha workspace", "Zulu workspace"])
        XCTAssertEqual(subject.projectionGeneration, 12)
        XCTAssertEqual(subject.projectionRunID, runID.rawValue.uuidString)

        let alpha = try XCTUnwrap(home.snapshot.workspaces.first?.conversations.first)
        home.open(alpha)
        subject.consumeSessionsState(SessionsRuntime.State(
            connectionGeneration: 7,
            snapshot: snapshot(titles: ["Alpha updated", "Zulu"]),
            phase: .live
        ))
        XCTAssertEqual(home.selectedConversation?.title, "Alpha updated")
    }

    func testFirstConnectWithoutSnapshotPresentsConnectingNotUnreachable() {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: MobileHomeSnapshot(hostName: "toastty.test.ts.net", workspaces: []),
            connectionState: .offline
        )
        var freshnesses: [LiveProjectionFreshness] = []
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home,
            onFreshness: { freshnesses.append($0) }
        )

        subject.consumeCoordinatorState(ConnectionCoordinator.State(phase: .idle))
        subject.consumeCoordinatorState(ConnectionCoordinator.State(phase: .connecting))
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            phase: .awaitingFreshSessionSnapshot
        ))

        XCTAssertEqual(freshnesses, [.connecting, .connecting, .connecting])
        XCTAssertEqual(home.freshness, .connecting)
        XCTAssertEqual(home.connectionState, .reconnecting)
        XCTAssertEqual(home.connectionNoticeMessage, "Connecting to your Mac…")
    }

    func testAwaitingFreshStreamSnapshotRetainsReadableDataAsStale() {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home
        )

        subject.consumeSessionsState(SessionsRuntime.State(
            connectionGeneration: 8,
            snapshot: snapshot(titles: ["Readable"]),
            phase: .awaitingFreshSnapshot
        ))
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 8,
            phase: .awaitingFreshSessionSnapshot
        ))

        XCTAssertEqual(home.freshness, .stale)
        XCTAssertEqual(home.connectionState, .offline)
        XCTAssertEqual(home.snapshot.workspaces.first?.conversations.first?.title, "Readable")
    }

    func testTransportFailureClassificationReachesHomePresentation() {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home
        )

        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            phase: .reconnecting(failureCount: 2, showsBanner: true),
            consecutiveFailureCount: 2,
            latestTransportFailure: .dns
        ))

        XCTAssertEqual(home.latestTransportFailure, .dns)
        XCTAssertTrue(home.connectionNoticeMessage?.contains("couldn't find your Mac") == true)
    }

    func testAuthRevocationTransitionsWhileAuthorizationDenialRetainsPairedCallback() {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )
        var terminals: [LiveConnectionTerminal] = []
        var callbacks: [String] = []
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home,
            onTerminal: {
                terminals.append($0)
                callbacks.append("terminal")
            },
            onFreshness: { _ in callbacks.append("freshness") }
        )

        subject.consumeCoordinatorState(ConnectionCoordinator.State(phase: .authorizationDenied))
        XCTAssertEqual(callbacks, ["freshness", "terminal"])
        callbacks.removeAll()
        subject.consumeCoordinatorState(ConnectionCoordinator.State(phase: .requiresAuthentication))

        XCTAssertEqual(terminals, [.authorizationDenied, .requiresAuthentication])
        XCTAssertEqual(callbacks, ["freshness", "terminal"])
        XCTAssertEqual(home.freshness, .unreachable)
    }

    func testSceneLifecycleRetainsActiveConversationDuringBriefBackground() async throws {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: snapshot(titles: ["Alpha"]).presentation(),
            connectionState: .live
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home
        )
        let conversation = try XCTUnwrap(home.snapshot.workspaces.first?.conversations.first)
        await subject.openConversation(conversation.id)
        let controller = try XCTUnwrap(subject.activeConversationController)

        await subject.background(lifecycleSequence: 1)
        let backgroundSequences = await runtime.backgroundSequences()
        XCTAssertEqual(backgroundSequences, [1])
        let didSuspend = await runtime.didSuspend()
        XCTAssertFalse(didSuspend)
        XCTAssertEqual(home.freshness, .live)
        XCTAssertTrue(subject.activeConversationController === controller)
        var conversationOpenCount = await runtime.conversationOpenCount()
        var conversationCloseCount = await runtime.conversationCloseCount()
        XCTAssertEqual(conversationOpenCount, 1)
        XCTAssertEqual(conversationCloseCount, 0)

        await subject.foreground(lifecycleSequence: 2)
        let resumeSequences = await runtime.resumeSequences()
        XCTAssertEqual(resumeSequences, [2])
        XCTAssertTrue(subject.activeConversationController === controller)
        conversationOpenCount = await runtime.conversationOpenCount()
        conversationCloseCount = await runtime.conversationCloseCount()
        XCTAssertEqual(conversationOpenCount, 1)
        XCTAssertEqual(conversationCloseCount, 0)

        await subject.closeConversation(conversation.id)
        XCTAssertNil(subject.activeConversationController)
        conversationCloseCount = await runtime.conversationCloseCount()
        XCTAssertEqual(conversationCloseCount, 1)
        subject.stopObserving()
    }

    func testShortForegroundProbeKeepsPresentationStable() async throws {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(runtimeMode: .fixture, snapshot: snapshot(titles: ["Alpha"]).presentation(),
                                        connectionState: .live)
        let subject = LiveSessionsController(runtime: runtime, hostName: "toastty.test.ts.net", homeController: home)
        subject.consumeSessionsState(.init(connectionGeneration: 7, snapshot: snapshot(titles: ["Alpha"]), phase: .live))
        subject.consumeCoordinatorState(.init(connectionGeneration: 7, phase: .live))
        let conversation = try XCTUnwrap(home.snapshot.workspaces.first?.conversations.first)
        await subject.openConversation(conversation.id)
        let controller = try XCTUnwrap(subject.activeConversationController)
        controller.stop()
        await subject.background(lifecycleSequence: 1)
        await subject.foreground(lifecycleSequence: 2)
        // Conversation authority can arrive before the connection phase.
        controller.consume(composerState(for: conversation, failure: .coordinatorNotLive))
        var composer = try XCTUnwrap(subject.composerPresentation(for: conversation))
        XCTAssertTrue(composer.waitsForConnection)
        XCTAssertFalse(composer.canSubmit(draft: "keep my draft"))
        XCTAssertEqual(composer.placeholder, "Message Codex…")
        subject.consumeCoordinatorState(.init(connectionGeneration: 7, phase: .checkingConnection))
        XCTAssertEqual(home.freshness, .live)
        XCTAssertEqual(home.chatConnection, .live)
        // A successful probe can reach home before the restored authority.
        subject.consumeCoordinatorState(.init(connectionGeneration: 7, phase: .live))
        composer = try XCTUnwrap(subject.composerPresentation(for: conversation))
        XCTAssertTrue(composer.waitsForConnection)
        XCTAssertFalse(composer.canSubmit(draft: "keep my draft"))
        let epoch = RemoteInputEpoch(bindingID: UUID(), counter: 1)
        controller.consume(stateForComposer(
            conversationID: conversation.id,
            stamp: ConversationComposerStamp(
                connectionGeneration: 7, streamSnapshotOrdinal: 2,
                projectionRunID: runID, projectionGeneration: 12,
                latestSequence: 4, inputEpoch: epoch
            ),
            epoch: epoch
        ))
        composer = try XCTUnwrap(subject.composerPresentation(for: conversation))
        XCTAssertFalse(composer.waitsForConnection)
        XCTAssertTrue(composer.canSubmit(draft: "keep my draft"))
        XCTAssertEqual(home.freshness, .live)
        XCTAssertEqual(home.chatConnection, .live)
        XCTAssertEqual(home.snapshot.workspaces.first?.conversations.first?.title, "Alpha")
        subject.stopObserving()
    }

    /// The recorded bug: on a return to the app the composer locked, a
    /// draft's tall field collapsed and a status line grew under it, and all
    /// of it moved back once the chat was live. The field now stays where it
    /// was, open, with its draft, through the quiet start, "reconnecting…",
    /// offline and live again.
    func testRenderedComposerKeepsItsPlaceAndDraftThroughAReconnect() async throws {
        let home = HomeScreenController(runtimeMode: .fixture, snapshot: snapshot(titles: ["Alpha"]).presentation(),
                                        connectionState: .live)
        let subject = LiveSessionsController(
            runtime: LiveRuntimeSpy(), hostName: "toastty.test.ts.net", homeController: home,
            chatConnectionTimeline: ToasttyChatConnectionTimeline(
                reconnectingDelay: .milliseconds(300), offlineDelay: .milliseconds(900)
            )
        )
        subject.consumeSessionsState(.init(connectionGeneration: 7, snapshot: snapshot(titles: ["Alpha"]), phase: .live))
        subject.consumeCoordinatorState(.init(connectionGeneration: 7, phase: .live))
        let conversation = try XCTUnwrap(home.snapshot.workspaces.first?.conversations.first)
        await subject.openConversation(conversation.id)
        let controller = try XCTUnwrap(subject.activeConversationController)
        controller.stop()
        let epoch = RemoteInputEpoch(bindingID: UUID(), counter: 1)
        controller.consume(stateForComposer(
            conversationID: conversation.id,
            stamp: ConversationComposerStamp(
                connectionGeneration: 7, streamSnapshotOrdinal: 2,
                projectionRunID: runID, projectionGeneration: 12,
                latestSequence: 4, inputEpoch: epoch
            ),
            epoch: epoch
        ))
        XCTAssertTrue(try XCTUnwrap(subject.composerPresentation(for: conversation)).canSubmit(draft: "saved draft"))
        let drafts = ToasttyComposerDraftStore()
        drafts.update { $0.updateDraft("saved draft", for: conversation.id) }
        let host = UIHostingController(rootView: ForegroundProbeComposerHarness(
            sessions: subject, home: home, conversation: conversation, drafts: drafts
        ))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            subject.stopObserving()
        }
        host.view.layoutIfNeeded()
        for _ in 0..<100 where composerTextView(in: host.view) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        func field() throws -> ToasttyComposerUIKitTextView { try XCTUnwrap(composerTextView(in: host.view)) }
        func frame() throws -> CGRect {
            host.view.layoutIfNeeded()
            let view = try field()
            return view.convert(view.bounds, to: window)
        }
        let liveFrame = try frame()
        XCTAssertEqual(try field().text, "saved draft")
        attachComposerScreenshot(window, named: "composer-live-with-draft")

        await subject.background(lifecycleSequence: 1)
        // The stream was suspended while the app was away.
        subject.consumeCoordinatorState(.init(connectionGeneration: 7, phase: .suspended))
        await subject.foreground(lifecycleSequence: 2)
        subject.consumeCoordinatorState(.init(connectionGeneration: 8, phase: .connecting))
        controller.consume(composerState(for: conversation, failure: .coordinatorNotLive))
        XCTAssertEqual(home.chatConnection, .live, "A return starts quiet")

        func assertUnmoved(_ state: String) throws {
            let view = try field()
            XCTAssertEqual(try frame(), liveFrame, "The field moved while \(state)")
            XCTAssertEqual(view.text, "saved draft", state)
            XCTAssertEqual(view.placeholder, "Message Codex…", state)
            XCTAssertTrue(view.isEditable, "The field must take text while \(state)")
        }
        // Give SwiftUI a pass to apply the locked gate.
        try await Task.sleep(for: .milliseconds(50))
        try assertUnmoved("the chat starts reconnecting")
        XCTAssertFalse(try XCTUnwrap(subject.composerPresentation(for: conversation)).canSubmit(draft: "saved draft"))
        attachComposerScreenshot(window, named: "composer-quiet-start")

        for _ in 0..<100 where home.chatConnection != .reconnecting {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(home.chatConnection, .reconnecting)
        try assertUnmoved("it shows reconnecting")
        attachComposerScreenshot(window, named: "composer-reconnecting")

        for _ in 0..<150 where home.chatConnection != .offline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(home.chatConnection, .offline)
        try await Task.sleep(for: .milliseconds(50))
        try assertUnmoved("it is offline")
        attachComposerScreenshot(window, named: "composer-offline")

        subject.consumeSessionsState(.init(connectionGeneration: 8, snapshot: snapshot(titles: ["Alpha"]), phase: .live))
        subject.consumeCoordinatorState(.init(connectionGeneration: 8, phase: .live))
        XCTAssertEqual(home.chatConnection, .live)
        let newEpoch = RemoteInputEpoch(bindingID: UUID(), counter: 2)
        controller.consume(stateForComposer(
            conversationID: conversation.id,
            stamp: ConversationComposerStamp(
                connectionGeneration: 8, streamSnapshotOrdinal: 3,
                projectionRunID: runID, projectionGeneration: 13,
                latestSequence: 4, inputEpoch: newEpoch
            ),
            epoch: newEpoch
        ))
        try await Task.sleep(for: .milliseconds(50))
        try assertUnmoved("it is live again")
        XCTAssertTrue(try XCTUnwrap(subject.composerPresentation(for: conversation)).canSubmit(draft: "saved draft"))
        attachComposerScreenshot(window, named: "composer-live-again")
    }

    func testSlowForegroundProbeExposesConnectionState() async throws {
        let home = HomeScreenController(runtimeMode: .fixture, snapshot: snapshot(titles: ["Alpha"]).presentation(),
                                        connectionState: .live)
        let subject = LiveSessionsController(runtime: LiveRuntimeSpy(), hostName: "toastty.test.ts.net",
                                             homeController: home, connectionPresentationDelay: .milliseconds(1))
        subject.consumeSessionsState(.init(connectionGeneration: 7, snapshot: snapshot(titles: ["Alpha"]), phase: .live))
        subject.consumeCoordinatorState(.init(connectionGeneration: 7, phase: .live))
        let conversation = try XCTUnwrap(home.snapshot.workspaces.first?.conversations.first)
        await subject.openConversation(conversation.id)
        let controller = try XCTUnwrap(subject.activeConversationController)
        controller.stop()
        await subject.background(lifecycleSequence: 1)
        await subject.foreground(lifecycleSequence: 2)
        subject.consumeCoordinatorState(.init(connectionGeneration: 7, phase: .checkingConnection))
        controller.consume(composerState(for: conversation, failure: .coordinatorNotLive))
        for _ in 0..<100 where home.freshness == .live {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(home.freshness, .reconnecting)
        let composer = try XCTUnwrap(subject.composerPresentation(for: conversation))
        XCTAssertTrue(composer.waitsForConnection)
        XCTAssertEqual(composer.placeholder, "Message Codex…")
        XCTAssertFalse(composer.canSubmit(draft: "keep my draft"))
        // The chat's own signal waits longer than Home's grace.
        XCTAssertEqual(home.chatConnection, .live)
        subject.stopObserving()
    }

    func testForegroundFailureEndsHomeGraceWhileSendStillWaits() async throws {
        let home = HomeScreenController(runtimeMode: .fixture, snapshot: snapshot(titles: ["Alpha"]).presentation(),
                                        connectionState: .live)
        let subject = LiveSessionsController(runtime: LiveRuntimeSpy(), hostName: "toastty.test.ts.net",
                                             homeController: home, connectionPresentationDelay: .seconds(30))
        subject.consumeSessionsState(.init(connectionGeneration: 7, snapshot: snapshot(titles: ["Alpha"]), phase: .live))
        subject.consumeCoordinatorState(.init(connectionGeneration: 7, phase: .live))
        let conversation = try XCTUnwrap(home.snapshot.workspaces.first?.conversations.first)
        await subject.openConversation(conversation.id)
        let controller = try XCTUnwrap(subject.activeConversationController)
        controller.stop()
        await subject.background(lifecycleSequence: 1)
        await subject.foreground(lifecycleSequence: 2)
        controller.consume(composerState(for: conversation, failure: .coordinatorNotLive))
        XCTAssertTrue(try XCTUnwrap(subject.composerPresentation(for: conversation)).waitsForConnection)

        subject.consumeCoordinatorState(.init(
            connectionGeneration: 9, phase: .connecting, latestTransportFailure: .connectionLost
        ))

        XCTAssertNotEqual(home.freshness, .live)
        let composer = try XCTUnwrap(subject.composerPresentation(for: conversation))
        XCTAssertTrue(composer.waitsForConnection)
        XCTAssertEqual(composer.placeholder, "Message Codex…")
        XCTAssertFalse(composer.canSubmit(draft: "keep my draft"))
        let outcome = await controller.send("keep my draft")
        XCTAssertEqual(outcome, .notEnqueued(.coordinatorNotLive))
        subject.stopObserving()
    }

    /// The session list can be live while the open chat still catches up,
    /// and Send waits for the chat: the header follows the chat.
    func testOpenChatCatchingUpShowsReconnectingAfterTheQuietStart() async throws {
        let home = HomeScreenController(runtimeMode: .fixture, snapshot: snapshot(titles: ["Alpha"]).presentation(),
                                        connectionState: .live)
        let subject = LiveSessionsController(
            runtime: LiveRuntimeSpy(), hostName: "toastty.test.ts.net", homeController: home,
            chatConnectionTimeline: ToasttyChatConnectionTimeline(
                reconnectingDelay: .milliseconds(100), offlineDelay: .seconds(30)
            )
        )
        defer { subject.stopObserving() }
        subject.consumeSessionsState(.init(connectionGeneration: 7, snapshot: snapshot(titles: ["Alpha"]), phase: .live))
        subject.consumeCoordinatorState(.init(connectionGeneration: 7, phase: .live))
        let conversation = try XCTUnwrap(home.snapshot.workspaces.first?.conversations.first)
        await subject.openConversation(conversation.id)
        let controller = try XCTUnwrap(subject.activeConversationController)
        controller.stop()
        let remoteID = RemoteConversationID(rawValue: conversation.id)
        let message = CompatibleConversationEvent.known(ConversationEvent(
            conversationID: remoteID, sequence: 1, eventID: "event-1",
            timestamp: Date(timeIntervalSince1970: 1), provider: .codex,
            payload: .assistantMessage(ConversationAssistantMessagePayload(text: "message 1", phase: .final))
        ))
        controller.consume(ConversationRuntime.State(
            conversationID: remoteID, connectionGeneration: 7, events: [message], phase: .catchingUp,
            sendReconciliation: SendReconciliation()
        ))
        XCTAssertEqual(controller.phase, .resynchronizing(reason: nil))
        XCTAssertEqual(home.chatConnection, .live)
        for _ in 0..<100 where home.chatConnection != .reconnecting {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(home.chatConnection, .reconnecting)

        controller.consume(ConversationRuntime.State(
            conversationID: remoteID, connectionGeneration: 7, events: [message], phase: .live,
            sendReconciliation: SendReconciliation()
        ))
        XCTAssertEqual(home.chatConnection, .live)
    }

    func testChatConnectionCountsFromTheReturnAndRetryShowsReconnectingAtOnce() async throws {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(runtimeMode: .fixture, snapshot: snapshot(titles: ["Alpha"]).presentation(),
                                        connectionState: .live)
        let subject = LiveSessionsController(
            runtime: runtime, hostName: "toastty.test.ts.net", homeController: home,
            chatConnectionTimeline: ToasttyChatConnectionTimeline(
                reconnectingDelay: .milliseconds(100), offlineDelay: .milliseconds(400)
            )
        )
        defer { subject.stopObserving() }
        subject.consumeSessionsState(.init(connectionGeneration: 7, snapshot: snapshot(titles: ["Alpha"]), phase: .live))
        subject.consumeCoordinatorState(.init(connectionGeneration: 7, phase: .live))
        XCTAssertEqual(home.chatConnection, .live)

        await subject.background(lifecycleSequence: 1)
        subject.consumeCoordinatorState(.init(connectionGeneration: 7, phase: .suspended))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(home.chatConnection, .live, "Time in the background must not count")

        await subject.foreground(lifecycleSequence: 2)
        subject.consumeCoordinatorState(.init(connectionGeneration: 8, phase: .connecting))
        XCTAssertEqual(home.chatConnection, .live)
        for _ in 0..<100 where home.chatConnection != .reconnecting {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(home.chatConnection, .reconnecting)
        for _ in 0..<100 where home.chatConnection != .offline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(home.chatConnection, .offline)

        await subject.refresh()
        XCTAssertEqual(home.chatConnection, .reconnecting, "Retry says it reconnects at once")
        let restartCount = await runtime.restartCount()
        XCTAssertEqual(restartCount, 1)

        subject.consumeSessionsState(.init(connectionGeneration: 9, snapshot: snapshot(titles: ["Alpha"]), phase: .live))
        subject.consumeCoordinatorState(.init(connectionGeneration: 9, phase: .live))
        XCTAssertEqual(home.chatConnection, .live)
        // No timer left over brings back a stale signal.
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(home.chatConnection, .live)
    }

    func testSlowRefreshStopsSuppressingConnectionStateAfterGracePeriod() async throws {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home,
            connectionPresentationDelay: .milliseconds(1)
        )
        subject.consumeSessionsState(SessionsRuntime.State(
            connectionGeneration: 7,
            snapshot: snapshot(titles: ["Before refresh"]),
            phase: .live
        ))
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7,
            phase: .live
        ))

        await subject.refresh()
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 9,
            phase: .connecting
        ))
        XCTAssertEqual(home.freshness, .live)

        for _ in 0..<100 where home.freshness == .live {
            try await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertNotEqual(home.freshness, .live)
        XCTAssertNotNil(home.connectionNoticeMessage)
        subject.stopObserving()
    }

    func testRefreshRestartsLiveRuntime() async {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home
        )

        await subject.refresh()

        let restartCount = await runtime.restartCount()
        XCTAssertEqual(restartCount, 1)
        subject.stopObserving()
    }

    func testRefreshKeepsLivePresentationUntilRestartSucceeds() async {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home,
            connectionPresentationDelay: .seconds(30)
        )
        subject.consumeSessionsState(SessionsRuntime.State(
            connectionGeneration: 7,
            snapshot: snapshot(titles: ["Before refresh"]),
            phase: .live
        ))
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7,
            phase: .live
        ))

        await subject.refresh()
        subject.consumeSessionsState(SessionsRuntime.State(
            connectionGeneration: 9,
            snapshot: snapshot(titles: ["Before refresh"]),
            phase: .seedingREST
        ))
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 9,
            phase: .connecting
        ))

        XCTAssertEqual(home.freshness, .live)
        XCTAssertNil(home.connectionNoticeMessage)

        subject.consumeSessionsState(SessionsRuntime.State(
            connectionGeneration: 9,
            snapshot: snapshot(titles: ["After refresh"]),
            phase: .live
        ))
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 9,
            phase: .live
        ))

        XCTAssertEqual(home.freshness, .live)
        XCTAssertEqual(
            home.snapshot.workspaces.first?.conversations.first?.title,
            "After refresh"
        )
        subject.stopObserving()
    }

    func testRefreshShowsReconnectGuidanceWhenRestartFails() async {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home,
            connectionPresentationDelay: .seconds(30)
        )
        subject.consumeSessionsState(SessionsRuntime.State(
            connectionGeneration: 7,
            snapshot: snapshot(titles: ["Before refresh"]),
            phase: .live
        ))
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7,
            phase: .live
        ))

        await subject.refresh()
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 9,
            phase: .reconnecting(failureCount: 1, showsBanner: false),
            consecutiveFailureCount: 1
        ))

        XCTAssertEqual(home.freshness, .reconnecting)
        XCTAssertTrue(home.connectionNoticeMessage?.contains("Remote Access enabled") == true)
        subject.stopObserving()
    }

    func testDeviceScopeRefreshForwardsToDomainRuntime() async {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home
        )

        await subject.updateDeviceScopes([.read, .approve])

        let scopes = await runtime.latestDeviceScopes()
        XCTAssertEqual(scopes, [.read, .approve])
    }

    func testConversationFlagNeedsTheHostCapabilityAndThisDevicesSendAccess() async {
        let home = HomeScreenController(
            runtimeMode: .live(gatewayURL: URL(string: "https://toastty.test.ts.net")!),
            snapshot: MobileHomeSnapshot(hostName: "toastty.test.ts.net", workspaces: []),
            connectionState: .offline
        )
        let subject = LiveSessionsController(
            runtime: LiveRuntimeSpy(),
            hostName: "toastty.test.ts.net",
            homeController: home
        )
        subject.consumeSessionsState(SessionsRuntime.State(
            connectionGeneration: 7, snapshot: snapshot(titles: ["Alpha"]), phase: .live
        ))
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: [.conversationFlag]
        ))
        XCTAssertFalse(home.canFlagConversations)
        await subject.updateDeviceScopes([.read])
        XCTAssertFalse(home.canFlagConversations)
        await subject.updateDeviceScopes([.read, .send])
        XCTAssertTrue(home.canFlagConversations)
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: []
        ))
        XCTAssertFalse(home.canFlagConversations)
    }

    /// Home asks the user to update the Mac only while a live Mac's
    /// capabilities lack `tasks`. Empty capabilities, before a hello or
    /// between connections, keep what Home knew.
    func testHomeAsksToUpdateOnlyALiveMacWithoutTasks() {
        let home = HomeScreenController(
            runtimeMode: .live(gatewayURL: URL(string: "https://toastty.test.ts.net")!),
            snapshot: MobileHomeSnapshot(hostName: "toastty.test.ts.net", workspaces: []),
            connectionState: .offline
        )
        let subject = LiveSessionsController(
            runtime: LiveRuntimeSpy(),
            hostName: "toastty.test.ts.net",
            homeController: home
        )
        subject.consumeSessionsState(SessionsRuntime.State(
            connectionGeneration: 7, snapshot: snapshot(titles: ["Alpha"]), phase: .live
        ))
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: []
        ))
        XCTAssertTrue(home.hostSupportsTasks)
        XCTAssertFalse(home.asksToUpdateMacForTasks)
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: [.workspacePanels]
        ))
        XCTAssertTrue(home.asksToUpdateMacForTasks)
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .reconnecting(failureCount: 1, showsBanner: false), capabilities: []
        ))
        XCTAssertFalse(home.hostSupportsTasks)
        XCTAssertFalse(home.asksToUpdateMacForTasks)
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: [.workspacePanels, .tasks]
        ))
        XCTAssertTrue(home.hostSupportsTasks)
        XCTAssertFalse(home.asksToUpdateMacForTasks)
    }

    func testSessionStartNeedsTheHostCapabilityAndThisDevicesSendAccess() async {
        let home = HomeScreenController(
            runtimeMode: .live(gatewayURL: URL(string: "https://toastty.test.ts.net")!),
            snapshot: MobileHomeSnapshot(hostName: "toastty.test.ts.net", workspaces: []),
            connectionState: .offline
        )
        let subject = LiveSessionsController(
            runtime: LiveRuntimeSpy(),
            hostName: "toastty.test.ts.net",
            homeController: home
        )
        subject.consumeSessionsState(SessionsRuntime.State(
            connectionGeneration: 7, snapshot: snapshot(titles: ["Alpha"]), phase: .live
        ))
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: [.sessionStart]
        ))
        XCTAssertFalse(home.canStartSessions)
        await subject.updateDeviceScopes([.read])
        XCTAssertFalse(home.canStartSessions)
        await subject.updateDeviceScopes([.read, .send])
        XCTAssertTrue(home.canStartSessions)
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .reconnecting(failureCount: 1, showsBanner: false), capabilities: [.sessionStart]
        ))
        XCTAssertFalse(home.canStartSessions)
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: []
        ))
        XCTAssertFalse(home.canStartSessions)
    }

    /// Home's ＋ opens New Task only for a live Mac that advertises task
    /// creation to a device allowed to send; otherwise it stays New Session.
    func testTaskCreateNeedsTheHostCapabilityAndThisDevicesSendAccess() async {
        let home = HomeScreenController(
            runtimeMode: .live(gatewayURL: URL(string: "https://toastty.test.ts.net")!),
            snapshot: MobileHomeSnapshot(hostName: "toastty.test.ts.net", workspaces: []),
            connectionState: .offline
        )
        let subject = LiveSessionsController(
            runtime: LiveRuntimeSpy(),
            hostName: "toastty.test.ts.net",
            homeController: home
        )
        subject.consumeSessionsState(SessionsRuntime.State(
            connectionGeneration: 7, snapshot: snapshot(titles: ["Alpha"]), phase: .live
        ))
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: [.sessionStart]
        ))
        await subject.updateDeviceScopes([.read, .send])
        XCTAssertTrue(home.canStartSessions)
        XCTAssertFalse(home.canCreateTasks, "An older Mac keeps New Session")
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: [.sessionStart, .taskCreate]
        ))
        XCTAssertTrue(home.canCreateTasks)
        await subject.updateDeviceScopes([.read])
        XCTAssertFalse(home.canCreateTasks)
        await subject.updateDeviceScopes([.read, .send])
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .reconnecting(failureCount: 1, showsBanner: false),
            capabilities: [.sessionStart, .taskCreate]
        ))
        XCTAssertFalse(home.canCreateTasks)
    }

    /// New Task sends to the coordinator only for a live Mac that
    /// advertises it to a device allowed to send. The capability can arrive
    /// after the device's scopes, with the next connection state.
    func testCoordinatorSendNeedsTheHostCapabilityAndThisDevicesSendAccess() async {
        let home = HomeScreenController(
            runtimeMode: .live(gatewayURL: URL(string: "https://toastty.test.ts.net")!),
            snapshot: MobileHomeSnapshot(hostName: "toastty.test.ts.net", workspaces: []),
            connectionState: .offline
        )
        let subject = LiveSessionsController(
            runtime: LiveRuntimeSpy(),
            hostName: "toastty.test.ts.net",
            homeController: home
        )
        subject.consumeSessionsState(SessionsRuntime.State(
            connectionGeneration: 7, snapshot: snapshot(titles: ["Alpha"]), phase: .live
        ))
        await subject.updateDeviceScopes([.read, .send])
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: [.taskCreate]
        ))
        XCTAssertTrue(home.canCreateTasks)
        XCTAssertFalse(home.supportsCoordinatorSend, "An older Mac gets the New Task sheet as before")
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: [.taskCreate, .coordinatorSend]
        ))
        XCTAssertTrue(home.supportsCoordinatorSend)
        await subject.updateDeviceScopes([.read])
        XCTAssertFalse(home.supportsCoordinatorSend)
        await subject.updateDeviceScopes([.read, .send])
        XCTAssertTrue(home.supportsCoordinatorSend)
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .reconnecting(failureCount: 1, showsBanner: false),
            capabilities: [.taskCreate, .coordinatorSend]
        ))
        XCTAssertFalse(home.supportsCoordinatorSend)
    }

    /// The Coordinator tab's menu lists the coordinator's files only for a
    /// Mac that serves file previews. The capability can arrive after the
    /// device's scopes, and a reconnect without capabilities keeps what the
    /// phone knew.
    func testCoordinatorFilesNeedTheHostsFilePreviews() async {
        let home = HomeScreenController(
            runtimeMode: .live(gatewayURL: URL(string: "https://toastty.test.ts.net")!),
            snapshot: MobileHomeSnapshot(hostName: "toastty.test.ts.net", workspaces: []),
            connectionState: .offline
        )
        let subject = LiveSessionsController(
            runtime: LiveRuntimeSpy(),
            hostName: "toastty.test.ts.net",
            homeController: home
        )
        XCTAssertFalse(home.hostSupportsLocalFilePreview)
        subject.consumeSessionsState(SessionsRuntime.State(
            connectionGeneration: 7, snapshot: snapshot(titles: ["Alpha"]), phase: .live
        ))
        await subject.updateDeviceScopes([.read])
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: [.workspacePanelPreview]
        ))
        XCTAssertFalse(home.hostSupportsLocalFilePreview, "An older Mac lists only the panels")
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: [.workspacePanelPreview, .localFilePreview]
        ))
        XCTAssertTrue(home.hostSupportsLocalFilePreview)
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .reconnecting(failureCount: 1, showsBanner: false), capabilities: []
        ))
        XCTAssertTrue(home.hostSupportsLocalFilePreview)
        await subject.updateDeviceScopes([])
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: [.localFilePreview]
        ))
        XCTAssertFalse(home.hostSupportsLocalFilePreview, "A device without read access cannot preview")
    }

    /// The coordinator chat's New line needs the Mac's capability and its
    /// read point. Each can change while the chat is open: the capability
    /// comes with a connection state or the device's scopes, the read point
    /// with a session list.
    func testTheCoordinatorChatTakesTheMacsReadPointAndCapabilityFromEveryPath() async throws {
        let home = HomeScreenController(
            runtimeMode: .live(gatewayURL: URL(string: "https://toastty.test.ts.net")!),
            snapshot: MobileHomeSnapshot(hostName: "toastty.test.ts.net", workspaces: []),
            connectionState: .offline
        )
        let subject = LiveSessionsController(
            runtime: LiveRuntimeSpy(),
            hostName: "toastty.test.ts.net",
            homeController: home
        )
        await subject.updateDeviceScopes([.read])
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: [.tasks]
        ))
        let readPoint = RemoteCoordinatorChatReadPoint(eventID: "claude:read", timestamp: Date(timeIntervalSince1970: 90))
        func coordinatorSnapshot(readPoint: RemoteCoordinatorChatReadPoint?) -> CompatibleSessionListSnapshot {
            var list = snapshot(titles: ["Alpha"])
            let alpha = list.conversations[0]
            list.workspaces = [RemoteWorkspaceSummary(
                id: try! XCTUnwrap(alpha.placement.workspaceID), title: "Coordinator", panels: [],
                isCoordinator: true, coordinatorConversationID: alpha.conversationID, coordinatorChatRead: readPoint
            )]
            list.tasks = RemoteTaskBoard(doneCount: 0)
            return list
        }
        subject.consumeSessionsState(SessionsRuntime.State(
            connectionGeneration: 7, snapshot: coordinatorSnapshot(readPoint: nil), phase: .live
        ))
        let coordinatorID = try XCTUnwrap(home.snapshot.coordinatorConversation?.id)
        await subject.openConversation(coordinatorID)
        let controller = try XCTUnwrap(subject.activeConversationController)
        XCTAssertTrue(controller.isCoordinatorChat)
        XCTAssertFalse(controller.readsCoordinatorChat, "An older Mac shares no read point")

        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: [.tasks, .coordinatorChatRead]
        ))
        XCTAssertTrue(controller.readsCoordinatorChat)
        XCTAssertNil(controller.chatReading.macReadPoint)
        subject.consumeSessionsState(SessionsRuntime.State(
            connectionGeneration: 7, snapshot: coordinatorSnapshot(readPoint: readPoint), phase: .live
        ))
        XCTAssertEqual(controller.chatReading.macReadPoint, readPoint)

        // The capability also needs this device's read access, so a change
        // of the device's scopes reaches the open chat too.
        await subject.updateDeviceScopes([])
        XCTAssertFalse(controller.readsCoordinatorChat)
        await subject.updateDeviceScopes([.read])
        XCTAssertTrue(controller.readsCoordinatorChat)
        XCTAssertEqual(controller.chatReading.macReadPoint, readPoint)
        subject.stopObserving()
    }

    /// The coordinator's chat folds the wake turns that the Mac shares as
    /// quiet. The phone reads their keys when a snapshot names a revision
    /// it does not have, also after a failed read, and gives the open chat
    /// the keys. A Mac without the capability gets no read, and no turn
    /// folds.
    func testTheCoordinatorChatReadsTheQuietTurnsWhenTheirRevisionChanges() async throws {
        let runtime = LiveRuntimeSpy()
        let first = RemoteCoordinatorQuietDigests(revision: "revision-1", keys: ["key-1"])
        let second = RemoteCoordinatorQuietDigests(revision: "revision-2", keys: ["key-1", "key-2"])
        await runtime.scriptQuietDigests([.success(first), .failure(.network(reason: .timedOut)), .success(second)])
        let home = HomeScreenController(
            runtimeMode: .live(gatewayURL: URL(string: "https://toastty.test.ts.net")!),
            snapshot: MobileHomeSnapshot(hostName: "toastty.test.ts.net", workspaces: []),
            connectionState: .offline
        )
        let subject = LiveSessionsController(runtime: runtime, hostName: "toastty.test.ts.net", homeController: home)
        await subject.updateDeviceScopes([.read])
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: [.tasks]
        ))
        func announce(_ revision: String?) {
            var list = snapshot(titles: ["Alpha"])
            let alpha = list.conversations[0]
            list.workspaces = [RemoteWorkspaceSummary(
                id: try! XCTUnwrap(alpha.placement.workspaceID), title: "Coordinator", panels: [],
                isCoordinator: true, coordinatorConversationID: alpha.conversationID,
                coordinatorQuietDigestsRevision: revision
            )]
            list.tasks = RemoteTaskBoard(doneCount: 0)
            subject.consumeSessionsState(SessionsRuntime.State(connectionGeneration: 7, snapshot: list, phase: .live))
        }
        func waitForKeys(_ keys: Set<String>?, of controller: LiveConversationController) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while controller.quietDigestKeys != keys, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(controller.quietDigestKeys, keys)
        }
        announce(first.revision)
        let coordinatorID = try XCTUnwrap(home.snapshot.coordinatorConversation?.id)
        await subject.openConversation(coordinatorID)
        let controller = try XCTUnwrap(subject.activeConversationController)

        // A Mac without the capability: no read, and nothing folds.
        try await Task.sleep(for: .milliseconds(100))
        let readsByAnOlderMac = await runtime.quietDigestReadCount()
        XCTAssertEqual(readsByAnOlderMac, 0)
        XCTAssertNil(controller.quietDigestKeys)

        // The capability comes with a connection state: one read.
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: [.tasks, .coordinatorQuietDigests]
        ))
        try await waitForKeys(Set(first.keys), of: controller)
        // The same revision again reads nothing.
        announce(first.revision)
        try await Task.sleep(for: .milliseconds(100))
        let readsForTheFirstRevision = await runtime.quietDigestReadCount()
        XCTAssertEqual(readsForTheFirstRevision, 1)

        // A mark comes: a new revision. The read fails, and the chat keeps
        // the keys it has. The next snapshot tries again.
        announce(second.revision)
        try await Task.sleep(for: .milliseconds(100))
        let readsAfterTheFailure = await runtime.quietDigestReadCount()
        XCTAssertEqual(readsAfterTheFailure, 2)
        XCTAssertEqual(controller.quietDigestKeys, Set(first.keys))
        announce(second.revision)
        try await waitForKeys(Set(second.keys), of: controller)

        // The Mac stops sharing them: nothing folds.
        announce(nil)
        XCTAssertNil(controller.quietDigestKeys)
        subject.stopObserving()
    }

    /// Every chat draws chips for the Mac's Done and archived tasks, which
    /// the phone reads apart when the task board names a revision it does
    /// not have, also after a failed read. An older Mac names none: the
    /// phone reads nothing, and a link to a finished task stays text. The
    /// finished tasks never reach the board, so no list or count shows
    /// them, and an unpaired phone keeps none.
    func testTheFinishedTasksAreReadWhenTheBoardNamesANewRevision() async throws {
        let runtime = LiveRuntimeSpy()
        let doneID = UUID(), archivedID = UUID()
        let done = RemoteFinishedTask(
            id: doneID, title: "Signup feedback", group: .done, stageTitle: "Done", stageReason: "merged",
            statusLine: "Done", projectTitle: "toastty",
            pullRequest: RemoteTaskPullRequest(number: 301, url: URL(string: "https://example.com/pull/301")!, state: .merged)
        )
        let archived = RemoteFinishedTask(
            id: archivedID, title: "Export spike", group: .archived, stageTitle: "Archived",
            stageReason: "closed without finishing", statusLine: "Archived"
        )
        let first = RemoteFinishedTasks(revision: "finished-1", tasks: [done])
        let second = RemoteFinishedTasks(revision: "finished-2", tasks: [archived, done])
        await runtime.scriptFinishedTasks([
            .success(first), .failure(.network(reason: .timedOut)), .success(second), .success(second),
        ])
        let home = HomeScreenController(
            runtimeMode: .live(gatewayURL: URL(string: "https://toastty.test.ts.net")!),
            snapshot: MobileHomeSnapshot(hostName: "toastty.test.ts.net", workspaces: []),
            connectionState: .offline
        )
        let subject = LiveSessionsController(runtime: runtime, hostName: "toastty.test.ts.net", homeController: home)
        await subject.updateDeviceScopes([.read])
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: [.tasks]
        ))
        func announce(_ revision: String?) {
            var list = snapshot(titles: ["Alpha"])
            list.tasks = RemoteTaskBoard(doneCount: 2, finishedTasksRevision: revision)
            subject.consumeSessionsState(SessionsRuntime.State(connectionGeneration: 7, snapshot: list, phase: .live))
        }
        func waitForRevision(_ revision: String?) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while home.finishedTasks.revision != revision, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(home.finishedTasks.revision, revision)
        }
        func chips() -> ToasttyTaskLinkChips {
            ToasttyTaskLinkChips(board: home.snapshot.taskBoard, finished: home.finishedTasks)
        }

        // An older Mac: no read, and the link stays text.
        announce(nil)
        try await Task.sleep(for: .milliseconds(100))
        let readsByAnOlderMac = await runtime.finishedTaskReadCount()
        XCTAssertEqual(readsByAnOlderMac, 0)
        XCTAssertNil(chips().taskID(for: CoordinatorTaskLink.url(taskID: doneID)))

        // The board names a revision: one read, and the chip shows the
        // task's title and pull request. The board does not list it.
        announce(first.revision)
        try await waitForRevision(first.revision)
        XCTAssertEqual(chips().chips[doneID]?.title, ConversationLinkChip.taskTitle("Signup feedback"))
        XCTAssertEqual(chips().chips[doneID]?.detail, "#301")
        XCTAssertEqual(chips().taskID(for: CoordinatorTaskLink.url(taskID: doneID)), doneID)
        XCTAssertNil(chips().taskID(for: CoordinatorTaskLink.url(taskID: archivedID)))
        XCTAssertEqual(home.snapshot.taskBoard?.tasks, [])
        XCTAssertNil(home.snapshot.taskBoard?.task(id: doneID))
        // The same revision again reads nothing.
        announce(first.revision)
        try await Task.sleep(for: .milliseconds(100))
        let readsForTheFirstRevision = await runtime.finishedTaskReadCount()
        XCTAssertEqual(readsForTheFirstRevision, 1)

        // A task is archived: a new revision. The read fails, and the chips
        // stay as they were; the next snapshot tries again.
        announce(second.revision)
        try await Task.sleep(for: .milliseconds(100))
        let readsAfterTheFailure = await runtime.finishedTaskReadCount()
        XCTAssertEqual(readsAfterTheFailure, 2)
        XCTAssertEqual(home.finishedTasks.revision, first.revision)
        announce(second.revision)
        try await waitForRevision(second.revision)
        XCTAssertEqual(chips().taskID(for: CoordinatorTaskLink.url(taskID: archivedID)), archivedID)

        // A board without a revision, as from a Mac whose task system
        // stopped, leaves no chip.
        announce(nil)
        XCTAssertNil(home.finishedTasks.revision)
        XCTAssertTrue(home.finishedTasks.chips.isEmpty)

        // Unpairing keeps none either.
        announce(second.revision)
        try await waitForRevision(second.revision)
        subject.stopObserving()
        XCTAssertNil(home.finishedTasks.revision)
        XCTAssertNil(chips().taskID(for: CoordinatorTaskLink.url(taskID: doneID)))
    }

    /// The coordinator's chat lists both of the coordinator's queues as one,
    /// from a Mac that shares its own queue: the conversation's queue, then
    /// the coordinator's. One Resume, on the first held row, presents the
    /// Stop's token; Remove goes to the queue that holds the row. A queue
    /// for another conversation is not this chat's. Without the capability
    /// the phone reads nothing and lists the conversation's queue as before,
    /// and a phone without send access gets no Resume or Remove.
    func testTheCoordinatorChatListsBothQueuesAndActsOnEach() async throws {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .live(gatewayURL: URL(string: "https://toastty.test.ts.net")!),
            snapshot: MobileHomeSnapshot(hostName: "toastty.test.ts.net", workspaces: []),
            connectionState: .offline
        )
        let subject = LiveSessionsController(runtime: runtime, hostName: "toastty.test.ts.net", homeController: home)
        await subject.updateDeviceScopes([.read, .send])
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: [.tasks, .conversationInputControl]
        ))
        var list = snapshot(titles: ["Alpha"])
        let alphaID = list.conversations[0].conversationID
        let held = RemoteCoordinatorQueue(
            revision: "revision-1", conversationID: alphaID, heldSetToken: "stop-1",
            entries: [
                RemoteCoordinatorQueueEntry(id: "mac-1", text: "From the Mac", isHeld: true),
                RemoteCoordinatorQueueEntry(id: "task-1", text: "Ready for review", sender: "task Fix the dot"),
            ]
        )
        let elsewhere = RemoteCoordinatorQueue(
            revision: "revision-2", conversationID: RemoteConversationID(rawValue: UUID()), entries: [
                RemoteCoordinatorQueueEntry(id: "other", text: "Not this chat's"),
            ]
        )
        await runtime.scriptCoordinatorQueue([held, elsewhere])
        func announce(_ revision: String?) {
            list.conversations[0].inputControl = RemoteConversationInputControl(
                canQueue: true,
                queuedMessages: [RemoteQueuedMessage(clientRequestID: "phone-1", text: "From the phone", enqueuedAt: .now)],
                isQueuePaused: true
            )
            list.workspaces = [RemoteWorkspaceSummary(
                id: try! XCTUnwrap(list.conversations[0].placement.workspaceID), title: "Coordinator", panels: [],
                isCoordinator: true, coordinatorConversationID: alphaID,
                coordinatorQueueRevision: revision
            )]
            list.tasks = RemoteTaskBoard(doneCount: 0)
            subject.consumeSessionsState(SessionsRuntime.State(connectionGeneration: 7, snapshot: list, phase: .live))
        }
        func queuedRows(_ controller: LiveConversationController) -> [(id: String, queued: ToasttyQueuedSendPresentation)] {
            controller.transcriptPresentation.sendItems.compactMap { item in
                guard case .queued(let queued) = item.content else { return nil }
                return (item.clientRequestID, queued)
            }
        }
        announce(held.revision)
        await subject.openConversation(alphaID.rawValue)
        let controller = try XCTUnwrap(subject.activeConversationController)

        // An older Mac: no read, and the conversation's queue as before.
        try await Task.sleep(for: .milliseconds(100))
        let readsByAnOlderMac = await runtime.coordinatorQueueReadCount()
        XCTAssertEqual(readsByAnOlderMac, 0)
        XCTAssertEqual(queuedRows(controller).map(\.id), ["phone-1"])
        XCTAssertEqual(queuedRows(controller).first?.queued.resumeTitle, "Send next")

        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: [.tasks, .conversationInputControl, .coordinatorQueue]
        ))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while controller.coordinatorQueue != held, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.coordinatorQueue, held)
        let rows = queuedRows(controller)
        XCTAssertEqual(rows.map(\.id), ["phone-1", "mac-1", "task-1"])
        XCTAssertEqual(rows.map(\.queued.position), [1, 2, 3])
        XCTAssertEqual(rows.map(\.queued.isPaused), [true, true, false])
        XCTAssertEqual(rows.map(\.queued.resumeTitle), ["Resume all 2", nil, nil])
        XCTAssertEqual(rows.map(\.queued.canEdit), [true, false, false])
        XCTAssertEqual(rows.map(\.queued.canChange), [true, true, true])
        XCTAssertEqual(
            controller.transcriptPresentation.sendItems.last?.text,
            "From task Fix the dot:\nReady for review"
        )

        _ = await controller.removeQueuedMessage("mac-1")
        _ = await controller.removeQueuedMessage("phone-1")
        await controller.resumeQueue()
        let updates = await runtime.recordedQueueUpdates()
        XCTAssertEqual(updates.map(\.action), [.coordinatorRemove, .remove, .coordinatorResume])
        XCTAssertEqual(updates.map(\.clientRequestID), ["mac-1", "phone-1", nil])
        XCTAssertEqual(updates.last?.heldSetToken, "stop-1")
        XCTAssertEqual(Set(updates.map(\.conversationID)), [alphaID])

        // Without send access: the rows show, without Resume or Remove.
        await subject.updateDeviceScopes([.read])
        let readOnly = queuedRows(controller).filter { $0.id != "phone-1" }
        XCTAssertEqual(readOnly.map(\.queued.canChange), [false, false])
        XCTAssertTrue(queuedRows(controller).allSatisfy { $0.queued.resumeTitle == nil })

        // A queue for an earlier agent's conversation is not this chat's.
        announce(elsewhere.revision)
        let cleared = ContinuousClock.now.advanced(by: .seconds(3))
        while controller.coordinatorQueue != nil, ContinuousClock.now < cleared {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(controller.coordinatorQueue)
        XCTAssertEqual(queuedRows(controller).map(\.id), ["phone-1"])
        subject.stopObserving()
    }

    /// A row of the coordinator's own queue warns while the Mac marks its
    /// typing as interrupted. When the Mac answers a Remove with `failed`,
    /// the row stays and says so, until a later Remove works or the row
    /// leaves the queue. A Remove whose answer this phone cannot read, as
    /// an older phone cannot read `failed`, keeps the row and says nothing.
    func testACoordinatorRowWarnsAndKeepsAFailedRemove() async throws {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .live(gatewayURL: URL(string: "https://toastty.test.ts.net")!),
            snapshot: MobileHomeSnapshot(hostName: "toastty.test.ts.net", workspaces: []),
            connectionState: .offline
        )
        let subject = LiveSessionsController(runtime: runtime, hostName: "toastty.test.ts.net", homeController: home)
        await subject.updateDeviceScopes([.read, .send])
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live,
            capabilities: [.tasks, .conversationInputControl, .coordinatorQueue]
        ))
        var list = snapshot(titles: ["Alpha"])
        let alphaID = list.conversations[0].conversationID
        let restored = RemoteCoordinatorQueue(
            revision: "revision-1", conversationID: alphaID, heldSetToken: "relaunch",
            entries: [
                RemoteCoordinatorQueueEntry(id: "mac-1", text: "Create the task", isHeld: true, typingWasInterrupted: true),
                RemoteCoordinatorQueueEntry(id: "task-1", text: "Ready for review", sender: "task Fix the dot"),
            ]
        )
        var withoutTask = restored
        withoutTask.revision = "revision-2"
        withoutTask.entries.removeLast()
        await runtime.scriptCoordinatorQueue([restored, withoutTask])
        func announce(_ revision: String) {
            list.conversations[0].inputControl = RemoteConversationInputControl(canQueue: true)
            list.workspaces = [RemoteWorkspaceSummary(
                id: try! XCTUnwrap(list.conversations[0].placement.workspaceID), title: "Coordinator", panels: [],
                isCoordinator: true, coordinatorConversationID: alphaID,
                coordinatorQueueRevision: revision
            )]
            list.tasks = RemoteTaskBoard(doneCount: 0)
            subject.consumeSessionsState(SessionsRuntime.State(connectionGeneration: 7, snapshot: list, phase: .live))
        }
        func rows(_ controller: LiveConversationController) -> [String: ToasttyQueuedSendPresentation] {
            controller.transcriptPresentation.sendItems.reduce(into: [:]) { rows, item in
                guard case .queued(let queued) = item.content else { return }
                rows[item.clientRequestID] = queued
            }
        }
        func waitFor(_ queue: RemoteCoordinatorQueue, in controller: LiveConversationController) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while controller.coordinatorQueue != queue, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(controller.coordinatorQueue, queue)
        }
        announce(restored.revision)
        await subject.openConversation(alphaID.rawValue)
        let controller = try XCTUnwrap(subject.activeConversationController)
        try await waitFor(restored, in: controller)

        XCTAssertEqual(rows(controller)["mac-1"]?.warning, ToasttySendPresentationAdapter.typingInterruptedWarning)
        XCTAssertNil(rows(controller)["task-1"]?.warning)
        XCTAssertTrue(rows(controller).values.allSatisfy { $0.actionFailure == nil })

        // The Mac could not save its queue: the row stays and says so.
        await runtime.scriptQueueUpdates([.failed, nil, .failed])
        let failed = await controller.removeQueuedMessage("task-1")
        XCTAssertFalse(failed)
        XCTAssertEqual(rows(controller)["task-1"]?.actionFailure, ToasttySendPresentationAdapter.removeFailedNotice)
        XCTAssertNil(rows(controller)["mac-1"]?.actionFailure)
        XCTAssertEqual(controller.coordinatorQueue, restored)

        // An answer this phone cannot read: the row stays, and the note
        // of the earlier failure goes with the new attempt.
        let unreadable = await controller.removeQueuedMessage("task-1")
        XCTAssertFalse(unreadable)
        XCTAssertNotNil(rows(controller)["task-1"])
        XCTAssertNil(rows(controller)["task-1"]?.actionFailure)

        // Failed again, then the row leaves the Mac's queue: the note goes
        // with it.
        _ = await controller.removeQueuedMessage("task-1")
        XCTAssertEqual(rows(controller)["task-1"]?.actionFailure, ToasttySendPresentationAdapter.removeFailedNotice)
        announce(withoutTask.revision)
        try await waitFor(withoutTask, in: controller)
        XCTAssertNil(rows(controller)["task-1"])
        XCTAssertTrue(controller.coordinatorRemoveFailures.isEmpty)

        let updates = await runtime.recordedQueueUpdates()
        XCTAssertEqual(updates.map(\.action), [.coordinatorRemove, .coordinatorRemove, .coordinatorRemove])
        subject.stopObserving()
    }

    /// The coordinator's chat shows attached images as thumbnails only with
    /// a Mac that serves them and read access, whichever comes last: the
    /// capability with a connection state, or the scopes, as with a stored
    /// credential. Without either, the files show by name.
    func testTheCoordinatorChatShowsAttachedImagesOnlyWhenTheMacServesThem() async throws {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .live(gatewayURL: URL(string: "https://toastty.test.ts.net")!),
            snapshot: MobileHomeSnapshot(hostName: "toastty.test.ts.net", workspaces: []),
            connectionState: .offline
        )
        let subject = LiveSessionsController(runtime: runtime, hostName: "toastty.test.ts.net", homeController: home)
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7, phase: .live, capabilities: [.tasks, .coordinatorAttachmentImages]
        ))
        var list = snapshot(titles: ["Alpha"])
        let alpha = list.conversations[0]
        list.workspaces = [RemoteWorkspaceSummary(
            id: try XCTUnwrap(alpha.placement.workspaceID), title: "Coordinator", panels: [],
            isCoordinator: true, coordinatorConversationID: alpha.conversationID
        )]
        list.tasks = RemoteTaskBoard(doneCount: 0)
        subject.consumeSessionsState(SessionsRuntime.State(connectionGeneration: 7, snapshot: list, phase: .live))
        let coordinatorID = try XCTUnwrap(home.snapshot.coordinatorConversation?.id)
        await subject.openConversation(coordinatorID)
        let controller = try XCTUnwrap(subject.activeConversationController)

        // The capability came before the scopes: no read access yet.
        XCTAssertFalse(controller.showsCoordinatorAttachedImages)
        await subject.updateDeviceScopes([.read])
        XCTAssertTrue(controller.showsCoordinatorAttachedImages)

        // A Mac without the capability, after a reconnect.
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 8, phase: .live, capabilities: [.tasks]
        ))
        XCTAssertFalse(controller.showsCoordinatorAttachedImages)
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 9, phase: .live, capabilities: [.tasks, .coordinatorAttachmentImages]
        ))
        XCTAssertTrue(controller.showsCoordinatorAttachedImages)
        subject.stopObserving()
    }

    func testSessionStartTreatsEveryUnansweredRequestAsUnconfirmed() async {
        let runtime = LiveRuntimeSpy()
        let conversationID = RemoteConversationID()
        await runtime.scriptSessionStarts([
            .success(RemoteSessionStartResponse(result: .started(conversationID: conversationID))),
            .success(RemoteSessionStartResponse(result: .rejected(reason: .busy))),
            // The coordinator refused to send: not live, or no capability.
            .success(nil),
            .failure(.network(reason: .timedOut)),
        ])
        let home = HomeScreenController(
            runtimeMode: .live(gatewayURL: URL(string: "https://toastty.test.ts.net")!),
            snapshot: MobileHomeSnapshot(hostName: "toastty.test.ts.net", workspaces: []),
            connectionState: .live
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home
        )
        let request = RemoteSessionStartRequest(
            clientRequestID: "request-1", workspaceID: UUID(), profileID: "claude", text: "Hi"
        )

        var outcomes: [ToasttySessionStartOutcome] = []
        for _ in 0..<4 {
            outcomes.append(await home.startSession(request))
        }

        XCTAssertEqual(outcomes, [
            .answered(.started(conversationID: conversationID)),
            .answered(.rejected(reason: .busy)),
            .unconfirmed,
            .unconfirmed,
        ])
        withExtendedLifetime(subject) {}
    }

    func testTaskActionsNeedTheHostCapabilityAndThisDevicesSendAccess() async {
        let home = HomeScreenController(
            runtimeMode: .live(gatewayURL: URL(string: "https://toastty.test.ts.net")!),
            snapshot: MobileHomeSnapshot(hostName: "toastty.test.ts.net", workspaces: []),
            connectionState: .offline
        )
        let subject = LiveSessionsController(
            runtime: LiveRuntimeSpy(),
            hostName: "toastty.test.ts.net",
            homeController: home
        )
        func connect(capabilities: Set<RemoteGatewayCapability>) {
            subject.consumeSessionsState(SessionsRuntime.State(
                connectionGeneration: 7, snapshot: snapshot(titles: ["Alpha"]), phase: .live
            ))
            subject.consumeCoordinatorState(ConnectionCoordinator.State(
                connectionGeneration: 7, phase: .live, capabilities: capabilities
            ))
        }

        connect(capabilities: [.tasks, .taskActions])
        await subject.updateDeviceScopes([.read])
        XCTAssertFalse(home.canActOnTasks, "A read-only device cannot change the Mac")
        await subject.updateDeviceScopes([.read, .send])
        XCTAssertTrue(home.canActOnTasks)
        connect(capabilities: [.tasks])
        XCTAssertFalse(home.canActOnTasks, "An older Mac keeps the read-only task bar")
    }

    func testATaskActionWithoutAnAnswerIsUnconfirmedAndOneNeverSentSaysSo() async throws {
        let runtime = LiveRuntimeSpy()
        await runtime.scriptTaskActions([
            .success(RemoteTaskActionResponse(result: .performed)),
            // The coordinator refused to send: not live, or no capability.
            .success(nil),
            .failure(.network(reason: .timedOut)),
        ])
        let home = HomeScreenController(
            runtimeMode: .live(gatewayURL: URL(string: "https://toastty.test.ts.net")!),
            snapshot: MobileHomeSnapshot(hostName: "toastty.test.ts.net", workspaces: []),
            connectionState: .live
        )
        let subject = LiveSessionsController(runtime: runtime, hostName: "toastty.test.ts.net", homeController: home)
        let send = try XCTUnwrap(home.sendTaskAction)
        let request = RemoteTaskActionRequest(taskID: UUID(), action: .merge, clientRequestID: "request-1")

        var outcomes: [ToasttyTaskActionSendOutcome] = []
        for _ in 0..<3 {
            outcomes.append(await send(request))
        }

        XCTAssertEqual(outcomes, [.answered(.performed), .notSent, .unconfirmed])
        withExtendedLifetime(subject) {}
    }

    func testSubspaceDoneNeedsTheHostCapabilityAndThisDevicesSendAccess() async {
        let home = HomeScreenController(
            runtimeMode: .live(gatewayURL: URL(string: "https://toastty.test.ts.net")!),
            snapshot: MobileHomeSnapshot(hostName: "toastty.test.ts.net", workspaces: []),
            connectionState: .offline
        )
        let subject = LiveSessionsController(
            runtime: LiveRuntimeSpy(),
            hostName: "toastty.test.ts.net",
            homeController: home
        )
        func connect(capabilities: Set<RemoteGatewayCapability>) {
            subject.consumeSessionsState(SessionsRuntime.State(
                connectionGeneration: 7, snapshot: snapshot(titles: ["Alpha"]), phase: .live
            ))
            subject.consumeCoordinatorState(ConnectionCoordinator.State(
                connectionGeneration: 7, phase: .live, capabilities: capabilities
            ))
        }

        connect(capabilities: [.workspaceDone])
        XCTAssertFalse(home.canMarkSubspacesDone, "The device's access is not known yet")

        await subject.updateDeviceScopes([.read])
        XCTAssertFalse(home.canMarkSubspacesDone, "A read-only device cannot change the Mac")

        await subject.updateDeviceScopes([.read, .send])
        XCTAssertTrue(home.canMarkSubspacesDone)

        connect(capabilities: [])
        XCTAssertFalse(home.canMarkSubspacesDone, "An older Mac does not take the change")
    }

    func testActiveConversationSendAndReceiptDismissUseDomainRuntime() async throws {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: snapshot(titles: ["Alpha"]).presentation(),
            connectionState: .live
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home
        )
        let conversation = try XCTUnwrap(home.snapshot.workspaces.first?.conversations.first)
        await subject.openConversation(conversation.id)
        let controller = try XCTUnwrap(subject.activeConversationController)
        let epoch = RemoteInputEpoch(
            bindingID: UUID(uuidString: "CC000000-0000-0000-0000-000000000001")!,
            counter: 5
        )
        let stamp = ConversationComposerStamp(
            connectionGeneration: 7,
            streamSnapshotOrdinal: 2,
            projectionRunID: runID,
            projectionGeneration: 12,
            latestSequence: 4,
            inputEpoch: epoch
        )
        controller.stop()
        controller.consume(stateForComposer(
            conversationID: conversation.id,
            stamp: stamp,
            epoch: epoch
        ))

        let outcome = await controller.send("ship it")
        await controller.dismissSendReceipt("request-1")

        XCTAssertEqual(outcome, .enqueued(clientRequestID: "request-1"))
        let sends = await runtime.recordedSends()
        XCTAssertEqual(sends, [.init(
            conversationID: RemoteConversationID(rawValue: conversation.id),
            text: "ship it",
            stamp: stamp
        )])
        let dismissals = await runtime.recordedDismissals()
        XCTAssertEqual(dismissals, [.init(
            conversationID: RemoteConversationID(rawValue: conversation.id),
            clientRequestID: "request-1"
        )])
        subject.stopObserving()
    }

    func testSelectionOwnsOneConversationRuntimeAndDismissClosesIt() async throws {
        let runtime = LiveRuntimeSpy()
        await runtime.holdConversationOpens()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: snapshot(titles: ["Alpha"]).presentation(),
            connectionState: .live
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home
        )
        let conversation = try XCTUnwrap(home.snapshot.workspaces.first?.conversations.first)

        home.open(conversation)
        await runtime.waitForConversationOpenToStart(
            RemoteConversationID(rawValue: conversation.id)
        )
        var conversationOpenCount = await runtime.conversationOpenCount()
        XCTAssertEqual(conversationOpenCount, 1)

        let duplicateOpen = Task { @MainActor in
            await subject.openConversation(conversation.id)
        }
        await Task.yield()
        await runtime.releaseConversationOpens()
        await duplicateOpen.value

        XCTAssertEqual(subject.activeConversationController?.conversationID, conversation.id)
        conversationOpenCount = await runtime.conversationOpenCount()
        XCTAssertEqual(conversationOpenCount, 1)
        var activeConversationIDs = await runtime.activeConversationIDs()
        XCTAssertEqual(activeConversationIDs, Set([RemoteConversationID(rawValue: conversation.id)]))

        home.dismissConversation()
        await subject.closeConversation(conversation.id)

        XCTAssertNil(subject.activeConversationController)
        activeConversationIDs = await runtime.activeConversationIDs()
        XCTAssertEqual(activeConversationIDs, Set<RemoteConversationID>())
        let conversationCloseCount = await runtime.conversationCloseCount()
        XCTAssertEqual(conversationCloseCount, 1)
        subject.stopObserving()
    }

    func testNewestDifferentSelectionWinsWhilePreviousOpenIsInFlight() async throws {
        let runtime = LiveRuntimeSpy()
        await runtime.holdConversationOpens()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: snapshot(titles: ["Alpha", "Zulu"]).presentation(),
            connectionState: .live
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home
        )
        let conversations = home.snapshot.workspaces.flatMap(\.conversations)
        let alpha = try XCTUnwrap(conversations.first { $0.title == "Alpha" })
        let zulu = try XCTUnwrap(conversations.first { $0.title == "Zulu" })
        let alphaID = RemoteConversationID(rawValue: alpha.id)
        let zuluID = RemoteConversationID(rawValue: zulu.id)

        home.open(alpha)
        await runtime.waitForConversationOpenToStart(alphaID)
        home.open(zulu)
        await runtime.waitForConversationOpenToStart(zuluID)

        await runtime.releaseConversationOpens()
        await subject.openConversation(zulu.id)
        await runtime.waitForConversationClose(alphaID)

        XCTAssertEqual(home.selectedConversationID, zulu.id)
        XCTAssertEqual(subject.activeConversationController?.conversationID, zulu.id)
        let activeConversationIDs = await runtime.activeConversationIDs()
        XCTAssertEqual(activeConversationIDs, Set([zuluID]))
        let closedConversationIDs = await runtime.closedConversationIDs()
        XCTAssertEqual(closedConversationIDs, [alphaID])

        home.dismissConversation()
        await subject.closeConversation(zulu.id)
        subject.stopObserving()
    }

    private var runID: RemoteProjectionRunID {
        RemoteProjectionRunID(
            rawValue: UUID(uuidString: "AAAA0000-0000-0000-0000-000000000001")!
        )
    }

    private func snapshot(titles: [String]) -> CompatibleSessionListSnapshot {
        CompatibleSessionListSnapshot(
            projectionRunID: runID,
            conversations: titles.map { title in
                let stableTitle = title.replacingOccurrences(of: " updated", with: "")
                let isAlpha = stableTitle == "Alpha"
                return CompatibleConversationSummary(
                    conversationID: RemoteConversationID(rawValue: UUID(
                        uuidString: isAlpha
                            ? "BB000000-0000-0000-0000-000000000001"
                            : "BB000000-0000-0000-0000-000000000002"
                    )!),
                    provider: .codex,
                    title: title,
                    placement: RemoteConversationPlacement(
                        workspaceID: UUID(
                            uuidString: isAlpha
                                ? "AA000000-0000-0000-0000-000000000001"
                                : "AA000000-0000-0000-0000-000000000002"
                        ),
                        workspaceTitle: "\(stableTitle) workspace"
                    ),
                    cwd: "/redacted",
                    state: MobileSessionDisplayState.ready,
                    inputAvailability: .unavailable(reason: .known(.unknownProviderState)),
                    projectionGeneration: 12,
                    latestSequence: 4,
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            },
            generatedAt: Date(timeIntervalSince1970: 101)
        )
    }

    private func composerState(
        for conversation: MobileConversation,
        failure: ConversationSendGateFailure
    ) -> ConversationRuntime.State {
        ConversationRuntime.State(
            conversationID: RemoteConversationID(rawValue: conversation.id),
            connectionGeneration: 7,
            phase: .live,
            composerAuthority: ConversationComposerAuthority(gateFailure: failure),
            sendReconciliation: SendReconciliation()
        )
    }

    private func composerTextView(in view: UIView) -> ToasttyComposerUIKitTextView? {
        if let textView = view as? ToasttyComposerUIKitTextView { return textView }
        return view.subviews.lazy.compactMap { self.composerTextView(in: $0) }.first
    }

    private func attachComposerScreenshot(_ window: UIWindow, named name: String) {
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func stateForComposer(
        conversationID: UUID,
        stamp: ConversationComposerStamp,
        epoch: RemoteInputEpoch
    ) -> ConversationRuntime.State {
        ConversationRuntime.State(
            conversationID: RemoteConversationID(rawValue: conversationID),
            connectionGeneration: stamp.connectionGeneration,
            projectionRunID: stamp.projectionRunID,
            projectionGeneration: stamp.projectionGeneration,
            latestSequence: stamp.latestSequence,
            phase: .live,
            composerAuthority: ConversationComposerAuthority(
                stamp: stamp,
                inputAvailability: .openPrompt(epoch: epoch)
            ),
            sendReconciliation: SendReconciliation()
        )
    }
}

private struct ForegroundProbeComposerHarness: View {
    let sessions: LiveSessionsController
    let home: HomeScreenController
    let conversation: MobileConversation
    let drafts: ToasttyComposerDraftStore

    var body: some View {
        ToasttyConversationScreen(
            conversationID: conversation.id,
            controller: home,
            composer: sessions.composerPresentation(for: conversation),
            drafts: drafts,
            canAcknowledgeRead: false
        )
    }
}

private actor LiveRuntimeSpy: LiveConnectionRuntime {
    struct SendCall: Equatable {
        var conversationID: RemoteConversationID
        var text: String
        var stamp: ConversationComposerStamp
    }

    struct DismissCall: Equatable {
        var conversationID: RemoteConversationID
        var clientRequestID: String
    }

    private var connectionRequests = 0
    private var restartRequests = 0
    private var suspended = false
    private var backgrounds: [UInt64] = []
    private var resumes: [UInt64] = []
    private var conversationRuntimes: [RemoteConversationID: ConversationRuntime] = [:]
    private var shouldHoldConversationOpens = false
    private var conversationOpenContinuations: [CheckedContinuation<Void, Never>] = []
    private var startedConversationIDs: Set<RemoteConversationID> = []
    private var conversationOpenStartedContinuations:
        [RemoteConversationID: [CheckedContinuation<Void, Never>]] = [:]
    private var conversationCloseContinuations:
        [RemoteConversationID: [CheckedContinuation<Void, Never>]] = [:]
    private var conversationOpenRequests = 0
    private var conversationCloseRequests = 0
    private var closedConversations: [RemoteConversationID] = []
    private var deviceScopes: [RemoteDeviceScope] = []
    private var sends: [SendCall] = []
    private var dismissals: [DismissCall] = []
    private var sessionStartScripts: [Result<RemoteSessionStartResponse?, GatewayFailure>] = []
    private var taskActionScripts: [Result<RemoteTaskActionResponse?, GatewayFailure>] = []

    func currentCoordinatorState() -> ConnectionCoordinator.State {
        ConnectionCoordinator.State()
    }

    func coordinatorStates() -> AsyncStream<ConnectionCoordinator.State> {
        AsyncStream { $0.finish() }
    }

    func sessionsStates() -> AsyncStream<SessionsRuntime.State> {
        AsyncStream { $0.finish() }
    }

    func connectIfNeeded() {
        connectionRequests += 1
    }

    func enterBackground(lifecycleSequence: UInt64) -> Duration? {
        backgrounds.append(lifecycleSequence)
        return nil
    }
    func resume(lifecycleSequence: UInt64, backgroundedAt: ContinuousClock.Instant?) { resumes.append(lifecycleSequence) }
    func backgroundSequences() -> [UInt64] { backgrounds }
    func resumeSequences() -> [UInt64] { resumes }

    func restart() {
        connectionRequests += 1
        restartRequests += 1
    }

    func suspend() {
        suspended = true
    }

    func restartCount() -> Int { restartRequests }

    func openConversation(_ conversationID: RemoteConversationID) async -> ConversationRuntime {
        conversationOpenRequests += 1
        startedConversationIDs.insert(conversationID)
        let startedContinuations = conversationOpenStartedContinuations.removeValue(
            forKey: conversationID
        ) ?? []
        startedContinuations.forEach { $0.resume() }
        if shouldHoldConversationOpens {
            await withCheckedContinuation { continuation in
                conversationOpenContinuations.append(continuation)
            }
        }
        if let runtime = conversationRuntimes[conversationID] {
            return runtime
        }
        let runtime = ConversationRuntime(conversationID: conversationID)
        conversationRuntimes[conversationID] = runtime
        return runtime
    }

    func closeConversation(_ conversationID: RemoteConversationID) async {
        conversationCloseRequests += 1
        closedConversations.append(conversationID)
        let closeContinuations = conversationCloseContinuations.removeValue(
            forKey: conversationID
        ) ?? []
        closeContinuations.forEach { $0.resume() }
        guard let runtime = conversationRuntimes.removeValue(forKey: conversationID) else {
            return
        }
        _ = await runtime.suspend(connectionGeneration: 1)
    }

    func loadOlder(_ conversationID: RemoteConversationID) {}

    func updateDeviceScopes(_ scopes: [RemoteDeviceScope]) {
        deviceScopes = scopes
    }

    func sendMessage(
        conversationID: RemoteConversationID,
        text: String,
        composerStamp: ConversationComposerStamp
    ) -> ConversationSendOutcome {
        sends.append(.init(
            conversationID: conversationID,
            text: text,
            stamp: composerStamp
        ))
        return .enqueued(clientRequestID: "request-1")
    }

    func dismissSendReceipt(
        conversationID: RemoteConversationID,
        clientRequestID: String
    ) {
        dismissals.append(.init(
            conversationID: conversationID,
            clientRequestID: clientRequestID
        ))
    }

    func acknowledgeConversationRead(
        _ request: RemoteConversationReadAcknowledgementRequest
    ) -> RemoteConversationReadAcknowledgementResponse? {
        nil
    }

    func scriptSessionStarts(_ scripts: [Result<RemoteSessionStartResponse?, GatewayFailure>]) {
        sessionStartScripts = scripts
    }

    func startSession(
        _ request: RemoteSessionStartRequest
    ) async throws -> RemoteSessionStartResponse? {
        try sessionStartScripts.removeFirst().get()
    }

    func scriptTaskActions(_ scripts: [Result<RemoteTaskActionResponse?, GatewayFailure>]) {
        taskActionScripts = scripts
    }

    private var quietDigestAnswers: [Result<RemoteCoordinatorQuietDigests, GatewayFailure>] = []
    private var quietDigestReads = 0

    /// What each read of the quiet digests answers, in turn.
    func scriptQuietDigests(_ answers: [Result<RemoteCoordinatorQuietDigests, GatewayFailure>]) {
        quietDigestAnswers = answers
    }

    func coordinatorQuietDigests() async throws -> RemoteCoordinatorQuietDigests? {
        quietDigestReads += 1
        guard quietDigestAnswers.isEmpty == false else { throw GatewayFailure.invalidResponse }
        return try quietDigestAnswers.removeFirst().get()
    }

    func quietDigestReadCount() -> Int { quietDigestReads }

    private var finishedTaskAnswers: [Result<RemoteFinishedTasks, GatewayFailure>] = []
    private var finishedTaskReads = 0

    /// What each read of the finished tasks answers, in turn.
    func scriptFinishedTasks(_ answers: [Result<RemoteFinishedTasks, GatewayFailure>]) {
        finishedTaskAnswers = answers
    }

    func finishedTasks() async throws -> RemoteFinishedTasks? {
        finishedTaskReads += 1
        guard finishedTaskAnswers.isEmpty == false else { throw GatewayFailure.invalidResponse }
        return try finishedTaskAnswers.removeFirst().get()
    }

    func finishedTaskReadCount() -> Int { finishedTaskReads }

    private var coordinatorQueueAnswers: [RemoteCoordinatorQueue] = []
    private var coordinatorQueueReads = 0
    private var queueUpdates: [RemoteConversationQueueUpdateRequest] = []

    /// What each read of the coordinator's own queue answers, in turn.
    func scriptCoordinatorQueue(_ answers: [RemoteCoordinatorQueue]) {
        coordinatorQueueAnswers = answers
    }

    func coordinatorQueue() async throws -> RemoteCoordinatorQueue? {
        coordinatorQueueReads += 1
        guard coordinatorQueueAnswers.isEmpty == false else { throw GatewayFailure.invalidResponse }
        return coordinatorQueueAnswers.removeFirst()
    }

    func coordinatorQueueReadCount() -> Int { coordinatorQueueReads }

    /// What each queue update answers, in turn: `nil` throws, as a
    /// response that this phone cannot decode does. `updated` once these
    /// run out.
    private var queueUpdateAnswers: [RemoteConversationQueueUpdateResult?] = []

    func scriptQueueUpdates(_ answers: [RemoteConversationQueueUpdateResult?]) {
        queueUpdateAnswers = answers
    }

    func updateQueue(
        _ request: RemoteConversationQueueUpdateRequest
    ) async throws -> RemoteConversationQueueUpdateResponse? {
        queueUpdates.append(request)
        let answer = queueUpdateAnswers.isEmpty ? .updated : queueUpdateAnswers.removeFirst()
        guard let answer else { throw GatewayFailure.invalidResponse }
        return RemoteConversationQueueUpdateResponse(result: answer)
    }

    func recordedQueueUpdates() -> [RemoteConversationQueueUpdateRequest] { queueUpdates }

    func taskAction(
        _ request: RemoteTaskActionRequest
    ) async throws -> RemoteTaskActionResponse? {
        try taskActionScripts.removeFirst().get()
    }

    func activeConversationIDs() -> Set<RemoteConversationID> {
        Set(conversationRuntimes.keys)
    }

    func holdConversationOpens() {
        shouldHoldConversationOpens = true
    }

    func releaseConversationOpens() {
        shouldHoldConversationOpens = false
        let continuations = conversationOpenContinuations
        conversationOpenContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func waitForConversationOpenToStart(_ conversationID: RemoteConversationID) async {
        guard startedConversationIDs.contains(conversationID) == false else { return }
        await withCheckedContinuation { continuation in
            conversationOpenStartedContinuations[conversationID, default: []].append(continuation)
        }
    }

    func waitForConversationClose(_ conversationID: RemoteConversationID) async {
        guard closedConversations.contains(conversationID) == false else { return }
        await withCheckedContinuation { continuation in
            conversationCloseContinuations[conversationID, default: []].append(continuation)
        }
    }

    func conversationOpenCount() -> Int { conversationOpenRequests }
    func conversationCloseCount() -> Int { conversationCloseRequests }
    func closedConversationIDs() -> [RemoteConversationID] { closedConversations }

    func didSuspend() -> Bool { suspended }
    func connectCount() -> Int { connectionRequests }
    func latestDeviceScopes() -> [RemoteDeviceScope] { deviceScopes }
    func recordedSends() -> [SendCall] { sends }
    func recordedDismissals() -> [DismissCall] { dismissals }
}
