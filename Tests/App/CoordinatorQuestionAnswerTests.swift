import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

/// Answers to the coordinator's question cards from outside its chat, as
/// `coordinator.answer-question` gives them: through Toastty's question
/// hook to Claude, the path of the chat's own card.
@MainActor
struct CoordinatorQuestionAnswerTests {
    /// Claude receives such an answer after the sender's line, also for a
    /// choice, so the coordinator never reads it as the user's. The answer
    /// names the card it is for, so it never lands on the card that Claude
    /// asks after it.
    @Test func anAnswerFromOutsideTheChatCarriesItsSenderAndNamesItsCard() async throws {
        let fixture = try CoordinatorChatFixture(agent: .claude)
        defer { fixture.tearDown() }
        let conversations = fixture.conversations
        let sessions = conversations.sessionRuntimeStore
        let controller = fixture.controller
        let questions = [RemoteInteractionQuestion(
            id: "q0", header: "Projects", question: "2 of 5 · Projects. Save these projects?",
            options: [.init(id: "yes", label: "Yes (suggested)"), .init(id: "later", label: "Later")]
        )]

        func hook(
            _ phase: ClaudeQuestionHookRequest.Phase,
            _ event: ClaudeQuestionHookEvent.EventName,
            call: String,
            responseID: String? = nil,
            answers: [String: String]? = nil
        ) -> ClaudeQuestionHookRequest {
            .init(phase: phase, sessionID: conversations.sessionID, panelID: conversations.panelID,
                  event: .init(eventName: event, nativeSessionID: conversations.resumeRecord.nativeSessionID,
                               promptID: "prompt", transcriptPath: conversations.resumeRecord.sessionFilePath,
                               providerCallID: phase == .observe ? call : nil, questions: questions, answers: answers),
                  responseID: responseID)
        }
        /// Claude asks the card, and Toastty's hook holds it.
        func ask(_ call: String) -> String {
            let responseID = UUID().uuidString
            #expect(sessions.handleClaudeQuestion(hook(.observe, .preToolUse, call: call), at: Date()).status == .observed)
            #expect(sessions.handleClaudeQuestion(
                hook(.begin, .permissionRequest, call: call, responseID: responseID), at: Date()
            ).status == .pending)
            return responseID
        }
        /// What the hook gives Claude for the card, as Claude reads it.
        func received(_ responseID: String) -> String? {
            let reply = sessions.handleClaudeQuestion(.init(
                phase: .poll, sessionID: conversations.sessionID, panelID: conversations.panelID, responseID: responseID
            ), at: Date())
            return reply.answers.flatMap { ClaudeQuestionValidation.providerAnswers($0, for: questions) }?[questions[0].question]
        }
        func refusal(_ body: () throws -> Void) -> String? {
            do {
                try body()
                return nil
            } catch let error as CoordinatorError {
                return error.message
            } catch {
                return "\(error)"
            }
        }

        #expect(controller.openQuestion() == nil)
        let first = ask("call-1")
        let open = try #require(controller.openQuestion())
        #expect(open == .init(card: "claude:call:call-1", header: "Projects",
                              question: questions[0].question, options: ["Yes (suggested)", "Later"]))

        // A task's agent picks a choice. The case of the label may differ.
        let taskID = UUID()
        let fromTask = CoordinatorMessageHeader.Sender.task(id: taskID, title: "Fix the unread dot")
        #expect(refusal { _ = try controller.answerOpenQuestion(card: "claude:call:other", option: "Later", text: nil, from: fromTask) }?
            .contains("another one: claude:call:call-1") == true)
        #expect(refusal { _ = try controller.answerOpenQuestion(card: open.card, option: "Maybe", text: nil, from: fromTask) }?
            .contains("no choice \"Maybe\"") == true)
        #expect(received(first) == nil)
        let answer = try controller.answerOpenQuestion(card: open.card, option: "yes (SUGGESTED)", text: nil, from: fromTask)
        let taskLine = "[Toastty] From task [Fix the unread dot](toastty://task/\(taskID.uuidString)): not from the user."
        #expect(answer.chosenOption == "Yes (suggested)")
        #expect(answer.answer == taskLine + "\nYes (suggested)")
        // Claude gets the line too, not the bare choice, which would read
        // as the user's click.
        let claudeRead = try #require(received(first))
        #expect(claudeRead == taskLine + "\nYes (suggested)")
        #expect(CoordinatorMessageHeader.senderParts(of: claudeRead)?.sender == "task Fix the unread dot")

        // Claude takes the answer and asks the next card. An answer that
        // names the card before it is refused.
        #expect(sessions.handleClaudeQuestion(hook(
            .observe, .postToolUse, call: "call-1", answers: [questions[0].question: claudeRead]
        ), at: Date()).status == .observed)
        #expect(controller.openQuestion() == nil)
        let second = ask("call-2")
        #expect(controller.openQuestion()?.card == "claude:call:call-2")
        #expect(refusal { _ = try controller.answerOpenQuestion(card: open.card, option: "Later", text: nil, from: fromTask) }?
            .contains("another one: claude:call:call-2") == true)
        #expect(received(second) == nil)

        // A caller that names no session answers in its own words.
        let typed = try controller.answerOpenQuestion(
            card: "claude:call:call-2", option: nil, text: "  Build the billing page first.\n", from: .unknown
        )
        #expect(typed.chosenOption == nil)
        #expect(received(second)
            == "[Toastty] From a terminal command: Toastty cannot tell who ran it.\nBuild the billing page first.")
        #expect(typed.answer == received(second))

        // Without a sender, the answer is the user's, as the live check's
        // test instance gives it: a choice reaches Claude as the chat
        // card's click does, with no line.
        #expect(sessions.handleClaudeQuestion(hook(
            .observe, .postToolUse, call: "call-2", answers: [questions[0].question: received(second) ?? ""]
        ), at: Date()).status == .observed)
        let third = ask("call-3")
        let asUser = try controller.answerOpenQuestion(card: "claude:call:call-3", option: "later", text: nil, from: nil)
        #expect(asUser.chosenOption == "Later")
        #expect(asUser.answer == "Later")
        #expect(received(third) == "Later")
    }
}
