import Combine
import CoreState
import Foundation
import RemoteProtocol

/// Global ownership keeps both queue actions and chat alive across window changes.
@MainActor
final class CoordinatorHomeController {
    let session: CoordinatorSessionController
    let conversation: CoordinatorConversationModel
    let reviews: CoordinatorReviewStore
    let actions: CoordinatorReviewActions
    let peeks: CoordinatorPeekStore
    private let wake: CoordinatorWakeController
    private var boardSubscription: AnyCancellable?
    private var runtimeSubscription: AnyCancellable?

    init(store: AppStore, launcher: any TaskAgentLaunching, sessionRuntimeStore: SessionRuntimeStore,
         runtimePaths: ToasttyRuntimePaths, service: ConversationService,
         tasks: TaskCoordinator, board: TaskBoardStore, pullRequests: PullRequestStateCache) {
        reviews = CoordinatorReviewStore(runtimePaths: runtimePaths)
        actions = CoordinatorReviewActions(store: reviews, tasks: tasks, pullRequests: pullRequests)
        session = CoordinatorSessionController(store: store, launcher: launcher,
            sessionRuntimeStore: sessionRuntimeStore, runtimePaths: runtimePaths,
            defaultsProvider: { (try? TasksConfigFile.load().defaults) ?? .init() })
        conversation = CoordinatorConversationModel(service: service, session: session)
        peeks = CoordinatorPeekStore(service: service, session: session, board: board,
            store: store, sessionRuntimeStore: sessionRuntimeStore)
        wake = CoordinatorWakeController(board: board, reviews: reviews, session: session,
            conversation: conversation, service: service, runtimePaths: runtimePaths)
        actions.reconcile(tasks: board.items())
        boardSubscription = board.objectWillChange.sink { [weak self, weak board] _ in
            // The board publishes before storing its new state. Reconcile from
            // the app-owned controller after that publication has completed.
            Task { @MainActor [weak self, weak board] in
                guard let self, let board else { return }
                self.actions.reconcile(tasks: board.items())
            }
        }
        runtimeSubscription = sessionRuntimeStore.$sessionRegistry.sink { [weak self, weak board] _ in
            Task { @MainActor [weak self, weak board] in
                guard let self, let board else { return }
                self.actions.reconcile(tasks: board.items())
                self.wake.taskFactsDidChange()
            }
        }
    }
}

