import Foundation

/// Selects which provider lifecycle signal may qualify root hook/notify events.
/// Launch-log identity and context observations remain valid for every authority.
public enum CodexRootTurnAuthority: Equatable, Sendable {
    case hooks
    case sessionLogFallback
    /// Temporary compatibility for sessions launched before source selection was
    /// made explicit. New callers should choose one of the fixed authorities.
    case legacyPermissive
}

/// A lossless session-log field: omission retains an existing value, `null`
/// explicitly clears it, and `string` replaces it.
public enum CodexRootTurnContextField: Equatable, Sendable {
    case unspecified
    case null
    case string(String)

    public var isSpecified: Bool {
        switch self {
        case .unspecified:
            return false
        case .null, .string:
            return true
        }
    }

    public var stringValue: String? {
        switch self {
        case .unspecified, .null:
            return nil
        case .string(let value):
            return value
        }
    }
}

public struct CodexRootTurnApprovalContext: Equatable, Sendable {
    public var approvalPolicy: CodexRootTurnContextField
    public var approvalsReviewer: CodexRootTurnContextField

    public init(
        approvalPolicy: CodexRootTurnContextField = .unspecified,
        approvalsReviewer: CodexRootTurnContextField = .unspecified
    ) {
        self.approvalPolicy = approvalPolicy
        self.approvalsReviewer = approvalsReviewer
    }

    public var hasSpecifiedField: Bool {
        approvalPolicy.isSpecified || approvalsReviewer.isSpecified
    }
}

public enum CodexRootTurnHookKind: Equatable, Sendable {
    case sessionStart(isClear: Bool)
    case userPromptSubmit
    case stop
    case other

    fileprivate var canLatchRootThread: Bool {
        switch self {
        case .sessionStart, .userPromptSubmit:
            return true
        case .stop, .other:
            return false
        }
    }

    fileprivate var isClearSessionStart: Bool {
        if case .sessionStart(isClear: true) = self { return true }
        return false
    }
}

public enum CodexRootTurnObservation: Equatable, Sendable {
    case launchLogRootInput(
        fingerprint: String?,
        threadID: String?,
        turnID: String?,
        context: CodexRootTurnApprovalContext
    )
    case launchLogOverrideContext(CodexRootTurnApprovalContext)
    case hook(
        kind: CodexRootTurnHookKind,
        threadID: String?,
        turnID: String?,
        promptFingerprint: String?
    )
    case fallbackNotifyThreadCandidate(threadID: String, inputFingerprint: String?)
}

public struct CodexRootTurnSnapshot: Equatable, Sendable {
    public let rootThreadID: String?
    public let rootTurnID: String?
    public let rootTurnInputFingerprint: String?
    public let isAwaitingSessionLogContext: Bool
    public let pendingRootInputFingerprint: String?
    public let pendingApprovalContext: CodexRootTurnApprovalContext?
    public let activeApprovalContext: CodexRootTurnApprovalContext?
    public let currentApprovalContext: CodexRootTurnApprovalContext?

    public init(
        rootThreadID: String? = nil,
        rootTurnID: String? = nil,
        rootTurnInputFingerprint: String? = nil,
        isAwaitingSessionLogContext: Bool = false,
        pendingRootInputFingerprint: String? = nil,
        pendingApprovalContext: CodexRootTurnApprovalContext? = nil,
        activeApprovalContext: CodexRootTurnApprovalContext? = nil,
        currentApprovalContext: CodexRootTurnApprovalContext? = nil
    ) {
        self.rootThreadID = rootThreadID
        self.rootTurnID = rootTurnID
        self.rootTurnInputFingerprint = rootTurnInputFingerprint
        self.isAwaitingSessionLogContext = isAwaitingSessionLogContext
        self.pendingRootInputFingerprint = pendingRootInputFingerprint
        self.pendingApprovalContext = pendingApprovalContext
        self.activeApprovalContext = activeApprovalContext
        self.currentApprovalContext = currentApprovalContext
    }

    public static let empty = CodexRootTurnSnapshot()
}

/// Whether downstream approval/completion policy should continue evaluating the
/// provider event. A proceeding observation may still be a root-state no-op.
public enum CodexRootTurnQualification: Equatable, Sendable {
    case proceed
    case rejectEvent
}

public enum CodexRootTurnReductionReason: Equatable, Sendable {
    case launchLogRootInput
    case launchLogOverrideContext
    case hookAccepted
    case hookOther
    case fallbackNotifyThreadMatched
    case fallbackNotifyThreadLatched
    case incompatibleWithAuthority
    case threadMismatch
    case missingRootThread
    case turnMismatch
    case missingRootInputFingerprint
    case missingNotifyInputFingerprint
    case inputFingerprintMismatch
}

public struct CodexRootTurnReduction: Equatable, Sendable {
    public let qualification: CodexRootTurnQualification
    public let didMutateRootState: Bool
    public let shouldClearLegacyAutoReviewedTurns: Bool
    public let reason: CodexRootTurnReductionReason
    public let snapshot: CodexRootTurnSnapshot

    public init(
        qualification: CodexRootTurnQualification,
        didMutateRootState: Bool,
        shouldClearLegacyAutoReviewedTurns: Bool,
        reason: CodexRootTurnReductionReason,
        snapshot: CodexRootTurnSnapshot
    ) {
        self.qualification = qualification
        self.didMutateRootState = didMutateRootState
        self.shouldClearLegacyAutoReviewedTurns = shouldClearLegacyAutoReviewedTurns
        self.reason = reason
        self.snapshot = snapshot
    }
}

/// Pure, session-local root identity and structured approval-context state.
/// Parsing, approval decisions, status projection, effects, and logging remain
/// application concerns.
public struct CodexRootTurnReconciler: Equatable, Sendable {
    public let authority: CodexRootTurnAuthority

    private var rootThreadID: String?
    private var rootTurnID: String?
    private var rootTurnInputFingerprint: String?
    private var isAwaitingSessionLogContext = false
    private var pendingRootInputFingerprint: String?
    private var pendingApprovalContext: CodexRootTurnApprovalContext?
    private var activeApprovalContext: CodexRootTurnApprovalContext?
    private var currentApprovalContext: CodexRootTurnApprovalContext?

    public init(authority: CodexRootTurnAuthority) {
        self.authority = authority
    }

    public var snapshot: CodexRootTurnSnapshot {
        CodexRootTurnSnapshot(
            rootThreadID: rootThreadID,
            rootTurnID: rootTurnID,
            rootTurnInputFingerprint: rootTurnInputFingerprint,
            isAwaitingSessionLogContext: isAwaitingSessionLogContext,
            pendingRootInputFingerprint: pendingRootInputFingerprint,
            pendingApprovalContext: pendingApprovalContext,
            activeApprovalContext: activeApprovalContext,
            currentApprovalContext: currentApprovalContext
        )
    }

    public mutating func reduce(
        _ observation: CodexRootTurnObservation
    ) -> CodexRootTurnReduction {
        let previousSnapshot = snapshot
        let outcome: Outcome

        switch observation {
        case .launchLogRootInput(
            let fingerprint,
            let threadID,
            let turnID,
            let context
        ):
            outcome = reduceLaunchLogRootInput(
                fingerprint: fingerprint,
                threadID: threadID,
                turnID: turnID,
                context: context
            )

        case .launchLogOverrideContext(let context):
            reduceLaunchLogOverrideContext(context)
            outcome = .proceed(.launchLogOverrideContext)

        case .hook(let kind, let threadID, let turnID, let promptFingerprint):
            outcome = reduceHook(
                kind: kind,
                threadID: threadID,
                turnID: turnID,
                promptFingerprint: promptFingerprint
            )

        case .fallbackNotifyThreadCandidate(let threadID, let inputFingerprint):
            outcome = reduceFallbackNotifyThreadCandidate(
                threadID: threadID,
                inputFingerprint: inputFingerprint
            )
        }

        assertStateInvariants()
        let nextSnapshot = snapshot
        let reduction = CodexRootTurnReduction(
            qualification: outcome.qualification,
            didMutateRootState: previousSnapshot != nextSnapshot,
            shouldClearLegacyAutoReviewedTurns: outcome.shouldClearLegacyAutoReviewedTurns,
            reason: outcome.reason,
            snapshot: nextSnapshot
        )
        assertReductionInvariants(reduction)
        return reduction
    }

    private mutating func reduceLaunchLogRootInput(
        fingerprint: String?,
        threadID: String?,
        turnID: String?,
        context: CodexRootTurnApprovalContext
    ) -> Outcome {
        var shouldClearLegacyAutoReviewedTurns = false

        // This write intentionally precedes replacement cleanup. A new launch
        // thread must preserve its just-observed input correlation fingerprint.
        pendingRootInputFingerprint = fingerprint

        if let threadID {
            let previousRootThreadID = rootThreadID
            rootThreadID = threadID
            if let previousRootThreadID, previousRootThreadID != threadID {
                rootTurnID = nil
                rootTurnInputFingerprint = nil
                isAwaitingSessionLogContext = false
                pendingApprovalContext = nil
                activeApprovalContext = nil
                currentApprovalContext = nil
                shouldClearLegacyAutoReviewedTurns = true
            }
        }

        let nextApprovalContext = applying(
            context,
            to: activeApprovalContext,
            preservingNilWhenUnspecified: true
        )
        if let turnID {
            rootTurnID = turnID
            rootTurnInputFingerprint = fingerprint
            isAwaitingSessionLogContext = false
            pendingApprovalContext = nil
            currentApprovalContext = nextApprovalContext
        } else if fingerprint != nil {
            if fingerprint == rootTurnInputFingerprint,
               rootTurnID != nil,
               isAwaitingSessionLogContext {
                isAwaitingSessionLogContext = false
                pendingApprovalContext = nil
                currentApprovalContext = nextApprovalContext
            } else {
                rootTurnID = nil
                rootTurnInputFingerprint = nil
                isAwaitingSessionLogContext = false
                pendingApprovalContext = nextApprovalContext
                currentApprovalContext = nil
            }
        } else if context.hasSpecifiedField {
            rootTurnID = nil
            rootTurnInputFingerprint = nil
            isAwaitingSessionLogContext = false
            pendingApprovalContext = nil
            currentApprovalContext = nil
        }

        return .proceed(
            .launchLogRootInput,
            shouldClearLegacyAutoReviewedTurns: shouldClearLegacyAutoReviewedTurns
        )
    }

    private mutating func reduceLaunchLogOverrideContext(
        _ context: CodexRootTurnApprovalContext
    ) {
        guard context.hasSpecifiedField else { return }

        activeApprovalContext = applying(
            context,
            to: activeApprovalContext,
            preservingNilWhenUnspecified: false
        )

        if let pendingApprovalContext {
            self.pendingApprovalContext = applyingWithActiveFallback(
                context,
                to: pendingApprovalContext
            )
        }

        if rootTurnID != nil {
            currentApprovalContext = applyingWithActiveFallback(
                context,
                to: currentApprovalContext
            )
            isAwaitingSessionLogContext = false
            pendingApprovalContext = nil
        }
    }

    private mutating func reduceHook(
        kind: CodexRootTurnHookKind,
        threadID: String?,
        turnID: String?,
        promptFingerprint: String?
    ) -> Outcome {
        guard authority != .sessionLogFallback else {
            return .reject(.incompatibleWithAuthority)
        }

        let isClearSessionStart = kind.isClearSessionStart
        var shouldClearLegacyAutoReviewedTurns = isClearSessionStart

        if let threadID {
            if let rootThreadID {
                if threadID != rootThreadID {
                    guard isClearSessionStart else {
                        return .reject(.threadMismatch)
                    }
                    self.rootThreadID = threadID
                    rootTurnID = nil
                    rootTurnInputFingerprint = nil
                    isAwaitingSessionLogContext = false
                    pendingRootInputFingerprint = nil
                    pendingApprovalContext = nil
                    activeApprovalContext = nil
                    currentApprovalContext = nil
                    shouldClearLegacyAutoReviewedTurns = true
                }
            } else if kind.canLatchRootThread {
                rootThreadID = threadID
            } else if kind == .stop,
                      rootTurnID == nil || turnID != rootTurnID {
                return .reject(.missingRootThread)
            }
        }

        if kind == .stop,
           threadID == nil,
           let turnID,
           let rootTurnID,
           turnID != rootTurnID {
            return .reject(.turnMismatch)
        }

        if kind == .userPromptSubmit, rootTurnID != turnID {
            // Correlation must use the old pending fingerprint/context before
            // this hook's fingerprint replaces the bridge below.
            let oldPendingRootInputFingerprint = pendingRootInputFingerprint
            let matchedPendingContext = promptFingerprint != nil &&
                promptFingerprint == oldPendingRootInputFingerprint &&
                pendingApprovalContext != nil
            let shouldAwaitSessionLogContext = promptFingerprint != nil && !matchedPendingContext

            rootTurnID = turnID
            rootTurnInputFingerprint = promptFingerprint
            if matchedPendingContext {
                currentApprovalContext = pendingApprovalContext
            } else if !shouldAwaitSessionLogContext {
                currentApprovalContext = activeApprovalContext
            } else {
                currentApprovalContext = nil
            }
            pendingApprovalContext = nil
            isAwaitingSessionLogContext = shouldAwaitSessionLogContext
        }

        if let promptFingerprint {
            pendingRootInputFingerprint = promptFingerprint
        }

        return .proceed(
            kind == .other ? .hookOther : .hookAccepted,
            shouldClearLegacyAutoReviewedTurns: shouldClearLegacyAutoReviewedTurns
        )
    }

    private mutating func reduceFallbackNotifyThreadCandidate(
        threadID: String,
        inputFingerprint: String?
    ) -> Outcome {
        guard authority != .hooks else {
            return .reject(.incompatibleWithAuthority)
        }

        if let rootThreadID {
            guard threadID == rootThreadID else {
                return .reject(.threadMismatch)
            }
            return .proceed(.fallbackNotifyThreadMatched)
        }

        guard pendingRootInputFingerprint != nil else {
            return .reject(.missingRootInputFingerprint)
        }
        guard let inputFingerprint else {
            return .reject(.missingNotifyInputFingerprint)
        }
        guard inputFingerprint == pendingRootInputFingerprint else {
            return .reject(.inputFingerprintMismatch)
        }

        rootThreadID = threadID
        return .proceed(.fallbackNotifyThreadLatched)
    }

    private func applying(
        _ patch: CodexRootTurnApprovalContext,
        to base: CodexRootTurnApprovalContext?,
        preservingNilWhenUnspecified: Bool
    ) -> CodexRootTurnApprovalContext? {
        if preservingNilWhenUnspecified, !patch.hasSpecifiedField, base == nil {
            return nil
        }

        var result = base ?? CodexRootTurnApprovalContext()
        if patch.approvalPolicy.isSpecified {
            result.approvalPolicy = patch.approvalPolicy
        }
        if patch.approvalsReviewer.isSpecified {
            result.approvalsReviewer = patch.approvalsReviewer
        }
        return result
    }

    private func applyingWithActiveFallback(
        _ patch: CodexRootTurnApprovalContext,
        to current: CodexRootTurnApprovalContext?
    ) -> CodexRootTurnApprovalContext {
        let patched = applying(
            patch,
            to: current,
            preservingNilWhenUnspecified: false
        ) ?? CodexRootTurnApprovalContext()
        return CodexRootTurnApprovalContext(
            approvalPolicy: patched.approvalPolicy.isSpecified
                ? patched.approvalPolicy
                : activeApprovalContext?.approvalPolicy ?? .unspecified,
            approvalsReviewer: patched.approvalsReviewer.isSpecified
                ? patched.approvalsReviewer
                : activeApprovalContext?.approvalsReviewer ?? .unspecified
        )
    }

    private func assertStateInvariants() {
        assert(!(isAwaitingSessionLogContext && pendingApprovalContext != nil))
        assert(!(isAwaitingSessionLogContext && currentApprovalContext != nil))
        assert(!(pendingApprovalContext != nil && currentApprovalContext != nil))
        if pendingApprovalContext != nil {
            assert(rootTurnID == nil)
            assert(rootTurnInputFingerprint == nil)
        }
    }

    private func assertReductionInvariants(_ reduction: CodexRootTurnReduction) {
        if reduction.qualification == .rejectEvent {
            assert(reduction.didMutateRootState == false)
            assert(reduction.shouldClearLegacyAutoReviewedTurns == false)
        }
        if reduction.shouldClearLegacyAutoReviewedTurns {
            assert(reduction.qualification == .proceed)
        }
    }
}

private extension CodexRootTurnReconciler {
    struct Outcome {
        let qualification: CodexRootTurnQualification
        let reason: CodexRootTurnReductionReason
        let shouldClearLegacyAutoReviewedTurns: Bool

        static func proceed(
            _ reason: CodexRootTurnReductionReason,
            shouldClearLegacyAutoReviewedTurns: Bool = false
        ) -> Outcome {
            Outcome(
                qualification: .proceed,
                reason: reason,
                shouldClearLegacyAutoReviewedTurns: shouldClearLegacyAutoReviewedTurns
            )
        }

        static func reject(_ reason: CodexRootTurnReductionReason) -> Outcome {
            Outcome(
                qualification: .rejectEvent,
                reason: reason,
                shouldClearLegacyAutoReviewedTurns: false
            )
        }
    }
}
