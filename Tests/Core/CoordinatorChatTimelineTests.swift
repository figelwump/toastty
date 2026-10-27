import CoreState
import Foundation
import Testing

struct CoordinatorChatTimelineTests {
    private let start = Date(timeIntervalSince1970: 1_792_800_000)
    private let taskID = UUID()

    private func event(_ kind: CoordinatorEvent.Kind, at seconds: TimeInterval, task: UUID? = nil, text: String? = nil) -> CoordinatorEvent {
        CoordinatorEvent(at: start.addingTimeInterval(seconds), kind: kind, taskID: task, text: text, sessionID: nil)
    }

    private func stamp(_ version: Int, at seconds: TimeInterval) -> CoordinatorChatTimeline.PacketStamp {
        .init(version: version, createdAt: start.addingTimeInterval(seconds))
    }

    @Test
    func aPacketCardShowsThePacketThatWasNewestWhenItWasPosted() {
        let cards = CoordinatorChatTimeline.cards(
            events: [event(.taskStarted, at: 0, task: taskID), event(.packet, at: 100, task: taskID)],
            packets: [taskID: [stamp(1, at: 90)]]
        )
        #expect(cards.map(\.kind) == [.taskStarted, .packet])
        #expect(cards[1].packetVersion == 1)
        #expect(cards[1].superseded == false && cards[1].isNew == false)
    }

    @Test
    func aNewerPacketAddsANewCardAtTheEndAndTheOldOneCollapses() {
        let note = event(.note, at: 150, text: "Checking in.")
        let cards = CoordinatorChatTimeline.cards(
            events: [event(.packet, at: 100, task: taskID), note],
            packets: [taskID: [stamp(2, at: 200), stamp(1, at: 90)]]
        )
        #expect(cards.map(\.id) == [cards[0].id, note.id.uuidString, "packet-\(taskID.uuidString)-v2"])
        #expect(cards[0].packetVersion == 1 && cards[0].superseded)
        #expect(cards[2].packetVersion == 2 && cards[2].isNew && cards[2].superseded == false)
        #expect(cards[2].at == start.addingTimeInterval(200))
    }

    @Test
    func theCoordinatorPostingTheNewVersionReplacesTheAddedCard() {
        let cards = CoordinatorChatTimeline.cards(
            events: [event(.packet, at: 100, task: taskID), event(.packet, at: 230, task: taskID)],
            packets: [taskID: [stamp(1, at: 90), stamp(2, at: 200)]]
        )
        #expect(cards.count == 2)
        #expect(cards.map(\.packetVersion) == [1, 2])
        #expect(cards.map(\.superseded) == [true, false])
        #expect(cards[1].isNew)
        // A card posted just before its packet landed still names it.
        let early = CoordinatorChatTimeline.cards(
            events: [event(.packet, at: 100, task: taskID)],
            packets: [taskID: [stamp(1, at: 120)]]
        )
        #expect(early.map(\.packetVersion) == [1])
        // A version published soon after the card is a new version.
        let soon = CoordinatorChatTimeline.cards(
            events: [event(.packet, at: 100, task: taskID)],
            packets: [taskID: [stamp(1, at: 90), stamp(2, at: 150)]]
        )
        #expect(soon.map(\.packetVersion) == [1, 2])
        #expect(soon.map(\.isNew) == [false, true])
    }

    @Test
    func tasksWithoutCardsAndPacketlessCardsAddNothing() {
        let other = UUID()
        let cards = CoordinatorChatTimeline.cards(
            events: [event(.question, at: 10, task: taskID, text: "Which base?"), event(.packet, at: 20, task: other)],
            packets: [UUID(): [stamp(1, at: 5)]]
        )
        #expect(cards.count == 2)
        #expect(cards[1].packetVersion == nil && cards[1].superseded == false)
        // The question card's task gets a card once it publishes.
        let later = CoordinatorChatTimeline.cards(
            events: [event(.question, at: 10, task: taskID, text: "Which base?")],
            packets: [taskID: [stamp(1, at: 50)]]
        )
        #expect(later.map(\.kind) == [.question, .packet])
        #expect(later[1].isNew == false)
    }

    @Test
    func addedCardsKeepEachVersionWhenTheCoordinatorPostedNone() {
        let started = event(.taskStarted, at: 0, task: taskID)
        let first = CoordinatorChatTimeline.cards(events: [started], packets: [taskID: [stamp(1, at: 50)]])
        let v1 = "packet-\(taskID.uuidString)-v1"
        #expect(first.map(\.id) == [started.id.uuidString, v1])
        // v2 adds a new card; the v1 card keeps its ID and collapses.
        let second = CoordinatorChatTimeline.cards(events: [started], packets: [taskID: [stamp(1, at: 50), stamp(2, at: 80)]])
        #expect(second.map(\.id) == [started.id.uuidString, v1, "packet-\(taskID.uuidString)-v2"])
        #expect(second.map(\.superseded) == [false, true, false])
        #expect(second[2].isNew)
        // A card the coordinator posts after v2 announces v2; v1 keeps its
        // added card.
        let posted = event(.packet, at: 90, task: taskID)
        let third = CoordinatorChatTimeline.cards(events: [started, posted], packets: [taskID: [stamp(1, at: 50), stamp(2, at: 80)]])
        #expect(third.map(\.id) == [started.id.uuidString, v1, posted.id.uuidString])
        #expect(third.map(\.packetVersion) == [nil, 1, 2])
        #expect(third.map(\.superseded) == [false, true, false])
        #expect(third[2].isNew)
    }

    @Test
    func versionsFromBeforeTheTasksFirstCardGetNoCardButTheLatest() {
        let started = event(.taskStarted, at: 100, task: taskID)
        let cards = CoordinatorChatTimeline.cards(events: [started], packets: [taskID: [stamp(1, at: 10), stamp(2, at: 20)]])
        #expect(cards.map(\.packetVersion) == [2, nil])
    }

    @Test
    func taskNotesAndRepliesFormOneSharedThreadInsteadOfMoreCards() throws {
        let question = CoordinatorEvent(
            at: start, kind: .question, taskID: taskID, text: "Which base?", sessionID: nil, options: ["Main", "Feature"]
        )
        let note = event(.note, at: 10, task: taskID, text: "I checked both branches.")
        let reply = CoordinatorEvent(
            at: start.addingTimeInterval(20), kind: .reply, taskID: taskID, text: "Feature", sessionID: nil,
            threadRole: .userCoordinator, questionID: question.id, sourceID: "user-turn"
        )
        let packet = event(.packet, at: 30, task: taskID)
        let agent = CoordinatorEvent(
            at: start.addingTimeInterval(40), kind: .reply, taskID: taskID, text: "The branch is ready.", sessionID: nil,
            threadRole: .agent, sourceID: "agent-turn"
        )
        let standalone = event(.note, at: 50, text: "Checking other tasks.")
        var data = Data()
        for event in [question, note, reply, packet, agent, standalone] {
            data.append(try event.jsonLine())
            data.append(UInt8(ascii: "\n"))
        }
        let cards = CoordinatorChatTimeline.cards(events: CoordinatorEvent.decodeLog(data), packets: [:])
        #expect(cards.map(\.id) == [question.id.uuidString, packet.id.uuidString, standalone.id.uuidString])
        #expect(cards[0].options == ["Main", "Feature"])
        #expect(cards[0].answer == "Feature")
        #expect(cards[0].thread.map(\.role) == [.coordinator, .userCoordinator, .agent])
        #expect(cards[0].thread.map(\.text) == ["I checked both branches.", "Feature", "The branch is ready."])
        #expect(cards[1].thread == cards[0].thread)
        #expect(cards.map(\.isCurrent) == [false, true, false])
        #expect(cards[2].thread.isEmpty)
    }

    @Test
    func onlyTheFirstMatchingUserReplyAnswersAnEarlierQuestion() {
        let question = event(.question, at: 10, task: taskID, text: "Which base?")
        func reply(_ role: CoordinatorEvent.ThreadRole, text: String = "Main", task: UUID? = nil, questionID: UUID? = nil) -> CoordinatorEvent {
            CoordinatorEvent(
                at: start.addingTimeInterval(20), kind: .reply, taskID: task ?? taskID, text: text, sessionID: nil,
                threadRole: role, questionID: questionID ?? question.id
            )
        }
        let cards = CoordinatorChatTimeline.cards(events: [
            reply(.userTask, text: "Too early"), question,
            reply(.coordinator), reply(.agent), reply(.userCoordinator, task: UUID()),
            reply(.userTask, text: "  "), reply(.userTask, questionID: UUID()),
            reply(.userTask, text: "Feature"), reply(.userCoordinator, text: "Main"),
        ], packets: [:])
        #expect(cards.count == 1)
        #expect(cards[0].answer == "Feature")
        let unanswered = CoordinatorChatTimeline.cards(events: [question, reply(.agent)], packets: [:])
        #expect(unanswered[0].answer == nil)
    }

    @Test
    func aReplyBeforeAnyPostedCardKeepsAThreadAndReusesTheNextCard() {
        for role in [CoordinatorEvent.ThreadRole.userCoordinator, .userTask] {
            let reply = CoordinatorEvent(at: start, kind: .reply, taskID: taskID,
                                         text: "What changed?", sessionID: nil, threadRole: role)
            let first = CoordinatorChatTimeline.cards(events: [reply], packets: [:])
            #expect(first.count == 1)
            #expect(first.first?.taskID == taskID)
            #expect(first.first?.thread.map(\.text) == ["What changed?"])
            let question = event(.question, at: 10, task: taskID, text: "Continue?")
            let next = CoordinatorChatTimeline.cards(events: [reply, question], packets: [:])
            #expect(next.count == 1)
            #expect(next.first?.id == question.id.uuidString)
            #expect(next.first?.thread == first.first?.thread)
        }
    }

    @Test
    func sourceMessagesDeduplicatePerTaskAndThreadsKeepTheLastHundredInStableTimeOrder() {
        let note = event(.note, at: 0, task: taskID, text: "The task's first note.")
        let otherTaskID = UUID()
        let other = event(.question, at: 0, task: otherTaskID, text: "Continue?")
        var events = [note, other]
        for number in 1...101 {
            events.append(CoordinatorEvent(
                at: start.addingTimeInterval(TimeInterval(number / 2)), kind: .reply, taskID: taskID,
                text: "Reply \(number)", sessionID: nil, threadRole: .userTask, sourceID: "reply-\(number)"
            ))
        }
        events.append(CoordinatorEvent(
            at: start.addingTimeInterval(200), kind: .reply, taskID: taskID,
            text: "Duplicate", sessionID: nil, threadRole: .userTask, sourceID: "reply-101"
        ))
        events.append(CoordinatorEvent(
            at: start.addingTimeInterval(200), kind: .reply, taskID: otherTaskID,
            text: "Another task", sessionID: nil, threadRole: .userTask, sourceID: "reply-101"
        ))
        let cards = CoordinatorChatTimeline.cards(events: events, packets: [:])
        #expect(cards.count == 2)
        #expect(cards[0].id == note.id.uuidString && cards[0].kind == .taskStarted && cards[0].text == nil)
        #expect(cards[0].thread.count == 100)
        #expect(cards[0].thread.first?.text == "Reply 2")
        #expect(cards[0].thread.last?.text == "Reply 101")
        #expect(cards[1].thread.map(\.text) == ["Another task"])
        #expect(cards.allSatisfy { $0.isCurrent })
    }

    @Test
    func theCurrentCardIsTheNewestCardThatANewerPacketDidNotReplace() {
        let question = event(.question, at: 200, task: taskID, text: "Ship it?")
        let cards = CoordinatorChatTimeline.cards(
            events: [question, event(.packet, at: 100, task: taskID)],
            packets: [taskID: [stamp(1, at: 90), stamp(2, at: 150)]]
        )
        #expect(cards.map(\.kind) == [.packet, .packet, .question])
        #expect(cards.map(\.superseded) == [true, false, false])
        #expect(cards.map(\.isCurrent) == [false, false, true])
    }

    @Test
    func theChatCoversOnlyTheSelectedCoordinatorWorkspaceUntilItsTerminalShows() throws {
        var state = AppState.bootstrap()
        let windowID = try #require(state.windows.first?.id)
        #expect(state.showsCoordinatorChat(windowID: windowID) == false)
        var coordinator = WorkspaceState.bootstrap(title: "Coordinator")
        coordinator.isCoordinator = true
        state.workspacesByID[coordinator.id] = coordinator
        state.windows[0].workspaceIDs.append(coordinator.id)
        state.windows[0].selectedWorkspaceID = coordinator.id
        #expect(state.showsCoordinatorChat(windowID: windowID))
        #expect(state.coversWorkspaceContent(windowID: windowID))

        let reducer = AppReducer()
        #expect(reducer.send(.setCoordinatorTerminalShown(windowID: windowID, shown: true), state: &state))
        #expect(state.showsCoordinatorChat(windowID: windowID) == false)
        #expect(state.coversWorkspaceContent(windowID: windowID) == false)
        #expect(reducer.send(.setCoordinatorTerminalShown(windowID: windowID, shown: true), state: &state) == false)

        // The flag is not saved: a relaunch shows the chat again.
        let decoded = try JSONDecoder().decode(WindowState.self, from: JSONEncoder().encode(state.windows[0]))
        #expect(decoded.showsCoordinatorTerminal == false)
    }
}
