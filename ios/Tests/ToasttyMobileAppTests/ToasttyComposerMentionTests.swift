import ConversationUI
import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain
import UIKit
import XCTest
@testable import ToasttyMobileApp

/// @ mentions in the coordinator chat's message field, through the real text
/// view in a window: `@` opens the list, a task goes in as one highlighted
/// word, the draft holds the task's link, and the word deletes, selects and
/// restores whole.
///
/// Failure modes covered: an email address opening the list; ordinary words
/// after `@` keeping it open; a chosen task leaving the search behind or a
/// double space; Delete taking one letter of a mention; the caret stopping
/// inside a mention; text typed next to a mention becoming part of it; an edit
/// inside a mention keeping a link that no longer matches the word; a saved
/// draft coming back as raw links, or counting as an edit; a link to a task
/// the phone does not know turning into a mention; Copy giving the word
/// without its link; Paste of a link staying raw; a task's session field
/// changing behavior.
@MainActor
final class ToasttyComposerMentionTests: XCTestCase {
    private static let loginID = UUID(uuidString: "A1B2C3D4-0000-4000-8000-000000000441")!
    private static let previewID = UUID(uuidString: "A1B2C3D4-0000-4000-8000-000000000438")!
    private static let unknownID = UUID(uuidString: "A1B2C3D4-0000-4000-8000-0000000000FF")!
    private static let loginLink = "[Fix login crash on launch](toastty://task/\(loginID.uuidString))"
    private static let previewLink = "[Fix local file preview](toastty://task/\(previewID.uuidString))"

    private static let candidates: [CoordinatorMentionCandidate] = [
        CoordinatorMentionCandidate(
            taskID: loginID, title: "Fix login crash on launch", projectTitle: "toastty", pullRequestNumber: 441,
            group: .needsYou, markColor: ConversationChipColor(red: 0.9, green: 0.4, blue: 0.3), doneAt: nil
        ),
        CoordinatorMentionCandidate(
            taskID: previewID, title: "Fix local file preview", projectTitle: "toastty", pullRequestNumber: 438,
            group: .working, markColor: ConversationChipColor(red: 0.3, green: 0.5, blue: 0.9), doneAt: nil
        ),
    ]

    // MARK: - The list

    func testAtSignOpensTheListAndTheSearchFiltersIt() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { close(window) }
        type("Can you check ", into: textView)
        XCTAssertFalse(model.picker.isOpen)
        type("@", into: textView)
        XCTAssertTrue(model.picker.isOpen)
        XCTAssertEqual(model.picker.sections.map(\.group), [.needsYou, .working])
        type("lo", into: textView)
        XCTAssertEqual(model.picker.session?.query, "lo")
        type("gin", into: textView)
        XCTAssertEqual(model.picker.sections.flatMap(\.candidates).map(\.taskID), [Self.loginID])
        // A space after a search that matches nothing closes the list.
        type("zzz", into: textView)
        XCTAssertTrue(model.picker.isOpen, "One word that matches nothing says so")
        type(" ", into: textView)
        XCTAssertFalse(model.picker.isOpen)
    }

    func testTheListClosesWhenTheAtSignGoesOrTheCaretLeaves() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { close(window) }
        type("ask @fix", into: textView)
        XCTAssertTrue(model.picker.isOpen)
        textView.selectedRange = NSRange(location: 2, length: 0)
        XCTAssertFalse(model.picker.isOpen, "The caret left the search")
        textView.selectedRange = NSRange(location: textView.textStorage.length, length: 0)
        XCTAssertTrue(model.picker.isOpen, "The caret came back after the search")
        for _ in 0..<4 { textView.deleteBackward() }
        XCTAssertEqual(textView.text, "ask ")
        XCTAssertFalse(model.picker.isOpen, "The @ is gone")
        // A tap outside closes it for that @ only.
        type("@fi", into: textView)
        XCTAssertTrue(model.picker.isOpen)
        model.picker.dismiss()
        type("x", into: textView)
        XCTAssertFalse(model.picker.isOpen)
        type(" @", into: textView)
        XCTAssertTrue(model.picker.isOpen, "A new @ opens it again")
        // The field losing the keyboard closes it.
        textView.resignFirstResponder()
        await settle()
        XCTAssertFalse(model.picker.isOpen)
    }

    /// Tasks that arrive while the list is open, such as the Mac's finished
    /// tasks after its first answer, show without another key.
    func testTheOpenListShowsTasksThatArrive() async throws {
        let (window, model, textView) = try await makeComposer(candidates: [Self.candidates[0]])
        defer { close(window) }
        type("@prev", into: textView)
        XCTAssertTrue(model.picker.isOpen)
        XCTAssertTrue(model.picker.sections.isEmpty)
        model.candidates = Self.candidates
        try await waitUntil { model.picker.sections.flatMap(\.candidates).map(\.taskID) == [Self.previewID] }
        XCTAssertEqual(model.picker.session?.query, "prev")
    }

    func testAnEmailAddressOpensNoList() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { close(window) }
        type("mail me at me@example.com", into: textView)
        XCTAssertFalse(model.picker.isOpen)
    }

    // MARK: - Done and archived tasks

    /// The Mac's finished tasks join the list with the Mac's rules, through
    /// the fixture Mac's board and finished tasks: before a search, the
    /// Done task that finished two days ago, but not the archived one or the
    /// Done one from a month ago; a search finds those.
    ///
    /// Failure modes covered: finished tasks missing from the list, or
    /// archived and older Done ones showing before a search; a search not
    /// finding them; a task on the board and in the finished list showing
    /// twice, or as the finished list has it; an older Mac's finished tasks,
    /// without `doneAt`, showing before a search; a choice not giving the
    /// task's link.
    func testFinishedTasksJoinTheListWithTheMacsRules() throws {
        let board = try XCTUnwrap(ToasttyMobileFixture.taskHome.taskBoard)
        let finished = ToasttyFinishedTasks(ToasttyMobileFixture.finishedTasks)
        let candidates = CoordinatorMentionCandidate.candidates(from: board, finished: finished)
        let now = Date()
        func titles(_ query: String, in candidates: [CoordinatorMentionCandidate]) -> [CoordinatorMentionCandidate.Group: [String]] {
            Dictionary(uniqueKeysWithValues: CoordinatorMentionSearch.sections(query: query, candidates: candidates, now: now)
                .map { ($0.group, $0.candidates.map(\.title)) })
        }

        // The board's Done tasks come first, then the finished one.
        let boardOnly = CoordinatorMentionCandidate.candidates(from: board)
        let boardDone = titles("", in: boardOnly)[.done] ?? []
        XCTAssertFalse(boardDone.isEmpty, "The fixture board lists Done tasks whose task space is open")
        let before = titles("", in: candidates)
        XCTAssertEqual(before[.done], boardDone + ["signup-feedback-form"])
        XCTAssertNil(before[.archived])
        // The board's tasks are as before.
        for group in [CoordinatorMentionCandidate.Group.needsYou, .working, .idle, .toShip] {
            XCTAssertEqual(before[group], titles("", in: boardOnly)[group], group.title)
        }
        XCTAssertEqual(titles("csv", in: candidates)[.archived], ["csv-export-spike"])
        XCTAssertEqual(titles("onboarding", in: candidates)[.done], ["onboarding-copy-pass"])
        XCTAssertEqual(titles("#158", in: candidates)[.done], ["onboarding-copy-pass"])
        let archived = try XCTUnwrap(candidates.first { $0.taskID == ToasttyMobileFixture.finishedArchivedTaskID })
        XCTAssertEqual(archived.group, .archived)
        XCTAssertEqual(archived.projectTitle, "toastty")
        XCTAssertEqual(archived.markColor, finished.chips[archived.taskID]?.markColor)
        XCTAssertEqual(
            ToasttyMentionToken(candidate: archived).markdown,
            "[csv-export-spike](toastty://task/\(ToasttyMobileFixture.finishedArchivedTaskID.uuidString))"
        )

        // A Done task whose task space is open is on the board and in the
        // finished list: once, as the board lists it, finished when the Mac
        // says, although its latest change is older than 14 days.
        let open = RemoteTaskSummary(
            id: ToasttyMobileFixture.finishedDoneTaskID, title: "signup-feedback-form (open)", group: .done,
            mark: .done, statusLine: "Done", stageTitle: "Done", stageReason: "marked done",
            projectTitle: "toastty", taskSpaceWorkspaceID: UUID(), activityAt: now.addingTimeInterval(-40 * 86_400)
        )
        let withOpen = CoordinatorMentionCandidate.candidates(
            from: MobileTaskBoard(RemoteTaskBoard(tasks: board.tasks + [open])), finished: finished
        )
        XCTAssertEqual(withOpen.filter { $0.taskID == open.id }.map(\.title), ["signup-feedback-form (open)"])
        XCTAssertEqual(titles("", in: withOpen)[.done], boardDone + ["signup-feedback-form (open)"])
        XCTAssertEqual(withOpen.count, candidates.count)

        // An older Mac sends no done times: its finished tasks show only for
        // a search. One that shares none gives the board's list.
        var undatedAnswer = ToasttyMobileFixture.finishedTasks
        for index in undatedAnswer.tasks.indices { undatedAnswer.tasks[index].doneAt = nil }
        let undated = CoordinatorMentionCandidate.candidates(from: board, finished: ToasttyFinishedTasks(undatedAnswer))
        XCTAssertEqual(titles("", in: undated), titles("", in: boardOnly))
        XCTAssertEqual(titles("signup", in: undated)[.done], ["signup-feedback-form"])
        XCTAssertEqual(titles("csv", in: undated)[.archived], ["csv-export-spike"])
        XCTAssertEqual(CoordinatorMentionCandidate.candidates(from: board, finished: ToasttyFinishedTasks()), boardOnly)
    }

    // MARK: - A mention in the field

    func testATaskGoesInAsOneWordAndTheDraftHoldsItsLink() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { close(window) }
        type("Can you check @fix lo", into: textView)
        model.picker.choose(Self.candidates[0])
        await settle()
        XCTAssertFalse(model.picker.isOpen)
        XCTAssertEqual(textView.text, "Can you check @Fix login crash on launch ")
        XCTAssertEqual(textView.selectedRange, NSRange(location: textView.textStorage.length, length: 0))
        XCTAssertEqual(model.text, "Can you check \(Self.loginLink) ")
        XCTAssertEqual(mentionWords(in: textView), ["@Fix login crash on launch"])
        XCTAssertEqual(textView.accessibilityValue, "Can you check mention, Fix login crash on launch ")
        // The rest of the sentence is plain text.
        type("before the release?", into: textView)
        await settle()
        XCTAssertEqual(model.text, "Can you check \(Self.loginLink) before the release?")
        XCTAssertEqual(mentionWords(in: textView), ["@Fix login crash on launch"])
    }

    func testAMentionBeforeASpaceAddsNoSecondSpace() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { close(window) }
        type("ask @fix about it", into: textView)
        textView.selectedRange = NSRange(location: 8, length: 0)
        XCTAssertEqual(model.picker.session?.query, "fix")
        model.picker.choose(Self.candidates[1])
        await settle()
        XCTAssertEqual(textView.text, "ask @Fix local file preview about it")
        XCTAssertEqual(model.text, "ask \(Self.previewLink) about it")
        XCTAssertEqual(textView.selectedRange.location, ("ask @Fix local file preview " as NSString).length)
    }

    func testOneDeleteRemovesTheWholeMention() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { close(window) }
        type("check @lo", into: textView)
        model.picker.choose(Self.candidates[0])
        textView.deleteBackward()
        XCTAssertEqual(textView.text, "check @Fix login crash on launch", "The first Delete takes the space")
        textView.deleteBackward()
        await settle()
        XCTAssertEqual(textView.text, "check ")
        XCTAssertEqual(model.text, "check ")
        XCTAssertTrue(mentionWords(in: textView).isEmpty)
    }

    func testTheCaretDoesNotStopInsideAMention() async throws {
        let (window, _, textView) = try await makeComposer()
        defer { close(window) }
        type("check @lo", into: textView)
        let start = ("check " as NSString).length
        let end = start + ("@Fix login crash on launch" as NSString).length
        textView.insertMention(Self.candidates[0])
        XCTAssertEqual(textView.mentionRange(at: start), NSRange(location: start, length: end - start))
        // A step right from the mention's start goes to its end; a step left
        // from its end goes to its start.
        textView.selectedRange = NSRange(location: start, length: 0)
        textView.selectedRange = NSRange(location: start + 1, length: 0)
        XCTAssertEqual(textView.selectedRange, NSRange(location: end, length: 0))
        textView.selectedRange = NSRange(location: end - 1, length: 0)
        XCTAssertEqual(textView.selectedRange, NSRange(location: start, length: 0))
        // A tap inside goes to the nearer side, also from one of its edges.
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.selectedRange = NSRange(location: end - 3, length: 0)
        XCTAssertEqual(textView.selectedRange, NSRange(location: end, length: 0))
        textView.selectedRange = NSRange(location: start, length: 0)
        textView.selectedRange = NSRange(location: start + 3, length: 0)
        XCTAssertEqual(textView.selectedRange, NSRange(location: start, length: 0))
        textView.selectedRange = NSRange(location: end, length: 0)
        textView.selectedRange = NSRange(location: end - 4, length: 0)
        XCTAssertEqual(textView.selectedRange, NSRange(location: end, length: 0))
        // A selection that starts inside takes the mention whole.
        textView.selectedRange = NSRange(location: start + 4, length: end + 1 - start - 4)
        XCTAssertEqual(textView.selectedRange, NSRange(location: start, length: end + 1 - start))
    }

    func testTextTypedAgainstAMentionIsPlainText() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { close(window) }
        type("@lo", into: textView)
        model.picker.choose(Self.candidates[0])
        textView.deleteBackward()
        type("s", into: textView)
        await settle()
        XCTAssertEqual(model.text, "\(Self.loginLink)s")
        XCTAssertEqual(mentionWords(in: textView), ["@Fix login crash on launch"])
        // Before a mention at the very start of the text.
        textView.selectedRange = NSRange(location: 0, length: 0)
        type("Is ", into: textView)
        await settle()
        XCTAssertEqual(model.text, "Is \(Self.loginLink)s")
        XCTAssertEqual(mentionWords(in: textView), ["@Fix login crash on launch"])
    }

    /// An edit that changes a mention's word, such as autocorrect across it,
    /// leaves plain text: the draft never holds a link the field does not
    /// show.
    func testAnEditInsideAMentionMakesItPlainText() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { close(window) }
        type("@lo", into: textView)
        model.picker.choose(Self.candidates[0])
        let crash = ("@Fix login " as NSString).length
        let range = try XCTUnwrap(textView.textRange(
            from: XCTUnwrap(textView.position(from: textView.beginningOfDocument, offset: crash)),
            to: XCTUnwrap(textView.position(from: textView.beginningOfDocument, offset: crash + 5))
        ))
        textView.replace(range, withText: "bug")
        await settle()
        XCTAssertEqual(textView.text, "@Fix login bug on launch ")
        XCTAssertEqual(model.text, "@Fix login bug on launch ")
        XCTAssertTrue(mentionWords(in: textView).isEmpty)
    }

    func testTwoMentionsOfOneTaskStayTwo() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { close(window) }
        type("@lo", into: textView)
        model.picker.choose(Self.candidates[0])
        textView.deleteBackward()
        type("@", into: textView)
        XCTAssertTrue(model.picker.isOpen, "An @ right after a mention starts one")
        model.picker.choose(Self.candidates[0])
        await settle()
        XCTAssertEqual(mentionWords(in: textView), ["@Fix login crash on launch", "@Fix login crash on launch"])
        XCTAssertEqual(model.text, "\(Self.loginLink)\(Self.loginLink) ")
    }

    /// Undo and Redo of a mention's insertion and of its one-step delete
    /// leave the field and the draft in agreement: the draft holds a link
    /// only for a word the field shows as a mention.
    func testUndoAndRedoKeepTheFieldAndTheDraftInAgreement() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { close(window) }
        let undoManager = try XCTUnwrap(textView.undoManager)
        type("check @lo", into: textView)
        await settle()
        model.picker.choose(Self.candidates[0])
        await settle()
        XCTAssertEqual(model.text, "check \(Self.loginLink) ")

        undoManager.undo()
        await settle()
        XCTAssertEqual(textView.text, "check @lo")
        XCTAssertEqual(model.text, "check @lo")
        XCTAssertTrue(mentionWords(in: textView).isEmpty)

        undoManager.redo()
        await settle()
        XCTAssertEqual(textView.text, "check @Fix login crash on launch ")
        XCTAssertEqual(model.text, textView.draftText)
        print("Redo of a mention gives \(mentionWords(in: textView).isEmpty ? "plain text" : "the mention")")

        // Make sure the mention is there, then delete it in one step.
        textView.selectedRange = NSRange(location: 0, length: textView.textStorage.length)
        textView.replace(try XCTUnwrap(textView.selectedTextRange), withText: "check @lo")
        model.picker.choose(Self.candidates[0])
        await settle()
        textView.deleteBackward()
        textView.deleteBackward()
        await settle()
        XCTAssertEqual(model.text, "check ")
        undoManager.undo()
        await settle()
        XCTAssertTrue(textView.text.hasPrefix("check @Fix login crash on launch"), textView.text)
        XCTAssertEqual(model.text, textView.draftText)
        print("Undo of a deleted mention gives \(mentionWords(in: textView).isEmpty ? "plain text" : "the mention")")
    }

    // MARK: - Drafts

    func testASavedDraftComesBackWithItsMentions() async throws {
        let saved = "Ask \(Self.loginLink) and [old](toastty://task/\(Self.unknownID.uuidString)) now"
        let (window, model, textView) = try await makeComposer(text: saved)
        defer { close(window) }
        XCTAssertEqual(textView.text, "Ask @Fix login crash on launch and [old](toastty://task/\(Self.unknownID.uuidString)) now")
        XCTAssertEqual(mentionWords(in: textView), ["@Fix login crash on launch"])
        XCTAssertEqual(textView.draftText, saved)
        await settle()
        XCTAssertEqual(model.text, saved)
        XCTAssertEqual(model.editRevision, 0, "Showing the draft is no edit")
    }

    /// A link whose label is not the task's title keeps its text in the
    /// draft; the word shows the title now.
    func testAMentionKeepsTheLinkAsTyped() async throws {
        let typed = "[Old name](toastty://task/\(Self.loginID.uuidString))"
        let (window, model, textView) = try await makeComposer(text: typed)
        defer { close(window) }
        XCTAssertEqual(textView.text, "@Fix login crash on launch")
        XCTAssertEqual(textView.draftText, typed)
        type(" ok", into: textView)
        await settle()
        XCTAssertEqual(model.text, typed + " ok")
    }

    func testAReplacementShowsMentionsAndClearsTheList() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { close(window) }
        type("@fi", into: textView)
        XCTAssertTrue(model.picker.isOpen)
        model.replace(with: "Edit \(Self.previewLink) please")
        await settle()
        await settle()
        XCTAssertEqual(textView.text, "Edit @Fix local file preview please")
        XCTAssertEqual(mentionWords(in: textView), ["@Fix local file preview"])
        XCTAssertFalse(model.picker.isOpen)
        model.replace(with: "")
        await settle()
        await settle()
        XCTAssertEqual(textView.text, "")
        XCTAssertTrue(mentionWords(in: textView).isEmpty)
        type("plain", into: textView)
        await settle()
        XCTAssertEqual(model.text, "plain")
    }

    // MARK: - The paperclip, Copy and Paste

    func testMentionATaskTypesAnAtSignAndOpensTheList() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { close(window) }
        type("ask", into: textView)
        model.picker.beginMention()
        XCTAssertEqual(textView.text, "ask @")
        XCTAssertTrue(model.picker.isOpen)
        type(" ", into: textView)
        model.picker.beginMention()
        XCTAssertEqual(textView.text, "ask @ @", "No second space after a space")
        // Without the keyboard, it takes the keyboard first.
        textView.resignFirstResponder()
        await settle()
        model.picker.beginMention()
        XCTAssertTrue(textView.isFirstResponder)
        XCTAssertTrue(model.picker.isOpen)
    }

    func testCopyGivesTheLinkAndPastePutsInTheMention() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { close(window) }
        type("check @lo", into: textView)
        model.picker.choose(Self.candidates[0])
        textView.selectedRange = NSRange(location: 0, length: textView.textStorage.length)
        textView.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "check \(Self.loginLink) ")
        textView.selectedRange = NSRange(location: textView.textStorage.length, length: 0)
        UIPasteboard.general.string = "and \(Self.previewLink)"
        textView.paste(nil)
        await settle()
        XCTAssertEqual(textView.text, "check @Fix login crash on launch and @Fix local file preview")
        XCTAssertEqual(mentionWords(in: textView), ["@Fix login crash on launch", "@Fix local file preview"])
        XCTAssertEqual(model.text, "check \(Self.loginLink) and \(Self.previewLink)")
        // Plain text pastes as before. UIKit's own paste can finish after
        // several run-loop turns on a slow runner, so wait for the draft.
        UIPasteboard.general.string = " ok"
        textView.paste(nil)
        try await waitUntil { model.text.hasSuffix(" ok") }
        XCTAssertEqual(model.text, "check \(Self.loginLink) and \(Self.previewLink) ok")
    }

    // MARK: - A task's session

    func testATaskSessionFieldIsPlainText() async throws {
        let (window, model, textView) = try await makeComposer(text: Self.loginLink, mentions: false)
        defer { close(window) }
        XCTAssertEqual(textView.text, Self.loginLink)
        type(" @lo", into: textView)
        await settle()
        XCTAssertFalse(model.picker.isOpen)
        XCTAssertEqual(model.text, Self.loginLink + " @lo")
        XCTAssertTrue(mentionWords(in: textView).isEmpty)
    }

    // MARK: - Support

    private func type(_ text: String, into textView: ToasttyComposerUIKitTextView) {
        for character in text { textView.insertText(String(character)) }
    }

    private func mentionWords(in textView: ToasttyComposerUIKitTextView) -> [String] {
        ToasttyComposerMentionText.mentions(in: textView.textStorage).map { ($0.token.text) }
    }

    private func makeComposer(
        text: String = "",
        mentions: Bool = true,
        candidates: [CoordinatorMentionCandidate] = ToasttyComposerMentionTests.candidates
    ) async throws -> (UIWindow, MentionModel, ToasttyComposerUIKitTextView) {
        let model = MentionModel(text: text, candidates: candidates)
        let host = UIHostingController(rootView: MentionHarness(model: model, usesMentions: mentions))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 500)
        window.rootViewController = host
        window.makeKeyAndVisible()
        for _ in 0..<40 where findComposer(in: host.view) == nil {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await settle()
        }
        let textView = try XCTUnwrap(findComposer(in: host.view))
        textView.autocorrectionType = .no
        textView.inlinePredictionType = .no
        textView.smartQuotesType = .no
        XCTAssertTrue(textView.becomeFirstResponder())
        await settle()
        return (window, model, textView)
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func findComposer(in view: UIView) -> ToasttyComposerUIKitTextView? {
        if let textView = view as? ToasttyComposerUIKitTextView { return textView }
        return view.subviews.lazy.compactMap { self.findComposer(in: $0) }.first
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(30))
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met in time", file: file, line: line)
    }
}

@MainActor
private final class MentionModel: ObservableObject {
    @Published var text: String
    @Published var focused = false
    @Published var replacement: ToasttyComposerReplacement?
    var editRevision: UInt64 = 0
    let picker = ToasttyMentionPicker()
    @Published var candidates: [CoordinatorMentionCandidate]

    init(text: String, candidates: [CoordinatorMentionCandidate]) {
        self.text = text
        self.candidates = candidates
    }

    func replace(with text: String) {
        replacement = ToasttyComposerReplacement(
            revision: (replacement?.revision ?? 0) + 1, expectedEditRevision: editRevision, text: text
        )
        self.text = text
    }
}

private struct MentionHarness: View {
    @ObservedObject var model: MentionModel
    let usesMentions: Bool

    var body: some View {
        VStack {
            ToasttyComposerTextView(
                text: model.text,
                onTextChange: { text, revision in
                    model.text = text
                    model.editRevision = revision
                },
                editRevision: model.editRevision,
                replacement: model.replacement,
                onReplacementCompleted: { result in
                    guard model.replacement?.revision == result.revision else { return }
                    model.text = result.nativeText
                    model.editRevision = result.nativeEditRevision
                },
                isFocused: $model.focused,
                placeholder: "Message",
                isEnabled: true,
                accessibilityLabel: "Message",
                accessibilityHint: "",
                mentionPicker: usesMentions ? model.picker : nil,
                mentionCandidates: usesMentions ? model.candidates : []
            )
            .frame(width: 340)
        }
    }
}
