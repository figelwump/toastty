import Foundation
import RemoteProtocol

/// Disclosure state for per-turn work sections. Settled turns fold by
/// default; the live turn streams expanded and auto-folds when its response
/// completes, unless the host folds running work too
/// (`ToasttyTranscriptOptions.foldsRunningWork`). Explicit user toggles win
/// over automatic behavior.
struct ToasttyTurnFoldState: Equatable {
    private(set) var expandedIDs: Set<ToasttyTranscriptRowID> = []
    private var explicitlyToggledIDs: Set<ToasttyTranscriptRowID> = []
    private var knownIDs: Set<ToasttyTranscriptRowID> = []

    func isExpanded(_ id: ToasttyTranscriptRowID) -> Bool {
        expandedIDs.contains(id)
    }

    mutating func toggle(_ id: ToasttyTranscriptRowID) {
        explicitlyToggledIDs.insert(id)
        if expandedIDs.remove(id) == nil {
            expandedIDs.insert(id)
        }
    }

    /// - Parameters:
    ///   - settledIDs: turns whose work may fold (response complete and the
    ///     session is no longer working on them).
    ///   - previousBoundarySequence: on `.prepended`, the first row sequence
    ///     that was already on screen before the update. A newly grouped turn
    ///     whose work reaches into the previously visible region stays
    ///     expanded so the reader's anchor cannot vanish into a fold.
    ///   - opensRunningTurns: a turn that still runs shows its work. `false`
    ///     keeps every turn folded until the reader opens it.
    mutating func reconcile(
        turns: [ToasttyTranscriptTurn],
        settledIDs: Set<ToasttyTranscriptRowID>,
        revision: ToasttyTranscriptRevision,
        previousBoundarySequence: UInt64?,
        opensRunningTurns: Bool = true
    ) {
        let currentIDs = Set(turns.map(\.id))
        func opens(_ turn: ToasttyTranscriptTurn) -> Bool {
            opensRunningTurns && settledIDs.contains(turn.id) == false
        }

        switch revision {
        case .initial, .rebuilt:
            explicitlyToggledIDs.removeAll(keepingCapacity: true)
            expandedIDs = Set(turns.filter(opens).map(\.id))
        case .appended, .metadataOnly:
            for turn in turns where explicitlyToggledIDs.contains(turn.id) == false {
                // Covers both a newly settled live turn and settled turns
                // revealed by an append.
                if opens(turn) {
                    expandedIDs.insert(turn.id)
                } else {
                    expandedIDs.remove(turn.id)
                }
            }
        case .prepended:
            for turn in turns where knownIDs.contains(turn.id) == false
                && explicitlyToggledIDs.contains(turn.id) == false {
                let reachesVisibleRegion = previousBoundarySequence.map { boundary in
                    turn.workBlockIDs.contains { $0.rowID.sequence >= boundary }
                } ?? false
                if opens(turn) {
                    expandedIDs.insert(turn.id)
                } else if reachesVisibleRegion {
                    // The reader sees this work: it stays open, as after
                    // the reader's own toggle, also when later updates
                    // come.
                    expandedIDs.insert(turn.id)
                    explicitlyToggledIDs.insert(turn.id)
                }
            }
        }

        expandedIDs.formIntersection(currentIDs)
        explicitlyToggledIDs.formIntersection(currentIDs)
        knownIDs = currentIDs
    }
}

/// Which rows of quiet checks (`ToasttyQuietCheckRun`) the reader opened.
/// Rows start closed. A row is open while any of its turns is in
/// `openTurnIDs`, so it stays open when a check joins it: at its end when a
/// turn ends quiet, or in front when older history loads. Each reconcile
/// records every turn of an open row, so the row also stays open when its
/// first turns leave it, such as when Toastty forgets their quiet marks.
struct ToasttyQuietCheckFoldState: Equatable {
    private(set) var openTurnIDs: Set<ToasttyTranscriptRowID> = []
    /// The turns in a row at the last reconcile.
    private var memberIDs: Set<ToasttyTranscriptRowID> = []

    func isOpen(_ run: ToasttyQuietCheckRun) -> Bool {
        run.turnIDs.contains(where: openTurnIDs.contains)
    }

    mutating func toggle(_ run: ToasttyQuietCheckRun) {
        if isOpen(run) {
            openTurnIDs.subtract(run.turnIDs)
        } else {
            open(run)
        }
    }

    mutating func open(_ run: ToasttyQuietCheckRun) {
        openTurnIDs.formUnion(run.turnIDs)
    }

    /// A new or rebuilt transcript closes every row, as it closes the turns
    /// that the reader opened (`ToasttyTurnFoldState`).
    ///
    /// - Parameter expandedTurnIDs: the turns whose line is open
    ///   (`ToasttyTurnFoldState.expandedIDs`). A turn that joins a closed row
    ///   while its line is open opens the row, so that what the reader sees
    ///   does not vanish: a running check that the reader opened and that
    ///   then ends quiet, or a turn that stays open because older history
    ///   loaded around what the reader saw.
    mutating func reconcile(
        runs: [ToasttyQuietCheckRun],
        revision: ToasttyTranscriptRevision,
        expandedTurnIDs: Set<ToasttyTranscriptRowID>
    ) {
        let currentMemberIDs = Set(runs.flatMap(\.turnIDs))
        switch revision {
        case .initial, .rebuilt:
            openTurnIDs.removeAll()
        case .appended, .prepended, .metadataOnly:
            openTurnIDs.formIntersection(currentMemberIDs)
        }
        for run in runs where isOpen(run) || run.turnIDs.contains(where: { turnID in
            memberIDs.contains(turnID) == false && expandedTurnIDs.contains(turnID)
        }) {
            open(run)
        }
        memberIDs = currentMemberIDs
    }
}

/// The one place that shows that the agent works: the end of the running
/// turn.
enum ToasttyTranscriptWorkingLine: Equatable {
    /// The agent does not work, or the transcript is not live.
    case none
    /// The running turn's own line: its work strip, or the line of the
    /// host's message that started it. Its work is folded, so the line is
    /// the turn's end.
    case turn(ToasttyTranscriptRowID)
    /// The line of a host's message that was typed and is not in the
    /// transcript yet. Its row's line takes over when it comes.
    case send(String)
    /// The working row at the end of the chat.
    case row

    /// - Parameters:
    ///   - isWorking: the agent works and the transcript is live.
    ///   - foldsRunningWork: `ToasttyTranscriptOptions.foldsRunningWork`.
    ///   - liveTurn: the transcript's last turn, while it is not settled.
    ///   - isLiveTurnExpanded: the reader opened that turn's work.
    static func place(
        isWorking: Bool,
        foldsRunningWork: Bool,
        sendItems: [ToasttySendPresentationItem],
        liveTurn: ToasttyTranscriptTurn?,
        isLiveTurnExpanded: Bool
    ) -> Self {
        guard isWorking else { return .none }
        guard foldsRunningWork else { return .row }
        // A message that was typed and is not in the transcript yet shows
        // after it. A receipt of a send that failed is not part of a turn.
        if let sent = sendItems.last(where: { item in
            if case .optimistic = item.content { return true }
            return false
        }) {
            return sent.hostMessage?.isLine == true ? .send(sent.clientRequestID) : .row
        }
        // Only a turn without its answer surely is the one that runs. After
        // the answer, the agent works on a message that the transcript
        // does not show yet, such as a digest that another device sees
        // typed, or goes on after an answer without a phase. An open turn
        // ends with its work. In each case the row at the end is the end.
        if let liveTurn, liveTurn.hasResponse == false, isLiveTurnExpanded == false {
            return .turn(liveTurn.id)
        }
        return .row
    }
}

/// What the transcript's tail shows while the agent works.
public struct ToasttyTranscriptWorkingIndicator: Equatable, Sendable {
    /// A turn's age as the host reported it, anchored to the local monotonic
    /// clock so wall-clock changes cannot move it.
    public struct TurnElapsed: Equatable, Sendable {
        public let secondsAtReceipt: Int
        public let receivedAtMonotonicTime: TimeInterval

        public init(secondsAtReceipt: Int, receivedAtMonotonicTime: TimeInterval) {
            self.secondsAtReceipt = max(0, secondsAtReceipt)
            self.receivedAtMonotonicTime = receivedAtMonotonicTime.isFinite
                ? max(0, receivedAtMonotonicTime)
                : 0
        }

        /// Whole seconds elapsed, advanced only from the monotonic anchor.
        func seconds(atMonotonicTime now: TimeInterval) -> Int {
            let finiteNow = now.isFinite ? now : receivedAtMonotonicTime
            return secondsAtReceipt + max(0, Int(finiteNow - receivedAtMonotonicTime))
        }
    }

    /// The running turn's age, when the host reports it.
    public let turnElapsed: TurnElapsed?

    public init(turnElapsed: TurnElapsed?) {
        self.turnElapsed = turnElapsed
    }

    func elapsedLabel(atMonotonicTime now: TimeInterval) -> String? {
        turnElapsed.map { Self.durationLabel(seconds: $0.seconds(atMonotonicTime: now)) }
    }

    /// Durations past this show as this, as in the iPhone session list.
    static let maximumDurationSeconds = 100 * 365 * 24 * 60 * 60

    /// The same format as the iPhone session list: "42s", then "3m 07s".
    static func durationLabel(seconds: Int) -> String {
        let clamped = min(max(0, seconds), maximumDurationSeconds)
        let minutes = clamped / 60
        let remaining = clamped % 60
        guard minutes > 0 else { return "\(remaining)s" }
        return String(format: "%dm %02ds", minutes, remaining)
    }
}
