import AppKit
import CoreState
import Foundation

/// Asks once whether to start the coordinator, so that a new user learns
/// that it exists. The question is the What's new sheet
/// (`WhatsNewSheet`), which also names tasks and quick entry.
///
/// Toastty asks when a window first has the keyboard and no coordinator was
/// ever opened: there is no coordinator's workspace, and the coordinator's
/// folder, which the first open creates and nothing removes, does not exist.
/// Start runs the same code as Open Coordinator, and is saved once the
/// coordinator's agent runs: a start that fails, for example because the
/// agent is not installed, asks again at the next launch. Not Now is saved,
/// and Toastty does not ask again; Open Coordinator stays in the Agent menu
/// and in the command palette.
@MainActor
final class CoordinatorStartOffer {
    enum Answer: Equatable {
        case start
        case notNow
    }

    /// Shows the question over a window and calls `answer` with the user's
    /// choice, or with `nil` when the question went away without one.
    /// Returns a way to take the question down, or `nil` when the question
    /// could not show.
    typealias Presenter = @MainActor (
        _ windowID: UUID,
        _ answer: @escaping @MainActor (Answer?) -> Void
    ) -> (@MainActor () -> Void)?

    /// Set once the user answered.
    static let answeredKey = "toastty.coordinator.startOfferAnswered"

    private let controller: CoordinatorController
    private let store: AppStore
    /// Where the answer is saved, or `nil` for a run that never asks, such
    /// as an automation run.
    private let defaults: UserDefaults?
    private let coordinatorDirectoryURL: URL
    private let present: Presenter
    private let presentFailure: @MainActor (String, String) -> Void
    private let offerAgent: CoordinatorController.AgentChoicePresenter

    /// Takes down the question that shows now.
    private var dismiss: (@MainActor () -> Void)?
    private var storeObserverToken: UUID?
    /// Called each time the question stops showing, answered or not, after
    /// the answer counts. The quick entry key waits for the question, so it
    /// is set up again here.
    var questionEnded: (@MainActor () -> Void)?

    init(
        controller: CoordinatorController,
        store: AppStore,
        defaults: UserDefaults?,
        coordinatorDirectoryURL: URL,
        present: @escaping Presenter,
        presentFailure: @escaping @MainActor (String, String) -> Void = TaskActions.presentFailure,
        offerAgent: @escaping CoordinatorController.AgentChoicePresenter = CoordinatorController.presentAgentChoice
    ) {
        self.controller = controller
        self.store = store
        self.defaults = defaults
        self.coordinatorDirectoryURL = coordinatorDirectoryURL
        self.present = present
        self.presentFailure = presentFailure
        self.offerAgent = offerAgent
    }

    /// Whether Toastty still has the question to ask.
    var shouldOffer: Bool {
        guard answeredThisLaunch == false,
              let defaults, defaults.bool(forKey: Self.answeredKey) == false else { return false }
        return controller.location == nil
            && FileManager.default.fileExists(atPath: coordinatorDirectoryURL.path) == false
    }

    /// Whether the question shows now.
    var isShowing: Bool { dismiss != nil }

    /// The user answered in this launch. A Start whose start failed is not
    /// saved, but the question waits for the next launch.
    private var answeredThisLaunch = false

    /// Asks over `windowID` when the question is still open. Call it when a
    /// window gets the keyboard.
    func offerIfNeeded(windowID: UUID) {
        guard isShowing == false, shouldOffer else { return }
        guard let dismiss = present(windowID, { [weak self] answer in
            self?.answered(answer, windowID: windowID)
        }) else { return }
        self.dismiss = dismiss
        // A coordinator opened another way while the question shows, such
        // as `toastty coordinator open`, is the answer.
        storeObserverToken = store.addActionAppliedObserver { [weak self] _, previousState, nextState in
            guard previousState.coordinator == nil, nextState.coordinator != nil else { return }
            self?.takeDown()
        }
        ToasttyLog.info("Asked whether to start the coordinator", category: .tasks)
    }

    private func answered(_ answer: Answer?, windowID: UUID) {
        let wasShowing = isShowing
        // Before the open below, which would take the question down.
        stopShowing()
        // Once the answer counts, so the quick entry key sees it.
        defer { if wasShowing { questionEnded?() } }
        // Without an answer the question is still open: a window that gets
        // the keyboard later asks it again.
        guard let answer else { return }
        answeredThisLaunch = true
        ToasttyLog.info("The user answered whether to start the coordinator", category: .tasks, metadata: [
            "answer": answer == .start ? "start" : "not_now",
        ])
        guard answer == .start else {
            defaults?.set(true, forKey: Self.answeredKey)
            return
        }
        let start = controller.perform(.open, windowID: windowID, presentFailure: presentFailure, offerAgent: offerAgent)
        Task { @MainActor [weak self] in
            guard await start.value else {
                ToasttyLog.info("The coordinator did not start from the question; the next launch asks again", category: .tasks)
                return
            }
            self?.defaults?.set(true, forKey: Self.answeredKey)
        }
    }

    private func takeDown() {
        let dismiss = dismiss
        stopShowing()
        dismiss?()
        questionEnded?()
    }

    private func stopShowing() {
        dismiss = nil
        if let storeObserverToken {
            store.removeActionAppliedObserver(storeObserverToken)
            self.storeObserverToken = nil
        }
    }
}
