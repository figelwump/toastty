import RemoteProtocol
import AppKit
import CoreState
import SwiftUI

private struct SidebarSemanticTextBridge: NSViewRepresentable {
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
private struct SidebarCappedIntrinsicWidthLayout: Layout {
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
        scheduleRefresh()
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
        guard let clipView = enclosingScrollView?.contentView else { return }

        if observedClipView !== clipView {
            observedClipView = clipView
            lastReportedHeight = nil
            boundsObservation = clipView.observe(\.bounds, options: [.new]) { [weak self] _, change in
                guard let height = change.newValue?.height else { return }
                Task { @MainActor [weak self] in
                    self?.reportHeight(height)
                }
            }
        }

        reportHeight(clipView.bounds.height)
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
    let terminalRuntimeContext: TerminalWindowRuntimeContext
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
    @State private var hoveredPanelID: UUID?
    @State private var hoveredWorkspaceID: UUID?
    @State private var flashingWorkspaceID: UUID?
    @State private var flashingSessionPanelID: UUID?
    @State private var flashingSessionOverlayOpacity = 0.0
    @State private var activeSidebarFlashRequestID: UUID?
    @State private var lastHandledSidebarFlashRequestID: UUID?
    @State private var sidebarFlashClearWorkItem: DispatchWorkItem?
    @State private var sidebarFlashResetWorkItem: DispatchWorkItem?
    @State private var activeSessionDrag: SessionDragState?
    @State private var sessionPointerRowID: SidebarSessionPresentation.SidebarSessionRowID?
    @State private var measuredSessionGroupFrames: [SidebarSessionPresentation.SidebarSessionRowID: CGRect] = [:]
    @State private var activeWorkspaceDrag: WorkspaceDragState?
    @State private var measuredWorkspaceRowFramesByID: [UUID: CGRect] = [:]
    @State private var measuredSessionRowFramesByID: [SidebarSessionPresentation.SidebarSessionRowID: CGRect] = [:]
    @State private var sidebarWorkspaceListViewportHeight: CGFloat = 0
    @State private var sidebarSessionRowDiagnosticsByPanelID: [UUID: SidebarSessionRowDiagnosticState] = [:]
    @State private var expandedSessionChildrenBySessionID: [String: Bool] = [:]
    @State private var collapsedSubspaceGroupParentIDs: Set<UUID> = []
    /// Spawning session whose subspaces the group shows, per parent workspace.
    @State private var subspaceFilterSessionIDByParentID: [UUID: String] = [:]
    /// Row order captured when the pointer entered a group, so rows hold
    /// still under the pointer; released on exit.
    @State private var frozenSubspaceOrderByParentID: [UUID: [UUID]] = [:]
    @State private var hoveredSpawnerSessionID: String?
    @State private var hoveredSubspaceID: UUID?
    @State private var optionKeyPressed = false

    /// Fixed height for the session detail text area (1 line at the detail
    /// font size). Reserving a constant height prevents the sidebar from
    /// jittering as streaming summaries change length.
    private static let sessionDetailFixedHeight: CGFloat = {
        // 10pt system font default line height ≈ 12pt; 1 line.
        let font = NSFont.systemFont(ofSize: 10, weight: .regular)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return lineHeight
    }()
    private static let sessionStatusesTopSpacing: CGFloat = 0
    /// The status rail keeps this width whether or not it has an indicator, so
    /// row text stays aligned down the list.
    private static let sessionStatusRailWidth: CGFloat = 12
    private static let sessionStatusRailGap: CGFloat = 6
    private static let sessionStatusRailDotSize: CGFloat = 7
    /// The rail's second slot, under the status one, for a standing mark on the
    /// session: the later flag or the watch bell. Short enough that a two-line
    /// row is still taller than the rail, so the rail never sets row height.
    private static let sessionStatusRailMarkerSlotHeight: CGFloat = 13
    private static let sessionStatusRailSlotSpacing: CGFloat = 2
    private static let sessionRailFlagFontSize: CGFloat = 9
    /// `bell.fill` carries less ink than `flag.fill`, so it needs a larger
    /// point size to read at the same weight.
    private static let sessionRailWatchFontSize: CGFloat = 10.5
    /// Elapsed time sits among the accessories `ViewThatFits` measures, and its
    /// text changes every second. A floor wide enough for `00m 00s` keeps each
    /// candidate line's measured width constant, so a tick cannot re-measure
    /// the row or flip a chip in and out at a width boundary.
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
    /// Rows sit 10pt inside the sidebar's trailing edge, so this clears that
    /// inset and leaves a small gap over the terminal.
    private static let sessionHoverTipTrailingGap: CGFloat = 16
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
        terminalRuntimeContext: TerminalWindowRuntimeContext,
        scrollRequestObserver: ((UUID, Bool) -> Void)? = nil,
        workspaceRowFrameObserver: (([UUID: CGRect]) -> Void)? = nil,
        workspaceViewportHeightObserver: ((CGFloat) -> Void)? = nil
    ) {
        self.windowID = windowID
        self.store = store
        self.terminalRuntimeRegistry = terminalRuntimeRegistry
        self.sessionRuntimeStore = sessionRuntimeStore
        self.annotationStyleStore = annotationStyleStore
        self.terminalRuntimeContext = terminalRuntimeContext
        self.scrollRequestObserver = scrollRequestObserver
        self.workspaceRowFrameObserver = workspaceRowFrameObserver
        self.workspaceViewportHeightObserver = workspaceViewportHeightObserver
    }

    private var selectedWorkspaceID: UUID? {
        store.selectedWorkspaceID(in: windowID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if store.window(id: windowID) != nil {
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
                                        isSelected: selectedWorkspaceID == workspaceID,
                                        index: index + 1,
                                        orderedWorkspaceIDs: topLevelWorkspaceIDs
                                    )
                                    .id(workspaceID)
                                }
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
                            sidebarWorkspaceListViewportHeight = height
                            workspaceViewportHeightObserver?(height)
                        }
                    }
                    .onPreferenceChange(WorkspaceRowFramePreferenceKey.self) { framesByID in
                        measuredWorkspaceRowFramesByID = framesByID
                        workspaceRowFrameObserver?(framesByID)
                    }
                    .onPreferenceChange(SidebarSessionRowFramePreferenceKey.self) { framesByID in
                        measuredSessionRowFramesByID = framesByID
                    }
                    .onPreferenceChange(SidebarSessionGroupFramePreferenceKey.self) { frames in
                        measuredSessionGroupFrames = frames
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
                    sidebarTitlebarCover
                }
                .overlay(alignment: .top) {
                    hiddenSessionPill(sidebarHiddenSessionPillState.above, using: proxy)
                }
                .overlay(alignment: .bottom) {
                    hiddenSessionPill(sidebarHiddenSessionPillState.below, using: proxy)
                }
                .onAppear {
                    scrollToSelectedWorkspace(using: proxy, animated: false)
                }
                .onChange(of: selectedWorkspaceID) { _, _ in
                    revealSelectedSubspaceIfNeeded()
                    scrollToSelectedWorkspace(using: proxy, animated: true)
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
                  workspace.parentWorkspaceID == nil else { return }
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

    private var sidebarTitlebarCover: some View {
        Rectangle()
            .fill(ToastyTheme.chromeBackground)
            .frame(maxWidth: .infinity)
            .frame(height: ToastyTheme.sidebarTopPadding)
            .allowsHitTesting(false)
    }

    private var sidebarHiddenSessionPillState: SidebarSessionPresentation.HiddenSessionPillState {
        guard activeWorkspaceDrag == nil, activeSessionDrag == nil else { return .empty }

        return SidebarSessionPresentation.hiddenSessionPillState(
            orderedSessionRowIDs: currentSidebarSessionRowIDs(),
            measuredSessionRowFramesByID: measuredSessionRowFramesByID,
            unreadSessionRowIDs: currentUnreadSidebarSessionRowIDs(),
            workingSessionRowIDs: currentWorkingSidebarSessionRowIDs(),
            viewportHeight: sidebarWorkspaceListViewportHeight,
            visibleTop: ToastyTheme.sidebarTopPadding
        )
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
        orderedWorkspaceIDs: [UUID]
    ) -> some View {
        let row = Group {
            if renamingWorkspaceID == workspaceID {
                workspaceRenameRow(
                    workspaceID: workspaceID,
                    workspace: workspace,
                    shortcutLabel: shortcutLabel,
                    isSelected: isSelected,
                    sourceIndex: index - 1,
                    orderedWorkspaceIDs: orderedWorkspaceIDs
                )
            } else {
                workspaceButton(
                    workspaceID: workspaceID,
                    workspace: workspace,
                    shortcutLabel: shortcutLabel,
                    isSelected: isSelected,
                    sourceIndex: index - 1,
                    orderedWorkspaceIDs: orderedWorkspaceIDs
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
        orderedWorkspaceIDs: [UUID]
    ) -> some View {
        let sessionStatuses = sidebarSessionStatuses(for: workspace.id)
        let subspaceRows = subspaceRows(for: workspace.id, parentSessionStatuses: sessionStatuses)
        let agentSummary = WorkspaceAgentSummary.make(from: sessionStatuses, workspaceID: workspace.id)
        let accessibilityLabel = SidebarSessionPresentation.workspaceAccessibilityLabel(
            for: workspace,
            isSelected: isSelected,
            agentSummary: agentSummary
        )

        return workspaceRowChrome(
            workspaceID: workspaceID,
            isSelected: isSelected,
            isFlashing: flashingWorkspaceID == workspaceID
        ) {
            VStack(alignment: .leading, spacing: 0) {
                workspaceHeaderContent {
                    workspacePrimaryContent(
                        workspace: workspace,
                        shortcutLabel: shortcutLabel,
                        selectionSubtitle: nil,
                        isSelected: isSelected,
                        agentSummary: agentSummary
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

                // Rendered below and outside the title header's AppKit
                // pointer-interaction overlay: workspace drag keeps starting
                // from the title region while link chips stay real buttons.
                workspaceAnnotationChipsRow(workspace: workspace)

                if !sessionStatuses.isEmpty {
                    sessionStatusesContent(sessionStatuses, workspace: workspace, subspaceRows: subspaceRows)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 14)
                }

                subspacesGroup(subspaceRows, parentWorkspaceID: workspace.id)
            }
        }
    }

    private func workspaceRenameRow(
        workspaceID: UUID,
        workspace: WorkspaceState,
        shortcutLabel: String?,
        isSelected: Bool,
        sourceIndex _: Int,
        orderedWorkspaceIDs _: [UUID]
    ) -> some View {
        let sessionStatuses = sidebarSessionStatuses(for: workspace.id)
        let subspaceRows = subspaceRows(for: workspace.id, parentSessionStatuses: sessionStatuses)
        let agentSummary = WorkspaceAgentSummary.make(from: sessionStatuses, workspaceID: workspace.id)

        return workspaceRowChrome(
            workspaceID: workspaceID,
            isSelected: isSelected,
            isFlashing: flashingWorkspaceID == workspaceID
        ) {
            VStack(alignment: .leading, spacing: 0) {
                workspaceHeaderContent {
                    workspacePrimaryContent(
                        workspace: workspace,
                        shortcutLabel: shortcutLabel,
                        selectionSubtitle: nil,
                        isSelected: isSelected,
                        agentSummary: agentSummary
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
                workspaceAnnotationChipsRow(workspace: workspace)
                if !sessionStatuses.isEmpty {
                    sessionStatusesContent(sessionStatuses, workspace: workspace, subspaceRows: subspaceRows)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 14)
                }
                subspacesGroup(subspaceRows, parentWorkspaceID: workspace.id)
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
    private func workspaceAnnotationChip(key: String, annotation: WorkspaceAnnotation) -> some View {
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
                    isLink: true
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
                isLink: false
            )
                .background {
                    SidebarTooltipBridge(text: annotation.text)
                        .allowsHitTesting(false)
                }
                .accessibilityHidden(true)
        }
    }

    static func workspaceAnnotationChipLabel(
        annotation: WorkspaceAnnotation,
        chipColors: ToastyTheme.AnnotationChipColors,
        isLink: Bool
    ) -> some View {
        SidebarCappedIntrinsicWidthLayout(maximumWidth: 160) {
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
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? ToastyTheme.elevatedBackground
                : activeWorkspaceDrag == nil && hoveredWorkspaceID == workspaceID ? ToastyTheme.elevatedBackground
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
                    hoveredWorkspaceID = workspaceID
                } else if hoveredWorkspaceID == workspaceID {
                    hoveredWorkspaceID = nil
                }
            }
    }

    private func workspaceHeaderContent<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private func workspacePrimaryContent<Title: View>(
        workspace: WorkspaceState,
        shortcutLabel: String?,
        selectionSubtitle: String?,
        isSelected: Bool,
        agentSummary: WorkspaceAgentSummary?,
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

                if let agentSummary, agentSummary.hasRunning {
                    workspaceAgentCountBadge(agentSummary)
                }

                if optionKeyPressed, let shortcutLabel {
                    shortcutBadge(shortcutLabel, highlighted: true)
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

    @ViewBuilder
    private func sessionStatusesContent(
        _ workspaceSessionStatuses: [WorkspaceSessionStatus],
        workspace: WorkspaceState,
        subspaceRows: [SidebarSubspacePresentation.Row] = []
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(workspaceSessionStatuses, id: \.sessionID) { workspaceSessionStatus in
                sessionStatusContent(
                    hidingSubspaceChildren(workspaceSessionStatus, subspaceRows: subspaceRows),
                    workspace: workspace,
                    isHovered: hoveredPanelID == workspaceSessionStatus.panelID,
                    spawnerChip: SidebarSubspacePresentation.spawnerChip(
                        sessionID: workspaceSessionStatus.sessionID,
                        rows: subspaceRows,
                        activeFilterSessionID: subspaceFilterSessionIDByParentID[workspace.id]
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Self.sessionStatusesTopSpacing)
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
        spawnerChip: SidebarSubspacePresentation.SpawnerChip? = nil
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
        let parentSessionName = parentSessionName(for: workspaceSessionStatus, in: workspace.id)
        let customTabTitle = SidebarSessionPresentation.sessionCustomTabTitle(
            for: workspaceSessionStatus,
            in: store.state.workspacesByID[workspaceSessionStatus.workspaceID]
        )
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
            customTabTitle: customTabTitle,
            parentSessionName: parentSessionName,
            isLaterFlagged: isLaterFlagged,
            effectiveScopedWorkspaceIDs: workspaceSessionStatus.effectiveScopedWorkspaceIDs,
            sessionName: workspaceSessionStatus.sessionName
        )
        let rowShape = SidebarSessionPresentation.sessionRowShape(
            sessionName: workspaceSessionStatus.sessionName,
            summary: normalizedSessionDetail(status.detail),
            agentFallbackName: workspaceSessionStatus.agent.displayName
        )
        // Rows no longer show the scope tag or the working directory; the
        // accessibility label keeps both so VoiceOver loses nothing.
        let accessibilityLabel = SidebarSessionPresentation.sessionAccessibilityLabel(
            agentName: workspaceSessionStatus.displayTitle,
            chipKind: chipKind,
            projection: workspaceSessionStatus.projection,
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
            workspaceSessionStatus,
            status: status,
            projection: workspaceSessionStatus.projection,
            rowShape: rowShape,
            isLaterFlagged: isLaterFlagged,
            showsUnreadSessionAccent: showsUnreadSessionAccent,
            isActivePanel: isActivePanel,
            isHovered: isHovered,
            isFlashing: isFlashing,
            childCount: workspaceSessionStatus.children.count,
            childRowsExpanded: childRowsExpanded,
            collapsedChildNeedsAttention: collapsedChildNeedsAttention,
            parentSessionName: parentSessionName,
            customTabTitle: customTabTitle,
            spawnerChip: spawnerChip,
            onToggleChildRows: {
                toggleSessionChildRows(sessionID: workspaceSessionStatus.sessionID)
            },
            onToggleSpawnerFilter: {
                toggleSubspaceFilter(
                    parentWorkspaceID: workspace.id,
                    spawningSessionID: workspaceSessionStatus.sessionID
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
                    placement: .trailing(gap: Self.sessionHoverTipTrailingGap),
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
                        parentWorkspaceID: workspace.id,
                        spawningSessionID: workspaceSessionStatus.sessionID
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
                    named: Text(SidebarSubspacePresentation.spawnerFilterActionTitle(isFilterActive: spawnerChip.isFilterActive)),
                    spawnerFilterAction
                )
        } else {
            withChildAction
        }
    }

    private func sessionStatusLabel(
        _ workspaceSessionStatus: WorkspaceSessionStatus,
        status: SessionStatus,
        projection: SessionStatusProjection,
        rowShape: SidebarSessionPresentation.SessionRowShape,
        isLaterFlagged: Bool,
        showsUnreadSessionAccent: Bool,
        isActivePanel: Bool,
        isHovered: Bool,
        isFlashing: Bool,
        childCount: Int,
        childRowsExpanded: Bool,
        collapsedChildNeedsAttention: Bool,
        parentSessionName: String?,
        customTabTitle: String?,
        spawnerChip: SidebarSubspacePresentation.SpawnerChip? = nil,
        onToggleChildRows: @escaping () -> Void,
        onToggleSpawnerFilter: @escaping () -> Void = {},
        onHoverSpawnerChip: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        let railState = SidebarSessionPresentation.sessionRailState(
            for: status.kind,
            showsUnreadSessionAccent: showsUnreadSessionAccent
        )
        let borderColor = sessionStatusBorderColor(
            showsUnreadSessionAccent: showsUnreadSessionAccent,
            isHovered: isHovered
        )
        let flashOpacity = isFlashing ? flashingSessionOverlayOpacity : 0
        let agentLabel = SidebarSessionPresentation.showsSessionAgentLabel(
            shape: rowShape,
            agentFallbackName: workspaceSessionStatus.agent.displayName
        ) ? SidebarSessionPresentation.sessionAgentLabel(for: workspaceSessionStatus.agent) : nil

        let railMarker: SessionRailMarker? = if isLaterFlagged {
            .laterFlag
        } else if workspaceSessionStatus.agent == .processWatch {
            .processWatch
        } else {
            nil
        }
        let accessories = SessionRowAccessoryModel(
            chipKind: SidebarSessionPresentation.sessionStatusChipKind(
                for: status,
                showsUnreadSessionAccent: showsUnreadSessionAccent
            ),
            waitingChipLabel: SidebarSessionPresentation.sessionStatusProjectionChipLabel(for: projection),
            turnStartedAt: workspaceSessionStatus.turnStartedAt,
            parentTagLabel: parentSessionName.map(
                SidebarSessionPresentation.parentSessionTagLabel(parentName:)
            ),
            parentSessionName: parentSessionName,
            childCount: childCount,
            childRowsExpanded: childRowsExpanded,
            collapsedChildNeedsAttention: collapsedChildNeedsAttention,
            spawnerChip: spawnerChip,
            onToggleSpawnerFilter: onToggleSpawnerFilter,
            onHoverSpawnerChip: onHoverSpawnerChip
        )
        let hasParentTag = parentSessionName != nil
        let hasWaitingChip = accessories.waitingChipLabel != nil

        // Drop the parent tag, then the waiting chip, then the tab pill, when
        // the tab line does not fit at its ideal width. Truncating them
        // instead leaves stubs like "↖ Cl…" and an empty pill, because the
        // stack reserves every chip's minimum width before layout priority
        // applies. The hover card still carries all three.
        let tabLine = { (showsParentTag: Bool, showsWaitingChip: Bool, showsTabPill: Bool) in
            sessionRowTabLine(
                customTabTitle: showsTabPill ? customTabTitle : nil,
                agentLabel: agentLabel,
                accessories: accessories,
                showsParentTag: showsParentTag,
                showsWaitingChip: showsWaitingChip,
                onToggleChildRows: onToggleChildRows
            )
        }

        return HStack(alignment: .top, spacing: Self.sessionStatusRailGap) {
            sessionStatusRail(railState, marker: railMarker)

            VStack(alignment: .leading, spacing: 2) {
                switch rowShape {
                case .named(let name, let summary):
                    sessionRowTitleLine(
                        name: name,
                        statusKind: status.kind,
                        showsUnreadSessionAccent: showsUnreadSessionAccent
                    )

                    // Reserved even without a summary yet, so named rows keep
                    // one height and the list does not reflow as summaries
                    // arrive.
                    sessionDetailLabel(
                        summary ?? " ",
                        statusKind: status.kind,
                        showsUnreadSessionAccent: showsUnreadSessionAccent,
                        isResuming: projection == .resuming
                    )

                case .summaryFirst(let summary):
                    sessionRowPrimaryLabel(
                        summary,
                        statusKind: status.kind,
                        showsUnreadSessionAccent: showsUnreadSessionAccent,
                        isResuming: projection == .resuming
                    )
                }

                ViewThatFits(in: .horizontal) {
                    if hasParentTag {
                        tabLine(true, hasWaitingChip, true)
                    }
                    if hasWaitingChip {
                        tabLine(false, true, true)
                    }
                    tabLine(false, false, true)
                    tabLine(false, false, false)
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .backgroundPreferenceValue(SidebarSessionRowCompactHelpTextPreferenceKey.self) { compactHelpText in
            // When the chosen header variant dropped a tag, the whole row's
            // tooltip carries that tag's information.
            if let compactHelpText {
                SidebarTooltipBridge(text: compactHelpText)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(
                    sessionStatusBackgroundColor(
                        showsUnreadSessionAccent: showsUnreadSessionAccent,
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
                .stroke(borderColor, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(ToastyTheme.accent.opacity(flashOpacity), lineWidth: 1.75)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5))
    }

    /// The trailing accessories a session row shows at the end of whichever
    /// line carries them: the first line for a named row, the tab line for a
    /// row the provider has not named yet.
    private struct SessionRowAccessoryModel {
        let chipKind: SessionStatusKind?
        let waitingChipLabel: String?
        let turnStartedAt: Date?
        let parentTagLabel: String?
        let parentSessionName: String?
        let childCount: Int
        let childRowsExpanded: Bool
        let collapsedChildNeedsAttention: Bool
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
        Group {
            switch state {
            case .empty:
                Color.clear
            case .spinner:
                SessionStatusIndicator(state: .spinner, size: 9, lineWidth: 1.4)
            case .approvalDot:
                Circle()
                    .fill(ToastyTheme.sessionNeedsApprovalText)
                    .frame(width: Self.sessionStatusRailDotSize, height: Self.sessionStatusRailDotSize)
                    .overlay {
                        Circle()
                            .stroke(ToastyTheme.sidebarSessionRailApprovalHalo, lineWidth: 3)
                    }
            case .unreadDot:
                Circle()
                    .fill(ToastyTheme.sessionReadyText)
                    .frame(width: Self.sessionStatusRailDotSize, height: Self.sessionStatusRailDotSize)
            case .errorDot:
                Circle()
                    .fill(ToastyTheme.sessionErrorText)
                    .frame(width: Self.sessionStatusRailDotSize, height: Self.sessionStatusRailDotSize)
            }
        }
        .frame(width: Self.sessionStatusRailWidth, height: Self.sessionRowLineMinHeight)
    }

    private func sessionStatusRailMarkerSlot(_ marker: SessionRailMarker) -> some View {
        Group {
            switch marker {
            case .laterFlag:
                Image(systemName: "flag.fill")
                    .font(.system(size: Self.sessionRailFlagFontSize, weight: .semibold))
                    .foregroundStyle(ToastyTheme.sidebarSessionLaterFlag)
            case .processWatch:
                Image(systemName: "bell.fill")
                    .font(.system(size: Self.sessionRailWatchFontSize, weight: .semibold))
                    .foregroundStyle(ToastyTheme.sidebarSessionWatchIcon)
            }
        }
        .frame(width: Self.sessionStatusRailWidth, height: Self.sessionStatusRailMarkerSlotHeight)
    }

    @ViewBuilder
    private func sessionRowAccessories(
        _ model: SessionRowAccessoryModel,
        showsParentTag: Bool,
        showsWaitingChip: Bool,
        onToggleChildRows: @escaping () -> Void
    ) -> some View {
        if let chipKind = model.chipKind {
            sessionStatusChip(kind: chipKind)
                .layoutPriority(2)
        }

        // The waiting and parent chips keep the default layout priority so
        // they give up width before the name, status badge, and disclosure
        // pill. Do not lower them below the spacer: a lower priority lets the
        // spacer starve them of width even when the row has room.
        if model.waitingChipLabel != nil, showsWaitingChip {
            sessionWaitingChip()
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
                    .frame(minWidth: Self.sessionElapsedMinimumWidth, alignment: .trailing)
            }
            .accessibilityHidden(true)
        }

        if let parentTagLabel = model.parentTagLabel, showsParentTag {
            sessionParentTag(label: parentTagLabel)
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

    /// Identity only. Status, times and controls all live on the tab line, so
    /// the name gets the row's full width and both row shapes put the badge in
    /// the same place.
    private func sessionRowTitleLine(
        name: String,
        statusKind: SessionStatusKind,
        showsUnreadSessionAccent: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Self.styledSessionNameText(
                name,
                statusKind: statusKind,
                showsUnreadSessionAccent: showsUnreadSessionAccent
            )
                .foregroundStyle(ToastyTheme.sidebarSessionAgentText)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .frame(minHeight: Self.sessionRowLineMinHeight)
    }

    /// The tab pill, the agent label, and every trailing accessory: the status
    /// badge, the waiting chip, elapsed time, a parent tag and the sub-agent
    /// disclosure pill. Both row shapes end on this line.
    private func sessionRowTabLine(
        customTabTitle: String?,
        agentLabel: String?,
        accessories: SessionRowAccessoryModel,
        showsParentTag: Bool,
        showsWaitingChip: Bool,
        onToggleChildRows: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            if let customTabTitle {
                sessionTabPill(title: customTabTitle)
            }

            if let agentLabel {
                Text(agentLabel)
                    .font(ToastyTheme.fontWorkspaceSessionAgentLabel)
                    .foregroundStyle(ToastyTheme.sidebarChildContextText)
                    .lineLimit(1)
                    .fixedSize()
            }

            Spacer(minLength: 0)

            sessionRowAccessories(
                accessories,
                showsParentTag: showsParentTag,
                showsWaitingChip: showsWaitingChip,
                onToggleChildRows: onToggleChildRows
            )
        }
        .frame(minHeight: Self.sessionRowSecondaryLineMinHeight)
        .preference(
            key: SidebarSessionRowCompactHelpTextPreferenceKey.self,
            value: Self.sessionRowCompactHelpText(
                accessories,
                showsParentTag: showsParentTag,
                showsWaitingChip: showsWaitingChip
            )
        )
    }

    private static func sessionRowCompactHelpText(
        _ accessories: SessionRowAccessoryModel,
        showsParentTag: Bool,
        showsWaitingChip: Bool
    ) -> String? {
        SidebarSessionPresentation.sessionRowCompactHelpText(
            parentSessionName: showsParentTag ? nil : accessories.parentSessionName,
            workspaceScopeHelpText: nil,
            droppedWaitingChipLabel: showsWaitingChip ? nil : accessories.waitingChipLabel
        )
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

    private func sessionTabPill(title: String) -> some View {
        Text(title)
            .font(ToastyTheme.fontWorkspaceSessionChip)
            .foregroundStyle(ToastyTheme.sidebarSessionPathText)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                ToastyTheme.sidebarSessionTabPillBackground,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(ToastyTheme.sidebarSessionTabPillBorder, lineWidth: 1)
            }
            .background {
                // The row is one accessibility element, so the pill's own text
                // is otherwise invisible to AppKit inspectors and host tests.
                SidebarSemanticTextBridge(text: title)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
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
        let previousPanelID = hoveredPanelID
        let ignored = activeWorkspaceDrag != nil || activeSessionDrag != nil
        defer {
            SidebarHoverDiagnostics.log(ignored ? "sidebar-hover-ignored" : "sidebar-hover-accepted", metadata: [
                "windowID": windowID.uuidString,
                "workspaceID": rowID.workspaceID.uuidString,
                "sessionID": rowID.sessionID,
                "panelID": panelID.uuidString,
                "incomingHover": String(isHovering),
                "previousHoveredPanelID": previousPanelID?.uuidString ?? "none",
                "hoveredPanelID": hoveredPanelID?.uuidString ?? "none",
                "changed": String(previousPanelID != hoveredPanelID),
                "workspaceDragActive": String(activeWorkspaceDrag != nil),
                "sessionDragActive": String(activeSessionDrag != nil),
            ])
        }
        guard ignored == false else { return }
        if isHovering {
            hoveredPanelID = panelID
        } else if hoveredPanelID == panelID {
            hoveredPanelID = nil
        }
    }

    private func logSessionHoverClear(reason: String) {
        guard hoveredPanelID != nil else { return }
        SidebarHoverDiagnostics.log("sidebar-hover-cleared", metadata: [
            "windowID": windowID.uuidString,
            "previousHoveredPanelID": hoveredPanelID?.uuidString ?? "none",
            "hoveredPanelID": "none",
            "reason": reason,
        ])
    }

    private func sessionDropTarget(
        rowID: SidebarSessionPresentation.SidebarSessionRowID,
        value: PointerInteractionValue
    ) -> SidebarSessionPresentation.SessionDropTarget? {
        guard let parentFrame = measuredSessionRowFramesByID[rowID] else { return nil }
        let rows = currentSidebarSessionRowIDs().filter { $0.workspaceID == rowID.workspaceID }
        return SidebarSessionPresentation.sessionDropTarget(
            orderedRowIDs: rows,
            frames: measuredSessionGroupFrames,
            source: rowID,
            pointer: CGPoint(x: parentFrame.minX + value.location.x, y: parentFrame.minY + value.location.y),
            viewportHeight: sidebarWorkspaceListViewportHeight
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
        logSessionHoverClear(reason: "session-drag")
        hoveredPanelID = nil
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
        measuredSessionGroupFrames = measuredSessionGroupFrames.filter { currentRows.contains($0.key) }
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

        hoveredWorkspaceID = nil
        logSessionHoverClear(reason: "workspace-drag")
        hoveredPanelID = nil

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

    private func sessionStatusBackgroundColor(
        showsUnreadSessionAccent: Bool,
        isActivePanel: Bool,
        isHovered: Bool
    ) -> Color {
        if isActivePanel {
            return isHovered ? ToastyTheme.sidebarSessionActiveHoverBackground
                : ToastyTheme.sidebarSessionActiveBackground
        }
        if showsUnreadSessionAccent {
            return ToastyTheme.sidebarSessionUnreadBackground
        }
        return isHovered ? ToastyTheme.sidebarSessionHoverBackground : Color.clear
    }

    private func sessionStatusBorderColor(
        showsUnreadSessionAccent: Bool,
        isHovered: Bool
    ) -> Color {
        if showsUnreadSessionAccent {
            return ToastyTheme.sidebarSessionUnreadBorder
        }
        return isHovered ? ToastyTheme.sidebarSessionHoverBorder : Color.clear
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

    private func sessionStatusChip(kind: SessionStatusKind) -> some View {
        let badgeLabel = SidebarSessionPresentation.sessionStatusBadgeLabel(for: kind)

        return Text(badgeLabel)
            .font(ToastyTheme.fontWorkspaceSessionChip)
            .foregroundStyle(ToastyTheme.sessionStatusTextColor(for: kind))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                ToastyTheme.sessionStatusBackgroundColor(for: kind),
                in: RoundedRectangle(cornerRadius: 4)
            )
            .background {
                // The row is one accessibility element and carries the spoken
                // wording, so the badge's shortened text is otherwise
                // invisible to AppKit inspectors and host-based tests.
                SidebarSemanticTextBridge(text: badgeLabel)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
    }

    private func sessionWaitingChip() -> some View {
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
        .hoverTip(id: child.sidebarStableID, refreshID: hoverTipModel) {
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
                Text(context)
                    .font(ToastyTheme.fontWorkspaceSessionChildContext)
                    .foregroundStyle(ToastyTheme.sidebarChildContextText)
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

    @ViewBuilder
    private func sessionDetailLabel(
        _ text: String,
        statusKind: SessionStatusKind,
        showsUnreadSessionAccent: Bool,
        isResuming: Bool = false
    ) -> some View {
        // Keep weight inside the Font itself instead of chaining
        // `.fontWeight(...)` after `.italic()`. For these small sidebar labels,
        // SwiftUI can otherwise collapse the italicized detail text back to the
        // upright face.
        let styled = Self.styledSessionDetailText(
            text,
            statusKind: statusKind,
            showsUnreadSessionAccent: showsUnreadSessionAccent
        )

        // Fixed 2-line height prevents sidebar jitter as summaries
        // stream in at varying lengths. The placeholder sets the
        // intrinsic height; the real text overlays it.
        styled
            .foregroundStyle(
                isResuming
                    ? ToastyTheme.sessionResumingDetailText
                    : ToastyTheme.sidebarSessionDetailText
            )
            .lineLimit(1)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .frame(
                maxWidth: .infinity,
                minHeight: Self.sessionDetailFixedHeight,
                alignment: .topLeading
            )
    }

    /// The summary promoted to the first line of a row the provider has not
    /// named yet. It reads as the row's title, so it uses the title weight.
    private func sessionRowPrimaryLabel(
        _ text: String,
        statusKind: SessionStatusKind,
        showsUnreadSessionAccent: Bool,
        isResuming: Bool
    ) -> some View {
        Self.styledSessionPrimaryText(
            text,
            statusKind: statusKind,
            showsUnreadSessionAccent: showsUnreadSessionAccent
        )
        .foregroundStyle(
            isResuming
                ? ToastyTheme.sessionResumingDetailText
                : ToastyTheme.sidebarSessionAgentText
        )
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(
            maxWidth: .infinity,
            minHeight: Self.sessionRowLineMinHeight,
            alignment: .leading
        )
    }

    private func normalizedSessionDetail(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Subspaces

    /// Sub-agent rows that live in one of this workspace's subspaces are
    /// represented by the ⑂ chip and the group instead of a ↗ row.
    private func hidingSubspaceChildren(
        _ status: WorkspaceSessionStatus,
        subspaceRows: [SidebarSubspacePresentation.Row]
    ) -> WorkspaceSessionStatus {
        guard subspaceRows.isEmpty == false else { return status }
        let subspaceIDs = Set(subspaceRows.map(\.id))
        var status = status
        status.children.removeAll { child in
            child.source == .session && child.workspaceID.map(subspaceIDs.contains) == true
        }
        return status
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
        return subspaceIDs.compactMap { subspaceID in
            guard let workspace = store.state.workspacesByID[subspaceID] else { return nil }
            let statuses = sidebarSessionStatuses(for: subspaceID)
            let sessions = statuses.map { status in
                SidebarSubspacePresentation.SessionLine(
                    title: status.displayTitle,
                    statusKind: status.status.kind,
                    summary: normalizedSessionDetail(status.status.detail) ?? normalizedSessionDetail(status.status.summary)
                )
            }
            return SidebarSubspacePresentation.Row(
                id: subspaceID,
                title: workspace.title,
                status: SidebarSubspacePresentation.rowStatus(
                    sessionStatuses: statuses.map { status in
                        (
                            kind: status.status.kind,
                            showsUnreadSessionAccent: showsUnreadSessionAccent(for: status.panelID, in: workspace)
                        )
                    }
                ),
                pullRequest: workspace.annotations[SidebarSubspacePresentation.annotationKeyPullRequest],
                summary: sessions.first?.summary,
                spawningSessionID: workspace.spawningSessionID,
                spawnerName: workspace.spawningSessionID.flatMap { spawnersBySessionID[$0]?.displayTitle },
                spawnerPanelID: workspace.spawningSessionID.flatMap { spawnersBySessionID[$0]?.panelID },
                sessions: sessions,
                creationIndex: windowWorkspaceIDs.firstIndex(of: subspaceID) ?? Int.max
            )
        }
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
        let orderedRows = SidebarSubspacePresentation.orderedRows(
            filteredRows,
            frozenOrder: frozenSubspaceOrderByParentID[parentWorkspaceID]
        )
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

            if isExpanded {
                if filterSessionID != nil {
                    subspacesFilterBar(
                        spawnerName: filterSpawnerName ?? "this agent",
                        parentWorkspaceID: parentWorkspaceID
                    )
                }

                VStack(alignment: .leading, spacing: 1) {
                    ForEach(orderedRows) { row in
                        subspaceRow(row, parentWorkspaceID: parentWorkspaceID, showsSpawnerTag: showsSpawnerTags)
                    }
                }
                .animation(
                    accessibilityReduceMotion ? nil : .easeInOut(duration: 0.28),
                    value: orderedRowIDs
                )
                .onHover { isHovering in
                    if isHovering {
                        frozenSubspaceOrderByParentID[parentWorkspaceID] = orderedRowIDs
                    } else {
                        frozenSubspaceOrderByParentID.removeValue(forKey: parentWorkspaceID)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
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
                    Text(SidebarSubspacePresentation.headerCountLabel(shownCount: shownCount, totalCount: totalCount))
                        .font(ToastyTheme.fontWorkspaceAgentCount)
                        .foregroundStyle(ToastyTheme.sidebarSessionPathText)
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

            if tally.isEmpty == false {
                HStack(spacing: 8) {
                    subspacesTallyItem(count: tally.ready, color: ToastyTheme.sessionReadyText)
                    subspacesTallyItem(count: tally.needsApproval, color: ToastyTheme.sessionNeedsApprovalText)
                    subspacesTallyItem(count: tally.error, color: ToastyTheme.sessionErrorText)
                }
                .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 16)
        .padding(.top, 6)
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
            .accessibilityLabel("Clear subspace filter")
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
    /// button that focuses that session's panel in the parent workspace.
    @ViewBuilder
    private func spawnerTag(
        label: String,
        spawnerName: String,
        parentWorkspaceID: UUID,
        spawnerPanelID: UUID?
    ) -> some View {
        if let spawnerPanelID {
            Button {
                focusSessionPanel(workspaceID: parentWorkspaceID, panelID: spawnerPanelID)
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

    private func subspaceRow(
        _ row: SidebarSubspacePresentation.Row,
        parentWorkspaceID: UUID,
        showsSpawnerTag: Bool
    ) -> some View {
        let isSelected = selectedWorkspaceID == row.id
        let isHovered = hoveredSubspaceID == row.id
        let isSpawnerHighlighted = hoveredSpawnerSessionID != nil
            && hoveredSpawnerSessionID == row.spawningSessionID
        // Same chrome as a session row: hover fills and outlines, selection
        // uses the active fill.
        let background: Color = if isSelected {
            isHovered ? ToastyTheme.sidebarSessionActiveHoverBackground : ToastyTheme.sidebarSessionActiveBackground
        } else if isHovered || isSpawnerHighlighted {
            ToastyTheme.sidebarSessionHoverBackground
        } else {
            Color.clear
        }
        let borderColor = isHovered ? ToastyTheme.sidebarSessionHoverBorder : Color.clear
        let hoverTipModel = SidebarSubspacePresentation.hoverTipModel(row)
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

        // A tap on the row selects the workspace; the PR chip inside stays a
        // real link button, as it is on top-level cards.
        // Same rail and padding as a session row, so the title's left edge
        // lines up with the session titles above whatever the status is.
        return HStack(alignment: .top, spacing: Self.sessionStatusRailGap) {
            sessionStatusRailStatusSlot(Self.subspaceRailState(row.status))
                .frame(width: Self.sessionStatusRailWidth)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(ToastyTheme.fontWorkspaceSessionChildName)
                        .foregroundStyle(ToastyTheme.sidebarSessionAgentText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                    if let chipKind = Self.subspaceStatusChipKind(row.status) {
                        sessionStatusChip(kind: chipKind)
                            .layoutPriority(2)
                    }
                    if let pullRequest = row.pullRequest {
                        // The chip keeps its width; the title truncates instead.
                        workspaceAnnotationChip(
                            key: SidebarSubspacePresentation.annotationKeyPullRequest,
                            annotation: pullRequest
                        )
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                    }
                }
                .frame(minHeight: Self.sessionRowSecondaryLineMinHeight)

                if row.summary != nil || (showsSpawnerTag && row.spawnerName != nil) {
                    HStack(spacing: 6) {
                        if let summary = row.summary {
                            Text(summary)
                                .font(ToastyTheme.fontWorkspaceSessionChildContext)
                                .foregroundStyle(ToastyTheme.sidebarChildContextText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                        if showsSpawnerTag, let spawnerName = row.spawnerName {
                            // Capped so the summary keeps most of the line; the
                            // hover card carries the full spawner name.
                            spawnerTag(
                                label: SidebarSubspacePresentation.spawnerTagLabel(spawnerName),
                                spawnerName: spawnerName,
                                parentWorkspaceID: parentWorkspaceID,
                                spawnerPanelID: row.spawnerPanelID
                            )
                            .frame(maxWidth: 110, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                hoveredSubspaceID = row.id
            } else if hoveredSubspaceID == row.id {
                hoveredSubspaceID = nil
            }
        }
        .hoverTip(
            id: row.id,
            refreshID: hoverTipModel,
            placement: .trailing(gap: Self.sessionHoverTipTrailingGap)
        ) {
            SessionChildHoverTipCard(model: hoverTipModel)
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
        .accessibilityAction(named: Text("Move to top level")) {
            _ = store.send(
                .setWorkspaceParent(workspaceID: row.id, parentWorkspaceID: nil, spawningSessionID: nil),
                source: .ui("sidebar_subspace_move_to_top_level")
            )
        }
        .accessibilityIdentifier("sidebar.workspace.subspace.\(row.id.uuidString)")
        .id(row.id)
        .contextMenu {
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

    private static func subspaceRailState(
        _ status: SidebarSubspacePresentation.RowStatus
    ) -> SidebarSessionPresentation.SessionRailState {
        switch status {
        case .ready: return .unreadDot
        case .needsApproval: return .approvalDot
        case .error: return .errorDot
        case .working: return .spinner
        case .idle: return .empty
        }
    }

    private static func subspaceStatusChipKind(
        _ status: SidebarSubspacePresentation.RowStatus
    ) -> SessionStatusKind? {
        switch status {
        case .ready: return .ready
        case .needsApproval: return .needsApproval
        case .error: return .error
        case .working, .idle: return nil
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

    private func toggleSubspaceFilter(parentWorkspaceID: UUID, spawningSessionID: String) {
        if subspaceFilterSessionIDByParentID[parentWorkspaceID] == spawningSessionID {
            subspaceFilterSessionIDByParentID.removeValue(forKey: parentWorkspaceID)
        } else {
            subspaceFilterSessionIDByParentID[parentWorkspaceID] = spawningSessionID
            collapsedSubspaceGroupParentIDs.remove(parentWorkspaceID)
        }
    }

    private func pruneSubspaceGroupState() {
        // Keep state only for cards that still have a group, so a later
        // group under the same card starts fresh.
        let parentIDs = Set(store.state.workspacesByID.keys.filter { store.state.subspaceWorkspaceIDs(of: $0).isEmpty == false })
        if let hoveredSubspaceID, store.state.workspacesByID[hoveredSubspaceID]?.parentWorkspaceID == nil {
            self.hoveredSubspaceID = nil
        }
        collapsedSubspaceGroupParentIDs = collapsedSubspaceGroupParentIDs.filter(parentIDs.contains)
        subspaceFilterSessionIDByParentID = subspaceFilterSessionIDByParentID.filter { parentIDs.contains($0.key) }
        frozenSubspaceOrderByParentID = frozenSubspaceOrderByParentID.filter { parentIDs.contains($0.key) }
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

    private func parentSessionName(
        for workspaceSessionStatus: WorkspaceSessionStatus,
        in workspaceID: UUID
    ) -> String? {
        guard let parentSessionID = workspaceSessionStatus.parentSessionID,
              let parent = sessionRuntimeStore.sessionRegistry.activeSession(sessionID: parentSessionID),
              parent.workspaceID != workspaceID else {
            return nil
        }
        return parent.displayTitleOverride ?? parent.providerSessionName ?? parent.agent.displayName
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

    private func scrollToHiddenSession(
        _ pill: SidebarSessionPresentation.HiddenSessionPill,
        using proxy: ScrollViewProxy
    ) {
        guard let target = SidebarSessionPresentation.hiddenSessionScrollTarget(
            for: pill.direction,
            orderedWorkspaceIDs: store.window(id: windowID)?.workspaceIDs ?? []
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

    private func currentUnreadSidebarSessionRowIDs() -> Set<SidebarSessionPresentation.SidebarSessionRowID> {
        guard let window = store.window(id: windowID) else { return [] }

        return Set(
            window.workspaceIDs.flatMap { workspaceID -> [SidebarSessionPresentation.SidebarSessionRowID] in
                guard let workspace = store.state.workspacesByID[workspaceID] else { return [] }

                return sidebarSessionStatuses(for: workspaceID)
                    .compactMap { status in
                        guard showsUnreadSessionAccent(for: status.panelID, in: workspace) else {
                            return nil
                        }

                        return SidebarSessionPresentation.SidebarSessionRowID(
                            workspaceID: workspaceID,
                            sessionID: status.sessionID,
                            panelID: status.panelID
                        )
                    }
            }
        )
    }

    private func currentWorkingSidebarSessionRowIDs() -> Set<SidebarSessionPresentation.SidebarSessionRowID> {
        guard let window = store.window(id: windowID) else { return [] }

        return Set(
            window.workspaceIDs.flatMap { workspaceID -> [SidebarSessionPresentation.SidebarSessionRowID] in
                guard store.state.workspacesByID[workspaceID] != nil else { return [] }

                return sidebarSessionStatuses(for: workspaceID)
                    .compactMap { workspaceSessionStatus in
                        guard workspaceSessionStatus.status.kind == .working else {
                            return nil
                        }

                        return SidebarSessionPresentation.SidebarSessionRowID(
                            workspaceID: workspaceID,
                            sessionID: workspaceSessionStatus.sessionID,
                            panelID: workspaceSessionStatus.panelID
                        )
                    }
            }
        )
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
            measuredSessionRowFramesByID = [:]
            cancelWorkspaceDrag()
            return
        }

        let workspaceIDs = Set(window.workspaceIDs)
        measuredWorkspaceRowFramesByID = measuredWorkspaceRowFramesByID.filter { workspaceIDs.contains($0.key) }
        let currentSessionRowIDs = Set(currentSidebarSessionRowIDs())
        measuredSessionRowFramesByID = measuredSessionRowFramesByID.filter { currentSessionRowIDs.contains($0.key) }
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

    static func styledSessionNameText(
        _ text: String,
        statusKind: SessionStatusKind,
        showsUnreadSessionAccent: Bool
    ) -> Text {
        styledSessionText(
            text,
            font: ToastyTheme.workspaceSessionNameFont(
                weight: SidebarSessionPresentation.sessionAgentFontWeight(
                    showsUnreadSessionAccent: showsUnreadSessionAccent
                )
            ),
            usesItalic: SidebarSessionPresentation.sessionTextUsesItalic(for: statusKind)
        )
    }

    static func styledSessionPrimaryText(
        _ text: String,
        statusKind: SessionStatusKind,
        showsUnreadSessionAccent: Bool
    ) -> Text {
        styledSessionSummaryText(
            text,
            font: ToastyTheme.workspaceSessionPrimaryFont(
                weight: SidebarSessionPresentation.sessionAgentFontWeight(
                    showsUnreadSessionAccent: showsUnreadSessionAccent
                )
            ),
            usesItalic: SidebarSessionPresentation.sessionTextUsesItalic(for: statusKind)
        )
    }

    static func styledSessionDetailText(
        _ text: String,
        statusKind: SessionStatusKind,
        showsUnreadSessionAccent: Bool
    ) -> Text {
        styledSessionSummaryText(
            text,
            font: ToastyTheme.workspaceSessionDetailFont(
                weight: SidebarSessionPresentation.sessionBodyFontWeight(
                    showsUnreadSessionAccent: showsUnreadSessionAccent
                )
            ),
            usesItalic: SidebarSessionPresentation.sessionTextUsesItalic(for: statusKind)
        )
    }

    static func styledSessionText(
        _ text: String,
        font: Font,
        usesItalic: Bool
    ) -> Text {
        let base = Text(text).font(font)
        return usesItalic ? base.italic() : base
    }

    /// Summaries carry provider Markdown; names and titles do not.
    static func styledSessionSummaryText(
        _ text: String,
        font: Font,
        usesItalic: Bool
    ) -> Text {
        let base = Text(SidebarSessionPresentation.sessionSummaryAttributedText(text)).font(font)
        return usesItalic ? base.italic() : base
    }

    private func shortcutBadge(_ label: String, highlighted: Bool) -> some View {
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
