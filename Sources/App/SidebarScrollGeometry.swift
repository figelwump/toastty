import Combine
import SwiftUI

/// Geometry changes on every scroll step. Keep it outside SidebarView's
/// observed state so those changes cannot rebuild the workspace and row content.
@MainActor
final class SidebarScrollGeometry: ObservableObject {
    typealias RowID = SidebarSessionPresentation.SidebarSessionRowID

    struct Content: Equatable {
        var isDragging = false
        var orderedSessionRowIDs: [RowID] = []
        var unreadSessionRowIDs: Set<RowID> = []
        var workingSessionRowIDs: Set<RowID> = []
        var subspaceRows: [SidebarSubspacePresentation.Row] = []
        var subspaceFrameIDs: [UUID: SidebarSubspaceFrameID] = [:]
    }

    // Drag handlers need current geometry even when the pill result is unchanged.
    var sessionRowFrames: [RowID: CGRect] = [:] { didSet { refreshPills() } }
    var sessionGroupFrames: [RowID: CGRect] = [:]
    var subspaceFrames: [SidebarSubspaceFrameID: CGRect] = [:] { didSet { refreshPills() } }
    var viewportHeight: CGFloat = 0 { didSet { refreshPills() } }
    private var content = Content()
    @Published private(set) var pills = SidebarSessionPresentation.HiddenSessionPillState.empty

    func updateContent(_ content: Content) {
        guard self.content != content else { return }
        self.content = content
        refreshPills()
    }

    private func refreshPills() {
        let next: SidebarSessionPresentation.HiddenSessionPillState
        if content.isDragging {
            next = .empty
        } else {
            let subspaceRowFrames = content.subspaceFrameIDs.compactMapValues { subspaceFrames[$0] }
            next = SidebarSessionPresentation.hiddenSessionPillState(
                orderedSessionRowIDs: content.orderedSessionRowIDs,
                measuredSessionRowFramesByID: sessionRowFrames,
                unreadSessionRowIDs: content.unreadSessionRowIDs,
                workingSessionRowIDs: content.workingSessionRowIDs,
                subspaceRows: content.subspaceRows,
                measuredSubspaceRowFramesByID: subspaceRowFrames,
                viewportHeight: viewportHeight,
                visibleTop: ToastyTheme.sidebarTopPadding
            )
        }
        guard pills != next else { return }
        pills = next
    }
}

/// Both overlays observe one derived result. Status projection is supplied by
/// the sidebar only when its semantic inputs change, never from a scroll event.
struct SidebarHiddenSessionPills<Pill: View>: View {
    @ObservedObject var geometry: SidebarScrollGeometry
    let content: SidebarScrollGeometry.Content
    @ViewBuilder let pill: (SidebarSessionPresentation.HiddenSessionPill?) -> Pill

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .overlay(alignment: .top) { pill(content.isDragging ? nil : geometry.pills.above) }
            .overlay(alignment: .bottom) { pill(content.isDragging ? nil : geometry.pills.below) }
            .onChange(of: content, initial: true) { _, content in
                geometry.updateContent(content)
            }
    }
}

enum SidebarSubspaceFrameID: Hashable {
    case row(UUID)
    case group(UUID)

    var workspaceID: UUID {
        switch self {
        case .row(let id), .group(let id): return id
        }
    }
}
