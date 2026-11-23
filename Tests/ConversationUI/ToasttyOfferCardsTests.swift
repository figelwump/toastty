@testable import ConversationUI
import Foundation
import RemoteProtocol
import XCTest

/// The coordinator's offers in the shared chat views: which block of a
/// message is a group of offers, which offers show as cards at once, and
/// which offers the user has answered. Both test targets compile this file.
///
/// Failure modes covered: a long block of offers cut into pieces as code is;
/// a broken block or another language's block drawn as cards; an answer
/// counted for an offer that the coordinator made again later; an answer
/// that waits not shown; an older list that takes answers after a newer one;
/// a block of offers in a message that is not the agent's counted as a list.
@MainActor
final class ToasttyOfferCardsTests: XCTestCase {
    private static func offersJSON(_ ids: [String], suggested: String = "yes", padding: Int = 0) -> String {
        let offers = ids.map { id in
            #"{"id": "\#(id)", "kind": "task", "title": "Offer \#(id)", "what": "\#(String(repeating: "word ", count: padding))", "suggested": "\#(suggested)"}"#
        }
        return "{\"offers\": [\(offers.joined(separator: ",\n"))]}"
    }

    private static func message(_ json: String, language: String = CoordinatorOfferGroup.codeLanguage) -> String {
        "2 items block work.\n\n```\(language)\n\(json)\n```\n\nThat is all."
    }

    private static func offerGroups(in blocks: [ToasttyMarkdownBlock]) -> [CoordinatorOfferGroup] {
        blocks.compactMap { block in
            if case .offers(let group) = block.style { return group }
            return nil
        }
    }

    // MARK: - The block

    func testABlockOfOffersIsOneGroupAndOtherBlocksStayCode() {
        let blocks = ToasttyMarkdownParser.parse(Self.message(Self.offersJSON(["a", "b"])))
        XCTAssertEqual(Self.offerGroups(in: blocks).map { $0.offers.map(\.id) }, [["a", "b"]])
        // The text around the block stays text.
        XCTAssertEqual(blocks.count, 3)

        for text in [
            Self.message("{\"offers\": ["),
            Self.message(Self.offersJSON(["a", "a"])),
            Self.message(Self.offersJSON(["a"]), language: "json"),
        ] {
            let blocks = ToasttyMarkdownParser.parse(text)
            XCTAssertTrue(Self.offerGroups(in: blocks).isEmpty, text)
            XCTAssertTrue(blocks.contains { block in
                if case .code = block.style { return true }
                return false
            }, text)
        }
    }

    /// A long message is drawn as several rows. The offers stay one block,
    /// in a row of their own, so the cards have all of them.
    func testALongBlockOfOffersIsNotCutIntoPieces() throws {
        let ids = (1...12).map { "offer-\($0)" }
        let text = String(repeating: "A paragraph before the offers. ", count: 60)
            + "\n\n" + Self.message(Self.offersJSON(ids, padding: 80))
        XCTAssertGreaterThan(text.count, ToasttyMarkdownChunking.chunkThreshold * 2)
        let chunks = ToasttyMarkdownChunking.split(text)
        XCTAssertGreaterThan(chunks.count, 2)
        let groups = chunks.map { Self.offerGroups(in: $0.blocks) }
        XCTAssertEqual(groups.flatMap { $0 }.map { $0.offers.map(\.id) }, [ids])
        let offersChunk = try XCTUnwrap(chunks.first { Self.offerGroups(in: $0.blocks).isEmpty == false })
        XCTAssertEqual(offersChunk.blocks.count, 1)
    }

    // MARK: - Which offers show at once

    func testFiveSuggestedOffersShowAndTheOthersFold() throws {
        let suggested = (1...7).map { "yes-\($0)" }
        let skips = ["skip-1", "skip-2"]
        let json = "[" + (suggested.map { #"{"id": "\#($0)", "title": "T"}"# }
            + skips.map { #"{"id": "\#($0)", "title": "T", "suggested": "skip"}"# }).joined(separator: ",") + "]"
        let layout = ToasttyOfferGroupLayout(try XCTUnwrap(CoordinatorOfferGroup(json: json)))
        XCTAssertEqual(layout.shown.map(\.id), Array(suggested.prefix(5)))
        XCTAssertEqual(layout.more.map(\.id), Array(suggested.suffix(2)))
        XCTAssertEqual(layout.skips.map(\.id), skips)
    }

    func testAnOfferSaysOnWhichListItIs() {
        XCTAssertEqual(CoordinatorOffer(id: "a", title: "T", list: 1, lists: 3).listText, "new")
        XCTAssertEqual(CoordinatorOffer(id: "a", title: "T", list: 2, lists: 3).listText, "list 2 of 3")
        XCTAssertEqual(CoordinatorOffer(id: "a", title: "T", list: 3, lists: 3).listText, "list 3 of 3 · last time")
        XCTAssertNil(CoordinatorOffer(id: "a", title: "T").listText)
        // A rule's text is its line.
        XCTAssertEqual(
            CoordinatorOffer(id: "a", kind: "Rule", title: "T", what: "W", yes: "Y").details.map(\.label),
            ["The line", "A yes writes"]
        )
        XCTAssertEqual(
            CoordinatorOffer(id: "a", kind: "task", title: "T", what: "W", example: "E", why: "N", yes: "Y").details.map(\.label),
            ["What it does", "When it helps", "Why now", "A yes starts"]
        )
        XCTAssertEqual(CoordinatorOffer(id: "a", title: "Plain `task send` and [a task](toastty://task/x)").plainTitle,
                       "Plain task send and a task")
    }

    /// The message's accessibility label names the offers and leaves out
    /// their data: each card has its own label.
    func testTheMessagesLabelLeavesOutTheOffersData() {
        let spoken = ToasttyOfferGroupView.spokenText(of: Self.message(Self.offersJSON(["a", "b"])))
        XCTAssertEqual(spoken, "2 items block work.\n2 offers\nThat is all.")
        let broken = Self.message("{\"offers\": [")
        XCTAssertEqual(ToasttyOfferGroupView.spokenText(of: broken), broken)
        XCTAssertEqual(ToasttyOfferGroupView.spokenText(of: "No offers."), "No offers.")
    }

    func testTheFooterCountsTheAnswers() {
        func text(_ takesAnswers: Bool, _ pending: Int, _ answered: Int) -> String {
            ToasttyOfferGroupView.footerText(takesAnswers: takesAnswers, pending: pending, answered: answered, total: 4)
        }
        XCTAssertEqual(text(true, 0, 0), "No answers yet")
        XCTAssertEqual(text(true, 1, 0), "1 answer not sent")
        XCTAssertEqual(text(true, 3, 1), "3 answers not sent")
        XCTAssertEqual(text(true, 0, 2), "2 of 4 answered")
        XCTAssertEqual(text(true, 0, 4), "All 4 answered")
        XCTAssertEqual(text(false, 2, 0), "A newer list has the offers that are open now.")
    }

    // MARK: - The choices before they are sent

    /// Yes and Skip on a card, "Skip all" on the folded line, and Send
    /// answers: the choices collect, an offer that has its answer takes no
    /// second one, and the sent choices are choices no longer.
    func testChoicesCollectUntilTheyAreSent() throws {
        let group = try XCTUnwrap(CoordinatorOfferGroup(json: """
        [{"id": "a", "title": "Plain `task send`"}, {"id": "b", "title": "B"},
         {"id": "s1", "title": "S1", "suggested": "skip"}, {"id": "s2", "title": "S2", "suggested": "skip"}]
        """))
        let row = ToasttyOfferRow(
            rowID: ToasttyTranscriptRowID(
                projectionRunID: UUID(), projectionGeneration: 1, conversationID: conversationID.rawValue, sequence: 1
            ),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )
        func key(_ id: String) -> ToasttyOfferSelections.Key { .init(rowID: row.rowID, offerID: id) }
        // The user answered s2 before, in the conversation.
        let answered = ToasttyOfferAnswers(events: [offers(1, ["a", "b", "s1", "s2"]), answers(2, [("s2", .yes)])])
        let skips = ToasttyOfferGroupLayout(group).skips
        let selections = ToasttyOfferSelections()
        XCTAssertTrue(selections.pendingAnswers(for: group, in: row, answers: answered).isEmpty)

        selections.choose(.yes, for: key("b"))
        selections.choose(.skip, for: key("a"))
        selections.choose(.yes, for: key("a"))
        // A click on the chosen answer takes it back.
        selections.choose(.yes, for: key("b"))
        selections.choose(.skip, for: key("s2"))
        XCTAssertEqual(
            selections.pendingAnswers(for: group, in: row, answers: answered),
            [CoordinatorOfferAnswer(offerID: "a", title: "Plain task send", choice: .yes)]
        )

        XCTAssertEqual(selections.unanswered(skips, in: row, answers: answered).map(\.id), ["s1"])
        XCTAssertFalse(selections.allSkipped(skips, in: row, answers: answered))
        selections.toggleSkipAll(skips, in: row, answers: answered)
        XCTAssertTrue(selections.allSkipped(skips, in: row, answers: answered))
        let pending = selections.pendingAnswers(for: group, in: row, answers: answered)
        XCTAssertEqual(pending.map(\.offerID), ["a", "s1"])
        XCTAssertEqual(pending.map(\.choice), [.yes, .skip])
        selections.toggleSkipAll(skips, in: row, answers: answered)
        XCTAssertEqual(selections.pendingAnswers(for: group, in: row, answers: answered).map(\.offerID), ["a"])

        // The choices of another message's cards are apart.
        let other = ToasttyOfferRow(
            rowID: ToasttyTranscriptRowID(
                projectionRunID: row.rowID.projectionRunID, projectionGeneration: 1,
                conversationID: conversationID.rawValue, sequence: 9
            ),
            timestamp: row.timestamp
        )
        XCTAssertTrue(selections.pendingAnswers(for: group, in: other, answers: ToasttyOfferAnswers()).isEmpty)

        selections.didSend(selections.pendingAnswers(for: group, in: row, answers: answered), in: row)
        XCTAssertTrue(selections.pendingAnswers(for: group, in: row, answers: answered).isEmpty)
    }

    // MARK: - The answers

    private let conversationID = RemoteConversationID(rawValue: UUID())

    private func event(_ sequence: UInt64, _ payload: ConversationEventPayload) -> ConversationEvent {
        ConversationEvent(
            conversationID: conversationID,
            sequence: sequence,
            eventID: "event-\(sequence)",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(sequence)),
            provider: .claude,
            payload: payload
        )
    }

    private func offers(_ sequence: UInt64, _ ids: [String]) -> ConversationEvent {
        event(sequence, .assistantMessage(.init(text: Self.message(Self.offersJSON(ids)), phase: .final)))
    }

    private func answers(_ sequence: UInt64, _ choices: [(String, CoordinatorOfferAnswer.Choice)]) -> ConversationEvent {
        event(sequence, .userMessage(.init(text: Self.answersText(choices), origin: .remote)))
    }

    private static func answersText(_ choices: [(String, CoordinatorOfferAnswer.Choice)]) -> String {
        CoordinatorMessageHeader.answersMessage(
            choices.map { CoordinatorOfferAnswer(offerID: $0.0, title: "Offer \($0.0)", choice: $0.1) },
            time: "9:03 AM"
        )
    }

    func testAnAnswerCountsForTheOffersBeforeIt() {
        let state = ToasttyOfferAnswers(events: [
            offers(1, ["a", "b", "c"]),
            answers(2, [("a", .yes), ("b", .skip)]),
        ])
        XCTAssertEqual(state.choice(for: "a", offeredAt: 1), .yes)
        XCTAssertEqual(state.choice(for: "b", offeredAt: 1), .skip)
        XCTAssertNil(state.choice(for: "c", offeredAt: 1))
        XCTAssertTrue(state.takesAnswers(at: 1))
    }

    /// The coordinator can offer the same thing on the next list. That
    /// offer has no answer yet, and the older list takes none anymore.
    func testANewerListReplacesTheOlderAndItsOffersAreOpenAgain() {
        let state = ToasttyOfferAnswers(events: [
            offers(1, ["a", "b"]),
            answers(2, [("a", .skip)]),
            event(3, .assistantMessage(.init(text: "Nothing else.", phase: .final))),
            offers(4, ["a", "b"]),
        ])
        XCTAssertEqual(state.choice(for: "a", offeredAt: 1), .skip)
        XCTAssertNil(state.choice(for: "a", offeredAt: 4))
        XCTAssertFalse(state.takesAnswers(at: 1))
        XCTAssertTrue(state.takesAnswers(at: 4))

        // A second answer replaces the first for the newer list.
        let answered = ToasttyOfferAnswers(events: [
            offers(1, ["a"]), answers(2, [("a", .skip)]), offers(4, ["a"]), answers(5, [("a", .yes)]),
        ])
        XCTAssertEqual(answered.choice(for: "a", offeredAt: 4), .yes)
    }

    /// An answer counts from the click: its message can wait for the
    /// coordinator's prompt. When the user removes it, the card is open again.
    func testAnAnswerThatWaitsCountsUntilItsMessageIsRemoved() {
        let inConversation = ToasttyOfferAnswers(events: [offers(1, ["a", "b"])])
        let waiting = inConversation.adding(waitingMessages: ["Hello", Self.answersText([("b", .yes)])])
        XCTAssertEqual(waiting.choice(for: "b", offeredAt: 1), .yes)
        XCTAssertNil(waiting.choice(for: "a", offeredAt: 1))
        XCTAssertNil(inConversation.adding(waitingMessages: ["Hello"]).choice(for: "b", offeredAt: 1))
    }

    /// Only the agent's own message holds a list. A user's message, or a
    /// sender's, that shows the same block replaces no list and answers
    /// nothing.
    func testOnlyTheAgentsMessageIsAListAndOnlyToasttysLineIsAnAnswer() {
        let block = Self.message(Self.offersJSON(["a"]))
        let state = ToasttyOfferAnswers(events: [
            offers(1, ["a"]),
            event(2, .userMessage(.init(text: block, origin: .remote))),
            event(3, .userMessage(.init(
                text: CoordinatorMessageHeader.message(from: .named("Grok Bot"), text: Self.answersText([("a", .yes)])),
                origin: .remote
            ))),
            event(4, .assistantMessage(.init(text: Self.message("{\"offers\": ["), phase: .final))),
        ])
        XCTAssertTrue(state.takesAnswers(at: 1))
        XCTAssertNil(state.choice(for: "a", offeredAt: 1))
        XCTAssertEqual(ToasttyOfferAnswers(), ToasttyOfferAnswers(events: []))
    }
}
