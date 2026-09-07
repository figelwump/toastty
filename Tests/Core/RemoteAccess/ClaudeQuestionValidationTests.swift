import Foundation
import RemoteProtocol
import Testing
@testable import CoreState

struct ClaudeQuestionValidationTests {
    private static let questions = [
        RemoteInteractionQuestion(id: "q1", header: "Approach", question: "Which approach?", options: [
            .init(id: "a", label: "Small, focused", preview: "<script>inert</script>"),
            .init(id: "b", label: "Broad"),
        ]),
        RemoteInteractionQuestion(id: "q2", header: "Checks", question: "Which checks?", options: [
            .init(id: "a", label: "Unit"), .init(id: "b", label: "UI"),
        ], multiSelect: true),
    ]

    @Test func canonicalAnswersUseSnapshotOrderAndProviderLabels() throws {
        let answers: [RemoteInteractionAnswer] = [
            .init(questionID: "q2", selectedOptionIDs: ["b", "a"]),
            .init(questionID: "q1", selectedOptionIDs: ["a"]),
        ]
        let canonical = try #require(ClaudeQuestionValidation.canonicalAnswers(answers, for: Self.questions))
        #expect(canonical.map(\.questionID) == ["q1", "q2"])
        #expect(canonical[1].selectedOptionIDs == ["a", "b"])
        #expect(ClaudeQuestionValidation.providerAnswers(answers, for: Self.questions) == [
            "Which approach?": "Small, focused", "Which checks?": "Unit, UI",
        ])
    }

    @Test func rejectsPartialUnknownDuplicateAndConflictingSingleAnswers() {
        let second = RemoteInteractionAnswer(questionID: "q2", selectedOptionIDs: ["a"])
        let invalid: [[RemoteInteractionAnswer]] = [
            [second],
            [.init(questionID: "unknown", selectedOptionIDs: ["a"]), second],
            [.init(questionID: "q1", selectedOptionIDs: ["missing"]), second],
            [.init(questionID: "q1", selectedOptionIDs: ["a", "a"]), second],
            [.init(questionID: "q1", selectedOptionIDs: ["a", "b"]), second],
            [.init(questionID: "q1", selectedOptionIDs: ["a"], text: "Also"), second],
            [second, second],
        ]
        for answers in invalid {
            #expect(ClaudeQuestionValidation.canonicalAnswers(answers, for: Self.questions) == nil)
        }
    }

    @Test func boundsCustomTextAndAllowsMultiline() {
        let second = RemoteInteractionAnswer(questionID: "q2", selectedOptionIDs: ["a"], text: "Other check")
        #expect(ClaudeQuestionValidation.providerAnswers([
            .init(questionID: "q1", text: "  My\nchoice  "), second,
        ], for: Self.questions) == ["Which approach?": "My\nchoice", "Which checks?": "Unit, Other check"])
        #expect(ClaudeQuestionValidation.providerAnswers([
            .init(questionID: "q1", text: "Build it 👩‍💻"), second,
        ], for: Self.questions)?["Which approach?"] == "Build it 👩‍💻")
        for text in [" ", "bad\u{0000}text", String(repeating: "x", count: 8193)] {
            #expect(ClaudeQuestionValidation.canonicalAnswers([
                .init(questionID: "q1", text: text), second,
            ], for: Self.questions) == nil)
        }
    }

    @Test func completionPreservesCommaLabelsAndOpaqueCustomText() throws {
        let answers = try #require(ClaudeQuestionValidation.answersFromProvider([
            "Which approach?": "Small, focused", "Which checks?": "Unit, then verify everything",
        ], for: Self.questions))
        #expect(answers[0].selectedOptionIDs == ["a"])
        #expect(answers[1].selectedOptionIDs.isEmpty)
        #expect(answers[1].text == "Unit, then verify everything")
    }

    @Test func rejectsAmbiguousQuestionAndOptionShapes() {
        #expect(!ClaudeQuestionValidation.validateQuestions([]))
        #expect(!ClaudeQuestionValidation.validateQuestions(Array(repeating: Self.questions[0], count: 5)))
        var questions = Self.questions
        questions[1].question = questions[0].question
        #expect(!ClaudeQuestionValidation.validateQuestions(questions))
        questions = Self.questions
        questions[0].options[1].label = questions[0].options[0].label
        #expect(!ClaudeQuestionValidation.validateQuestions(questions))
    }

    @Test func additiveFieldsDecodeOlderInteractionAndRoundTripNewEvents() throws {
        let old = RemotePendingInteraction(id: .init(rawValue: "claude:call:1"), kind: .permission,
            prompt: "Approval", inputEpoch: .init(bindingID: UUID(), counter: 0), presentedAt: Date())
        let encoder = ConversationEventCoding.makeEncoder()
        let decoder = ConversationEventCoding.makeDecoder()
        let decoded = try decoder.decode(RemotePendingInteraction.self, from: encoder.encode(old))
        #expect(decoded.questions == nil)
        #expect(decoded.responseID == nil)
        for payload: ConversationEventPayload in [
            .interactionResponseClosed(.init(interactionID: old.id, reason: .expired)),
            .interactionResolved(.init(interactionID: old.id, resolution: .resolved,
                answers: [.init(questionID: "q1", text: "Custom")])),
        ] {
            #expect(try decoder.decode(ConversationEventPayload.self, from: encoder.encode(payload)) == payload)
        }
    }
}
