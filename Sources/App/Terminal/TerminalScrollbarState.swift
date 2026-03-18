import Foundation

struct TerminalScrollbarState: Equatable, Sendable {
    let total: UInt64
    let offset: UInt64
    let visibleLength: UInt64

    var trailingEdge: UInt64 {
        let (sum, overflow) = offset.addingReportingOverflow(visibleLength)
        return overflow ? UInt64.max : sum
    }

    var isPinnedToBottom: Bool {
        total == 0 || trailingEdge >= total
    }
}
