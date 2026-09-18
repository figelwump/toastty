import Darwin
import Foundation
import RemoteProtocol

/// Where a provider CLI records the short name it generated for a session.
///
/// Neither format is documented, so both cases are read defensively: a missing
/// file, a truncated line, a renamed key, or a record for another session all
/// resolve to "no name" rather than an error. A row must never fail to draw
/// because a provider changed its bookkeeping.
enum ProviderSessionNameSource: Equatable, Sendable {
    /// Claude Code appends `{"type":"ai-title","aiTitle":…,"sessionId":…}`
    /// records to the session transcript, refreshed several times per session.
    /// The last matching record wins.
    case claudeTranscript(path: String, nativeSessionID: String)
    /// Codex appends `{"id":…,"thread_name":…,"updated_at":…}` to a thread
    /// index shared by every thread under `$CODEX_HOME`. The rollout file the
    /// hook reports does not carry the name.
    case codexThreadIndex(path: String, threadID: String)
}

/// Parsing, separated from file access so the tolerated-malformation rules are
/// directly testable.
enum ProviderSessionNameParser {
    /// Observed transcripts hold tens of `ai-title` records across a couple of
    /// megabytes, so the tail reliably carries a recent one. Reading the tail
    /// keeps the cost flat as a transcript grows.
    static let maximumClaudeTranscriptTailBytes = 512 * 1024
    /// The thread index holds roughly one record per named thread, so this
    /// ceiling covers tens of thousands of threads. Past it, the oldest
    /// records fall outside the read and those threads read as unnamed —
    /// preferable to an unbounded read of a file Toastty does not own.
    static let maximumCodexThreadIndexBytes = 8 * 1024 * 1024
    /// Provider names are short. The cap counts scalars, not grapheme
    /// clusters, so a combining-mark payload cannot slip past it.
    static let maximumNameScalarCount = 200

    static func claudeSessionName(
        inTranscriptTail tail: String,
        nativeSessionID: String
    ) -> String? {
        guard normalized(nativeSessionID) != nil else { return nil }
        var resolved: String?
        for line in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            // Cheap reject before paying for JSON: transcript lines are large
            // and almost none of them are title records.
            guard line.contains("ai-title") else { continue }
            guard let object = jsonObject(String(line)),
                  object["type"] as? String == "ai-title",
                  object["sessionId"] as? String == nativeSessionID,
                  let name = normalized(object["aiTitle"] as? String) else {
                continue
            }
            resolved = name
        }
        return resolved
    }

    static func codexThreadName(
        inIndex index: String,
        threadID: String
    ) -> String? {
        guard normalized(threadID) != nil else { return nil }
        var resolved: String?
        for line in index.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains(threadID) else { continue }
            guard let object = jsonObject(String(line)),
                  object["id"] as? String == threadID,
                  let name = normalized(object["thread_name"] as? String) else {
                continue
            }
            resolved = name
        }
        return resolved
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// A name lands in a persisted record and a one-line row, so a value with
    /// embedded newlines or control characters is treated as malformed rather
    /// than sanitized into something that looks deliberate.
    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false,
              trimmed.unicodeScalars.count <= maximumNameScalarCount,
              trimmed.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) == false }) else {
            return nil
        }
        return trimmed
    }
}

actor ProviderSessionNameReader {
    /// Resolves where to look for a bound session's generated name. Returns
    /// `nil` for providers that do not generate one.
    static func source(
        agent: AgentKind,
        nativeSessionID: String,
        sessionFilePath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryPath: String = NSHomeDirectory()
    ) -> ProviderSessionNameSource? {
        let trimmedSessionID = nativeSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSessionID.isEmpty == false else { return nil }

        switch agent {
        case .claude:
            let trimmedPath = sessionFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedPath.isEmpty == false else { return nil }
            return .claudeTranscript(path: trimmedPath, nativeSessionID: trimmedSessionID)
        case .codex:
            return .codexThreadIndex(
                path: codexThreadIndexURL(
                    environment: environment,
                    homeDirectoryPath: homeDirectoryPath
                ).path,
                threadID: trimmedSessionID
            )
        default:
            return nil
        }
    }

    static func codexThreadIndexURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryPath: String = NSHomeDirectory()
    ) -> URL {
        let configuredHome = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let codexHome = if let configuredHome, configuredHome.hasPrefix("/") {
            URL(fileURLWithPath: configuredHome, isDirectory: true)
        } else {
            URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
                .appendingPathComponent(".codex", isDirectory: true)
        }
        return codexHome.appendingPathComponent("session_index.jsonl", isDirectory: false)
    }

    func readName(from source: ProviderSessionNameSource) -> String? {
        switch source {
        case .claudeTranscript(let path, let nativeSessionID):
            guard let tail = readTail(
                atPath: path,
                maximumBytes: ProviderSessionNameParser.maximumClaudeTranscriptTailBytes
            ) else { return nil }
            return ProviderSessionNameParser.claudeSessionName(
                inTranscriptTail: tail,
                nativeSessionID: nativeSessionID
            )
        case .codexThreadIndex(let path, let threadID):
            guard let contents = readTail(
                atPath: path,
                maximumBytes: ProviderSessionNameParser.maximumCodexThreadIndexBytes
            ) else { return nil }
            return ProviderSessionNameParser.codexThreadName(
                inIndex: contents,
                threadID: threadID
            )
        }
    }

    /// Reads at most `maximumBytes` from the end of a file, discarding a
    /// leading partial line whenever the read did not reach the start of the
    /// file. Both providers store one JSON object per line, so a fragment is
    /// never parsable and always belongs to a record outside the window.
    private func readTail(atPath path: String, maximumBytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        // A provider records a regular file here. Reading whatever else the
        // path resolves to — a FIFO above all — would block this read, and
        // with it every later refresh for the session. The check is on the
        // open descriptor, so it follows symlinks and leaves no window
        // between the check and the read.
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG else {
            return nil
        }

        do {
            let size = try handle.seekToEnd()
            guard size > 0 else { return nil }
            let readLength = min(UInt64(maximumBytes), size)
            try handle.seek(toOffset: size - readLength)
            guard let data = try handle.read(upToCount: Int(readLength)),
                  data.isEmpty == false else {
                return nil
            }
            // A provider transcript can hold invalid UTF-8 mid-stream, and a
            // tail read can also slice a multi-byte scalar. Decode lossily so
            // one bad byte cannot hide every name record after it.
            var text = String(decoding: data, as: UTF8.self)
            if readLength < size, let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            return text
        } catch {
            return nil
        }
    }
}
