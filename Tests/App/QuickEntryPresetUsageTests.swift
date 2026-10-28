import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// The Frequent ranking: a recency-weighted count with a 14-day half-life,
/// at least one use, at most five presets, only agents still offered.
@MainActor
struct QuickEntryPresetUsageTests {
    static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let day: TimeInterval = 24 * 60 * 60
    static let opusHigh = QuickEntryPreset(agent: "claude", model: "claude-opus-5-5", effort: "high")
    static let solHigh = QuickEntryPreset(agent: "codex", model: "gpt-6.1-sol", effort: "high")
    static let agents: Set<String> = ["claude", "codex"]

    @MainActor
    final class Clock {
        var now = QuickEntryPresetUsageTests.start
    }

    private func usage(root: URL, clock: Clock) -> QuickEntryPresetUsage {
        QuickEntryPresetUsage(
            runtimePaths: ToasttyRuntimePaths.resolve(homeDirectoryPath: root.path, environment: [:]),
            now: { clock.now }
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("qepu-\(UUID().uuidString)", isDirectory: true)
    }

    private func record(_ preset: QuickEntryPreset, count: Int, daysAgo: Double = 0, score: Double? = nil) -> QuickEntryPresetUsageRecord {
        QuickEntryPresetUsageRecord(
            preset: preset,
            count: count,
            score: score ?? Double(count),
            lastUsedAt: Self.start.addingTimeInterval(-daysAgo * Self.day)
        )
    }

    @Test func aPresetIsListedFromItsFirstUse() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let usage = usage(root: root, clock: clock)
        usage.record(Self.opusHigh)
        #expect(usage.frequent(agents: Self.agents) == [Self.opusHigh])
        usage.record(Self.opusHigh)
        #expect(usage.frequent(agents: Self.agents) == [Self.opusHigh])
    }

    @Test func lastUsedSurvivesARestartIndependentlyOfFrequency() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let first = usage(root: root, clock: clock)
        #expect(first.lastUsed(agents: Self.agents) == nil)
        for _ in 0..<4 { first.record(Self.opusHigh) }
        clock.now = clock.now.addingTimeInterval(Self.day)
        first.record(Self.solHigh)
        #expect(first.lastUsed(agents: Self.agents) == Self.solHigh)
        let restarted = usage(root: root, clock: clock)
        #expect(restarted.lastUsed(agents: Self.agents) == Self.solHigh)
        #expect(restarted.frequent(agents: Self.agents) == [Self.opusHigh, Self.solHigh])
        #expect(restarted.lastUsed(agents: ["claude"]) == Self.opusHigh)
        #expect(restarted.lastUsed(agents: []) == nil)
    }

    @Test func repeatedPresetsInTheSameSecondKeepTheirLastUseOrderAfterRestart() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let first = usage(root: root, clock: clock)
        first.record(Self.solHigh)
        first.record(Self.opusHigh)
        first.record(Self.solHigh)
        #expect(first.lastUsed(agents: Self.agents) == Self.solHigh)
        #expect(usage(root: root, clock: clock).lastUsed(agents: Self.agents) == Self.solHigh)
    }

    @Test func existingHistoryRestoresByDateBeforeArrayOrder() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(".toastty", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Older writers kept insertion order when updating an existing
        // preset. The latest use can therefore be in the middle.
        let records = [
            record(QuickEntryPreset(agent: "codex", effort: "high"), count: 6, daysAgo: 2),
            record(Self.solHigh, count: 1),
            record(Self.opusHigh, count: 4, daysAgo: 1),
        ]
        try encoder.encode(records).write(to: directory.appendingPathComponent(QuickEntryPresetUsage.fileName))
        let clock = Clock()
        let loaded = usage(root: root, clock: clock)
        #expect(loaded.lastUsed(agents: Self.agents) == Self.solHigh)
        #expect(loaded.frequent(agents: Self.agents).contains(Self.solHigh))
        clock.now = clock.now.addingTimeInterval(Self.day)
        loaded.record(Self.opusHigh)
        #expect(usage(root: root, clock: clock).lastUsed(agents: Self.agents) == Self.opusHigh)
    }

    @Test func aUseCountsHalfAfterFourteenDays() throws {
        let used = record(Self.opusHigh, count: 1, daysAgo: 14)
        #expect(abs(QuickEntryPresetUsage.decayed(used, at: Self.start) - 0.5) < 0.0001)

        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let usage = usage(root: root, clock: clock)
        usage.record(Self.opusHigh)
        clock.now = clock.now.addingTimeInterval(14 * Self.day)
        usage.record(Self.opusHigh)
        // 1 halved, plus 1.
        let saved = try JSONDecoder.iso8601.decode(
            [QuickEntryPresetUsageRecord].self,
            from: Data(contentsOf: root.appendingPathComponent(".toastty/task-preset-usage.json"))
        )
        #expect(saved.count == 1)
        #expect(saved.first?.count == 2)
        #expect(abs((saved.first?.score ?? 0) - 1.5) < 0.0001)
    }

    @Test func recentUseOutranksOlderHeavierUse() {
        let records = [
            record(Self.opusHigh, count: 6, daysAgo: 42),
            record(Self.solHigh, count: 2, daysAgo: 1),
        ]
        // 6 × 1/8 = 0.75 against 2 × 0.95.
        #expect(QuickEntryPresetUsage.ranked(records, agents: Self.agents, at: Self.start) == [Self.solHigh, Self.opusHigh])
        let sameDay = [record(Self.opusHigh, count: 6), record(Self.solHigh, count: 2)]
        #expect(QuickEntryPresetUsage.ranked(sameDay, agents: Self.agents, at: Self.start) == [Self.opusHigh, Self.solHigh])
    }

    @Test func presetsOfAgentsThatAreGoneAreLeftOut() {
        let shipper = QuickEntryPreset(agent: "shipper")
        let records = [record(shipper, count: 9), record(Self.opusHigh, count: 2)]
        #expect(QuickEntryPresetUsage.ranked(records, agents: Self.agents, at: Self.start) == [Self.opusHigh])
    }

    @Test func aTieGoesToTheLastUsedThenToAFixedOrder() {
        let xhigh = QuickEntryPreset(agent: "claude", model: "claude-opus-5-5", effort: "xhigh")
        // Equal decayed scores: 2 now, and 4 a half-life ago.
        let records = [
            record(Self.solHigh, count: 4, daysAgo: 14),
            record(Self.opusHigh, count: 2),
        ]
        #expect(QuickEntryPresetUsage.ranked(records, agents: Self.agents, at: Self.start) == [Self.opusHigh, Self.solHigh])
        let identical = [record(xhigh, count: 2), record(Self.opusHigh, count: 2)]
        let order = QuickEntryPresetUsage.ranked(identical, agents: Self.agents, at: Self.start)
        #expect(order == QuickEntryPresetUsage.ranked(identical.reversed(), agents: Self.agents, at: Self.start))
    }

    @Test func atMostFivePresetsAreListed() {
        let records = (0..<7).map { index in
            record(QuickEntryPreset(agent: "codex", model: "model-\(index)"), count: 2 + index)
        }
        let ranked = QuickEntryPresetUsage.ranked(records, agents: Self.agents, at: Self.start)
        #expect(ranked.map(\.model) == ["model-6", "model-5", "model-4", "model-3", "model-2"])
    }

    @Test func usageSurvivesARestartAndABrokenFileIsIgnored() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let first = usage(root: root, clock: clock)
        first.record(Self.solHigh)
        first.record(Self.solHigh)
        #expect(usage(root: root, clock: clock).frequent(agents: Self.agents) == [Self.solHigh])

        let file = root.appendingPathComponent(".toastty/task-preset-usage.json")
        try Data("{not json".utf8).write(to: file)
        let broken = usage(root: root, clock: clock)
        #expect(broken.frequent(agents: Self.agents).isEmpty)
        // The next use starts the file over, readable again.
        broken.record(Self.opusHigh)
        broken.record(Self.opusHigh)
        #expect(usage(root: root, clock: clock).frequent(agents: Self.agents) == [Self.opusHigh])
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
