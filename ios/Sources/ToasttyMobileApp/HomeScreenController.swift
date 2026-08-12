import Foundation
import Observation
import ToasttyMobileDomain

struct SelectedConversationPresentation: Identifiable, Equatable {
    let id: UUID
}

@MainActor
@Observable
final class HomeScreenController {
    let runtimeMode: ToasttyMobileRuntimeMode
    var snapshot: MobileHomeSnapshot
    var connectionState: MobileConnectionState
    var freshness: LiveProjectionFreshness
    private(set) var selectedConversationID: UUID?
    private(set) var removedSelectionMessage: String?
    private var onConversationOpened: @MainActor (UUID) -> Void = { _ in }
    private var onConversationClosed: @MainActor (UUID) -> Void = { _ in }

    init(
        runtimeMode: ToasttyMobileRuntimeMode,
        snapshot: MobileHomeSnapshot,
        connectionState: MobileConnectionState,
        freshness: LiveProjectionFreshness? = nil
    ) {
        self.runtimeMode = runtimeMode
        self.snapshot = snapshot
        self.connectionState = connectionState
        self.freshness = freshness ?? Self.freshness(for: connectionState)
    }

    func open(_ conversation: MobileConversation) {
        selectConversation(conversation.id)
    }

    func dismissConversation() {
        selectConversation(nil)
    }

    func update(
        snapshot newSnapshot: MobileHomeSnapshot,
        connectionState: MobileConnectionState,
        freshness: LiveProjectionFreshness
    ) {
        let removedConversation = selectedConversationID.flatMap { conversation(id: $0) }
        snapshot = newSnapshot
        self.connectionState = connectionState
        self.freshness = freshness

        if let removedConversation, conversation(id: removedConversation.id) == nil {
            selectConversation(nil)
            removedSelectionMessage = "\(removedConversation.title) is no longer available on your Mac."
        }
    }

    func workspace(id: UUID) -> MobileWorkspace? {
        snapshot.workspaces.first { $0.id == id }
    }

    func conversation(id: UUID) -> MobileConversation? {
        snapshot.workspaces
            .lazy
            .flatMap(\.conversations)
            .first { $0.id == id }
    }

    var selectedConversation: MobileConversation? {
        selectedConversationID.flatMap(conversation(id:))
    }

    var selectedConversationPresentation: SelectedConversationPresentation? {
        get { selectedConversationID.map(SelectedConversationPresentation.init(id:)) }
        set { selectConversation(newValue?.id) }
    }

    func installConversationLifecycle(
        onOpen: @escaping @MainActor (UUID) -> Void,
        onClose: @escaping @MainActor (UUID) -> Void
    ) {
        onConversationOpened = onOpen
        onConversationClosed = onClose
        if let selectedConversationID {
            onConversationOpened(selectedConversationID)
        }
    }

    func dismissRemovalMessage() {
        removedSelectionMessage = nil
    }

    private func selectConversation(_ conversationID: UUID?) {
        guard selectedConversationID != conversationID else { return }
        if let selectedConversationID {
            onConversationClosed(selectedConversationID)
        }
        selectedConversationID = conversationID
        if let conversationID {
            onConversationOpened(conversationID)
        }
    }

    private static func freshness(for state: MobileConnectionState) -> LiveProjectionFreshness {
        switch state {
        case .live: .live
        case .reconnecting: .reconnecting
        case .offline: .unreachable
        }
    }
}
