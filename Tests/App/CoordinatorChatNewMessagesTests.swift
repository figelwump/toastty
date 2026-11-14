@testable import ToasttyApp
import ConversationUI
import Foundation
import RemoteProtocol
import Testing

/// The line above the coordinator's messages that the user has not seen,
/// with the real controller and a Codex conversation read from its
/// transcript file.
@Suite(.serialized)
struct CoordinatorChatNewMessagesTests {
    @MainActor
    private func row(_ text: String, in fixture: CoordinatorChatFixture) -> ToasttyTranscriptRowID? {
        fixture.chat.presentation.rows.last { row in
            if case .assistantMessage(let rowText, _) = row.content { return rowText == text }
            return false
        }?.id
    }

    @MainActor
    private func waitForRow(_ text: String, in fixture: CoordinatorChatFixture) async throws -> ToasttyTranscriptRowID {
        try await fixture.waitFor("the row \"\(text)\"") { row(text, in: fixture) }
    }

    /// Toastty reads the coordinator's conversation while the chat is
    /// hidden too, a moment after the agent writes it. A test that shows
    /// the chat waits for that read first, as a user who comes back later
    /// does.
    @MainActor
    private func waitUntilToasttyRead(_ text: String, in fixture: CoordinatorChatFixture) async throws {
        let subscription = fixture.conversations.service.subscribeToConversation(inPanel: fixture.panelID)
        defer { subscription.cancel() }
        try await fixture.waitUntil("Toastty to read \"\(text)\"") {
            guard case .page(let page) = subscription.events(before: nil, limit: 50) else { return false }
            return page.events.contains { event in
                if case .assistantMessage(let payload) = event.payload { return payload.text == text }
                return false
            }
        }
    }

    @MainActor
    @Test func theLineMarksWhatArrivedWhileTheUserWasAwayAndStaysWhileTheUserReads() async throws {
        let suiteName = "toastty.tests.coordinator-new-messages.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = try CoordinatorChatFixture(chatDefaults: defaults)
        defer { fixture.tearDown() }

        // The first read shows no line: nothing was read before.
        fixture.chat.show(panelID: fixture.panelID)
        try fixture.startTurn(1, userText: "What is open?")
        try fixture.recordAgentMessage("Two tasks are open.")
        try fixture.endTurn(1)
        _ = try await waitForRow("Two tasks are open.", in: fixture)
        #expect(fixture.chat.newMessages == nil)

        // The coordinator answers a task while the chat is hidden. The line
        // goes above its turn's first row that is not the user's, and
        // counts its message.
        fixture.chat.hide()
        try fixture.startTurn(2, userText: "A message from the phone")
        try fixture.recordAgentMessage("The sidebar fix is ready for review.")
        try fixture.endTurn(2)
        try await waitUntilToasttyRead("The sidebar fix is ready for review.", in: fixture)
        fixture.chat.show(panelID: fixture.panelID)
        let away = try await waitForRow("The sidebar fix is ready for review.", in: fixture)
        #expect(fixture.chat.newMessages == ToasttyNewMessagesMarker(firstRowID: away, count: 1))

        // A message that arrives while the user reads is below the line,
        // and the line stays where it is.
        try fixture.startTurn(3, userText: "And the iOS build?")
        try fixture.recordAgentMessage("The iOS build passed.")
        try fixture.endTurn(3)
        _ = try await waitForRow("The iOS build passed.", in: fixture)
        #expect(fixture.chat.newMessages == ToasttyNewMessagesMarker(firstRowID: away, count: 2))

        // Back with nothing new: everything was read, and the line is gone.
        fixture.chat.hide()
        fixture.chat.show(panelID: fixture.panelID)
        try await fixture.waitUntil("the line to go") { fixture.chat.newMessages == nil }

        // A chat on screen behind another app is not read: what arrives
        // then is new, and the line stays when the user comes back.
        fixture.clock.appIsActive = false
        fixture.chat.appActivityChanged()
        try fixture.startTurn(4, userText: "Anything else?")
        try fixture.recordAgentMessage("A task needs your answer.")
        try fixture.endTurn(4)
        let behind = try await waitForRow("A task needs your answer.", in: fixture)
        try await fixture.waitUntil("the line above the message from while Toastty was in the background") {
            fixture.chat.newMessages == ToasttyNewMessagesMarker(firstRowID: behind, count: 1)
        }
        fixture.clock.appIsActive = true
        fixture.chat.appActivityChanged()
        #expect(fixture.chat.newMessages == ToasttyNewMessagesMarker(firstRowID: behind, count: 1))

        // The user's own message answers: the line goes.
        try await fixture.waitUntil("the open prompt") {
            fixture.chat.summary?.inputAvailability.allowsRemoteSend == true
        }
        fixture.chat.draft = "Thanks"
        fixture.chat.send()
        #expect(fixture.chat.newMessages == nil)
        try fixture.startTurn(5, userText: "Thanks")
        try fixture.endTurn(5)

        // What the user read survives a relaunch.
        fixture.chat.hide()
        try fixture.startTurn(6, userText: "Status?")
        try fixture.recordAgentMessage("All tasks are done.")
        try fixture.endTurn(6)
        try await waitUntilToasttyRead("All tasks are done.", in: fixture)
        fixture.relaunch()
        fixture.chat.show(panelID: fixture.panelID)
        let afterRelaunch = try await waitForRow("All tasks are done.", in: fixture)
        try await fixture.waitUntil("the line after the relaunch") {
            fixture.chat.newMessages == ToasttyNewMessagesMarker(firstRowID: afterRelaunch, count: 1)
        }
    }

    /// After a relaunch the chat reads only the newest page. The line still
    /// goes where the user stopped, also when more than a page came since.
    @MainActor
    @Test func afterARelaunchTheLineGoesWhereTheUserStoppedAlsoPagesBack() async throws {
        let suiteName = "toastty.tests.coordinator-new-messages.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = try CoordinatorChatFixture(chatDefaults: defaults)
        defer { fixture.tearDown() }

        fixture.chat.show(panelID: fixture.panelID)
        try fixture.startTurn(1, userText: "What is open?")
        try fixture.recordAgentMessage("Two tasks are open.")
        try fixture.endTurn(1)
        _ = try await waitForRow("Two tasks are open.", in: fixture)
        fixture.chat.hide()

        let unreadCount = CoordinatorChatModel.pageSize + 30
        try fixture.startTurn(2, userText: "Report each check")
        for index in 1 ... unreadCount {
            try fixture.recordAgentMessage("Check \(index) passed.")
        }
        try fixture.endTurn(2)
        try await waitUntilToasttyRead("Check \(unreadCount) passed.", in: fixture)
        fixture.relaunch()
        fixture.chat.show(panelID: fixture.panelID)
        _ = try await waitForRow("Check \(unreadCount) passed.", in: fixture)
        let first = try #require(row("Check 1 passed.", in: fixture), "The chat did not read back to where the user stopped")
        #expect(fixture.chat.newMessages == ToasttyNewMessagesMarker(firstRowID: first, count: unreadCount))
    }

    // MARK: - Which rows are new

    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let runID = UUID()

    private static func row(_ sequence: UInt64, _ content: ToasttyTranscriptRow.Content) -> ToasttyTranscriptRow {
        ToasttyTranscriptRow(
            id: rowID(sequence),
            timestamp: start.addingTimeInterval(TimeInterval(sequence)),
            provider: .claude,
            content: content
        )
    }

    private static func rowID(_ sequence: UInt64) -> ToasttyTranscriptRowID {
        ToasttyTranscriptRowID(projectionRunID: runID, projectionGeneration: 1, conversationID: runID, sequence: sequence)
    }

    private static func digest(foldsTurn: Bool) -> ToasttyTranscriptRow.Content {
        .hostMessage(ToasttyHostMessagePresentation(summary: "2 task updates", text: "digest", foldsTurn: foldsTurn))
    }

    @Test func aQuietWakeTurnAndTheUsersOwnMessagesAreNotNew() {
        let rows = [
            Self.row(1, .assistantMessage(text: "Read before", phase: .final)),
            // A wake turn that the coordinator marked quiet.
            Self.row(2, Self.digest(foldsTurn: true)),
            Self.row(3, .assistantMessage(text: "Nothing for you", phase: .final)),
            // The user's message from the phone, then the coordinator's
            // work and answer.
            Self.row(4, .userMessage(text: "Status?", origin: .remote)),
            Self.row(5, .toolStarted(callID: "1", name: "Bash", detail: nil)),
            Self.row(6, .assistantMessage(text: "Checking", phase: .commentary)),
            Self.row(7, .assistantMessage(text: "All green", phase: .final)),
            // A wake turn that has something for the user.
            Self.row(8, Self.digest(foldsTurn: false)),
            Self.row(9, .assistantMessage(text: "A task needs you", phase: .final)),
        ]
        let readThrough = Self.start.addingTimeInterval(1)

        #expect(CoordinatorChatReadPoint.marker(in: rows, after: readThrough)
            == ToasttyNewMessagesMarker(firstRowID: Self.rowID(5), count: 2))
        // Nothing read yet: no line.
        #expect(CoordinatorChatReadPoint.marker(in: rows, after: nil) == nil)
        // Only the quiet turn and the user's message are new: no line.
        #expect(CoordinatorChatReadPoint.marker(in: Array(rows.prefix(4)), after: readThrough) == nil)
        // Work without a message yet: no line.
        #expect(CoordinatorChatReadPoint.marker(in: Array(rows.prefix(6)), after: readThrough) == nil)
    }
}
