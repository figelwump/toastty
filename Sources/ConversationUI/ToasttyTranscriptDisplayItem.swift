import Foundation
import RemoteProtocol

enum ToasttyConversationScrollTarget: Hashable {
    case transcript(ToasttyTranscriptBlockID)
    case responseContext(ToasttyTranscriptBlockID)
    case turnWork(ToasttyTranscriptRowID)
    /// A row of quiet checks' line, by the row's ID.
    case quietChecks(ToasttyTranscriptRowID)
    case send(String)
    case liveEdge
}

enum ToasttyTranscriptDisplayItem: Identifiable {
    case block(ToasttyTranscriptBlock, isWork: Bool)
    case workStrip(ToasttyTranscriptTurn)
    case quietChecks(ToasttyQuietCheckRun)

    var id: ToasttyConversationScrollTarget {
        switch self {
        case .block(let block, _): .transcript(block.id)
        case .workStrip(let turn): .turnWork(turn.id)
        case .quietChecks(let run): .quietChecks(run.id)
        }
    }

    /// The first row that the item shows.
    var firstRowID: ToasttyTranscriptRowID? {
        switch self {
        case .block(let block, _): block.id.rowID
        case .workStrip(let turn): turn.workBlockIDs.first?.rowID
        case .quietChecks(let run): run.id
        }
    }
}
