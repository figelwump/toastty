import CoreState
import Foundation

/// Tails one Codex rollout file for the remote-access projection.
///
/// Reads the whole file from the start on first poll (the projection
/// deduplicates by fingerprint, so full re-reads are idempotent), then follows
/// appended bytes, buffering partial lines. When the file is replaced or
/// truncated (identity change or shrink), it stops and reports
/// `fileReplaced` — the owner forces a projection resnapshot and starts a
/// fresh tailer rather than guessing at offsets.
@MainActor
final class RemoteTranscriptTailer {
    enum Event: Sendable {
        case observations([ProviderTranscriptObservation])
        case fileReplaced
    }

    let conversationID: RemoteConversationID
    let fileURL: URL
    let provider: AgentKind

    private let pollIntervalNanoseconds: UInt64
    private let makeParser: @Sendable () -> any ProviderTranscriptLineParser
    private let onEvent: @MainActor (RemoteConversationID, Event) -> Void
    private var task: Task<Void, Never>?

    init(
        conversationID: RemoteConversationID,
        fileURL: URL,
        provider: AgentKind,
        makeParser: @escaping @Sendable () -> any ProviderTranscriptLineParser,
        pollIntervalNanoseconds: UInt64 = 500_000_000,
        onEvent: @escaping @MainActor (RemoteConversationID, Event) -> Void
    ) {
        self.conversationID = conversationID
        self.fileURL = fileURL
        self.provider = provider
        self.makeParser = makeParser
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.onEvent = onEvent
    }

    func start() {
        guard task == nil else { return }
        let conversationID = conversationID
        let fileURL = fileURL
        let pollInterval = pollIntervalNanoseconds
        let onEvent = onEvent
        let makeParser = makeParser

        task = Task.detached(priority: .utility) {
            var parser = makeParser()
            var offset: UInt64 = 0
            var identity: FileIdentity?
            var remainder = Data()

            while Task.isCancelled == false {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else {
                    try? await Task.sleep(nanoseconds: pollInterval)
                    continue
                }
                let currentIdentity = FileIdentity(attributes: attributes)
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0

                if let knownIdentity = identity, knownIdentity != currentIdentity || size < offset {
                    await onEvent(conversationID, .fileReplaced)
                    return
                }
                identity = currentIdentity

                if size > offset,
                   let handle = try? FileHandle(forReadingFrom: fileURL) {
                    defer { try? handle.close() }
                    try? handle.seek(toOffset: offset)
                    let data = (try? handle.readToEnd()) ?? Data()
                    offset += UInt64(data.count)
                    remainder.append(data)

                    var observations: [ProviderTranscriptObservation] = []
                    while let newlineIndex = remainder.firstIndex(of: UInt8(ascii: "\n")) {
                        let lineData = remainder[remainder.startIndex..<newlineIndex]
                        remainder.removeSubrange(remainder.startIndex...newlineIndex)
                        guard let line = String(data: lineData, encoding: .utf8) else { continue }
                        observations.append(contentsOf: parser.parseLine(line))
                    }
                    if observations.isEmpty == false {
                        await onEvent(conversationID, .observations(observations))
                    }
                }

                try? await Task.sleep(nanoseconds: pollInterval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private struct FileIdentity: Equatable, Sendable {
        let deviceNumber: UInt64
        let fileNumber: UInt64

        init(attributes: [FileAttributeKey: Any]) {
            deviceNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
            fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        }
    }
}
