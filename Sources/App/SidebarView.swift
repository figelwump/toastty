import RemoteProtocol
import AppKit
import CoreState
import SwiftUI

/// Zero-size hidden text that AppKit inspectors and hosted tests can find;
/// the remote test host has no accessibility tree.
struct SidebarSemanticTextBridge: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.isHidden = true
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBezeled = false
        label.isBordered = false
        label.setAccessibilityElement(false)
        return label
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.stringValue = text
    }
}

private struct SidebarTooltipBridge: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = ClickThroughToolTipView(frame: .zero)
        view.toolTip = text.isEmpty ? nil : text
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = text.isEmpty ? nil : text
    }
}

// Tool tips register their own tracking rects, so passing clicks through keeps
// the row tap gesture reachable without losing the help tag.
private final class ClickThroughToolTipView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct SidebarScrollViewportHeightReporter: NSViewRepresentable {
    let onHeightChange: @MainActor (CGFloat) -> Void

    func makeNSView(context: Context) -> SidebarScrollViewportHeightReporterView {
        let view = SidebarScrollViewportHeightReporterView()
        view.onHeightChange = onHeightChange
        return view
    }

    func updateNSView(_ nsView: SidebarScrollViewportHeightReporterView, context: Context) {
        nsView.onHeightChange = onHeightChange
        nsView.scheduleRefresh()
    }
}

/// Reports a child's intrinsic width until it reaches either the configured
/// cap or a tighter parent proposal. Unlike `fixedSize`, the layout stays
/// compressible so narrow sidebars can truncate chip content normally.
struct SidebarCappedIntrinsicWidthLayout: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        assert(subviews.count <= 1, "SidebarCappedIntrinsicWidthLayout expects one subview")
        guard let subview = subviews.first else { return .zero }

        let cap = max(0, maximumWidth)
        let idealSize = subview.sizeThatFits(.unspecified)
        let availableWidth = proposal.width.map { max(0, $0) } ?? cap
        let width = min(idealSize.width, cap, availableWidth)
        let constrainedSize = subview.sizeThatFits(
            ProposedViewSize(width: width, height: nil)
        )
        return CGSize(width: width, height: constrainedSize.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        guard let subview = subviews.first else { return }
        let width = min(bounds.width, max(0, maximumWidth))
        subview.place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: width, height: nil)
        )
    }
}

struct SidebarWrappingFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    private struct Item {
        let index: Int
        let size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private struct Placement {
        let index: Int
        let origin: CGPoint
        let size: CGSize
    }

    private struct ResolvedLayout {
        let size: CGSize
        let placements: [Placement]
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        resolve(availableWidth: proposal.width, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        let resolved = resolve(availableWidth: bounds.width, subviews: subviews)
        for placement in resolved.placements {
            subviews[placement.index].place(
                at: CGPoint(
                    x: bounds.minX + placement.origin.x,
                    y: bounds.minY + placement.origin.y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: placement.size.width,
                    height: nil
                )
            )
        }
    }

    private func resolve(
        availableWidth rawAvailableWidth: CGFloat?,
        subviews: Subviews
    ) -> ResolvedLayout {
        let availableWidth = rawAvailableWidth.flatMap { width in
            width.isFinite ? max(0, width) : nil
        }
        if availableWidth == 0 {
            return ResolvedLayout(size: .zero, placements: [])
        }
        let resolvedHorizontalSpacing = max(0, horizontalSpacing)
        let resolvedVerticalSpacing = max(0, verticalSpacing)
        var rows: [Row] = []
        var currentRow = Row()

        for (index, subview) in subviews.enumerated() {
            let idealSize = subview.sizeThatFits(.unspecified)
            let proposedItemWidth = availableWidth.map {
                min(max(0, idealSize.width), $0)
            }
            let measuredSize = subview.sizeThatFits(
                ProposedViewSize(width: proposedItemWidth, height: nil)
            )
            let itemSize = CGSize(
                width: availableWidth.map { min(max(0, measuredSize.width), $0) }
                    ?? max(0, measuredSize.width),
                height: max(0, measuredSize.height)
            )
            let nextWidth = currentRow.items.isEmpty
                ? itemSize.width
                : currentRow.width + resolvedHorizontalSpacing + itemSize.width

            if currentRow.items.isEmpty == false,
               let availableWidth,
               nextWidth > availableWidth {
                rows.append(currentRow)
                currentRow = Row()
            }

            let itemSpacing = currentRow.items.isEmpty ? 0 : resolvedHorizontalSpacing
            currentRow.items.append(Item(index: index, size: itemSize))
            currentRow.width += itemSpacing + itemSize.width
            currentRow.height = max(currentRow.height, itemSize.height)
        }

        if currentRow.items.isEmpty == false {
            rows.append(currentRow)
        }

        var placements: [Placement] = []
        var nextY: CGFloat = 0
        var maximumRowWidth: CGFloat = 0
        for row in rows {
            var nextX: CGFloat = 0
            for item in row.items {
                placements.append(
                    Placement(
                        index: item.index,
                        origin: CGPoint(
                            x: nextX,
                            y: nextY + ((row.height - item.size.height) / 2)
                        ),
                        size: item.size
                    )
                )
                nextX += item.size.width + resolvedHorizontalSpacing
            }
            maximumRowWidth = max(maximumRowWidth, row.width)
            nextY += row.height + resolvedVerticalSpacing
        }

        let height = rows.isEmpty ? 0 : max(0, nextY - resolvedVerticalSpacing)
        let width = availableWidth.map { min(maximumRowWidth, $0) } ?? maximumRowWidth
        return ResolvedLayout(
            size: CGSize(width: width, height: height),
            placements: placements
        )
    }
}

@MainActor
private final class SidebarScrollViewportHeightReporterView: NSView {
    var onHeightChange: (@MainActor (CGFloat) -> Void)?
    private weak var observedClipView: NSClipView?
    private var boundsObservation: NSKeyValueObservation?
    private var lastReportedHeight: CGFloat?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleRefresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
            boundsObservation = nil
            observedClipView = nil
        } else {
            scheduleRefresh()
        }
    }

    override func layout() {
        super.layout()
        scheduleRefresh()
    }

    func scheduleRefresh() {
        Task { @MainActor [weak self] in
            self?.refreshHeight()
        }
    }

    private func refreshHeight() {
        guard window != nil, let clipView = enclosingScrollView?.contentView else { return }

        if observedClipView !== clipView {
            NotificationCenter.default.removeObserver(
                self, name: NSView.frameDidChangeNotification, object: observedClipView
            )
            // Resizing the clip view does not reliably send KVO bounds changes.
            clipView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipViewFrameDidChange(_:)),
                name: NSView.frameDidChangeNotification, object: clipView
            )
            observedClipView = clipView
            lastReportedHeight = nil
            boundsObservation = clipView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.refreshHeight()
                }
            }
        }

        reportHeight(clipView.bounds.height)
    }

    @objc private func clipViewFrameDidChange(_ notification: Notification) {
        scheduleRefresh()
    }

    private func reportHeight(_ height: CGFloat) {
        guard height.isFinite,
              lastReportedHeight.map({ abs(height - $0) >= 0.5 }) ?? true else {
            return
        }

        lastReportedHeight = height
        onHeightChange?(height)
    }
}

/// What the hover card would show, in raw form. Cheap to build for every row
/// on every publish, which is what makes deferring the card's own model safe:
/// a change here still re-presents a visible card.
private struct SessionRowHoverTipRefreshKey: Hashable {
    let statusKind: SessionStatusKind
    let statusDetail: String?
    let projection: String
    let cwd: String?
    let updatedAt: Date
    let turnStartedAt: Date?
    let lastTurnDuration: TimeInterval?
    let childCount: Int
    let waitingSummary: SessionWaitingSummary?
    let customTabTitle: String?
    let parentSessionName: String?
    let isLaterFlagged: Bool
    let effectiveScopedWorkspaceIDs: Set<UUID>?
    let sessionName: String?
}

private struct SidebarSessionRowDiagnosticState: Equatable {
    var windowID: UUID
    var workspaceID: UUID
    var sessionID: String
    var panelID: UUID
    var agent: AgentKind
    var statusKind: SessionStatusKind
    var chipKind: SessionStatusKind?
    var projection: SessionStatusProjection
    var railState: SidebarSessionPresentation.SessionRailState
    var showsUnreadSessionAccent: Bool
    var canFocusPanel: Bool
    var isActivePanel: Bool
    var isLaterFlagged: Bool
    var isFlashing: Bool
    var selectedWorkspaceID: UUID?
    var selectedPanelID: UUID?
    var childRowCount: Int
    var collapsedChildNeedsAttention: Bool

    var displayState: String {
        if case .waitingOnChildren = projection {
            return "waiting_chip"
        }
        if let chipKind {
            return "\(chipKind.rawValue)_chip"
        }
        switch railState {
        case .spinner:
            return "working_spinner"
        case .approvalDot, .unreadDot, .errorDot:
            return "\(SidebarSessionPresentation.sessionRailLogValue(railState))_rail"
        case .empty:
            break
        }
        if isFlashing {
            return "flash"
        }
        if showsUnreadSessionAccent {
            return "unread_accent"
        }
        if isActivePanel {
            return "active_panel"
        }
        return "plain"
    }
}

private extension SessionChildRow {
    var sidebarStableID: String {
        let sourcePrefix: String
        switch source {
        case .activity:
            sourcePrefix = "activity"
        case .session:
            sourcePrefix = "session"
        }
        return "\(sourcePrefix):\(id)"
    }
}

/// The status mark in a session row's left rail. The subspace hover card
/// draws its session rows with it too.
struct SessionRailStatusIcon: View {
    static let dotSize: CGFloat = 7

    let state: SidebarSessionPresentation.SessionRailState

    var body: some View {
        switch state {
        case .empty:
            Color.clear
        case .spinner:
            SessionStatusIndicator(state: .spinner, size: 9, lineWidth: 1.4)
        case .approvalDot:
            Circle()
                .fill(ToastyTheme.sessionNeedsApprovalText)
                .frame(width: Self.dotSize, height: Self.dotSize)
                .overlay {
                    Circle()
                        .stroke(ToastyTheme.sidebarSessionRailApprovalHalo, lineWidth: 3)
                }
        case .unreadDot:
            Circle()
                .fill(ToastyTheme.sessionReadyText)
                .frame(width: Self.dotSize, height: Self.dotSize)
        case .errorDot:
            Circle()
                .fill(ToastyTheme.sessionErrorText)
                .frame(width: Self.dotSize, height: Self.dotSize)
        }
    }
}

/// A subspace row's status mark: square where a session's is round, so a
/// workspace reads apart from an agent, and hollow when idle so an idle
/// subspace still has one. The hollow box doubles as the done checkbox: it
/// previews the check under the pointer and fills with one when done.
private struct SubspaceRailStatusIcon: View {
    private static let markSize: CGFloat = 7
    private static let doneMarkSize: CGFloat = 10
    private static let cornerRadius: CGFloat = 1.5

    let status: SidebarSubspacePresentation.RowStatus
    var isDoneTogglePreviewed = false

    var body: some View {
        switch status {
        case .working:
            SessionStatusIndicator(state: .spinner, size: 9, lineWidth: 1.4)
        case .idle where isDoneTogglePreviewed, .ready where isDoneTogglePreviewed,
             .question where isDoneTogglePreviewed, .review where isDoneTogglePreviewed:
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(ToastyTheme.sidebarSubspaceDoneMark, lineWidth: 1.2)
                .frame(width: Self.doneMarkSize, height: Self.doneMarkSize)
                .overlay { checkGlyph(ToastyTheme.sidebarSubspaceDoneMark) }
        case .idle:
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(ToastyTheme.sidebarSubspaceQuietMark, lineWidth: 1.2)
                .frame(width: Self.markSize, height: Self.markSize)
        case .done:
            RoundedRectangle(cornerRadius: 2)
                .fill(ToastyTheme.sidebarSubspaceDoneMarkBackground)
                .frame(width: Self.doneMarkSize, height: Self.doneMarkSize)
                .overlay { checkGlyph(ToastyTheme.sidebarSubspaceDoneMark) }
                .opacity(isDoneTogglePreviewed ? 0.6 : 1)
        case .ready:
            filledMark(ToastyTheme.sessionReadyText)
        case .needsApproval:
            filledMark(ToastyTheme.sessionNeedsApprovalText)
                .overlay {
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .stroke(ToastyTheme.sidebarSessionRailApprovalHalo, lineWidth: 3)
                }
        case .error:
            filledMark(ToastyTheme.sessionErrorText)
        case .review:
            // A tinted box with a blue dot: the pull request waits for you.
            RoundedRectangle(cornerRadius: 2)
                .fill(ToastyTheme.sidebarTaskReviewMarkBackground)
                .frame(width: Self.doneMarkSize, height: Self.doneMarkSize)
                .overlay {
                    Circle()
                        .fill(ToastyTheme.sidebarTaskReviewMark)
                        .frame(width: 4.5, height: 4.5)
                }
        case .question:
            // A tinted box with a question mark: the agent asked you something
            // and waits for your reply.
            RoundedRectangle(cornerRadius: 2)
                .fill(ToastyTheme.sidebarTaskQuestionMarkBackground)
                .frame(width: Self.doneMarkSize, height: Self.doneMarkSize)
                .overlay { TaskQuestionGlyph() }
        case .toShip:
            RoundedRectangle(cornerRadius: 2)
                .fill(ToastyTheme.sidebarTaskToShipMarkBackground)
                .frame(width: Self.doneMarkSize, height: Self.doneMarkSize)
                .overlay {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 6.5, weight: .black))
                        .foregroundStyle(ToastyTheme.sidebarTaskToShipMark)
                }
        }
    }

    private func filledMark(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius)
            .fill(color)
            .frame(width: Self.markSize, height: Self.markSize)
    }

    private func checkGlyph(_ color: Color) -> some View {
        Image(systemName: "checkmark")
            .font(.system(size: 6.5, weight: .black))
            .foregroundStyle(color)
    }
}

/// The approval or error badge on a session row's first line; ready rows
/// show their state through the tint and weight instead.
struct SessionStatusBadge: View {
    let kind: SessionStatusKind
    var label: String? = nil

    var body: some View {
        SidebarStatusPill(
            text: label ?? SidebarSessionPresentation.sessionStatusBadgeLabel(for: kind),
            foreground: ToastyTheme.sessionStatusTextColor(for: kind),
            background: ToastyTheme.sessionStatusBackgroundColor(for: kind)
        )
    }
}

/// The filled pill on a row's first line: the session status badge, and the
/// task-row `question` pill, which has no session status kind.
struct SidebarStatusPill: View {
    let text: String
    let foreground: Color
    let background: Color

    var body: some View {
        Text(text)
            .font(ToastyTheme.fontWorkspaceSessionChip)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// The row is one accessibility element and carries the spoken wording, so a
/// pill's shortened text is otherwise invisible to AppKit inspectors and
/// host-based tests.
private struct SidebarStatusPillSemanticText: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content.background {
            SidebarSemanticTextBridge(text: text)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }
}

/// The task board as of the sidebar's last body pass. Built once per pass
/// and read by the header, the segments, card footers and rows, so a
/// redraw does not rebuild the board for every card. A plain reference
/// rather than SwiftUI state, because the body writes it while it computes.
@MainActor
private final class SidebarTaskBoardSnapshot {
    var windowItems: [TaskBoardItem] = []
    var allItems: [TaskBoardItem] = []
}

/// The bucket each row was last drawn in and the selected row's hold, for
/// the segment that drew them. Kept out of view state, like
/// `SidebarTaskBoardSnapshot`, so recording them does not draw the sidebar
/// again.
private final class SidebarBucketMemory {
    var segment: SidebarSegment?
    var displayed: [SidebarRowKey: SidebarBucket] = [:]
    var pin: SidebarBucketPin?
}

/// Scroll target for a card's Subspaces group.
private struct SubspaceGroupScrollID: Hashable {
    let parentWorkspaceID: UUID
}

/// A ⑂ chip in another card asked to bring this card's Subspaces group into
/// view. When the chip also selects the card, the selection change performs
/// the scroll, so the usual scroll to the card's top does not compete with it.
private struct SubspaceGroupScrollRequest: Equatable {
    let id = UUID()
    let parentWorkspaceID: UUID
    let awaitsSelection: Bool
}

struct SidebarView: View {
    struct WorkspaceDragState: Equatable {
        let workspaceID: UUID
        let sourceIndex: Int
        let startPointerY: CGFloat
        var translationHeight: CGFloat
        var targetIndex: Int
    }

    struct SessionDragState: Equatable {
        let rowID: SidebarSessionPresentation.SidebarSessionRowID
        var target: SidebarSessionPresentation.SessionDropTarget?
    }

    let windowID: UUID
    @ObservedObject var store: AppStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    // Observed so first-use claims, unlocked replacements, and legacy
    // materialization immediately restyle every visible chip with that key.
    @ObservedObject var annotationStyleStore: AnnotationStyleStore
    /// Not observed here: `taskBoard` publishes task changes.
    let taskCoordinator: TaskCoordinator?
    /// Every task's stage. Observed: a stage change moves rows and marks.
    @ObservedObject var taskBoard: TaskBoardStore
    /// Opens the quick entry panel; `nil` hides the Tasks row's ＋.
    let newTask: (@MainActor () -> Void)?
    let terminalRuntimeContext: TerminalWindowRuntimeContext
    /// Runs a subspace row's Merge menu item for that workspace.
    let requestWorkspaceMerge: @MainActor (UUID, WorkspaceMergeMode) -> Void
    /// Runs a subspace row's Close Without Merging menu item.
    let requestWorkspaceClose: @MainActor (UUID) -> Void
    /// Closes a session's pane, given its panel ID and row title.
    let requestSessionClose: @MainActor (UUID, String) -> Void
    /// Test seam for asserting scroll requests without depending on AppKit's
    /// NSScrollView behavior inside unit-test hosting views.
    let scrollRequestObserver: ((UUID, Bool) -> Void)?
    /// Test seam for asserting row geometry used by drag reordering.
    let workspaceRowFrameObserver: (([UUID: CGRect]) -> Void)?
    /// Test seam for asserting the rendered scroll viewport used by hidden-session pills.
    let workspaceViewportHeightObserver: ((CGFloat) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var renamingWorkspaceID: UUID?
    @State private var renameDraftTitle = ""
    @State private var flashingWorkspaceID: UUID?
    @State private var flashingSessionPanelID: UUID?
    @State private var flashingSessionOverlayOpacity = 0.0
    @State private var activeSidebarFlashRequestID: UUID?
    @State private var lastHandledSidebarFlashRequestID: UUID?
    @State private var sidebarFlashClearWorkItem: DispatchWorkItem?
    @State private var sidebarFlashResetWorkItem: DispatchWorkItem?
    @State private var activeSessionDrag: SessionDragState?
    @State private var sessionPointerRowID: SidebarSessionPresentation.SidebarSessionRowID?
    @State private var activeWorkspaceDrag: WorkspaceDragState?
    @State private var measuredWorkspaceRowFramesByID: [UUID: CGRect] = [:]
    @State private var hoverState = SidebarHoverState()
    // The sidebar owns this reference; only the pill overlay observes it.
    @State private var scrollGeometry = SidebarScrollGeometry()
    @State private var sidebarSessionRowDiagnosticsByPanelID: [UUID: SidebarSessionRowDiagnosticState] = [:]
    @State private var expandedSessionChildrenBySessionID: [String: Bool] = [:]
    @State private var collapsedSubspaceGroupParentIDs: Set<UUID> = []
    /// Project cards whose To ship group is expanded. Each card starts
    /// collapsed, and like a collapsed Subspaces group the choice is not
    /// saved: it resets when the sidebar hides or the app quits.
    @State private var expandedToShipProjectIDs: Set<UUID> = []
    /// Spawning session whose subspaces the group shows, per parent workspace.
    @State private var subspaceFilterSessionIDByParentID: [UUID: String] = [:]
    @State private var bucketMemory = SidebarBucketMemory()
    @State private var taskBoardSnapshot = SidebarTaskBoardSnapshot()
    @State private var subspaceGroupScrollRequest: SubspaceGroupScrollRequest?
    @State private var hoveredSpawnerSessionID: String?
    @State private var optionKeyPressed = false

    private static let sessionStatusesTopSpacing: CGFloat = 0
    /// Session rows sit this close together; the hover and attention fills
    /// already separate them.
    private static let sessionRowSpacing: CGFloat = 2
    /// Room the state line keeps for the name before it drops the waiting
    /// chip, so the chip does not squeeze the name to a bare ellipsis.
    private static let sessionRowTitleReservedWidth: CGFloat = 60
    private static let sessionParentTagMaximumWidth: CGFloat = 90
    private static let linkedChildIndent: CGFloat = 14

    /// The ↳ mark in a linked child row's indent, level with the row's
    /// first line and just left of its status mark.
    private static var linkedChildArrow: some View {
        TaskChildArrowMark()
            .frame(width: linkedChildIndent, height: sessionRowLineMinHeight)
            .padding(.leading, 6)
            .padding(.top, 4)
    }

    /// A small tag on a task row's second line: its project, or how many of
    /// the tasks it started have merged.
    static func sidebarTaskTag(_ text: String) -> some View {
        Text(text)
            .font(ToastyTheme.fontWorkspaceSessionChip)
            .foregroundStyle(ToastyTheme.sidebarSessionPathText)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(ToastyTheme.sidebarWorkspaceTagBackground, in: RoundedRectangle(cornerRadius: 4))
    }

    /// Space under a card's session list: room above the card's bottom edge,
    /// or a short step down to a Subspaces group, whose header adds its own.
    private static func sessionListBottomPadding(followedBySubspaces: Bool) -> CGFloat {
        followedBySubspaces ? 6 : 14
    }
    /// The status rail keeps this width whether or not it has an indicator, so
    /// row text stays aligned down the list.
    private static let sessionStatusRailWidth: CGFloat = 12
    /// How far a subspace's done checkbox takes clicks past its rail.
    private static let subspaceDoneToggleHitOutset: CGFloat = 4
    private static let sessionStatusRailGap: CGFloat = 6
    /// The rail's second slot, under the status one, for a standing mark on the
    /// session: the later flag or the watch bell. Short enough that a two-line
    /// row is still taller than the rail.
    private static let sessionStatusRailMarkerSlotHeight: CGFloat = 13
    private static let sessionStatusRailSlotSpacing: CGFloat = 2
    private static let sessionRailFlagFontSize: CGFloat = 9
    /// `bell.fill` carries less ink than `flag.fill`, so it needs a larger
    /// point size to read at the same weight.
    private static let sessionRailWatchFontSize: CGFloat = 10.5
    /// Elapsed time sits among the accessories `ViewThatFits` measures, and its
    /// text changes every second. A floor wide enough for `00m 00s` keeps each
    /// candidate line's measured width constant, so a tick cannot re-measure
    /// the row or flip a chip in and out at a width boundary. Rows without a
    /// waiting chip have one candidate and skip the floor.
    private static let sessionElapsedMinimumWidth: CGFloat = {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        return ceil((Self.sessionElapsedWidestTemplate as NSString)
            .size(withAttributes: [.font: font]).width)
    }()
    static let sessionElapsedWidestTemplate = "00m 00s"
    /// Reserving a line height keeps the rail, name, and accessories on one
    /// baseline whether or not a row has a badge or disclosure pill.
    private static let sessionRowLineMinHeight: CGFloat = 17
    private static let sessionRowSecondaryLineMinHeight: CGFloat = 16
    /// Hover cards open this close to their row's trailing edge, over the
    /// sidebar's 10pt inset, so the pointer has almost no gap to cross to
    /// reach a card.
    private static let hoverTipTrailingGap: CGFloat = 4
    private static let workspaceScopeFallbackHelpText = "Workspace-scoped automation is limited to assigned workspaces."
    private static let sessionFlashPeakDuration: Double = 0.18
    private static let sessionFlashSettleDuration: Double = 0.28
    private nonisolated static let workspaceDragActivationDistance: CGFloat = 4

    nonisolated static func workspaceReorderTargetIndex(
        orderedWorkspaceIDs: [UUID],
        measuredRowFramesByID: [UUID: CGRect],
        draggedWorkspaceID: UUID,
        pointerY: CGFloat
    ) -> Int? {
        guard pointerY.isFinite else { return nil }

        let measuredFrames = orderedWorkspaceIDs.compactMap { workspaceID -> CGRect? in
            guard workspaceID != draggedWorkspaceID else { return nil }
            return measuredRowFramesByID[workspaceID]
        }
        guard measuredFrames.count == max(orderedWorkspaceIDs.count - 1, 0) else { return nil }
        guard measuredFrames.isEmpty == false else { return 0 }

        for (index, frame) in measuredFrames.enumerated() {
            if pointerY < frame.midY {
                return index
            }
        }
        return measuredFrames.count
    }

    nonisolated static func workspaceInsertionIndicatorFrame(
        orderedWorkspaceIDs: [UUID],
        measuredRowFramesByID: [UUID: CGRect],
        draggedWorkspaceID: UUID,
        targetIndex: Int
    ) -> CGRect? {
        let measuredFrames = orderedWorkspaceIDs.compactMap { workspaceID -> CGRect? in
            guard workspaceID != draggedWorkspaceID else { return nil }
            return measuredRowFramesByID[workspaceID]
        }
        guard measuredFrames.count == max(orderedWorkspaceIDs.count - 1, 0) else { return nil }
        guard measuredFrames.isEmpty == false else { return nil }
        guard targetIndex >= 0, targetIndex <= measuredFrames.count else { return nil }

        let referenceFrame: CGRect
        let y: CGFloat
        if targetIndex == 0 {
            referenceFrame = measuredFrames[0]
            y = referenceFrame.minY
        } else if targetIndex == measuredFrames.count {
            referenceFrame = measuredFrames[measuredFrames.count - 1]
            y = referenceFrame.maxY
        } else {
            referenceFrame = measuredFrames[targetIndex]
            y = referenceFrame.minY
        }
        return CGRect(x: referenceFrame.minX, y: y, width: referenceFrame.width, height: 2)
    }

    static func hiddenSessionPillBorderColor(_ pill: SidebarSessionPresentation.HiddenSessionPill) -> Color {
        if pill.unreadCount > 0 {
            return ToastyTheme.badgeBlue.opacity(0.70)
        }
        if pill.hasWorking {
            return ToastyTheme.accent.opacity(0.60)
        }
        return ToastyTheme.primaryText.opacity(0.30)
    }

    init(
        windowID: UUID,
        store: AppStore,
        terminalRuntimeRegistry: TerminalRuntimeRegistry,
        sessionRuntimeStore: SessionRuntimeStore,
        annotationStyleStore: AnnotationStyleStore,
        taskCoordinator: TaskCoordinator? = nil,
        taskBoard: TaskBoardStore = .disabled,
        newTask: (@MainActor () -> Void)? = nil,
        terminalRuntimeContext: TerminalWindowRuntimeContext,
        requestWorkspaceMerge: @escaping @MainActor (UUID, WorkspaceMergeMode) -> Void = { _, _ in },
        requestWorkspaceClose: @escaping @MainActor (UUID) -> Void = { _ in },
        requestSessionClose: @escaping @MainActor (UUID, String) -> Void = { _, _ in },
        scrollRequestObserver: ((UUID, Bool) -> Void)? = nil,
        workspaceRowFrameObserver: (([UUID: CGRect]) -> Void)? = nil,
        workspaceViewportHeightObserver: ((CGFloat) -> Void)? = nil
    ) {
        self.windowID = windowID
        self.store = store
        self.terminalRuntimeRegistry = terminalRuntimeRegistry
        self.sessionRuntimeStore = sessionRuntimeStore
        self.annotationStyleStore = annotationStyleStore
        self.taskCoordinator = taskCoordinator
        self.taskBoard = taskBoard
        self.newTask = newTask
        self.terminalRuntimeContext = terminalRuntimeContext
        self.requestWorkspaceMerge = requestWorkspaceMerge
        self.requestWorkspaceClose = requestWorkspaceClose
        self.requestSessionClose = requestSessionClose
        self.scrollRequestObserver = scrollRequestObserver
        self.workspaceRowFrameObserver = workspaceRowFrameObserver
        self.workspaceViewportHeightObserver = workspaceViewportHeightObserver
    }

    private var selectedWorkspaceID: UUID? {
        store.selectedWorkspaceID(in: windowID)
    }

    /// A subspace renders inside its parent's card, so selecting it highlights
    /// that card the same way focusing one of the card's own sessions does.
    private func workspaceCardContainsSelection(_ workspaceID: UUID) -> Bool {
        guard let selectedWorkspaceID else { return false }
        return selectedWorkspaceID == workspaceID
            || store.state.workspacesByID[selectedWorkspaceID]?.parentWorkspaceID == workspaceID
    }

    var body: some View {
        refreshTaskBoardSnapshot()
        let bucketed = taskBoard.isEnabled ? makeBucketedSidebar() : nil
        return VStack(alignment: .leading, spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let bucketed, sidebarSegment == .needsYou {
                            needsYouSegmentContent(bucketed)
                        } else if store.window(id: windowID) != nil {
                            // Subspaces render inside their parent's card, so
                            // the card list, its numbering, and drag reordering
                            // all work on the top-level workspaces only.
                            let topLevelWorkspaceIDs = store.state.topLevelWorkspaceIDs(in: windowID)
                            ForEach(Array(topLevelWorkspaceIDs.enumerated()), id: \.element) { index, workspaceID in
                                if let workspace = store.state.workspacesByID[workspaceID] {
                                    workspaceRow(
                                        workspaceID: workspaceID,
                                        workspace: workspace,
                                        shortcutLabel: DisplayShortcutConfig.workspaceSwitchShortcutLabel(for: index + 1),
                                        isSelected: workspaceCardContainsSelection(workspaceID),
                                        index: index + 1,
                                        orderedWorkspaceIDs: topLevelWorkspaceIDs,
                                        card: bucketed?.cards[workspaceID]
                                    )
                                    .id(workspaceID)
                                }
                            }
                            if let other = bucketed?.other {
                                otherTasksCard(other)
                            }
                        } else {
                            Text("No windows")
                                .font(ToastyTheme.fontBody)
                                .foregroundStyle(ToastyTheme.mutedText)
                        }
                    }
                    .padding(.horizontal, 8)
                    .coordinateSpace(name: SidebarWorkspaceListCoordinateSpace.name)
                    .background {
                        // SwiftUI geometry attached to the ScrollView can report
                        // a zero height on macOS; read the enclosing NSScrollView
                        // clip view from inside this scroll content instead.
                        SidebarScrollViewportHeightReporter { height in
                            scrollGeometry.viewportHeight = height
                            workspaceViewportHeightObserver?(height)
                        }
                    }
                    .onPreferenceChange(WorkspaceRowFramePreferenceKey.self) { framesByID in
                        measuredWorkspaceRowFramesByID = framesByID
                        workspaceRowFrameObserver?(framesByID)
                    }
                    .onPreferenceChange(SidebarSessionRowFramePreferenceKey.self) { framesByID in
                        scrollGeometry.sessionRowFrames = framesByID
                    }
                    .onPreferenceChange(SidebarSubspaceFramePreferenceKey.self) { frames in
                        scrollGeometry.subspaceFrames = frames
                    }
                    .onPreferenceChange(SidebarSessionGroupFramePreferenceKey.self) { frames in
                        scrollGeometry.sessionGroupFrames = frames
                    }
                    .overlay(alignment: .topLeading) {
                        if let activeWorkspaceDrag,
                           activeWorkspaceDrag.targetIndex != activeWorkspaceDrag.sourceIndex,
                           let indicatorFrame = Self.workspaceInsertionIndicatorFrame(
                               orderedWorkspaceIDs: store.state.topLevelWorkspaceIDs(in: windowID),
                               measuredRowFramesByID: measuredWorkspaceRowFramesByID,
                               draggedWorkspaceID: activeWorkspaceDrag.workspaceID,
                               targetIndex: activeWorkspaceDrag.targetIndex
                           ) {
                            Rectangle()
                                .fill(ToastyTheme.accent)
                                .frame(width: indicatorFrame.width, height: indicatorFrame.height)
                                .offset(
                                    x: indicatorFrame.minX,
                                    y: indicatorFrame.minY - (indicatorFrame.height / 2)
                                )
                                .allowsHitTesting(false)
                        }
                    }
                }
                .coordinateSpace(name: SidebarWorkspaceViewportCoordinateSpace.name)
                // Keep the titlebar region opaque while letting rows scroll
                // underneath it instead of showing through the traffic-light area.
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        sidebarTitlebarCover
                        coordinatorRow
                        if let bucketed {
                            tasksHeader(needsYouCount: bucketed.needsYouCount)
                        }
                    }
                }
                .overlay {
                    SidebarHiddenSessionPills(geometry: scrollGeometry, content: sidebarHiddenSessionContent) { pill in
                        hiddenSessionPill(pill, using: proxy)
                    }
                }
                .onAppear {
                    scrollToSelectedWorkspace(using: proxy, animated: false)
                }
                .onChange(of: selectedWorkspaceID) { _, _ in
                    revealSelectedSubspaceIfNeeded()
                    if let request = subspaceGroupScrollRequest {
                        subspaceGroupScrollRequest = nil
                        if request.awaitsSelection,
                           workspaceCardContainsSelection(request.parentWorkspaceID) {
                            scrollToSubspaceGroup(parentWorkspaceID: request.parentWorkspaceID, using: proxy)
                            return
                        }
                    }
                    scrollToSelectedWorkspace(using: proxy, animated: true)
                }
                .onChange(of: subspaceGroupScrollRequest) { _, request in
                    guard let request, request.awaitsSelection == false else { return }
                    subspaceGroupScrollRequest = nil
                    scrollToSubspaceGroup(parentWorkspaceID: request.parentWorkspaceID, using: proxy)
                }
            }

            Button {
                cancelWorkspaceRename()
                store.sendNavigation(.createWorkspace(windowID: windowID, title: nil, activate: true))
            } label: {
                HStack(spacing: 6) {
                    Canvas { context, _ in
                        var plus = Path()
                        plus.move(to: CGPoint(x: 5.5, y: 2))
                        plus.addLine(to: CGPoint(x: 5.5, y: 9))
                        plus.move(to: CGPoint(x: 2, y: 5.5))
                        plus.addLine(to: CGPoint(x: 9, y: 5.5))
                        context.stroke(
                            plus,
                            with: .color(ToastyTheme.inactiveText),
                            style: StrokeStyle(lineWidth: 1.1, lineCap: .round)
                        )
                    }
                    .frame(width: 11, height: 11)

                    Text("New workspace")
                        .font(ToastyTheme.fontWorkspaceNameInactive)
                        .foregroundStyle(ToastyTheme.inactiveText)
                        .lineLimit(1)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 2)
                }
            }
            .buttonStyle(SidebarRowButtonStyle())
            .accessibilityIdentifier("sidebar.workspaces.new")
            .padding(.horizontal, 8)
        }
        .padding(.bottom, 10)
        .background(ToastyTheme.chromeBackground)
        .onChange(of: store.state.workspacesByID) { _, _ in
            pruneTransientSidebarState()
            pruneSubspaceGroupState()
            pruneTransientWorkspaceDragState()
            pruneSessionDrag()
            pruneSidebarSessionRowDiagnostics()
        }
        .onChange(of: sessionRuntimeStore.sessionRegistry) { _, registry in
            pruneSessionDrag()
            pruneSidebarSessionRowDiagnostics()
            if let hoveredSpawnerSessionID, registry.activeSession(sessionID: hoveredSpawnerSessionID) == nil {
                self.hoveredSpawnerSessionID = nil
            }
        }
        .onChange(of: store.pendingRenameWorkspaceRequest) { _, _ in
            guard let request = store.consumePendingWorkspaceRenameRequest(windowID: windowID),
                  let window = store.window(id: windowID),
                  window.workspaceIDs.contains(request.workspaceID),
                  let workspace = store.state.workspacesByID[request.workspaceID],
                  // Subspace rows have no inline rename field yet; entering the
                  // rename state for one would be invisible and block card drags.
                  // The coordinator's workspace keeps its name.
                  workspace.parentWorkspaceID == nil, workspace.isCoordinator == false else { return }
            beginWorkspaceRename(workspace)
        }
        .onAppear {
            schedulePendingSidebarSessionFlashRequestHandling()
        }
        .onChange(of: store.pendingSidebarSessionFlashRequest) { _, _ in
            schedulePendingSidebarSessionFlashRequestHandling()
        }
        .onDisappear {
            cancelSessionInteraction()
            cancelWorkspaceDrag()
            sidebarFlashClearWorkItem?.cancel()
            sidebarFlashResetWorkItem?.cancel()
            optionKeyPressed = false
        }
        .background {
            ModifierKeyPressObserver(modifier: .option, isPressed: $optionKeyPressed)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private func refreshTaskBoardSnapshot() {
        guard taskBoard.isEnabled else {
            taskBoardSnapshot.windowItems = []
            taskBoardSnapshot.allItems = []
            return
        }
        let all = taskBoard.items()
        taskBoardSnapshot.allItems = all
        taskBoardSnapshot.windowItems = TaskBoard.items(all, in: windowID, state: store.state)
    }

    private var sidebarSegment: SidebarSegment {
        store.window(id: windowID)?.sidebarSegment ?? .all
    }

    private func tasksHeader(needsYouCount: Int) -> some View {
        SidebarTasksHeader(
            needsYouCount: needsYouCount,
            isTasksViewShown: store.window(id: windowID)?.showsTasksView ?? false,
            segment: sidebarSegment,
            openTasksView: { openTasksView(selecting: nil) },
            newTask: newTask.map { action in { action() } },
            newTaskShortcutLabel: taskBoard.newTaskShortcut?.label,
            showsShortcutBadge: optionKeyPressed,
            selectSegment: { segment in
                _ = store.send(.setSidebarSegment(windowID: windowID, segment: segment), source: .ui("sidebar_segment"))
            },
            webhooks: taskBoard.coordinator?.webhooks
        )
    }

    /// The coordinator's row, when this window holds its workspace. It is
    /// outside the scrolling list and outside both segments, so no segment
    /// or card state hides it.
    @ViewBuilder
    private var coordinatorRow: some View {
        if let controller = taskCoordinator?.coordinatorController,
           let location = store.state.coordinator, location.windowID == windowID,
           let workspace = store.state.workspacesByID[location.workspaceID] {
            let isSelected = selectedWorkspaceID == location.workspaceID
                && store.window(id: windowID)?.showsTasksView != true
            let dockShows = controller.dockShows(in: windowID)
            SidebarCoordinatorRow(
                workspace: workspace,
                isSelected: isSelected,
                // The full view's panel, or the dock's chat, is read.
                readPanelID: isSelected ? workspace.focusedPanelID : (dockShows ? location.panelID : nil),
                offersDock: controller.chatIsAvailable,
                dockShows: dockShows,
                controller: controller,
                sessionRuntimeStore: sessionRuntimeStore,
                select: {
                    cancelWorkspaceRename()
                    // Where the chat can show, a click opens the dock with
                    // the keyboard in its field. In the full view, the
                    // field there takes the keyboard.
                    if controller.chatIsAvailable, isSelected == false {
                        controller.showDock(focusComposer: true)
                    } else if controller.chatIsAvailable {
                        controller.chat?.requestComposerFocus(host: .panel)
                    } else {
                        _ = store.selectWorkspace(
                            windowID: windowID,
                            workspaceID: location.workspaceID,
                            preferringUnreadSessionPanelIn: sessionRuntimeStore
                        )
                    }
                },
                openFullView: {
                    cancelWorkspaceRename()
                    controller.openFullView()
                },
                toggleDock: {
                    cancelWorkspaceRename()
                    controller.toggleDock()
                },
                openPolicy: {
                    cancelWorkspaceRename()
                    do {
                        try controller.openPolicy()
                    } catch {
                        TaskActions.presentFailure("Unable to Open the Coordinator's Policy", error.localizedDescription)
                    }
                },
                restart: {
                    Task { @MainActor in
                        do {
                            try await controller.restart()
                        } catch {
                            TaskActions.presentFailure("Unable to Restart the Coordinator", error.localizedDescription)
                        }
                    }
                },
                close: { requestWorkspaceClose(workspaceID: location.workspaceID) }
            )
        }
    }

    private func openTasksView(selecting subject: TaskBoardItem.Subject?, revealing group: TaskStage.Group? = nil) {
        cancelWorkspaceRename()
        taskBoard.showTasksView(
            windowID: windowID,
            selecting: subject,
            revealing: group,
            store: store,
            source: .ui("sidebar_tasks_row")
        )
    }

    // MARK: - Buckets

    /// A row a card lists in a bucket.
    private struct CardRow {
        enum Kind {
            case terminal(TerminalStatusRow)
            case subspace(SidebarSubspacePresentation.Row)
            case task(TaskBoardItem)
        }

        let kind: Kind
        /// The task that started this one. The Needs you segment names it on
        /// a row that lists without that task.
        var parentTaskTitle: String? = nil
    }

    /// One card's rows for a body pass. The Other tasks card has no
    /// workspace.
    private struct BucketedCard: Identifiable {
        let workspaceID: UUID?
        let title: String
        let sessionStatuses: [WorkspaceSessionStatus]
        /// The card's task space rows, before the spawner filter.
        let subspaceRows: [SidebarSubspacePresentation.Row]
        /// Task spaces the card's sessions started under other cards.
        let otherCardSpawns: [String: OtherCardSubspaceSpawn]
        let counts: [SidebarBucket: Int]
        var layout = SidebarBuckets.Layout<CardRow>()
        var needsYou = SidebarBuckets.NeedsYouList<CardRow>()

        var id: UUID { workspaceID ?? SidebarView.otherTasksCardID }
        /// Whether the All segment draws any bucket for the card.
        var hasRows: Bool { layout.entries.isEmpty == false }
    }

    /// The bucketed sidebar for one body pass, while the task system is on.
    private struct BucketedSidebar {
        var cards: [UUID: BucketedCard] = [:]
        /// Tasks whose project is not open in the window, such as one that
        /// waits for its workspace to be picked.
        var other: BucketedCard?
        var needsYouCount = 0
    }

    /// Stands in for a workspace ID where the Other tasks card needs one.
    private static let otherTasksCardID = UUID(uuidString: "00000000-0000-0000-0000-00000000071D")!
    static let otherTasksCardTitle = "Other tasks"

    private func isCardCollapsed(_ workspaceID: UUID) -> Bool {
        store.window(id: windowID)?.collapsedSidebarWorkspaceIDs.contains(workspaceID) ?? false
    }

    /// The selected row: a task space, or the focused session of a selected
    /// project workspace. Selecting either reads its finished turn.
    private var selectedRowKey: SidebarRowKey? {
        guard let workspace = store.selectedWorkspace(in: windowID) else { return nil }
        if workspace.parentWorkspaceID != nil { return .workspace(workspace.id) }
        return workspace.focusedPanelID.map(SidebarRowKey.panel)
    }

    /// Every card's rows in their buckets, for the segment on screen.
    private func makeBucketedSidebar() -> BucketedSidebar {
        let segment = sidebarSegment
        if bucketMemory.segment != segment {
            // Buckets from a segment that is not on screen would hold the
            // next selection where the user no longer sees it.
            bucketMemory.segment = segment
            bucketMemory.pin = nil
            bucketMemory.displayed = [:]
        }
        let pin = SidebarBuckets.pin(previous: bucketMemory.pin, selected: selectedRowKey, displayed: bucketMemory.displayed)
        let windowWorkspaceIDs = Set(store.window(id: windowID)?.workspaceIDs ?? [])
        let topLevelWorkspaceIDs = store.state.topLevelWorkspaceIDs(in: windowID)
        let itemsByTaskID = Dictionary(
            taskBoardSnapshot.allItems.compactMap { item in item.taskID.map { ($0, item) } },
            uniquingKeysWith: { first, _ in first }
        )
        // A task's row in this window: its task space row, or its own.
        func rowKey(_ item: TaskBoardItem) -> SidebarRowKey {
            if let taskSpace = item.taskSpaceWorkspaceID, windowWorkspaceIDs.contains(taskSpace) {
                return .workspace(taskSpace)
            }
            return .task(item.id)
        }
        func parentItem(ofTaskID taskID: UUID?) -> TaskBoardItem? {
            taskID.flatMap { itemsByTaskID[$0]?.parentTaskID }.flatMap { itemsByTaskID[$0] }
        }
        // Each card's sessions and task space rows, read once for the pass.
        var cardInputs: [(workspace: WorkspaceState, sessionStatuses: [WorkspaceSessionStatus], subspaceRows: [SidebarSubspacePresentation.Row])] = []
        for workspaceID in topLevelWorkspaceIDs {
            guard let workspace = store.state.workspacesByID[workspaceID] else { continue }
            let sessionStatuses = sidebarSessionStatuses(for: workspaceID)
            cardInputs.append((workspace, sessionStatuses, subspaceRows(for: workspaceID, parentSessionStatuses: sessionStatuses)))
        }
        let nestedTaskSpaceIDs = Set(cardInputs.flatMap { $0.subspaceRows.map(\.id) })
        // Tasks that list by a row of their own: no task space row under a
        // card, and a stage the buckets list. A task space that became a
        // top-level workspace, such as when its project closed, lists here
        // too, so its task's stage still shows. Rows keep the order the
        // sidebar lists tasks in, not their latest activity.
        let recordItems = SidebarStatusSections.sidebarOrder(
            taskBoardSnapshot.windowItems.filter { item in
                item.taskSpaceWorkspaceID.map(nestedTaskSpaceIDs.contains) != true
                    && SidebarBucket(item.stage.group) != nil
            },
            workspaceIDs: store.window(id: windowID)?.workspaceIDs ?? []
        )
        func recordCandidates(_ items: [TaskBoardItem]) -> [SidebarBucketCandidate<CardRow>] {
            items.compactMap { item in
                guard let bucket = SidebarBucket(item.stage.group) else { return nil }
                let parent = parentItem(ofTaskID: item.taskID)
                return SidebarBucketCandidate(
                    key: rowKey(item), bucket: bucket, parent: parent.map(rowKey),
                    payload: CardRow(kind: .task(item), parentTaskTitle: parent?.title)
                )
            }
        }

        var displayed: [SidebarRowKey: SidebarBucket] = [:]
        var nextPin: SidebarBucketPin?
        var needsYouCount = 0
        func card(
            workspaceID: UUID?,
            title: String,
            sessionStatuses: [WorkspaceSessionStatus] = [],
            subspaceRows: [SidebarSubspacePresentation.Row] = [],
            otherCardSpawns: [String: OtherCardSubspaceSpawn] = [:],
            candidates: [SidebarBucketCandidate<CardRow>],
            shown: [SidebarBucketCandidate<CardRow>]
        ) -> BucketedCard {
            var card = BucketedCard(
                workspaceID: workspaceID, title: title, sessionStatuses: sessionStatuses,
                subspaceRows: subspaceRows, otherCardSpawns: otherCardSpawns, counts: SidebarBuckets.counts(candidates)
            )
            switch segment {
            case .all:
                card.layout = SidebarBuckets.layout(shown, pin: pin)
                displayed.merge(card.layout.displayed) { first, _ in first }
                nextPin = card.layout.pin ?? nextPin
            case .needsYou:
                card.needsYou = SidebarBuckets.needsYou(candidates, pin: pin)
                displayed.merge(card.needsYou.displayed) { first, _ in first }
                nextPin = card.needsYou.pin ?? nextPin
            }
            needsYouCount += card.counts[.needsYou] ?? 0
            return card
        }

        var result = BucketedSidebar()
        for (workspace, sessionStatuses, subspaceRows) in cardInputs {
            let workspaceID = workspace.id
            let otherCardSpawns = otherCardSubspaceSpawns(cardWorkspaceID: workspaceID, sessionStatuses: sessionStatuses)
            var candidates = terminalStatusRows(sessionStatuses, workspace: workspace).map { row in
                let bucket: SidebarBucket = switch row {
                case .session(let status):
                    // As the row draws it: without children a task space
                    // row shows.
                    .session(
                        kind: status.status.kind,
                        isUnread: showsUnreadSessionAccent(for: status.panelID, in: workspace),
                        childNeedsAttention: SidebarSessionPresentation.sessionChildRowsNeedAttention(
                            hidingSubspaceChildren(status, subspaceIDs: childWorkspaceIDsShownElsewhere(
                                sessionID: status.sessionID, subspaceRows: subspaceRows, otherCardSpawns: otherCardSpawns
                            )).children
                        )
                    )
                case .program(let program):
                    .session(kind: program.status.kind, isUnread: program.presentation.record.state == .done)
                }
                return SidebarBucketCandidate(key: .panel(row.panelID), bucket: bucket, payload: CardRow(kind: .terminal(row)))
            }
            candidates += subspaceRows.map { row in
                let parent = parentItem(ofTaskID: store.state.workspacesByID[row.id]?.taskID)
                return SidebarBucketCandidate(
                    key: .workspace(row.id), bucket: .subspace(row), parent: parent.map(rowKey),
                    payload: CardRow(kind: .subspace(row), parentTaskTitle: parent?.title)
                )
            }
            candidates += recordCandidates(recordItems.filter { $0.projectWorkspaceID == workspaceID })
            // The ⑂ filter narrows the task space rows the All card draws;
            // the counts and the Needs you segment ignore it.
            let filterSessionID = subspaceFilterSessionIDByParentID[workspaceID]
            let filteredIDs = Set(SidebarSubspacePresentation.filteredRows(subspaceRows, spawningSessionID: filterSessionID).map(\.id))
            let shown = candidates.filter { candidate in
                guard case .subspace(let row) = candidate.payload.kind else { return true }
                return filteredIDs.contains(row.id)
            }
            result.cards[workspaceID] = card(
                workspaceID: workspaceID, title: workspace.title, sessionStatuses: sessionStatuses,
                subspaceRows: subspaceRows, otherCardSpawns: otherCardSpawns, candidates: candidates, shown: shown
            )
        }

        let topLevel = Set(topLevelWorkspaceIDs)
        let otherCandidates = recordCandidates(recordItems.filter { $0.projectWorkspaceID.map(topLevel.contains) != true })
        if otherCandidates.isEmpty == false || otherFinishedItems(.toShip).isEmpty == false {
            result.other = card(workspaceID: nil, title: Self.otherTasksCardTitle, candidates: otherCandidates, shown: otherCandidates)
        }
        result.needsYouCount = needsYouCount
        bucketMemory.pin = nextPin
        bucketMemory.displayed = displayed
        return result
    }

    /// To ship or Done tasks whose project is not open in the window.
    private func otherFinishedItems(_ group: TaskStage.Group) -> [TaskBoardItem] {
        let topLevel = Set(store.state.topLevelWorkspaceIDs(in: windowID))
        return taskBoardSnapshot.windowItems.filter { item in
            item.stage.group == group && item.projectWorkspaceID.map(topLevel.contains) != true
        }
    }

    /// A card's buckets in the All segment: Needs you, Running and Idle,
    /// each with its header. Empty buckets do not show.
    private func bucketedCardBody(_ card: BucketedCard, workspace: WorkspaceState?) -> some View {
        let filterSessionID = workspace.flatMap { subspaceFilterSessionIDByParentID[$0.id] }
        let filteredRows = SidebarSubspacePresentation.filteredRows(card.subspaceRows, spawningSessionID: filterSessionID)
        let attentionRowIDs = Set(card.subspaceRows.filter { $0.status.needsAttention }.map(\.id))
        let orderedKeys = SidebarBucket.allCases.flatMap { card.layout.entries($0).map(\.key) }
        return VStack(alignment: .leading, spacing: 0) {
            if let workspace, let filterSessionID {
                subspacesFilterBar(
                    spawnerName: card.subspaceRows.first { $0.spawningSessionID == filterSessionID }?.spawnerName ?? "this agent",
                    parentWorkspaceID: workspace.id
                )
                .padding(.bottom, 2)
            }
            ForEach(SidebarBucket.allCases, id: \.self) { bucket in
                let entries = card.layout.entries(bucket)
                if entries.isEmpty == false {
                    bucketHeader(bucket, count: card.counts[bucket] ?? 0)
                    VStack(alignment: .leading, spacing: Self.sessionRowSpacing) {
                        ForEach(entries) { entry in
                            bucketRow(entry, card: card, workspace: workspace)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.28), value: orderedKeys)
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .id(SubspaceGroupScrollID(parentWorkspaceID: card.id))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.workspace.buckets.\(card.id.uuidString)")
        // As in the Task Spaces group: a task space that newly needs the
        // user clears a ⑂ filter that would hide it, and a filter whose
        // agent has no task spaces left clears itself.
        .onChange(of: attentionRowIDs) { previousIDs, currentIDs in
            guard let workspace, let filterSessionID else { return }
            let hiddenNewIDs = currentIDs.subtracting(previousIDs).filter { rowID in
                card.subspaceRows.first { $0.id == rowID }?.spawningSessionID != filterSessionID
            }
            if hiddenNewIDs.isEmpty == false {
                subspaceFilterSessionIDByParentID.removeValue(forKey: workspace.id)
            }
        }
        .onChange(of: filteredRows.isEmpty, initial: true) { _, isEmpty in
            if isEmpty, let workspace, filterSessionID != nil {
                subspaceFilterSessionIDByParentID.removeValue(forKey: workspace.id)
            }
        }
    }

    /// "NEEDS YOU 4" over a bucket's rows. The count is the rows whose own
    /// state is in the bucket; a dimmed relative or a held row counts where
    /// its own state is.
    private func bucketHeader(_ bucket: SidebarBucket, count: Int) -> some View {
        SidebarGroupTitle(title: bucket.title, count: count)
            .foregroundStyle(bucket == .needsYou ? Self.needsYouMarkColor : ToastyTheme.sidebarChildContextText)
            .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
            .padding(.leading, 8)
            .padding(.top, 6)
            .padding(.bottom, 1)
            .background {
                SidebarSemanticTextBridge(text: "\(bucket.title), \(count)")
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
            .accessibilityAddTraits(.isHeader)
    }

    private static let needsYouMarkColor = Color(hex: 0xF2C46B)

    /// One row in a bucket, drawn by the row's own kind: a session or
    /// program row, a task space row, or a task without an open task space.
    @ViewBuilder
    private func bucketRow(
        _ entry: SidebarBucketEntry<CardRow>,
        card: BucketedCard,
        workspace: WorkspaceState?
    ) -> some View {
        Group {
            switch entry.payload.kind {
            case .terminal(let row):
                if let workspace {
                    terminalStatusRowView(row, workspace: workspace, subspaceRows: card.subspaceRows, otherCardSpawns: card.otherCardSpawns)
                }
            case .subspace(let row):
                let parentWorkspaceID = card.workspaceID ?? row.id
                subspaceRow(
                    Self.bucketedSubspaceRow(row, entry: entry),
                    parentWorkspaceID: parentWorkspaceID,
                    showsSpawnerTag: SidebarSubspacePresentation.showsSpawnerTag(
                        row,
                        parentWorkspaceID: parentWorkspaceID,
                        groupShowsSpawnerTags: SidebarSubspacePresentation.showsSpawnerTags(card.subspaceRows)
                    )
                )
            case .task(let item):
                if let taskSpaceID = item.taskSpaceWorkspaceID,
                   store.window(id: windowID)?.workspaceIDs.contains(taskSpaceID) == true,
                   let taskSpace = store.state.workspacesByID[taskSpaceID] {
                    // Its task space is open as a workspace of its own.
                    let row = subspaceRowModel(workspace: taskSpace, spawner: nil, projectTag: card.workspaceID == nil ? item.projectTitle : nil)
                    subspaceRow(Self.bucketedSubspaceRow(row, entry: entry), parentWorkspaceID: taskSpaceID, showsSpawnerTag: false)
                } else {
                    SidebarTaskRecordRow(
                        item: item,
                        showsProject: card.workspaceID == nil,
                        parentTaskTitle: entry.listsApartFromParent ? entry.payload.parentTaskTitle : nil
                    ) { openTasksView(selecting: item.id) }
                        .padding(.leading, entry.isLinkedChild ? Self.linkedChildIndent : 0)
                        .overlay(alignment: .topLeading) {
                            if entry.isLinkedChild {
                                Self.linkedChildArrow
                            }
                        }
                        .contextMenu {
                            TaskContextMenuItems(sections: TaskBoardPresentation.menuItems(item), run: runTaskMenuItem)
                        }
                }
            }
        }
        // Its own state is in a calmer bucket; see `SidebarBucketEntry.isContext`.
        .opacity(entry.isContext ? 0.55 : 1)
    }

    private static func bucketedSubspaceRow(
        _ row: SidebarSubspacePresentation.Row,
        entry: SidebarBucketEntry<CardRow>
    ) -> SidebarSubspacePresentation.Row {
        var row = row
        row.isLinkedChild = entry.isLinkedChild
        row.parentTaskTitle = entry.listsApartFromParent ? entry.payload.parentTaskTitle : nil
        return row
    }

    /// The card's counts by bucket, in place of the running-agents chip:
    /// a yellow dot for Needs you, a spinner for Running, a gray dot for
    /// Idle. Empty buckets show no count.
    @ViewBuilder
    private func bucketCountsBadge(_ counts: [SidebarBucket: Int]) -> some View {
        let label = Self.bucketCountsLabel(counts)
        if label.isEmpty == false {
            HStack(spacing: 7) {
                if let count = counts[.needsYou], count > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(Self.needsYouMarkColor).frame(width: 6, height: 6)
                        Text("\(count)").foregroundStyle(Self.needsYouMarkColor)
                    }
                }
                if let count = counts[.running], count > 0 {
                    HStack(spacing: 3) {
                        SessionStatusIndicator(state: .spinner, size: 8, lineWidth: 1.4)
                        Text("\(count)")
                    }
                }
                if let count = counts[.idle], count > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(ToastyTheme.sidebarSubspaceQuietMark).frame(width: 6, height: 6)
                        Text("\(count)")
                    }
                }
            }
            .font(ToastyTheme.fontWorkspaceAgentCount)
            .foregroundStyle(ToastyTheme.inactiveText)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier("sidebar.workspace.bucketCounts")
            .background {
                SidebarSemanticTextBridge(text: label)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
        }
    }

    /// "4 need you, 2 running, 3 idle", leaving out empty buckets.
    static func bucketCountsLabel(_ counts: [SidebarBucket: Int]) -> String {
        SidebarBucket.allCases.compactMap { bucket -> String? in
            guard let count = counts[bucket], count > 0 else { return nil }
            switch bucket {
            case .needsYou: return "\(count) \(count == 1 ? "needs" : "need") you"
            case .running: return "\(count) running"
            case .idle: return "\(count) idle"
            }
        }
        .joined(separator: ", ")
    }

    /// The chevron left of a project card's name. A collapsed card shows
    /// only its name line with its counts; the choice is saved.
    private func cardCollapseButton(workspace: WorkspaceState, isCollapsed: Bool) -> some View {
        let label = "\(isCollapsed ? "Expand" : "Collapse") \(workspace.title)"
        return Button {
            cancelWorkspaceRename()
            _ = store.send(
                .setSidebarWorkspaceCollapsed(windowID: windowID, workspaceID: workspace.id, collapsed: isCollapsed == false),
                source: .ui("sidebar_card_collapse")
            )
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ToastyTheme.sidebarSessionPathText)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 4)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier("sidebar.workspace.collapse.\(workspace.id.uuidString)")
        .background {
            SidebarSemanticTextBridge(text: label)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    /// The All segment's last card: tasks whose project is not open in the
    /// window, such as one that waits for its workspace to be picked.
    private func otherTasksCard(_ card: BucketedCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(card.title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(ToastyTheme.inactiveText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                bucketCountsBadge(card.counts)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .background {
                SidebarSemanticTextBridge(text: card.title)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
            bucketedCardBody(card, workspace: nil)
            otherTasksFooter
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.otherTasks")
    }

    /// The Other tasks card's To ship and Done counts. Each opens the Tasks
    /// view at its group.
    @ViewBuilder
    private var otherTasksFooter: some View {
        let toShip = otherFinishedItems(.toShip).count
        let done = otherFinishedItems(.done).count
        if toShip > 0 || done > 0 {
            HStack(spacing: 12) {
                if toShip > 0 {
                    finishedTasksButton(.toShip, count: toShip, projectWorkspaceID: Self.otherTasksCardID) {
                        Label("To ship \(toShip)", systemImage: "arrow.up.square")
                            .foregroundStyle(ToastyTheme.sidebarTaskToShipMark)
                    }
                }
                if done > 0 {
                    finishedTasksDoneButton(count: done, projectWorkspaceID: Self.otherTasksCardID)
                }
                Spacer(minLength: 0)
            }
            .font(ToastyTheme.fontWorkspaceSessionChip)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
    }

    /// The Needs you segment: only the rows that need the user, from every
    /// project, under each project's name. Projects with nothing for the
    /// user are left out.
    private func needsYouSegmentContent(_ sidebar: BucketedSidebar) -> some View {
        let cards = store.state.topLevelWorkspaceIDs(in: windowID).compactMap { sidebar.cards[$0] }
            + [sidebar.other].compactMap { $0 }
        let listed = cards.filter { $0.needsYou.entries.isEmpty == false }
        return VStack(alignment: .leading, spacing: 4) {
            if listed.isEmpty {
                VStack(spacing: 3) {
                    Text("Nothing needs you")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(ToastyTheme.primaryText)
                    Text("Running and idle work is in All.")
                        .font(ToastyTheme.fontWorkspaceSessionChip)
                        .foregroundStyle(ToastyTheme.sidebarSessionPathText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background {
                    SidebarSemanticTextBridge(text: "Nothing needs you")
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("sidebar.needsYou.empty")
            }
            ForEach(listed) { card in
                needsYouCard(card)
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.needsYou")
    }

    /// A project's rows in the Needs you segment, under its name and count.
    /// The name selects the project's workspace.
    private func needsYouCard(_ card: BucketedCard) -> some View {
        let workspace = card.workspaceID.flatMap { store.state.workspacesByID[$0] }
        let isSelected = card.workspaceID.map(workspaceCardContainsSelection) ?? false
        let count = card.counts[.needsYou] ?? 0
        let label = "\(card.title), \(count) \(count == 1 ? "needs" : "need") you"
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(card.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? ToastyTheme.primaryText : ToastyTheme.inactiveText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if count > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(Self.needsYouMarkColor).frame(width: 6, height: 6)
                        Text("\(count)").foregroundStyle(Self.needsYouMarkColor)
                    }
                    .font(ToastyTheme.fontWorkspaceAgentCount)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
            .onTapGesture {
                guard let workspaceID = card.workspaceID else { return }
                cancelWorkspaceRename()
                store.selectWorkspace(windowID: windowID, workspaceID: workspaceID, preferringUnreadSessionPanelIn: sessionRuntimeStore)
            }
            .background {
                SidebarSemanticTextBridge(text: label)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(card.workspaceID == nil ? .isHeader : [.isHeader, .isButton])

            VStack(alignment: .leading, spacing: Self.sessionRowSpacing) {
                ForEach(card.needsYou.entries) { entry in
                    bucketRow(entry, card: card, workspace: workspace)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? ToastyTheme.elevatedBackground : Color.clear)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isSelected ? ToastyTheme.accent : Color.clear)
                .frame(width: 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.needsYou.\(card.id.uuidString)")
    }

    /// A merged task waiting for a release, under its project's card. Its
    /// task space usually closed at the merge, so the row opens the task in
    /// the Tasks view; a task space the user kept open opens instead.
    private func toShipTaskRow(_ item: TaskBoardItem) -> some View {
        let hoverID = switch item.id {
        case .task(let id), .taskSpace(let id): id
        }
        return SidebarHoverRegion(id: hoverID, selection: hoverState.toShipTask) { isHovered in
            let label = TaskBoardPresentation.addingReleaseAfterMerge(
                to: "\(item.title), \(TaskBoardPresentation.statusLine(item))", item
            )
            let open = {
                if let workspaceID = item.taskSpaceWorkspaceID {
                    runTaskMenuItem(.openTaskSpace(workspaceID: workspaceID))
                } else {
                    openTasksView(selecting: item.id)
                }
            }
            HStack(alignment: .top, spacing: Self.sessionStatusRailGap) {
                SubspaceRailStatusIcon(status: .toShip, isDoneTogglePreviewed: false)
                    .frame(width: Self.sessionStatusRailWidth, height: Self.sessionRowLineMinHeight)
                    .accessibilityHidden(true)
                Self.styledSessionNameText(item.title, isEmphasized: false)
                    .foregroundStyle(ToastyTheme.sidebarSessionAgentText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minHeight: Self.sessionRowLineMinHeight, alignment: .leading)
                if TaskBoardPresentation.releaseAfterMergeRequestedAt(item) != nil {
                    TaskReleaseAfterMergeMark()
                        .frame(minHeight: Self.sessionRowLineMinHeight)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? ToastyTheme.sidebarSessionHoverBackground : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .onTapGesture(perform: open)
            .onHover { isHovering in
                if isHovering {
                    hoverState.toShipTask.value = hoverID
                } else if hoverState.toShipTask.value == hoverID {
                    hoverState.toShipTask.value = nil
                }
            }
            .help(TaskBoardPresentation.addingReleaseAfterMerge(to: TaskBoardPresentation.statusLine(item), item))
            .background {
                SidebarSemanticTextBridge(text: label)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, open)
            .accessibilityIdentifier(Self.toShipTaskRowIdentifier(item.id))
            .contextMenu {
                TaskContextMenuItems(sections: TaskBoardPresentation.menuItems(item), run: runTaskMenuItem)
            }
        }
    }

    static func toShipTaskRowIdentifier(_ subject: TaskBoardItem.Subject) -> String {
        switch subject {
        case .task(let id): "sidebar.toShip.task.\(id.uuidString)"
        case .taskSpace(let id): "sidebar.toShip.taskSpace.\(id.uuidString)"
        }
    }

    /// Under a project card: the tasks that left it because they finished.
    /// The To ship tasks list under "› TO SHIP N", which starts collapsed,
    /// with Release when the project can release and the Done count on the
    /// same line. Expanded, the latest To ship tasks show as rows, then
    /// "Show N more". When every To ship task shows as a task space row, the
    /// line counts them instead.
    @ViewBuilder
    private func finishedTasksFooter(projectWorkspaceID: UUID, shownTaskSpaceIDs: Set<UUID>) -> some View {
        if taskBoard.isEnabled {
            let items = taskBoardSnapshot.windowItems.filter { $0.projectWorkspaceID == projectWorkspaceID }
            let recent = SidebarRecentToShip.card(items, projectWorkspaceID: projectWorkspaceID, shownTaskSpaceIDs: shownTaskSpaceIDs)
            let listed = recent.shown.count + recent.hidden.count
            let toShip = listed == 0 ? items.filter { $0.stage == .toShip }.count : 0
            let done = items.filter { $0.stage == .done }.count
            let releaseWorkspaceID = SidebarStatusSections.releaseWorkspaceID(
                items.filter { $0.stage == .toShip },
                releasable: taskBoard.canRelease
            )
            if listed > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    // The toggle takes the width the Release button and the
                    // Done count leave.
                    HStack(spacing: 12) {
                        cardToShipToggle(count: listed, projectWorkspaceID: projectWorkspaceID)
                        if let releaseWorkspaceID {
                            cardReleaseButton(releaseWorkspaceID, projectWorkspaceID: projectWorkspaceID)
                        }
                        if done > 0 {
                            finishedTasksDoneButton(count: done, projectWorkspaceID: projectWorkspaceID)
                                .font(ToastyTheme.fontWorkspaceSessionChip)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .padding(.horizontal, 10)
                    if expandedToShipProjectIDs.contains(projectWorkspaceID) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(recent.shown) { item in
                                toShipTaskRow(item)
                            }
                            if let firstHidden = recent.hidden.first {
                                SidebarShowMoreToShipButton(count: recent.hidden.count) {
                                    openTasksView(selecting: firstHidden.id, revealing: .toShip)
                                }
                                // Lines up with the task titles: the row's
                                // padding, status mark and gap.
                                .padding(.leading, 8 + Self.sessionStatusRailWidth + Self.sessionStatusRailGap)
                                .padding(.vertical, 3)
                                .accessibilityIdentifier("sidebar.workspace.finishedTasks.toShipMore.\(projectWorkspaceID.uuidString)")
                            }
                        }
                        .padding(.horizontal, 10)
                    }
                }
                .padding(.bottom, 10)
            } else if toShip > 0 || done > 0 {
                // Each count opens the Tasks view at its own group.
                HStack(spacing: 12) {
                    if toShip > 0 {
                        finishedTasksButton(.toShip, count: toShip, projectWorkspaceID: projectWorkspaceID) {
                            Label("To ship \(toShip)", systemImage: "arrow.up.square")
                                .foregroundStyle(ToastyTheme.sidebarTaskToShipMark)
                        }
                        if let releaseWorkspaceID {
                            cardReleaseButton(releaseWorkspaceID, projectWorkspaceID: projectWorkspaceID)
                        }
                    }
                    if done > 0 {
                        finishedTasksDoneButton(count: done, projectWorkspaceID: projectWorkspaceID)
                    }
                    Spacer(minLength: 0)
                }
                .font(ToastyTheme.fontWorkspaceSessionChip)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            }
        }
    }

    /// Starts a release task for the project's merged tasks, on the card's
    /// To ship line. It shows when a To ship task merged on its own and
    /// the project can release from Toastty.
    private func cardReleaseButton(_ releaseWorkspaceID: UUID, projectWorkspaceID: UUID) -> some View {
        TaskReleaseButton(title: "Release") {
            if let coordinator = taskBoard.coordinator {
                TaskActions.release(workspaceID: releaseWorkspaceID, coordinator: coordinator)
            }
        }
        .fixedSize()
        .accessibilityIdentifier("sidebar.workspace.finishedTasks.release.\(projectWorkspaceID.uuidString)")
        .background {
            SidebarSemanticTextBridge(text: Self.cardReleaseLabel)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    static let cardReleaseLabel = "Release the merged tasks"

    /// "› TO SHIP N" under a project card, lined up with the card's
    /// "TASK SPACES" toggle.
    private func cardToShipToggle(count: Int, projectWorkspaceID: UUID) -> some View {
        let isExpanded = Binding(
            get: { expandedToShipProjectIDs.contains(projectWorkspaceID) },
            set: { isExpanded in
                if isExpanded {
                    expandedToShipProjectIDs.insert(projectWorkspaceID)
                } else {
                    expandedToShipProjectIDs.remove(projectWorkspaceID)
                }
            }
        )
        return SidebarToShipGroupToggle(
            count: count,
            isExpanded: isExpanded,
            showsMark: true,
            accessibilityText: SidebarToShipGroupToggle.label(count: count, isExpanded: isExpanded.wrappedValue)
        )
        .accessibilityIdentifier("sidebar.workspace.finishedTasks.toShipToggle.\(projectWorkspaceID.uuidString)")
    }

    private func finishedTasksDoneButton(count: Int, projectWorkspaceID: UUID) -> some View {
        finishedTasksButton(.done, count: count, projectWorkspaceID: projectWorkspaceID) {
            Label("Done \(count)", systemImage: "checkmark.square")
                .foregroundStyle(ToastyTheme.sidebarSubspaceDoneMark.opacity(0.85))
        }
    }

    private func finishedTasksButton(
        _ group: TaskStage.Group,
        count: Int,
        projectWorkspaceID: UUID,
        @ViewBuilder label: () -> some View
    ) -> some View {
        let accessibilityText = Self.finishedTasksFooterLabel(group, count: count)
        return Button {
            openTasksView(selecting: nil, revealing: group)
        } label: {
            label()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(group == .done ? "Show done tasks in the Tasks view" : "Show tasks to ship in the Tasks view")
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("sidebar.workspace.finishedTasks.\(group == .done ? "done" : "toShip").\(projectWorkspaceID.uuidString)")
        .background {
            SidebarSemanticTextBridge(text: accessibilityText)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    static func finishedTasksFooterLabel(_ group: TaskStage.Group, count: Int) -> String {
        let counted = group == .done ? "\(count) done" : "\(count) to ship"
        return "Finished tasks: \(counted). Opens the Tasks view."
    }

    private var sidebarTitlebarCover: some View {
        Rectangle()
            .fill(ToastyTheme.chromeBackground)
            .frame(maxWidth: .infinity)
            .frame(height: ToastyTheme.sidebarTopPadding)
            .allowsHitTesting(false)
    }

    private var sidebarHiddenSessionContent: SidebarScrollGeometry.Content {
        guard activeWorkspaceDrag == nil, activeSessionDrag == nil else {
            return SidebarScrollGeometry.Content(isDragging: true)
        }
        // The pills point at session rows in project cards, which the Needs
        // you segment does not draw. Rows in a collapsed card have no frame,
        // so the pills leave them out; the card's counts show them.
        guard taskBoard.isEnabled == false || sidebarSegment == .all else {
            return SidebarScrollGeometry.Content()
        }

        var content = SidebarScrollGeometry.Content()
        // Derive IDs and attention from the same status pass for both pills.
        for workspaceID in store.window(id: windowID)?.workspaceIDs ?? [] {
            // The coordinator's pinned row draws no session rows to point at.
            guard let workspace = store.state.workspacesByID[workspaceID], workspace.isCoordinator == false else { continue }
            for status in sidebarSessionStatuses(for: workspaceID) {
                let rowID = SidebarSessionPresentation.SidebarSessionRowID(
                    workspaceID: workspaceID, sessionID: status.sessionID, panelID: status.panelID
                )
                content.orderedSessionRowIDs.append(rowID)
                if showsUnreadSessionAccent(for: status.panelID, in: workspace) {
                    content.unreadSessionRowIDs.insert(rowID)
                }
                if status.status.kind == .working {
                    content.workingSessionRowIDs.insert(rowID)
                }
            }
        }
        for parentID in store.state.topLevelWorkspaceIDs(in: windowID) {
            let rows = subspaceRows(for: parentID, parentSessionStatuses: sidebarSessionStatuses(for: parentID))
            // Bucketed cards have no Task Spaces group to collapse.
            let isCollapsed = taskBoard.isEnabled == false && collapsedSubspaceGroupParentIDs.contains(parentID)
            let displayedRows = isCollapsed ? rows : SidebarSubspacePresentation.filteredRows(
                rows, spawningSessionID: subspaceFilterSessionIDByParentID[parentID]
            )
            content.subspaceRows.append(contentsOf: displayedRows)
            for row in displayedRows {
                // A collapsed group represents its rows at the header's position.
                content.subspaceFrameIDs[row.id] = isCollapsed ? .group(parentID) : .row(row.id)
            }
        }
        return content
    }

    @ViewBuilder
    private func hiddenSessionPill(
        _ pill: SidebarSessionPresentation.HiddenSessionPill?,
        using proxy: ScrollViewProxy
    ) -> some View {
        if let pill {
            Button {
                scrollToHiddenSession(pill, using: proxy)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: pill.direction.iconName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(ToastyTheme.hiddenSessionPillText)

                    if pill.hasWorking {
                        SessionStatusIndicator(state: .spinner, size: 8, lineWidth: 1.4)
                    }

                    if pill.unreadCount > 0 {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(ToastyTheme.badgeBlue)
                                .frame(width: 6, height: 6)
                                .shadow(color: ToastyTheme.badgeBlue.opacity(0.5), radius: 3, x: 0, y: 0)

                            Text("\(pill.unreadCount)")
                                .font(ToastyTheme.fontWorkspaceAgentCount)
                                .foregroundStyle(ToastyTheme.badgeBlue)
                        }
                        .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(
                    Capsule()
                        .fill(ToastyTheme.elevatedBackground)
                )
                .overlay {
                    Capsule()
                        .stroke(Self.hiddenSessionPillBorderColor(pill), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .background {
                SidebarSemanticTextBridge(text: SidebarSessionPresentation.hiddenSessionPillAccessibilityLabel(pill))
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel(SidebarSessionPresentation.hiddenSessionPillAccessibilityLabel(pill))
            .accessibilityIdentifier("sidebar.hiddenSessions.\(pill.direction.accessibilityDirection)")
            .offset(y: pill.direction == .above ? ToastyTheme.sidebarTopPadding + 8 : -12)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.12), value: pill)
        }
    }

    @ViewBuilder
    private func workspaceRow(
        workspaceID: UUID,
        workspace: WorkspaceState,
        shortcutLabel: String?,
        isSelected: Bool,
        index: Int,
        orderedWorkspaceIDs: [UUID],
        card: BucketedCard? = nil
    ) -> some View {
        let row = Group {
            if renamingWorkspaceID == workspaceID {
                workspaceRenameRow(
                    workspaceID: workspaceID,
                    workspace: workspace,
                    shortcutLabel: shortcutLabel,
                    isSelected: isSelected,
                    sourceIndex: index - 1,
                    orderedWorkspaceIDs: orderedWorkspaceIDs,
                    card: card
                )
            } else {
                workspaceButton(
                    workspaceID: workspaceID,
                    workspace: workspace,
                    shortcutLabel: shortcutLabel,
                    isSelected: isSelected,
                    sourceIndex: index - 1,
                    orderedWorkspaceIDs: orderedWorkspaceIDs,
                    card: card
                )
            }
        }
        .offset(y: activeWorkspaceDrag?.workspaceID == workspaceID ? activeWorkspaceDrag?.translationHeight ?? 0 : 0)
        .zIndex(activeWorkspaceDrag?.workspaceID == workspaceID ? 1 : 0)
        .accessibilityIdentifier("sidebar.workspace.\(index)")

        row.contextMenu {
            if activeWorkspaceDrag == nil {
                Button(ToasttyKeyboardShortcuts.renameWorkspace.menuTitle("Rename Workspace")) {
                    beginWorkspaceRename(workspace)
                }

                Button(ToasttyKeyboardShortcuts.closeWorkspace.menuTitle("Close workspace"), role: .destructive) {
                    requestWorkspaceClose(workspaceID: workspaceID)
                }
            }
        }
    }

    private func workspaceButton(
        workspaceID: UUID,
        workspace: WorkspaceState,
        shortcutLabel: String?,
        isSelected: Bool,
        sourceIndex: Int,
        orderedWorkspaceIDs: [UUID],
        card: BucketedCard?
    ) -> some View {
        let sessionStatuses = card?.sessionStatuses ?? sidebarSessionStatuses(for: workspace.id)
        let subspaceRows = card?.subspaceRows ?? subspaceRows(for: workspace.id, parentSessionStatuses: sessionStatuses)
        let agentSummary = WorkspaceAgentSummary.make(from: sessionStatuses, workspaceID: workspace.id)
        let accessibilityLabel = SidebarSessionPresentation.workspaceAccessibilityLabel(
            for: workspace,
            isSelected: isSelected,
            agentSummary: agentSummary
        )
        let isCollapsed = card != nil && isCardCollapsed(workspaceID)

        return workspaceRowChrome(
            workspaceID: workspaceID,
            isSelected: isSelected,
            isFlashing: flashingWorkspaceID == workspaceID
        ) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    if card != nil {
                        // Outside the header's pointer overlay, which would
                        // take its clicks for selection and drags.
                        cardCollapseButton(workspace: workspace, isCollapsed: isCollapsed)
                    }
                    workspaceHeaderContent(leadingPadding: card == nil ? 10 : 2) {
                        workspacePrimaryContent(
                            workspace: workspace,
                            shortcutLabel: shortcutLabel,
                            selectionSubtitle: nil,
                            isSelected: isSelected,
                            agentSummary: agentSummary,
                            bucketCounts: card?.counts
                        ) {
                            Self.styledWorkspaceTitleText(
                                workspace.title,
                                isSelected: isSelected,
                                hasBeenVisited: workspace.hasBeenVisited
                            )
                                .foregroundStyle(isSelected ? ToastyTheme.primaryText : ToastyTheme.inactiveText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .contentShape(Rectangle())
                    .overlay {
                        PointerInteractionRegion(
                            name: "workspace-sidebar-row",
                            metadata: [
                                "workspaceID": workspaceID.uuidString,
                                "sourceIndex": "\(sourceIndex)",
                            ],
                            onBegan: { _ in
                                beginWorkspaceInteraction(workspaceID: workspaceID)
                            },
                            onChanged: { value in
                                updateWorkspaceDrag(
                                    workspaceID: workspaceID,
                                    sourceIndex: sourceIndex,
                                    orderedWorkspaceIDs: orderedWorkspaceIDs,
                                    value: value
                                )
                            },
                            onEnded: { value in
                                finishWorkspaceInteraction(
                                    workspaceID: workspaceID,
                                    workspace: workspace,
                                    value: value
                                )
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityAction {
                        handleWorkspaceButtonActivation(workspaceID: workspaceID, workspace: workspace)
                    }
                    .background {
                        SidebarSemanticTextBridge(text: accessibilityLabel)
                    }
                }

                if let card {
                    // A collapsed card keeps only its name line.
                    if isCollapsed == false {
                        workspaceAnnotationChipsRow(workspace: workspace)
                        if card.hasRows {
                            bucketedCardBody(card, workspace: workspace)
                        }
                        finishedTasksFooter(projectWorkspaceID: workspace.id, shownTaskSpaceIDs: Set(subspaceRows.map(\.id)))
                    }
                } else {
                    // Rendered below and outside the title header's AppKit
                    // pointer-interaction overlay: workspace drag keeps starting
                    // from the title region while link chips stay real buttons.
                    workspaceAnnotationChipsRow(workspace: workspace)

                    if !sessionStatuses.isEmpty || !sessionRuntimeStore.programStatusRows(in: workspace).isEmpty {
                        sessionStatusesContent(sessionStatuses, workspace: workspace, subspaceRows: subspaceRows)
                            .padding(.horizontal, 10)
                            .padding(.bottom, Self.sessionListBottomPadding(followedBySubspaces: subspaceRows.isEmpty == false))
                    }

                    subspacesGroup(subspaceRows, parentWorkspaceID: workspace.id)
                    finishedTasksFooter(projectWorkspaceID: workspace.id, shownTaskSpaceIDs: Set(subspaceRows.map(\.id)))
                }
            }
        }
    }

    private func workspaceRenameRow(
        workspaceID: UUID,
        workspace: WorkspaceState,
        shortcutLabel: String?,
        isSelected: Bool,
        sourceIndex _: Int,
        orderedWorkspaceIDs _: [UUID],
        card: BucketedCard?
    ) -> some View {
        let sessionStatuses = card?.sessionStatuses ?? sidebarSessionStatuses(for: workspace.id)
        let subspaceRows = card?.subspaceRows ?? subspaceRows(for: workspace.id, parentSessionStatuses: sessionStatuses)
        let agentSummary = WorkspaceAgentSummary.make(from: sessionStatuses, workspaceID: workspace.id)
        let isCollapsed = card != nil && isCardCollapsed(workspaceID)

        return workspaceRowChrome(
            workspaceID: workspaceID,
            isSelected: isSelected,
            isFlashing: flashingWorkspaceID == workspaceID
        ) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    if card != nil {
                        cardCollapseButton(workspace: workspace, isCollapsed: isCollapsed)
                    }
                    workspaceHeaderContent(leadingPadding: card == nil ? 10 : 2) {
                        workspacePrimaryContent(
                            workspace: workspace,
                            shortcutLabel: shortcutLabel,
                            selectionSubtitle: nil,
                            isSelected: isSelected,
                            agentSummary: agentSummary,
                            bucketCounts: card?.counts
                        ) {
                            WorkspaceRenameTextField(
                                text: $renameDraftTitle,
                                itemID: workspaceID,
                                placeholder: "Workspace name",
                                font: ToastyTheme.sidebarWorkspaceNameNSFont(isSelected: isSelected),
                                accessibilityID: renameTextFieldAccessibilityID(for: workspaceID),
                                onSubmit: {
                                    commitWorkspaceRename(workspaceID: workspaceID)
                                },
                                onCancel: {
                                    cancelWorkspaceRename()
                                    scheduleWorkspaceSlotFocusRestore()
                                }
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if let card {
                    if isCollapsed == false {
                        workspaceAnnotationChipsRow(workspace: workspace)
                        if card.hasRows {
                            bucketedCardBody(card, workspace: workspace)
                        }
                    }
                } else {
                    workspaceAnnotationChipsRow(workspace: workspace)
                    if !sessionStatuses.isEmpty || !sessionRuntimeStore.programStatusRows(in: workspace).isEmpty {
                        sessionStatusesContent(sessionStatuses, workspace: workspace, subspaceRows: subspaceRows)
                            .padding(.horizontal, 10)
                            .padding(.bottom, Self.sessionListBottomPadding(followedBySubspaces: subspaceRows.isEmpty == false))
                    }
                    subspacesGroup(subspaceRows, parentWorkspaceID: workspace.id)
                }
            }
        }
    }

    /// Intrinsic-width annotation chips in deterministic bytewise key order.
    /// Whole chips wrap before they shrink; an individually overlong chip
    /// truncates to the row width and exposes its full value in a tooltip.
    @ViewBuilder
    private func workspaceAnnotationChipsRow(workspace: WorkspaceState) -> some View {
        let sortedAnnotations = workspace.annotations.sorted { $0.key < $1.key }
        if sortedAnnotations.isEmpty == false {
            SidebarWrappingFlowLayout(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(sortedAnnotations, id: \.key) { key, annotation in
                    workspaceAnnotationChip(key: key, annotation: annotation)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, -6)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private func workspaceAnnotationChip(
        key: String,
        annotation: WorkspaceAnnotation,
        maximumWidth: CGFloat = SidebarView.workspaceAnnotationChipMaximumWidth,
        showsLinkGlyph: Bool = true
    ) -> some View {
        let chipColors = ToastyTheme.annotationChipColors(
            for: annotationStyleStore.effectiveColorToken(forKey: key)
        )
        if let url = annotation.url {
            Button {
                openWorkspaceAnnotationURL(url)
            } label: {
                Self.workspaceAnnotationChipLabel(
                    annotation: annotation,
                    chipColors: chipColors,
                    isLink: showsLinkGlyph,
                    maximumWidth: maximumWidth
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(key): \(annotation.text), link")
            .background {
                ZStack {
                    SidebarTooltipBridge(text: annotation.text)
                    SidebarSemanticTextBridge(text: "\(key): \(annotation.text)")
                        .frame(width: 0, height: 0)
                }
                .allowsHitTesting(false)
            }
        } else {
            Self.workspaceAnnotationChipLabel(
                annotation: annotation,
                chipColors: chipColors,
                isLink: false,
                maximumWidth: maximumWidth
            )
                .background {
                    SidebarTooltipBridge(text: annotation.text)
                        .allowsHitTesting(false)
                }
                .accessibilityHidden(true)
        }
    }

    static let workspaceAnnotationChipMaximumWidth: CGFloat = 160
    /// Tighter than a card's chips: the chip shares one line with the row
    /// title, which truncates first. The chip's tooltip shows the full text.
    static let subspaceRowAnnotationChipMaximumWidth: CGFloat = 96
    /// Room for the ↖ and a few characters of the spawner's name; the tag
    /// only tells rows with different spawners apart, and its tooltip and the
    /// hover card carry the full name.
    static let subspaceSpawnerTagMaximumWidth: CGFloat = 60

    static func workspaceAnnotationChipLabel(
        annotation: WorkspaceAnnotation,
        chipColors: ToastyTheme.AnnotationChipColors,
        isLink: Bool,
        maximumWidth: CGFloat = SidebarView.workspaceAnnotationChipMaximumWidth
    ) -> some View {
        SidebarCappedIntrinsicWidthLayout(maximumWidth: maximumWidth) {
            HStack(spacing: 3) {
                Text(annotation.text)
                    .font(ToastyTheme.fontWorkspaceSessionChip)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isLink {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 7, weight: .semibold))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
        .foregroundStyle(chipColors.foreground)
        .background(chipColors.background)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(chipColors.border, lineWidth: 1)
        }
    }

    private func openWorkspaceAnnotationURL(_ urlString: String) {
        // Persisted layout files are user-editable; revalidate the scheme
        // immediately before opening rather than trusting stored state.
        guard let validated = WorkspaceAnnotation.validatedURLString(urlString),
              let url = URL(string: validated) else {
            return
        }
        _ = AppURLRouter.open(
            url,
            preferredWindowID: windowID,
            appStore: store
        )
    }

    private func workspaceRowChrome<Content: View>(
        workspaceID: UUID,
        isSelected: Bool,
        isFlashing: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let rowContent = content()
        return SidebarHoverRegion(id: workspaceID, selection: hoverState.workspace) { isHovered in
            rowContent
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? ToastyTheme.elevatedBackground
                : activeWorkspaceDrag == nil && isHovered ? ToastyTheme.elevatedBackground
                : Color.clear)
            .background(workspaceRowFrameMeasurement(workspaceID: workspaceID))
            .overlay {
                Rectangle()
                    .fill(ToastyTheme.accent.opacity(0.28 * (isFlashing ? flashingSessionOverlayOpacity : 0)))
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isSelected ? ToastyTheme.accent : Color.clear)
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
            .onHover { isHovering in
                guard activeWorkspaceDrag == nil, activeSessionDrag == nil else { return }
                if isHovering {
                    hoverState.workspace.value = workspaceID
                } else if hoverState.workspace.value == workspaceID {
                    hoverState.workspace.value = nil
                }
            }
        }
    }

    private func workspaceHeaderContent<Content: View>(
        leadingPadding: CGFloat = 10,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.vertical, 12)
            .padding(.leading, leadingPadding)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private func workspacePrimaryContent<Title: View>(
        workspace: WorkspaceState,
        shortcutLabel: String?,
        selectionSubtitle: String?,
        isSelected: Bool,
        agentSummary: WorkspaceAgentSummary?,
        bucketCounts: [SidebarBucket: Int]? = nil,
        @ViewBuilder titleView: () -> Title
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                titleView()

                if SidebarSessionPresentation.showsNewWorkspaceBadge(
                    isSelected: isSelected,
                    hasBeenVisited: workspace.hasBeenVisited
                ) {
                    workspaceNewBadge()
                }

                if workspace.unreadNotificationCount > 0 {
                    Circle()
                        .fill(ToastyTheme.badgeBlue)
                        .frame(width: 7, height: 7)
                        .shadow(color: ToastyTheme.badgeBlue.opacity(0.5), radius: 3, x: 0, y: 0)
                }

                Spacer(minLength: 0)

                if let bucketCounts {
                    bucketCountsBadge(bucketCounts)
                } else if let agentSummary, agentSummary.hasRunning {
                    workspaceAgentCountBadge(agentSummary)
                }

                if optionKeyPressed, let shortcutLabel {
                    SidebarShortcutBadge(label: shortcutLabel, highlighted: true)
                }
            }

            if let selectionSubtitle {
                Text(selectionSubtitle)
                    .font(ToastyTheme.fontWorkspaceSubtitle)
                    .foregroundStyle(isSelected ? ToastyTheme.inactiveText : ToastyTheme.inactiveWorkspaceSubtitleText)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func workspaceNewBadge() -> some View {
        Text(SidebarSessionPresentation.workspaceNewBadgeLabel)
            .font(ToastyTheme.fontWorkspaceNewBadge)
            .foregroundStyle(ToastyTheme.workspaceNewBadgeText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                ToastyTheme.workspaceNewBadgeBackground,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(ToastyTheme.workspaceNewBadgeBorder, lineWidth: 1)
            }
            .fixedSize()
            .accessibilityIdentifier("sidebar.workspace.newBadge")
    }

    private enum TerminalStatusRow: Identifiable {
        case session(WorkspaceSessionStatus)
        case program(SidebarProgramStatusRow)
        var panelID: UUID {
            switch self { case .session(let row): row.panelID; case .program(let row): row.panelID }
        }
        var id: String {
            switch self { case .session(let row): row.sessionID; case .program(let row): "program-" + row.id.uuidString }
        }
    }

    private func terminalStatusRows(_ sessions: [WorkspaceSessionStatus], workspace: WorkspaceState) -> [TerminalStatusRow] {
        let programs = sessionRuntimeStore.programStatusRows(in: workspace)
        let programPanelIDs = Set(programs.map(\.panelID))
        let rows = sessions.filter { !programPanelIDs.contains($0.panelID) }.map(TerminalStatusRow.session)
            + programs.map(TerminalStatusRow.program)
        let order = workspace.sidebarSessionPanelOrder
        return rows.enumerated().sorted {
            let left = order.firstIndex(of: $0.element.panelID) ?? Int.max
            let right = order.firstIndex(of: $1.element.panelID) ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    private func programStatusContent(_ row: SidebarProgramStatusRow, workspace: WorkspaceState) -> some View {
        SidebarHoverRegion(id: row.panelID, selection: hoverState.panel) { isHovered in
            Button {
                focusSessionPanel(workspaceID: workspace.id, panelID: row.panelID)
            } label: {
                sessionStatusLabel(
                    status: row.status, projection: .none, turnStartedAt: nil,
                    marker: row.isAgent ? nil : .program,
                    badgeLabel: row.badge, progress: row.presentation.record.progress,
                    title: row.title, summary: row.summary, isLaterFlagged: false,
                    showsUnreadSessionAccent: row.presentation.record.state == .done,
                    isActivePanel: workspace.focusedPanelID == row.panelID,
                    isHovered: isHovered, isFlashing: false,
                    childCount: 0, childRowsExpanded: false, collapsedChildNeedsAttention: false,
                    parentSessionName: nil, onToggleChildRows: {}
                )
            }
            .buttonStyle(.plain)
            .onHover { hoverState.panel.value = $0 ? row.panelID : nil }
            .help("Terminal: \(row.terminalLabel)")
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityIdentifier("sidebar.programStatus.\(row.panelID.uuidString)")
            .background {
                SidebarSemanticTextBridge(text: row.accessibilityLabel)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func sessionStatusesContent(
        _ workspaceSessionStatuses: [WorkspaceSessionStatus],
        workspace: WorkspaceState,
        subspaceRows: [SidebarSubspacePresentation.Row] = []
    ) -> some View {
        let otherCardSpawns = otherCardSubspaceSpawns(
            cardWorkspaceID: workspace.id,
            sessionStatuses: workspaceSessionStatuses
        )
        VStack(alignment: .leading, spacing: Self.sessionRowSpacing) {
            ForEach(terminalStatusRows(workspaceSessionStatuses, workspace: workspace)) { row in
                terminalStatusRowView(row, workspace: workspace, subspaceRows: subspaceRows, otherCardSpawns: otherCardSpawns)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Self.sessionStatusesTopSpacing)
    }

    /// One session or program row in a project card.
    @ViewBuilder
    private func terminalStatusRowView(
        _ row: TerminalStatusRow,
        workspace: WorkspaceState,
        subspaceRows: [SidebarSubspacePresentation.Row],
        otherCardSpawns: [String: OtherCardSubspaceSpawn]
    ) -> some View {
        switch row {
        case .program(let program):
            programStatusContent(program, workspace: workspace)
        case .session(let workspaceSessionStatus):
            let sessionID = workspaceSessionStatus.sessionID
            let ownChip = SidebarSubspacePresentation.spawnerChip(
                sessionID: sessionID,
                rows: subspaceRows,
                activeFilterSessionID: subspaceFilterSessionIDByParentID[workspace.id]
            )
            // The card's own group wins; a session that nested its
            // subspaces only under other cards points at that card's group.
            let otherCardSpawn = ownChip == nil ? otherCardSpawns[sessionID] : nil
            let hiddenChildWorkspaceIDs = childWorkspaceIDsShownElsewhere(
                sessionID: sessionID, subspaceRows: subspaceRows, otherCardSpawns: otherCardSpawns
            )
            SidebarHoverRegion(id: workspaceSessionStatus.panelID, selection: hoverState.panel) { isHovered in
                sessionStatusContent(
                    hidingSubspaceChildren(workspaceSessionStatus, subspaceIDs: hiddenChildWorkspaceIDs),
                    workspace: workspace,
                    isHovered: isHovered,
                    spawnerChip: ownChip ?? otherCardSpawn.flatMap { spawn in
                        SidebarSubspacePresentation.spawnerChip(
                            sessionID: sessionID,
                            rows: spawn.spawnedRows,
                            activeFilterSessionID: subspaceFilterSessionIDByParentID[spawn.parentWorkspaceID],
                            targetWorkspaceTitle: spawn.parentWorkspaceTitle
                        )
                    },
                    spawnerChipParentWorkspaceID: otherCardSpawn?.parentWorkspaceID ?? workspace.id
                )
            }
        }
    }

    /// The workspaces whose sessions a session row leaves out of its
    /// children, because a task space row shows them: the card's task
    /// spaces, and, for a session that started task spaces only under another
    /// card, that card's ones.
    private func childWorkspaceIDsShownElsewhere(
        sessionID: String,
        subspaceRows: [SidebarSubspacePresentation.Row],
        otherCardSpawns: [String: OtherCardSubspaceSpawn]
    ) -> Set<UUID> {
        let startedHere = subspaceRows.contains { $0.spawningSessionID == sessionID }
        let elsewhere = startedHere ? nil : otherCardSpawns[sessionID]
        return Set(subspaceRows.map(\.id)).union(elsewhere?.spawnedRows.map(\.id) ?? [])
    }

    private func selectionSubtitle(for workspace: WorkspaceState) -> String? {
        let paneCount = workspace.layoutTree.allSlotInfos.count
        return workspaceSubtitle(paneCount: paneCount)
    }

    @ViewBuilder
    private func sessionStatusContent(
        _ workspaceSessionStatus: WorkspaceSessionStatus,
        workspace: WorkspaceState,
        isHovered: Bool,
        spawnerChip: SidebarSubspacePresentation.SpawnerChip? = nil,
        spawnerChipParentWorkspaceID: UUID
    ) -> some View {
        let sessionRowID = SidebarSessionPresentation.SidebarSessionRowID(
            workspaceID: workspace.id,
            sessionID: workspaceSessionStatus.sessionID,
            panelID: workspaceSessionStatus.panelID
        )
        let status = workspaceSessionStatus.status
        let isLaterFlagged = sessionRuntimeStore.isLaterFlagged(sessionID: workspaceSessionStatus.sessionID)
        let showsUnreadSessionAccent = showsUnreadSessionAccent(
            for: workspaceSessionStatus.panelID,
            in: workspace
        )
        let chipKind = SidebarSessionPresentation.sessionStatusChipKind(
            for: status,
            showsUnreadSessionAccent: showsUnreadSessionAccent
        )
        let scopeHelpText = sessionWorkspaceScopeHelpText(
            for: workspaceSessionStatus,
            fallbackWorkspace: workspace
        )
        let childRowsExpanded = SidebarSessionPresentation.sessionChildRowsExpanded(
            sessionID: workspaceSessionStatus.sessionID,
            expandedSessionChildrenBySessionID: expandedSessionChildrenBySessionID
        )
        let childRowsNeedAttention = SidebarSessionPresentation.sessionChildRowsNeedAttention(
            workspaceSessionStatus.children
        )
        let collapsedChildNeedsAttention = childRowsNeedAttention && childRowsExpanded == false
        let launchParent = parentSession(for: workspaceSessionStatus)
        let parentSessionName = launchParent?.displayTitleOverride
            ?? launchParent?.providerSessionName
            ?? launchParent?.agent.displayName
        let parentTagName = launchParent?.workspaceID == workspace.id ? nil : parentSessionName
        let customTabTitle = SidebarSessionPresentation.sessionCustomTabTitle(
            for: workspaceSessionStatus,
            in: store.state.workspacesByID[workspaceSessionStatus.workspaceID]
        )
        let waitingSummary = SidebarSessionPresentation.sessionWaitingSummary(for: workspaceSessionStatus)
        // Only the card's inputs are gathered here. Building the model itself
        // standardizes a filesystem path and formats a relative date, which is
        // main-thread work this row does not need until the card is shown —
        // see docs/agents/menu-performance.md.
        let hoverTipRefreshKey = SessionRowHoverTipRefreshKey(
            statusKind: status.kind,
            statusDetail: status.detail,
            projection: SidebarSessionPresentation.sessionStatusProjectionLogValue(
                workspaceSessionStatus.projection
            ),
            cwd: workspaceSessionStatus.cwd,
            updatedAt: workspaceSessionStatus.updatedAt,
            turnStartedAt: workspaceSessionStatus.turnStartedAt,
            lastTurnDuration: workspaceSessionStatus.lastTurnDuration,
            childCount: workspaceSessionStatus.children.count,
            waitingSummary: waitingSummary,
            customTabTitle: customTabTitle,
            parentSessionName: parentSessionName,
            isLaterFlagged: isLaterFlagged,
            effectiveScopedWorkspaceIDs: workspaceSessionStatus.effectiveScopedWorkspaceIDs,
            sessionName: workspaceSessionStatus.sessionName
        )
        let rowTitle = SidebarSessionPresentation.sessionRowTitle(
            sessionName: workspaceSessionStatus.sessionName,
            agentFallbackName: workspaceSessionStatus.agent.displayName
        )
        let rowSummary = normalizedSessionDetail(status.detail)
        // Rows no longer show the scope tag or the working directory; the
        // accessibility label keeps both so VoiceOver loses nothing.
        let accessibilityLabel = SidebarSessionPresentation.sessionAccessibilityLabel(
            agentName: workspaceSessionStatus.displayTitle,
            chipKind: chipKind,
            projection: workspaceSessionStatus.projection,
            waitingSummary: waitingSummary,
            childCount: workspaceSessionStatus.children.count,
            detailText: normalizedSessionDetail(status.detail),
            cwd: SidebarSessionPresentation.abbreviatedPathLabel(workspaceSessionStatus.cwd),
            isLaterFlagged: isLaterFlagged,
            workspaceScopeHelpText: scopeHelpText,
            customTabTitle: customTabTitle,
            agentLabel: SidebarSessionPresentation.sessionAgentLabel(for: workspaceSessionStatus.agent)
        )
        let canFocusPanel = SidebarSessionPresentation.canFocusSessionPanel(
            workspaceSessionStatus.panelID,
            in: workspace
        )
        let selectedWorkspaceID = store.selectedWorkspaceID(in: windowID)
        let selectedPanelID = store.selectedWorkspace(in: windowID)?.focusedPanelID
        let isActivePanel = selectedWorkspaceID == workspace.id
            && selectedPanelID == workspaceSessionStatus.panelID
        let isFlashing = flashingSessionPanelID == workspaceSessionStatus.panelID
        let rowDiagnosticState = SidebarSessionRowDiagnosticState(
            windowID: windowID,
            workspaceID: workspace.id,
            sessionID: workspaceSessionStatus.sessionID,
            panelID: workspaceSessionStatus.panelID,
            agent: workspaceSessionStatus.agent,
            statusKind: status.kind,
            chipKind: chipKind,
            projection: workspaceSessionStatus.projection,
            railState: SidebarSessionPresentation.sessionRailState(
                for: status.kind,
                showsUnreadSessionAccent: showsUnreadSessionAccent
            ),
            showsUnreadSessionAccent: showsUnreadSessionAccent,
            canFocusPanel: canFocusPanel,
            isActivePanel: isActivePanel,
            isLaterFlagged: isLaterFlagged,
            isFlashing: isFlashing,
            selectedWorkspaceID: selectedWorkspaceID,
            selectedPanelID: selectedPanelID,
            childRowCount: workspaceSessionStatus.children.count,
            collapsedChildNeedsAttention: collapsedChildNeedsAttention
        )

        let row = sessionStatusLabel(
            status: status,
            projection: workspaceSessionStatus.projection,
            turnStartedAt: workspaceSessionStatus.turnStartedAt,
            marker: workspaceSessionStatus.agent == .processWatch ? .processWatch : nil,
            title: rowTitle,
            summary: rowSummary,
            waitingSummary: waitingSummary,
            isLaterFlagged: isLaterFlagged,
            showsUnreadSessionAccent: showsUnreadSessionAccent,
            isActivePanel: isActivePanel,
            isHovered: isHovered,
            isFlashing: isFlashing,
            childCount: workspaceSessionStatus.children.count,
            childRowsExpanded: childRowsExpanded,
            collapsedChildNeedsAttention: collapsedChildNeedsAttention,
            parentSessionName: parentTagName,
            spawnerChip: spawnerChip,
            onToggleChildRows: {
                toggleSessionChildRows(sessionID: workspaceSessionStatus.sessionID)
            },
            onToggleSpawnerFilter: {
                toggleSubspaceFilter(
                    parentWorkspaceID: spawnerChipParentWorkspaceID,
                    spawningSessionID: workspaceSessionStatus.sessionID,
                    fromCardWorkspaceID: workspace.id
                )
            },
            onHoverSpawnerChip: { isHovering in
                if isHovering {
                    hoveredSpawnerSessionID = workspaceSessionStatus.sessionID
                } else if hoveredSpawnerSessionID == workspaceSessionStatus.sessionID {
                    hoveredSpawnerSessionID = nil
                }
            }
        )

        VStack(alignment: .leading, spacing: 0) {
            sessionParentRowAccessibilityAction(
                Group {
                    if canFocusPanel {
                        Button {
                            focusSessionPanel(
                                workspaceID: workspace.id,
                                panelID: workspaceSessionStatus.panelID
                            )
                        } label: {
                            row
                        }
                        .buttonStyle(.plain)
                    } else {
                        row
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityIdentifier("sidebar.workspace.session.\(workspaceSessionStatus.sessionID)")
                .hoverTip(
                    id: sessionRowID,
                    refreshID: hoverTipRefreshKey,
                    placement: .trailing(gap: Self.hoverTipTrailingGap),
                    isHovering: isHovered
                ) {
                    SessionRowHoverTipCard(
                        model: sessionRowHoverTipModel(
                            workspaceSessionStatus,
                            workspace: workspace,
                            customTabTitle: customTabTitle,
                            parentSessionName: parentSessionName,
                            isLaterFlagged: isLaterFlagged
                        )
                    )
                },
                childCount: workspaceSessionStatus.children.count,
                childRowsExpanded: childRowsExpanded,
                action: {
                    toggleSessionChildRows(sessionID: workspaceSessionStatus.sessionID)
                },
                spawnerChip: spawnerChip,
                spawnerFilterAction: {
                    toggleSubspaceFilter(
                        parentWorkspaceID: spawnerChipParentWorkspaceID,
                        spawningSessionID: workspaceSessionStatus.sessionID,
                        fromCardWorkspaceID: workspace.id
                    )
                }
            )
            .overlayPreferenceValue(SidebarSessionDisclosureAnchorKey.self) { anchors in
                GeometryReader { geometry in
                    sessionPointerRegion(
                        rowID: sessionRowID,
                        excludedRects: anchors.map { geometry[$0] }
                    )
                }
            }
            .background(sessionRowFrameMeasurement(rowID: sessionRowID))

            if workspaceSessionStatus.children.isEmpty == false && childRowsExpanded {
                sessionChildRowsContainer(
                    workspaceSessionStatus.children,
                    parentWorkspaceID: workspace.id,
                    parentPanelID: workspaceSessionStatus.panelID
                )
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: SidebarSessionGroupFramePreferenceKey.self,
                    value: [sessionRowID: geometry.frame(in: .named(SidebarWorkspaceViewportCoordinateSpace.name))]
                )
            }
        }
        .opacity(activeSessionDrag?.rowID == sessionRowID ? 0.55 : 1)
        .overlay(alignment: activeSessionDrag?.target?.placeAfter == true ? .bottom : .top) {
            if activeSessionDrag?.rowID.workspaceID == workspace.id,
               activeSessionDrag?.target?.panelID == workspaceSessionStatus.panelID {
                Rectangle()
                    .fill(ToastyTheme.accent)
                    .frame(height: 2)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            autoExpandSessionChildRowsIfNeeded(
                sessionID: workspaceSessionStatus.sessionID,
                childrenNeedAttention: childRowsNeedAttention
            )
        }
        .onChange(of: childRowsNeedAttention) { _, needsAttention in
            autoExpandSessionChildRowsIfNeeded(
                sessionID: workspaceSessionStatus.sessionID,
                childrenNeedAttention: needsAttention
            )
        }
        .onChange(of: workspaceSessionStatus.children) { _, children in
            guard children.isEmpty else { return }
            expandedSessionChildrenBySessionID.removeValue(forKey: workspaceSessionStatus.sessionID)
        }
        .id(sessionRowID)
        .contextMenu {
            if workspaceSessionStatus.agent != .processWatch {
                Button(
                    ToasttyKeyboardShortcuts.toggleLaterFlag.menuTitle(
                        SidebarSessionPresentation.laterFlagActionTitle(isFlaggedForLater: isLaterFlagged)
                    )
                ) {
                    sessionRuntimeStore.setLaterFlag(
                        sessionID: workspaceSessionStatus.sessionID,
                        isFlagged: !isLaterFlagged
                    )
                }
                Divider()
                Button("Close Session") {
                    requestSessionClose(workspaceSessionStatus.panelID, rowTitle)
                }
            }
        }
        // SwiftUI context menus can collapse the hosted AppKit text tree into
        // drawing-only layers. Keep a zero-size hidden text bridge so row text
        // remains discoverable to host-based tests and AppKit inspectors.
        .background {
            SidebarSemanticTextBridge(text: accessibilityLabel)
                .frame(width: 0, height: 0)
        }
        .onAppear {
            logSidebarSessionRowDiagnosticIfChanged(rowDiagnosticState, reason: "appear")
        }
        .onChange(of: rowDiagnosticState) { _, nextState in
            logSidebarSessionRowDiagnosticIfChanged(nextState, reason: "changed")
        }
    }

    @ViewBuilder
    private func sessionParentRowAccessibilityAction<Content: View>(
        _ content: Content,
        childCount: Int,
        childRowsExpanded: Bool,
        action: @escaping () -> Void,
        spawnerChip: SidebarSubspacePresentation.SpawnerChip? = nil,
        spawnerFilterAction: @escaping () -> Void = {}
    ) -> some View {
        // The row is one accessibility element, so its interactive chips are
        // exposed as named actions rather than as child buttons.
        let withChildAction = Group {
            if childCount > 0 {
                content
                    .accessibilityAction(
                        named: Text(childRowsExpanded ? "Collapse sub-agents" : "Expand sub-agents"),
                        action
                    )
            } else {
                content
            }
        }
        if let spawnerChip {
            withChildAction
                .accessibilityAction(
                    named: Text(SidebarSubspacePresentation.spawnerFilterActionTitle(spawnerChip)),
                    spawnerFilterAction
                )
        } else {
            withChildAction
        }
    }

    private func sessionStatusLabel(
        status: SessionStatus,
        projection: SessionStatusProjection,
        turnStartedAt: Date?,
        marker: SessionRailMarker?,
        badgeLabel: String? = nil,
        progress: Int? = nil,
        title: String,
        summary: String?,
        waitingSummary: SessionWaitingSummary? = nil,
        isLaterFlagged: Bool,
        showsUnreadSessionAccent: Bool,
        isActivePanel: Bool,
        isHovered: Bool,
        isFlashing: Bool,
        childCount: Int,
        childRowsExpanded: Bool,
        collapsedChildNeedsAttention: Bool,
        parentSessionName: String?,
        spawnerChip: SidebarSubspacePresentation.SpawnerChip? = nil,
        onToggleChildRows: @escaping () -> Void,
        onToggleSpawnerFilter: @escaping () -> Void = {},
        onHoverSpawnerChip: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        let railState = SidebarSessionPresentation.sessionRailState(
            for: status.kind,
            showsUnreadSessionAccent: showsUnreadSessionAccent
        )
        // Ready (unread), approval, and error: the states that want the user.
        let attentionKind = SidebarSessionPresentation.sessionStatusChipKind(
            for: status,
            showsUnreadSessionAccent: showsUnreadSessionAccent
        )
        let isEmphasized = attentionKind != nil
        let isItalic = SidebarSessionPresentation.sessionTextUsesItalic(for: status.kind, projection: projection)
        let isResuming = projection == .resuming
        let flashOpacity = isFlashing ? flashingSessionOverlayOpacity : 0

        let railMarker: SessionRailMarker? = if isLaterFlagged {
            .laterFlag
        } else {
            marker
        }
        let accessories = SessionRowAccessoryModel(
            // Ready gets the tint and the heavy name but no badge; approval
            // and error keep a word so the state does not rest on color.
            badgeKind: attentionKind == .ready ? nil : attentionKind,
            waitingChipLabel: SidebarSessionPresentation.sessionStatusProjectionChipLabel(for: projection),
            turnStartedAt: turnStartedAt,
            parentTagLabel: parentSessionName.map(
                SidebarSessionPresentation.parentSessionTagLabel(parentName:)
            ),
            childCount: childCount,
            childRowsExpanded: childRowsExpanded,
            collapsedChildNeedsAttention: collapsedChildNeedsAttention,
            badgeLabel: badgeLabel,
            progress: progress,
            spawnerChip: spawnerChip,
            onToggleSpawnerFilter: onToggleSpawnerFilter,
            onHoverSpawnerChip: onHoverSpawnerChip
        )

        return HStack(alignment: .top, spacing: Self.sessionStatusRailGap) {
            sessionStatusRail(railState, marker: railMarker)

            VStack(alignment: .leading, spacing: 1) {
                sessionRowStateLine(accessories) {
                    Self.styledSessionNameText(title, isEmphasized: isEmphasized, isItalic: isItalic)
                        .foregroundStyle(ToastyTheme.sidebarSessionAgentText)
                }
                // Reserved even without a summary yet, so every row keeps one
                // height and the list does not reflow as summaries or names
                // arrive.
                sessionRowSummaryLine(accessories, onToggleChildRows: onToggleChildRows) {
                    if let waitingSummary {
                        sessionWaitingSummaryLabel(waitingSummary)
                    } else {
                        sessionSummaryLabel(summary ?? " ", isResuming: isResuming, isItalic: isItalic)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .backgroundPreferenceValue(SidebarSessionRowCompactHelpTextPreferenceKey.self) { compactHelpText in
            // When the state line dropped the waiting chip, the whole row's
            // tooltip carries it.
            if let compactHelpText {
                SidebarTooltipBridge(text: compactHelpText)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(
                    sessionStatusBackgroundColor(
                        attentionKind: attentionKind,
                        isActivePanel: isActivePanel,
                        isHovered: isHovered
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .fill(ToastyTheme.accent.opacity(0.42 * flashOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isHovered ? ToastyTheme.sidebarSessionHoverBorder : Color.clear, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(ToastyTheme.accent.opacity(flashOpacity), lineWidth: 1.75)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5))
    }

    /// What a session row shows besides its name and summary: state on the
    /// first line, the parent tag and controls on the second.
    private struct SessionRowAccessoryModel {
        let badgeKind: SessionStatusKind?
        let waitingChipLabel: String?
        let turnStartedAt: Date?
        let parentTagLabel: String?
        let childCount: Int
        let childRowsExpanded: Bool
        let collapsedChildNeedsAttention: Bool
        var badgeLabel: String? = nil
        var progress: Int? = nil
        var spawnerChip: SidebarSubspacePresentation.SpawnerChip? = nil
        var onToggleSpawnerFilter: () -> Void = {}
        var onHoverSpawnerChip: (Bool) -> Void = { _ in }
    }

    /// A standing mark on the session, as opposed to its current status. The
    /// two are mutually exclusive: a watched process cannot be flagged (see
    /// `SessionRegistry.setLaterFlag`).
    private enum SessionRailMarker: Equatable {
        case laterFlag
        case processWatch
        case program
    }

    /// Reserved left gutter, and the column for what is true about a session:
    /// current status in the top slot, a standing mark under it. Both slots
    /// keep their size when empty so row text lines up down the list.
    private func sessionStatusRail(
        _ state: SidebarSessionPresentation.SessionRailState,
        marker: SessionRailMarker?
    ) -> some View {
        VStack(spacing: Self.sessionStatusRailSlotSpacing) {
            sessionStatusRailStatusSlot(state)

            if let marker {
                sessionStatusRailMarkerSlot(marker)
            }
        }
        .frame(width: Self.sessionStatusRailWidth)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func sessionStatusRailStatusSlot(
        _ state: SidebarSessionPresentation.SessionRailState
    ) -> some View {
        SessionRailStatusIcon(state: state)
            .frame(width: Self.sessionStatusRailWidth, height: Self.sessionRowLineMinHeight)
    }

    private func sessionStatusRailMarkerSlot(_ marker: SessionRailMarker) -> some View {
        Group {
            switch marker {
            case .laterFlag:
                Image(systemName: "flag.fill")
                    .font(.system(size: Self.sessionRailFlagFontSize, weight: .semibold))
                    .foregroundStyle(ToastyTheme.sidebarSessionLaterFlag)
            case .program:
                Image(systemName: "terminal")
                    .font(.system(size: Self.sessionRailWatchFontSize, weight: .medium))
                    .foregroundStyle(ToastyTheme.sidebarChildContextText)
            case .processWatch:
                Image(systemName: "bell.fill")
                    .font(.system(size: Self.sessionRailWatchFontSize, weight: .semibold))
                    .foregroundStyle(ToastyTheme.sidebarSessionWatchIcon)
            }
        }
        .frame(width: Self.sessionStatusRailWidth, height: Self.sessionStatusRailMarkerSlotHeight)
    }

    /// The name, or the agent's name standing in for it, then the row's state:
    /// the approval or error badge, the waiting chip, and elapsed time.
    private func sessionRowStateLine<Title: View>(
        _ accessories: SessionRowAccessoryModel,
        @ViewBuilder title: () -> Title
    ) -> some View {
        let title = title()
        // A narrow sidebar drops the waiting chip before the title would get
        // shorter than its reserved width; the row tooltip then carries it.
        return ViewThatFits(in: .horizontal) {
            if accessories.waitingChipLabel != nil {
                sessionRowStateLineContent(title, accessories, showsWaitingChip: true)
            }
            sessionRowStateLineContent(title, accessories, showsWaitingChip: false)
        }
        .frame(minHeight: Self.sessionRowLineMinHeight)
    }

    private func sessionRowStateLineContent<Title: View>(
        _ title: Title,
        _ accessories: SessionRowAccessoryModel,
        showsWaitingChip: Bool
    ) -> some View {
        HStack(spacing: 6) {
            // The ideal width is what the fit check above reserves for the
            // title. In layout it has no floor and takes whatever the state
            // leaves, so the badge and elapsed time always fit.
            title
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    minWidth: 0,
                    idealWidth: Self.sessionRowTitleReservedWidth,
                    maxWidth: .infinity,
                    alignment: .leading
                )

            sessionRowStateAccessories(accessories, showsWaitingChip: showsWaitingChip)
                .layoutPriority(1)
        }
    }

    private func sessionRowStateAccessories(
        _ model: SessionRowAccessoryModel,
        showsWaitingChip: Bool
    ) -> some View {
        HStack(spacing: 6) {
            if let badgeKind = model.badgeKind {
                sessionStatusChip(kind: badgeKind, label: model.badgeLabel)
            }
            if let progress = model.progress {
                Text("\(progress)%")
                    .font(ToastyTheme.fontWorkspaceSessionElapsed)
                    .foregroundStyle(ToastyTheme.sessionProgressText)
                    .monospacedDigit()
                    .fixedSize()
            }

            if model.waitingChipLabel != nil, showsWaitingChip {
                Self.sessionWaitingChip()
            }

            if let turnStartedAt = model.turnStartedAt {
                // The tick lives on this leaf and only exists while a row is
                // working, so idle rows carry no timer and a counting row
                // invalidates one Text rather than the sidebar.
                TimelineView(.periodic(from: turnStartedAt, by: 1)) { timeline in
                    Text(SidebarSessionPresentation.elapsedChildActivityText(
                        startedAt: turnStartedAt,
                        now: timeline.date
                    ))
                        .font(ToastyTheme.fontWorkspaceSessionElapsed)
                        .foregroundStyle(ToastyTheme.sidebarChildContextText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        // Only a row with a waiting chip gives `ViewThatFits`
                        // two candidates to choose between; without one, the
                        // floor would only take width from the title.
                        .frame(
                            minWidth: model.waitingChipLabel == nil ? nil : Self.sessionElapsedMinimumWidth,
                            alignment: .trailing
                        )
                }
                .accessibilityHidden(true)
            }
        }
        .preference(
            key: SidebarSessionRowCompactHelpTextPreferenceKey.self,
            value: SidebarSessionPresentation.sessionRowCompactHelpText(
                droppedWaitingChipLabel: showsWaitingChip ? nil : model.waitingChipLabel
            )
        )
    }

    /// The summary, then the parent tag and the subspace and sub-agent
    /// controls.
    private func sessionRowSummaryLine<Summary: View>(
        _ model: SessionRowAccessoryModel,
        onToggleChildRows: @escaping () -> Void,
        @ViewBuilder summary: () -> Summary
    ) -> some View {
        HStack(spacing: 6) {
            summary()
                .frame(maxWidth: .infinity, alignment: .leading)

            if let parentTagLabel = model.parentTagLabel {
                // Capped so the summary keeps most of the line; the hover
                // card names the parent in full.
                SidebarCappedIntrinsicWidthLayout(maximumWidth: Self.sessionParentTagMaximumWidth) {
                    sessionParentTag(label: parentTagLabel)
                }
            }

            if let spawnerChip = model.spawnerChip {
                spawnerSubspacesChip(
                    spawnerChip,
                    onToggle: model.onToggleSpawnerFilter,
                    onHover: model.onHoverSpawnerChip
                )
                .layoutPriority(1)
                .anchorPreference(key: SidebarSessionDisclosureAnchorKey.self, value: .bounds) { [$0] }
            }

            if model.childCount > 0 {
                sessionChildrenDisclosurePill(
                    count: model.childCount,
                    isExpanded: model.childRowsExpanded,
                    showsAttention: model.collapsedChildNeedsAttention,
                    action: onToggleChildRows
                )
                .layoutPriority(1)
                .anchorPreference(key: SidebarSessionDisclosureAnchorKey.self, value: .bounds) { [$0] }
            }
        }
        .frame(minHeight: Self.sessionRowSecondaryLineMinHeight)
    }

    /// Built only when a card is about to be shown. Everything expensive about
    /// the card — path standardizing, relative-date formatting, resolving the
    /// scoped workspace names — happens here rather than per row per publish.
    private func sessionRowHoverTipModel(
        _ workspaceSessionStatus: WorkspaceSessionStatus,
        workspace: WorkspaceState,
        customTabTitle: String?,
        parentSessionName: String?,
        isLaterFlagged: Bool
    ) -> SessionRowHoverTipModel {
        SidebarSessionPresentation.sessionRowHoverTipModel(
            session: workspaceSessionStatus,
            customTabTitle: customTabTitle,
            parentSessionName: parentSessionName,
            workspaceScopeNames: workspaceSessionStatus.isWorkspaceScoped
                ? workspaceScopeWorkspaceNames(
                    for: workspaceSessionStatus.effectiveScopedWorkspaceIDs ?? [],
                    fallbackWorkspace: workspace
                )
                : [],
            isLaterFlagged: isLaterFlagged,
            now: Date()
        )
    }

    private func sidebarSessionStatuses(for workspaceID: UUID) -> [WorkspaceSessionStatus] {
        SidebarSessionPresentation.orderedStatuses(
            sessionRuntimeStore.workspaceStatuses(for: workspaceID),
            panelOrder: store.state.workspacesByID[workspaceID]?.sidebarSessionPanelOrder ?? []
        )
    }

    private func sessionPointerRegion(
        rowID: SidebarSessionPresentation.SidebarSessionRowID,
        excludedRects: [CGRect]
    ) -> some View {
        PointerInteractionRegion(
            name: "session-sidebar-row",
            metadata: [
                "workspaceID": rowID.workspaceID.uuidString,
                "sessionID": rowID.sessionID,
                "panelID": rowID.panelID.uuidString,
                "windowID": windowID.uuidString,
            ],
            excludedRects: excludedRects,
            supportsDragScrolling: true,
            onBegan: { _ in
                cancelWorkspaceDrag()
                activeSessionDrag = nil
                sessionPointerRowID = rowID
            },
            onChanged: { value in
                updateSessionDrag(rowID: rowID, value: value)
            },
            onEnded: { value in
                finishSessionInteraction(rowID: rowID, value: value)
            },
            onCancelled: {
                if sessionPointerRowID == rowID {
                    cancelSessionInteraction()
                }
            },
            onHoverChanged: { isHovering in
                updateSessionRowHover(rowID: rowID, isHovering: isHovering)
            }
        )
    }

    /// This region overlays the whole row and claims hit-testing, so a
    /// SwiftUI `.onHover` beneath it never fires. It is the row's only hover
    /// signal: the hover background and the hover card both read from here.
    private func updateSessionRowHover(
        rowID: SidebarSessionPresentation.SidebarSessionRowID,
        isHovering: Bool
    ) {
        let panelID = rowID.panelID
        guard activeWorkspaceDrag == nil, activeSessionDrag == nil else { return }
        if isHovering {
            hoverState.panel.value = panelID
        } else if hoverState.panel.value == panelID {
            hoverState.panel.value = nil
        }
    }

    private func sessionDropTarget(
        rowID: SidebarSessionPresentation.SidebarSessionRowID,
        value: PointerInteractionValue
    ) -> SidebarSessionPresentation.SessionDropTarget? {
        guard let parentFrame = scrollGeometry.sessionRowFrames[rowID] else { return nil }
        let frames = scrollGeometry.sessionGroupFrames
        // Top to bottom as drawn: buckets list a card's sessions apart from
        // the card's panel order.
        let rows = currentSidebarSessionRowIDs()
            .filter { $0.workspaceID == rowID.workspaceID }
            .enumerated()
            .sorted { lhs, rhs in
                let left = frames[lhs.element]?.minY ?? .infinity, right = frames[rhs.element]?.minY ?? .infinity
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
        return SidebarSessionPresentation.sessionDropTarget(
            orderedRowIDs: rows,
            frames: frames,
            source: rowID,
            pointer: CGPoint(x: parentFrame.minX + value.location.x, y: parentFrame.minY + value.location.y),
            viewportHeight: scrollGeometry.viewportHeight
        )
    }

    private func updateSessionDrag(
        rowID: SidebarSessionPresentation.SidebarSessionRowID,
        value: PointerInteractionValue
    ) {
        guard sessionPointerRowID == rowID else { return }
        guard currentSidebarSessionRowIDs().contains(rowID) else {
            cancelSessionInteraction()
            return
        }
        guard activeSessionDrag != nil || Self.workspaceDragActivationExceeded(translation: value.translation) else {
            return
        }
        hoverState.panel.value = nil
        activeSessionDrag = SessionDragState(rowID: rowID, target: sessionDropTarget(rowID: rowID, value: value))
    }

    private func finishSessionInteraction(
        rowID: SidebarSessionPresentation.SidebarSessionRowID,
        value: PointerInteractionValue
    ) {
        guard sessionPointerRowID == rowID else { return }
        // Re-evaluate using live identities and geometry, including any scrolling
        // or session updates that happened after the last mouse-drag event.
        updateSessionDrag(rowID: rowID, value: value)
        let drag = activeSessionDrag
        cancelSessionInteraction()
        guard currentSidebarSessionRowIDs().contains(rowID) else { return }
        if let drag {
            guard let target = drag.target else { return }
            let visiblePanelIDs = sidebarSessionStatuses(for: rowID.workspaceID).map(\.panelID)
            var reordered = visiblePanelIDs.filter { $0 != rowID.panelID }
            guard let targetIndex = reordered.firstIndex(of: target.panelID) else { return }
            reordered.insert(rowID.panelID, at: targetIndex + (target.placeAfter ? 1 : 0))
            guard reordered != visiblePanelIDs else { return }
            store.send(.moveSidebarSession(
                workspaceID: rowID.workspaceID,
                panelID: rowID.panelID,
                targetPanelID: target.panelID,
                placeAfter: target.placeAfter,
                visiblePanelIDs: visiblePanelIDs
            ))
        } else if Self.pointerMovementWithinTapTolerance(translation: value.translation),
                  let workspace = store.state.workspacesByID[rowID.workspaceID],
                  SidebarSessionPresentation.canFocusSessionPanel(rowID.panelID, in: workspace) {
            focusSessionPanel(workspaceID: rowID.workspaceID, panelID: rowID.panelID)
        }
    }

    private func cancelSessionInteraction() {
        activeSessionDrag = nil
        sessionPointerRowID = nil
    }

    private func pruneSessionDrag() {
        let currentRows = Set(currentSidebarSessionRowIDs())
        scrollGeometry.sessionGroupFrames = scrollGeometry.sessionGroupFrames.filter { currentRows.contains($0.key) }
        if let rowID = sessionPointerRowID, currentRows.contains(rowID) == false {
            cancelSessionInteraction()
        }
    }

    private func workspaceRowFrameMeasurement(workspaceID: UUID) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: WorkspaceRowFramePreferenceKey.self,
                value: [
                    workspaceID: geometry.frame(in: .named(SidebarWorkspaceListCoordinateSpace.name))
                ]
            )
        }
    }

    private func sessionRowFrameMeasurement(
        rowID: SidebarSessionPresentation.SidebarSessionRowID
    ) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: SidebarSessionRowFramePreferenceKey.self,
                value: [
                    rowID: geometry.frame(in: .named(SidebarWorkspaceViewportCoordinateSpace.name))
                ]
            )
        }
    }

    private func subspaceFrameMeasurement(id: SidebarSubspaceFrameID) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: SidebarSubspaceFramePreferenceKey.self,
                value: [id: geometry.frame(in: .named(SidebarWorkspaceViewportCoordinateSpace.name))]
            )
        }
    }

    nonisolated static func workspaceDragActivationExceeded(translation: CGSize) -> Bool {
        abs(translation.height) >= workspaceDragActivationDistance
    }

    nonisolated static func pointerMovementWithinTapTolerance(translation: CGSize) -> Bool {
        let distanceSquared = (translation.width * translation.width) + (translation.height * translation.height)
        return distanceSquared < (workspaceDragActivationDistance * workspaceDragActivationDistance)
    }

    private func updateWorkspaceDrag(
        workspaceID: UUID,
        sourceIndex: Int,
        orderedWorkspaceIDs: [UUID],
        value: PointerInteractionValue
    ) {
        let baseMetadata = workspaceDragLogMetadata(
            workspaceID: workspaceID,
            sourceIndex: sourceIndex,
            value: value
        )
        if renamingWorkspaceID != nil {
            ToasttyLog.info(
                "workspace sidebar drag ignored",
                category: .input,
                metadata: baseMetadata.merging(["reason": "renaming-workspace"], uniquingKeysWith: { _, new in new })
            )
            return
        }
        guard Self.workspaceDragActivationExceeded(translation: value.translation) else {
            ToasttyLog.info(
                "workspace sidebar drag below activation threshold",
                category: .input,
                metadata: baseMetadata
            )
            return
        }

        hoverState.workspace.value = nil
        hoverState.panel.value = nil

        var dragState = activeWorkspaceDrag
        if dragState?.workspaceID != workspaceID {
            let startPointerY = (measuredWorkspaceRowFramesByID[workspaceID]?.minY ?? 0) + value.startLocation.y
            dragState = WorkspaceDragState(
                workspaceID: workspaceID,
                sourceIndex: sourceIndex,
                startPointerY: startPointerY,
                translationHeight: value.translation.height,
                targetIndex: sourceIndex
            )
            ToasttyLog.info(
                "workspace sidebar drag activated",
                category: .input,
                metadata: baseMetadata.merging(
                    [
                        "startPointerY": "\(startPointerY)",
                        "orderedWorkspaceCount": "\(orderedWorkspaceIDs.count)",
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )
        } else {
            dragState?.translationHeight = value.translation.height
        }

        let pointerY = (dragState?.startPointerY ?? value.location.y) + value.translation.height
        let targetIndex = Self.workspaceReorderTargetIndex(
            orderedWorkspaceIDs: orderedWorkspaceIDs,
            measuredRowFramesByID: measuredWorkspaceRowFramesByID,
            draggedWorkspaceID: workspaceID,
            pointerY: pointerY
        ) ?? sourceIndex
        let previousTargetIndex = dragState?.targetIndex
        dragState?.targetIndex = targetIndex
        activeWorkspaceDrag = dragState
        if previousTargetIndex != targetIndex {
            ToasttyLog.info(
                "workspace sidebar drag target changed",
                category: .input,
                metadata: baseMetadata.merging(
                    [
                        "pointerY": "\(pointerY)",
                        "targetIndex": "\(targetIndex)",
                        "previousTargetIndex": previousTargetIndex.map(String.init) ?? "nil",
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )
        }
    }

    private func finishWorkspaceInteraction(
        workspaceID: UUID,
        workspace: WorkspaceState,
        value: PointerInteractionValue
    ) {
        if activeWorkspaceDrag?.workspaceID == workspaceID {
            ToasttyLog.info(
                "workspace sidebar drag finishing",
                category: .input,
                metadata: workspaceDragLogMetadata(workspaceID: workspaceID, sourceIndex: nil, value: value)
            )
            finishWorkspaceDrag()
            return
        }

        guard activeWorkspaceDrag == nil, activeSessionDrag == nil else { return }
        guard Self.pointerMovementWithinTapTolerance(translation: value.translation) else { return }
        ToasttyLog.info(
            "workspace sidebar pointer ended as tap",
            category: .input,
            metadata: workspaceDragLogMetadata(workspaceID: workspaceID, sourceIndex: nil, value: value)
        )
        handleWorkspaceButtonActivation(workspaceID: workspaceID, workspace: workspace)
    }

    private func finishWorkspaceDrag() {
        guard let activeWorkspaceDrag else { return }
        cancelWorkspaceDrag()

        guard activeWorkspaceDrag.targetIndex != activeWorkspaceDrag.sourceIndex else {
            ToasttyLog.info(
                "workspace sidebar drag finished without reorder",
                category: .input,
                metadata: [
                    "workspaceID": activeWorkspaceDrag.workspaceID.uuidString,
                    "sourceIndex": "\(activeWorkspaceDrag.sourceIndex)",
                    "targetIndex": "\(activeWorkspaceDrag.targetIndex)",
                    "translationHeight": "\(activeWorkspaceDrag.translationHeight)",
                ]
            )
            return
        }
        ToasttyLog.info(
            "workspace sidebar drag committing reorder",
            category: .input,
            metadata: [
                "workspaceID": activeWorkspaceDrag.workspaceID.uuidString,
                "sourceIndex": "\(activeWorkspaceDrag.sourceIndex)",
                "targetIndex": "\(activeWorkspaceDrag.targetIndex)",
                "translationHeight": "\(activeWorkspaceDrag.translationHeight)",
            ]
        )
        // Drag indexes count cards; the window order also holds subspaces.
        guard let moveIndices = Self.windowWorkspaceMoveIndices(
            draggedWorkspaceID: activeWorkspaceDrag.workspaceID,
            targetIndex: activeWorkspaceDrag.targetIndex,
            topLevelWorkspaceIDs: store.state.topLevelWorkspaceIDs(in: windowID),
            windowWorkspaceIDs: store.window(id: windowID)?.workspaceIDs ?? []
        ) else {
            return
        }
        _ = store.send(
            .moveWorkspace(
                windowID: windowID,
                fromIndex: moveIndices.fromIndex,
                toIndex: moveIndices.toIndex
            )
        )
    }

    /// Maps a drop position among the top-level cards to `moveWorkspace`
    /// indexes in the window's full order, which interleaves subspaces.
    /// `targetIndex` is the position among the cards with the dragged one
    /// removed, as `workspaceReorderTargetIndex` reports it.
    nonisolated static func windowWorkspaceMoveIndices(
        draggedWorkspaceID: UUID,
        targetIndex: Int,
        topLevelWorkspaceIDs: [UUID],
        windowWorkspaceIDs: [UUID]
    ) -> (fromIndex: Int, toIndex: Int)? {
        guard let fromIndex = windowWorkspaceIDs.firstIndex(of: draggedWorkspaceID) else { return nil }
        let remainingWindowIDs = windowWorkspaceIDs.filter { $0 != draggedWorkspaceID }
        let remainingCardIDs = topLevelWorkspaceIDs.filter { $0 != draggedWorkspaceID }
        guard targetIndex >= 0, targetIndex <= remainingCardIDs.count else { return nil }
        let toIndex: Int
        if targetIndex < remainingCardIDs.count,
           let anchorIndex = remainingWindowIDs.firstIndex(of: remainingCardIDs[targetIndex]) {
            toIndex = anchorIndex
        } else {
            toIndex = remainingWindowIDs.count
        }
        return (fromIndex, toIndex)
    }

    private func cancelWorkspaceDrag() {
        activeWorkspaceDrag = nil
    }

    private func beginWorkspaceInteraction(workspaceID: UUID) {
        cancelSessionInteraction()
        guard let activeWorkspaceDrag else { return }
        ToasttyLog.info(
            "workspace sidebar stale drag cancelled on new pointer sequence",
            category: .input,
            metadata: [
                "newWorkspaceID": workspaceID.uuidString,
                "activeWorkspaceID": activeWorkspaceDrag.workspaceID.uuidString,
                "sourceIndex": "\(activeWorkspaceDrag.sourceIndex)",
                "targetIndex": "\(activeWorkspaceDrag.targetIndex)",
                "translationHeight": "\(activeWorkspaceDrag.translationHeight)",
            ]
        )
        cancelWorkspaceDrag()
    }

    private func workspaceDragLogMetadata(
        workspaceID: UUID,
        sourceIndex: Int?,
        value: PointerInteractionValue
    ) -> [String: String] {
        var metadata: [String: String] = [
            "workspaceID": workspaceID.uuidString,
            "startLocation": DraggableInteractionLog.pointDescription(value.startLocation),
            "location": DraggableInteractionLog.pointDescription(value.location),
            "translation": DraggableInteractionLog.sizeDescription(value.translation),
        ]
        if let sourceIndex {
            metadata["sourceIndex"] = "\(sourceIndex)"
        }
        if let activeWorkspaceDrag {
            metadata["activeWorkspaceID"] = activeWorkspaceDrag.workspaceID.uuidString
            metadata["activeSourceIndex"] = "\(activeWorkspaceDrag.sourceIndex)"
            metadata["activeTargetIndex"] = "\(activeWorkspaceDrag.targetIndex)"
            metadata["activeTranslationHeight"] = "\(activeWorkspaceDrag.translationHeight)"
        }
        if let measuredFrame = measuredWorkspaceRowFramesByID[workspaceID] {
            metadata["measuredFrame"] = DraggableInteractionLog.rectDescription(measuredFrame)
        }
        return metadata
    }

    @MainActor
    private func schedulePendingSidebarSessionFlashRequestHandling() {
        DispatchQueue.main.async {
            handlePendingSidebarSessionFlashRequest()
        }
    }

    @MainActor
    private func handlePendingSidebarSessionFlashRequest() {
        guard let request = store.pendingSidebarSessionFlashRequest,
              request.windowID == windowID,
              lastHandledSidebarFlashRequestID != request.requestID else {
            return
        }

        guard let consumedRequest = store.consumePendingSidebarSessionFlashRequest(
            windowID: windowID,
            requestID: request.requestID
        ) else {
            return
        }

        lastHandledSidebarFlashRequestID = consumedRequest.requestID
        if let panelID = consumedRequest.panelID,
           sessionRuntimeStore
            .workspaceStatuses(for: consumedRequest.workspaceID)
            .contains(where: { $0.panelID == panelID }) {
            flashSidebarSelection(
                workspaceID: nil,
                panelID: panelID,
                requestID: consumedRequest.requestID
            )
        } else {
            flashSidebarSelection(
                workspaceID: consumedRequest.workspaceID,
                panelID: nil,
                requestID: consumedRequest.requestID
            )
        }
    }

    @MainActor
    private func flashSidebarSelection(
        workspaceID: UUID?,
        panelID: UUID?,
        requestID: UUID
    ) {
        activeSidebarFlashRequestID = requestID
        sidebarFlashClearWorkItem?.cancel()
        sidebarFlashResetWorkItem?.cancel()
        sidebarFlashClearWorkItem = nil
        sidebarFlashResetWorkItem = nil
        flashingWorkspaceID = workspaceID
        flashingSessionPanelID = panelID
        flashingSessionOverlayOpacity = 0

        withAnimation(.easeOut(duration: 0.08)) {
            flashingSessionOverlayOpacity = 1
        }

        let clearWorkItem = DispatchWorkItem { [requestID] in
            guard activeSidebarFlashRequestID == requestID else { return }
            sidebarFlashClearWorkItem = nil
            withAnimation(.easeOut(duration: Self.sessionFlashSettleDuration)) {
                flashingSessionOverlayOpacity = 0
            }
        }
        sidebarFlashClearWorkItem = clearWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.sessionFlashPeakDuration,
            execute: clearWorkItem
        )

        let resetWorkItem = DispatchWorkItem { [requestID] in
            guard activeSidebarFlashRequestID == requestID else { return }
            activeSidebarFlashRequestID = nil
            flashingWorkspaceID = nil
            flashingSessionPanelID = nil
            flashingSessionOverlayOpacity = 0
            sidebarFlashResetWorkItem = nil
        }
        sidebarFlashResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.sessionFlashPeakDuration + Self.sessionFlashSettleDuration,
            execute: resetWorkItem
        )
    }

    /// The focused panel's fill wins; otherwise a row that wants the user
    /// keeps its tint under the pointer, and hover adds only the outline.
    private func sessionStatusBackgroundColor(
        attentionKind: SessionStatusKind?,
        isActivePanel: Bool,
        isHovered: Bool
    ) -> Color {
        if isActivePanel {
            return isHovered ? ToastyTheme.sidebarSessionActiveHoverBackground
                : ToastyTheme.sidebarSessionActiveBackground
        }
        if let tint = attentionKind.flatMap(ToastyTheme.sidebarAttentionTint(for:)) {
            return tint
        }
        return isHovered ? ToastyTheme.sidebarSessionHoverBackground : Color.clear
    }

    private func logSidebarSessionRowDiagnosticIfChanged(
        _ nextState: SidebarSessionRowDiagnosticState,
        reason: String
    ) {
        let previousState = sidebarSessionRowDiagnosticsByPanelID[nextState.panelID]
        guard previousState != nextState else { return }

        var metadata = sidebarSessionRowDiagnosticMetadata(nextState)
        metadata["source"] = "sidebar_view"
        metadata["reason"] = reason
        metadata["previous_state"] = previousState?.displayState ?? "none"
        metadata["previous_status_kind"] = previousState?.statusKind.rawValue ?? "none"
        metadata["previous_chip_kind"] = previousState?.chipKind?.rawValue ?? "none"
        metadata["previous_projection"] = previousState.map {
            SidebarSessionPresentation.sessionStatusProjectionLogValue($0.projection)
        } ?? "none"
        metadata["previous_unread_accent"] = previousState?.showsUnreadSessionAccent == true ? "true" : "false"
        metadata["previous_active_panel"] = previousState?.isActivePanel == true ? "true" : "false"
        metadata["previous_child_row_count"] = previousState.map { String($0.childRowCount) } ?? "none"
        metadata["previous_collapsed_child_attention"] = previousState?.collapsedChildNeedsAttention == true ? "true" : "false"

        ToasttyLog.debug(
            "Sidebar session row display state changed",
            category: .state,
            metadata: metadata
        )
        sidebarSessionRowDiagnosticsByPanelID[nextState.panelID] = nextState
    }

    private func sidebarSessionRowDiagnosticMetadata(
        _ state: SidebarSessionRowDiagnosticState
    ) -> [String: String] {
        [
            "window_id": state.windowID.uuidString,
            "workspace_id": state.workspaceID.uuidString,
            "session_id": state.sessionID,
            "panel_id": state.panelID.uuidString,
            "agent": state.agent.rawValue,
            "status_kind": state.statusKind.rawValue,
            "chip_kind": state.chipKind?.rawValue ?? "none",
            "projection": SidebarSessionPresentation.sessionStatusProjectionLogValue(state.projection),
            "rail_state": SidebarSessionPresentation.sessionRailLogValue(state.railState),
            "display_state": state.displayState,
            "shows_unread_session_accent": state.showsUnreadSessionAccent ? "true" : "false",
            "can_focus_panel": state.canFocusPanel ? "true" : "false",
            "is_active_panel": state.isActivePanel ? "true" : "false",
            "is_later_flagged": state.isLaterFlagged ? "true" : "false",
            "is_flashing": state.isFlashing ? "true" : "false",
            "selected_workspace_id": state.selectedWorkspaceID?.uuidString ?? "none",
            "selected_panel_id": state.selectedPanelID?.uuidString ?? "none",
            "selected_workspace_matches": state.selectedWorkspaceID == state.workspaceID ? "true" : "false",
            "selected_panel_matches": state.selectedPanelID == state.panelID ? "true" : "false",
            "child_row_count": String(state.childRowCount),
            "collapsed_child_attention": state.collapsedChildNeedsAttention ? "true" : "false",
        ]
    }

    private func sessionStatusChip(kind: SessionStatusKind, label: String? = nil) -> some View {
        SessionStatusBadge(kind: kind, label: label)
            .modifier(SidebarStatusPillSemanticText(
                text: label ?? SidebarSessionPresentation.sessionStatusBadgeLabel(for: kind)
            ))
    }

    /// A task row whose agent waits for the user's reply. Same colors as the
    /// rail's question box.
    private func taskQuestionChip() -> some View {
        SidebarStatusPill(
            text: Self.taskQuestionChipLabel,
            foreground: ToastyTheme.sidebarTaskQuestionMark,
            background: ToastyTheme.sidebarTaskQuestionMarkBackground
        )
        .modifier(SidebarStatusPillSemanticText(text: Self.taskQuestionChipLabel))
    }

    static let taskQuestionChipLabel = "question"

    static func sessionWaitingChip() -> some View {
        Text("waiting")
            .font(ToastyTheme.fontWorkspaceSessionChip)
            .foregroundStyle(ToastyTheme.sessionWaitingText)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                ToastyTheme.sessionWaitingBackground,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(ToastyTheme.sessionWaitingChipRing, lineWidth: 1)
            )
            .background {
                SidebarSemanticTextBridge(text: "waiting")
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
    }

    private func sessionWorkspaceScopeHelpText(
        for workspaceSessionStatus: WorkspaceSessionStatus,
        fallbackWorkspace: WorkspaceState
    ) -> String? {
        guard workspaceSessionStatus.isWorkspaceScoped else { return nil }

        guard let scopeIDs = workspaceSessionStatus.effectiveScopedWorkspaceIDs,
              scopeIDs.isEmpty == false else {
            return Self.workspaceScopeFallbackHelpText
        }
        let workspaceNames = workspaceScopeWorkspaceNames(
            for: scopeIDs,
            fallbackWorkspace: fallbackWorkspace
        )
        guard workspaceNames.isEmpty == false else {
            return Self.workspaceScopeFallbackHelpText
        }

        let joinedNames = Self.joinedWorkspaceScopeNames(workspaceNames)
        let workspaceNoun = workspaceNames.count == 1 ? "this workspace" : "these workspaces"
        return "Scoped to: \(joinedNames). Automation from this session is limited to \(workspaceNoun)."
    }

    private func workspaceScopeWorkspaceNames(
        for workspaceIDs: Set<UUID>,
        fallbackWorkspace: WorkspaceState
    ) -> [String] {
        let state = store.state
        var orderedIDs: [UUID] = []

        if workspaceIDs.contains(fallbackWorkspace.id) {
            orderedIDs.append(fallbackWorkspace.id)
        }

        for window in state.windows {
            for workspaceID in window.workspaceIDs
                where workspaceIDs.contains(workspaceID) &&
                orderedIDs.contains(workspaceID) == false {
                orderedIDs.append(workspaceID)
            }
        }

        for workspaceID in workspaceIDs.sorted(by: { $0.uuidString < $1.uuidString })
            where orderedIDs.contains(workspaceID) == false {
            orderedIDs.append(workspaceID)
        }

        return orderedIDs.map { workspaceID in
            let title = state.workspacesByID[workspaceID]?.title
            return Self.normalizedWorkspaceScopeName(title, fallbackID: workspaceID)
        }
    }

    private static func normalizedWorkspaceScopeName(_ title: String?, fallbackID: UUID) -> String {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              title.isEmpty == false else {
            return "Workspace \(fallbackID.uuidString.prefix(8))"
        }
        return title
    }

    private static func joinedWorkspaceScopeNames(_ names: [String]) -> String {
        switch names.count {
        case 0:
            return ""
        case 1:
            return names[0]
        case 2:
            return "\(names[0]) and \(names[1])"
        default:
            let leadingNames = names.dropLast().joined(separator: ", ")
            return "\(leadingNames), and \(names[names.count - 1])"
        }
    }

    private func sessionParentTag(label: String) -> some View {
        Text(label)
            .font(ToastyTheme.fontWorkspaceSessionChip)
            .foregroundStyle(ToastyTheme.sidebarSessionPathText)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                ToastyTheme.sidebarWorkspaceTagBackground,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .accessibilityLabel(label)
    }

    private func sessionChildrenDisclosurePill(
        count: Int,
        isExpanded: Bool,
        showsAttention: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            // The pill is a control, so it keeps its intrinsic width instead
            // of wrapping or dropping the count when the header is squeezed.
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(ToastyTheme.sidebarDisclosureText)
            .padding(.horizontal, 8)
            .padding(.vertical, 1.5)
            .background(
                Capsule()
                    .fill(ToastyTheme.sidebarDisclosureBackground)
            )
            .overlay {
                Capsule()
                    .stroke(ToastyTheme.sidebarDisclosureBorder, lineWidth: 1)
            }
            .overlay(alignment: .topTrailing) {
                if showsAttention {
                    Circle()
                        .fill(ToastyTheme.sessionNeedsApprovalText)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .stroke(ToastyTheme.chromeBackground, lineWidth: 1.5)
                        )
                        .offset(x: 2, y: -2)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SidebarSessionPresentation.sessionChildrenDisclosureAccessibilityLabel(
            childCount: count,
            isExpanded: isExpanded,
            showsAttention: showsAttention
        ))
    }

    private func sessionChildRowsContainer(
        _ children: [SessionChildRow],
        parentWorkspaceID: UUID,
        parentPanelID: UUID
    ) -> some View {
        TimelineView(.periodic(from: Date(), by: 30)) { timeline in
            VStack(alignment: .leading, spacing: 1) {
                ForEach(children, id: \.sidebarStableID) { child in
                    sessionChildRow(
                        child,
                        parentWorkspaceID: parentWorkspaceID,
                        parentPanelID: parentPanelID,
                        now: timeline.date
                    )
                }
            }
            .padding(.leading, 6)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(ToastyTheme.sidebarChildRail)
                    .frame(width: 1)
                    .padding(.vertical, 2)
            }
        }
        .padding(.leading, 6)
        .padding(.top, 3)
        .padding(.bottom, 2)
    }

    private func sessionChildRow(
        _ child: SessionChildRow,
        parentWorkspaceID: UUID,
        parentPanelID: UUID,
        now: Date
    ) -> some View {
        let focusTarget = SidebarSessionPresentation.sessionChildFocusTarget(
            for: child,
            parentWorkspaceID: parentWorkspaceID,
            parentPanelID: parentPanelID
        )
        let workspaceTag = childWorkspaceTagLabel(
            for: child,
            parentWorkspaceID: parentWorkspaceID
        )
        let elapsedText = child.source == .activity
            ? SidebarSessionPresentation.elapsedChildActivityText(startedAt: child.startedAt, now: now)
            : nil
        let accessibilityLabel = SidebarSessionPresentation.sessionChildAccessibilityLabel(
            child: child,
            workspaceTag: workspaceTag,
            elapsedText: child.source == .activity ? elapsedText : nil
        )
        let hoverTipModel = SidebarSessionPresentation.sessionChildHoverTipModel(
            child: child,
            workspaceName: workspaceTag,
            elapsedText: elapsedText,
            now: now
        )

        return Button {
            focusSessionPanel(workspaceID: focusTarget.workspaceID, panelID: focusTarget.panelID)
        } label: {
            // Drop the workspace tag rather than truncate it when the row
            // does not fit; the hover tip already names the workspace.
            ViewThatFits(in: .horizontal) {
                if elapsedText == nil, workspaceTag != nil {
                    sessionChildRowContent(child, elapsedText: elapsedText, workspaceTag: workspaceTag)
                }
                sessionChildRowContent(child, elapsedText: elapsedText, workspaceTag: nil)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .hoverTip(
            id: child.sidebarStableID,
            refreshID: hoverTipModel,
            placement: .trailing(gap: Self.hoverTipTrailingGap)
        ) {
            SessionChildHoverTipCard(model: hoverTipModel)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("sidebar.workspace.sessionChild.\(child.sidebarStableID)")
    }

    private func sessionChildRowContent(
        _ child: SessionChildRow,
        elapsedText: String?,
        workspaceTag: String?
    ) -> some View {
        HStack(spacing: 6) {
            Text(child.panelID == nil ? "" : "↗")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ToastyTheme.sidebarChildContextText)
                .frame(width: 9, alignment: .center)
                .accessibilityHidden(true)

            sessionChildStatusView(for: child)

            // The name wins over the command context; the elapsed time is fixed.
            Text(child.displayName)
                .font(ToastyTheme.fontWorkspaceSessionChildName)
                .foregroundStyle(ToastyTheme.sidebarSessionAgentText)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            if let context = child.context {
                // A child session's context is its summary, so it reads like
                // every other summary, Markdown included; a sub-agent's is the
                // command it ran, which stays plain metadata.
                Group {
                    if child.source == .session {
                        Self.styledSessionSummaryText(context)
                            .foregroundStyle(ToastyTheme.sidebarSummaryText)
                    } else {
                        Text(context)
                            .font(ToastyTheme.fontWorkspaceSessionChildContext)
                            .foregroundStyle(ToastyTheme.sidebarChildContextText)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            if let elapsedText {
                Text(elapsedText)
                    .font(ToastyTheme.fontWorkspaceSessionChildMeta)
                    .foregroundStyle(ToastyTheme.sidebarChildMetaText)
                    .monospacedDigit()
                    .fixedSize()
            } else if let workspaceTag {
                sessionParentTag(label: workspaceTag)
            }
        }
    }

    static func sessionChildHoverTipModel(
        child: SessionChildRow,
        workspaceName: String?,
        elapsedText: String?,
        now: Date
    ) -> SessionChildHoverTipModel {
        SidebarSessionPresentation.sessionChildHoverTipModel(
            child: child,
            workspaceName: workspaceName,
            elapsedText: elapsedText,
            now: now
        )
    }

    @ViewBuilder
    private func sessionChildStatusView(for child: SessionChildRow) -> some View {
        switch child.source {
        case .activity:
            SessionChildActivityDot(
                phaseOffset: SessionChildActivityDot.phaseOffset(forStableID: child.sidebarStableID)
            )
        case .session:
            switch child.statusKind {
            case .working:
                SessionChildActivityDot(
                    phaseOffset: SessionChildActivityDot.phaseOffset(forStableID: child.sidebarStableID)
                )
            case .needsApproval, .error, .ready:
                if let statusKind = child.statusKind {
                    sessionStatusChip(kind: statusKind)
                }
            case .idle, nil:
                EmptyView()
            }
        }
    }

    /// While waiting, the summary line says what the session waits on; the
    /// agent's last message stays in the hover card. A narrow row takes the
    /// shorter wording before it truncates.
    private func sessionWaitingSummaryLabel(_ summary: SessionWaitingSummary) -> some View {
        ViewThatFits(in: .horizontal) {
            sessionWaitingSummaryText(summary.rowText(.full))
            sessionWaitingSummaryText(summary.rowText(.compact))
                .truncationMode(.tail)
        }
        .background {
            SidebarSemanticTextBridge(text: summary.rowText(.full))
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    private func sessionWaitingSummaryText(_ text: String) -> some View {
        Text(text)
            .font(ToastyTheme.fontSidebarSummary)
            .foregroundStyle(ToastyTheme.sessionWaitingText)
            .lineLimit(1)
    }

    private func sessionSummaryLabel(_ text: String, isResuming: Bool, isItalic: Bool) -> some View {
        Self.styledSessionSummaryText(text, isItalic: isItalic)
            .foregroundStyle(isResuming ? ToastyTheme.sessionResumingDetailText : ToastyTheme.sidebarSummaryText)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func normalizedSessionDetail(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Subspaces

    /// Sub-agent rows that live in a subspace the ⑂ chip and a Subspaces
    /// group already represent are left out instead of drawn as ↗ rows.
    private func hidingSubspaceChildren(
        _ status: WorkspaceSessionStatus,
        subspaceIDs: Set<UUID>
    ) -> WorkspaceSessionStatus {
        guard subspaceIDs.isEmpty == false else { return status }
        var status = status
        status.children.removeAll { child in
            child.source == .session && child.workspaceID.map(subspaceIDs.contains) == true
        }
        return status
    }

    /// Subspaces a session in this card nested under another card, as
    /// `workspace.create parent=<id>` does.
    private struct OtherCardSubspaceSpawn {
        let parentWorkspaceID: UUID
        let parentWorkspaceTitle: String
        /// That card's rows this session spawned.
        let spawnedRows: [SidebarSubspacePresentation.Row]
    }

    /// For each session in this card that spawned subspaces under other
    /// cards, the first such card as the sidebar lists them. Its ⑂ chip
    /// filters that card's group; subspaces under any further card keep
    /// their ↗ rows.
    private func otherCardSubspaceSpawns(
        cardWorkspaceID: UUID,
        sessionStatuses: [WorkspaceSessionStatus]
    ) -> [String: OtherCardSubspaceSpawn] {
        let sessionIDs = Set(sessionStatuses.map(\.sessionID))
        guard sessionIDs.isEmpty == false,
              let windowWorkspaceIDs = store.window(id: windowID)?.workspaceIDs else {
            return [:]
        }
        var parentIDsBySessionID: [String: Set<UUID>] = [:]
        for workspaceID in windowWorkspaceIDs {
            guard let workspace = store.state.workspacesByID[workspaceID],
                  let parentID = workspace.parentWorkspaceID,
                  parentID != cardWorkspaceID,
                  let spawningSessionID = workspace.spawningSessionID,
                  sessionIDs.contains(spawningSessionID) else {
                continue
            }
            parentIDsBySessionID[spawningSessionID, default: []].insert(parentID)
        }
        guard parentIDsBySessionID.isEmpty == false else { return [:] }
        let cardOrder = store.state.topLevelWorkspaceIDs(in: windowID)
        let parentIDBySessionID = parentIDsBySessionID.compactMapValues { parentIDs in
            cardOrder.first(where: parentIDs.contains)
        }

        var rowsByParentID: [UUID: [SidebarSubspacePresentation.Row]] = [:]
        var spawns: [String: OtherCardSubspaceSpawn] = [:]
        for (sessionID, parentID) in parentIDBySessionID {
            guard let parent = store.state.workspacesByID[parentID] else { continue }
            let rows = rowsByParentID[parentID] ?? subspaceRows(
                for: parentID,
                parentSessionStatuses: sidebarSessionStatuses(for: parentID)
            )
            rowsByParentID[parentID] = rows
            // Rows only exist for valid links, so a stale parent drops out here.
            let spawnedRows = rows.filter { $0.spawningSessionID == sessionID }
            guard spawnedRows.isEmpty == false else { continue }
            spawns[sessionID] = OtherCardSubspaceSpawn(
                parentWorkspaceID: parentID,
                parentWorkspaceTitle: parent.title,
                spawnedRows: spawnedRows
            )
        }
        return spawns
    }

    private func subspaceRows(
        for parentWorkspaceID: UUID,
        parentSessionStatuses: [WorkspaceSessionStatus]
    ) -> [SidebarSubspacePresentation.Row] {
        let subspaceIDs = store.state.subspaceWorkspaceIDs(of: parentWorkspaceID)
        guard subspaceIDs.isEmpty == false else { return [] }
        let windowWorkspaceIDs = store.window(id: windowID)?.workspaceIDs ?? []
        let spawnersBySessionID = Dictionary(
            parentSessionStatuses.map { ($0.sessionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // `workspace.create` with an explicit parent lets a session in another
        // workspace spawn a subspace here, so look past the parent's sessions
        // for it, within this window.
        func spawnerStatus(_ sessionID: String) -> WorkspaceSessionStatus? {
            if let status = spawnersBySessionID[sessionID] { return status }
            guard let workspaceID = sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID)?.workspaceID,
                  windowWorkspaceIDs.contains(workspaceID) else {
                return nil
            }
            return sidebarSessionStatuses(for: workspaceID).first { $0.sessionID == sessionID }
        }
        return subspaceIDs.compactMap { subspaceID in
            guard let workspace = store.state.workspacesByID[subspaceID] else { return nil }
            let row = subspaceRowModel(
                workspace: workspace,
                spawner: workspace.spawningSessionID.flatMap(spawnerStatus)
            )
            // A finished task leaves its project's card; the card's footer
            // counts it and the Tasks view lists it.
            if taskBoard.isEnabled, SidebarSubspacePresentation.isHiddenAsFinished(row) {
                return nil
            }
            return row
        }
    }

    /// One task space's row, with its task's stage when the task system is on.
    func subspaceRowModel(
        workspace: WorkspaceState,
        spawner: WorkspaceSessionStatus?,
        projectTag: String? = nil,
        isLinkedChild: Bool = false
    ) -> SidebarSubspacePresentation.Row {
        let subspaceID = workspace.id
        let statuses = sidebarSessionStatuses(for: subspaceID)
        let boardItem = taskBoard.item(taskSpace: workspace, statuses: statuses)
        let sessions = statuses.map { status in
            SidebarSubspacePresentation.SessionLine(
                title: status.displayTitle,
                panelID: status.panelID,
                // An unnamed session's title is already the agent's name.
                agentLabel: status.sessionName == nil ? nil : SidebarSessionPresentation.sessionAgentLabel(for: status.agent),
                statusKind: status.status.kind,
                isWaiting: SidebarSessionPresentation.sessionStatusProjectionChipLabel(for: status.projection) != nil,
                showsUnreadSessionAccent: showsUnreadSessionAccent(for: status.panelID, in: workspace),
                summary: SidebarSessionPresentation.sessionWaitingSummary(for: status)?.rowText(.compact)
                    ?? normalizedSessionDetail(status.status.detail)
                    ?? normalizedSessionDetail(status.status.summary),
                turnStartedAt: status.turnStartedAt,
                statusUpdatedAt: TaskBoard.agentActivityAt(status)
            )
        }
        return SidebarSubspacePresentation.Row(
            id: subspaceID,
            title: boardItem?.title ?? workspace.title,
            status: SidebarSubspacePresentation.rowStatus(
                sessionStatus: SidebarSubspacePresentation.rowStatus(
                    sessionStatuses: sessions.map { session in
                        (kind: session.statusKind, showsUnreadSessionAccent: session.showsUnreadSessionAccent)
                    }
                ),
                isDone: workspace.doneAt != nil,
                stage: boardItem?.stage
            ),
            stage: boardItem?.stage,
            isTask: workspace.taskID != nil,
            projectTag: projectTag,
            linkedParentID: taskCoordinator?.records.linkedParentTaskSpaceID(of: workspace, in: store.state),
            isLinkedChild: isLinkedChild,
            childProgressLabel: boardItem?.taskID.flatMap(childProgressLabel(ofTaskID:)),
            doneAt: workspace.doneAt,
            acceptsDoneMark: boardItem?.acceptsDoneMark ?? true,
            releasesAfterMerge: boardItem.flatMap(TaskBoardPresentation.releaseAfterMergeRequestedAt) != nil,
            annotations: workspace.annotations,
            primaryAnnotationKey: workspace.primaryAnnotationKey,
            // While setup or the move into a worktree runs or has failed,
            // the row says so instead of what its sessions show.
            summary: boardItem.flatMap { item in
                // The agent's question replaces its last status line.
                if case .needsYou(.awaitingReply) = item.stage { return TaskBoardPresentation.replyLine(item) }
                return item.stage.isBeforeStart ? TaskBoardPresentation.statusLine(item) : nil
            } ?? SidebarSubspacePresentation.rowSummary(sessions: sessions),
            spawningSessionID: workspace.spawningSessionID,
            spawnerName: spawner?.displayTitle,
            spawnerPanelID: spawner?.panelID,
            spawnerWorkspaceID: spawner?.workspaceID,
            sessions: sessions,
            path: SidebarSubspacePresentation.path(sessionCWDs: statuses.map(\.cwd), workspace: workspace),
            taskMenu: taskMenu(for: boardItem, workspace: workspace)
        )
    }

    /// A task space's task menu. Only a task space with a task record has
    /// one; other subspaces keep their own menu.
    private func taskMenu(for item: TaskBoardItem?, workspace: WorkspaceState) -> [[TaskBoardPresentation.MenuItem]]? {
        guard let item, item.record != nil else { return nil }
        // The window shows the selected task space unless the Tasks view
        // covers it.
        let showsTasksView = store.window(id: windowID)?.showsTasksView ?? false
        let currentWorkspaceID = showsTasksView ? nil : selectedWorkspaceID
        return TaskBoardPresentation.menuItems(
            item,
            currentWorkspaceID: currentWorkspaceID,
            showsMergeShortcut: currentWorkspaceID == workspace.id && isMergeButtonReady(workspace)
        )
    }

    /// Whether Option+Shift+M would merge the workspace: its Merge button is
    /// ready, as the shortcut's handler checks.
    private func isMergeButtonReady(_ workspace: WorkspaceState) -> Bool {
        guard case .ready? = WorkspaceMergePresentation.make(
            workspace: workspace,
            request: sessionRuntimeStore.workspaceMergeRequests[workspace.id],
            mode: store.workspaceMergeMode,
            isCheckingMerge: sessionRuntimeStore.isCheckingTaskMerge(workspaceID: workspace.id),
            isTaskMerged: sessionRuntimeStore.isTaskMerged(workspaceID: workspace.id)
        ) else { return false }
        return true
    }

    private func childProgressLabel(ofTaskID taskID: UUID) -> String? {
        guard let coordinator = taskCoordinator,
              coordinator.records.records.contains(where: { $0.parentTaskID == taskID }) else { return nil }
        guard let progress = TaskBoard.childProgress(of: taskID, items: taskBoardSnapshot.allItems) else { return nil }
        return SidebarSubspacePresentation.childProgressLabel(merged: progress.merged, total: progress.total)
    }

    @ViewBuilder
    private func subspacesGroup(
        _ rows: [SidebarSubspacePresentation.Row],
        parentWorkspaceID: UUID
    ) -> some View {
        if rows.isEmpty == false {
            subspacesGroupContent(rows, parentWorkspaceID: parentWorkspaceID)
        }
    }

    private func subspacesGroupContent(
        _ rows: [SidebarSubspacePresentation.Row],
        parentWorkspaceID: UUID
    ) -> some View {
        let filterSessionID = subspaceFilterSessionIDByParentID[parentWorkspaceID]
        let isExpanded = collapsedSubspaceGroupParentIDs.contains(parentWorkspaceID) == false
        let filteredRows = SidebarSubspacePresentation.filteredRows(rows, spawningSessionID: filterSessionID)
        // Rows keep the window's workspace order; only adding or removing a
        // task space moves the rows around it.
        let orderedRows = SidebarSubspacePresentation.groupingLinkedChildren(filteredRows)
        let tally = SidebarSubspacePresentation.tally(rows)
        let needsAttention = SidebarSubspacePresentation.needsAttention(rows)
        let attentionRowIDs = Set(rows.filter { $0.status.needsAttention }.map(\.id))
        let showsSpawnerTags = SidebarSubspacePresentation.showsSpawnerTags(rows)
        let filterSpawnerName = filterSessionID.flatMap { sessionID in
            rows.first { $0.spawningSessionID == sessionID }?.spawnerName
        }
        let orderedRowIDs = orderedRows.map(\.id)

        return VStack(alignment: .leading, spacing: 3) {
            subspacesGroupHeader(
                parentWorkspaceID: parentWorkspaceID,
                shownCount: filteredRows.count,
                totalCount: rows.count,
                tally: tally,
                isExpanded: isExpanded
            )
            .background(subspaceFrameMeasurement(id: .group(parentWorkspaceID)))

            if isExpanded {
                if filterSessionID != nil {
                    subspacesFilterBar(
                        spawnerName: filterSpawnerName ?? "this agent",
                        parentWorkspaceID: parentWorkspaceID
                    )
                }

                VStack(alignment: .leading, spacing: 1) {
                    ForEach(orderedRows) { row in
                        subspaceRow(
                            row,
                            parentWorkspaceID: parentWorkspaceID,
                            showsSpawnerTag: SidebarSubspacePresentation.showsSpawnerTag(
                                row,
                                parentWorkspaceID: parentWorkspaceID,
                                groupShowsSpawnerTags: showsSpawnerTags
                            )
                        )
                    }
                }
                .animation(
                    accessibilityReduceMotion ? nil : .easeInOut(duration: 0.28),
                    value: orderedRowIDs
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .id(SubspaceGroupScrollID(parentWorkspaceID: parentWorkspaceID))
        .accessibilityIdentifier("sidebar.workspace.subspaces.\(parentWorkspaceID.uuidString)")
        .onAppear {
            if needsAttention {
                collapsedSubspaceGroupParentIDs.remove(parentWorkspaceID)
            }
        }
        // A subspace that newly needs the user reopens a collapsed group and
        // clears a filter that would hide it, the same rule sub-agent rows
        // follow. Attention that already existed when the user chose the
        // filter does not fight the choice; the header tally still shows it.
        .onChange(of: needsAttention) { _, needsAttention in
            if needsAttention {
                collapsedSubspaceGroupParentIDs.remove(parentWorkspaceID)
            }
        }
        .onChange(of: attentionRowIDs) { previousIDs, currentIDs in
            let hiddenNewIDs = currentIDs.subtracting(previousIDs).filter { rowID in
                rows.first { $0.id == rowID }?.spawningSessionID != filterSessionID
            }
            if filterSessionID != nil, hiddenNewIDs.isEmpty == false {
                subspaceFilterSessionIDByParentID.removeValue(forKey: parentWorkspaceID)
            }
        }
        .onChange(of: filteredRows.isEmpty, initial: true) { _, isEmpty in
            // The filtered agent has no open subspaces left; show everything.
            if isEmpty, filterSessionID != nil {
                subspaceFilterSessionIDByParentID.removeValue(forKey: parentWorkspaceID)
            }
        }
    }

    private func subspacesGroupHeader(
        parentWorkspaceID: UUID,
        shownCount: Int,
        totalCount: Int,
        tally: SidebarSubspacePresentation.Tally,
        isExpanded: Bool
    ) -> some View {
        // Narrow sidebars drop the status tally (the rows show the same
        // statuses) before the title has to truncate.
        ViewThatFits(in: .horizontal) {
            subspacesGroupHeaderRow(
                parentWorkspaceID: parentWorkspaceID,
                shownCount: shownCount,
                totalCount: totalCount,
                tally: tally,
                showsTally: true,
                isExpanded: isExpanded
            )
            subspacesGroupHeaderRow(
                parentWorkspaceID: parentWorkspaceID,
                shownCount: shownCount,
                totalCount: totalCount,
                tally: tally,
                showsTally: false,
                isExpanded: isExpanded
            )
        }
        .frame(minHeight: 16)
        .padding(.top, 6)
    }

    private func subspacesGroupHeaderRow(
        parentWorkspaceID: UUID,
        shownCount: Int,
        totalCount: Int,
        tally: SidebarSubspacePresentation.Tally,
        showsTally: Bool,
        isExpanded: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                if isExpanded {
                    collapsedSubspaceGroupParentIDs.insert(parentWorkspaceID)
                } else {
                    collapsedSubspaceGroupParentIDs.remove(parentWorkspaceID)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 9)
                    Text(SidebarSubspacePresentation.groupTitle.uppercased())
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(SidebarSubspacePresentation.headerCountLabel(shownCount: shownCount, totalCount: totalCount))
                        .font(ToastyTheme.fontWorkspaceAgentCount)
                        .foregroundStyle(ToastyTheme.sidebarSessionPathText)
                        .lineLimit(1)
                        .fixedSize()
                }
                .foregroundStyle(ToastyTheme.sidebarChildContextText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(SidebarSubspacePresentation.groupAccessibilityLabel(
                rowCount: totalCount,
                isExpanded: isExpanded,
                tally: tally
            ))
            .accessibilityIdentifier("sidebar.workspace.subspaces.toggle")
            .background {
                SidebarSemanticTextBridge(text: SidebarSubspacePresentation.groupAccessibilityLabel(
                    rowCount: totalCount,
                    isExpanded: isExpanded,
                    tally: tally
                ))
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }

            Spacer(minLength: 0)

            if showsTally, tally.isEmpty == false {
                HStack(spacing: 8) {
                    subspacesTallyItem(count: tally.ready, color: ToastyTheme.sessionReadyText)
                    subspacesTallyItem(count: tally.question, color: ToastyTheme.sidebarTaskQuestionMark)
                    subspacesTallyItem(count: tally.needsApproval, color: ToastyTheme.sessionNeedsApprovalText)
                    subspacesTallyItem(count: tally.error, color: ToastyTheme.sessionErrorText)
                    subspacesTallyItem(count: tally.review, color: ToastyTheme.sidebarTaskReviewMark)
                }
                .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func subspacesTallyItem(count: Int, color: Color) -> some View {
        if count > 0 {
            HStack(spacing: 3) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text("\(count)")
                    .font(ToastyTheme.fontWorkspaceAgentCount)
                    .foregroundStyle(color)
            }
        }
    }

    private func subspacesFilterBar(spawnerName: String, parentWorkspaceID: UUID) -> some View {
        HStack(spacing: 5) {
            Text(SidebarSubspacePresentation.filterBarLabel(spawnerName: spawnerName))
                .font(ToastyTheme.fontWorkspaceSessionChip)
                .foregroundStyle(ToastyTheme.sidebarSessionPathText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button {
                subspaceFilterSessionIDByParentID.removeValue(forKey: parentWorkspaceID)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(ToastyTheme.sidebarChildContextText)
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear task space filter")
            .accessibilityIdentifier("sidebar.workspace.subspaces.clearFilter")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(ToastyTheme.sidebarDisclosureBackground, in: RoundedRectangle(cornerRadius: 5))
        .background {
            SidebarSemanticTextBridge(text: SidebarSubspacePresentation.filterBarLabel(spawnerName: spawnerName))
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    /// The ↖ tag on a subspace row. While the spawning session runs it is a
    /// button that focuses that session's panel in whichever workspace holds it.
    @ViewBuilder
    private func spawnerTag(
        label: String,
        spawnerName: String,
        spawnerWorkspaceID: UUID,
        spawnerPanelID: UUID?
    ) -> some View {
        if let spawnerPanelID {
            Button {
                focusSessionPanel(workspaceID: spawnerWorkspaceID, panelID: spawnerPanelID)
            } label: {
                sessionParentTag(label: label)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Go to \(spawnerName)")
            .accessibilityIdentifier("sidebar.workspace.subspace.spawnerTag")
            .background {
                SidebarSemanticTextBridge(text: "Go to \(spawnerName)")
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
        } else {
            sessionParentTag(label: label)
        }
    }

    private func subspaceRowTitleLine(
        _ row: SidebarSubspacePresentation.Row,
        isEmphasized: Bool,
        showsAnnotation: Bool,
        showsWaitingChip: Bool
    ) -> some View {
        HStack(spacing: 6) {
            // The ideal width is what the fit check reserves for the title;
            // in layout it takes whatever the chips leave.
            Self.styledSessionNameText(row.title, isEmphasized: isEmphasized, isItalic: row.status == .working)
                .foregroundStyle(
                    row.status == .done
                        ? ToastyTheme.sidebarSubspaceDoneTitleText
                        : ToastyTheme.sidebarSessionAgentText
                )
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    minWidth: 0,
                    idealWidth: Self.sessionRowTitleReservedWidth,
                    maxWidth: .infinity,
                    alignment: .leading
                )

            HStack(spacing: 6) {
                if row.releasesAfterMerge {
                    TaskReleaseAfterMergeMark()
                }
                if let chipKind = Self.subspaceStatusChipKind(row.status) {
                    sessionStatusChip(kind: chipKind)
                } else if row.status == .question {
                    taskQuestionChip()
                }
                if showsWaitingChip {
                    Self.sessionWaitingChip()
                }
                if showsAnnotation, let rowAnnotation = row.rowAnnotation {
                    // No ↗ glyph here to save width; the chip still opens
                    // its link.
                    workspaceAnnotationChip(
                        key: rowAnnotation.key,
                        annotation: rowAnnotation.annotation,
                        maximumWidth: Self.subspaceRowAnnotationChipMaximumWidth,
                        showsLinkGlyph: false
                    )
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
    }

    private func subspaceRow(
        _ row: SidebarSubspacePresentation.Row,
        parentWorkspaceID: UUID,
        showsSpawnerTag: Bool
    ) -> some View {
        SidebarHoverRegion(id: row.id, selection: hoverState.subspace) { isHovered in
            subspaceRowContent(row, parentWorkspaceID: parentWorkspaceID, showsSpawnerTag: showsSpawnerTag, isHovered: isHovered)
        }
    }

    private func subspaceRowContent(
        _ row: SidebarSubspacePresentation.Row,
        parentWorkspaceID: UUID,
        showsSpawnerTag: Bool,
        isHovered: Bool
    ) -> some View {
        let isSelected = selectedWorkspaceID == row.id
        let isSpawnerHighlighted = hoveredSpawnerSessionID != nil
            && hoveredSpawnerSessionID == row.spawningSessionID
        let attentionKind = Self.subspaceAttentionKind(row.status)
        // Same chrome as a session row: selection uses the active fill, a row
        // that wants the user keeps its tint, and hover fills and outlines.
        // A tinted row shows the spawner highlight as an outline, since a
        // fill would hide the tint; a selected row shows neither.
        let background: Color = if isSelected {
            isHovered ? ToastyTheme.sidebarSessionActiveHoverBackground : ToastyTheme.sidebarSessionActiveBackground
        } else if let tint = attentionKind.flatMap(ToastyTheme.sidebarAttentionTint(for:)) {
            tint
        } else if isHovered || isSpawnerHighlighted {
            ToastyTheme.sidebarSessionHoverBackground
        } else {
            Color.clear
        }
        let borderColor = isHovered || (isSpawnerHighlighted && attentionKind != nil && isSelected == false)
            ? ToastyTheme.sidebarSessionHoverBorder
            : Color.clear
        let hoverTipModel = SidebarSubspacePresentation.hoverTipModel(
            row,
            annotationColorToken: annotationStyleStore.effectiveColorToken(forKey:)
        )
        let accessibilityLabel = SidebarSubspacePresentation.rowAccessibilityLabel(
            row,
            showsSpawnerTag: showsSpawnerTag
        )

        let select = {
            cancelWorkspaceRename()
            store.selectWorkspace(
                windowID: windowID,
                workspaceID: row.id,
                preferringUnreadSessionPanelIn: sessionRuntimeStore
            )
        }

        // A tap on the row selects the workspace; the annotation chip inside stays a
        // real link button, as it is on top-level cards.
        // Same rail and padding as a session row, so the title's left edge
        // lines up with the session titles above whatever the status is.
        return HStack(alignment: .top, spacing: Self.sessionStatusRailGap) {
            subspaceRailMark(row)

            VStack(alignment: .leading, spacing: 1) {
                // Status takes priority over the annotation at narrow widths.
                // Both remain available in the hover card and spoken label.
                ViewThatFits(in: .horizontal) {
                    if row.rowAnnotation != nil {
                        subspaceRowTitleLine(
                            row, isEmphasized: attentionKind != nil,
                            showsAnnotation: true, showsWaitingChip: row.isWaiting
                        )
                    }
                    if row.isWaiting {
                        subspaceRowTitleLine(
                            row, isEmphasized: attentionKind != nil,
                            showsAnnotation: false, showsWaitingChip: true
                        )
                    }
                    subspaceRowTitleLine(
                        row, isEmphasized: attentionKind != nil,
                        showsAnnotation: false, showsWaitingChip: false
                    )
                }
                .frame(minHeight: Self.sessionRowLineMinHeight)

                if row.summary != nil || (showsSpawnerTag && row.spawnerName != nil)
                    || row.projectTag != nil || row.childProgressLabel != nil || row.parentTaskTitle != nil {
                    HStack(spacing: 6) {
                        if let summary = row.summary {
                            Self.styledSessionSummaryText(summary, isItalic: row.status == .working)
                                .foregroundStyle(ToastyTheme.sidebarSummaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                        if let childProgressLabel = row.childProgressLabel {
                            Self.sidebarTaskTag(childProgressLabel)
                        }
                        if let projectTag = row.projectTag {
                            Self.sidebarTaskTag(projectTag)
                        }
                        if let parentTaskTitle = row.parentTaskTitle {
                            SidebarCappedIntrinsicWidthLayout(maximumWidth: Self.subspaceSpawnerTagMaximumWidth + 30) {
                                Text(SidebarSubspacePresentation.spawnerTagLabel(parentTaskTitle))
                                    .font(ToastyTheme.fontWorkspaceSessionChip)
                                    .foregroundStyle(ToastyTheme.sidebarSessionPathText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(ToastyTheme.sidebarWorkspaceTagBackground, in: RoundedRectangle(cornerRadius: 4))
                            }
                            .background {
                                SidebarTooltipBridge(text: "Started by \(parentTaskTitle)")
                                    .allowsHitTesting(false)
                            }
                        }
                        if showsSpawnerTag, let spawnerName = row.spawnerName {
                            SidebarCappedIntrinsicWidthLayout(maximumWidth: Self.subspaceSpawnerTagMaximumWidth) {
                                spawnerTag(
                                    label: SidebarSubspacePresentation.spawnerTagLabel(spawnerName),
                                    spawnerName: spawnerName,
                                    spawnerWorkspaceID: row.spawnerWorkspaceID ?? parentWorkspaceID,
                                    spawnerPanelID: row.spawnerPanelID
                                )
                            }
                            .background {
                                SidebarTooltipBridge(text: spawnerName)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A task an agent split off draws under the task that started it,
        // indented, with a ↳ mark.
        .padding(.leading, row.isLinkedChild ? Self.linkedChildIndent : 0)
        .overlay(alignment: .topLeading) {
            if row.isLinkedChild {
                Self.linkedChildArrow
            }
        }
        .background(background, in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(borderColor, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture(perform: select)
        // No AppKit pointer overlay covers this row, so SwiftUI hover works
        // directly, unlike the session rows above it.
        .onHover { isHovering in
            guard activeWorkspaceDrag == nil, activeSessionDrag == nil else { return }
            if isHovering {
                hoverState.subspace.value = row.id
            } else if hoverState.subspace.value == row.id {
                hoverState.subspace.value = nil
            }
        }
        .hoverTip(
            id: row.id,
            refreshID: hoverTipModel,
            placement: .trailing(gap: Self.hoverTipTrailingGap)
        ) {
            SubspaceHoverTipCard(model: hoverTipModel) { panelID in
                focusSessionPanel(workspaceID: row.id, panelID: panelID)
            }
        }
        .background {
            SidebarSemanticTextBridge(text: accessibilityLabel)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, select)
        .accessibilityActions {
            if SidebarSubspacePresentation.canToggleDone(row) {
                Button(SidebarSubspacePresentation.doneToggleActionTitle(isDone: row.isDone)) {
                    toggleSubspaceDone(row)
                }
            }
        }
        .accessibilityAction(named: Text("Move to top level")) {
            _ = store.send(
                .setWorkspaceParent(workspaceID: row.id, parentWorkspaceID: nil, spawningSessionID: nil),
                source: .ui("sidebar_subspace_move_to_top_level")
            )
        }
        .accessibilityIdentifier("sidebar.workspace.subspace.\(row.id.uuidString)")
        .background(subspaceFrameMeasurement(id: .row(row.id)))
        .id(row.id)
        .contextMenu {
            // A task's own items replace the merge items and the done mark:
            // its Mark Done and merge are what done means for it.
            if let taskMenu = row.taskMenu {
                TaskContextMenuItems(sections: taskMenu, run: runTaskMenuItem)
                if taskMenu.isEmpty == false {
                    Divider()
                }
            } else {
                let mergePresentation = subspaceMergeMenuPresentation(row)
                if let mergePresentation {
                    subspaceMergeMenuItems(row, presentation: mergePresentation)
                }
                Button(SidebarSubspacePresentation.doneToggleActionTitle(isDone: row.isDone)) {
                    toggleSubspaceDone(row)
                }
                if mergePresentation != nil {
                    Divider()
                }
            }
            Button("Move to top level") {
                _ = store.send(
                    .setWorkspaceParent(workspaceID: row.id, parentWorkspaceID: nil, spawningSessionID: nil),
                    source: .ui("sidebar_subspace_move_to_top_level")
                )
            }
            Button(ToasttyKeyboardShortcuts.closeWorkspace.menuTitle("Close workspace"), role: .destructive) {
                requestWorkspaceClose(workspaceID: row.id)
            }
        }
    }

    /// The rail mark, which is also the done checkbox while it is a box. A
    /// click on it toggles the mark instead of selecting the row.
    @ViewBuilder
    private func subspaceRailMark(_ row: SidebarSubspacePresentation.Row) -> some View {
        if SidebarSubspacePresentation.showsDoneToggle(row) {
            SidebarHoverRegion(id: row.id, selection: hoverState.doneToggle) { isPreviewed in
                Button {
                    toggleSubspaceDone(row)
                } label: {
                    // The glyph stays in the rail, but the click target reaches
                    // into the row's padding and the gap beside the rail, so a
                    // near miss does not fall through and open the workspace.
                    SubspaceRailStatusIcon(status: row.status, isDoneTogglePreviewed: isPreviewed)
                        .frame(width: Self.sessionStatusRailWidth, height: Self.sessionRowLineMinHeight)
                        .padding(Self.subspaceDoneToggleHitOutset)
                        .contentShape(Rectangle())
                        .padding(-Self.subspaceDoneToggleHitOutset)
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    if isHovering {
                        hoverState.doneToggle.value = row.id
                    } else if hoverState.doneToggle.value == row.id {
                        hoverState.doneToggle.value = nil
                    }
                }
                .background {
                    SidebarTooltipBridge(text: SidebarSubspacePresentation.doneToggleActionTitle(isDone: row.isDone))
                        .allowsHitTesting(false)
                }
                .accessibilityHidden(true)
                .accessibilityIdentifier("sidebar.workspace.subspace.doneToggle.\(row.id.uuidString)")
            }
        } else {
            SubspaceRailStatusIcon(status: row.status)
                .frame(width: Self.sessionStatusRailWidth, height: Self.sessionRowLineMinHeight)
                .accessibilityHidden(true)
                .onAppear {
                    // The box can turn into a spinner under the pointer; do
                    // not let the preview come back when it turns into a box.
                    if hoverState.doneToggle.value == row.id {
                        hoverState.doneToggle.value = nil
                    }
                }
        }
    }

    /// The row's merge menu items: both merge actions while the pull request
    /// is open, a disabled progress item while the agent merges it, and the
    /// retry and dismiss items for a pending or failed cleanup.
    @ViewBuilder
    private func subspaceMergeMenuItems(
        _ row: SidebarSubspacePresentation.Row,
        presentation: WorkspaceMergePresentation
    ) -> some View {
        switch presentation {
        case .ready(let pullRequest, _, _) where sessionRuntimeStore.isTaskSpaceWithRecord(workspaceID: row.id):
            // A task merges its own way and always cleans up after.
            Button(ToasttyKeyboardShortcuts.mergeWorkspacePullRequest.menuTitle("Merge \(pullRequest)")) {
                requestWorkspaceMerge(row.id, store.workspaceMergeMode)
            }
            Button("Merge \(pullRequest) Without Checks") {
                TaskActions.mergeWithoutChecks(workspaceID: row.id, store: store, sessionRuntimeStore: sessionRuntimeStore)
            }
            Button("Archive Task…") {
                if let coordinator = sessionRuntimeStore.taskCoordinator,
                   let taskID = store.state.workspacesByID[row.id]?.taskID {
                    TaskActions.archive(taskID: taskID, coordinator: coordinator)
                }
            }
        case .ready(let pullRequest, let currentMode, _):
            ForEach(WorkspaceMergeMode.allCases, id: \.self) { mode in
                let title = WorkspaceMergePresentation.actionTitle(mode: mode, pullRequest: pullRequest)
                // The shortcut runs the mode selected in the top bar button menu.
                Button(mode == currentMode ? ToasttyKeyboardShortcuts.mergeWorkspacePullRequest.menuTitle(title) : title) {
                    requestWorkspaceMerge(row.id, mode)
                }
            }
            Button(WorkspaceMergePresentation.closeWithoutMergingTitle) {
                requestWorkspaceClose(row.id)
            }
        case .cleanupFailed:
            Button(presentation.title) {}
                .disabled(true)
            Button("Retry Clean Up") {
                sessionRuntimeStore.workspaceMergeCoordinator?.retryCleanup(workspaceID: row.id)
            }
            Button("Don't Clean Up") {
                sessionRuntimeStore.workspaceMergeCoordinator?.cancelCleanup(workspaceID: row.id)
            }
        case .merging, .cleaningUp, .closing, .done:
            Button(presentation.title) {}
                .disabled(true)
        }
    }

    /// The row's merge state for its context menu; `nil` once the row is
    /// done with nothing left to clean up.
    private func subspaceMergeMenuPresentation(
        _ row: SidebarSubspacePresentation.Row
    ) -> WorkspaceMergePresentation? {
        guard store.isWorkspaceMergeEnabled || sessionRuntimeStore.isTaskSpaceWithRecord(workspaceID: row.id),
              let workspace = store.state.workspacesByID[row.id],
              let presentation = WorkspaceMergePresentation.make(
                workspace: workspace,
                request: sessionRuntimeStore.workspaceMergeRequests[row.id],
                mode: store.workspaceMergeMode,
                isCheckingMerge: sessionRuntimeStore.isCheckingTaskMerge(workspaceID: row.id),
                isTaskMerged: sessionRuntimeStore.isTaskMerged(workspaceID: row.id)
              ) else {
            return nil
        }
        if case .done = presentation {
            return nil
        }
        return presentation
    }

    private func runTaskMenuItem(_ item: TaskBoardPresentation.MenuItem) {
        guard let coordinator = taskCoordinator else { return }
        TaskActions.runFromMenu(item, coordinator: coordinator) { workspaceID in
            TaskActions.openTaskSpace(
                workspaceID: workspaceID,
                fallbackWindowID: windowID,
                store: store,
                sessionRuntimeStore: sessionRuntimeStore
            )
        }
    }

    private func toggleSubspaceDone(_ row: SidebarSubspacePresentation.Row) {
        let isDone = store.state.workspacesByID[row.id]?.doneAt != nil
        guard isDone || sessionRuntimeStore.taskSpaceAcceptsDoneMark(workspaceID: row.id) else { return }
        _ = store.send(
            .setWorkspaceDone(workspaceID: row.id, doneAt: isDone ? nil : Date()),
            source: .ui("sidebar_subspace_toggle_done")
        )
    }

    /// Selecting a subspace whose row is collapsed or filtered away would
    /// leave nothing highlighted, so open the group and drop the filter.
    private func revealSelectedSubspaceIfNeeded() {
        guard let selectedWorkspaceID,
              let parentWorkspaceID = store.state.workspacesByID[selectedWorkspaceID]?.parentWorkspaceID else {
            return
        }
        collapsedSubspaceGroupParentIDs.remove(parentWorkspaceID)
        if let filterSessionID = subspaceFilterSessionIDByParentID[parentWorkspaceID],
           store.state.workspacesByID[selectedWorkspaceID]?.spawningSessionID != filterSessionID {
            subspaceFilterSessionIDByParentID.removeValue(forKey: parentWorkspaceID)
        }
    }

    /// The statuses that tint a subspace row and set its title heavy, as on
    /// a session row.
    private static func subspaceAttentionKind(
        _ status: SidebarSubspacePresentation.RowStatus
    ) -> SessionStatusKind? {
        switch status {
        case .ready: return .ready
        case .needsApproval: return .needsApproval
        case .error: return .error
        case .working, .idle, .question, .review, .toShip, .done: return nil
        }
    }

    /// Ready gets no chip: the rail dot, the header tally, and the sort order
    /// already show it, and the chip would squeeze the title next to an annotation chip.
    /// Question has no session kind; `subspaceRowTitleLine` draws its pill.
    private static func subspaceStatusChipKind(
        _ status: SidebarSubspacePresentation.RowStatus
    ) -> SessionStatusKind? {
        switch status {
        case .needsApproval: return .needsApproval
        case .error: return .error
        case .ready, .working, .idle, .question, .review, .toShip, .done: return nil
        }
    }

    private func spawnerSubspacesChip(
        _ chip: SidebarSubspacePresentation.SpawnerChip,
        onToggle: @escaping () -> Void,
        onHover: @escaping (Bool) -> Void
    ) -> some View {
        let foreground: Color
        let background: Color
        let border: Color
        if chip.isFilterActive {
            foreground = ToastyTheme.chromeBackground
            background = ToastyTheme.sidebarDisclosureText
            border = ToastyTheme.sidebarDisclosureText
        } else {
            switch chip.tone {
            case .neutral:
                foreground = ToastyTheme.sidebarDisclosureText
                background = ToastyTheme.sidebarDisclosureBackground
                border = ToastyTheme.sidebarDisclosureBorder
            case .needsApproval:
                foreground = ToastyTheme.sessionNeedsApprovalText
                background = ToastyTheme.sessionNeedsApprovalBackground
                border = ToastyTheme.sessionNeedsApprovalText.opacity(0.6)
            case .error:
                foreground = ToastyTheme.sessionErrorText
                background = ToastyTheme.sessionErrorBackground
                border = ToastyTheme.sessionErrorText.opacity(0.6)
            }
        }
        return Button(action: onToggle) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8.5, weight: .semibold))
                Text("\(chip.count)")
                    .font(ToastyTheme.fontWorkspaceAgentCount)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
            .overlay {
                Capsule().stroke(border, lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .accessibilityLabel(SidebarSubspacePresentation.spawnerChipAccessibilityLabel(chip))
        .accessibilityIdentifier("sidebar.workspace.session.spawnerChip")
        // The row folds its children into one accessibility element, so the
        // chip's wording is otherwise invisible to AppKit inspectors and
        // host-based tests.
        .background {
            SidebarSemanticTextBridge(text: SidebarSubspacePresentation.spawnerChipAccessibilityLabel(chip))
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    /// A chip whose subspaces live under another card also takes the user
    /// there: it selects that card, unless the selection is already in it,
    /// and scrolls its Subspaces group into view.
    private func toggleSubspaceFilter(
        parentWorkspaceID: UUID,
        spawningSessionID: String,
        fromCardWorkspaceID: UUID
    ) {
        if subspaceFilterSessionIDByParentID[parentWorkspaceID] == spawningSessionID {
            subspaceFilterSessionIDByParentID.removeValue(forKey: parentWorkspaceID)
            return
        }
        subspaceFilterSessionIDByParentID[parentWorkspaceID] = spawningSessionID
        collapsedSubspaceGroupParentIDs.remove(parentWorkspaceID)
        // The chip asks to see those task spaces, so a collapsed card opens.
        if isCardCollapsed(parentWorkspaceID) {
            _ = store.send(
                .setSidebarWorkspaceCollapsed(windowID: windowID, workspaceID: parentWorkspaceID, collapsed: false),
                source: .ui("sidebar_spawner_filter")
            )
        }
        guard parentWorkspaceID != fromCardWorkspaceID else { return }

        let awaitsSelection = workspaceCardContainsSelection(parentWorkspaceID) == false
        subspaceGroupScrollRequest = SubspaceGroupScrollRequest(
            parentWorkspaceID: parentWorkspaceID,
            awaitsSelection: awaitsSelection
        )
        guard awaitsSelection else { return }
        cancelWorkspaceRename()
        store.selectWorkspace(
            windowID: windowID,
            workspaceID: parentWorkspaceID,
            preferringUnreadSessionPanelIn: sessionRuntimeStore
        )
        // No selection change means no handler will consume the request.
        if workspaceCardContainsSelection(parentWorkspaceID) == false {
            subspaceGroupScrollRequest = nil
        }
    }

    private func pruneSubspaceGroupState() {
        // Keep state only for cards that still have a group, so a later
        // group under the same card starts fresh.
        let parentIDs = Set(store.state.workspacesByID.keys.filter { store.state.subspaceWorkspaceIDs(of: $0).isEmpty == false })
        if let hoveredID = hoverState.subspace.value, store.state.workspacesByID[hoveredID]?.parentWorkspaceID == nil {
            hoverState.subspace.value = nil
        }
        collapsedSubspaceGroupParentIDs = collapsedSubspaceGroupParentIDs.filter(parentIDs.contains)
        subspaceFilterSessionIDByParentID = subspaceFilterSessionIDByParentID.filter { parentIDs.contains($0.key) }
    }

    private func toggleSessionChildRows(sessionID: String) {
        expandedSessionChildrenBySessionID[sessionID] = !SidebarSessionPresentation.sessionChildRowsExpanded(
            sessionID: sessionID,
            expandedSessionChildrenBySessionID: expandedSessionChildrenBySessionID
        )
    }

    private func autoExpandSessionChildRowsIfNeeded(
        sessionID: String,
        childrenNeedAttention: Bool
    ) {
        guard childrenNeedAttention else { return }
        expandedSessionChildrenBySessionID[sessionID] = true
    }

    private func parentSession(for workspaceSessionStatus: WorkspaceSessionStatus) -> SessionRecord? {
        guard let parentSessionID = workspaceSessionStatus.parentSessionID,
              parentSessionID != workspaceSessionStatus.sessionID else {
            return nil
        }
        return sessionRuntimeStore.sessionRegistry.activeSession(sessionID: parentSessionID)
    }

    private func childWorkspaceTagLabel(
        for child: SessionChildRow,
        parentWorkspaceID: UUID
    ) -> String? {
        let workspaceNamesByID = store.state.workspacesByID.mapValues(\.title)
        return SidebarSessionPresentation.childWorkspaceTagLabel(
            for: child,
            parentWorkspaceID: parentWorkspaceID,
            workspaceNamesByID: workspaceNamesByID
        )
    }

    private func handleWorkspaceButtonActivation(workspaceID: UUID, workspace: WorkspaceState) {
        if let currentEvent = NSApp.currentEvent,
           currentEvent.type == .leftMouseUp,
           currentEvent.clickCount == 2 {
            beginWorkspaceRename(workspace)
            return
        }

        cancelWorkspaceRename()
        store.selectWorkspace(
            windowID: windowID,
            workspaceID: workspaceID,
            preferringUnreadSessionPanelIn: sessionRuntimeStore
        )
    }

    private func focusSessionPanel(workspaceID: UUID, panelID: UUID) {
        cancelWorkspaceRename()
        _ = store.focusExplicitlyNavigatedPanel(
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID
        )
        terminalRuntimeContext.scheduleWorkspaceFocusRestore(
            workspaceID: workspaceID,
            avoidStealingKeyboardFocus: false
        )
    }

    private func beginWorkspaceRename(_ workspace: WorkspaceState) {
        renamingWorkspaceID = workspace.id
        renameDraftTitle = workspace.title
    }

    private func commitWorkspaceRename(workspaceID: UUID) {
        guard let workspace = store.state.workspacesByID[workspaceID] else {
            cancelWorkspaceRename()
            scheduleWorkspaceSlotFocusRestore()
            return
        }

        let trimmedTitle = renameDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.isEmpty == false else {
            renameDraftTitle = workspace.title
            cancelWorkspaceRename()
            scheduleWorkspaceSlotFocusRestore()
            return
        }

        _ = store.send(.renameWorkspace(workspaceID: workspaceID, title: trimmedTitle))
        cancelWorkspaceRename()
        scheduleWorkspaceSlotFocusRestore()
    }

    private func cancelWorkspaceRename() {
        renamingWorkspaceID = nil
        renameDraftTitle = ""
    }

    private func scheduleWorkspaceSlotFocusRestore() {
        guard let workspaceID = store.selectedWorkspace(in: windowID)?.id else { return }
        terminalRuntimeContext.scheduleWorkspaceFocusRestore(
            workspaceID: workspaceID,
            avoidStealingKeyboardFocus: false
        )
    }

    private func renameTextFieldAccessibilityID(for workspaceID: UUID) -> String {
        "sidebar.workspace.rename.\(workspaceID.uuidString)"
    }

    private func requestWorkspaceClose(workspaceID: UUID) {
        _ = store.requestWorkspaceClose(workspaceID: workspaceID)
    }

    private func scrollToSelectedWorkspace(
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard let selectedWorkspaceID else { return }
        scrollRequestObserver?(selectedWorkspaceID, animated)

        Task { @MainActor in
            if animated {
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(selectedWorkspaceID)
                }
            } else {
                proxy.scrollTo(selectedWorkspaceID)
            }
        }
    }

    private func scrollToSubspaceGroup(parentWorkspaceID: UUID, using proxy: ScrollViewProxy) {
        let target = SubspaceGroupScrollID(parentWorkspaceID: parentWorkspaceID)
        Task { @MainActor in
            if accessibilityReduceMotion {
                proxy.scrollTo(target)
            } else {
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(target)
                }
            }
        }
    }

    private func scrollToHiddenSession(
        _ pill: SidebarSessionPresentation.HiddenSessionPill,
        using proxy: ScrollViewProxy
    ) {
        guard let target = SidebarSessionPresentation.hiddenSessionScrollTarget(
            for: pill.direction,
            orderedWorkspaceIDs: store.state.topLevelWorkspaceIDs(in: windowID)
        ) else {
            return
        }

        Task { @MainActor in
            if accessibilityReduceMotion {
                proxy.scrollTo(target.workspaceID, anchor: target.anchor)
            } else {
                withAnimation(.easeInOut(duration: 0.16)) {
                    proxy.scrollTo(target.workspaceID, anchor: target.anchor)
                }
            }
        }
    }

    private func currentSidebarSessionRowIDs() -> [SidebarSessionPresentation.SidebarSessionRowID] {
        guard let window = store.window(id: windowID) else { return [] }

        return window.workspaceIDs.flatMap { workspaceID -> [SidebarSessionPresentation.SidebarSessionRowID] in
            guard store.state.workspacesByID[workspaceID] != nil else { return [] }

            return sidebarSessionStatuses(for: workspaceID)
                .map { status in
                    SidebarSessionPresentation.SidebarSessionRowID(
                        workspaceID: workspaceID,
                        sessionID: status.sessionID,
                        panelID: status.panelID
                    )
                }
        }
    }

    private func pruneTransientSidebarState() {
        if let renamingWorkspaceID,
           store.state.workspacesByID[renamingWorkspaceID] == nil {
            cancelWorkspaceRename()
        }
    }

    private func pruneSidebarSessionRowDiagnostics() {
        guard let window = store.window(id: windowID) else {
            sidebarSessionRowDiagnosticsByPanelID = [:]
            return
        }

        let activePanelIDs = Set(
            window.workspaceIDs.flatMap { workspaceID in
                sidebarSessionStatuses(for: workspaceID)
                    .map(\.panelID)
            }
        )
        sidebarSessionRowDiagnosticsByPanelID = sidebarSessionRowDiagnosticsByPanelID.filter {
            activePanelIDs.contains($0.key)
        }
    }

    private func pruneTransientWorkspaceDragState() {
        guard let window = store.window(id: windowID) else {
            measuredWorkspaceRowFramesByID = [:]
            scrollGeometry.sessionRowFrames = [:]
            scrollGeometry.subspaceFrames = [:]
            cancelWorkspaceDrag()
            return
        }

        let workspaceIDs = Set(window.workspaceIDs)
        measuredWorkspaceRowFramesByID = measuredWorkspaceRowFramesByID.filter { workspaceIDs.contains($0.key) }
        scrollGeometry.subspaceFrames = scrollGeometry.subspaceFrames.filter { workspaceIDs.contains($0.key.workspaceID) }
        let currentSessionRowIDs = Set(currentSidebarSessionRowIDs())
        scrollGeometry.sessionRowFrames = scrollGeometry.sessionRowFrames.filter { currentSessionRowIDs.contains($0.key) }
        if let activeWorkspaceDrag,
           workspaceIDs.contains(activeWorkspaceDrag.workspaceID) == false {
            cancelWorkspaceDrag()
        }
    }

    private func workspaceSubtitle(paneCount: Int) -> String {
        paneCount == 1 ? "1 pane" : "\(paneCount) panes"
    }

    private func showsUnreadSessionAccent(
        for panelID: UUID,
        in workspace: WorkspaceState
    ) -> Bool {
        SidebarSessionPresentation.showsUnreadSessionAccent(
            for: panelID,
            in: workspace,
            selectedWorkspaceID: store.selectedWorkspaceID(in: windowID),
            selectedPanelID: store.selectedWorkspace(in: windowID)?.focusedPanelID
        )
    }

    static func styledWorkspaceTitleText(
        _ text: String,
        isSelected: Bool,
        hasBeenVisited: Bool
    ) -> Text {
        Text(text).font(
            Font.system(
                size: 13,
                weight: SidebarSessionPresentation.workspaceTitleFontWeight(
                    isSelected: isSelected,
                    hasBeenVisited: hasBeenVisited
                )
            )
        )
    }

    // Weight stays inside the Font rather than a `.fontWeight(...)` chained
    // after `.italic()`: for these small labels SwiftUI can otherwise drop
    // the italic back to the upright face.

    /// Rows that want the user (ready, approval, error) set the name heavy;
    /// working rows set it italic.
    static func styledSessionNameText(_ text: String, isEmphasized: Bool, isItalic: Bool = false) -> Text {
        let base = Text(text).font(ToastyTheme.workspaceSessionNameFont(
            weight: SidebarSessionPresentation.sessionNameFontWeight(isEmphasized: isEmphasized)
        ))
        return isItalic ? base.italic() : base
    }

    /// Every agent summary in the sidebar and its hover cards uses this face.
    /// Summaries carry provider Markdown; names and titles do not.
    static func styledSessionSummaryText(_ text: String, isItalic: Bool = false) -> Text {
        let base = Text(SidebarSessionPresentation.sessionSummaryAttributedText(text)).font(ToastyTheme.fontSidebarSummary)
        return isItalic ? base.italic() : base
    }

    @ViewBuilder
    private func workspaceAgentCountBadge(_ summary: WorkspaceAgentSummary) -> some View {
        workspaceAgentCountBadgeContent(summary)
    }

    private func workspaceAgentCountBadgeContent(_ summary: WorkspaceAgentSummary) -> some View {
        HStack(spacing: summary.hasActive ? 4 : 0) {
            if summary.hasActive {
                SessionStatusIndicator(state: .spinner, size: 8, lineWidth: 1.4)
            }

            Text("\(summary.active)/\(summary.running)")
                .foregroundStyle(ToastyTheme.inactiveText)
        }
        .font(ToastyTheme.fontWorkspaceAgentCount)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(
            summary.hasActive ? ToastyTheme.workspaceAgentCountActiveBackground : ToastyTheme.hairline,
            in: Capsule()
        )
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SidebarSessionPresentation.workspaceAgentSummaryAccessibilityLabel(summary))
        .accessibilityIdentifier("sidebar.workspace.agentCount")
    }
}

private struct SidebarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

struct WorkspaceHeaderSubtitleText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(ToastyTheme.fontWorkspaceAgentCount)
            .foregroundStyle(ToastyTheme.inactiveText)
            .lineLimit(1)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }
}

private enum SidebarWorkspaceListCoordinateSpace {
    static let name = "sidebar-workspaces.list"
}

private enum SidebarWorkspaceViewportCoordinateSpace {
    static let name = "sidebar-workspaces.viewport"
}

private struct WorkspaceRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct SidebarSubspaceFramePreferenceKey: PreferenceKey {
    static let defaultValue: [SidebarSubspaceFrameID: CGRect] = [:]

    static func reduce(
        value: inout [SidebarSubspaceFrameID: CGRect],
        nextValue: () -> [SidebarSubspaceFrameID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct SidebarSessionRowCompactHelpTextPreferenceKey: PreferenceKey {
    static let defaultValue: String? = nil

    static func reduce(value: inout String?, nextValue: () -> String?) {
        value = nextValue() ?? value
    }
}

private struct SidebarSessionRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [SidebarSessionPresentation.SidebarSessionRowID: CGRect] = [:]

    static func reduce(
        value: inout [SidebarSessionPresentation.SidebarSessionRowID: CGRect],
        nextValue: () -> [SidebarSessionPresentation.SidebarSessionRowID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct SidebarSessionDisclosureAnchorKey: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

private struct SidebarSessionGroupFramePreferenceKey: PreferenceKey {
    static let defaultValue: [SidebarSessionPresentation.SidebarSessionRowID: CGRect] = [:]

    static func reduce(
        value: inout [SidebarSessionPresentation.SidebarSessionRowID: CGRect],
        nextValue: () -> [SidebarSessionPresentation.SidebarSessionRowID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// A shortcut such as "⌥3" that the sidebar shows beside the control it
/// opens while Option is held.
struct SidebarShortcutBadge: View {
    let label: String
    var highlighted = true

    var body: some View {
        Text(label)
            .font(ToastyTheme.fontShortcutBadge)
            .foregroundStyle(highlighted ? ToastyTheme.shortcutBadgeText : ToastyTheme.subtleText)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                ToastyTheme.hairline.opacity(highlighted ? 1 : 0.55),
                in: RoundedRectangle(cornerRadius: 3)
            )
            .animation(.easeOut(duration: 0.12), value: highlighted)
    }
}
