import Foundation
import Testing
@testable import CodexReconciliation

struct CodexSubagentReconciliationTests {
    private let epoch = Date(timeIntervalSince1970: 1_000)

    @Test
    func typedIdentifiersEnforceTheirBoundaries() {
        #expect(SpawnCallID("  call-1\n")?.rawValue == "call-1")
        #expect(ProviderAgentID("  agent-1 ")?.rawValue == "agent-1")
        #expect(SpawnCallID(" \n") == nil)
        #expect(ProviderAgentID("") == nil)

        #expect(ActivityID(" \n") == nil)
        #expect(ActivityID(" /tmp/Run.JSONL ")?.rawValue == " /tmp/Run.JSONL ")
        #expect(ActivityID("/tmp/Run.JSONL") != ActivityID("/tmp/run.jsonl"))
    }

    @Test
    func defaultConfigurationMatchesLegacyCapacityAndTTL() {
        let configuration = CodexSubagentReconciliationConfiguration()

        #expect(configuration.pendingCorrelationCapacity == 64)
        #expect(configuration.resolvedMetadataCapacity == 64)
        #expect(configuration.finishTombstoneTTL == 120)
    }

    @Test
    func equalityExposesStateMutationEvenWhenReductionHasNoProjectionDecision() {
        var reconciler = CodexSubagentReconciler(authority: .hooks)
        let initial = reconciler

        #expect(reconciler.reduce(
            .hookSpawn(callID: call("call-1"), taskName: "task", command: "command"),
            projection: .empty,
            now: epoch
        ) == .none)
        #expect(reconciler != initial)

        _ = reconciler.reduce(.stop, projection: .empty, now: epoch)
        #expect(reconciler == initial)
    }

    @Test
    func hookAndRolloutMetadataConvergeInEitherArrivalOrder() {
        let expectedStart = CodexSubagentReduction(decisions: [
            .authoritativeHookReopen(
                providerAgentID: agent("agent-1"),
                display: .preserveExisting(defaultValue: "Sub-agent")
            ),
            .enrichExisting(
                providerAgentID: agent("agent-1"),
                metadata: .init(displayName: "hook task", command: "hook command")
            ),
        ])

        var hookFirst = CodexSubagentReconciler(authority: .hooks)
        #expect(hookFirst.reduce(
            .hookSpawn(
                callID: call("call-1"),
                taskName: "hook task",
                command: "hook command"
            ),
            projection: .empty,
            now: epoch
        ) == .none)
        #expect(hookFirst.reduce(
            rolloutStart(
                activity: "rollout-local",
                call: "call-1",
                agent: "agent-1",
                displayName: "rollout display",
                command: "rollout command"
            ),
            projection: .empty,
            now: epoch
        ) == .none)
        #expect(hookFirst.reduce(
            .hookStart(agentID: agent("agent-1"), subagentType: "default"),
            projection: .empty,
            now: epoch
        ) == expectedStart)

        var rolloutFirst = CodexSubagentReconciler(authority: .hooks)
        #expect(rolloutFirst.reduce(
            rolloutStart(
                activity: "rollout-local",
                call: "call-1",
                agent: "agent-1",
                displayName: "rollout display",
                command: "rollout command"
            ),
            projection: .empty,
            now: epoch
        ) == .none)
        #expect(rolloutFirst.reduce(
            .hookSpawn(
                callID: call("call-1"),
                taskName: "hook task",
                command: "hook command"
            ),
            projection: .empty,
            now: epoch
        ) == .none)
        #expect(rolloutFirst.reduce(
            .hookStart(agentID: agent("agent-1"), subagentType: nil),
            projection: .empty,
            now: epoch
        ) == expectedStart)
    }

    @Test
    func rolloutFirstMetadataEnrichesStartThenHookMetadataOverridesActiveActivity() {
        var reconciler = CodexSubagentReconciler(authority: .hooks)

        #expect(reconciler.reduce(
            rolloutStart(
                activity: "rollout-local",
                call: "call-1",
                agent: "agent-1",
                displayName: "rollout display",
                command: "ignored rollout command"
            ),
            projection: .empty,
            now: epoch
        ) == .none)

        #expect(reconciler.reduce(
            .hookStart(agentID: agent("agent-1"), subagentType: nil),
            projection: .empty,
            now: epoch
        ).decisions == [
            .authoritativeHookReopen(
                providerAgentID: agent("agent-1"),
                display: .preserveExisting(defaultValue: "Sub-agent")
            ),
            .enrichExisting(
                providerAgentID: agent("agent-1"),
                metadata: .init(displayName: "rollout display")
            ),
        ])

        let hookResult = reconciler.reduce(
            .hookSpawn(
                callID: call("call-1"),
                taskName: "hook task",
                command: "hook command"
            ),
            projection: snapshot(active: ["agent-1"]),
            now: epoch
        )
        #expect(hookResult.decisions == [
            .enrichExisting(
                providerAgentID: agent("agent-1"),
                metadata: .init(displayName: "hook task", command: "hook command")
            ),
        ])
        #expect(hookResult.decisions.allSatisfy { decision in
            if case .fallbackUpsert = decision { return false }
            return true
        })
    }

    @Test
    func concurrentCallIDsCorrelateExactlyWithoutCrossJoining() {
        var reconciler = CodexSubagentReconciler(authority: .hooks)

        _ = reconciler.reduce(
            rolloutStart(
                activity: "activity-1",
                call: "call-1",
                agent: "agent-1",
                displayName: "rollout one"
            ),
            projection: .empty,
            now: epoch
        )
        _ = reconciler.reduce(
            rolloutStart(
                activity: "activity-2",
                call: "call-2",
                agent: "agent-2",
                displayName: "rollout two"
            ),
            projection: .empty,
            now: epoch
        )
        _ = reconciler.reduce(
            .hookSpawn(callID: call("call-2"), taskName: "hook two", command: "cmd two"),
            projection: .empty,
            now: epoch
        )
        _ = reconciler.reduce(
            .hookSpawn(callID: call("call-1"), taskName: "hook one", command: "cmd one"),
            projection: .empty,
            now: epoch
        )

        let first = reconciler.reduce(
            .hookStart(agentID: agent("agent-1"), subagentType: nil),
            projection: .empty,
            now: epoch
        )
        let second = reconciler.reduce(
            .hookStart(agentID: agent("agent-2"), subagentType: nil),
            projection: .empty,
            now: epoch
        )

        #expect(first.decisions.last == .enrichExisting(
            providerAgentID: agent("agent-1"),
            metadata: .init(displayName: "hook one", command: "cmd one")
        ))
        #expect(second.decisions.last == .enrichExisting(
            providerAgentID: agent("agent-2"),
            metadata: .init(displayName: "hook two", command: "cmd two")
        ))
    }

    @Test
    func duplicateHookStartsExpressReplaceVersusPreserveSemantics() {
        var reconciler = CodexSubagentReconciler(authority: .hooks)

        #expect(reconciler.reduce(
            .hookStart(agentID: agent("agent-1"), subagentType: "  researcher "),
            projection: .empty,
            now: epoch
        ).decisions == [
            .authoritativeHookReopen(
                providerAgentID: agent("agent-1"),
                display: .replace("researcher")
            ),
        ])

        for genericType in [nil, "", " default "] as [String?] {
            #expect(reconciler.reduce(
                .hookStart(agentID: agent("agent-1"), subagentType: genericType),
                projection: snapshot(active: ["agent-1"]),
                now: epoch
            ).decisions == [
                .authoritativeHookReopen(
                    providerAgentID: agent("agent-1"),
                    display: .preserveExisting(defaultValue: "Sub-agent")
                ),
            ])
        }

        var withResolvedHookTask = CodexSubagentReconciler(authority: .hooks)
        _ = withResolvedHookTask.reduce(
            .hookSpawn(callID: call("call-1"), taskName: "specific task", command: "cmd"),
            projection: .empty,
            now: epoch
        )
        _ = withResolvedHookTask.reduce(
            rolloutStart(
                activity: "activity-1",
                call: "call-1",
                agent: "agent-1",
                displayName: "rollout display"
            ),
            projection: .empty,
            now: epoch
        )
        #expect(withResolvedHookTask.reduce(
            .hookStart(agentID: agent("agent-1"), subagentType: "reviewer"),
            projection: .empty,
            now: epoch
        ).decisions == [
            .authoritativeHookReopen(
                providerAgentID: agent("agent-1"),
                display: .replace("reviewer")
            ),
            .enrichExisting(
                providerAgentID: agent("agent-1"),
                metadata: .init(displayName: "specific task", command: "cmd")
            ),
        ])
    }

    @Test
    func hookFinishBeforeStartBlocksRolloutButAuthoritativeStartReopens() {
        var reconciler = CodexSubagentReconciler(authority: .hooks)

        _ = reconciler.reduce(
            .hookSpawn(callID: call("call-1"), taskName: "task", command: "cmd"),
            projection: .empty,
            now: epoch
        )
        #expect(reconciler.reduce(
            .hookFinish(agentID: agent("agent-1")),
            projection: .empty,
            now: epoch
        ).decisions == [.finish(.providerAgent(agent("agent-1")))])

        let blocked = reconciler.reduce(
            rolloutStart(
                activity: "activity-1",
                call: "call-1",
                agent: "agent-1",
                displayName: "rollout"
            ),
            projection: .empty,
            now: epoch.addingTimeInterval(1)
        )
        #expect(blocked.decisions.isEmpty)
        #expect(blocked.diagnostics == [
            .ignored(observation: .rolloutStart, reason: .activeFinishTombstone),
        ])

        #expect(reconciler.reduce(
            .hookStart(agentID: agent("agent-1"), subagentType: nil),
            projection: .empty,
            now: epoch.addingTimeInterval(2)
        ).decisions == [
            .authoritativeHookReopen(
                providerAgentID: agent("agent-1"),
                display: .preserveExisting(defaultValue: "Sub-agent")
            ),
        ])
    }

    @Test
    func correlatedRolloutTurnLifecycleControlsHookAuthoritativeProviderActivity() {
        var reconciler = CodexSubagentReconciler(authority: .hooks)
        let activityID = activity("/root/teller_schema_contract")
        let providerAgentID = agent("thread-teller")

        #expect(reconciler.reduce(
            .rolloutTurnDeactivated(
                activityID: activityID,
                providerAgentID: providerAgentID
            ),
            projection: snapshot(active: ["thread-teller"]),
            now: epoch
        ).decisions == [.finish(.providerAgent(providerAgentID))])

        #expect(reconciler.reduce(
            .rolloutTurnActivated(
                activityID: activityID,
                providerAgentID: providerAgentID,
                displayName: "teller_schema_contract"
            ),
            projection: .empty,
            now: epoch.addingTimeInterval(1)
        ).decisions == [
            .authoritativeHookReopen(
                providerAgentID: providerAgentID,
                display: .replace("teller_schema_contract")
            ),
        ])

        #expect(reconciler.reduce(
            .rolloutTurnDeactivated(
                activityID: activityID,
                providerAgentID: providerAgentID
            ),
            projection: snapshot(active: ["thread-teller"]),
            now: epoch.addingTimeInterval(2)
        ).decisions == [.finish(.providerAgent(providerAgentID))])
    }

    @Test
    func correlatedRolloutFollowUpReopensFallbackActivityBeforeTombstoneExpiry() {
        var reconciler = CodexSubagentReconciler(authority: .rolloutFallback)
        let activityID = activity("/root/reusable")

        _ = reconciler.reduce(
            .rolloutTurnDeactivated(
                activityID: activityID,
                providerAgentID: nil
            ),
            projection: .empty,
            now: epoch
        )

        #expect(reconciler.reduce(
            .rolloutTurnActivated(
                activityID: activityID,
                providerAgentID: nil,
                displayName: "reusable"
            ),
            projection: .empty,
            now: epoch.addingTimeInterval(1)
        ).decisions == [
            .fallbackReopen(
                activityID: activityID,
                metadata: .init(displayName: "reusable")
            ),
        ])
    }

    @Test
    func fallbackFinishBlocksRestartUntilExactReceiveTimeTTLBoundary() {
        var reconciler = CodexSubagentReconciler(authority: .rolloutFallback)
        let activity = activity("rollout-1")

        _ = reconciler.reduce(
            .rolloutFinish(activityID: activity),
            projection: .empty,
            now: epoch
        )
        #expect(reconciler.reduce(
            rolloutStart(activity: "rollout-1", displayName: "worker", command: "cmd"),
            projection: .empty,
            now: epoch.addingTimeInterval(119.999)
        ).decisions.isEmpty)

        #expect(reconciler.reduce(
            rolloutStart(activity: "rollout-1", displayName: "worker", command: "cmd"),
            projection: .empty,
            now: epoch.addingTimeInterval(120)
        ).decisions == [
            .fallbackUpsert(
                activityID: activity,
                metadata: .init(displayName: "worker", command: "cmd")
            ),
        ])
    }

    @Test
    func fallbackFinishTombstonesUseTTLOnlyAcrossLargeBurst() {
        var reconciler = CodexSubagentReconciler(authority: .rolloutFallback)
        let burstSize = 1_000

        for index in 0 ..< burstSize {
            _ = reconciler.reduce(
                .rolloutFinish(activityID: activity("burst-\(index)")),
                projection: .empty,
                now: epoch
            )
        }

        for index in 0 ..< burstSize {
            let blocked = reconciler.reduce(
                rolloutStart(activity: "burst-\(index)", displayName: "blocked"),
                projection: .empty,
                now: epoch.addingTimeInterval(119.999)
            )
            #expect(blocked.decisions.isEmpty)
            #expect(blocked.diagnostics == [
                .ignored(observation: .rolloutStart, reason: .activeFinishTombstone),
            ])
        }

        for index in 0 ..< burstSize {
            #expect(reconciler.reduce(
                rolloutStart(activity: "burst-\(index)", displayName: "allowed"),
                projection: .empty,
                now: epoch.addingTimeInterval(120)
            ).decisions == [
                .fallbackUpsert(
                    activityID: activity("burst-\(index)"),
                    metadata: .init(displayName: "allowed")
                ),
            ])
        }
    }

    @Test
    func repeatedUnknownFinishRefreshesTombstoneReceiveTime() {
        var reconciler = CodexSubagentReconciler(authority: .rolloutFallback)

        #expect(reconciler.reduce(
            .rolloutFinish(activityID: activity("unknown")),
            projection: .empty,
            now: epoch
        ).decisions == [.finish(.rolloutActivity(activity("unknown")))])
        #expect(reconciler.reduce(
            .rolloutFinish(activityID: activity("unknown")),
            projection: .empty,
            now: epoch.addingTimeInterval(119)
        ).decisions == [.finish(.rolloutActivity(activity("unknown")))])

        #expect(reconciler.reduce(
            rolloutStart(activity: "unknown", displayName: "blocked"),
            projection: .empty,
            now: epoch.addingTimeInterval(120)
        ).decisions.isEmpty)
        #expect(reconciler.reduce(
            rolloutStart(activity: "unknown", displayName: "allowed"),
            projection: .empty,
            now: epoch.addingTimeInterval(239)
        ).decisions == [
            .fallbackUpsert(
                activityID: activity("unknown"),
                metadata: .init(displayName: "allowed")
            ),
        ])
    }

    @Test
    func pendingCorrelationCapacityUsesDeterministicInsertionOrderEviction() {
        var reconciler = CodexSubagentReconciler(
            authority: .hooks,
            configuration: .init(
                pendingCorrelationCapacity: 2,
                resolvedMetadataCapacity: 64,
                finishTombstoneTTL: 120
            )
        )

        _ = reconciler.reduce(
            .hookSpawn(callID: call("call-1"), taskName: "hook one", command: nil),
            projection: .empty,
            now: epoch
        )
        _ = reconciler.reduce(
            .hookSpawn(callID: call("call-2"), taskName: "hook two", command: nil),
            projection: .empty,
            now: epoch
        )
        _ = reconciler.reduce(
            .hookSpawn(callID: call("call-1"), taskName: "hook one updated", command: nil),
            projection: .empty,
            now: epoch
        )
        let third = reconciler.reduce(
            .hookSpawn(callID: call("call-3"), taskName: "hook three", command: nil),
            projection: .empty,
            now: epoch
        )
        #expect(third.diagnostics == [.evictedPendingCorrelation(call("call-1"))])

        let evicted = reconciler.reduce(
            rolloutStart(
                activity: "activity-1",
                call: "call-1",
                agent: "agent-1",
                displayName: "rollout one"
            ),
            projection: snapshot(active: ["agent-1"]),
            now: epoch
        )
        #expect(evicted.decisions == [
            .enrichExisting(
                providerAgentID: agent("agent-1"),
                metadata: .init(displayName: "rollout one")
            ),
        ])
        #expect(evicted.diagnostics == [.evictedPendingCorrelation(call("call-2"))])

        let retained = reconciler.reduce(
            rolloutStart(
                activity: "activity-3",
                call: "call-3",
                agent: "agent-3",
                displayName: "rollout three"
            ),
            projection: snapshot(active: ["agent-3"]),
            now: epoch
        )
        #expect(retained.decisions == [
            .enrichExisting(
                providerAgentID: agent("agent-3"),
                metadata: .init(displayName: "hook three")
            ),
        ])
    }

    @Test
    func resolvedMetadataCapacityUsesDeterministicInsertionOrderEviction() {
        var reconciler = CodexSubagentReconciler(
            authority: .hooks,
            configuration: .init(
                pendingCorrelationCapacity: 64,
                resolvedMetadataCapacity: 2,
                finishTombstoneTTL: 120
            )
        )

        for index in 1 ... 3 {
            _ = reconciler.reduce(
                .hookSpawn(
                    callID: call("call-\(index)"),
                    taskName: "hook \(index)",
                    command: nil
                ),
                projection: .empty,
                now: epoch
            )
            let result = reconciler.reduce(
                rolloutStart(
                    activity: "activity-\(index)",
                    call: "call-\(index)",
                    agent: "agent-\(index)",
                    displayName: "rollout \(index)"
                ),
                projection: .empty,
                now: epoch
            )
            if index == 3 {
                #expect(result.diagnostics == [
                    .evictedResolvedMetadata(agent("agent-1")),
                ])
            }
        }

        #expect(reconciler.reduce(
            .hookStart(agentID: agent("agent-1"), subagentType: nil),
            projection: .empty,
            now: epoch
        ).decisions.count == 1)
        #expect(reconciler.reduce(
            .hookStart(agentID: agent("agent-2"), subagentType: nil),
            projection: .empty,
            now: epoch
        ).decisions.last == .enrichExisting(
            providerAgentID: agent("agent-2"),
            metadata: .init(displayName: "hook 2")
        ))
    }

    @Test
    func fixedAuthorityTableSeparatesProjectionDecisionsFromDiagnostics() {
        var hooks = CodexSubagentReconciler(authority: .hooks)
        let missingCorrelationIDs = hooks.reduce(
            rolloutStart(activity: "activity", displayName: "rollout"),
            projection: .empty,
            now: epoch
        )
        #expect(missingCorrelationIDs.decisions.isEmpty)
        #expect(missingCorrelationIDs.diagnostics == [
            .ignored(
                observation: .rolloutStart,
                reason: .missingExactCorrelationIdentifiers
            ),
        ])
        #expect(hooks.reduce(
            .rolloutFinish(activityID: activity("activity")),
            projection: .empty,
            now: epoch
        ).diagnostics == [
            .ignored(observation: .rolloutFinish, reason: .incompatibleWithAuthority),
        ])
        #expect(hooks.reduce(
            .rolloutTurnActivated(
                activityID: activity("activity"),
                providerAgentID: nil,
                displayName: "worker"
            ),
            projection: .empty,
            now: epoch
        ).diagnostics == [
            .ignored(
                observation: .rolloutTurnActivated,
                reason: .missingExactCorrelationIdentifiers
            ),
        ])

        var fallback = CodexSubagentReconciler(authority: .rolloutFallback)
        let ignoredHook = fallback.reduce(
            .hookSpawn(callID: call("call"), taskName: "task", command: "cmd"),
            projection: .empty,
            now: epoch
        )
        #expect(ignoredHook.decisions.isEmpty)
        #expect(ignoredHook.diagnostics == [
            .ignored(observation: .hookSpawn, reason: .incompatibleWithAuthority),
        ])
        #expect(fallback.reduce(
            rolloutStart(
                activity: "activity",
                call: "call",
                agent: "agent",
                displayName: "rollout",
                command: "command"
            ),
            projection: snapshot(active: ["agent"]),
            now: epoch
        ).decisions == [
            .fallbackUpsert(
                activityID: activity("activity"),
                metadata: .init(displayName: "rollout", command: "command")
            ),
        ])
    }

    @Test
    func streamResetRetainsHookStateAndClearsOnlyFallbackProjection() {
        var hooks = CodexSubagentReconciler(authority: .hooks)
        _ = hooks.reduce(
            .hookSpawn(callID: call("call"), taskName: "hook", command: "cmd"),
            projection: .empty,
            now: epoch
        )
        _ = hooks.reduce(
            rolloutStart(
                activity: "activity",
                call: "call",
                agent: "agent",
                displayName: "rollout"
            ),
            projection: .empty,
            now: epoch
        )
        #expect(hooks.reduce(
            .streamReset,
            projection: .empty,
            now: epoch
        ) == .none)
        #expect(hooks.reduce(
            .hookStart(agentID: agent("agent"), subagentType: nil),
            projection: .empty,
            now: epoch
        ).decisions.last == .enrichExisting(
            providerAgentID: agent("agent"),
            metadata: .init(displayName: "hook", command: "cmd")
        ))

        var fallback = CodexSubagentReconciler(authority: .rolloutFallback)
        _ = fallback.reduce(
            .rolloutFinish(activityID: activity("activity")),
            projection: .empty,
            now: epoch
        )
        #expect(fallback.reduce(
            .streamReset,
            projection: .empty,
            now: epoch.addingTimeInterval(1)
        ).decisions == [.clearRolloutProjectedActivities])
        #expect(fallback.reduce(
            rolloutStart(activity: "activity", displayName: "still blocked"),
            projection: .empty,
            now: epoch.addingTimeInterval(2)
        ).decisions.isEmpty)
    }

    @Test
    func stopClearsMetadataAndTombstonesForBothAuthorities() {
        var hooks = CodexSubagentReconciler(authority: .hooks)
        _ = hooks.reduce(
            .hookSpawn(callID: call("call"), taskName: "hook", command: "cmd"),
            projection: .empty,
            now: epoch
        )
        _ = hooks.reduce(
            rolloutStart(
                activity: "activity",
                call: "call",
                agent: "agent",
                displayName: "rollout"
            ),
            projection: .empty,
            now: epoch
        )
        #expect(hooks.reduce(.stop, projection: .empty, now: epoch) == .none)
        #expect(hooks.reduce(
            .hookStart(agentID: agent("agent"), subagentType: nil),
            projection: .empty,
            now: epoch
        ).decisions.count == 1)

        var fallback = CodexSubagentReconciler(authority: .rolloutFallback)
        _ = fallback.reduce(
            .rolloutFinish(activityID: activity("activity")),
            projection: .empty,
            now: epoch
        )
        #expect(fallback.reduce(.stop, projection: .empty, now: epoch) == .none)
        #expect(fallback.reduce(
            rolloutStart(activity: "activity", displayName: "allowed"),
            projection: .empty,
            now: epoch.addingTimeInterval(1)
        ).decisions == [
            .fallbackUpsert(
                activityID: activity("activity"),
                metadata: .init(displayName: "allowed")
            ),
        ])
    }

    @Test
    func reconcilerInstancesKeepSessionStateIsolated() {
        var first = CodexSubagentReconciler(authority: .rolloutFallback)
        var second = CodexSubagentReconciler(authority: .rolloutFallback)

        _ = first.reduce(
            .rolloutFinish(activityID: activity("same-id")),
            projection: .empty,
            now: epoch
        )

        #expect(first.reduce(
            rolloutStart(activity: "same-id", displayName: "blocked"),
            projection: .empty,
            now: epoch.addingTimeInterval(1)
        ).decisions.isEmpty)
        #expect(second.reduce(
            rolloutStart(activity: "same-id", displayName: "independent"),
            projection: .empty,
            now: epoch.addingTimeInterval(1)
        ).decisions == [
            .fallbackUpsert(
                activityID: activity("same-id"),
                metadata: .init(displayName: "independent")
            ),
        ])
    }

    private func call(_ rawValue: String) -> SpawnCallID {
        SpawnCallID(rawValue)!
    }

    private func agent(_ rawValue: String) -> ProviderAgentID {
        ProviderAgentID(rawValue)!
    }

    private func activity(_ rawValue: String) -> ActivityID {
        ActivityID(rawValue)!
    }

    private func snapshot(active rawValues: [String]) -> CodexSubagentProjectionSnapshot {
        CodexSubagentProjectionSnapshot(
            activeProviderAgentIDs: Set(rawValues.map(agent))
        )
    }

    private func rolloutStart(
        activity activityRawValue: String,
        call callRawValue: String? = nil,
        agent agentRawValue: String? = nil,
        displayName: String? = nil,
        command: String? = nil
    ) -> CodexSubagentObservation {
        .rolloutStart(
            activityID: activity(activityRawValue),
            spawnCallID: callRawValue.map(call),
            providerAgentID: agentRawValue.map(agent),
            displayName: displayName,
            command: command
        )
    }
}
