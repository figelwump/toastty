import CoreState
import Foundation

/// Unanswered Codex questions, read from each active Codex session's rollout.
///
/// Codex (0.163+) asks through the async `request_user_input_async` tool: the
/// call returns `{"accepted":true}` at once and the turn keeps working while
/// the question waits in Codex's UI, so hooks report the session as working
/// throughout and the shared `CodexSessionLogWatcher` (which knows the older
/// blocking `request_user_input` event) never sees it. The answer comes back
/// as a user message wrapped in `<send_user_message_question_reply>` whose
/// `questionItemId` names the call. Any other user message also ends the
/// wait: the user is back at the terminal.
///
/// Linux-only (macOS has the same gap; the shared watcher would be the place
/// to fix it there). Polls once a second; the first read of a rollout covers
/// at most its last `initialScanLimit` bytes and raises no notifications.
@MainActor
final class CodexPendingQuestionMonitor {
    struct Question: Equatable, Sendable {
        let callID: String
        let title: String
    }

    struct Target: Equatable, Sendable {
        let sessionID: String
        let panelID: UUID
        let workspaceID: UUID
        let rolloutURL: URL
    }

    enum Observation: Equatable, Sendable {
        case asked(Question)
        case answered(callIDs: [String])
        case userMessage
    }

    nonisolated static let initialScanLimit: UInt64 = 8 << 20
    nonisolated static let replyTag = "<send_user_message_question_reply>"

    private struct Tail {
        let target: Target
        var offset: UInt64
        var partialLine = Data()
        var pending: [Question] = []
    }

    private var tails: [String: Tail] = [:]
    private var timer: DispatchSourceTimer?
    private let targets: @MainActor () -> [Target]
    private let onChange: @MainActor () -> Void
    private let onQuestionAsked: @MainActor (Target, Question) -> Void

    init(
        targets: @escaping @MainActor () -> [Target],
        onChange: @escaping @MainActor () -> Void,
        onQuestionAsked: @escaping @MainActor (Target, Question) -> Void
    ) {
        self.targets = targets
        self.onChange = onChange
        self.onQuestionAsked = onQuestionAsked
    }

    func start(interval: TimeInterval = 1) {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// The oldest unanswered question of `sessionID`.
    func pendingQuestion(sessionID: String) -> Question? {
        tails[sessionID]?.pending.first
    }

    func poll() {
        var current: [String: Target] = [:]
        for target in targets() where current[target.sessionID] == nil {
            current[target.sessionID] = target
        }
        var changed = false
        for (sessionID, tail) in tails where current[sessionID] != tail.target {
            tails[sessionID] = nil
            changed = changed || tail.pending.isEmpty == false
        }
        var asked: [(Target, Question)] = []
        for (sessionID, target) in current {
            var tail: Tail
            let isInitialRead: Bool
            if let existing = tails[sessionID] {
                tail = existing
                isInitialRead = false
            } else {
                guard let size = Self.fileSize(target.rolloutURL) else { continue }
                tail = Tail(target: target, offset: size > Self.initialScanLimit ? size - Self.initialScanLimit : 0)
                isInitialRead = true
            }
            if let size = Self.fileSize(target.rolloutURL), size < tail.offset {
                // Replaced or truncated: start over from its tail.
                tail = Tail(target: target, offset: size > Self.initialScanLimit ? size - Self.initialScanLimit : 0)
            }
            let skipsFirstLine = isInitialRead && tail.offset > 0
            guard let data = Self.read(target.rolloutURL, from: tail.offset) else {
                tails[sessionID] = tail
                continue
            }
            tail.offset += UInt64(data.count)
            var buffer = tail.partialLine + data
            if let lastNewline = buffer.lastIndex(of: 0x0A) {
                tail.partialLine = Data(buffer[buffer.index(after: lastNewline)...])
                buffer = Data(buffer[..<lastNewline])
            } else {
                tail.partialLine = buffer
                buffer = Data()
            }
            let before = tail.pending
            var lines = String(decoding: buffer, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
            if skipsFirstLine, lines.isEmpty == false { lines.removeFirst() }
            for line in lines {
                guard let observation = Self.observation(in: line) else { continue }
                Self.apply(observation, to: &tail.pending)
            }
            tails[sessionID] = tail
            if tail.pending != before {
                changed = true
                if isInitialRead == false {
                    asked += tail.pending.filter { before.contains($0) == false }.map { (target, $0) }
                }
            }
        }
        if changed { onChange() }
        for (target, question) in asked { onQuestionAsked(target, question) }
    }

    nonisolated static func apply(_ observation: Observation, to pending: inout [Question]) {
        switch observation {
        case .asked(let question):
            if pending.contains(where: { $0.callID == question.callID }) == false {
                pending.append(question)
            }
        case .answered(let callIDs):
            pending.removeAll { callIDs.contains($0.callID) }
        case .userMessage:
            pending.removeAll()
        }
    }

    /// What one rollout line says about questions, if anything.
    nonisolated static func observation(in line: Substring) -> Observation? {
        guard line.contains("request_user_input_async") || line.contains("\"UserMessage\"") else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return nil }
        switch (object["type"] as? String, payload["type"] as? String) {
        case ("response_item", "function_call"):
            guard payload["name"] as? String == "request_user_input_async",
                  let callID = payload["call_id"] as? String else { return nil }
            return .asked(Question(callID: callID, title: questionTitle(arguments: payload["arguments"] as? String)))
        case ("event_msg", "item_completed"):
            guard let item = payload["item"] as? [String: Any], item["type"] as? String == "UserMessage" else { return nil }
            let text = ((item["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
            guard text.contains(replyTag) else { return .userMessage }
            let callIDs = answeredCallIDs(reply: text)
            return callIDs.isEmpty ? .userMessage : .answered(callIDs: callIDs)
        default:
            return nil
        }
    }

    nonisolated static func questionTitle(arguments: String?) -> String {
        let fallback = "Codex is asking a question"
        guard let arguments,
              let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
              let questions = object["questions"] as? [[String: Any]],
              let first = (questions.first?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              first.isEmpty == false else { return fallback }
        return questions.count > 1 ? "\(first) (+\(questions.count - 1) more)" : first
    }

    /// Call IDs from `questionItemId`s like `["request_user_input_async","call_…",0]`.
    nonisolated static func answeredCallIDs(reply: String) -> [String] {
        guard let start = reply.range(of: replyTag) else { return [] }
        var body = reply[start.upperBound...]
        if let end = body.range(of: "</send_user_message_question_reply>") { body = body[..<end.lowerBound] }
        guard let answers = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]] else { return [] }
        return answers.compactMap { answer in
            guard let itemID = answer["questionItemId"] as? String,
                  let parts = try? JSONSerialization.jsonObject(with: Data(itemID.utf8)) as? [Any],
                  parts.count >= 2 else { return nil }
            return parts[1] as? String
        }
    }

    nonisolated private static func fileSize(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }

    nonisolated private static func read(_ url: URL, from offset: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        guard let data = try? handle.readToEnd(), data.isEmpty == false else { return nil }
        return data
    }
}
