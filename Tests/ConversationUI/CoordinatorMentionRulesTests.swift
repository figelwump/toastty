import ConversationUI
import Foundation
import XCTest

/// The rules that the Mac's and the phone's coordinator chats share for
/// mentioning a task: where `@` starts a mention, and which tasks the list
/// shows. Both test targets compile this file.
///
/// Failure modes covered: an email address or `@` inside a word starting a
/// mention; `@` followed by a space; a search that crosses a line break or a
/// mention shown as one object; a search over 60 characters; positions in
/// UTF-16 units after characters outside the Basic Multilingual Plane; `#`
/// with letters; archived and old done tasks before a search; more than 50
/// matches; the order of groups and of tasks in a group; ordinary words after
/// `@` keeping the list open; long or empty titles in a mention.
final class CoordinatorMentionRulesTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let gray = ConversationChipColor(red: 0.5, green: 0.5, blue: 0.5)

    // MARK: - Where @ starts a mention

    private func match(_ text: String, caret: Int? = nil) -> CoordinatorMentionTrigger.Match? {
        let string = text as NSString
        return CoordinatorMentionTrigger.match(in: string, caret: caret ?? string.length)
    }

    func testAnAtSignStartsAMentionAtTheStartAfterASpaceOrAnOpener() {
        XCTAssertEqual(match("@"), .init(anchor: 0, query: ""))
        XCTAssertEqual(match("ask @dock"), .init(anchor: 4, query: "dock"))
        XCTAssertEqual(match("ask (@dock"), .init(anchor: 5, query: "dock"))
        XCTAssertEqual(match("ask [@dock"), .init(anchor: 5, query: "dock"))
        XCTAssertEqual(match("ask \"@dock"), .init(anchor: 5, query: "dock"))
        XCTAssertEqual(match("ask “@dock"), .init(anchor: 5, query: "dock"))
        XCTAssertEqual(match("ask '@dock"), .init(anchor: 5, query: "dock"))
        XCTAssertEqual(match("is @fix the dot"), .init(anchor: 3, query: "fix the dot"))
        // After a mention shown as one object, such as the Mac's chip.
        XCTAssertEqual(match("\u{FFFC}@dock"), .init(anchor: 1, query: "dock"))
        // The last @ before the caret is the one the user types after.
        XCTAssertEqual(match("ask @a and @b"), .init(anchor: 11, query: "b"))
    }

    func testAnAtSignInAWordOrBeforeASpaceStartsNone() {
        XCTAssertNil(match("mail a@b.com"))
        XCTAssertNil(match("mail me@"))
        XCTAssertNil(match("meet @ 5"))
        XCTAssertNil(match("@ "))
        XCTAssertNil(match("@a@b"))
        XCTAssertNil(match("no at sign"))
        XCTAssertNil(match(""))
        XCTAssertNil(match("@dock", caret: 0))
    }

    /// An `@` at the start of a line starts a mention, and the search stays
    /// on its line.
    func testTheSearchStaysOnItsLine() {
        XCTAssertEqual(match("first line\n@dock"), .init(anchor: 11, query: "dock"))
        XCTAssertEqual(match("first line\r\n@dock"), .init(anchor: 12, query: "dock"))
        XCTAssertNil(match("@one\ntwo"))
        XCTAssertNil(match("@one\u{2028}two"))
        // A mention shown as one object ends the search too.
        XCTAssertNil(match("@one\u{FFFC}two"))
    }

    func testASearchLongerThanSixtyCharactersIsOrdinaryText() {
        let longest = String(repeating: "a", count: CoordinatorMentionTrigger.maximumQueryLength)
        XCTAssertEqual(match("@" + longest), .init(anchor: 0, query: longest))
        XCTAssertNil(match("@" + longest + "a"))
        XCTAssertNil(match("ask @" + longest + " more words"))
    }

    func testTheCaretDecidesTheSearch() {
        XCTAssertEqual(match("ask @dock please", caret: 9), .init(anchor: 4, query: "dock"))
        XCTAssertEqual(match("ask @dock please", caret: 5), .init(anchor: 4, query: ""))
        XCTAssertNil(match("ask @dock please", caret: 4))
        XCTAssertNil(match("ask @dock please", caret: 3))
        XCTAssertNil(match("ask @dock please", caret: 99))
    }

    /// Positions are in UTF-16 units, as text views count them.
    func testPositionsCountUTF16Units() {
        let text = "🙂 é @dock"
        XCTAssertEqual(match(text), .init(anchor: (text as NSString).length - 5, query: "dock"))
        XCTAssertEqual(match("ask @🙂x"), .init(anchor: 4, query: "🙂x"))
    }

    // MARK: - Which tasks the list shows

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
        candidate("Done without a date", group: .done),
        candidate("Archived spike", group: .archived),
        candidate("Idle notes", group: .idle, project: nil),
    ]

    private func titles(_ query: String) -> [[String]] {
        CoordinatorMentionSearch.sections(query: query, candidates: Self.board, now: Self.now)
            .map { $0.candidates.map(\.title) }
    }

    func testBeforeASearchTheListShowsOpenTasksByStageAndRecentDoneOnes() {
        let sections = CoordinatorMentionSearch.sections(query: "", candidates: Self.board, now: Self.now)
        XCTAssertEqual(sections.map(\.group), [.needsYou, .working, .idle, .toShip, .done])
        // Within a group, the order the app gives: newest activity first.
        XCTAssertEqual(sections[0].candidates.map(\.title), ["Fix the unread dot", "Add the export API"])
        // A done task from the last 14 days; not an older one, not one with
        // no date, and no archived task.
        XCTAssertEqual(sections.last?.candidates.map(\.title), ["Show the sidebar as All and Needs you"])
        // Spaces alone are no search.
        XCTAssertEqual(titles("  "), sections.map { $0.candidates.map(\.title) })
    }

    func testAPullRequestNumberFindsItsTasks() {
        XCTAssertEqual(titles("#33"), [
            ["Show the coordinator's chat in a dock"],
            ["Keep image thumbnails one size"],
            ["Show the sidebar as All and Needs you", "Old cleanup of the Café menu"],
        ])
        XCTAssertEqual(titles("#312"), [["Fix the unread dot"]])
        // Digits alone match a number too.
        XCTAssertEqual(titles("331"), [["Show the coordinator's chat in a dock"]])
        // `#` alone lists the tasks with a pull request.
        XCTAssertEqual(titles("#").flatMap { $0 }.count, 5)
    }

    func testAHashWithLettersMatchesNothing() {
        XCTAssertEqual(titles("#dock"), [])
        XCTAssertEqual(titles("#3a"), [])
        XCTAssertEqual(titles("#３３"), [], "Only ASCII digits are a number")
    }

    func testWordsMatchTheTitleAndProjectInAnyOrder() {
        XCTAssertEqual(titles("dot unread"), [["Fix the unread dot"]])
        XCTAssertEqual(titles("web export"), [["Add the export API"]])
        XCTAssertEqual(titles("  idle  "), [["Idle notes"]])
        // Case and accents do not matter; an old done task and an archived
        // one show for a search.
        XCTAssertEqual(titles("cafe"), [["Old cleanup of the Café menu"]])
        XCTAssertEqual(titles("SPIKE"), [["Archived spike"]])
        XCTAssertEqual(titles("without date"), [["Done without a date"]])
        XCTAssertEqual(titles("nothing like this"), [])
    }

    func testTheListShowsAtMostFiftyTasksInGroupOrder() {
        let needsYou = (0..<30).map { Self.candidate("Needs you \($0)", group: .needsYou) }
        let working = (0..<30).map { Self.candidate("Working \($0)", group: .working) }
        let idle = (0..<5).map { Self.candidate("Idle \($0)", group: .idle) }
        let sections = CoordinatorMentionSearch.sections(query: "", candidates: idle + working + needsYou, now: Self.now)
        XCTAssertEqual(sections.map(\.group), [.needsYou, .working])
        XCTAssertEqual(sections.flatMap(\.candidates).count, CoordinatorMentionSearch.maximumResults)
        XCTAssertEqual(sections[0].candidates.count, 30)
        XCTAssertEqual(sections[1].candidates.map(\.title), (0..<20).map { "Working \($0)" })
    }

    /// Several words that match nothing end the search, so ordinary text
    /// after an `@` does not keep the list open; one word shows that nothing
    /// matches.
    func testOrdinaryWordsAfterAnAtSignEndTheSearch() {
        func ends(_ query: String) -> Bool {
            CoordinatorMentionSearch.endsTheSearch(
                query: query,
                sections: CoordinatorMentionSearch.sections(query: query, candidates: Self.board, now: Self.now)
            )
        }
        XCTAssertFalse(ends("bob"))
        XCTAssertTrue(ends("bob "))
        XCTAssertTrue(ends("bob about"))
        XCTAssertFalse(ends("fix the"))
        XCTAssertFalse(ends(""))
    }

    // MARK: - A mention's label

    func testALabelIsOneShortLine() {
        XCTAssertEqual(CoordinatorMentionCandidate.label(title: "Fix the\n  unread dot"), "Fix the unread dot")
        XCTAssertEqual(CoordinatorMentionCandidate.label(title: " \n "), "Untitled task")
        let long = String(repeating: "word ", count: 20)
        let label = CoordinatorMentionCandidate.label(title: long)
        XCTAssertEqual(label.count, CoordinatorMentionCandidate.maximumLabelLength)
        XCTAssertTrue(label.hasSuffix("…"))
        let exact = String(repeating: "a", count: CoordinatorMentionCandidate.maximumLabelLength)
        XCTAssertEqual(CoordinatorMentionCandidate.label(title: exact), exact)
    }
}
