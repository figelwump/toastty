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

    var name: String
    var sessions: [Session]
    var hiddenSessionCount: Int
    var annotations: [Annotation]
    /// Display form, with the home directory shortened to `~`.
    var path: String?
    /// What the copy button copies.
    var absolutePath: String?
    var spawnerName: String?
}
