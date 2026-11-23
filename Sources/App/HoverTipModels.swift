import CoreState
import Foundation
import RemoteProtocol
import SwiftUI

struct SessionChildHoverTipModel: Hashable {
    enum StatusDotColorKind: Hashable {
        case idle
        case working
        case needsApproval
        case ready
        case error

        init(statusKind: SessionStatusKind?) {
            switch statusKind ?? .idle {
            case .idle:
                self = .idle
            case .working:
                self = .working
            case .needsApproval:
                self = .needsApproval
            case .ready:
                self = .ready
            case .error:
                self = .error
            }
        }
    }

    var name: String
    var typeLabel: String
    var statusDotColorKind: StatusDotColorKind
    var bodyText: String?
    var executionProfileText: String?
    var metaItems: [String]
}

/// Row metadata the sidebar row itself stopped showing.
struct SessionRowHoverTipModel: Hashable {
    struct MetaItem: Hashable {
        let label: String
        let value: String
        /// Long values such as a scope list wrap instead of truncating.
        let wraps: Bool
        /// Where a value that does not wrap loses characters. A path cuts
        /// from the front so its last directories stay.
        var truncationMode: Text.TruncationMode = .middle
        /// Set for values worth copying, such as a path; the row then shows a
        /// copy button.
        var copyValue: String? = nil
    }

    var name: String
    var agentLabel: String
    /// A custom tab title; automatic titles never reach the sidebar.
    var tabTitle: String?
    var statusDotColorKind: SessionChildHoverTipModel.StatusDotColorKind
    var bodyText: String?
    var turnStartedAt: Date?
    /// Present while the session waits on work it started.
    var waiting: Waiting? = nil
    var metaItems: [MetaItem]

    /// What a waiting session waits on, shown first after the summary.
    struct Waiting: Hashable {
        static let maximumVisibleItemCount = 4

        let headline: String
        let items: [SessionWaitingSummary.Item]
        /// Work the counts include but the card does not list.
        let hiddenItemCount: Int

        init(summary: SessionWaitingSummary) {
            headline = summary.headline
            items = Array(summary.items.prefix(Self.maximumVisibleItemCount))
            hiddenItemCount = summary.totalCount - items.count
        }
    }
}

/// A subspace row's hover card: every annotation under the name, as the
/// sidebar shows them under a workspace title, then its agent sessions as
/// compact rows shaped like the sidebar's session rows, then where the
/// subspace lives.
struct SubspaceHoverTipModel: Hashable {
    struct Session: Hashable {
        let title: String
        let panelID: UUID
        let agentLabel: String?
        let isUnread: Bool
        let railState: SidebarSessionPresentation.SessionRailState
        /// Approval and error only; the rail carries the other states.
        let badgeKind: SessionStatusKind?
        let isWaiting: Bool
        let turnStartedAt: Date?
        let summary: String?
    }

    struct Annotation: Hashable {
        let key: String
        let text: String
        let colorToken: AnnotationColorToken
    }

    /// Where the task stands, in place of the "task space" tag: the task's
    /// own sidebar group, as the group counts count it. A row that lists
    /// with its family can sit under a more urgent heading.
    enum Stage: Hashable {
        case bucket(TaskBucket)
        case toShip
        case done
        case archived

        var title: String {
            switch self {
            case .bucket(let bucket): bucket.title
            case .toShip: "To ship"
            case .done: "Done"
            case .archived: "Archived"
            }
        }
    }

    var name: String
    /// `nil` for a subspace that is not a task.
    var stage: Stage? = nil
    var sessions: [Session]
    var hiddenSessionCount: Int
    var annotations: [Annotation]
    /// Display form, with the home directory shortened to `~`.
    var path: String?
    /// What the copy button copies.
    var absolutePath: String?
    var spawnerName: String?
    /// The row's summary, such as the question it asks, for a one-line row
    /// that does not show it.
    var rowSummary: String? = nil
    /// The task that started this one, which the card's Parent button
    /// opens.
    var parentTaskTitle: String? = nil

    /// A task that this one started, as the card lists it.
    struct ChildTask: Hashable {
        let taskID: UUID
        /// The task, for its status mark.
        let item: TaskBoardItem
        /// Its sidebar group, or To ship or Done once its work finished.
        let stage: Stage
        /// The child's project, when it is not this task's project.
        let projectTitle: String?

        var title: String { item.title }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.taskID == rhs.taskID && lhs.item == rhs.item && lhs.stage == rhs.stage
                && lhs.projectTitle == rhs.projectTitle
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(taskID)
            hasher.combine(stage)
            hasher.combine(projectTitle)
        }
    }

    /// Open child tasks, most urgent first.
    var openChildTasks: [ChildTask] = []
    /// To ship and Done children, newest first.
    var finishedChildTasks: [ChildTask] = []
    var childProgress: TaskBoard.ChildProgress?
}
