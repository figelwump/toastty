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
    case canonicalTurnContext(
        turnID: String,
        context: CodexRootTurnApprovalContext
    )
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
    public let latestCanonicalTurnID: String?
    public let latestCanonicalApprovalContext: CodexRootTurnApprovalContext?

    public init(
        rootThreadID: String? = nil,
        rootTurnID: String? = nil,
        rootTurnInputFingerprint: String? = nil,
        isAwaitingSessionLogContext: Bool = false,
        pendingRootInputFingerprint: String? = nil,
        pendingApprovalContext: CodexRootTurnApprovalContext? = nil,
        activeApprovalContext: CodexRootTurnApprovalContext? = nil,
        currentApprovalContext: CodexRootTurnApprovalContext? = nil,
        latestCanonicalTurnID: String? = nil,
        latestCanonicalApprovalContext: CodexRootTurnApprovalContext? = nil
    ) {
        self.rootThreadID = rootThreadID
        self.rootTurnID = rootTurnID
        self.rootTurnInputFingerprint = rootTurnInputFingerprint
        self.isAwaitingSessionLogContext = isAwaitingSessionLogContext
        self.pendingRootInputFingerprint = pendingRootInputFingerprint
        self.pendingApprovalContext = pendingApprovalContext
        self.activeApprovalContext = activeApprovalContext
        self.currentApprovalContext = currentApprovalContext
        self.latestCanonicalTurnID = latestCanonicalTurnID
        self.latestCanonicalApprovalContext = latestCanonicalApprovalContext
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
    case canonicalTurnContext
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
    public let shouldResetApprovalHistory: Bool
    public let reason: CodexRootTurnReductionReason
    public let snapshot: CodexRootTurnSnapshot

    public init(
        qualification: CodexRootTurnQualification,
        didMutateRootState: Bool,
        shouldResetApprovalHistory: Bool,
        reason: CodexRootTurnReductionReason,
        snapshot: CodexRootTurnSnapshot
    ) {
        self.qualification = qualification
        self.didMutateRootState = didMutateRootState
        self.shouldResetApprovalHistory = shouldResetApprovalHistory
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
    private var latestCanonicalTurnID: String?
    private var latestCanonicalApprovalContext: CodexRootTurnApprovalContext?

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
            currentApprovalContext: currentApprovalContext,
            latestCanonicalTurnID: latestCanonicalTurnID,
            latestCanonicalApprovalContext: latestCanonicalApprovalContext
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

        case .canonicalTurnContext(let turnID, let context):
            reduceCanonicalTurnContext(turnID: turnID, context: context)
            outcome = .proceed(.canonicalTurnContext)

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
            shouldResetApprovalHistory: outcome.shouldResetApprovalHistory,
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
        var shouldResetApprovalHistory = false

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
                latestCanonicalTurnID = nil
                latestCanonicalApprovalContext = nil
                shouldResetApprovalHistory = true
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
            if latestCanonicalTurnID == turnID,
               let latestCanonicalApprovalContext {
                currentApprovalContext = latestCanonicalApprovalContext
            } else {
                currentApprovalContext = nextApprovalContext
            }
        } else if fingerprint != nil {
            if fingerprint == rootTurnInputFingerprint,
               rootTurnID != nil {
                if isAwaitingSessionLogContext,
                   let nextApprovalContext {
                    isAwaitingSessionLogContext = false
                    pendingApprovalContext = nil
                    currentApprovalContext = nextApprovalContext
                }
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
            shouldResetApprovalHistory: shouldResetApprovalHistory
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
            // A canonical context is effective state. A later outbound launch
            // override for the same turn must not downgrade it.
            if latestCanonicalTurnID != rootTurnID {
                currentApprovalContext = applyingWithActiveFallback(
                    context,
                    to: currentApprovalContext
                )
                isAwaitingSessionLogContext = false
                pendingApprovalContext = nil
            }
        }
    }

    private mutating func reduceCanonicalTurnContext(
        turnID: String,
        context: CodexRootTurnApprovalContext
    ) {
        guard context.hasSpecifiedField else { return }

        let effectiveContext: CodexRootTurnApprovalContext
        if latestCanonicalTurnID == turnID {
            effectiveContext = applying(
                context,
                to: latestCanonicalApprovalContext,
                preservingNilWhenUnspecified: false
            ) ?? context
        } else {
            effectiveContext = context
        }
        latestCanonicalTurnID = turnID
        latestCanonicalApprovalContext = effectiveContext
        guard rootTurnID == turnID else { return }

        currentApprovalContext = effectiveContext
        isAwaitingSessionLogContext = false
        pendingApprovalContext = nil
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
        var shouldResetApprovalHistory = isClearSessionStart

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
                    latestCanonicalTurnID = nil
                    latestCanonicalApprovalContext = nil
                    shouldResetApprovalHistory = true
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
            if let turnID,
               latestCanonicalTurnID == turnID,
               let latestCanonicalApprovalContext {
                currentApprovalContext = latestCanonicalApprovalContext
                isAwaitingSessionLogContext = false
            } else if matchedPendingContext {
                currentApprovalContext = pendingApprovalContext
            } else if !shouldAwaitSessionLogContext {
                currentApprovalContext = activeApprovalContext
            } else {
                currentApprovalContext = nil
            }
            pendingApprovalContext = nil
            if latestCanonicalTurnID != turnID {
                isAwaitingSessionLogContext = shouldAwaitSessionLogContext
            }
        } else if kind == .userPromptSubmit,
                  let turnID,
                  latestCanonicalTurnID == turnID,
                  let latestCanonicalApprovalContext {
            currentApprovalContext = latestCanonicalApprovalContext
            isAwaitingSessionLogContext = false
            pendingApprovalContext = nil
        }

        if let promptFingerprint {
            pendingRootInputFingerprint = promptFingerprint
        }

        return .proceed(
            kind == .other ? .hookOther : .hookAccepted,
            shouldResetApprovalHistory: shouldResetApprovalHistory
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
            assert(reduction.shouldResetApprovalHistory == false)
        }
        if reduction.shouldResetApprovalHistory {
            assert(reduction.qualification == .proceed)
        }
    }
}

private extension CodexRootTurnReconciler {
    struct Outcome {
        let qualification: CodexRootTurnQualification
        let reason: CodexRootTurnReductionReason
        let shouldResetApprovalHistory: Bool

        static func proceed(
            _ reason: CodexRootTurnReductionReason,
            shouldResetApprovalHistory: Bool = false
        ) -> Outcome {
            Outcome(
                qualification: .proceed,
                reason: reason,
                shouldResetApprovalHistory: shouldResetApprovalHistory
            )
        }

        static func reject(_ reason: CodexRootTurnReductionReason) -> Outcome {
            Outcome(
                qualification: .rejectEvent,
                reason: reason,
                shouldResetApprovalHistory: false
            )
        }
    }
}
