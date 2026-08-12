import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

@MainActor
struct RemoteTranscriptTailerTests {
    static let conversationID = RemoteConversationID(rawValue: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!)

    private final class EventCollector {
        var observationBatches: [[ProviderTranscriptObservation]] = []
        var fileReplacedCount = 0

        var allObservations: [ProviderTranscriptObservation] {
            observationBatches.flatMap { $0 }
        }
    }

    private static func makeTemporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-tailer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("rollout.jsonl")
    }

    private static func waitUntil(
        timeoutSeconds: Double = 5,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @Test func tailsInitialContentAndAppends() async throws {
        let fileURL = try Self.makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try CodexRolloutFixtures.basicSession.write(to: fileURL, atomically: true, encoding: .utf8)

        let collector = EventCollector()
        let tailer = RemoteTranscriptTailer(
            conversationID: Self.conversationID,
            fileURL: fileURL,
            provider: .codex,
            makeParser: { CodexRolloutTranscriptParser() },
            pollIntervalNanoseconds: 50_000_000
        ) { _, event in
            switch event {
            case .observations(let observations):
                collector.observationBatches.append(observations)
            case .fileReplaced:
                collector.fileReplacedCount += 1
            }
        }
        tailer.start()
        defer { tailer.stop() }

        await Self.waitUntil {
            collector.allObservations.contains { observation in
                if case .turnEnded = observation.payload { return true }
                return false
            }
        }
        let expected = CodexRolloutTranscriptParser.parseContents(CodexRolloutFixtures.basicSession).observations
        #expect(collector.allObservations == expected)

        // Append the resumed continuation; the tailer picks up only the new
        // records with fingerprints consistent with a continuous parse.
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(CodexRolloutFixtures.resumeContinuation.utf8))
        try handle.close()

        let fullExpected = CodexRolloutTranscriptParser
            .parseContents(CodexRolloutFixtures.basicSession + CodexRolloutFixtures.resumeContinuation)
            .observations
        await Self.waitUntil { collector.allObservations.count == fullExpected.count }
        #expect(collector.allObservations == fullExpected)
        #expect(collector.fileReplacedCount == 0)
    }

    @Test func tailsClaudeTranscriptThroughProviderFactory() async throws {
        let fileURL = try Self.makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try ClaudeTranscriptFixtures.basicSession.write(to: fileURL, atomically: true, encoding: .utf8)

        let collector = EventCollector()
        let tailer = RemoteTranscriptTailer(
            conversationID: Self.conversationID,
            fileURL: fileURL,
            provider: .claude,
            makeParser: {
                ProviderTranscriptSupport.makeParser(for: .claude) ?? CodexRolloutTranscriptParser()
            },
            pollIntervalNanoseconds: 50_000_000
        ) { _, event in
            if case .observations(let observations) = event {
                collector.observationBatches.append(observations)
            }
        }
        tailer.start()
        defer { tailer.stop() }

        let expected = ClaudeTranscriptParser.parseContents(ClaudeTranscriptFixtures.basicSession).observations
        await Self.waitUntil { collector.allObservations.count == expected.count }
        #expect(collector.allObservations == expected)

        // A Claude transcript never carries a completed-turn signal, so the
        // provider-agnostic tailer path stays read-only.
        let sawCompletedTurn = collector.allObservations.contains { observation in
            if case .turnEnded(_, reason: .completed) = observation.payload { return true }
            return false
        }
        #expect(sawCompletedTurn == false)
    }

    @Test func truncationReportsFileReplaced() async throws {
        let fileURL = try Self.makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try CodexRolloutFixtures.basicSession.write(to: fileURL, atomically: true, encoding: .utf8)

        let collector = EventCollector()
        let tailer = RemoteTranscriptTailer(
            conversationID: Self.conversationID,
            fileURL: fileURL,
            provider: .codex,
            makeParser: { CodexRolloutTranscriptParser() },
            pollIntervalNanoseconds: 50_000_000
        ) { _, event in
            switch event {
            case .observations(let observations):
                collector.observationBatches.append(observations)
            case .fileReplaced:
                collector.fileReplacedCount += 1
            }
        }
        tailer.start()
        defer { tailer.stop() }

        await Self.waitUntil { collector.observationBatches.isEmpty == false }

        // Rewrite the file shorter (compaction-style rewrite).
        try Data("{}\n".utf8).write(to: fileURL, options: [.atomic])
        await Self.waitUntil { collector.fileReplacedCount > 0 }
        #expect(collector.fileReplacedCount == 1)
    }

    @Test func partialLinesAreBufferedUntilComplete() async throws {
        let fileURL = try Self.makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let fullLine = #"{"timestamp":"2026-08-07T10:00:05.000Z","type":"event_msg","payload":{"type":"user_message","message":"buffered line","images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}}"#
        let splitIndex = fullLine.index(fullLine.startIndex, offsetBy: 60)
        try String(fullLine[..<splitIndex]).write(to: fileURL, atomically: false, encoding: .utf8)

        let collector = EventCollector()
        let tailer = RemoteTranscriptTailer(
            conversationID: Self.conversationID,
            fileURL: fileURL,
            provider: .codex,
            makeParser: { CodexRolloutTranscriptParser() },
            pollIntervalNanoseconds: 50_000_000
        ) { _, event in
            if case .observations(let observations) = event {
                collector.observationBatches.append(observations)
            }
        }
        tailer.start()
        defer { tailer.stop() }

        // Give the tailer a few polls with only the partial line present.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(collector.allObservations.isEmpty)

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(fullLine[splitIndex...]) + "\n").utf8))
        try handle.close()

        await Self.waitUntil { collector.allObservations.count == 1 }
        guard case .transcript(.userMessage(let payload)) = collector.allObservations.first?.payload else {
            Issue.record("Expected the buffered user message")
            return
        }
        #expect(payload.text == "buffered line")
    }

    @Test func completeFinalRecordWithoutNewlineIsFlushed() async throws {
        let fileURL = try Self.makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let line = #"{"timestamp":"2026-08-07T10:00:05.000Z","type":"event_msg","payload":{"type":"user_message","message":"final record","images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}}"#
        try line.write(to: fileURL, atomically: false, encoding: .utf8)

        let collector = EventCollector()
        let tailer = RemoteTranscriptTailer(
            conversationID: Self.conversationID,
            fileURL: fileURL,
            provider: .codex,
            makeParser: { CodexRolloutTranscriptParser() },
            pollIntervalNanoseconds: 50_000_000
        ) { _, event in
            if case .observations(let observations) = event {
                collector.observationBatches.append(observations)
            }
        }
        tailer.start()
        defer { tailer.stop() }

        await Self.waitUntil { collector.allObservations.count == 1 }
        guard case .transcript(.userMessage(let payload)) = collector.allObservations.first?.payload else {
            Issue.record("Expected final user message")
            return
        }
        #expect(payload.text == "final record")

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        let nextLine =
            #"{"timestamp":"2026-08-07T10:00:06.000Z","type":"event_msg","payload":{"type":"user_message","message":"next record","images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}}"#
        try handle.write(contentsOf: Data(
            nextLine.utf8
        ))
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()

        await Self.waitUntil { collector.allObservations.count == 2 }
        #expect(collector.allObservations.count == 2)
    }

    @Test func routineLogMetadataOmitsTranscriptAndFilesystemDetails() {
        let sensitiveValues = [
            "person@example.com",
            "mac.tailnet.ts.net",
            "/Users/person/Secret Project/rollout.jsonl",
            "Confidential session title",
            "prompt contents",
            "transcript contents",
        ]
        let metadataSets = [
            RemoteTranscriptTailer.readFailureLogMetadata(provider: .codex),
            RemoteTranscriptTailer.oversizedRecordLogMetadata(provider: .claude, byteCount: 9_000_000),
        ]
        let serialized = metadataSets
            .flatMap { $0.flatMap { [$0.key, $0.value] } }
            .joined(separator: " ")

        #expect(metadataSets[0] == ["provider": "codex"])
        #expect(metadataSets[1] == ["provider": "claude", "bytes": "9000000"])
        for sensitiveValue in sensitiveValues {
            #expect(serialized.contains(sensitiveValue) == false)
        }
    }
}
