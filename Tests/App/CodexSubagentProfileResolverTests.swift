import CoreState
import Foundation
import Testing
@testable import ToasttyApp

struct CodexSubagentProfileResolverTests {
    @Test
    func resolvesExactChildRolloutURLWithoutReadingConversationContent() async throws {
        let fixture = try makeFixture(day: "16")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let childThreadID = "child-rollout-url"
        let childURL = fixture.dayURL.appendingPathComponent("rollout-\(childThreadID).jsonl")
        try writeLines([
            #"{"type":"response_item","payload":{"type":"message","text":"private content"}}"#,
        ], to: childURL)
        let resolver = CodexSubagentProfileResolver(
            maximumAttempts: 1,
            retryDelayNanoseconds: 0
        )

        let resolvedURL = await resolver.resolveRolloutURL(
            childThreadID: childThreadID,
            parentRolloutURL: fixture.parentRolloutURL
        )

        #expect(resolvedURL?.standardizedFileURL.path == childURL.standardizedFileURL.path)
    }

    @Test
    func resolvesEffectiveProfileWithoutDecodingUnrelatedRecords() async throws {
        let fixture = try makeFixture(day: "16")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let childThreadID = "01a00c55-a4a8-7eb0-a60d-03ba26cf7190"
        let childURL = fixture.dayURL
            .appendingPathComponent("rollout-2026-08-16T13-48-54-\(childThreadID).jsonl")
        try writeLines([
            #"{"type":"response_item","payload":{"type":"message","model":"wrong-model","effort":"wrong-effort","text":"private content"}}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-5.6-luna","effort":"xhigh"}}"#,
        ], to: childURL)
        let resolver = CodexSubagentProfileResolver(
            maximumAttempts: 1,
            retryDelayNanoseconds: 0
        )

        let profile = await resolver.resolveProfile(
            childThreadID: childThreadID,
            parentRolloutURL: fixture.parentRolloutURL
        )

        #expect(profile == SessionAgentExecutionProfile(
            modelIdentifier: "gpt-5.6-luna",
            reasoningEffort: "xhigh"
        ))
    }

    @Test
    func skipsNestedTurnContextMarkerBeforeAuthoritativeRecord() async throws {
        let fixture = try makeFixture(day: "16")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let childThreadID = "child-nested-marker"
        let childURL = fixture.dayURL.appendingPathComponent("rollout-\(childThreadID).jsonl")
        try writeLines([
            #"{"type":"response_item","payload":{"nested":{"type":"turn_context"}}}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-5.6-terra","effort":"high"}}"#,
        ], to: childURL)
        let resolver = CodexSubagentProfileResolver(
            maximumAttempts: 1,
            retryDelayNanoseconds: 0
        )

        let profile = await resolver.resolveProfile(
            childThreadID: childThreadID,
            parentRolloutURL: fixture.parentRolloutURL
        )

        #expect(profile == SessionAgentExecutionProfile(
            modelIdentifier: "gpt-5.6-terra",
            reasoningEffort: "high"
        ))
    }

    @Test
    func returnsAvailableFieldWhenOtherProfileFieldIsMissing() async throws {
        let fixture = try makeFixture(day: "16")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let childThreadID = "child-model-only"
        let childURL = fixture.dayURL.appendingPathComponent("rollout-\(childThreadID).jsonl")
        try writeLines([
            #"{"type": "turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
        ], to: childURL)
        let resolver = CodexSubagentProfileResolver(
            maximumAttempts: 1,
            retryDelayNanoseconds: 0
        )

        let profile = await resolver.resolveProfile(
            childThreadID: childThreadID,
            parentRolloutURL: fixture.parentRolloutURL
        )

        #expect(profile == SessionAgentExecutionProfile(modelIdentifier: "gpt-5.6-sol"))
    }

    @Test
    func ignoresIncompleteTrailingTurnContextUntilItIsComplete() async throws {
        let fixture = try makeFixture(day: "16")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let childThreadID = "child-incomplete"
        let childURL = fixture.dayURL.appendingPathComponent("rollout-\(childThreadID).jsonl")
        let line = #"{"type":"turn_context","payload":{"model":"gpt-5.6-terra","effort":"high"}}"#
        try Data(line.utf8).write(to: childURL)
        let resolver = CodexSubagentProfileResolver(
            maximumAttempts: 1,
            retryDelayNanoseconds: 0
        )

        #expect(await resolver.resolveProfile(
            childThreadID: childThreadID,
            parentRolloutURL: fixture.parentRolloutURL
        ) == nil)

        try Data("\(line)\n".utf8).write(to: childURL)
        #expect(await resolver.resolveProfile(
            childThreadID: childThreadID,
            parentRolloutURL: fixture.parentRolloutURL
        ) == SessionAgentExecutionProfile(
            modelIdentifier: "gpt-5.6-terra",
            reasoningEffort: "high"
        ))
    }

    @Test
    func resolvesAcrossAdjacentDayBucket() async throws {
        let fixture = try makeFixture(day: "16")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let childThreadID = "child-midnight"
        let adjacentDayURL = fixture.rootURL
            .appendingPathComponent("sessions/2026/08/17", isDirectory: true)
        try FileManager.default.createDirectory(at: adjacentDayURL, withIntermediateDirectories: true)
        try writeLines([
            #"{"type":"turn_context","payload":{"model":"gpt-5.6-luna","effort":"medium"}}"#,
        ], to: adjacentDayURL.appendingPathComponent("rollout-\(childThreadID).jsonl"))
        let resolver = CodexSubagentProfileResolver(
            maximumAttempts: 1,
            retryDelayNanoseconds: 0
        )

        let profile = await resolver.resolveProfile(
            childThreadID: childThreadID,
            parentRolloutURL: fixture.parentRolloutURL
        )

        #expect(profile?.modelIdentifier == "gpt-5.6-luna")
        #expect(profile?.reasoningEffort == "medium")
    }

    @Test
    func retriesWhenChildRolloutAppearsAfterLifecycleEvent() async throws {
        let fixture = try makeFixture(day: "16")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let childThreadID = "child-delayed"
        let childURL = fixture.dayURL.appendingPathComponent("rollout-\(childThreadID).jsonl")
        let resolver = CodexSubagentProfileResolver(
            maximumAttempts: 5,
            retryDelayNanoseconds: 20_000_000
        )

        let writer = Task.detached {
            try await Task.sleep(nanoseconds: 30_000_000)
            try writeLines([
                #"{"type":"turn_context","payload":{"model":"gpt-5.6-luna","effort":"low"}}"#,
            ], to: childURL)
        }
        let profile = await resolver.resolveProfile(
            childThreadID: childThreadID,
            parentRolloutURL: fixture.parentRolloutURL
        )
        try await writer.value

        #expect(profile == SessionAgentExecutionProfile(
            modelIdentifier: "gpt-5.6-luna",
            reasoningEffort: "low"
        ))
    }

    @Test
    func rolloutLookupGivesUpAtDeadlineWhenChildNeverAppears() async throws {
        let fixture = try makeFixture(day: "16")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let resolver = CodexSubagentProfileResolver(
            retryDelayNanoseconds: 5_000_000,
            rolloutLookupDeadlineNanoseconds: 60_000_000
        )

        let clock = ContinuousClock()
        let started = clock.now
        let rolloutURL = await resolver.resolveRolloutURL(
            childThreadID: "child-never-written",
            parentRolloutURL: fixture.parentRolloutURL
        )
        let elapsed = clock.now - started

        #expect(rolloutURL == nil)
        // Must stop near the deadline, not spin forever and not bail early.
        #expect(elapsed >= .milliseconds(55))
        #expect(elapsed < .seconds(2))
    }

    @Test
    func rolloutLookupStillResolvesLateChildWithinDeadline() async throws {
        let fixture = try makeFixture(day: "16")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let childThreadID = "child-late"
        let childURL = fixture.dayURL.appendingPathComponent("rollout-\(childThreadID).jsonl")
        let resolver = CodexSubagentProfileResolver(
            retryDelayNanoseconds: 5_000_000,
            maximumRetryDelayNanoseconds: 20_000_000,
            rolloutLookupDeadlineNanoseconds: 2_000_000_000
        )

        let writer = Task.detached {
            try await Task.sleep(nanoseconds: 120_000_000)
            try writeLines([#"{"type":"turn_context","payload":{"model":"m","effort":"low"}}"#], to: childURL)
        }
        let rolloutURL = await resolver.resolveRolloutURL(
            childThreadID: childThreadID,
            parentRolloutURL: fixture.parentRolloutURL
        )
        try await writer.value

        #expect(rolloutURL?.standardizedFileURL == childURL.standardizedFileURL)
    }

    @Test
    func refusesAmbiguousThreadRollouts() async throws {
        let fixture = try makeFixture(day: "16")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let childThreadID = "child-ambiguous"
        let line = #"{"type":"turn_context","payload":{"model":"gpt-5.6-luna","effort":"low"}}"#
        try writeLines([line], to: fixture.dayURL.appendingPathComponent("rollout-a-\(childThreadID).jsonl"))
        try writeLines([line], to: fixture.dayURL.appendingPathComponent("rollout-b-\(childThreadID).jsonl"))
        let resolver = CodexSubagentProfileResolver(
            maximumAttempts: 1,
            retryDelayNanoseconds: 0
        )

        #expect(await resolver.resolveProfile(
            childThreadID: childThreadID,
            parentRolloutURL: fixture.parentRolloutURL
        ) == nil)
    }
}

private func makeFixture(day: String) throws -> (
    rootURL: URL,
    dayURL: URL,
    parentRolloutURL: URL
) {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("toastty-codex-subagent-profile-\(UUID().uuidString)", isDirectory: true)
    let dayURL = rootURL
        .appendingPathComponent("sessions/2026/08/\(day)", isDirectory: true)
    try FileManager.default.createDirectory(at: dayURL, withIntermediateDirectories: true)
    return (
        rootURL,
        dayURL,
        dayURL.appendingPathComponent("rollout-parent.jsonl")
    )
}

private func writeLines(_ lines: [String], to url: URL) throws {
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
}
