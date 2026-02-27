import CoreState
import Foundation
import Testing

struct SessionUpdateCoalescerTests {
    @Test
    func coalescesRapidUpdatesPerSession() {
        var coalescer = SessionUpdateCoalescer(window: 0.5)
        let t0 = Date(timeIntervalSince1970: 100)

        coalescer.ingest(
            SessionFileUpdate(
                sessionID: "s1",
                files: ["a.swift", "b.swift"],
                cwd: "/repo",
                repoRoot: "/repo"
            ),
            at: t0
        )

        coalescer.ingest(
            SessionFileUpdate(
                sessionID: "s1",
                files: ["b.swift", "c.swift"],
                cwd: "/repo/subdir",
                repoRoot: nil
            ),
            at: t0.addingTimeInterval(0.2)
        )

        let beforeWindow = coalescer.flushReady(at: t0.addingTimeInterval(0.4))
        #expect(beforeWindow.isEmpty)

        let afterWindow = coalescer.flushReady(at: t0.addingTimeInterval(0.8))
        #expect(afterWindow.count == 1)
        #expect(afterWindow[0].files == ["a.swift", "b.swift", "c.swift"])
        #expect(afterWindow[0].cwd == "/repo/subdir")
        #expect(afterWindow[0].repoRoot == "/repo")
    }

    @Test
    func firstIngestDeduplicatesDuplicateFiles() {
        var coalescer = SessionUpdateCoalescer(window: 0.5)
        let t0 = Date(timeIntervalSince1970: 120)

        coalescer.ingest(
            SessionFileUpdate(
                sessionID: "s1",
                files: ["a.swift", "a.swift", "b.swift"],
                cwd: nil,
                repoRoot: nil
            ),
            at: t0
        )

        let flushed = coalescer.flushReady(at: t0.addingTimeInterval(1))
        #expect(flushed.count == 1)
        #expect(flushed[0].files == ["a.swift", "b.swift"])
    }

    @Test
    func flushReadyHandlesSessionsIndependently() {
        var coalescer = SessionUpdateCoalescer(window: 0.5)
        let t0 = Date(timeIntervalSince1970: 200)

        coalescer.ingest(
            SessionFileUpdate(sessionID: "s1", files: ["a.swift"], cwd: nil, repoRoot: nil),
            at: t0
        )
        coalescer.ingest(
            SessionFileUpdate(sessionID: "s2", files: ["b.swift"], cwd: nil, repoRoot: nil),
            at: t0.addingTimeInterval(0.4)
        )

        let firstFlush = coalescer.flushReady(at: t0.addingTimeInterval(0.6))
        #expect(firstFlush.count == 1)
        #expect(firstFlush[0].sessionID == "s1")

        let secondFlush = coalescer.flushReady(at: t0.addingTimeInterval(1.0))
        #expect(secondFlush.count == 1)
        #expect(secondFlush[0].sessionID == "s2")
    }

    @Test
    func flushReadyIncludesEventsAtExactWindowBoundary() {
        var coalescer = SessionUpdateCoalescer(window: 0.5)
        let t0 = Date(timeIntervalSince1970: 250)
        coalescer.ingest(
            SessionFileUpdate(sessionID: "s1", files: ["x.swift"], cwd: nil, repoRoot: nil),
            at: t0
        )

        let flushed = coalescer.flushReady(at: t0.addingTimeInterval(0.5))
        #expect(flushed.count == 1)
        #expect(flushed[0].sessionID == "s1")
    }

    @Test
    func flushAllDrainsPendingUpdates() {
        var coalescer = SessionUpdateCoalescer(window: 0.5)
        let now = Date(timeIntervalSince1970: 300)

        coalescer.ingest(
            SessionFileUpdate(sessionID: "s1", files: ["a.swift"], cwd: nil, repoRoot: nil),
            at: now
        )
        coalescer.ingest(
            SessionFileUpdate(sessionID: "s2", files: ["b.swift"], cwd: nil, repoRoot: nil),
            at: now.addingTimeInterval(0.1)
        )

        let all = coalescer.flushAll()
        #expect(all.count == 2)
        #expect(coalescer.flushReady(at: now.addingTimeInterval(2)).isEmpty)
    }
}
