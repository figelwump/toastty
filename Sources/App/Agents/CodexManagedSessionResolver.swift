import CoreState
import Foundation

protocol CodexManagedSessionResolving: Sendable {
    func resumeRecord(
        threadID: String,
        rolloutPath: String?,
        expectedCWD: String,
        capturedAt: Date
    ) async -> ManagedAgentResumeRecord?
}

actor CodexManagedSessionResolver: CodexManagedSessionResolving {
    private let codexSessionsDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        codexSessionsDirectory = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    init(codexSessionsDirectory: URL) {
        self.codexSessionsDirectory = codexSessionsDirectory
    }

    func resumeRecord(
        threadID: String,
        rolloutPath: String?,
        expectedCWD: String,
        capturedAt: Date
    ) async -> ManagedAgentResumeRecord? {
        guard let threadID = Self.normalizedNonEmpty(threadID),
              let expectedCWD = Self.normalizedPath(expectedCWD) else {
            return nil
        }

        if let rolloutPath = Self.normalizedPath(rolloutPath) {
            guard let metadata = Self.codexSessionMetadata(from: URL(fileURLWithPath: rolloutPath)),
                  metadata.sessionID == threadID,
                  metadata.cwd == expectedCWD else {
                return nil
            }
            return ManagedAgentResumeRecord(
                agent: .codex,
                nativeSessionID: metadata.sessionID,
                sessionFilePath: metadata.sessionFilePath,
                cwd: metadata.cwd,
                capturedAt: capturedAt
            )
        }

        let matches = Self.jsonlFiles(under: codexSessionsDirectory)
            .compactMap(Self.codexSessionMetadata(from:))
            .filter { metadata in
                metadata.sessionID == threadID && metadata.cwd == expectedCWD
            }

        guard matches.count == 1, let metadata = matches.first else {
            return nil
        }

        return ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: metadata.sessionID,
            sessionFilePath: metadata.sessionFilePath,
            cwd: metadata.cwd,
            capturedAt: capturedAt
        )
    }
}

private extension CodexManagedSessionResolver {
    struct CodexSessionMetadata: Equatable, Sendable {
        var sessionID: String
        var sessionFilePath: String
        var cwd: String
    }

    static func codexSessionMetadata(from fileURL: URL) -> CodexSessionMetadata? {
        for object in jsonObjects(fromPrefixOf: fileURL, maxLines: 20) {
            guard object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any],
                  let sessionID = normalizedNonEmpty(payload["id"] as? String),
                  let cwd = normalizedPath(payload["cwd"] as? String) else {
                continue
            }
            return CodexSessionMetadata(
                sessionID: sessionID,
                sessionFilePath: fileURL.path,
                cwd: cwd
            )
        }
        return nil
    }

    static func jsonlFiles(under directoryURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(atPath: directoryURL.path) else {
            return []
        }

        var urls: [URL] = []
        for case let relativePath as String in enumerator {
            guard relativePath.hasSuffix(".jsonl") else { continue }
            urls.append(directoryURL.appendingPathComponent(relativePath, isDirectory: false))
        }
        return urls.sorted { lhs, rhs in
            lhs.path < rhs.path
        }
    }

    static func jsonObjects(fromPrefixOf fileURL: URL, maxLines: Int) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return []
        }
        defer {
            try? handle.close()
        }

        let data = (try? handle.read(upToCount: 65_536)) ?? Data()
        guard data.isEmpty == false else {
            return []
        }
        let text = String(decoding: data, as: UTF8.self)
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(maxLines)
            .compactMap { line in
                guard let lineData = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    return nil
                }
                return object
            }
    }

    static func normalizedPath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let normalized = (expanded as NSString).standardizingPath
        guard normalized.isEmpty == false else { return nil }
        return normalized
    }

    static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
