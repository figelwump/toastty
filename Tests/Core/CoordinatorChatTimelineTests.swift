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
    func aTaskKeepsOneCardWithItsLatestContentAndAllPacketVersions() {
        let started = event(.taskStarted, at: 0, task: taskID)
        let posted = event(.packet, at: 100, task: taskID)
        let cards = CoordinatorChatTimeline.cards(
            events: [started, posted],
            packets: [taskID: [stamp(2, at: 90), stamp(1, at: 50)]]
        )
        #expect(cards.count == 1)
        #expect(cards[0].id == posted.id.uuidString)
        #expect(cards[0].kind == .packet)
        #expect(cards[0].packetVersion == 2)
        #expect(cards[0].packetVersions == [1, 2])
        #expect(cards[0].isCurrent && cards[0].isNew && cards[0].superseded == false)
    }

    @Test
    func aNewPacketMovesTheTaskAfterIndependentNotesAndPromotesItsContent() {
        let started = event(.taskStarted, at: 100, task: taskID)
        let note = event(.note, at: 150, text: "Checking in.")
        let cards = CoordinatorChatTimeline.cards(
            events: [started, note],
            packets: [taskID: [stamp(2, at: 200), stamp(1, at: 90)]]
        )
        #expect(cards.count == 2)
        #expect(cards[0].id == note.id.uuidString)
        #expect(cards[1].kind == .packet && cards[1].text == nil)
        #expect(cards[1].packetVersion == 2 && cards[1].packetVersions == [1, 2])
        #expect(cards[1].at == start.addingTimeInterval(200))
        #expect(cards[1].thread.isEmpty)
        #expect(cards[1].isNew && cards[1].superseded == false)
    }

    @Test
    func anUnansweredTaskQuestionStaysVisibleWhenANewerPacketArrives() {
        let question = CoordinatorEvent(
            at: start.addingTimeInterval(10), kind: .question, taskID: taskID, text: "Ship it?", sessionID: nil,
            options: ["Yes", "No"]
        )
        let packet = event(.packet, at: 40, task: taskID)
        for events in [[question], [question, packet]] {
            let cards = CoordinatorChatTimeline.cards(
                events: events, packets: [taskID: [stamp(1, at: 5), stamp(2, at: 50)]]
            )
            #expect(cards.count == 1 && cards[0].kind == .question)
            #expect(cards[0].id == question.id.uuidString && cards[0].text == "Ship it?")
            #expect(cards[0].options == ["Yes", "No"] && cards[0].answer == nil)
            #expect(cards[0].at == start.addingTimeInterval(50))
            #expect(cards[0].packetVersion == 2 && cards[0].packetVersions == [1, 2] && cards[0].isNew)
            #expect(cards[0].thread.isEmpty)
        }
    }

    @Test
    func anUnansweredTaskQuestionStaysVisibleAfterALaterStartAndPacket() {
        let question = event(.question, at: 10, task: taskID, text: "Continue?")
        let started = event(.taskStarted, at: 30, task: taskID)
        let cards = CoordinatorChatTimeline.cards(
            events: [question, started], packets: [taskID: [stamp(1, at: 5), stamp(2, at: 50)]]
        )
        #expect(cards.count == 1 && cards[0].kind == .question)
        #expect(cards[0].id == question.id.uuidString && cards[0].text == "Continue?" && cards[0].answer == nil)
        #expect(cards[0].at == start.addingTimeInterval(50) && cards[0].packetVersion == 2)
        #expect(cards[0].thread.isEmpty)
    }

    @Test
    func aNewerPacketCanReplaceAnAnsweredTaskQuestion() {
        let question = event(.question, at: 10, task: taskID, text: "Ship it?")
        let reply = CoordinatorEvent(
            at: start.addingTimeInterval(20), kind: .reply, taskID: taskID, text: "Yes", sessionID: nil,
            threadRole: .userTask, questionID: question.id
        )
        let cards = CoordinatorChatTimeline.cards(
            events: [question, reply], packets: [taskID: [stamp(1, at: 50)]]
        )
        #expect(cards.count == 1 && cards[0].kind == .packet && cards[0].packetVersion == 1)
        #expect(cards[0].at == start.addingTimeInterval(50))
        #expect(cards[0].thread.map(\.text) == ["Ship it?", "Yes"])
    }

    @Test
    func newerQuestionsKeepLatestPacketAndReplacedQuestionsInTheThread() {
        let first = event(.question, at: 10, task: taskID, text: "Which base?")
        let reply = CoordinatorEvent(
            at: start.addingTimeInterval(20), kind: .reply, taskID: taskID, text: "Main", sessionID: nil,
            threadRole: .userCoordinator, questionID: first.id
        )
        let newest = CoordinatorEvent(
            at: start.addingTimeInterval(100), kind: .question, taskID: taskID, text: "Ship it?", sessionID: nil,
            options: ["Yes", "No"]
        )
        let cards = CoordinatorChatTimeline.cards(
            events: [first, reply, newest], packets: [taskID: [stamp(1, at: 50), stamp(2, at: 80)]]
        )
        #expect(cards.count == 1)
        #expect(cards[0].id == newest.id.uuidString && cards[0].kind == .question)
        #expect(cards[0].text == "Ship it?" && cards[0].options == ["Yes", "No"])
        #expect(cards[0].answer == nil)
        #expect(cards[0].packetVersion == 2 && cards[0].packetVersions == [1, 2])
        #expect(cards[0].thread.map(\.text) == ["Which base?", "Main"])
        #expect(cards[0].thread.map(\.role) == [.coordinator, .userCoordinator])
    }

    /// Older builds saved each task agent's messages into the log. They
    /// still decode, but no longer show, move, anchor or crowd a card.
    @Test
    func legacyAgentMessagesStayOutOfCards() throws {
        let question = event(.question, at: 0, task: taskID, text: "Which base?")
        let answer = CoordinatorEvent(
            at: start.addingTimeInterval(10), kind: .reply, taskID: taskID, text: "Main", sessionID: nil,
            threadRole: .userTask, questionID: question.id, sourceID: "reply-1"
        )
        let note = event(.note, at: 20, task: taskID, text: "Sent to the task.")
        func agent(_ seconds: TimeInterval, task: UUID? = nil) -> CoordinatorEvent {
            CoordinatorEvent(at: start.addingTimeInterval(seconds), kind: .reply, taskID: task ?? taskID,
                             text: "Agent message \(Int(seconds))", sessionID: nil, threadRole: .agent,
                             sourceID: "task:\(Int(seconds))")
        }
        let agentOnlyTask = UUID()
        let agents = (0...CoordinatorChatTimeline.maximumThreadEntries).map { agent(30 + TimeInterval($0)) }
        var data = Data()
        for event in [question, answer, note, agent(500, task: agentOnlyTask)] + agents {
            data.append(try event.jsonLine())
            data.append(UInt8(ascii: "\n"))
        }
        let events = CoordinatorEvent.decodeLog(data)
        #expect(events.filter { $0.threadRole == .agent }.count == agents.count + 1)
        #expect(!agent(1).canAnchorTaskCard)
        let cards = CoordinatorChatTimeline.cards(events: events, packets: [:])
        #expect(cards.map(\.taskID) == [taskID], "a task with only agent messages has no card")
        #expect(cards[0].answer == "Main")
        #expect(cards[0].at == note.at)
        #expect(cards[0].thread.map(\.role) == [.userTask, .coordinator])
    }

    @Test
    func notesAndRepliesMoveTheTaskButPreserveItsQuestionAndAnswer() throws {
        let question = CoordinatorEvent(
            at: start, kind: .question, taskID: taskID, text: "Which base?", sessionID: nil,
            options: ["Main", "Feature"]
        )
        let note = event(.note, at: 10, task: taskID, text: "I checked both branches.")
        let reply = CoordinatorEvent(
            at: start.addingTimeInterval(20), kind: .reply, taskID: taskID, text: "Feature", sessionID: nil,
            threadRole: .userCoordinator, questionID: question.id, sourceID: "user-turn"
        )
        let standalone = event(.note, at: 30, text: "Checking other tasks.")
        let later = event(.note, at: 40, task: taskID, text: "The branch is ready.")
        var data = Data()
        for event in [question, note, reply, standalone, later] {
            data.append(try event.jsonLine())
            data.append(UInt8(ascii: "\n"))
        }
        let cards = CoordinatorChatTimeline.cards(events: CoordinatorEvent.decodeLog(data), packets: [:])
        #expect(cards.map(\.id) == [standalone.id.uuidString, question.id.uuidString])
        #expect(cards[1].kind == .question && cards[1].text == "Which base?")
        #expect(cards[1].options == ["Main", "Feature"] && cards[1].answer == "Feature")
        #expect(cards[1].at == later.at)
        #expect(cards[1].thread.map(\.text) == ["I checked both branches.", "Feature", "The branch is ready."])
        #expect(cards[1].thread.map(\.role) == [.coordinator, .userCoordinator, .coordinator])
        #expect(cards.map(\.isCurrent) == [false, true])
        #expect(cards[0].thread.isEmpty)
    }

    @Test
    func aScopedNoteDoesNotReplacePacketContent() {
        let packet = event(.packet, at: 10, task: taskID)
        let note = event(.note, at: 30, task: taskID, text: "Review the tests too.")
        let cards = CoordinatorChatTimeline.cards(events: [packet, note], packets: [taskID: [stamp(1, at: 5)]])
        #expect(cards.count == 1)
        #expect(cards[0].id == packet.id.uuidString && cards[0].kind == .packet)
        #expect(cards[0].at == note.at && cards[0].packetVersion == 1)
        #expect(cards[0].thread.map(\.text) == ["Review the tests too."])
    }

    @Test
    func aNoteOnlyTaskKeepsItsPacketContentAtTheNotesTime() {
        let note = event(.note, at: 100, task: taskID, text: "Review the tests too.")
        let cards = CoordinatorChatTimeline.cards(events: [note], packets: [taskID: [stamp(1, at: 50)]])
        #expect(cards.count == 1 && cards[0].kind == .packet)
        #expect(cards[0].at == note.at && cards[0].packetVersion == 1)
        #expect(cards[0].thread.map(\.text) == ["Review the tests too."])
    }

    @Test
    func packetHistoryIncludesOldVersionsWithoutMarkingThemNewOnFirstAppearance() {
        let started = event(.taskStarted, at: 100, task: taskID)
        let cards = CoordinatorChatTimeline.cards(
            events: [started], packets: [taskID: [stamp(2, at: 20), stamp(1, at: 10)]]
        )
        #expect(cards.count == 1 && cards[0].kind == .taskStarted)
        #expect(cards[0].packetVersion == 2 && cards[0].packetVersions == [1, 2])
        #expect(cards[0].isNew == false)
    }

    @Test
    func tasksWithoutEventsAndPacketlessCardsAddNothing() {
        let other = UUID()
        let question = event(.question, at: 10, task: taskID, text: "Which base?")
        let packet = event(.packet, at: 20, task: other)
        let cards = CoordinatorChatTimeline.cards(
            events: [question, packet], packets: [UUID(): [stamp(1, at: 5)]]
        )
        #expect(cards.count == 2)
        #expect(cards.allSatisfy { $0.packetVersion == nil && $0.packetVersions.isEmpty })
        #expect(cards.allSatisfy { $0.isCurrent && $0.superseded == false })
    }

    @Test
    func onlyTheFirstMatchingUserReplyAnswersATaskQuestion() {
        let question = event(.question, at: 10, task: taskID, text: "Which base?")
        func reply(_ role: CoordinatorEvent.ThreadRole, at: TimeInterval = 20, text: String = "Main", task: UUID? = nil, questionID: UUID? = nil) -> CoordinatorEvent {
            CoordinatorEvent(
                at: start.addingTimeInterval(at), kind: .reply, taskID: task ?? taskID, text: text, sessionID: nil,
                threadRole: role, questionID: questionID ?? question.id
            )
        }
        let cards = CoordinatorChatTimeline.cards(events: [
            question,
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
    func taskRepliesWithUnacceptedDeliveryDoNotAnswerOrEnterTheThread() {
        let question = event(.question, at: 10, task: taskID, text: "Continue?")
        let unaccepted = [CoordinatorEvent.Delivery.pending, .rejected].map { delivery in
            CoordinatorEvent(
                at: start.addingTimeInterval(20), kind: .reply, taskID: taskID, text: "No", sessionID: nil,
                threadRole: .userTask, questionID: question.id, delivery: delivery
            )
        }
        let unanswered = CoordinatorChatTimeline.cards(events: [question] + unaccepted, packets: [:])
        #expect(unanswered.count == 1 && unanswered[0].answer == nil && unanswered[0].thread.isEmpty)
        #expect(unanswered[0].at == question.at)
        let accepted = CoordinatorEvent(
            at: start.addingTimeInterval(30), kind: .reply, taskID: taskID, text: "Yes", sessionID: nil,
            threadRole: .userTask, questionID: question.id, delivery: .accepted
        )
        let answered = CoordinatorChatTimeline.cards(events: [question] + unaccepted + [accepted], packets: [:])
        #expect(answered.count == 1 && answered[0].answer == "Yes")
        #expect(answered[0].thread.map(\.text) == ["Yes"])
    }

    @Test
    func matchingRepliesAnswerQuestionsEvenWhenTheirTimestampIsEarlier() {
        for task in [taskID, nil] {
            let question = CoordinatorEvent(
                at: start.addingTimeInterval(10), kind: .question, taskID: task, text: "Continue?", sessionID: nil,
                options: ["Yes", "No"]
            )
            let reply = CoordinatorEvent(
                at: start.addingTimeInterval(5), kind: .reply, taskID: task, text: "Yes", sessionID: nil,
                threadRole: .userCoordinator, questionID: question.id, delivery: .accepted
            )
            let laterReply = CoordinatorEvent(
                at: start.addingTimeInterval(20), kind: .reply, taskID: task, text: "No", sessionID: nil,
                threadRole: .userCoordinator, questionID: question.id, delivery: .accepted
            )
            let cards = CoordinatorChatTimeline.cards(events: [question, reply, laterReply], packets: [:])
            #expect(cards.count == 1 && cards[0].id == question.id.uuidString)
            #expect(cards[0].answer == "Yes" && cards[0].answerPending == false)
            #expect(cards[0].at == (task == nil ? question.at : laterReply.at))
        }
    }

    @Test
    func tasklessQuestionsAndNotesStayIndependentAndOnlyMatchingCoordinatorRepliesAnswer() {
        let question = CoordinatorEvent(
            at: start, kind: .question, taskID: nil, text: "Which project?", sessionID: nil,
            options: ["Toastty", "EmptyOS"]
        )
        let other = event(.question, at: 1, text: "Another question?")
        let note = event(.note, at: 2, text: "An independent note.")
        func reply(_ role: CoordinatorEvent.ThreadRole, text: String, task: UUID? = nil, questionID: UUID? = nil) -> CoordinatorEvent {
            CoordinatorEvent(
                at: start.addingTimeInterval(10), kind: .reply, taskID: task, text: text, sessionID: nil,
                threadRole: role, questionID: questionID ?? question.id
            )
        }
        let cards = CoordinatorChatTimeline.cards(events: [
            question, other, note,
            reply(.userTask, text: "Toastty"), reply(.agent, text: "Toastty"),
            reply(.userCoordinator, text: "Toastty", task: taskID),
            reply(.userCoordinator, text: "Toastty", questionID: UUID()),
            reply(.userCoordinator, text: "Unknown"),
            reply(.userCoordinator, text: "EmptyOS"), reply(.userCoordinator, text: "Toastty"),
        ], packets: [:])
        #expect(cards.map(\.id) == [question.id.uuidString, other.id.uuidString, note.id.uuidString])
        #expect(cards[0].answer == "EmptyOS" && cards[1].answer == nil)
        #expect(cards.allSatisfy { $0.taskID == nil && $0.isCurrent == false && $0.thread.isEmpty })
    }

    @Test
    func tasklessAnswersTrackTheLastDeliveryRecordForEachReply() {
        let question = CoordinatorEvent(
            at: start, kind: .question, taskID: nil, text: "Which project?", sessionID: nil,
            options: ["Toastty", "EmptyOS"]
        )
        let replyID = UUID()
        func reply(_ delivery: CoordinatorEvent.Delivery, at seconds: TimeInterval, sourceID: String) -> CoordinatorEvent {
            CoordinatorEvent(
                id: replyID, at: start.addingTimeInterval(seconds), kind: .reply, taskID: nil, text: "Toastty",
                sessionID: nil, threadRole: .userCoordinator, questionID: question.id, sourceID: sourceID,
                delivery: delivery
            )
        }
        let pending = reply(.pending, at: 10, sourceID: "pending")
        let accepted = reply(.accepted, at: 20, sourceID: "accepted")
        let rejected = reply(.rejected, at: 20, sourceID: "rejected")
        let waiting = CoordinatorChatTimeline.cards(events: [question, pending], packets: [:])
        #expect(waiting.count == 1 && waiting[0].answer == nil && waiting[0].answerPending)
        let sent = CoordinatorChatTimeline.cards(events: [question, accepted, pending], packets: [:])
        #expect(sent.count == 1 && sent[0].answer == "Toastty" && sent[0].answerPending == false)
        let failed = CoordinatorChatTimeline.cards(events: [question, pending, rejected], packets: [:])
        #expect(failed.count == 1 && failed[0].answer == nil && failed[0].answerPending == false)
        let raced = CoordinatorChatTimeline.cards(events: [question, pending, accepted, rejected], packets: [:])
        #expect(raced.count == 1 && raced[0].answer == "Toastty" && raced[0].answerPending == false)
        let latePending = reply(.pending, at: 30, sourceID: "late-pending")
        let pendingRace = CoordinatorChatTimeline.cards(events: [question, accepted, latePending], packets: [:])
        #expect(pendingRace[0].answer == "Toastty" && pendingRace[0].answerPending == false)
        let echoed = CoordinatorChatTimeline.cards(events: [question, pending, accepted, accepted], packets: [:])
        #expect(echoed.count == 1 && echoed[0].answer == "Toastty" && echoed[0].answerPending == false)
    }

    @Test
    func aRejectedTasklessReplyCannotBecomePendingAgain() {
        let question = CoordinatorEvent(
            at: start, kind: .question, taskID: nil, text: "Continue?", sessionID: nil, options: ["Yes", "No"]
        )
        let replyID = UUID()
        let rejected = CoordinatorEvent(
            id: replyID, at: start.addingTimeInterval(20), kind: .reply, taskID: nil, text: "Yes", sessionID: nil,
            threadRole: .userCoordinator, questionID: question.id, sourceID: "rejected", delivery: .rejected
        )
        for pendingAt in [10.0, 30.0] {
            let pending = CoordinatorEvent(
                id: replyID, at: start.addingTimeInterval(pendingAt), kind: .reply, taskID: nil, text: "Yes", sessionID: nil,
                threadRole: .userCoordinator, questionID: question.id, sourceID: "pending", delivery: .pending
            )
            for replies in [[rejected, pending], [pending, rejected]] {
                let cards = CoordinatorChatTimeline.cards(events: [question] + replies, packets: [:])
                #expect(cards.count == 1 && cards[0].answer == nil && cards[0].answerPending == false)
            }
        }
    }

    @Test
    func aRejectedTasklessAnswerAllowsALaterAnswerAndAcceptedAnswersClearPending() {
        let question = CoordinatorEvent(
            at: start, kind: .question, taskID: nil, text: "Which project?", sessionID: nil,
            options: ["Toastty", "EmptyOS"]
        )
        let rejected = CoordinatorEvent(
            at: start.addingTimeInterval(10), kind: .reply, taskID: nil, text: "Toastty", sessionID: nil,
            threadRole: .userCoordinator, questionID: question.id, delivery: .rejected
        )
        let pending = CoordinatorEvent(
            at: start.addingTimeInterval(20), kind: .reply, taskID: nil, text: "Toastty", sessionID: nil,
            threadRole: .userCoordinator, questionID: question.id, delivery: .pending
        )
        let accepted = CoordinatorEvent(
            at: start.addingTimeInterval(30), kind: .reply, taskID: nil, text: "EmptyOS", sessionID: nil,
            threadRole: .userCoordinator, questionID: question.id, delivery: .accepted
        )
        let cards = CoordinatorChatTimeline.cards(events: [question, rejected, pending, accepted], packets: [:])
        #expect(cards.count == 1 && cards[0].answer == "EmptyOS" && cards[0].answerPending == false)
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
    func eventTimesChooseContentAndFileOrderBreaksActivityTies() {
        let otherTask = UUID()
        let newest = event(.question, at: 20, task: taskID, text: "Ship it?")
        let packet = event(.packet, at: 10, task: taskID)
        let other = event(.taskStarted, at: 30, task: otherTask)
        let note = event(.note, at: 30, task: taskID, text: "Still waiting.")
        let cards = CoordinatorChatTimeline.cards(
            events: [newest, packet, other, note], packets: [taskID: [stamp(1, at: 5)]]
        )
        #expect(cards.map(\.taskID) == [otherTask, taskID])
        #expect(cards[1].id == newest.id.uuidString && cards[1].kind == .question)
        #expect(cards[1].at == note.at && cards[1].packetVersion == 1)
        #expect(cards.allSatisfy { $0.isCurrent && $0.superseded == false })
        let tiedPacket = CoordinatorChatTimeline.cards(
            events: [newest], packets: [taskID: [stamp(1, at: 20)]]
        )
        #expect(tiedPacket[0].kind == .question)
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
