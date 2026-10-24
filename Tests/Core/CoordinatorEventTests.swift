import CoreState
import Foundation
import Testing

struct CoordinatorEventTests {
    private let at = Date(timeIntervalSince1970: 1_792_800_000)

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
}
