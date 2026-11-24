import Foundation
import RemoteProtocol

/// The transcript's layout decisions that do not depend on the toolkit: the
/// running turn, the rows of quiet checks, where the working line goes and
/// the items in display order. `ToasttyTranscriptView` (SwiftUI) and the GTK
/// coordinator chat draw these.
enum ToasttyTranscriptLayout {
    /// The last turn while it has not settled.
    static func liveTurnID(
        _ state: ToasttyConversationPresentationState,
        isSessionWorking: Bool,
        isSubmitting: Bool = false
    ) -> ToasttyTranscriptRowID? {
        guard let last = state.turns.last else { return nil }
        let settled = state.settledTurnIDs(isSessionWorking: isSessionWorking, isSubmitting: isSubmitting)
        return settled.contains(last.id) ? nil : last.id
    }

    /// The rows of quiet checks. The turn that runs and has no answer yet
    /// keeps its own line, which shows that the agent works. Once its
    /// answer comes it joins, also while the agent still works.
    static func quietCheckRuns(
        _ state: ToasttyConversationPresentationState,
        liveTurnID: ToasttyTranscriptRowID?
    ) -> [ToasttyQuietCheckRun] {
        let runningTurnID = state.turns.last.flatMap { turn in
            turn.id == liveTurnID && turn.hasResponse == false ? turn.id : nil
        }
        return state.quietCheckRuns(runningTurnID: runningTurnID)
    }

    static func workingLine(
        _ state: ToasttyConversationPresentationState,
        isWorking: Bool,
        foldsRunningWork: Bool,
        liveTurnID: ToasttyTranscriptRowID?,
        turnFold: ToasttyTurnFoldState
    ) -> ToasttyTranscriptWorkingLine {
        .place(
            isWorking: isWorking && state.phase == .live,
            foldsRunningWork: foldsRunningWork,
            sendItems: state.sendItems,
            liveTurn: liveTurnID == nil ? nil : state.turns.last,
            isLiveTurnExpanded: liveTurnID.map(turnFold.isExpanded) ?? false
        )
    }

    /// Blocks interleaved with per-turn work strips; a folded turn's work
    /// blocks are omitted and its strip stands in for them.
    static func displayItems(
        _ state: ToasttyConversationPresentationState,
        workingLine: ToasttyTranscriptWorkingLine,
        turnFold: ToasttyTurnFoldState,
        quietCheckFold: ToasttyQuietCheckFoldState,
        quietCheckRuns: [ToasttyQuietCheckRun],
        foldsRunningWork: Bool
    ) -> [ToasttyTranscriptDisplayItem] {
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
        // A row of quiet checks shows its line before its first turn's
        // line. Closed, it hides its turns' lines and work.
        var quietRunAtFirstLine: [ToasttyTranscriptBlockID: ToasttyQuietCheckRun] = [:]
        var closedQuietTurnIDs: Set<ToasttyTranscriptRowID> = []
        for run in quietCheckRuns {
            quietRunAtFirstLine[ToasttyTranscriptBlockID(rowID: run.id)] = run
            if quietCheckFold.isOpen(run) == false {
                closedQuietTurnIDs.formUnion(run.turnIDs)
            }
        }
        // The running turn's strip shows that the agent works from the
        // turn's start, under its message, before any work comes.
        var stripAfterAnchor: ToasttyTranscriptTurn?
        if case .turn(let turnID) = workingLine,
           let turn = state.turns.last, turn.id == turnID, turn.workBlockIDs.isEmpty,
           turn.opensFromAnchorLine(foldsRunningWork: foldsRunningWork) == false {
            stripAfterAnchor = turn
        }

        var items: [ToasttyTranscriptDisplayItem] = []
        items.reserveCapacity(state.blocks.count + state.turns.count)
        for block in state.blocks {
            if let run = quietRunAtFirstLine[block.id] {
                items.append(.quietChecks(run))
            }
            if closedQuietTurnIDs.isEmpty == false,
               closedQuietTurnIDs.contains(turnForWorkBlock[block.id] ?? block.id.rowID) {
                continue
            }
            // A turn whose host message's line opens it has no strip.
            if let turn = turnAtFirstWorkBlock[block.id],
               turn.opensFromAnchorLine(foldsRunningWork: foldsRunningWork) == false {
                items.append(.workStrip(turn))
            }
            if let turnID = turnForWorkBlock[block.id] {
                if turnFold.isExpanded(turnID) {
                    items.append(.block(block, isWork: true))
                }
            } else {
                items.append(.block(block, isWork: false))
            }
            if let turn = stripAfterAnchor, block.id.rowID == turn.id {
                items.append(.workStrip(turn))
            }
        }
        return items
    }
}
