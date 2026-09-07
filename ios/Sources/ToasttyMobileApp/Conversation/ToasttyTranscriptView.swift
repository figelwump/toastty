import RemoteProtocol
import SwiftUI
import UIKit
import ToasttyMobileDomain

struct ToasttyTranscriptView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    let state: ToasttyConversationPresentationState
    let loadOlder: () -> Void
    let dismissSendReceipt: (String) -> Void
    let interactionAnswerStates: [RemotePendingInteraction.ID: ToasttyInteractionAnswerState]
    let editInteractionAnswer: (RemotePendingInteraction.ID, ToasttyInteractionAnswerEdit) -> Void
    let submitInteractionAnswer: (RemotePendingInteraction.ID) -> Void
    let readAcknowledgementEpoch: MobileSessionStatus?
    let onVisibleLiveEdge: () -> Void
    @Binding private var jumpToLiveEdgeRequest: UInt64

    @State private var toolBatchDisclosure = ToasttyToolBatchDisclosureState()
    @State private var turnFold = ToasttyTurnFoldState()
    @State private var expandedSubagentIDs: Set<ToasttyTranscriptRowID> = []
    @State private var isAtLiveEdge = true
    @State private var hasReachedPhysicalLiveEdge = true
    @State private var hasMeasuredScrollGeometry = false
    @State private var measuredBoundaryID: ToasttyTranscriptRowID?
    @State private var isVisible = false
    @State private var followsLiveEdge = true
    @State private var visibleBlockIDs: [ToasttyTranscriptBlockID] = []
    @State private var scrollCoordinator = TranscriptScrollCoordinator()
    #if DEBUG
    @State private var fixtureScrollTrace = TranscriptFixtureScrollTrace()
    #endif

    init(
        state: ToasttyConversationPresentationState,
        loadOlder: @escaping () -> Void = {},
        dismissSendReceipt: @escaping (String) -> Void = { _ in },
        interactionAnswerStates: [RemotePendingInteraction.ID: ToasttyInteractionAnswerState] = [:],
        editInteractionAnswer: @escaping (
            RemotePendingInteraction.ID,
            ToasttyInteractionAnswerEdit
        ) -> Void = { _, _ in },
        submitInteractionAnswer: @escaping (RemotePendingInteraction.ID) -> Void = { _ in },
        readAcknowledgementEpoch: MobileSessionStatus? = nil,
        jumpToLiveEdgeRequest: Binding<UInt64>,
        onVisibleLiveEdge: @escaping () -> Void = {}
    ) {
        self.state = state
        self.loadOlder = loadOlder
        self.dismissSendReceipt = dismissSendReceipt
        self.interactionAnswerStates = interactionAnswerStates
        self.editInteractionAnswer = editInteractionAnswer
        self.submitInteractionAnswer = submitInteractionAnswer
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
                // Keep the content's bottom fixed in the same layout pass as
                // keyboard dismissal, composer collapse, and appended rows.
                // A pending submit applies before its command task executes.
                .defaultScrollAnchor(
                    followsLiveEdge || scrollCoordinator.ownsLiveEdge || jumpToLiveEdgeRequest > 0
                        ? .bottom : nil,
                    for: .sizeChanges
                )
                .overlay(alignment: .topLeading) {
                    #if DEBUG
                    if TranscriptFixtureScrollTrace.isEnabled {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityElement()
                            .accessibilityLabel("Transcript scroll trace")
                            .accessibilityValue(fixtureScrollTrace.encodedSamples)
                            .accessibilityIdentifier("toastty-mobile-transcript-scroll-trace")
                    }
                    #endif
                }
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
                    #if DEBUG
                    fixtureScrollTrace.record(new, hasSendItems: !state.sendItems.isEmpty)
                    #endif
                    let hadMeasuredScrollGeometry = hasMeasuredScrollGeometry
                    let atLiveEdge = new.isNearLiveEdge
                    let reachedPhysicalLiveEdge = new.hasReachedPhysicalLiveEdge
                    hasMeasuredScrollGeometry = true
                    measuredBoundaryID = state.rows.last?.id
                    isAtLiveEdge = atLiveEdge
                    hasReachedPhysicalLiveEdge = reachedPhysicalLiveEdge
                    if hadMeasuredScrollGeometry,
                       new.hasLiveEdgeLayoutChange(comparedTo: old),
                       lastScrollTarget != nil,
                       followsLiveEdge || scrollCoordinator.ownsLiveEdge {
                        // Layout changes reinforce the current owner through
                        // the same serialized command path as transcript
                        // changes; they never race a separate scroll writer.
                        scrollCoordinator.reinforceLiveEdge()
                    }
                    if reachedPhysicalLiveEdge {
                        if case .send(let request)? = scrollCoordinator.liveEdgeOwner,
                           jumpToLiveEdgeRequest == request,
                           scrollCoordinator.finishSend(atLiveEdge: true) {
                            jumpToLiveEdgeRequest = 0
                            followsLiveEdge = true
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
                        #if DEBUG
                        fixtureScrollTrace.stop()
                        #endif
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
                    ).isNearLiveEdge
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
                    #if DEBUG
                    fixtureScrollTrace.begin()
                    #endif
                    scrollCoordinator.requestSend(request)
                }
                .onChange(of: scrollChangeKey, initial: true) { _, _ in
                    reconcileScrollChange()
                }
                .task(id: scrollCoordinator.command) {
                    guard let command = scrollCoordinator.command else { return }
                    if command.motion == .stable {
                        // Stable moves wait for one quiet layout interval. New
                        // layout generations coalesce into this pending command
                        // instead of repeatedly restarting its task. Sustained
                        // growth is bounded so it cannot starve the first move;
                        // any later generation schedules a follow-up command.
                        var completedSettleChecks = 0
                        while true {
                            guard let candidate = scrollCoordinator.executionCandidate(
                                for: command
                            ) else { return }
                            try? await Task.sleep(
                                for: TranscriptScrollCoordinator.stableSettleInterval
                            )
                            guard Task.isCancelled == false else { return }
                            guard let settled = scrollCoordinator.executionCandidate(
                                for: command
                            ) else { return }
                            completedSettleChecks += 1
                            let isQuiet = candidate.layoutGeneration
                                == settled.layoutGeneration
                            guard TranscriptScrollCoordinator.shouldExecuteStableCandidate(
                                isQuiet: isQuiet,
                                completedSettleChecks: completedSettleChecks
                            ) else {
                                continue
                            }
                            guard scrollCoordinator.markExecuted(settled) else { continue }
                            break
                        }
                    } else {
                        // Submit acquires the bottom without animation or a
                        // settling delay; Jump to Latest keeps its animation.
                        // Native size-change anchoring covers subsequent layout.
                        await Task.yield()
                        guard Task.isCancelled == false,
                              let candidate = scrollCoordinator.executionCandidate(for: command),
                              scrollCoordinator.markExecuted(candidate)
                        else { return }
                    }
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
                        if hasReachedPhysicalLiveEdge == false {
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
                        followsLiveEdge = hasReachedPhysicalLiveEdge
                        _ = scrollCoordinator.finishSend(
                            atLiveEdge: hasReachedPhysicalLiveEdge
                        )
                    } else if case .jump? = command.liveEdgeOwner {
                        followsLiveEdge = hasReachedPhysicalLiveEdge
                        _ = scrollCoordinator.finishJump(
                            atLiveEdge: hasReachedPhysicalLiveEdge
                        )
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
                    withAnimation(reducesMotion ? nil : .easeInOut(duration: 0.25), apply)
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
                    withAnimation(reducesMotion ? nil : .easeInOut(duration: 0.22)) {
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
                toggleSubagentExpansion: { toggle(row.id, in: &expandedSubagentIDs) },
                interactionAnswerStates: interactionAnswerStates,
                editInteractionAnswer: editInteractionAnswer,
                submitInteractionAnswer: submitInteractionAnswer
            )
        case .messageChunk(let chunk):
            ToasttyTranscriptRowView(
                row: chunk.row,
                chunk: chunk,
                isDemoted: demoted,
                subagentIsExpanded: false,
                toggleSubagentExpansion: {},
                interactionAnswerStates: interactionAnswerStates,
                editInteractionAnswer: editInteractionAnswer,
                submitInteractionAnswer: submitInteractionAnswer
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

        if command.motion == .animated, !reducesMotion {
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
        withAnimation(reducesMotion ? nil : .easeInOut(duration: 0.2)) {
            if values.contains(id) {
                values.remove(id)
            } else {
                values.insert(id)
            }
        }
    }
}

struct TranscriptScrollMetrics: Equatable {
    static let nearLiveEdgeThreshold: CGFloat = 72
    static let physicalLiveEdgeEpsilon: CGFloat = 1
    static let viewportResizeThreshold: CGFloat = 0.5

    let contentHeight: CGFloat
    let visibleMaxY: CGFloat
    let visibleHeight: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let containerHeight: CGFloat

    init(geometry: ScrollGeometry) {
        contentHeight = geometry.contentSize.height
        // visibleRect includes the safe-area regions behind the composer and
        // keyboard. Only the inset-excluded viewport can establish that the
        // transcript's bottom is actually visible.
        visibleMaxY = geometry.visibleRect.maxY - geometry.contentInsets.bottom
        visibleHeight = max(
            0,
            geometry.visibleRect.height - geometry.contentInsets.top - geometry.contentInsets.bottom
        )
        topInset = geometry.contentInsets.top
        bottomInset = geometry.contentInsets.bottom
        containerHeight = geometry.containerSize.height
    }

    init(
        contentHeight: CGFloat,
        visibleMaxY: CGFloat,
        visibleHeight: CGFloat
    ) {
        self.contentHeight = contentHeight
        self.visibleMaxY = visibleMaxY
        self.visibleHeight = visibleHeight
        topInset = 0
        bottomInset = 0
        containerHeight = visibleHeight
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

    var isNearLiveEdge: Bool {
        distanceFromBottom < Self.nearLiveEdgeThreshold
    }

    /// Completion is intentionally tighter than the user-facing near-tail
    /// threshold. A negative distance is valid during bottom overscroll or
    /// when the content is shorter than the viewport.
    var hasReachedPhysicalLiveEdge: Bool {
        distanceFromBottom <= Self.physicalLiveEdgeEpsilon
    }

    var isAtLiveEdge: Bool {
        isNearLiveEdge
    }
}

#if DEBUG
/// UI tests collect one coherent geometry sample per layout change. Reading
/// separate accessibility frames can straddle the keyboard animation and report
/// movement that never appeared in a single frame.
private struct TranscriptFixtureScrollTrace {
    static let isEnabled = ProcessInfo.processInfo.environment[
        "TOASTTY_MOBILE_FIXTURE_SCROLL_TRACE"
    ] == "1"

    struct Sample: Encodable {
        let elapsed: Double
        let contentHeight: CGFloat
        let visibleMaxY: CGFloat
        let visibleHeight: CGFloat
        let topInset: CGFloat
        let bottomInset: CGFloat
        let containerHeight: CGFloat
        let hasSendItems: Bool
    }

    private var latest: TranscriptScrollMetrics?
    private var startedAt: TimeInterval?
    private var samples: [Sample] = []

    var encodedSamples: String {
        guard let data = try? JSONEncoder().encode(samples) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    mutating func begin() {
        guard Self.isEnabled else { return }
        samples = []
        startedAt = ProcessInfo.processInfo.systemUptime
        if let latest { record(latest, hasSendItems: false) }
    }

    mutating func stop() {
        startedAt = nil
    }

    mutating func record(_ metrics: TranscriptScrollMetrics, hasSendItems: Bool) {
        guard Self.isEnabled else { return }
        latest = metrics
        guard let startedAt, samples.count < 512 else { return }
        samples.append(Sample(
            elapsed: ProcessInfo.processInfo.systemUptime - startedAt,
            contentHeight: metrics.contentHeight,
            visibleMaxY: metrics.visibleMaxY,
            visibleHeight: metrics.visibleHeight,
            topInset: metrics.topInset,
            bottomInset: metrics.bottomInset,
            containerHeight: metrics.containerHeight,
            hasSendItems: hasSendItems
        ))
    }
}
#endif

struct TranscriptScrollCoordinator: Equatable {
    static let stableSettleInterval: Duration = .milliseconds(50)
    static let maximumStableSettleChecks = 4

    enum LiveEdgeOwner: Equatable {
        case automatic
        case send(UInt64)
        case jump(UInt64)
    }

    enum Motion: Equatable {
        case immediate
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

    struct ExecutionCandidate: Equatable {
        let command: Command
        let layoutGeneration: UInt64
    }

    private(set) var liveEdgeOwner: LiveEdgeOwner?
    private(set) var command: Command?
    private var nextSequence: UInt64 = 0
    private var nextJumpRequest: UInt64 = 0
    private var liveEdgeLayoutGeneration: UInt64 = 0
    private var executedCommandSequence: UInt64?

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

    static func shouldExecuteStableCandidate(
        isQuiet: Bool,
        completedSettleChecks: Int
    ) -> Bool {
        isQuiet || completedSettleChecks >= maximumStableSettleChecks
    }

    mutating func requestInitialLiveEdge() {
        issueLiveEdge(owner: .automatic, motion: .stable)
    }

    mutating func requestSend(_ request: UInt64) {
        issueLiveEdge(owner: .send(request), motion: .immediate)
    }

    mutating func requestJump() {
        nextJumpRequest &+= 1
        issueLiveEdge(owner: .jump(nextJumpRequest), motion: .animated)
    }

    mutating func reinforceLiveEdge() {
        let owner = liveEdgeOwner ?? .automatic
        liveEdgeOwner = owner
        advanceLiveEdgeLayoutGeneration()

        if let command,
           command.target == .liveEdge,
           command.liveEdgeOwner == owner,
           executedCommandSequence != command.sequence {
            // Equivalent work that arrives before execution belongs to the
            // same pending operation. Immediate sends use the latest generation;
            // stable commands wait for that generation's layout to settle.
            return
        }

        // Once the pending operation has executed, a later generation needs a
        // fresh command so SwiftUI starts a follow-up task rather than losing
        // late content growth.
        issue(target: .liveEdge, motion: .stable, liveEdgeOwner: owner)
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
        executedCommandSequence = nil
    }

    /// Returns true when an active jump completed at the live edge.
    @discardableResult
    mutating func finishJump(atLiveEdge: Bool) -> Bool {
        guard case .jump? = liveEdgeOwner,
              currentCommandHasExecuted
        else { return false }
        liveEdgeOwner = atLiveEdge ? .automatic : nil
        command = nil
        executedCommandSequence = nil
        return atLiveEdge
    }

    /// Returns true when an active send completed at the live edge. A failed
    /// acquisition releases ownership so the recovery affordance can appear.
    @discardableResult
    mutating func finishSend(atLiveEdge: Bool) -> Bool {
        guard case .send? = liveEdgeOwner,
              currentCommandHasExecuted
        else { return false }
        liveEdgeOwner = atLiveEdge ? .automatic : nil
        command = nil
        executedCommandSequence = nil
        return atLiveEdge
    }

    func executionCandidate(for command: Command) -> ExecutionCandidate? {
        guard self.command == command,
              executedCommandSequence != command.sequence
        else { return nil }
        return ExecutionCandidate(
            command: command,
            layoutGeneration: liveEdgeLayoutGeneration
        )
    }

    /// Marks exactly the observed generation. A newer generation must be
    /// observed by the task instead of being silently consumed.
    mutating func markExecuted(_ candidate: ExecutionCandidate) -> Bool {
        guard command == candidate.command,
              liveEdgeLayoutGeneration == candidate.layoutGeneration,
              executedCommandSequence != candidate.command.sequence
        else { return false }
        executedCommandSequence = candidate.command.sequence
        return true
    }

    private var currentCommandHasExecuted: Bool {
        guard let command else { return false }
        return executedCommandSequence == command.sequence
    }

    private mutating func issueLiveEdge(owner: LiveEdgeOwner, motion: Motion) {
        liveEdgeOwner = owner
        advanceLiveEdgeLayoutGeneration()
        issue(target: .liveEdge, motion: motion, liveEdgeOwner: owner)
    }

    private mutating func advanceLiveEdgeLayoutGeneration() {
        liveEdgeLayoutGeneration &+= 1
    }

    private mutating func issue(
        target: Target,
        motion: Motion,
        liveEdgeOwner: LiveEdgeOwner?
    ) {
        nextSequence &+= 1
        executedCommandSequence = nil
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

            Button {
                UIPasteboard.general.string = item.text
            } label: {
                Label("Copy attempted message", systemImage: "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44)
            }
            .foregroundStyle(ToasttyDesignTokens.amberText)
            .padding(.leading, 28)
            .accessibilityIdentifier("toastty-mobile-send-receipt-copy-\(item.clientRequestID)")

            Text(item.text)
                .font(.caption.monospaced())
                .foregroundStyle(ToasttyDesignTokens.mutedText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
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
    let interactionAnswerStates: [RemotePendingInteraction.ID: ToasttyInteractionAnswerState]
    let editInteractionAnswer: (RemotePendingInteraction.ID, ToasttyInteractionAnswerEdit) -> Void
    let submitInteractionAnswer: (RemotePendingInteraction.ID) -> Void

    @ViewBuilder
    var body: some View {
        switch row.content {
        case .interaction(let presentation):
            let interaction = presentation.interaction
            ToasttyInteractionCard(
                presentation: presentation,
                answerState: interactionAnswerStates[interaction.id],
                onEdit: { editInteractionAnswer(interaction.id, $0) },
                onSubmit: { submitInteractionAnswer(interaction.id) }
            )
                .accessibilityIdentifier(rowAccessibilityIdentifier)
                .overlay {
                    if interaction.state == .pending,
                       interactionAnswerStates[interaction.id] == nil {
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
                text: text,
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
        let containsTable = !isUser && (chunk?.blocks ?? ToasttyMarkdownText.blocks(text)).contains { block in
            if case .table = block.style { return true }
            return false
        }
        let content = VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
            if isUser {
                Text(text)
                    .font(.body)
                    .foregroundStyle(ToasttyDesignTokens.userBubbleText)
                    .textSelection(.enabled)
            } else {
                ToasttyMarkdownText(
                    text: text,
                    preparedBlocks: chunk?.blocks,
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
                // Combining the whole message hides descendants of nested
                // horizontal scroll views from VoiceOver.
                .accessibilityElement(children: containsTable ? .contain : .combine)
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
