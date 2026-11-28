@testable import ToasttyApp
@testable import CoreState
import Foundation
import RemoteProtocol
import Testing

/// A quit or a crash during a turn of the coordinator's direct session.
/// Toastty saves each message that the process got until its turn ends.
/// The next start of the conversation reads them against Claude's
/// transcript: the chat says which turn was cut off, and a message that
/// Claude never took waits, paused, for the user.
@Suite(.serialized)
struct CoordinatorCutOffTurnTests {
    // MARK: - After a relaunch

    @MainActor
    @Test func aQuitDuringADirectTurnLeavesTheCutOffTurnAndTheUntakenMessagesToTheUser() async throws {
        let fixture = try CoordinatorChatFixture(savesQueue: true, savesWorkspaceRecord: true, agent: .claude)
        defer { fixture.tearDown() }
        let queueFile = try #require(fixture.queueFileURL)
        let recordFile = try #require(fixture.workspaceFileURL)
        let workspaceID = try #require(fixture.store.state.coordinatorWorkspaceID)
        try await fixture.waitUntil("the open prompt") { fixture.controller.promptIsOpenForTesting }

        // Claude took the first message and began its answer. The kill cut
        // the transcript's last line short: the steer's record never
        // finished, so Claude never took it.
        let transcript = URL(filePath: fixture.conversations.runtimeHome).appendingPathComponent("native-direct.jsonl")
        try Data(#"""
        {"type":"user","uuid":"uuid-taken","message":{"role":"user","content":"Summarize the open pull requests"}}
        {"type":"assistant","uuid":"a1","parentUuid":"uuid-taken","message":{"role":"assistant","content":[{"type":"text","text":"Looking"}]}}
        {"type":"user","uuid":"uuid-steer","message":{"role":"us
        """#.utf8).write(to: transcript)
        try CoordinatorWorkspaceRecord(
            workspaceID: workspaceID,
            panelID: fixture.panelID,
            directSession: .init(
                nativeSessionID: "native-direct",
                transcriptPath: transcript.path,
                scopedWorkspaceIDs: nil,
                messagesInTurn: [
                    .init(id: "mac-1", messageID: "uuid-taken", text: "Summarize the open pull requests", byUser: true),
                    .init(id: "mac-steer", messageID: "uuid-steer", text: "Only the ones of this week", byUser: true),
                    .init(id: "phone-1", messageID: "uuid-phone", text: "And the failing checks", byUser: true),
                ]
            )
        ).save(to: recordFile)
        // "Steer now" was typing the steer from the paused queue.
        try CoordinatorQueueSnapshot(
            workspaceID: workspaceID,
            queued: [],
            paused: [.init(id: "mac-steer", text: "Only the ones of this week")],
            typingEntryID: "mac-steer"
        ).save(to: queueFile)

        fixture.relaunch()
        #expect(fixture.controller.hasInterruptedEntry)
        fixture.controller.recoverDirectTurnForTesting(resumes: true)

        // Claude took the first message, so its turn was cut off. The other
        // two never reached the conversation: they wait, paused, in the
        // order they were sent, and nothing is sent again.
        #expect(fixture.controller.cutOffMessage?.id == "mac-1")
        #expect(fixture.controller.pausedEntries.map(\.text) == ["Only the ones of this week", "And the failing checks"])
        #expect(fixture.controller.pausedEntries.allSatisfy { $0.quitBeforeTaken && $0.typingWasInterrupted == false })
        // Under new IDs: the conversation refuses one that it took in this
        // run. The steer keeps the folder of its files.
        #expect(Set(fixture.controller.pausedEntries.map(\.id)).isDisjoint(with: ["mac-steer", "phone-1"]))
        #expect(fixture.controller.pausedEntries.first?.attachmentFolders.contains("mac-steer") == true)
        #expect(fixture.controller.hasInterruptedEntry == false)
        let saved = try #require(CoordinatorWorkspaceRecord.load(from: recordFile)?.directSession)
        #expect(saved.messagesInTurn == nil)
        #expect(saved.cutOffMessage?.id == "mac-1")
        #expect(CoordinatorQueueSnapshot.load(from: queueFile)?.paused.map(\.quitBeforeTaken) == [true, true])

        // The chat of a direct session says so, and marks each message
        // that Claude never took.
        let conversations = fixture.conversations
        conversations.sessionRuntimeStore.markDirectSession(sessionID: conversations.sessionID)
        let session = DirectSessionStandIn(
            panelID: fixture.panelID, sessionID: conversations.sessionID, service: conversations.service
        )
        conversations.service.attachDirectSession(session)
        fixture.chat.show(panelID: fixture.panelID)
        let cutOffNotice = CoordinatorChatModel.Notice.turnCutOff(message: "Summarize the open pull requests")
        try await fixture.waitUntil("the cut-off turn's notice") { fixture.chat.notice == cutOffNotice }
        #expect(Self.warnings(fixture.chat) == [CoordinatorChatModel.quitBeforeTakenWarning, CoordinatorChatModel.quitBeforeTakenWarning])
        #expect(session.written.isEmpty)

        // A second relaunch keeps both.
        fixture.relaunch()
        fixture.chat.show(panelID: fixture.panelID)
        try await fixture.waitUntil("the notice after a second relaunch") { fixture.chat.notice == cutOffNotice }
        #expect(fixture.controller.pausedEntries.allSatisfy { $0.quitBeforeTaken })
        #expect(session.written.isEmpty)

        // Send Again sends the cut-off message as a new message, once, and
        // the notice goes.
        fixture.chat.sendCutOffMessageAgain()
        try await fixture.waitUntil("the message sent again") { session.written.count == 1 }
        #expect(session.written.first?.contains("Summarize the open pull requests") == true)
        #expect(fixture.chat.notice == nil)
        #expect(CoordinatorWorkspaceRecord.load(from: recordFile)?.directSession?.cutOffMessage == nil)
        #expect(fixture.controller.pausedEntries.count == 2)

        // Send next lets the paused messages go as any others.
        fixture.chat.perform(.resume)
        #expect(fixture.controller.pausedEntries.isEmpty)
        #expect((fixture.controller.queuedEntries.map(\.quitBeforeTaken)).allSatisfy { $0 == false })
    }

    @MainActor
    @Test func aRestartStartsANewConversationWithoutTheCutOffNotice() async throws {
        let fixture = try CoordinatorChatFixture(savesQueue: true, savesWorkspaceRecord: true, agent: .claude)
        defer { fixture.tearDown() }
        let recordFile = try #require(fixture.workspaceFileURL)
        let workspaceID = try #require(fixture.store.state.coordinatorWorkspaceID)
        let transcript = URL(filePath: fixture.conversations.runtimeHome).appendingPathComponent("native-direct.jsonl")
        try Data(#"{"type":"user","uuid":"uuid-taken","message":{"role":"user","content":"Hi"}}"#.utf8).write(to: transcript)
        try CoordinatorWorkspaceRecord(
            workspaceID: workspaceID,
            panelID: fixture.panelID,
            directSession: .init(
                nativeSessionID: "native-direct",
                transcriptPath: transcript.path,
                scopedWorkspaceIDs: nil,
                messagesInTurn: [.init(id: "mac-1", messageID: "uuid-taken", text: "Hi", byUser: true)]
            )
        ).save(to: recordFile)
        fixture.relaunch()

        fixture.controller.recoverDirectTurnForTesting(resumes: false)

        #expect(fixture.controller.cutOffMessage == nil)
        #expect(fixture.controller.pausedEntries.isEmpty)
        #expect(CoordinatorWorkspaceRecord.load(from: recordFile)?.directSession?.messagesInTurn == nil)
    }

    @MainActor
    private static func warnings(_ chat: CoordinatorChatModel) -> [String] {
        chat.presentation.sendItems.compactMap { item in
            guard case .queued(let queued) = item.content else { return nil }
            return queued.warning
        }
    }

    @MainActor
    @Test func theNoticeQuotesTheMessageWithoutToasttysFirstLine() {
        let fromSender = "[Toastty] From a terminal command: Toastty cannot tell who ran it. Message ID 0AC62612-B148-49A9-88AE-A5EE72F1E3FF.\nRun the slow check"
        #expect(CoordinatorChatModel.excerpt(of: fromSender) == "Run the slow check")
        #expect(CoordinatorChatModel.excerpt(of: "First line\nSecond line") == "First line…")
        #expect(CoordinatorChatModel.excerpt(of: String(repeating: "a", count: 100)) == String(repeating: "a", count: 80) + "…")
    }

    // MARK: - Claude's transcript

    @Test func onlyAWholeUserRecordCountsAsTaken() {
        let transcript = Data(#"""
        {"type":"user","uuid":"taken","message":{"role":"user","content":"Hi"}}
        {"type":"assistant","uuid":"assistant-id","parentUuid":"parent-only","message":{"role":"assistant","content":[]}}
        {"type":"user","uuid":"cut-short","message":{"ro
        """#.utf8)
        let taken = DirectTurnRecovery.takenMessageIDs(
            in: transcript, among: ["taken", "assistant-id", "parent-only", "cut-short", "absent"]
        )
        #expect(taken == ["taken"])
    }

    @Test func aTranscriptThatCannotBeReadDecidesNothing() {
        let message = CoordinatorWorkspaceRecord.UnfinishedMessage(id: "m", messageID: "u", text: "Hi", byUser: true)
        let outcome = DirectTurnRecovery.resolve([message], transcriptPath: "/nonexistent/transcript.jsonl")
        #expect(outcome == DirectTurnRecovery.Outcome(unknown: [message]))
    }

    // MARK: - The session's list

    /// A stand-in for Claude Code: it answers the start request, takes each
    /// message (writes it back under its `uuid`) except one that says HOLD,
    /// and ends the turn at a message that says END, without taking it.
    private static let standInScript = #"""
    IFS= read -r start
    id=$(printf '%s' "$start" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
    printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"account":{"subscriptionType":"Claude Max"}}}}\n' "$id"
    while IFS= read -r line; do
      uuid=$(printf '%s' "$line" | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')
      case "$line" in
        *HOLD*) ;;
        *END*) printf '{"type":"result","subtype":"success","is_error":false}\n' ;;
        *) printf '{"type":"system","subtype":"init","session_id":"native-direct","apiKeySource":"none"}\n{"type":"user","uuid":"%s","isReplay":true,"message":{"role":"user","content":"taken"}}\n' "$uuid" ;;
      esac
    done
    """#

    @MainActor
    @Test func aMessageLeavesTheSessionsListAtTheEndOfTheTurnThatTookIt() async throws {
        let reports = Reports()
        let session = ClaudeDirectSession(
            panelID: UUID(),
            sessionID: "direct",
            requirements: .init(requiresPlanSignIn: true),
            host: nil,
            onTurnEnd: { _ in },
            onMessagesInTurnChange: { reports.all.append($0) },
            onEnd: { _ in }
        )
        try session.start(launch: ClaudeStreamLaunch(
            executablePath: "/bin/sh",
            arguments: ["-c", Self.standInScript],
            environment: ["PATH": "/usr/bin:/bin"],
            directory: NSTemporaryDirectory()
        ))
        defer { session.stop() }
        try await Self.waitUntil("the start") { session.phase == .ready }
        session.admit()

        #expect(session.send(text: "Check the build", clientRequestID: "m1", deliveryMode: .prompt) == .delivered)
        // The owner heard of it before the process could take it.
        #expect(reports.all.first?.map(\.clientRequestID) == ["m1"])
        #expect(reports.all.first?.first?.isTaken == false)
        try await Self.waitUntil("the receipt") { session.messagesInTurn.first?.isTaken == true }

        #expect(session.send(text: "HOLD: only this week", clientRequestID: "m2", deliveryMode: .steer) == .delivered)
        #expect(session.send(text: "END", clientRequestID: "m3", deliveryMode: .prompt) == .delivered)
        // The turn ended: the message it took leaves. Claude holds the
        // other two for the next turn, so they stay.
        try await Self.waitUntil("the turn's end") { session.messagesInTurn.map(\.clientRequestID) == ["m2", "m3"] }
        #expect(session.messagesInTurn.allSatisfy { $0.isTaken == false })
        #expect(reports.all.last == session.messagesInTurn)
    }

    @MainActor
    private final class Reports {
        var all: [[ClaudeDirectSession.MessageInTurn]] = []
    }

    @MainActor
    private static func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while condition() == false {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
