import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain

struct ToasttyTranscriptView: View {
    @Environment(\.scenePhase) private var scenePhase

    let state: ToasttyConversationPresentationState
    let loadOlder: () -> Void
    let dismissSendReceipt: (String) -> Void
    let readAcknowledgementEpoch: MobileSessionStatus?
    let onVisibleLiveEdge: () -> Void
    @Binding private var jumpToLiveEdgeRequest: UInt64

    @State private var toolBatchDisclosure = ToasttyToolBatchDisclosureState()
    @State private var turnFold = ToasttyTurnFoldState()
    @State private var expandedSubagentIDs: Set<ToasttyTranscriptRowID> = []
    @State private var isAtLiveEdge = true
    @State private var hasMeasuredScrollGeometry = false
    @State private var measuredBoundaryID: ToasttyTranscriptRowID?
    @State private var isVisible = false
    @State private var followsLiveEdge = true
    @State private var visibleBlockIDs: [ToasttyTranscriptBlockID] = []
    @State private var scrollCoordinator = TranscriptScrollCoordinator()

    init(
        state: ToasttyConversationPresentationState,
        loadOlder: @escaping () -> Void = {},
        dismissSendReceipt: @escaping (String) -> Void = { _ in },
        readAcknowledgementEpoch: MobileSessionStatus? = nil,
        jumpToLiveEdgeRequest: Binding<UInt64>,
        onVisibleLiveEdge: @escaping () -> Void = {}
    ) {
        self.state = state
        self.loadOlder = loadOlder
        self.dismissSendReceipt = dismissSendReceipt
        self.readAcknowledgementEpoch = readAcknowledgementEpoch
        self.onVisibleLiveEdge = onVisibleLiveEdge
        _jumpToLiveEdgeRequest = jumpToLiveEdgeRequest
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if showsStatusContent {
                    VStack(spacing: 8) {
                        statusContent
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                    .background(ToasttyDesignTokens.background)
                }

                ScrollView {
                    // Modest transcripts lay out eagerly: measured heights mean
                    // no lazy-estimation churn, which both snapped the reader
                    // to a long message's start and could live-lock layout when
                    // a few large cells dominated the list. The lazy container
                    // stays for huge lists, where chunked messages keep cell
                    // sizes in the regime its estimation handles well.
                    Group {
                        if state.blocks.count <= Self.eagerLayoutBlockLimit {
                            VStack(alignment: .leading, spacing: 12) {
                                transcriptStackContent
                            }
                        } else {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                transcriptStackContent
                            }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                }
                .background(ToasttyDesignTokens.background)
                .accessibilityIdentifier("toastty-mobile-transcript")
                .scrollDismissesKeyboard(.interactively)
                .overlay(alignment: .topLeading) {
                    if state.rows.count == 5_000 {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityElement()
                            .accessibilityLabel("5,000 transcript rows ready")
                            .accessibilityIdentifier("toastty-mobile-transcript-ready-5000")
                    }
                }
                .onScrollGeometryChange(for: TranscriptScrollMetrics.self) { geometry in
                    TranscriptScrollMetrics(geometry: geometry)
                } action: { old, new in
                    let hadMeasuredScrollGeometry = hasMeasuredScrollGeometry
                    let atLiveEdge = new.isAtLiveEdge
                    hasMeasuredScrollGeometry = true
                    measuredBoundaryID = state.rows.last?.id
                    isAtLiveEdge = atLiveEdge
                    if hadMeasuredScrollGeometry,
                       new.hasLiveEdgeLayoutChange(comparedTo: old),
                       lastScrollTarget != nil,
                       followsLiveEdge || scrollCoordinator.ownsLiveEdge {
                        // Layout changes reinforce the current owner through
                        // the same serialized command path as transcript
                        // changes; they never race a separate scroll writer.
                        scrollCoordinator.reinforceLiveEdge()
                    }
                    if atLiveEdge {
                        if case .send(let request)? = scrollCoordinator.liveEdgeOwner,
                           jumpToLiveEdgeRequest == request {
                            jumpToLiveEdgeRequest = 0
                            followsLiveEdge = true
                            _ = scrollCoordinator.finishSend(atLiveEdge: true)
                        }
                        if scrollCoordinator.finishJump(atLiveEdge: true) {
                            followsLiveEdge = true
                        }
                    }
                }
                .onScrollPhaseChange { oldPhase, newPhase, context in
                    if newPhase == .tracking || newPhase == .interacting {
                        // Finger-down or a direct drag owns the reader's
                        // position until it settles, including any momentum
                        // after finger lift.
                        jumpToLiveEdgeRequest = 0
                        followsLiveEdge = false
                        scrollCoordinator.cancelForInteraction()
                        return
                    }

                    guard TranscriptScrollCoordinator.shouldResolveFollowing(
                        oldPhase: oldPhase,
                        newPhase: newPhase
                    )
                    else { return }
                    // Resolve only at rest so a short flick is classified after
                    // its momentum ends.
                    followsLiveEdge = TranscriptScrollMetrics(
                        geometry: context.geometry
                    ).isAtLiveEdge
                }
                .onScrollTargetVisibilityChange(
                    idType: ToasttyConversationScrollTarget.self,
                    threshold: 0.12
                ) { ids in
                    visibleBlockIDs = ids.compactMap { id in
                        guard case .transcript(let blockID) = id else { return nil }
                        return blockID
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isAtLiveEdge == false,
                       followsLiveEdge == false,
                       lastScrollTarget != nil {
                        Button {
                            // The affordance stays visible until the live edge
                            // is actually reached; each tap (re)starts a jump.
                            scrollCoordinator.requestJump()
                        } label: {
                            Label("Jump to latest", systemImage: "arrow.down")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(ToasttyDesignTokens.amber, in: Capsule())
                                .foregroundStyle(ToasttyDesignTokens.inkOnAmber)
                                .shadow(color: .black.opacity(0.45), radius: 7, y: 3)
                        }
                        .accessibilityIdentifier("toastty-mobile-transcript-jump-latest")
                        .padding(14)
                    }
                }
                .onChange(of: jumpToLiveEdgeRequest) { _, request in
                    guard request > 0, lastScrollTarget != nil else { return }
                    scrollCoordinator.requestSend(request)
                }
                .onChange(of: scrollChangeKey, initial: true) { _, _ in
                    reconcileScrollChange()
                }
                .task(id: scrollCoordinator.command) {
                    guard let command = scrollCoordinator.command else { return }
                    // Let the state update and text layout settle before
                    // executing the latest command. A superseding command or
                    // direct gesture cancels this task.
                    await Task.yield()
                    await Task.yield()
                    guard Task.isCancelled == false else { return }
                    guard scrollCoordinator.command == command else { return }
                    execute(command, using: proxy)

                    guard command.target == .liveEdge else { return }
                    let initialDelay: Duration = command.motion == .animated
                        ? .milliseconds(250)
                        : .milliseconds(100)
                    try? await Task.sleep(for: initialDelay)
                    let retryCount = switch command.liveEdgeOwner {
                    case .send?, .jump?: 8
                    case .automatic?, nil: 2
                    }
                    for _ in 0 ..< retryCount {
                        guard Task.isCancelled == false,
                              scrollCoordinator.command == command
                        else { return }
                        if isAtLiveEdge == false {
                            scrollWithoutAnimation(
                                to: ToasttyConversationScrollTarget.liveEdge,
                                anchor: .bottom,
                                using: proxy
                            )
                        }
                        try? await Task.sleep(for: .milliseconds(150))
                    }

                    guard Task.isCancelled == false,
                          scrollCoordinator.command == command
                    else { return }
                    if case .send(let request)? = command.liveEdgeOwner,
                       jumpToLiveEdgeRequest == request {
                        jumpToLiveEdgeRequest = 0
                        followsLiveEdge = isAtLiveEdge
                        _ = scrollCoordinator.finishSend(atLiveEdge: isAtLiveEdge)
                    } else if case .jump? = command.liveEdgeOwner {
                        followsLiveEdge = isAtLiveEdge
                        _ = scrollCoordinator.finishJump(atLiveEdge: isAtLiveEdge)
                    }
                }
                .onChange(of: liveEdgeVisibilityKey, initial: true) { _, key in
                    guard key.isEligible else { return }
                    onVisibleLiveEdge()
                }
            }
            .background(ToasttyDesignTokens.background)
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .onChange(of: toolBatchActivity, initial: true) { _, activity in
                toolBatchDisclosure.reconcile(activity: activity, revision: state.revision)
            }
            .onChange(of: turnFoldKey, initial: true) { old, new in
                let apply = {
                    turnFold.reconcile(
                        turns: new.turns,
                        settledIDs: new.settledIDs,
                        revision: new.revision,
                        previousBoundarySequence: old.firstSequence
                    )
                }
                // Animate only live transitions; initial, rebuilt, and
                // prepended reconciles must land instantly so opening or
                // re-anchoring never races an in-flight fold animation.
                if old != new, new.revision == .appended || new.revision == .metadataOnly {
                    withAnimation(.easeInOut(duration: 0.25), apply)
                } else {
                    apply()
                }
            }
        }
    }

    /// Above this block count the transcript falls back to lazy layout.
    private static let eagerLayoutBlockLimit = 150

    @ViewBuilder
    private var transcriptStackContent: some View {
        olderHistoryControl

        ForEach(displayItems) { item in
            displayItemView(item)
                .id(item.id)
        }

        ForEach(state.sendItems) { item in
            ToasttySendTailItemView(
                item: item,
                dismiss: { dismissSendReceipt(item.clientRequestID) }
            )
            .id(ToasttyConversationScrollTarget.send(item.clientRequestID))
        }

        if state.rows.isEmpty, state.sendItems.isEmpty, state.phase != .loading {
            ContentUnavailableView(
                "No transcript yet",
                systemImage: "text.bubble",
                description: Text("New conversation activity will appear here.")
            )
            .foregroundStyle(ToasttyDesignTokens.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44)
        }

        // The preceding 12-point stack spacing plus this target's height
        // preserve the original 14-point bottom inset while making that inset
        // part of the live-edge scroll target.
        Color.clear
            .frame(height: 2)
            .id(ToasttyConversationScrollTarget.liveEdge)
    }

    /// Blocks interleaved with per-turn work strips; a folded turn's work
    /// blocks are omitted and its strip stands in for them.
    private var displayItems: [ToasttyTranscriptDisplayItem] {
        guard state.turns.isEmpty == false else {
            return state.blocks.map { .block($0, isWork: false) }
        }
        var turnAtFirstWorkBlock: [ToasttyTranscriptBlockID: ToasttyTranscriptTurn] = [:]
        var turnForWorkBlock: [ToasttyTranscriptBlockID: ToasttyTranscriptRowID] = [:]
        for turn in state.turns {
            if let first = turn.workBlockIDs.first {
                turnAtFirstWorkBlock[first] = turn
            }
            for blockID in turn.workBlockIDs {
                turnForWorkBlock[blockID] = turn.id
            }
        }

        var items: [ToasttyTranscriptDisplayItem] = []
        items.reserveCapacity(state.blocks.count + state.turns.count)
        for block in state.blocks {
            if let turn = turnAtFirstWorkBlock[block.id] {
                items.append(.workStrip(turn))
            }
            if let turnID = turnForWorkBlock[block.id] {
                if turnFold.isExpanded(turnID) {
                    items.append(.block(block, isWork: true))
                }
            } else {
                items.append(.block(block, isWork: false))
            }
        }
        return items
    }

    @ViewBuilder
    private func displayItemView(_ item: ToasttyTranscriptDisplayItem) -> some View {
        switch item {
        case .workStrip(let turn):
            ToasttyTurnWorkStrip(
                turn: turn,
                isExpanded: turnFold.isExpanded(turn.id),
                isLive: turn.id == liveTurnID,
                toggle: {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        turnFold.toggle(turn.id)
                    }
                }
            )
        case .block(let block, let isWork):
            if isWork {
                blockView(block, demoted: true)
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(ToasttyDesignTokens.border)
                            .frame(width: 2)
                    }
            } else {
                blockView(block)
            }
        }
    }

    private var isSessionWorking: Bool {
        readAcknowledgementEpoch?.bucket == .working
    }

    /// Turns whose work may fold: the response arrived, and for the last turn
    /// the session is also no longer streaming it.
    private var settledTurnIDs: Set<ToasttyTranscriptRowID> {
        var settled = Set(state.turns.filter(\.hasResponse).map(\.id))
        if let last = state.turns.last, isSessionWorking {
            settled.remove(last.id)
        }
        return settled
    }

    private var liveTurnID: ToasttyTranscriptRowID? {
        guard let last = state.turns.last else { return nil }
        return settledTurnIDs.contains(last.id) ? nil : last.id
    }

    private var turnFoldKey: TurnFoldKey {
        TurnFoldKey(
            turns: state.turns,
            settledIDs: settledTurnIDs,
            revision: state.revision,
            firstSequence: state.blocks.first?.id.rowID.sequence
        )
    }

    @ViewBuilder
    private var statusContent: some View {
        switch state.phase {
        case .loading:
            HStack(spacing: 9) {
                ProgressView()
                    .tint(ToasttyDesignTokens.amber)
                Text("Loading transcript…")
            }
            .transcriptBannerStyle(color: ToasttyDesignTokens.secondaryText)
        case .resyncing:
            HStack(spacing: 9) {
                ProgressView()
                    .tint(ToasttyDesignTokens.amber)
                Text("Resyncing transcript…")
            }
            .transcriptBannerStyle(color: ToasttyDesignTokens.amberText)
            .accessibilityIdentifier("toastty-mobile-transcript-resyncing")
        case .stale:
            Label("Connection paused — transcript may be stale", systemImage: "wifi.slash")
                .transcriptBannerStyle(color: ToasttyDesignTokens.secondaryText)
                .accessibilityIdentifier("toastty-mobile-transcript-stale")
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .transcriptBannerStyle(color: ToasttyDesignTokens.red)
        case .live:
            EmptyView()
        }

        if state.historyTruncated {
            Label(
                "Earlier activity is no longer retained by Toastty",
                systemImage: "clock.badge.exclamationmark"
            )
            .transcriptBannerStyle(color: ToasttyDesignTokens.mutedText)
            .accessibilityIdentifier("toastty-mobile-transcript-history-truncated")
        }
    }

    private var showsStatusContent: Bool {
        state.phase != .live || state.historyTruncated
    }

    @ViewBuilder
    private var olderHistoryControl: some View {
        if state.isLoadingOlder {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(ToasttyDesignTokens.amber)
                Text("Loading earlier activity…")
            }
            .transcriptBannerStyle(color: ToasttyDesignTokens.secondaryText)
            .accessibilityIdentifier("toastty-mobile-transcript-loading-older")
        } else if state.hasOlder {
            Button(action: loadOlder) {
                Label("Load earlier activity", systemImage: "arrow.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ToasttyDesignTokens.amberText)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(ToasttyDesignTokens.raisedSurface)
                    .clipShape(RoundedRectangle(
                        cornerRadius: ToasttyDesignTokens.controlCornerRadius,
                        style: .continuous
                    ))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("toastty-mobile-transcript-load-older")
        }
    }

    @ViewBuilder
    private func blockView(_ block: ToasttyTranscriptBlock, demoted: Bool = false) -> some View {
        switch block.content {
        case .row(let row):
            ToasttyTranscriptRowView(
                row: row,
                isDemoted: demoted,
                subagentIsExpanded: expandedSubagentIDs.contains(row.id),
                toggleSubagentExpansion: { toggle(row.id, in: &expandedSubagentIDs) }
            )
        case .messageChunk(let chunk):
            ToasttyTranscriptRowView(
                row: chunk.row,
                chunk: chunk,
                isDemoted: demoted,
                subagentIsExpanded: false,
                toggleSubagentExpansion: {}
            )
        case .toolBatch(let rows):
            ToasttyToolBatchCard(
                blockID: block.id,
                rows: rows,
                isExpanded: toolBatchDisclosure.isExpanded(block.id),
                toggleDetails: {
                    toolBatchDisclosure.toggle(block.id)
                }
            )
        }
    }

    private var scrollChangeKey: ScrollChangeKey {
        ScrollChangeKey(
            revision: state.revision,
            blockCount: state.blocks.count,
            sendItems: state.sendItems.map(ToasttySendScrollItem.init),
            firstID: state.blocks.first?.id,
            lastTarget: lastScrollTarget
        )
    }

    private func reconcileScrollChange() {
        switch state.revision {
        case .initial, .rebuilt:
            guard lastScrollTarget != nil else { return }
            followsLiveEdge = true
            scrollCoordinator.requestInitialLiveEdge()
        case .appended, .metadataOnly:
            guard lastScrollTarget != nil,
                  followsLiveEdge || scrollCoordinator.ownsLiveEdge
            else { return }
            scrollCoordinator.reinforceLiveEdge()
        case .prepended:
            let anchor = state.prependAnchorID
                .map { ToasttyTranscriptBlockID(rowID: $0) }
                ?? visibleBlockIDs.first
            if let anchor {
                if scrollCoordinator.requestHistoryAnchor(anchor) {
                    followsLiveEdge = false
                }
            }
        }
    }

    private func execute(
        _ command: TranscriptScrollCoordinator.Command,
        using proxy: ScrollViewProxy
    ) {
        let target: ToasttyConversationScrollTarget
        let anchor: UnitPoint
        switch command.target {
        case .liveEdge:
            target = .liveEdge
            anchor = .bottom
        case .transcript(let blockID):
            target = .transcript(blockID)
            anchor = .top
        }

        if command.motion == .animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(target, anchor: anchor)
            }
        } else {
            scrollWithoutAnimation(to: target, anchor: anchor, using: proxy)
        }
    }

    private func scrollWithoutAnimation(
        to target: ToasttyConversationScrollTarget,
        anchor: UnitPoint,
        using proxy: ScrollViewProxy
    ) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(target, anchor: anchor)
        }
    }

    private var toolBatchActivity: [ToasttyToolBatchActivity] {
        ToasttyToolBatchActivity.make(from: state.blocks)
    }

    private var lastScrollTarget: ToasttyConversationScrollTarget? {
        guard state.blocks.isEmpty == false || state.sendItems.isEmpty == false else {
            return nil
        }
        return .liveEdge
    }

    private var liveEdgeVisibilityKey: TranscriptLiveEdgeVisibilityKey {
        TranscriptLiveEdgeVisibilityKey(
            phase: state.phase,
            scenePhase: scenePhase,
            isVisible: isVisible,
            isAtLiveEdge: isAtLiveEdge,
            hasMeasuredScrollGeometry: hasMeasuredScrollGeometry,
            measuredBoundaryID: measuredBoundaryID,
            latestBoundaryID: state.rows.last?.id,
            readAcknowledgementEpoch: readAcknowledgementEpoch
        )
    }

    private func toggle(
        _ id: ToasttyTranscriptRowID,
        in values: inout Set<ToasttyTranscriptRowID>
    ) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if values.contains(id) {
                values.remove(id)
            } else {
                values.insert(id)
            }
        }
    }
}

struct TranscriptScrollMetrics: Equatable {
    static let liveEdgeThreshold: CGFloat = 72
    static let viewportResizeThreshold: CGFloat = 0.5

    let contentHeight: CGFloat
    let visibleMaxY: CGFloat
    let visibleHeight: CGFloat

    init(geometry: ScrollGeometry) {
        contentHeight = geometry.contentSize.height
        visibleMaxY = geometry.visibleRect.maxY
        visibleHeight = geometry.visibleRect.height
    }

    init(
        contentHeight: CGFloat,
        visibleMaxY: CGFloat,
        visibleHeight: CGFloat
    ) {
        self.contentHeight = contentHeight
        self.visibleMaxY = visibleMaxY
        self.visibleHeight = visibleHeight
    }

    func hasViewportHeightChange(comparedTo other: Self) -> Bool {
        abs(visibleHeight - other.visibleHeight) >= Self.viewportResizeThreshold
    }

    func hasLiveEdgeLayoutChange(comparedTo other: Self) -> Bool {
        hasViewportHeightChange(comparedTo: other)
            || abs(contentHeight - other.contentHeight) >= Self.viewportResizeThreshold
    }

    var distanceFromBottom: CGFloat {
        contentHeight - visibleMaxY
    }

    var isAtLiveEdge: Bool {
        distanceFromBottom < Self.liveEdgeThreshold
    }
}

struct TranscriptScrollCoordinator: Equatable {
    enum LiveEdgeOwner: Equatable {
        case automatic
        case send(UInt64)
        case jump(UInt64)
    }

    enum Motion: Equatable {
        case stable
        case animated
    }

    enum Target: Equatable {
        case liveEdge
        case transcript(ToasttyTranscriptBlockID)
    }

    struct Command: Equatable {
        let sequence: UInt64
        let target: Target
        let motion: Motion
        let liveEdgeOwner: LiveEdgeOwner?
    }

    private(set) var liveEdgeOwner: LiveEdgeOwner?
    private(set) var command: Command?
    private var nextSequence: UInt64 = 0
    private var nextJumpRequest: UInt64 = 0

    var ownsLiveEdge: Bool {
        liveEdgeOwner != nil
    }

    var hasExplicitLiveEdgeOwner: Bool {
        switch liveEdgeOwner {
        case .send?, .jump?: true
        case .automatic?, nil: false
        }
    }

    static func shouldResolveFollowing(
        oldPhase: ScrollPhase,
        newPhase: ScrollPhase
    ) -> Bool {
        guard newPhase == .idle else { return false }
        return oldPhase == .tracking
            || oldPhase == .interacting
            || oldPhase == .decelerating
    }

    mutating func requestInitialLiveEdge() {
        issueLiveEdge(owner: .automatic, motion: .stable)
    }

    mutating func requestSend(_ request: UInt64) {
        issueLiveEdge(owner: .send(request), motion: .stable)
    }

    mutating func requestJump() {
        nextJumpRequest &+= 1
        issueLiveEdge(owner: .jump(nextJumpRequest), motion: .animated)
    }

    mutating func reinforceLiveEdge() {
        issueLiveEdge(owner: liveEdgeOwner ?? .automatic, motion: .stable)
    }

    /// Returns false when an explicit send or jump still owns the live edge;
    /// a late pagination result must not steal that user-requested movement.
    @discardableResult
    mutating func requestHistoryAnchor(_ blockID: ToasttyTranscriptBlockID) -> Bool {
        guard hasExplicitLiveEdgeOwner == false else {
            reinforceLiveEdge()
            return false
        }
        liveEdgeOwner = nil
        issue(target: .transcript(blockID), motion: .stable, liveEdgeOwner: nil)
        return true
    }

    mutating func cancelForInteraction() {
        liveEdgeOwner = nil
        command = nil
    }

    /// Returns true when an active jump completed at the live edge.
    @discardableResult
    mutating func finishJump(atLiveEdge: Bool) -> Bool {
        guard case .jump? = liveEdgeOwner else { return false }
        liveEdgeOwner = atLiveEdge ? .automatic : nil
        command = nil
        return atLiveEdge
    }

    /// Returns true when an active send completed at the live edge. A failed
    /// acquisition releases ownership so the recovery affordance can appear.
    @discardableResult
    mutating func finishSend(atLiveEdge: Bool) -> Bool {
        guard case .send? = liveEdgeOwner else { return false }
        liveEdgeOwner = atLiveEdge ? .automatic : nil
        command = nil
        return atLiveEdge
    }

    private mutating func issueLiveEdge(owner: LiveEdgeOwner, motion: Motion) {
        liveEdgeOwner = owner
        issue(target: .liveEdge, motion: motion, liveEdgeOwner: owner)
    }

    private mutating func issue(
        target: Target,
        motion: Motion,
        liveEdgeOwner: LiveEdgeOwner?
    ) {
        nextSequence &+= 1
        command = Command(
            sequence: nextSequence,
            target: target,
            motion: motion,
            liveEdgeOwner: liveEdgeOwner
        )
    }
}

struct TranscriptLiveEdgeVisibilityKey: Equatable {
    let phase: ToasttyConversationPresentationPhase
    let scenePhase: ScenePhase
    let isVisible: Bool
    let isAtLiveEdge: Bool
    let hasMeasuredScrollGeometry: Bool
    let measuredBoundaryID: ToasttyTranscriptRowID?
    let latestBoundaryID: ToasttyTranscriptRowID?
    let readAcknowledgementEpoch: MobileSessionStatus?

    var isEligible: Bool {
        phase == .live
            && scenePhase == .active
            && isVisible
            && isAtLiveEdge
            && hasMeasuredScrollGeometry
            && (latestBoundaryID == nil || measuredBoundaryID == latestBoundaryID)
    }
}

private enum ToasttyConversationScrollTarget: Hashable {
    case transcript(ToasttyTranscriptBlockID)
    case turnWork(ToasttyTranscriptRowID)
    case send(String)
    case liveEdge
}

private enum ToasttyTranscriptDisplayItem: Identifiable {
    case block(ToasttyTranscriptBlock, isWork: Bool)
    case workStrip(ToasttyTranscriptTurn)

    var id: ToasttyConversationScrollTarget {
        switch self {
        case .block(let block, _): .transcript(block.id)
        case .workStrip(let turn): .turnWork(turn.id)
        }
    }
}

private struct TurnFoldKey: Equatable {
    let turns: [ToasttyTranscriptTurn]
    let settledIDs: Set<ToasttyTranscriptRowID>
    let revision: ToasttyTranscriptRevision
    let firstSequence: UInt64?
}

private struct ScrollChangeKey: Equatable {
    let revision: ToasttyTranscriptRevision
    let blockCount: Int
    let sendItems: [ToasttySendScrollItem]
    let firstID: ToasttyTranscriptBlockID?
    let lastTarget: ToasttyConversationScrollTarget?
}

private struct ToasttySendScrollItem: Equatable {
    enum ContentKind: Equatable {
        case optimistic
        case receipt
    }

    let clientRequestID: String
    let contentKind: ContentKind

    init(_ item: ToasttySendPresentationItem) {
        clientRequestID = item.clientRequestID
        contentKind = switch item.content {
        case .optimistic: .optimistic
        case .receipt: .receipt
        }
    }
}

private struct ToasttySendTailItemView: View {
    let item: ToasttySendPresentationItem
    let dismiss: () -> Void

    @ViewBuilder
    var body: some View {
        switch item.content {
        case .optimistic:
            optimisticBubble
        case .receipt(let receipt):
            receiptCard(receipt)
        }
    }

    private var optimisticBubble: some View {
        VStack(alignment: .trailing, spacing: 7) {
            Text(item.text)
                .font(.body)
                .foregroundStyle(ToasttyDesignTokens.userBubbleText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(ToasttyDesignTokens.amberText)
                Text("Sending…")
                    .font(.caption2.monospaced())
                    .foregroundStyle(ToasttyDesignTokens.amberText)
            }
        }
        .padding(12)
        .background(ToasttyDesignTokens.userBubbleSurface)
        .overlay {
            ToasttyDesignTokens.userBubbleShape
                .stroke(ToasttyDesignTokens.userBubbleBorder)
        }
        .clipShape(ToasttyDesignTokens.userBubbleShape)
        .padding(.leading, 48)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.text), Sending")
        .accessibilityIdentifier("toastty-mobile-send-optimistic-\(item.clientRequestID)")
    }

    private func receiptCard(
        _ receipt: ToasttySendReceiptPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ToasttyDesignTokens.red)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(receipt.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ToasttyDesignTokens.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(receipt.detail)
                        .font(.caption)
                        .foregroundStyle(ToasttyDesignTokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 44, height: 44)
                }
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .accessibilityLabel("Dismiss delivery receipt")
                .accessibilityIdentifier(
                    "toastty-mobile-send-receipt-dismiss-\(item.clientRequestID)"
                )
            }

            Text(item.text)
                .font(.caption.monospaced())
                .foregroundStyle(ToasttyDesignTokens.mutedText)
                .lineLimit(3)
                .padding(.leading, 28)
        }
        .padding(12)
        .background(ToasttyDesignTokens.raisedSurface)
        .overlay {
            RoundedRectangle(
                cornerRadius: ToasttyDesignTokens.cardCornerRadius,
                style: .continuous
            )
            .stroke(ToasttyDesignTokens.red.opacity(0.5))
        }
        .clipShape(RoundedRectangle(
            cornerRadius: ToasttyDesignTokens.cardCornerRadius,
            style: .continuous
        ))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toastty-mobile-send-receipt-\(item.clientRequestID)")
    }
}

private struct ToasttyTranscriptRowView: View {
    let row: ToasttyTranscriptRow
    var chunk: ToasttyTranscriptMessageChunk?
    var isDemoted = false
    let subagentIsExpanded: Bool
    let toggleSubagentExpansion: () -> Void

    @ViewBuilder
    var body: some View {
        switch row.content {
        case .interaction(let interaction):
            ToasttyInteractionCard(interaction: interaction)
                .accessibilityIdentifier(rowAccessibilityIdentifier)
                .overlay {
                    if interaction.state == .pending {
                        Color.clear
                            .accessibilityElement()
                            .accessibilityLabel(
                                "Read-only interaction, \(interaction.prompt), Respond on the desktop"
                            )
                            .accessibilityIdentifier("toastty-mobile-readonly-interaction")
                    }
                }
        default:
            rowContent
                .accessibilityIdentifier(rowAccessibilityIdentifier)
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        switch row.content {
        case .userMessage(let text, let origin):
            message(
                text: text,
                isUser: true,
                metadata: origin == .remote ? "sent remotely" : nil
            )
        case .assistantMessage(let text, let phase):
            // A chunked message renders this row's slice; the metadata caption
            // belongs to the final slice only.
            message(
                text: chunk?.text ?? text,
                isUser: false,
                metadata: phase == .commentary && (chunk?.isLast ?? true) ? "commentary" : nil
            )
        case .statusChanged(let state, let availability):
            marker(icon: "circle.dotted", text: "\(state) · \(availability)")
        case .interaction:
            EmptyView()
        case .interactionResolved(_, let resolution):
            marker(icon: resolutionIcon(resolution), text: "interaction \(resolution.rawValue)")
        case .subagentSummary(let name, let phase, let detail):
            disclosureRow(
                icon: "person.2",
                title: "\(name) · \(subagentPhaseLabel(phase))",
                detail: detail,
                isExpanded: subagentIsExpanded,
                action: toggleSubagentExpansion
            )
        case .sessionBindingChanged(let reason):
            marker(icon: "link", text: bindingLabel(reason))
        case .toolStarted, .toolFinished:
            EmptyView()
        }
    }

    private var rowAccessibilityIdentifier: String {
        // Only the first chunk keeps the bare row identifier so accessibility
        // queries for a row stay unambiguous.
        if let chunk, chunk.isFirst == false {
            return "toastty-mobile-transcript-row-\(row.id.accessibilitySuffix)-c\(chunk.index)"
        }
        return "toastty-mobile-transcript-row-\(row.id.accessibilitySuffix)"
    }

    @ViewBuilder
    private func message(text: String, isUser: Bool, metadata: String?) -> some View {
        let content = VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
            if isUser {
                Text(text)
                    .font(.body)
                    .foregroundStyle(ToasttyDesignTokens.userBubbleText)
                    .textSelection(.enabled)
            } else {
                ToasttyMarkdownText(
                    text: text,
                    textColor: isDemoted
                        ? ToasttyDesignTokens.secondaryText
                        : ToasttyDesignTokens.primaryText
                )
            }

            if let metadata {
                Text(metadata)
                    .font(.caption2.monospaced())
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
            }
        }

        if isUser {
            content
                .padding(12)
                .background(ToasttyDesignTokens.userBubbleSurface)
                .overlay {
                    ToasttyDesignTokens.userBubbleShape
                        .stroke(ToasttyDesignTokens.userBubbleBorder)
                }
                .clipShape(ToasttyDesignTokens.userBubbleShape)
                .padding(.leading, 48)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityElement(children: .combine)
        } else {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
        }
    }

    private func marker(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2.monospaced())
            .foregroundStyle(ToasttyDesignTokens.mutedText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .accessibilityElement(children: .combine)
    }

    private func disclosureRow(
        icon: String,
        title: String,
        detail: String?,
        isExpanded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                HStack(spacing: 7) {
                    Image(systemName: icon)
                    Text(title)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                }
                .font(.caption.monospaced())
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityIdentifier("toastty-mobile-transcript-subagent-\(row.id.accessibilitySuffix)")

            if isExpanded, let detail, detail.isEmpty == false {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                    .textSelection(.enabled)
            }
        }
    }

    private func subagentPhaseLabel(_ phase: ConversationSubagentPhase) -> String {
        switch phase {
        case .started: "started"
        case .updated: "updated"
        case .finished: "finished"
        case .unknown: "activity"
        }
    }

    private func bindingLabel(_ reason: ConversationBindingChangeReason) -> String {
        switch reason {
        case .runtimeBound: "session connected"
        case .runtimeResumed: "session resumed"
        case .runtimeEnded: "session disconnected"
        case .projectionRebuilt: "transcript rebuilt"
        }
    }

    private func resolutionIcon(_ resolution: RemotePendingInteraction.State) -> String {
        switch resolution {
        case .pending: "hourglass"
        case .resolved: "checkmark.circle"
        case .superseded: "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }
}

struct ToasttyMarkdownText: View {
    let text: String
    var textColor: Color = ToasttyDesignTokens.primaryText

    var body: some View {
        // Matches the transcript stack spacing so the seams between chunks of
        // a split message are indistinguishable from in-message block gaps.
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.blocks(text)) { block in
                blockView(block)
            }
        }
        .foregroundStyle(textColor)
        .lineSpacing(6)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func blockView(_ block: ToasttyMarkdownBlock) -> some View {
        switch block.style {
        case .paragraph:
            Text(block.content)
                .font(.body)
        case .heading(let level):
            Text(block.content)
                .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, block.id == 0 ? 0 : 2)
        case .list(let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker.label)
                    .font(.body.monospaced())
                    .foregroundStyle(ToasttyDesignTokens.secondaryText)
                    .frame(minWidth: 16, alignment: .trailing)
                Text(block.content)
                    .font(.body)
            }
            .padding(.leading, CGFloat(max(0, depth - 1)) * 16)
        case .blockQuote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(ToasttyDesignTokens.border)
                    .frame(width: 3)
                Text(block.content)
                    .font(.body)
                    .foregroundStyle(ToasttyDesignTokens.secondaryText)
            }
        case .code(let language):
            VStack(alignment: .leading, spacing: 0) {
                if let language, language.isEmpty == false {
                    Text(language)
                        .font(.caption2.monospaced())
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ToasttyDesignTokens.codeHeaderSurface)
                    Divider()
                        .overlay(ToasttyDesignTokens.border)
                }
                Text(block.content)
                    .font(.body.monospaced())
                    .lineSpacing(4)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ToasttyDesignTokens.raisedSurface)
            .overlay {
                RoundedRectangle(
                    cornerRadius: ToasttyDesignTokens.controlCornerRadius,
                    style: .continuous
                )
                .stroke(ToasttyDesignTokens.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(
                cornerRadius: ToasttyDesignTokens.controlCornerRadius,
                style: .continuous
            ))
        }
    }

    /// Parsed-block cache: with eager transcript layout every message re-parses
    /// on each body evaluation without it. Keyed by the raw markdown text.
    private static let parsedBlockCache: NSCache<NSString, ParsedMarkdownBlocks> = {
        let cache = NSCache<NSString, ParsedMarkdownBlocks>()
        cache.countLimit = 600
        return cache
    }()

    private final class ParsedMarkdownBlocks {
        let blocks: [ToasttyMarkdownBlock]
        init(_ blocks: [ToasttyMarkdownBlock]) { self.blocks = blocks }
    }

    static func blocks(_ text: String) -> [ToasttyMarkdownBlock] {
        let key = text as NSString
        if let cached = parsedBlockCache.object(forKey: key) {
            return cached.blocks
        }
        let parsed = parseBlocks(text)
        parsedBlockCache.setObject(ParsedMarkdownBlocks(parsed), forKey: key)
        return parsed
    }

    private static func parseBlocks(_ text: String) -> [ToasttyMarkdownBlock] {
        guard let attributed = try? AttributedString(markdown: text) else {
            return [ToasttyMarkdownBlock(
                id: 0,
                content: AttributedString(text),
                style: .paragraph
            )]
        }

        var blocks: [ToasttyMarkdownBlock] = []
        var currentPresentationIdentity: Int?
        var currentContent = AttributedString()
        var currentStyle = ToasttyMarkdownBlock.Style.paragraph

        func flushCurrentBlock() {
            guard currentContent.characters.isEmpty == false else { return }
            let isCodeBlock = if case .code = currentStyle { true } else { false }
            blocks.append(ToasttyMarkdownBlock(
                id: blocks.count,
                content: isCodeBlock ? currentContent : stylingInlineContent(currentContent),
                style: currentStyle
            ))
            currentContent = AttributedString()
        }

        for run in attributed.runs {
            let intent = run.presentationIntent
            let identity = intent?.components.first?.identity
            if identity != currentPresentationIdentity {
                flushCurrentBlock()
                currentPresentationIdentity = identity
                currentStyle = Self.style(for: intent)
            }
            currentContent.append(AttributedString(attributed[run.range]))
        }
        flushCurrentBlock()

        if blocks.isEmpty, text.isEmpty == false {
            return [ToasttyMarkdownBlock(
                id: 0,
                content: AttributedString(text),
                style: .paragraph
            )]
        }
        return blocks
    }

    /// Tints inline code and semantic external web links. Inline code wins
    /// when Markdown assigns both attributes, while the link itself remains
    /// intact for SwiftUI interaction.
    private static func stylingInlineContent(_ content: AttributedString) -> AttributedString {
        guard content.runs.contains(where: {
            $0.inlinePresentationIntent?.contains(.code) == true
                || isExternalWebLink($0.link)
        }) else { return content }

        var styled = AttributedString()
        for run in content.runs {
            var piece = AttributedString(content[run.range])
            if run.inlinePresentationIntent?.contains(.code) == true {
                piece.foregroundColor = ToasttyDesignTokens.amberText
                piece.backgroundColor = ToasttyDesignTokens.chipSurface
            } else if isExternalWebLink(run.link) {
                piece.foregroundColor = ToasttyDesignTokens.externalLink
            }
            styled.append(piece)
        }
        return styled
    }

    private static func isExternalWebLink(_ url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }
        return url.host?.isEmpty == false
    }

    private static func style(
        for intent: PresentationIntent?
    ) -> ToasttyMarkdownBlock.Style {
        guard let intent else { return .paragraph }

        var headingLevel: Int?
        var codeLanguage: String?
        var isCode = false
        var isBlockQuote = false
        var listOrdinal: Int?
        var listMarker: ToasttyMarkdownBlock.ListMarker?
        var listDepth = 0

        for component in intent.components {
            switch component.kind {
            case .header(let level):
                headingLevel = level
            case .codeBlock(let language):
                isCode = true
                codeLanguage = language
            case .blockQuote:
                isBlockQuote = true
            case .listItem(let ordinal):
                if listOrdinal == nil { listOrdinal = ordinal }
            case .orderedList:
                listDepth += 1
                if listMarker == nil {
                    listMarker = .ordered(listOrdinal ?? 1)
                }
            case .unorderedList:
                listDepth += 1
                if listMarker == nil { listMarker = .bullet }
            case .paragraph, .thematicBreak, .table, .tableHeaderRow,
                 .tableRow(_), .tableCell(_):
                break
            @unknown default:
                break
            }
        }

        if isCode { return .code(language: codeLanguage) }
        if let headingLevel { return .heading(level: headingLevel) }
        if let listMarker { return .list(marker: listMarker, depth: listDepth) }
        if isBlockQuote { return .blockQuote }
        return .paragraph
    }
}

struct ToasttyMarkdownBlock: Identifiable {
    enum ListMarker: Equatable {
        case bullet
        case ordered(Int)

        var label: String {
            switch self {
            case .bullet: "•"
            case .ordered(let ordinal): "\(ordinal)."
            }
        }
    }

    enum Style: Equatable {
        case paragraph
        case heading(level: Int)
        case list(marker: ListMarker, depth: Int)
        case blockQuote
        case code(language: String?)
    }

    let id: Int
    let content: AttributedString
    let style: Style
}

private struct ToasttyInteractionCard: View {
    let interaction: RemotePendingInteraction

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Label(kindLabel, systemImage: kindIcon)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(accentColor)
                Spacer(minLength: 6)
                Text(interaction.state.rawValue)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(stateColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(stateColor.opacity(0.12), in: Capsule())
            }

            Text(interaction.prompt)
                .font(.body)
                .foregroundStyle(ToasttyDesignTokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if interaction.options.isEmpty == false {
                // Plain text, deliberately without selection affordances:
                // options are read-only here and answered on the Mac.
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(interaction.options, id: \.id) { option in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .font(.subheadline.weight(.medium))
                            if let detail = option.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                            }
                        }
                        .foregroundStyle(ToasttyDesignTokens.secondaryText)
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if interaction.state == .pending {
                Label("Respond on the desktop", systemImage: "desktopcomputer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ToasttyDesignTokens.amberText)
            }
        }
        .padding(14)
        .background(ToasttyDesignTokens.interactionSurface)
        .overlay {
            RoundedRectangle(
                cornerRadius: ToasttyDesignTokens.cardCornerRadius,
                style: .continuous
            )
            .stroke(accentColor.opacity(0.35))
        }
        .clipShape(RoundedRectangle(
            cornerRadius: ToasttyDesignTokens.cardCornerRadius,
            style: .continuous
        ))
        .accessibilityElement(children: .combine)
    }

    private var kindLabel: String {
        switch interaction.kind {
        case .permission: "Permission request"
        case .question: "Question"
        case .structuredChoice: "Choose on Mac"
        case .freeForm: "Response requested"
        }
    }

    private var kindIcon: String {
        switch interaction.kind {
        case .permission: "lock.shield"
        case .question: "questionmark.bubble"
        case .structuredChoice: "list.bullet.circle"
        case .freeForm: "text.bubble"
        }
    }

    private var accentColor: Color {
        interaction.state == .pending ? ToasttyDesignTokens.amber : ToasttyDesignTokens.secondaryText
    }

    private var stateColor: Color {
        switch interaction.state {
        case .pending: ToasttyDesignTokens.amberText
        case .resolved: ToasttyDesignTokens.green
        case .superseded: ToasttyDesignTokens.mutedText
        }
    }
}

private extension View {
    func transcriptBannerStyle(color: Color) -> some View {
        self
            .font(.caption.monospaced())
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ToasttyDesignTokens.raisedSurface)
            .clipShape(RoundedRectangle(
                cornerRadius: ToasttyDesignTokens.controlCornerRadius,
                style: .continuous
            ))
            .accessibilityElement(children: .combine)
    }
}
