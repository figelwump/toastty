@testable import ConversationUI
import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

/// The coordinator's chat on the phone shows the messages that Toastty typed
/// as the Mac's coordinator chat does. Every other chat shows them as typed.
final class ToasttyCoordinatorChatPresentationTests: XCTestCase {
    private let conversationID = RemoteConversationID(rawValue: UUID(uuidString: "B1000000-0000-0000-0000-000000000090")!)
    private let taskID = UUID(uuidString: "D1000000-0000-0000-0000-000000000001")!
    private let start = Date(timeIntervalSince1970: 1_786_406_400)

    func testADigestThatToasttyTypedFoldsToOneLine() throws {
        let digest = """
        \(CoordinatorMessageHeader.digestPrefix): this message is from Toastty, not from the user.
        - [Fix the unread dot](toastty://task/\(taskID.uuidString)): needsYou (review) at 2026-08-11T14:04:10Z
        - [Port the sync engine](toastty://task/\(UUID().uuidString)): running at 2026-08-11T14:04:40Z
        Read `toastty task list` for details.
        """
        let rows = coordinatorRows([.userMessage(.init(text: digest, origin: .remote))])

        guard case .hostMessage(let message) = try XCTUnwrap(rows.first).content else {
            return XCTFail("A digest is one folded line, not the user's message: \(rows)")
        }
        XCTAssertEqual(message.summary, "Toastty · 2 updates · \(time(1))")
        XCTAssertEqual(message.style, .disclosure)
        // The line opens to the whole digest. The phone does not know which
        // turns are quiet, so it folds no turn.
        XCTAssertEqual(message.text, digest)
        XCTAssertFalse(message.foldsTurn)
    }

    func testAMessageThatCoordinatorSendBroughtShowsItsSenderAndBodyInACard() throws {
        let text = CoordinatorMessageHeader.message(
            from: .task(id: taskID, title: "Port the sync engine"),
            text: "Done the first pass.\nShould the old API stay for one release?"
        )
        let rows = coordinatorRows([.userMessage(.init(text: text, origin: .remote))])

        guard case .hostMessage(let message) = try XCTUnwrap(rows.first).content else {
            return XCTFail("Expected a sender card: \(rows)")
        }
        XCTAssertEqual(message.style, .sender(name: "task Port the sync engine", timeText: time(1)))
        XCTAssertEqual(message.text, "Done the first pass.\nShould the old API stay for one release?")
        XCTAssertFalse(message.text.contains("[Toastty]"))
    }

    func testAQuickEntryMessageShowsTheTextTheChoicesAndTheNamesOfItsFiles() throws {
        let text = CoordinatorMessageHeader.quickEntryMessage(
            CoordinatorMessageHeader.QuickEntry(
                project: .init(id: UUID(), title: "toastty"),
                agent: "codex", model: "gpt-6.1-sol", effort: "high",
                selectedProject: nil
            ),
            text: "Add a CSV export to the Tasks tab.",
            attachmentPaths: ["/Users/me/.toastty/coordinator/attachments/A1/csv-mockup.png", "/tmp/notes.md"]
        )
        let rows = coordinatorRows([.userMessage(.init(text: text, origin: .remote))])

        guard case .userMessage(let shown, let origin, _, let quote, let attachments) = try XCTUnwrap(rows.first).content else {
            return XCTFail("Expected the user's message: \(rows)")
        }
        XCTAssertEqual(shown, """
        Add a CSV export to the Tasks tab.

        project "toastty" · codex, model gpt-6.1-sol, effort high · csv-mockup.png, notes.md
        """)
        // The files stay on the Mac: the phone names them and shows no path.
        XCTAssertEqual(attachments, [])
        XCTAssertFalse(shown.contains("/Users/me"))
        XCTAssertNil(quote)
        XCTAssertEqual(origin, .remote)

        // A Mac that serves the images: each file shows by itself, in the
        // message's order, as on the Mac, and the text does not name them.
        // The bubble asks the Mac for an image by the message's event and
        // the file's place in this list.
        let apart = coordinatorRows([.userMessage(.init(text: text, origin: .remote))], showsAttachedImages: true)
        guard case .userMessage(let apartText, _, _, _, let files) = try XCTUnwrap(apart.first).content else {
            return XCTFail("Expected the user's message: \(apart)")
        }
        XCTAssertEqual(apartText, """
        Add a CSV export to the Tasks tab.

        project "toastty" · codex, model gpt-6.1-sol, effort high
        """)
        XCTAssertEqual(files.map(\.path), ["/Users/me/.toastty/coordinator/attachments/A1/csv-mockup.png", "/tmp/notes.md"])
        XCTAssertEqual(apart.first?.eventID, "coordinator-1")
    }

    /// A message sent from a phone with a photo: the Mac's copy names the
    /// photo in its text and keeps the stored path apart. With a Mac that
    /// serves images the bubble shows the photo by itself and the typed
    /// text alone; otherwise it shows the name line, as before.
    func testAMessageSentWithAPhotoShowsThePhotoApartFromItsText() throws {
        let stored = "/Users/me/Library/Application Support/Toastty/remote-access/attachments/A1/9B1E4C2A.jpg"
        let payload = ConversationUserMessagePayload(
            text: "Is this the crash?\n[Attachment: Photo-3213AEE3.jpg]", origin: .remote,
            clientRequestID: "phone-1", attachmentPaths: [stored]
        )
        let apart = coordinatorRows([.userMessage(payload)], showsAttachedImages: true)
        guard case .userMessage(let text, _, _, _, let files) = try XCTUnwrap(apart.first).content else {
            return XCTFail("Expected the user's message: \(apart)")
        }
        XCTAssertEqual(text, "Is this the crash?")
        XCTAssertEqual(files.map(\.path), [stored])

        let byName = coordinatorRows([.userMessage(payload)])
        guard case .userMessage(let named, _, _, _, let none) = try XCTUnwrap(byName.first).content else {
            return XCTFail("Expected the user's message: \(byName)")
        }
        XCTAssertEqual(named, "Is this the crash?\n[Attachment: Photo-3213AEE3.jpg]")
        XCTAssertEqual(none, [])
    }

    func testAReplyShowsTheLineThatNamesTheMessageItAnswers() throws {
        let answer = "I asked it to keep the old API until the next release."
        let reply = CoordinatorMessageHeader.replyMessage(
            quote: answer, time: time(2), text: "Good. Release once it merges.", attachmentPaths: ["/tmp/plan.md"]
        )
        let rows = coordinatorRows([
            .assistantMessage(.init(text: "An older message.", phase: .final)),
            .assistantMessage(.init(text: answer, phase: .final)),
            .userMessage(.init(text: reply, origin: .remote, deliveryMode: .steer)),
        ])

        guard case .userMessage(let shown, _, let deliveryMode, let quote, _) = rows[2].content else {
            return XCTFail("Expected the user's reply: \(rows)")
        }
        XCTAssertEqual(shown, "Good. Release once it merges.\n\nplan.md")
        XCTAssertEqual(deliveryMode, .steer)
        let line = try XCTUnwrap(quote)
        XCTAssertEqual(line.text, answer)
        // The line writes the time on one line, with plain spaces.
        XCTAssertEqual(line.timeText, CoordinatorMessageHeader.replyTime(time(2)))
        // A tap on the line scrolls to the message it answers.
        XCTAssertEqual(line.sourceRowID, rows[1].id)
    }

    /// The reply's line carries the Mac's time, in the Mac's format, such as
    /// "14:07" on a phone that writes "2:07 PM". A quoted text that only one
    /// message has still finds that message; with two, the line opens
    /// neither.
    func testAReplyFindsItsMessageWhenTheMacWritesTimesDifferently() throws {
        let answer = "Yes, merge it after the checks pass."
        let reply = CoordinatorMessageHeader.replyMessage(quote: answer, time: "14:07 Mac", text: "Thanks.")
        let rows = coordinatorRows([
            .assistantMessage(.init(text: answer, phase: .final)),
            .userMessage(.init(text: reply, origin: .remote)),
        ])
        guard case .userMessage(_, _, _, let quote?, _) = rows[1].content else {
            return XCTFail("Expected the reply's line: \(rows)")
        }
        XCTAssertEqual(quote.timeText, "14:07 Mac")
        XCTAssertEqual(quote.sourceRowID, rows[0].id)

        let twice = coordinatorRows([
            .assistantMessage(.init(text: answer, phase: .final)),
            .assistantMessage(.init(text: answer, phase: .final)),
            .userMessage(.init(text: reply, origin: .remote)),
        ])
        guard case .userMessage(_, _, _, let ambiguous?, _) = twice[2].content else {
            return XCTFail("Expected the reply's line: \(twice)")
        }
        XCTAssertEqual(ambiguous.text, answer)
        XCTAssertNil(ambiguous.sourceRowID)
    }

    func testOtherChatsShowToasttysTextAsItWasTyped() throws {
        let text = CoordinatorMessageHeader.message(from: .unknown, text: "From a script.")
        let state = ToasttyConversationPresentationAdapter.makeState(
            events: [event(1, .userMessage(.init(text: text, origin: .remote)))],
            projectionRunID: nil,
            projectionGeneration: nil,
            phase: .live,
            revision: .initial,
            historyTruncated: false
        )
        XCTAssertEqual(state.rows.map(\.content), [.userMessage(text: text, origin: .remote, deliveryMode: nil)])
    }

    func testAPlainMessageInTheCoordinatorsChatIsUnchanged() {
        let rows = coordinatorRows([.userMessage(.init(text: "What needs me?", origin: .remote))])
        XCTAssertEqual(rows.map(\.content), [.userMessage(text: "What needs me?", origin: .remote, deliveryMode: nil)])
    }

    // MARK: - Task chips

    /// A link to a task that the board lists is a chip with its current
    /// title and pull request; a tap opens it. A task the board does not
    /// list, and a task space with no task record, stay text.
    func testATaskLinkIsAChipOnlyForATaskTheBoardLists() throws {
        let listed = RemoteTaskSummary(
            id: taskID, title: "compact-session-rows", group: .needsYou,
            statusLine: "Waiting", stageTitle: "Needs you", stageReason: "asked",
            projectWorkspaceID: UUID(), taskSpaceWorkspaceID: UUID(),
            pullRequest: RemoteTaskPullRequest(number: 36, url: URL(string: "https://example.com/pull/36")!, state: .open),
            activityAt: start
        )
        let watchedSpaceID = UUID()
        let watchedSpace = RemoteTaskSummary(
            id: watchedSpaceID, hasRecord: false, title: "ios-subspaces", group: .running,
            statusLine: "Working", stageTitle: "Running", stageReason: "working",
            projectWorkspaceID: UUID(), taskSpaceWorkspaceID: watchedSpaceID, activityAt: start
        )
        let chips = ToasttyTaskLinkChips(board: MobileTaskBoard(RemoteTaskBoard(tasks: [listed, watchedSpace])))

        let chip = try XCTUnwrap(chips.chips[taskID])
        XCTAssertEqual(chip.title, ConversationLinkChip.taskTitle("compact-session-rows"))
        XCTAssertEqual(chip.detail, "#36")
        XCTAssertEqual(chips.taskID(for: CoordinatorTaskLink.url(taskID: taskID)), taskID)

        let unlisted = UUID()
        XCTAssertNil(chips.chips[unlisted])
        XCTAssertNil(chips.taskID(for: CoordinatorTaskLink.url(taskID: unlisted)))
        XCTAssertNil(chips.taskID(for: CoordinatorTaskLink.url(taskID: watchedSpaceID)))
        XCTAssertNil(chips.taskID(for: URL(string: "toastty://action/open-settings")!))
        // Without a board there is no chip at all.
        XCTAssertTrue(ToasttyTaskLinkChips(board: nil).chips.isEmpty)
    }

    /// A link to one of the Mac's Done or archived tasks is a chip in the
    /// stage's color, with the task's title and pull request, and opens the
    /// task's detail: no task space and no action. A task the board also
    /// lists, while its task space is open, keeps the board's chip.
    func testAFinishedTaskLinkIsAChipThatOpensItsDetail() throws {
        let doneID = UUID(), archivedID = UUID()
        let mergedPullRequest = RemoteTaskPullRequest(
            number: 301, url: URL(string: "https://example.com/pull/301")!, state: .merged
        )
        let finished = ToasttyFinishedTasks(RemoteFinishedTasks(revision: "finished-1", tasks: [
            RemoteFinishedTask(
                id: doneID, title: "Signup feedback", group: .done, stageTitle: "Done", stageReason: "merged",
                statusLine: "Done", projectTitle: "toastty", pullRequest: mergedPullRequest
            ),
            RemoteFinishedTask(
                id: archivedID, title: "Export spike", group: .archived, stageTitle: "Archived",
                stageReason: "closed without finishing", statusLine: "Archived"
            ),
            RemoteFinishedTask(
                id: taskID, title: "compact-session-rows (old title)", group: .done, stageTitle: "Done",
                stageReason: "marked done", statusLine: "Done"
            ),
        ]))
        let listed = RemoteTaskSummary(
            id: taskID, title: "compact-session-rows", group: .done, mark: .done,
            statusLine: "Done", stageTitle: "Done", stageReason: "marked done",
            projectWorkspaceID: UUID(), taskSpaceWorkspaceID: UUID(), activityAt: start
        )
        let chips = ToasttyTaskLinkChips(board: MobileTaskBoard(RemoteTaskBoard(tasks: [listed])), finished: finished)

        let done = try XCTUnwrap(chips.chips[doneID])
        XCTAssertEqual(done.title, ConversationLinkChip.taskTitle("Signup feedback"))
        XCTAssertEqual(done.detail, "#301")
        XCTAssertEqual(done.markColor, ToasttyTaskLinkChips.chipColor(ToasttyDesignTokens.green))
        // The Mac marks an archived task quiet, not done.
        let archived = try XCTUnwrap(chips.chips[archivedID])
        XCTAssertNil(archived.detail)
        XCTAssertEqual(archived.markColor, ToasttyTaskLinkChips.chipColor(ToasttyDesignTokens.mutedText))
        XCTAssertEqual(chips.taskID(for: CoordinatorTaskLink.url(taskID: archivedID)), archivedID)
        // The board's task keeps its own chip.
        XCTAssertEqual(chips.chips[taskID]?.title, ConversationLinkChip.taskTitle("compact-session-rows"))

        // The detail shows the task's stage, why and pull request, with no
        // task space to open and no action.
        let detail = try XCTUnwrap(finished.summary(id: doneID))
        XCTAssertEqual(detail.title, "Signup feedback")
        XCTAssertEqual(detail.group, .done)
        XCTAssertEqual(detail.stageTitle, "Done")
        XCTAssertEqual(detail.stageReason, "merged")
        XCTAssertEqual(detail.projectTitle, "toastty")
        XCTAssertEqual(detail.pullRequest, mergedPullRequest)
        XCTAssertNil(detail.taskSpaceWorkspaceID)
        XCTAssertTrue(detail.actions.isEmpty)
        XCTAssertNil(detail.mergeControl)
        XCTAssertEqual(finished.summary(id: archivedID)?.group, .archived)
        XCTAssertNil(finished.summary(id: UUID()))
        // Without the Mac's answer there is no such chip.
        XCTAssertNil(ToasttyTaskLinkChips(board: nil, finished: ToasttyFinishedTasks()).chips[doneID])
    }

    // MARK: - Helpers

    private func coordinatorRows(
        _ payloads: [ConversationEventPayload],
        showsAttachedImages: Bool = false
    ) -> [ToasttyTranscriptRow] {
        ToasttyConversationPresentationAdapter.makeState(
            events: payloads.enumerated().map { event(UInt64($0.offset + 1), $0.element) },
            projectionRunID: RemoteProjectionRunID(rawValue: UUID()),
            projectionGeneration: 1,
            phase: .live,
            revision: .initial,
            historyTruncated: false,
            coordinatorMessages: ToasttyConversationPresentationAdapter.coordinatorMessages(
                showsAttachedImages: showsAttachedImages
            )
        ).rows
    }

    private func event(_ sequence: UInt64, _ payload: ConversationEventPayload) -> CompatibleConversationEvent {
        .known(ConversationEvent(
            conversationID: conversationID,
            sequence: sequence,
            eventID: "coordinator-\(sequence)",
            timestamp: date(sequence),
            provider: .claude,
            payload: payload
        ))
    }

    private func date(_ sequence: UInt64) -> Date {
        start.addingTimeInterval(TimeInterval(sequence) * 60)
    }

    /// The time of event `sequence` as the phone's coordinator chat writes it.
    private func time(_ sequence: UInt64) -> String {
        ToasttyConversationPresentationAdapter.coordinatorMessages().timeText(date(sequence))
    }
}
