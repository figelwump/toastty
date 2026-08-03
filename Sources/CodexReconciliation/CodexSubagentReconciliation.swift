import Foundation

public struct SpawnCallID: Hashable, Sendable {
    public let rawValue: String

    public init?(_ rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return nil }
        self.rawValue = normalized
    }
}

public struct ProviderAgentID: Hashable, Sendable {
    public let rawValue: String

    public init?(_ rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return nil }
        self.rawValue = normalized
    }
}

/// The rollout-local activity identity selected by the caller. Reconciliation
/// deliberately performs no aliasing or path normalization on this value.
public struct ActivityID: Hashable, Sendable {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        self.rawValue = rawValue
    }
}

public enum CodexSubagentAuthority: Equatable, Sendable {
    case hooks
    case rolloutFallback
}

public struct CodexSubagentReconciliationConfiguration: Equatable, Sendable {
    public var pendingCorrelationCapacity: Int
    public var resolvedMetadataCapacity: Int
    public var finishTombstoneTTL: TimeInterval

    public init(
        pendingCorrelationCapacity: Int = 64,
        resolvedMetadataCapacity: Int = 64,
        finishTombstoneTTL: TimeInterval = 120
    ) {
        precondition(pendingCorrelationCapacity >= 0)
        precondition(resolvedMetadataCapacity >= 0)
        precondition(finishTombstoneTTL >= 0)
        self.pendingCorrelationCapacity = pendingCorrelationCapacity
        self.resolvedMetadataCapacity = resolvedMetadataCapacity
        self.finishTombstoneTTL = finishTombstoneTTL
    }
}

public struct CodexSubagentProjectionMetadata: Equatable, Sendable {
    public let displayName: String?
    public let command: String?

    public init(displayName: String? = nil, command: String? = nil) {
        self.displayName = displayName
        self.command = command
    }

    public var isEmpty: Bool {
        displayName == nil && command == nil
    }

    fileprivate func mergingFallback(
        _ fallback: CodexSubagentProjectionMetadata
    ) -> CodexSubagentProjectionMetadata {
        CodexSubagentProjectionMetadata(
            displayName: displayName ?? fallback.displayName,
            command: command ?? fallback.command
        )
    }
}

public enum CodexSubagentObservation: Equatable, Sendable {
    /// `taskName` and `command` are expected to be normalized by the hook
    /// adapter, including its existing empty/ciphertext-only suppression.
    case hookSpawn(
        callID: SpawnCallID,
        taskName: String?,
        command: String?
    )
    case hookStart(
        agentID: ProviderAgentID,
        subagentType: String?
    )
    case hookFinish(agentID: ProviderAgentID)
    case rolloutStart(
        activityID: ActivityID,
        spawnCallID: SpawnCallID?,
        providerAgentID: ProviderAgentID?,
        displayName: String?,
        /// Used by fallback projection only. Hook authority accepts rollout
        /// display as a fallback but keeps command authority with hook data.
        command: String?
    )
    case rolloutFinish(activityID: ActivityID)
    case streamReset
    case stop
}

public struct CodexSubagentProjectionSnapshot: Equatable, Sendable {
    public let activeProviderAgentIDs: Set<ProviderAgentID>

    public init(activeProviderAgentIDs: Set<ProviderAgentID>) {
        self.activeProviderAgentIDs = activeProviderAgentIDs
    }

    public static let empty = CodexSubagentProjectionSnapshot(activeProviderAgentIDs: [])
}

/// Controls only the display name supplied while reopening a hook-authoritative
/// activity. The application layer must preserve an existing command in both
/// cases and must preserve the existing display for `preserveExisting`.
public enum CodexSubagentHookReopenDisplay: Equatable, Sendable {
    case replace(String)
    case preserveExisting(defaultValue: String)
}

public enum CodexSubagentProjectedActivityID: Equatable, Sendable {
    case providerAgent(ProviderAgentID)
    case rolloutActivity(ActivityID)
}

public enum CodexSubagentProjectionDecision: Equatable, Sendable {
    case fallbackUpsert(
        activityID: ActivityID,
        metadata: CodexSubagentProjectionMetadata
    )
    case authoritativeHookReopen(
        providerAgentID: ProviderAgentID,
        display: CodexSubagentHookReopenDisplay
    )
    /// Merge non-nil fields into the existing activity. This decision must not
    /// create a second registry row when the provider activity is already active.
    case enrichExisting(
        providerAgentID: ProviderAgentID,
        metadata: CodexSubagentProjectionMetadata
    )
    case finish(CodexSubagentProjectedActivityID)
    case clearRolloutProjectedActivities
}

public enum CodexSubagentObservationKind: Equatable, Sendable {
    case hookSpawn
    case hookStart
    case hookFinish
    case rolloutStart
    case rolloutFinish
    case streamReset
    case stop
}

public enum CodexSubagentIgnoredReason: Equatable, Sendable {
    case incompatibleWithAuthority
    case missingExactCorrelationIdentifiers
    case activeFinishTombstone
}

public enum CodexSubagentDiagnostic: Equatable, Sendable {
    case ignored(
        observation: CodexSubagentObservationKind,
        reason: CodexSubagentIgnoredReason
    )
    case evictedPendingCorrelation(SpawnCallID)
    case evictedResolvedMetadata(ProviderAgentID)
}

public struct CodexSubagentReduction: Equatable, Sendable {
    public let decisions: [CodexSubagentProjectionDecision]
    public let diagnostics: [CodexSubagentDiagnostic]

    public init(
        decisions: [CodexSubagentProjectionDecision] = [],
        diagnostics: [CodexSubagentDiagnostic] = []
    ) {
        self.decisions = decisions
        self.diagnostics = diagnostics
    }

    public static let none = CodexSubagentReduction()
}

/// Pure, session-local reconciliation state. Authority is fixed for the
/// lifetime of an instance; changing authority requires constructing a new one.
public struct CodexSubagentReconciler: Equatable, Sendable {
    public let authority: CodexSubagentAuthority
    public let configuration: CodexSubagentReconciliationConfiguration

    private struct PendingCorrelation: Equatable, Sendable {
        var observedHookSpawn = false
        var hookMetadata = CodexSubagentProjectionMetadata()
        var rolloutDisplayName: String?
        var providerAgentID: ProviderAgentID?

        var resolvedMetadata: CodexSubagentProjectionMetadata {
            hookMetadata.mergingFallback(
                CodexSubagentProjectionMetadata(displayName: rolloutDisplayName)
            )
        }

        var isComplete: Bool {
            observedHookSpawn && providerAgentID != nil
        }
    }

    private enum FinishTombstoneID: Hashable, Sendable {
        case providerAgent(ProviderAgentID)
        case rolloutActivity(ActivityID)
    }

    private var pendingCorrelationsByCallID: [SpawnCallID: PendingCorrelation] = [:]
    private var orderedPendingCallIDs: [SpawnCallID] = []
    private var resolvedMetadataByProviderAgentID: [
        ProviderAgentID: CodexSubagentProjectionMetadata
    ] = [:]
    private var orderedResolvedProviderAgentIDs: [ProviderAgentID] = []
    private var finishTombstonesByID: [FinishTombstoneID: Date] = [:]

    public init(
        authority: CodexSubagentAuthority,
        configuration: CodexSubagentReconciliationConfiguration = .init()
    ) {
        self.authority = authority
        self.configuration = configuration
    }

    public mutating func reduce(
        _ observation: CodexSubagentObservation,
        projection: CodexSubagentProjectionSnapshot,
        now: Date
    ) -> CodexSubagentReduction {
        pruneExpiredTombstones(at: now)

        switch authority {
        case .hooks:
            return reduceWithHookAuthority(observation, projection: projection, now: now)
        case .rolloutFallback:
            return reduceWithRolloutFallbackAuthority(observation, now: now)
        }
    }

    private mutating func reduceWithHookAuthority(
        _ observation: CodexSubagentObservation,
        projection: CodexSubagentProjectionSnapshot,
        now: Date
    ) -> CodexSubagentReduction {
        switch observation {
        case .hookSpawn(let callID, let taskName, let command):
            var diagnostics: [CodexSubagentDiagnostic] = []
            var correlation = pendingCorrelationsByCallID[callID] ?? PendingCorrelation()
            correlation.observedHookSpawn = true
            correlation.hookMetadata = CodexSubagentProjectionMetadata(
                displayName: meaningfulDisplayName(taskName),
                command: command
            )
            upsertPendingCorrelation(
                correlation,
                callID: callID,
                diagnostics: &diagnostics
            )
            let decisions = resolvePendingCorrelation(
                callID: callID,
                projection: projection,
                now: now,
                diagnostics: &diagnostics
            )
            return CodexSubagentReduction(decisions: decisions, diagnostics: diagnostics)

        case .hookStart(let agentID, let subagentType):
            clearTombstone(for: .providerAgent(agentID))
            let display: CodexSubagentHookReopenDisplay
            if let meaningfulType = meaningfulDisplayName(subagentType) {
                display = .replace(meaningfulType)
            } else {
                display = .preserveExisting(defaultValue: "Sub-agent")
            }

            var decisions: [CodexSubagentProjectionDecision] = [
                .authoritativeHookReopen(providerAgentID: agentID, display: display),
            ]
            if let metadata = removeResolvedMetadata(for: agentID) {
                decisions.append(.enrichExisting(providerAgentID: agentID, metadata: metadata))
            }
            return CodexSubagentReduction(decisions: decisions)

        case .hookFinish(let agentID):
            clearMetadata(for: agentID)
            recordTombstone(for: .providerAgent(agentID), at: now)
            return CodexSubagentReduction(decisions: [
                .finish(.providerAgent(agentID)),
            ])

        case .rolloutStart(
            _,
            let spawnCallID,
            let providerAgentID,
            let displayName,
            _
        ):
            guard let spawnCallID, let providerAgentID else {
                return ignored(
                    .rolloutStart,
                    because: .missingExactCorrelationIdentifiers
                )
            }
            guard isTombstoned(.providerAgent(providerAgentID), at: now) == false else {
                removePendingCorrelation(for: spawnCallID)
                _ = removeResolvedMetadata(for: providerAgentID)
                return ignored(.rolloutStart, because: .activeFinishTombstone)
            }

            var diagnostics: [CodexSubagentDiagnostic] = []
            var correlation = pendingCorrelationsByCallID[spawnCallID] ?? PendingCorrelation()
            correlation.providerAgentID = providerAgentID
            correlation.rolloutDisplayName = meaningfulDisplayName(displayName)
            upsertPendingCorrelation(
                correlation,
                callID: spawnCallID,
                diagnostics: &diagnostics
            )
            let decisions = resolvePendingCorrelation(
                callID: spawnCallID,
                projection: projection,
                now: now,
                diagnostics: &diagnostics
            )
            return CodexSubagentReduction(decisions: decisions, diagnostics: diagnostics)

        case .rolloutFinish:
            return ignored(.rolloutFinish, because: .incompatibleWithAuthority)

        case .streamReset:
            return .none

        case .stop:
            clearAllState()
            return .none
        }
    }

    private mutating func reduceWithRolloutFallbackAuthority(
        _ observation: CodexSubagentObservation,
        now: Date
    ) -> CodexSubagentReduction {
        switch observation {
        case .hookSpawn:
            return ignored(.hookSpawn, because: .incompatibleWithAuthority)
        case .hookStart:
            return ignored(.hookStart, because: .incompatibleWithAuthority)
        case .hookFinish:
            return ignored(.hookFinish, because: .incompatibleWithAuthority)

        case .rolloutStart(let activityID, _, _, let displayName, let command):
            guard isTombstoned(.rolloutActivity(activityID), at: now) == false else {
                return ignored(.rolloutStart, because: .activeFinishTombstone)
            }
            return CodexSubagentReduction(decisions: [
                .fallbackUpsert(
                    activityID: activityID,
                    metadata: CodexSubagentProjectionMetadata(
                        displayName: displayName,
                        command: command
                    )
                ),
            ])

        case .rolloutFinish(let activityID):
            recordTombstone(for: .rolloutActivity(activityID), at: now)
            return CodexSubagentReduction(decisions: [
                .finish(.rolloutActivity(activityID)),
            ])

        case .streamReset:
            return CodexSubagentReduction(decisions: [.clearRolloutProjectedActivities])

        case .stop:
            clearAllState()
            return .none
        }
    }

    private mutating func resolvePendingCorrelation(
        callID: SpawnCallID,
        projection: CodexSubagentProjectionSnapshot,
        now: Date,
        diagnostics: inout [CodexSubagentDiagnostic]
    ) -> [CodexSubagentProjectionDecision] {
        guard let correlation = pendingCorrelationsByCallID[callID],
              let providerAgentID = correlation.providerAgentID else {
            return []
        }

        if isTombstoned(.providerAgent(providerAgentID), at: now) {
            removePendingCorrelation(for: callID)
            _ = removeResolvedMetadata(for: providerAgentID)
            return []
        }

        let metadata = correlation.resolvedMetadata
        var decisions: [CodexSubagentProjectionDecision] = []
        if metadata.isEmpty == false {
            if projection.activeProviderAgentIDs.contains(providerAgentID) {
                decisions.append(
                    .enrichExisting(providerAgentID: providerAgentID, metadata: metadata)
                )
            } else {
                upsertResolvedMetadata(
                    metadata,
                    providerAgentID: providerAgentID,
                    diagnostics: &diagnostics
                )
            }
        }

        if correlation.isComplete {
            removePendingCorrelation(for: callID)
        }
        return decisions
    }

    private mutating func upsertPendingCorrelation(
        _ correlation: PendingCorrelation,
        callID: SpawnCallID,
        diagnostics: inout [CodexSubagentDiagnostic]
    ) {
        if pendingCorrelationsByCallID[callID] == nil {
            orderedPendingCallIDs.append(callID)
        }
        pendingCorrelationsByCallID[callID] = correlation

        while orderedPendingCallIDs.count > configuration.pendingCorrelationCapacity {
            let evictedCallID = orderedPendingCallIDs.removeFirst()
            pendingCorrelationsByCallID.removeValue(forKey: evictedCallID)
            diagnostics.append(.evictedPendingCorrelation(evictedCallID))
        }
    }

    private mutating func removePendingCorrelation(for callID: SpawnCallID) {
        pendingCorrelationsByCallID.removeValue(forKey: callID)
        orderedPendingCallIDs.removeAll { $0 == callID }
    }

    private mutating func upsertResolvedMetadata(
        _ metadata: CodexSubagentProjectionMetadata,
        providerAgentID: ProviderAgentID,
        diagnostics: inout [CodexSubagentDiagnostic]
    ) {
        if let existing = resolvedMetadataByProviderAgentID[providerAgentID] {
            resolvedMetadataByProviderAgentID[providerAgentID] = metadata.mergingFallback(existing)
            return
        }

        resolvedMetadataByProviderAgentID[providerAgentID] = metadata
        orderedResolvedProviderAgentIDs.append(providerAgentID)
        while orderedResolvedProviderAgentIDs.count > configuration.resolvedMetadataCapacity {
            let evictedAgentID = orderedResolvedProviderAgentIDs.removeFirst()
            resolvedMetadataByProviderAgentID.removeValue(forKey: evictedAgentID)
            diagnostics.append(.evictedResolvedMetadata(evictedAgentID))
        }
    }

    @discardableResult
    private mutating func removeResolvedMetadata(
        for providerAgentID: ProviderAgentID
    ) -> CodexSubagentProjectionMetadata? {
        orderedResolvedProviderAgentIDs.removeAll { $0 == providerAgentID }
        return resolvedMetadataByProviderAgentID.removeValue(forKey: providerAgentID)
    }

    private mutating func clearMetadata(for providerAgentID: ProviderAgentID) {
        _ = removeResolvedMetadata(for: providerAgentID)
        let matchingCallIDs = pendingCorrelationsByCallID.compactMap { callID, correlation in
            correlation.providerAgentID == providerAgentID ? callID : nil
        }
        for callID in matchingCallIDs {
            removePendingCorrelation(for: callID)
        }
    }

    private mutating func recordTombstone(for id: FinishTombstoneID, at now: Date) {
        finishTombstonesByID[id] = now
    }

    private mutating func clearTombstone(for id: FinishTombstoneID) {
        finishTombstonesByID.removeValue(forKey: id)
    }

    private func isTombstoned(_ id: FinishTombstoneID, at now: Date) -> Bool {
        guard let recordedAt = finishTombstonesByID[id] else { return false }
        return now.timeIntervalSince(recordedAt) < configuration.finishTombstoneTTL
    }

    private mutating func pruneExpiredTombstones(at now: Date) {
        finishTombstonesByID = finishTombstonesByID.filter { _, recordedAt in
            now.timeIntervalSince(recordedAt) < configuration.finishTombstoneTTL
        }
    }

    private mutating func clearAllState() {
        pendingCorrelationsByCallID = [:]
        orderedPendingCallIDs = []
        resolvedMetadataByProviderAgentID = [:]
        orderedResolvedProviderAgentIDs = []
        finishTombstonesByID = [:]
    }

    private func ignored(
        _ observation: CodexSubagentObservationKind,
        because reason: CodexSubagentIgnoredReason
    ) -> CodexSubagentReduction {
        CodexSubagentReduction(diagnostics: [
            .ignored(observation: observation, reason: reason),
        ])
    }

    private func meaningfulDisplayName(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false,
              normalized.caseInsensitiveCompare("default") != .orderedSame else {
            return nil
        }
        return normalized
    }
}
