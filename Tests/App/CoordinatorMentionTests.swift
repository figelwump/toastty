@testable import ConversationUI
import CoreState
import Foundation
import RemoteProtocol
import SwiftUI
import Testing
@testable import ToasttyApp

/// Mentions of tasks in a message to the coordinator: which text is a
/// link, where `@` starts a mention, which tasks the picker lists, and the
/// keys the picker takes.
@MainActor
struct CoordinatorMentionTests {
    private static let taskID = UUID(uuidString: "8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F")!
    private static let otherID = UUID(uuidString: "41B7E9C0-1111-4222-8333-444455556666")!
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let gray = ConversationChipColor(red: 0.5, green: 0.5, blue: 0.5)

    // MARK: - Links in plain text

    @Test func aLinkIsFoundWithItsLabelAndURL() throws {
        let text = "is [Fix the dot](toastty://task/\(Self.taskID.uuidString)) blocked?"
        let links = ConversationInlineLinks.scan(text)
        let link = try #require(links.first)
        #expect(links.count == 1)
        #expect(link.label == "Fix the dot")
        #expect(link.url.absoluteString == "toastty://task/\(Self.taskID.uuidString)")
        #expect(text[link.range] == "[Fix the dot](toastty://task/\(Self.taskID.uuidString))")
    }

    @Test func aLabelKeepsItsEscapedBracketsAndBackslashes() throws {
        let link = try #require(ConversationInlineLinks.scan(#"[Fix \[beta\] C:\\temp](https://example.com/a)"#).first)
        #expect(link.label == #"Fix [beta] C:\temp"#)
    }

    @Test(arguments: [
        "plain text with no link",
        "[label] (https://example.com) has a space",
        "[two\nlines](https://example.com)",
        "[no scheme](example.com/page)",
        "[spaces](https://example.com/a page)",
        "[](https://example.com/empty-label)",
        "[unclosed](https://example.com",
        #"\[escaped](https://example.com)"#,
        "[nested [label]](https://example.com)",
    ])
    func textThatIsNotAPlainInlineLinkIsNone(_ text: String) {
        #expect(ConversationInlineLinks.scan(text).isEmpty)
    }

    @Test func everyLinkInTheTextIsFound() {
        let text = "[a](https://a.example) and [b](toastty://task/\(Self.otherID.uuidString)), [c](https://c.example)"
        #expect(ConversationInlineLinks.scan(text).map(\.label) == ["a", "b", "c"])
    }

    /// A mention reads back as the task it names, with its title, also when
    /// the title has Markdown's brackets.
    @Test func aMentionsLinkReadsBackAsItsTask() throws {
        let title = #"Fix [beta] the \ dot"#
        let markdown = CoordinatorTaskLink.markdown(taskID: Self.taskID, title: title)
        #expect(markdown == #"[Fix \[beta\] the \\ dot](toastty://task/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F)"#)
        let link = try #require(ConversationInlineLinks.scan("see \(markdown) now").first)
        #expect(link.label == title)
        #expect(CoordinatorTaskLink.taskID(in: link.url) == Self.taskID)
    }

    // MARK: - Chips in the user's message

    @Test func onlyLinksThePresenterDrawsAsChipsChange() {
        let chip = ConversationLinkChip(markColor: Self.gray, title: "Fix the dot", detail: "#312")
        let presenter = ConversationLinkPresenter(revision: 1) { url in
            guard CoordinatorTaskLink.isToasttyURL(url) else { return nil }
            return CoordinatorTaskLink.taskID(in: url) == Self.taskID ? .chip(chip) : .plainText
        }
        let text = "is [x](toastty://task/\(Self.taskID.uuidString)) done? See [docs](https://example.com) and "
            + "[gone](toastty://task/\(Self.otherID.uuidString)). *Not bold*"
        let rendered = ConversationLinkDecoration.applyChips(toPlainText: text, presenter: presenter)
        let string = String(rendered.characters)
        #expect(string.hasPrefix("is "))
        #expect(string.contains("Fix\u{00A0}the\u{00A0}dot"))
        #expect(string.contains("#312"))
        #expect(string.contains("toastty://task/\(Self.taskID.uuidString)") == false)
        // Everything else stays as typed: a web link, a link to a task the
        // presenter does not know, and Markdown.
        #expect(string.contains(" done? See [docs](https://example.com) and [gone](toastty://task/\(Self.otherID.uuidString)). *Not bold*"))
        #expect(rendered.runs.contains { $0[ConversationChipAttribute.self] != nil })
    }

    @Test func withoutAPresenterTheTextIsAsTyped() {
        let text = "is [x](toastty://task/\(Self.taskID.uuidString)) done?"
        #expect(String(ConversationLinkDecoration.applyChips(toPlainText: text, presenter: nil).characters) == text)
    }

    // MARK: - Where @ starts a mention

    private func match(_ text: String, caret: Int? = nil) -> CoordinatorMentionTrigger.Match? {
        let string = text as NSString
        return CoordinatorMentionTrigger.match(in: string, caret: caret ?? string.length)
    }

    @Test func anAtSignStartsAMentionAtTheStartAfterASpaceOrAnOpener() {
        #expect(match("@") == .init(anchor: 0, query: ""))
        #expect(match("ask @dock") == .init(anchor: 4, query: "dock"))
        #expect(match("ask (@dock") == .init(anchor: 5, query: "dock"))
        #expect(match("ask \"@dock") == .init(anchor: 5, query: "dock"))
        #expect(match("is @fix the dot") == .init(anchor: 3, query: "fix the dot"))
        #expect(match("\u{FFFC}@dock") == .init(anchor: 1, query: "dock"))
    }

    @Test func anAtSignInAWordOrBeforeASpaceStartsNone() {
        #expect(match("mail a@b.com") == nil)
        #expect(match("meet @ 5") == nil)
        #expect(match("@one\ntwo") == nil)
        #expect(match("@a@b") == nil)
        #expect(match("no at sign") == nil)
        #expect(match("") == nil)
        // A search longer than a title's words is ordinary text.
        #expect(match("@" + String(repeating: "a", count: CoordinatorMentionTrigger.maximumQueryLength + 1)) == nil)
    }

    @Test func theCaretDecidesTheSearch() {
        #expect(match("ask @dock please", caret: 9) == .init(anchor: 4, query: "dock"))
        #expect(match("ask @dock please", caret: 3) == nil)
    }

    // MARK: - Which tasks the picker lists

    private static func candidate(
        _ title: String,
        group: CoordinatorMentionCandidate.Group,
        project: String? = "toastty",
        pullRequest: Int? = nil,
        doneDaysAgo: Double? = nil,
        id: UUID = UUID()
    ) -> CoordinatorMentionCandidate {
        CoordinatorMentionCandidate(
            taskID: id,
            title: title,
            projectTitle: project,
            pullRequestNumber: pullRequest,
            group: group,
            markColor: gray,
            doneAt: doneDaysAgo.map { now.addingTimeInterval(-$0 * 24 * 60 * 60) }
        )
    }

    private static let board: [CoordinatorMentionCandidate] = [
        candidate("Show the coordinator's chat in a dock", group: .working, pullRequest: 331),
        candidate("Fix the unread dot", group: .needsYou, pullRequest: 312),
        candidate("Add the export API", group: .needsYou, project: "toastty-web"),
        candidate("Keep image thumbnails one size", group: .toShip, pullRequest: 335),
        candidate("Show the sidebar as All and Needs you", group: .done, pullRequest: 332, doneDaysAgo: 2),
        candidate("Old cleanup of the Café menu", group: .done, pullRequest: 33, doneDaysAgo: 40),
        candidate("Archived spike", group: .archived),
        candidate("Idle notes", group: .idle),
    ]

    private func titles(_ query: String) -> [[String]] {
        CoordinatorMentionSearch.sections(query: query, candidates: Self.board, now: Self.now)
            .map { $0.candidates.map(\.title) }
    }

    @Test func beforeASearchThePickerListsOpenTasksByStageAndRecentDoneOnes() {
        let sections = CoordinatorMentionSearch.sections(query: "", candidates: Self.board, now: Self.now)
        #expect(sections.map(\.group) == [.needsYou, .working, .idle, .toShip, .done])
        // Within a group, the board's order: newest activity first.
        #expect(sections[0].candidates.map(\.title) == ["Fix the unread dot", "Add the export API"])
        #expect(sections.last?.candidates.map(\.title) == ["Show the sidebar as All and Needs you"])
    }

    @Test func aPullRequestNumberFindsItsTasks() {
        #expect(titles("#33") == [
            ["Show the coordinator's chat in a dock"],
            ["Keep image thumbnails one size"],
            ["Show the sidebar as All and Needs you", "Old cleanup of the Café menu"],
        ])
        #expect(titles("#312") == [["Fix the unread dot"]])
        // Digits alone match a number too.
        #expect(titles("331") == [["Show the coordinator's chat in a dock"]])
        #expect(titles("#dock").isEmpty)
    }

    @Test func wordsMatchTheTitleAndProjectInAnyOrder() {
        #expect(titles("dot unread") == [["Fix the unread dot"]])
        #expect(titles("web export") == [["Add the export API"]])
        // Case and accents do not matter; an old done task and an archived
        // one show for a search.
        #expect(titles("cafe") == [["Old cleanup of the Café menu"]])
        #expect(titles("SPIKE") == [["Archived spike"]])
        #expect(titles("nothing like this").isEmpty)
    }

    @Test func aTaskSpaceWithoutARecordCannotBeMentioned() {
        let item = TaskBoardItem(
            id: .taskSpace(UUID()), record: nil, title: "Watched space", stage: .running,
            agent: .idle, activityAt: Self.now
        )
        #expect(CoordinatorMentionCandidate.candidates(from: [item]).isEmpty)
    }

    // MARK: - The picker's keys

    private func picker(_ text: String) -> CoordinatorMentionPicker {
        let picker = CoordinatorMentionPicker()
        picker.candidates = Self.board
        picker.now = { Self.now }
        picker.update(text: text as NSString, selection: NSRange(location: (text as NSString).length, length: 0))
        return picker
    }

    @Test func theArrowsMoveTheSelectionAndWrap() {
        let picker = picker("ask @#33")
        #expect(picker.results.count == 4)
        #expect(picker.handle(.down))
        #expect(picker.selectedIndex == 1)
        #expect(picker.handle(.up) && picker.handle(.up))
        #expect(picker.selectedIndex == 3)
        // A new search starts at the first task.
        picker.update(text: "ask @#331", selection: NSRange(location: 9, length: 0))
        #expect(picker.selectedIndex == 0)
    }

    @Test func escapeClosesThePickerForThatAtSignOnly() {
        let picker = picker("ask @dock")
        #expect(picker.isOpen)
        #expect(picker.handle(.cancel))
        #expect(picker.isOpen == false)
        // Typing on after the same @ does not open it again.
        picker.update(text: "ask @docks", selection: NSRange(location: 10, length: 0))
        #expect(picker.isOpen == false)
        // A new @ does.
        picker.update(text: "ask @docks @fix", selection: NSRange(location: 15, length: 0))
        #expect(picker.isOpen)
    }

    @Test func withNoTaskToChooseOnlyEscapeIsThePickers() {
        let picker = picker("ask @zzz")
        #expect(picker.isOpen)
        #expect(picker.results.isEmpty)
        #expect(picker.handle(.choose) == false)
        #expect(picker.handle(.down) == false)
        #expect(picker.handle(.cancel))
    }

    @Test func ordinaryWordsAfterAnAtSignCloseThePicker() {
        let picker = picker("ping @bob")
        #expect(picker.isOpen, "One word with no match still shows that nothing matches")
        picker.update(text: "ping @bob about", selection: NSRange(location: 15, length: 0))
        #expect(picker.isOpen == false)
        // Words that match keep it open.
        picker.update(text: "ping @fix the", selection: NSRange(location: 13, length: 0))
        #expect(picker.isOpen)
    }
}
