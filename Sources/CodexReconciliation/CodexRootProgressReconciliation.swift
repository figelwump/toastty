import Foundation

/// Selects the one provider signal allowed to drive root-session progress.
/// Authority is chosen by the application for the lifetime of a session.
public enum CodexRootProgressAuthority: Equatable, Sendable {
    case hooks
    case sessionLogFallback
}

/// The unprojected registry status supplied by the application at evaluation
/// time. `none` means the active registry record has no status yet.
public enum CodexRootProgressRegistryKind: Equatable, Sendable {
    case none
    case idle
    case working
    case needsApproval
    case ready
    case error
}

public enum CodexRootProgressInterrupt: Equatable, Sendable {
    case escape
    case controlC
}

public enum CodexRootProgressObservation: Equatable, Sendable {
    case hookWorking(summary: String, detail: String?)
    case sessionLogWorking(detail: String?)
    case sessionLogTurnAborted(detail: String?)
    case visibleTextWorking(detail: String)
    case localInterrupt(CodexRootProgressInterrupt)
}

public enum CodexRootProgressIgnoredReason: Equatable, Sendable {
    case incompatibleWithAuthority
    case currentRegistryKindDoesNotPermitTransition
    case fallbackEscapeSuppressed
}

/// Progress reconciliation cannot project actionable or terminal states. Those
/// remain owned by the approval, completion, and visible-error paths.
public enum CodexRootProgressDecision: Equatable, Sendable {
    case projectWorking(summary: String, detail: String?)
    case projectIdle(detail: String?)
    case ignored(CodexRootProgressIgnoredReason)
}

/// Stateless policy for non-actionable Codex root-session progress. Parsing,
/// logging, registry mutation, and side effects remain application concerns.
public enum CodexRootProgressEvaluator {
    public static func evaluate(
        authority: CodexRootProgressAuthority,
        currentRegistryKind: CodexRootProgressRegistryKind,
        observation: CodexRootProgressObservation
    ) -> CodexRootProgressDecision {
        switch observation {
        case .hookWorking(let summary, let detail):
            switch authority {
            case .hooks:
                return .projectWorking(summary: summary, detail: detail)
            case .sessionLogFallback:
                return .ignored(.incompatibleWithAuthority)
            }

        case .sessionLogWorking(let detail):
            switch authority {
            case .hooks:
                return .ignored(.incompatibleWithAuthority)
            case .sessionLogFallback:
                return .projectWorking(summary: "Working", detail: detail)
            }

        case .sessionLogTurnAborted(let detail):
            switch authority {
            case .hooks:
                return .ignored(.incompatibleWithAuthority)
            case .sessionLogFallback:
                switch currentRegistryKind {
                case .working, .needsApproval:
                    return .projectIdle(detail: detail)
                case .none, .idle, .ready, .error:
                    return .ignored(.currentRegistryKindDoesNotPermitTransition)
                }
            }

        case .visibleTextWorking(let detail):
            switch currentRegistryKind {
            case .working:
                return .projectWorking(summary: "Working", detail: detail)
            case .none, .idle, .needsApproval, .ready, .error:
                return .ignored(.currentRegistryKindDoesNotPermitTransition)
            }

        case .localInterrupt(let interrupt):
            switch interrupt {
            case .escape:
                switch currentRegistryKind {
                case .working, .needsApproval:
                    switch authority {
                    case .hooks:
                        return .projectIdle(detail: "Ready for prompt")
                    case .sessionLogFallback:
                        return .ignored(.fallbackEscapeSuppressed)
                    }
                case .none, .idle, .ready, .error:
                    return .ignored(.currentRegistryKindDoesNotPermitTransition)
                }
            case .controlC:
                return idleAfterInterrupt(currentRegistryKind: currentRegistryKind)
            }
        }
    }

    private static func idleAfterInterrupt(
        currentRegistryKind: CodexRootProgressRegistryKind
    ) -> CodexRootProgressDecision {
        switch currentRegistryKind {
        case .working, .needsApproval:
            return .projectIdle(detail: "Ready for prompt")
        case .none, .idle, .ready, .error:
            return .ignored(.currentRegistryKindDoesNotPermitTransition)
        }
    }
}
