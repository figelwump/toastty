import Foundation

struct TerminalSearchState: Equatable, Sendable {
    var isPresented: Bool
    var needle: String
    var total: Int?
    var selected: Int?
    var focusRequestID: UUID

    init(
        isPresented: Bool,
        needle: String,
        total: Int? = nil,
        selected: Int? = nil,
        focusRequestID: UUID = UUID()
    ) {
        self.isPresented = isPresented
        self.needle = needle
        self.total = total
        self.selected = selected
        self.focusRequestID = focusRequestID
    }
}
