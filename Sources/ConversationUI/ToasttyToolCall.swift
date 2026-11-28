import Foundation
import RemoteProtocol

struct ToasttyToolBatchActivity: Equatable {
    let id: ToasttyTranscriptBlockID
    let lastSequence: UInt64

    static func make(from blocks: [ToasttyTranscriptBlock]) -> [Self] {
        blocks.compactMap { block in
            guard case .toolBatch(let rows) = block.content,
                  let lastSequence = rows.last?.id.sequence else { return nil }
            return Self(id: block.id, lastSequence: lastSequence)
        }
    }
}

/// Tool batches stay collapsed until the user opens them — live activity
/// keeps its count updating in the header without expanding, which stays
/// quiet inside an already-expanded working turn.
struct ToasttyToolBatchDisclosureState: Equatable {
    private(set) var expandedIDs: Set<ToasttyTranscriptBlockID> = []

    func isExpanded(_ id: ToasttyTranscriptBlockID) -> Bool {
        expandedIDs.contains(id)
    }

    mutating func toggle(_ id: ToasttyTranscriptBlockID) {
        if expandedIDs.remove(id) == nil {
            expandedIDs.insert(id)
        }
    }

    mutating func reconcile(
        activity: [ToasttyToolBatchActivity],
        revision: ToasttyTranscriptRevision
    ) {
        switch revision {
        case .initial, .rebuilt:
            expandedIDs.removeAll(keepingCapacity: true)
        case .appended, .prepended, .metadataOnly:
            break
        }
        expandedIDs.formIntersection(activity.map(\.id))
    }
}

/// One tool call: its start and its end, which are two events.
struct ToasttyToolCall: Identifiable, Equatable, Sendable {
    /// The call's ID, or the row's for an event without one.
    let id: String
    let name: String
    /// `nil` while the call runs.
    let outcome: ConversationToolOutcome?
    /// What the call did, such as its command, then what its end said.
    let details: [String]

    /// The calls in the order they started. A call's end updates its line.
    static func calls(in rows: [ToasttyTranscriptRow]) -> [ToasttyToolCall] {
        var calls: [ToasttyToolCall] = []
        var indexByID: [String: Int] = [:]
        for row in rows {
            let callID: String
            let name: String
            let outcome: ConversationToolOutcome?
            let detail: String?
            switch row.content {
            case .toolStarted(let id, let started, let startedDetail):
                (callID, name, outcome, detail) = (id, started, nil, startedDetail)
            case .toolFinished(let id, let finished, let result, let finishedDetail):
                (callID, name, outcome, detail) = (id, finished, result, finishedDetail)
            default:
                continue
            }
            let newDetails = [detail].compactMap { $0 }.filter { $0.isEmpty == false }
            if let index = indexByID[callID] {
                let previous = calls[index]
                calls[index] = ToasttyToolCall(
                    id: previous.id,
                    name: previous.name,
                    outcome: outcome ?? previous.outcome,
                    details: previous.details + newDetails.filter { previous.details.contains($0) == false }
                )
            } else {
                indexByID[callID] = calls.count
                calls.append(ToasttyToolCall(id: callID, name: name, outcome: outcome, details: newDetails))
            }
        }
        return calls
    }

    /// The calls of each tool batch, as the whole transcript tells them. A
    /// call shows in the batch where it starts, with its end also when the
    /// end comes in a later batch, such as after an approval. A batch whose
    /// calls all started earlier lists none.
    static func callsByBlock(_ blocks: [ToasttyTranscriptBlock]) -> [ToasttyTranscriptBlockID: [ToasttyToolCall]] {
        let batches = blocks.compactMap { block -> (id: ToasttyTranscriptBlockID, rows: [ToasttyTranscriptRow])? in
            guard case .toolBatch(let rows) = block.content else { return nil }
            return (block.id, rows)
        }
        guard batches.isEmpty == false else { return [:] }
        let whole = Dictionary(
            calls(in: batches.flatMap(\.rows)).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var shown: Set<String> = []
        var result: [ToasttyTranscriptBlockID: [ToasttyToolCall]] = [:]
        for batch in batches {
            result[batch.id] = calls(in: batch.rows).compactMap { call in
                shown.insert(call.id).inserted ? whole[call.id] ?? call : nil
            }
        }
        return result
    }
}
