import Foundation

enum ToasttyMobileRoute: Hashable {
    case workspace(UUID)
    case conversation(UUID)

    var conversationID: UUID? {
        guard case .conversation(let id) = self else { return nil }
        return id
    }
}

extension [ToasttyMobileRoute] {
    var containsConversation: Bool {
        contains { $0.conversationID != nil }
    }

    /// The path with its conversation tail matching `selection`. The
    /// conversation route always sits on top of the stack, so syncing removes
    /// any existing conversation entry before appending the selected one.
    func synchronized(
        with selection: SelectedConversationPresentation?
    ) -> [ToasttyMobileRoute] {
        var path = filter { $0.conversationID == nil }
        if let selection {
            path.append(.conversation(selection.id))
        }
        return path
    }
}
