import CoreState
import Foundation
import RemoteProtocol

/// The groups a project card lists its rows in when the task system is on.
/// The groups and the rules that place rows in them are shared with the
/// iPhone (`TaskBucket`, `TaskBuckets`); this file maps the Mac's own task
/// stages, sessions and task space rows to a bucket.
typealias SidebarBucket = TaskBucket

extension TaskBucket {
    /// A task stage's bucket: its group, with a review split off from the
    /// rest of Needs you. `nil` for To ship and Done, which the card's
    /// footer counts, and for Archived.
    init?(_ stage: TaskStage) {
        switch stage {
        case .needsYou(.review), .needsYou(.readyForReview): self = .readyToReview
        case .needsYou: self = .needsYou
        case .starting, .running: self = .running
        case .idle: self = .idle
        case .toShip, .done, .archived: return nil
        }
    }

    /// A session or program row: an approval, an error, an unread finished
    /// turn, or a sub-agent that needs the user. A finished turn that was
    /// read is Idle.
    static func session(kind: SessionStatusKind, isUnread: Bool, childNeedsAttention: Bool = false) -> Self {
        if childNeedsAttention { return .needsYou }
        switch kind {
        case .needsApproval, .error: return .needsYou
        case .ready: return isUnread ? .needsYou : .idle
        case .working: return .running
        case .idle: return .idle
        }
    }

    /// A task space or other subspace row: the more urgent of what its
    /// sessions show and its task's stage. The stage covers a task that
    /// needs the user while no agent asks, such as a failed setup. A row
    /// shows its review over a finished turn that is not read yet, so a
    /// task that just opened its pull request lists in Ready to review.
    static func subspace(_ row: SidebarSubspacePresentation.Row) -> Self {
        let fromStatus: Self = switch row.status {
        case .ready, .question, .needsApproval, .error: .needsYou
        case .review: .readyToReview
        case .working: .running
        case .idle, .toShip, .done: .idle
        }
        guard let fromStage = row.stage.flatMap(Self.init) else { return fromStatus }
        return min(fromStatus, fromStage)
    }
}

/// One row in the sidebar, the same from one pass to the next.
enum SidebarRowKey: Hashable, Sendable {
    /// A session or program row in a project workspace, by its panel.
    case panel(UUID)
    /// A task space or other subspace row, by its workspace.
    case workspace(UUID)
    /// A task without an open task space in the window.
    case task(TaskBoardItem.Subject)
}

typealias SidebarBucketCandidate<Payload> = TaskBucketCandidate<SidebarRowKey, Payload>
typealias SidebarBucketEntry<Payload> = TaskBucketEntry<SidebarRowKey, Payload>
typealias SidebarBucketPin = TaskBucketPin<SidebarRowKey>
/// The shared rules, keyed by the sidebar's rows.
typealias SidebarBuckets = TaskBuckets<SidebarRowKey>
