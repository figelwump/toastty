import Foundation
import Testing
@testable import ToasttyAppLogic

/// Codex's async questions (`request_user_input_async`) in its rollout,
/// in the line shapes Codex 0.163 writes: the question call, its answer as a
/// `<send_user_message_question_reply>` user message, and a typed prompt.
@Suite(.serialized)
@MainActor
struct LinuxCodexQuestionTests {
    static func questionLine(callID: String, titles: [String]) -> String {
        let questions = titles.map { ["title": $0, "options": ["Yes", "No"]] as [String: Any] }
        let arguments = String(decoding: try! JSONSerialization.data(withJSONObject: ["questions": questions]), as: UTF8.self)
        return json([
            "timestamp": "2026-10-22T17:19:10.070Z",
            "type": "response_item",
            "payload": [
                "type": "function_call", "status": "completed", "name": "request_user_input_async",
                "arguments": arguments, "call_id": callID,
            ] as [String: Any],
        ])
    }

    static func userMessageLine(_ text: String) -> String {
        json([
            "timestamp": "2026-10-22T17:20:33.750Z",
            "type": "event_msg",
            "payload": [
                "type": "item_completed",
                "item": ["type": "UserMessage", "content": [["type": "text", "text": text]]] as [String: Any],
            ] as [String: Any],
        ])
    }

    static func replyLine(callID: String, answer: String) -> String {
        let itemID = "[\"request_user_input_async\",\"\(callID)\",0]"
        let answers = String(decoding: try! JSONSerialization.data(withJSONObject: [
            ["answer": answer, "question": "Which pose?", "questionItemId": itemID],
        ]), as: UTF8.self)
        return userMessageLine("<send_user_message_question_reply>\n\(answers)\n</send_user_message_question_reply>")
    }

    static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @Test func parsesQuestionsAnswersAndPrompts() {
        let asked = CodexPendingQuestionMonitor.observation(in: Substring(Self.questionLine(callID: "call_a", titles: ["Which pose?", "Which mode?"])))
        #expect(asked == .asked(.init(callID: "call_a", title: "Which pose? (+1 more)")))
        #expect(CodexPendingQuestionMonitor.observation(in: Substring(Self.replyLine(callID: "call_a", answer: "Rest"))) == .answered(callIDs: ["call_a"]))
        #expect(CodexPendingQuestionMonitor.observation(in: Substring(Self.userMessageLine("Move waypoints to settings"))) == .userMessage)
        // The question's echo as an agent message and unrelated lines say nothing.
        #expect(CodexPendingQuestionMonitor.observation(in: #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"call_a"}}}"#) == nil)
        #expect(CodexPendingQuestionMonitor.observation(in: #"{"type":"response_item","payload":{"type":"function_call","name":"exec"}}"#) == nil)
    }

    @Test func monitorTracksQuestionsAndNotifiesOnlyForNewOnes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-questions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rollout = directory.appendingPathComponent("rollout.jsonl")
        // Already waiting when Toastty attaches: shown, but not notified.
        try (Self.questionLine(callID: "call_old", titles: ["Old question?"]) + "\n").write(to: rollout, atomically: true, encoding: .utf8)

        let target = CodexPendingQuestionMonitor.Target(sessionID: "s1", panelID: UUID(), workspaceID: UUID(), rolloutURL: rollout)
        var targets = [target]
        var changes = 0
        var asked: [String] = []
        let monitor = CodexPendingQuestionMonitor(
            targets: { targets },
            onChange: { changes += 1 },
            onQuestionAsked: { _, question in asked.append(question.callID) }
        )
        func append(_ line: String) throws {
            let handle = try FileHandle(forWritingTo: rollout)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
            try handle.close()
        }

        monitor.poll()
        #expect(monitor.pendingQuestion(sessionID: "s1")?.title == "Old question?")
        #expect(asked.isEmpty && changes == 1)

        try append(Self.replyLine(callID: "call_old", answer: "Yes"))
        try append(Self.questionLine(callID: "call_new", titles: ["New question?"]))
        monitor.poll()
        #expect(monitor.pendingQuestion(sessionID: "s1")?.callID == "call_new")
        #expect(asked == ["call_new"])

        // A line still being written is held until its newline arrives.
        let reply = Self.replyLine(callID: "call_new", answer: "No")
        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(reply.prefix(40).utf8))
        try handle.close()
        monitor.poll()
        #expect(monitor.pendingQuestion(sessionID: "s1")?.callID == "call_new")
        try append(String(reply.dropFirst(40)))
        monitor.poll()
        #expect(monitor.pendingQuestion(sessionID: "s1") == nil)

        // A typed prompt ends the wait too; a session that ends drops its questions.
        try append(Self.questionLine(callID: "call_3", titles: ["Third?"]))
        try append(Self.userMessageLine("Never mind, do something else"))
        monitor.poll()
        #expect(monitor.pendingQuestion(sessionID: "s1") == nil)
        try append(Self.questionLine(callID: "call_4", titles: ["Fourth?"]))
        monitor.poll()
        #expect(monitor.pendingQuestion(sessionID: "s1")?.callID == "call_4")
        targets = []
        monitor.poll()
        #expect(monitor.pendingQuestion(sessionID: "s1") == nil)
        #expect(asked == ["call_new", "call_4"])
    }
}
