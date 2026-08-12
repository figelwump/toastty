import Foundation
import Observation
import ToasttyMobileDomain

struct SelectedConversationPresentation: Identifiable, Equatable {
    let id: UUID
    let requestsComposerFocus: Bool

    init(id: UUID, requestsComposerFocus: Bool = false) {
        self.id = id
        self.requestsComposerFocus = requestsComposerFocus
    }
}

@MainActor
@Observable
final class HomeScreenController {
    let runtimeMode: ToasttyMobileRuntimeMode
    var snapshot: MobileHomeSnapshot
    var connectionState: MobileConnectionState
    var freshness: LiveProjectionFreshness
    private(set) var latestTransportFailure: NativeTransportFailure?
    private(set) var selectedConversationID: UUID?
    private(set) var selectedConversationRequestsComposerFocus = false
    private(set) var removedSelectionMessage: String?
    private var onConversationOpened: @MainActor (UUID) -> Void = { _ in }
    private var onConversationClosed: @MainActor (UUID) -> Void = { _ in }

    init(
        runtimeMode: ToasttyMobileRuntimeMode,
        snapshot: MobileHomeSnapshot,
        connectionState: MobileConnectionState,
        freshness: LiveProjectionFreshness? = nil,
        latestTransportFailure: NativeTransportFailure? = nil
    ) {
        self.runtimeMode = runtimeMode
        self.snapshot = snapshot
        self.connectionState = connectionState
        self.freshness = freshness ?? Self.freshness(for: connectionState)
        self.latestTransportFailure = latestTransportFailure
    }

    func open(_ conversation: MobileConversation) {
        selectConversation(conversation.id, requestsComposerFocus: false)
    }

    func reply(_ conversation: MobileConversation) {
        guard conversation.inputAvailability.allowsReply else { return }
        selectConversation(conversation.id, requestsComposerFocus: true)
    }

    @discardableResult
    func openConversation(id: UUID, requestsComposerFocus: Bool = false) -> Bool {
        guard let conversation = conversation(id: id),
              requestsComposerFocus == false || conversation.inputAvailability.allowsReply
        else {
            return false
        }
        selectConversation(id, requestsComposerFocus: requestsComposerFocus)
        return true
    }

    func dismissConversation() {
        selectConversation(nil, requestsComposerFocus: false)
    }

    func update(
        snapshot newSnapshot: MobileHomeSnapshot,
        connectionState: MobileConnectionState,
        freshness: LiveProjectionFreshness,
        latestTransportFailure: NativeTransportFailure? = nil
    ) {
        let removedConversation = selectedConversationID.flatMap { conversation(id: $0) }
        snapshot = newSnapshot
        self.connectionState = connectionState
        self.freshness = freshness
        self.latestTransportFailure = latestTransportFailure

        if let removedConversation, conversation(id: removedConversation.id) == nil {
            selectConversation(nil, requestsComposerFocus: false)
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
        get {
            selectedConversationID.map {
                SelectedConversationPresentation(
                    id: $0,
                    requestsComposerFocus: selectedConversationRequestsComposerFocus
                )
            }
        }
        set {
            selectConversation(
                newValue?.id,
                requestsComposerFocus: newValue?.requestsComposerFocus ?? false
            )
        }
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

    var connectionNoticeMessage: String? {
        guard freshness != .live else { return nil }
        guard let latestTransportFailure else { return freshness.message }

        let detail = switch latestTransportFailure {
        case .offline:
            "This iPhone appears to be offline."
        case .dns:
            "Toastty couldn't find your Mac. Check Tailscale and the Mac hostname."
        case .tls:
            "Toastty couldn't establish a secure connection to your Mac. Check its hostname and certificate."
        case .cannotConnect, .timedOut, .connectionLost:
            "The Toastty gateway on your Mac is unreachable."
        case .other:
            "Toastty couldn't connect to your Mac."
        }
        return "\(detail) Showing the last available update."
    }

    private func selectConversation(
        _ conversationID: UUID?,
        requestsComposerFocus: Bool
    ) {
        guard selectedConversationID != conversationID else {
            selectedConversationRequestsComposerFocus = requestsComposerFocus
            return
        }
        if let selectedConversationID {
            onConversationClosed(selectedConversationID)
        }
        selectedConversationID = conversationID
        selectedConversationRequestsComposerFocus = requestsComposerFocus
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
