import CoreState
import Foundation
import RemoteProtocol

/// The agent's latest message, as a coordinator reads it.
struct TaskAgentReply: Equatable {
    var text: String
    /// The text was longer than `TaskAgentReplyReader.maximumTextBytes` and
    /// was cut at the end.
    var truncated: Bool
    var at: Date?
}

/// Reads an agent's last reply from its provider transcript, with the same
/// parsers the phone's conversation view uses. Only the end of the file is
/// read, and results are cached by file size and modification time, so
/// polling a task does not reread an unchanged transcript.
@MainActor
final class TaskAgentReplyReader {
    static let maximumTextBytes = 16 * 1024
    /// Most transcripts end with the reply in this much; a long tool result
    /// after it makes the reader look further back once.
    static let tailBytes = 512 * 1024
    static let extendedTailBytes = 4 * 1024 * 1024

    private struct CacheKey: Equatable {
        var size: UInt64
        var modifiedAt: Date
    }

    private var cache: [String: (key: CacheKey, reply: TaskAgentReply?)] = [:]

    func lastReply(agent: AgentKind, transcriptPath: String) -> TaskAgentReply? {
        guard ProviderTranscriptSupport.hasFileTranscript(agent),
              let attributes = try? FileManager.default.attributesOfItem(atPath: transcriptPath),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modifiedAt = attributes[.modificationDate] as? Date else {
            return nil
        }
        let key = CacheKey(size: size, modifiedAt: modifiedAt)
        if let cached = cache[transcriptPath], cached.key == key {
            return cached.reply
        }
        var reply = Self.readReply(agent: agent, path: transcriptPath, size: size, tailBytes: Self.tailBytes)
        if reply == nil, size > UInt64(Self.tailBytes) {
            reply = Self.readReply(agent: agent, path: transcriptPath, size: size, tailBytes: Self.extendedTailBytes)
        }
        cache[transcriptPath] = (key, reply)
        return reply
    }

    /// The last reply in observations a provider extension published, for
    /// agents without a transcript file.
    static func lastReply(in observations: [ProviderTranscriptObservation]) -> TaskAgentReply? {
        for observation in observations.reversed() {
            if let reply = reply(from: observation) { return reply }
        }
        return nil
    }

    static func lastReply(agent: AgentKind, inTranscript contents: String, startsMidLine: Bool) -> TaskAgentReply? {
        guard var parser = ProviderTranscriptSupport.makeParser(for: agent) else { return nil }
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        // A tail read usually starts inside a line.
        if startsMidLine, lines.isEmpty == false { lines.removeFirst() }
        var last: TaskAgentReply?
        for line in lines {
            for observation in parser.parseLine(String(line)) {
                if let reply = reply(from: observation) { last = reply }
            }
        }
        return last
    }

    private static func readReply(agent: AgentKind, path: String, size: UInt64, tailBytes: Int) -> TaskAgentReply? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        do {
            try handle.seek(toOffset: start)
            guard let data = try handle.readToEnd() else { return nil }
            let contents = String(decoding: data, as: UTF8.self)
            return lastReply(agent: agent, inTranscript: contents, startsMidLine: start > 0)
        } catch {
            return nil
        }
    }

    private static func reply(from observation: ProviderTranscriptObservation) -> TaskAgentReply? {
        guard case .transcript(.assistantMessage(let message)) = observation.payload else { return nil }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return nil }
        let (capped, truncated) = cap(text)
        return TaskAgentReply(text: capped, truncated: truncated, at: observation.timestamp)
    }

    /// Keeps the start of a long reply, where agents put their result.
    static func cap(_ text: String) -> (String, Bool) {
        guard text.utf8.count > maximumTextBytes else { return (text, false) }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: maximumTextBytes)
        while String.Index(end, within: text) == nil {
            end = text.utf8.index(before: end)
        }
        return (String(text[..<end]), true)
    }
}
