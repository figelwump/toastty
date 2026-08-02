import Foundation

/// Selects which provider signal may make approval decisions for a session.
/// The authority is fixed when the session reconciliation runtime is created.
public enum CodexApprovalAuthority: Equatable, Sendable {
    case hooks
    case sessionLogFallback
    /// Temporary compatibility for sessions created before source selection
    /// was made explicit. New callers should choose a fixed authority.
    case legacyPermissive
}

public enum CodexApprovalSource: Equatable, Sendable {
    case hook
    case sessionLog
}

/// Records whether the provider supplied the request's turn identity. A turn
/// borrowed from root state can be used for correlation, but must not be added
/// to the auto-reviewed history as if the provider had observed it.
public enum CodexApprovalTurnProvenance: Equatable, Sendable {
    case sourceObserved
    case rootFallback
}

public struct CodexApprovalRequest: Equatable, Sendable {
    public let source: CodexApprovalSource
    public let threadID: String?
    public let turnID: String?
    public let turnProvenance: CodexApprovalTurnProvenance

    public init(
        source: CodexApprovalSource,
        threadID: String?,
        turnID: String?,
        turnProvenance: CodexApprovalTurnProvenance
    ) {
        self.source = source
        self.threadID = threadID
        self.turnID = turnID
        self.turnProvenance = turnProvenance
    }
}

public struct CodexApprovalSnapshot: Equatable, Sendable {
    public let autoReviewedTurnIDs: [String]

    public init(autoReviewedTurnIDs: [String] = []) {
        self.autoReviewedTurnIDs = autoReviewedTurnIDs
    }

    public static let empty = CodexApprovalSnapshot()
}

/// Stable policy reasons. Application adapters may map these to provider-
/// specific log strings without moving decision policy back into the App.
public enum CodexApprovalReason: Equatable, Sendable {
    case incompatibleWithAuthority
    case missingRequestThread
    case missingRootThread
    case threadMismatch
    case missingRequestTurn
    case missingRootTurn
    case autoReviewedStaleTurn
    case autoReviewContextTurnMismatch
    case turnMismatch
    case awaitingRootTurnContext
    case missingApprovalContext
    case unknownApprovalsReviewer
    case missingHumanApprovalPolicy
    case missingApprovalsReviewer
    case autoReviewApproval
}

public enum CodexApprovalDecision: Equatable, Sendable {
    case accept(reason: CodexApprovalReason)
    case suppress(reason: CodexApprovalReason)
    case ignore(reason: CodexApprovalReason)
    case deferForContext(reason: CodexApprovalReason)

    fileprivate var isSuppression: Bool {
        if case .suppress = self { return true }
        return false
    }
}

public struct CodexApprovalReduction: Equatable, Sendable {
    public let decision: CodexApprovalDecision
    public let didMutateHistory: Bool
    public let snapshot: CodexApprovalSnapshot

    public init(
        decision: CodexApprovalDecision,
        didMutateHistory: Bool,
        snapshot: CodexApprovalSnapshot
    ) {
        self.decision = decision
        self.didMutateHistory = didMutateHistory
        self.snapshot = snapshot
    }
}

/// Pure, session-local approval policy and bounded auto-review history.
/// Parsing, pending timers, status projection, effects, and logging remain
/// application concerns.
public struct CodexApprovalReconciler: Equatable, Sendable {
    public static let maximumAutoReviewedTurnCount = 16

    public let authority: CodexApprovalAuthority
    private var autoReviewedTurnIDs: [String]

    public init(authority: CodexApprovalAuthority) {
        self.authority = authority
        autoReviewedTurnIDs = []
    }

    public var snapshot: CodexApprovalSnapshot {
        CodexApprovalSnapshot(autoReviewedTurnIDs: autoReviewedTurnIDs)
    }

    public mutating func reduce(
        _ request: CodexApprovalRequest,
        root: CodexRootTurnSnapshot
    ) -> CodexApprovalReduction {
        let previousSnapshot = snapshot
        let decision = decision(for: request, root: root)

        if decision.isSuppression,
           request.turnProvenance == .sourceObserved,
           let normalizedTurnID = normalizedNonEmpty(request.turnID),
           !autoReviewedTurnIDs.contains(normalizedTurnID) {
            autoReviewedTurnIDs.append(normalizedTurnID)
            let overflow = autoReviewedTurnIDs.count - Self.maximumAutoReviewedTurnCount
            if overflow > 0 {
                autoReviewedTurnIDs.removeFirst(overflow)
            }
        }

        let nextSnapshot = snapshot
        return CodexApprovalReduction(
            decision: decision,
            didMutateHistory: previousSnapshot != nextSnapshot,
            snapshot: nextSnapshot
        )
    }

    @discardableResult
    public mutating func resetTurnHistory() -> Bool {
        guard !autoReviewedTurnIDs.isEmpty else { return false }
        autoReviewedTurnIDs.removeAll()
        return true
    }

    private func decision(
        for request: CodexApprovalRequest,
        root: CodexRootTurnSnapshot
    ) -> CodexApprovalDecision {
        guard accepts(request.source) else {
            return .ignore(reason: .incompatibleWithAuthority)
        }
        guard let requestThreadID = request.threadID else {
            return .suppress(reason: .missingRequestThread)
        }
        guard let rootThreadID = root.rootThreadID else {
            return .deferForContext(reason: .missingRootThread)
        }
        guard requestThreadID == rootThreadID else {
            return .ignore(reason: .threadMismatch)
        }
        guard let requestTurnID = request.turnID else {
            return .suppress(reason: .missingRequestTurn)
        }
        guard let rootTurnID = root.rootTurnID else {
            guard root.pendingRootInputFingerprint != nil else {
                return .suppress(reason: .missingRootTurn)
            }
            return .deferForContext(reason: .missingRootTurn)
        }
        if requestTurnID != rootTurnID,
           autoReviewedTurnIDs.contains(requestTurnID) {
            return .ignore(reason: .autoReviewedStaleTurn)
        }
        if requestTurnID != rootTurnID,
           hasApplicableReviewer(root: root) {
            return .suppress(reason: .autoReviewContextTurnMismatch)
        }
        guard requestTurnID == rootTurnID else {
            return .ignore(reason: .turnMismatch)
        }
        guard !root.isAwaitingSessionLogContext else {
            return .deferForContext(reason: .awaitingRootTurnContext)
        }
        guard let context = root.currentApprovalContext else {
            return .deferForContext(reason: .missingApprovalContext)
        }

        let approvalPolicy = normalizedNonEmpty(context.approvalPolicy.stringValue)
        let approvalsReviewer = normalizedNonEmpty(context.approvalsReviewer.stringValue)
        guard approvalsReviewer == nil else {
            return .suppress(reason: .autoReviewApproval)
        }
        guard context.approvalsReviewer.isSpecified else {
            return .deferForContext(reason: .unknownApprovalsReviewer)
        }
        guard requiresHumanApproval(approvalPolicy) else {
            return .suppress(reason: .missingHumanApprovalPolicy)
        }
        return .accept(reason: .missingApprovalsReviewer)
    }

    private func accepts(_ source: CodexApprovalSource) -> Bool {
        switch (authority, source) {
        case (.hooks, .hook), (.sessionLogFallback, .sessionLog), (.legacyPermissive, _):
            return true
        case (.hooks, .sessionLog), (.sessionLogFallback, .hook):
            return false
        }
    }

    private func hasApplicableReviewer(root: CodexRootTurnSnapshot) -> Bool {
        if normalizedNonEmpty(root.currentApprovalContext?.approvalsReviewer.stringValue) != nil {
            return true
        }
        guard root.isAwaitingSessionLogContext else { return false }
        return normalizedNonEmpty(
            root.activeApprovalContext?.approvalsReviewer.stringValue
        ) != nil
    }

    private func requiresHumanApproval(_ policy: String?) -> Bool {
        guard let policy = normalizedNonEmpty(policy)?.lowercased() else {
            return false
        }
        return policy != "never"
    }

    private func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

public struct CodexApprovalCorrelation: Equatable, Sendable {
    public let threadID: String?
    public let turnID: String?

    public init(threadID: String?, turnID: String?) {
        self.threadID = threadID
        self.turnID = turnID
    }
}

public enum CodexApprovalSupersession {
    public static func shouldSupersede(
        pending: CodexApprovalCorrelation,
        incoming: CodexApprovalCorrelation
    ) -> Bool {
        var threadMatches = false
        if let incomingThreadID = incoming.threadID,
           let pendingThreadID = pending.threadID {
            guard incomingThreadID == pendingThreadID else { return false }
            threadMatches = true
        }
        if let incomingTurnID = incoming.turnID,
           let pendingTurnID = pending.turnID {
            if incomingTurnID == pendingTurnID {
                return true
            }
            return threadMatches
        }
        return threadMatches
    }
}
