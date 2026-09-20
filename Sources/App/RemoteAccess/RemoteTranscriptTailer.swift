import CoreState
import Foundation
import RemoteProtocol

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
        /// `linkedFileReferences` are extracted here, off the main actor,
        /// because deriving them parses every assistant message as Markdown.
        case observations([ProviderTranscriptObservation], linkedFileReferences: [String])
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
        // A batch already queued for the main actor when the owner stops this
        // tailer must not reach a projection that has moved on: it would
        // restore events, and file-link grants, from the abandoned transcript.
        let onEvent: @MainActor (RemoteConversationID, Event) -> Void = { [weak self, onEvent] id, event in
            guard let self, self.task != nil else { return }
            onEvent(id, event)
        }
        let makeParser = makeParser
        let provider = provider

        task = Task.detached(priority: .utility) {
            var parser = makeParser()
            var offset: UInt64 = 0
            var identity: FileIdentity?
            var remainder = Data()
            let readChunkSize = 256 * 1024
            let maximumBufferedLineBytes = 8 * 1024 * 1024
            let observationBatchSize = 200

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
                    while offset < size, Task.isCancelled == false {
                        let data: Data
                        do {
                            data = try handle.read(upToCount: readChunkSize) ?? Data()
                        } catch {
                            ToasttyLog.warning(
                                "Failed to read remote transcript chunk",
                                category: .automation,
                                metadata: Self.readFailureLogMetadata(provider: provider)
                            )
                            break
                        }
                        guard data.isEmpty == false else { break }
                        offset += UInt64(data.count)
                        remainder.append(data)

                        var observations: [ProviderTranscriptObservation] = []
                        var consumedThrough = remainder.startIndex
                        while let newlineIndex = remainder[consumedThrough...].firstIndex(of: UInt8(ascii: "\n")) {
                            let lineData = remainder[consumedThrough..<newlineIndex]
                            consumedThrough = remainder.index(after: newlineIndex)
                            guard let line = String(data: lineData, encoding: .utf8) else { continue }
                            observations.append(contentsOf: parser.parseLine(line))
                            if observations.count >= observationBatchSize {
                                await onEvent(conversationID, Self.observationsEvent(observations))
                                observations.removeAll(keepingCapacity: true)
                            }
                        }
                        if consumedThrough > remainder.startIndex {
                            remainder.removeSubrange(remainder.startIndex..<consumedThrough)
                        }
                        if observations.isEmpty == false {
                            await onEvent(conversationID, Self.observationsEvent(observations))
                        }

                        if remainder.count > maximumBufferedLineBytes {
                            ToasttyLog.warning(
                                "Discarding oversized remote transcript record",
                                category: .automation,
                                metadata: Self.oversizedRecordLogMetadata(
                                    provider: provider,
                                    byteCount: remainder.count
                                )
                            )
                            remainder.removeAll(keepingCapacity: true)
                        }
                    }

                    // JSONL writers normally append a newline, but a complete
                    // final JSON object is still a valid record at EOF. Flush
                    // it once it is syntactically complete; genuinely partial
                    // writes remain buffered for the next poll.
                    if remainder.isEmpty == false,
                       (try? JSONSerialization.jsonObject(with: remainder)) != nil,
                       let line = String(data: remainder, encoding: .utf8) {
                        remainder.removeAll(keepingCapacity: true)
                        let observations = parser.parseLine(line)
                        if observations.isEmpty == false {
                            await onEvent(conversationID, Self.observationsEvent(observations))
                        }
                    }
                }

                try? await Task.sleep(nanoseconds: pollInterval)
            }
        }
    }

    nonisolated private static func observationsEvent(
        _ observations: [ProviderTranscriptObservation]
    ) -> Event {
        .observations(
            observations,
            linkedFileReferences: RemoteConversationProjectionStore.linkedFileReferences(
                in: observations))
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Routine tailer logs describe only the parser category and safe size
    /// facts. Transcript paths and filesystem error descriptions can contain a
    /// login, hostname, workspace path, or session title, so neither crosses
    /// this logging boundary.
    nonisolated static func readFailureLogMetadata(provider: AgentKind) -> [String: String] {
        ["provider": provider.rawValue]
    }

    nonisolated static func oversizedRecordLogMetadata(provider: AgentKind, byteCount: Int) -> [String: String] {
        [
            "provider": provider.rawValue,
            "bytes": "\(max(0, byteCount))",
        ]
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
