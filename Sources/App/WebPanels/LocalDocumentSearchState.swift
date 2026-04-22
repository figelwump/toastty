import Foundation

struct LocalDocumentSearchState: Equatable, Sendable {
    var isPresented: Bool
    var query: String
    var lastMatchFound: Bool?
    var focusRequestID: UUID

    init(
        isPresented: Bool,
        query: String,
        lastMatchFound: Bool? = nil,
        focusRequestID: UUID = UUID()
    ) {
        self.isPresented = isPresented
        self.query = query
        self.lastMatchFound = lastMatchFound
        self.focusRequestID = focusRequestID
    }
}
