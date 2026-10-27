import CoreState
import Foundation
import Testing

struct CoordinatorEventTests {
    private let at = Date(timeIntervalSince1970: 1_792_800_000)

    @Test func aProjectQuestionNeedsChoicesButNoTask() throws {
        let question = try CoordinatorEvent.validated(kind: "question", taskID: nil,
            text: "Which project is dark mode for?\nTwo projects have settings.", sessionID: nil, at: at,
            options: [" /repos/app ", "/repos/site"])
        #expect(question.taskID == nil && question.options == ["/repos/app", "/repos/site"])
        #expect(CoordinatorEvent.decodeLog(try question.jsonLine()) == [question])
        #expect(throws: CoordinatorEventError.self) {
            try CoordinatorEvent.validated(kind: "question", taskID: nil, text: "Which project?", sessionID: nil, at: at)
        }
        let pending = CoordinatorEvent(at: at, kind: .reply, taskID: nil, text: "/repos/app", sessionID: nil,
                                       threadRole: .userCoordinator, questionID: question.id, delivery: .pending)
        #expect(CoordinatorEvent.decodeLog(try pending.jsonLine()) == [pending])
    }

    @Test
    func checksWhatEachKindNeeds() throws {
        let taskID = UUID()
        let packet = try CoordinatorEvent.validated(kind: "packet", taskID: taskID, text: nil, sessionID: "s1", at: at)
        #expect(packet.kind == .packet)
        #expect(packet.text == nil)
        let note = try CoordinatorEvent.validated(kind: " Note ", taskID: nil, text: "  Fresh session.  ", sessionID: nil, at: at)
        #expect(note.kind == .note)
        #expect(note.text == "Fresh session.")

        #expect(throws: CoordinatorEventError.self) {
            try CoordinatorEvent.validated(kind: "task-started", taskID: nil, text: nil, sessionID: nil, at: at)
        }
        #expect(throws: CoordinatorEventError.self) {
            try CoordinatorEvent.validated(kind: "question", taskID: taskID, text: "   ", sessionID: nil, at: at)
        }
        #expect(throws: CoordinatorEventError.self) {
            try CoordinatorEvent.validated(kind: "intake", taskID: taskID, text: "x", sessionID: nil, at: at)
        }
        let long = String(repeating: "a", count: CoordinatorEvent.maximumTextLength + 1)
        #expect(throws: CoordinatorEventError.self) {
            try CoordinatorEvent.validated(kind: "note", taskID: nil, text: long, sessionID: nil, at: at)
        }
    }

    @Test
    func aLogReadsBackItsWholeLinesAndSkipsACutOne() throws {
        let first = CoordinatorEvent(at: at, kind: .taskStarted, taskID: UUID(), text: nil, sessionID: "s1")
        let second = CoordinatorEvent(at: at.addingTimeInterval(5), kind: .question, taskID: UUID(), text: "Which base?", sessionID: "s1")
        var log = Data()
        for event in [first, second] {
            let line = try event.jsonLine()
            #expect(line.contains(UInt8(ascii: "\n")) == false)
            log.append(line)
            log.append(UInt8(ascii: "\n"))
        }
        log.append(Data(#"{"id":"cut"#.utf8))

        #expect(CoordinatorEvent.decodeLog(log) == [first, second])
        let text = try #require(String(data: try second.jsonLine(), encoding: .utf8))
        #expect(text.contains(#""kind":"question""#))
    }

    @Test
    func questionOptionsAreTrimmedAndBoundedBeforeTheyAreSaved() throws {
        let taskID = UUID()
        let fullLength = String(repeating: "🧭", count: CoordinatorEvent.maximumOptionLength)
        let question = try CoordinatorEvent.validated(
            kind: "question", taskID: taskID, text: "Which base?", sessionID: nil, at: at,
            options: ["  Remote main\n", fullLength]
        )
        #expect(question.options == ["Remote main", fullLength])
        for options in [
            ["  \n"],
            [String(repeating: "a", count: CoordinatorEvent.maximumOptionLength + 1)],
            (0...CoordinatorEvent.maximumOptionCount).map { "Choice \($0)" },
            ["Remote main", " Remote main "],
        ] {
            #expect(throws: CoordinatorEventError.self) {
                try CoordinatorEvent.validated(kind: "question", taskID: taskID, text: "Which base?", sessionID: nil, at: at, options: options)
            }
        }
        for kind in CoordinatorEvent.Kind.postingKinds where kind != .question {
            #expect(throws: CoordinatorEventError.self) {
                try CoordinatorEvent.validated(kind: kind.rawValue, taskID: taskID, text: "A note.", sessionID: nil, at: at, options: ["Remote main"])
            }
        }
        #expect(throws: CoordinatorEventError.self) {
            try CoordinatorEvent.validated(kind: "reply", taskID: taskID, text: "Remote main", sessionID: nil, at: at)
        }
    }

    @Test
    func legacyEventsStillDecodeAndThreadEventsSurviveARelaunch() throws {
        let legacy = Data(#"{"id":"E16787EF-5592-4FC8-A26A-D46548253CBF","at":"2026-10-23T00:00:00Z","kind":"note","text":"Checking in."}"#.utf8)
        let decoded = try #require(CoordinatorEvent.decodeLog(legacy).first)
        #expect(decoded.options.isEmpty)
        #expect(decoded.threadRole == nil && decoded.questionID == nil && decoded.sourceID == nil)

        let reply = CoordinatorEvent(
            at: at, kind: .reply, taskID: UUID(), text: "Remote main", sessionID: nil,
            threadRole: .userCoordinator, questionID: UUID(), sourceID: "turn-12"
        )
        #expect(CoordinatorEvent.decodeLog(try reply.jsonLine()) == [reply])
        let unknown = Data(#"{"id":"E16787EF-5592-4FC8-A26A-D46548253CBF","at":"2026-10-23T00:00:00Z","kind":"future"}"#.utf8)
        #expect(CoordinatorEvent.decodeLog(unknown).isEmpty)
    }

    @Test
    func malformedStoredOptionsDoNotHideTheQuestion() throws {
        let question = CoordinatorEvent(at: at, kind: .question, taskID: UUID(), text: "Which base?", sessionID: nil)
        var object = try #require(JSONSerialization.jsonObject(with: question.jsonLine()) as? [String: Any])
        object["options"] = "an older invalid value"
        let malformed = try #require(CoordinatorEvent.decodeLog(JSONSerialization.data(withJSONObject: object)).first)
        #expect(malformed.text == "Which base?" && malformed.options.isEmpty)

        object["options"] = ["  ", String(repeating: "a", count: CoordinatorEvent.maximumOptionLength + 1), " Main ", "Main"]
            + (1...7).map { "Choice \($0)" }
        let sanitized = try #require(CoordinatorEvent.decodeLog(JSONSerialization.data(withJSONObject: object)).first)
        #expect(sanitized.options == ["Main", "Choice 1", "Choice 2", "Choice 3", "Choice 4", "Choice 5"])
    }
}
