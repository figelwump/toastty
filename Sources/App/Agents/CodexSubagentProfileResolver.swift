import CoreState
import Foundation

protocol CodexSubagentProfileResolving: Sendable {
    func resolveRolloutURL(
        childThreadID: String,
        parentRolloutURL: URL
    ) async -> URL?

    func resolveProfile(
        childThreadID: String,
        parentRolloutURL: URL
    ) async -> SessionAgentExecutionProfile?
}

/// Locates an exact child rollout and resolves its effective, runtime-selected
/// settings. Profile resolution only decodes complete `turn_context` records;
/// conversation and instruction records are never decoded or logged.
actor CodexSubagentProfileResolver: CodexSubagentProfileResolving {
    private enum RolloutLookupResult {
        case pending
        case resolved(URL)
        case unavailable
    }

    private enum LookupResult {
        case pending
        case resolved(SessionAgentExecutionProfile?)
        case unavailable
    }

    private struct TurnContextEnvelope: Decodable {
        struct Payload: Decodable {
            let model: String?
            let effort: String?
        }

        let type: String
        let payload: Payload
    }

    private let fileManager: FileManager
    private let maximumProfileResolutionAttempts: Int
    private let retryDelayNanoseconds: UInt64
    private let maximumRetryDelayNanoseconds: UInt64
    private let rolloutLookupDeadlineNanoseconds: UInt64
    private let maximumPrefixByteCount: Int
    private let maximumMetadataLineByteCount: Int

    /// - Parameters:
    ///   - retryDelayNanoseconds: Initial delay between rollout directory
    ///     scans. Each pending scan doubles it up to `maximumRetryDelayNanoseconds`,
    ///     so a child that never writes a rollout costs one directory
    ///     enumeration every few seconds rather than four per second.
    ///   - rolloutLookupDeadlineNanoseconds: Total time `resolveRolloutURL`
    ///     keeps looking before giving up. Codex writes the child rollout
    ///     within seconds of the lifecycle event, so a long wait means the
    ///     child was cancelled or the parent rollout path is wrong.
    init(
        fileManager: FileManager = .default,
        maximumAttempts: Int = 16,
        retryDelayNanoseconds: UInt64 = 250_000_000,
        maximumRetryDelayNanoseconds: UInt64 = 4_000_000_000,
        rolloutLookupDeadlineNanoseconds: UInt64 = 5 * 60 * 1_000_000_000,
        maximumPrefixByteCount: Int = 512 * 1_024,
        maximumMetadataLineByteCount: Int = 32 * 1_024
    ) {
        precondition(maximumAttempts > 0)
        precondition(maximumPrefixByteCount > 0)
        precondition(maximumMetadataLineByteCount > 0)
        self.fileManager = fileManager
        self.maximumProfileResolutionAttempts = maximumAttempts
        self.retryDelayNanoseconds = retryDelayNanoseconds
        self.maximumRetryDelayNanoseconds = max(retryDelayNanoseconds, maximumRetryDelayNanoseconds)
        self.rolloutLookupDeadlineNanoseconds = rolloutLookupDeadlineNanoseconds
        self.maximumPrefixByteCount = maximumPrefixByteCount
        self.maximumMetadataLineByteCount = maximumMetadataLineByteCount
    }

    func resolveProfile(
        childThreadID: String,
        parentRolloutURL: URL
    ) async -> SessionAgentExecutionProfile? {
        guard let childThreadID = Self.normalizedNonEmpty(childThreadID) else {
            return nil
        }

        for attempt in 0..<maximumProfileResolutionAttempts {
            if Task.isCancelled { return nil }
            switch lookupProfile(
                childThreadID: childThreadID,
                parentRolloutURL: parentRolloutURL
            ) {
            case .resolved(let profile):
                return profile
            case .unavailable:
                return nil
            case .pending:
                guard attempt + 1 < maximumProfileResolutionAttempts else { return nil }
                if retryDelayNanoseconds > 0 {
                    do {
                        try await Task.sleep(nanoseconds: retryDelayNanoseconds)
                    } catch {
                        return nil
                    }
                }
            }
        }
        return nil
    }

    func resolveRolloutURL(
        childThreadID: String,
        parentRolloutURL: URL
    ) async -> URL? {
        guard let childThreadID = Self.normalizedNonEmpty(childThreadID) else {
            return nil
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .nanoseconds(Int64(clamping: rolloutLookupDeadlineNanoseconds)))
        var delayNanoseconds = retryDelayNanoseconds
        while Task.isCancelled == false {
            switch lookupRolloutURL(
                childThreadID: childThreadID,
                parentRolloutURL: parentRolloutURL
            ) {
            case .resolved(let rolloutURL):
                return rolloutURL
            case .unavailable:
                return nil
            case .pending:
                guard clock.now < deadline else {
                    return nil
                }
                if delayNanoseconds > 0 {
                    do {
                        try await Task.sleep(nanoseconds: delayNanoseconds)
                    } catch {
                        return nil
                    }
                    delayNanoseconds = min(delayNanoseconds &* 2, maximumRetryDelayNanoseconds)
                } else {
                    await Task.yield()
                }
            }
        }
        return nil
    }
}

private extension CodexSubagentProfileResolver {
    static let compactTurnContextMarker = Data(#""type":"turn_context""#.utf8)
    static let spacedTurnContextMarker = Data(#""type": "turn_context""#.utf8)

    private func lookupProfile(
        childThreadID: String,
        parentRolloutURL: URL
    ) -> LookupResult {
        switch lookupRolloutURL(
            childThreadID: childThreadID,
            parentRolloutURL: parentRolloutURL
        ) {
        case .resolved(let candidateURL):
            return profileFromRolloutPrefix(candidateURL)
        case .pending:
            return .pending
        case .unavailable:
            return .unavailable
        }
    }

    private func lookupRolloutURL(
        childThreadID: String,
        parentRolloutURL: URL
    ) -> RolloutLookupResult {
        let candidateURLs = candidateRolloutURLs(
            childThreadID: childThreadID,
            parentRolloutURL: parentRolloutURL
        )
        guard candidateURLs.count <= 1 else {
            // A UUID-backed native thread should have exactly one rollout.
            // Refuse an ambiguous match instead of guessing by timestamp.
            return .unavailable
        }
        guard let candidateURL = candidateURLs.first else {
            return .pending
        }
        guard let values = try? candidateURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]),
        values.isRegularFile == true,
        values.isSymbolicLink != true else {
            return .unavailable
        }
        return .resolved(candidateURL)
    }

    func candidateRolloutURLs(
        childThreadID: String,
        parentRolloutURL: URL
    ) -> [URL] {
        let suffix = "-\(childThreadID).jsonl"
        let directName = "rollout-\(childThreadID).jsonl"
        var seenPaths = Set<String>()
        var matches: [URL] = []

        for directoryURL in Self.candidateDirectoryURLs(parentRolloutURL: parentRolloutURL) {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for url in urls {
                let name = url.lastPathComponent
                guard name == directName || name.hasSuffix(suffix) else { continue }
                let path = url.standardizedFileURL.path
                guard seenPaths.insert(path).inserted else { continue }
                matches.append(url)
            }
        }
        return matches.sorted { $0.path < $1.path }
    }

    private func profileFromRolloutPrefix(_ rolloutURL: URL) -> LookupResult {
        guard let handle = try? FileHandle(forReadingFrom: rolloutURL) else {
            return .pending
        }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: maximumPrefixByteCount) ?? Data()
        } catch {
            return .pending
        }
        guard data.isEmpty == false,
              let finalNewlineIndex = data.lastIndex(of: 0x0A) else {
            return .pending
        }

        let completeData = data[...finalNewlineIndex]
        for line in completeData.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard line.count <= maximumMetadataLineByteCount else { continue }
            let lineData = Data(line)
            guard lineData.range(of: Self.compactTurnContextMarker) != nil
                || lineData.range(of: Self.spacedTurnContextMarker) != nil else {
                continue
            }
            guard let envelope = try? JSONDecoder().decode(TurnContextEnvelope.self, from: lineData),
                  envelope.type == "turn_context" else {
                // A nested object can contain the same marker. Keep scanning;
                // only a top-level turn_context record is authoritative.
                continue
            }
            let profile = SessionAgentExecutionProfile(
                modelIdentifier: envelope.payload.model,
                reasoningEffort: envelope.payload.effort
            )
            return .resolved(profile.isEmpty ? nil : profile)
        }
        return .pending
    }

    static func candidateDirectoryURLs(parentRolloutURL: URL) -> [URL] {
        let parentDirectoryURL = parentRolloutURL.deletingLastPathComponent()
        var directories = [parentDirectoryURL]

        let day = parentDirectoryURL.lastPathComponent
        let monthDirectoryURL = parentDirectoryURL.deletingLastPathComponent()
        let month = monthDirectoryURL.lastPathComponent
        let yearDirectoryURL = monthDirectoryURL.deletingLastPathComponent()
        let year = yearDirectoryURL.lastPathComponent
        let sessionsDirectoryURL = yearDirectoryURL.deletingLastPathComponent()

        guard let yearValue = Int(year),
              let monthValue = Int(month),
              let dayValue = Int(day) else {
            return directories
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let date = calendar.date(from: DateComponents(
            year: yearValue,
            month: monthValue,
            day: dayValue
        )) else {
            return directories
        }

        for offset in [-1, 1] {
            guard let adjacentDate = calendar.date(byAdding: .day, value: offset, to: date) else {
                continue
            }
            let components = calendar.dateComponents([.year, .month, .day], from: adjacentDate)
            guard let adjacentYear = components.year,
                  let adjacentMonth = components.month,
                  let adjacentDay = components.day else {
                continue
            }
            let directoryURL = sessionsDirectoryURL
                .appendingPathComponent(String(format: "%04d", adjacentYear), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", adjacentMonth), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", adjacentDay), isDirectory: true)
            if directoryURL.standardizedFileURL != parentDirectoryURL.standardizedFileURL {
                directories.append(directoryURL)
            }
        }
        return directories
    }

    static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
