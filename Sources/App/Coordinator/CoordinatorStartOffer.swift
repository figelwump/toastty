import AppKit
import CoreState
import Foundation

/// Asks once whether to start the coordinator, so that a new user learns
/// that it exists.
///
/// Toastty asks when a window first has the keyboard and no coordinator was
/// ever opened: there is no coordinator's workspace, and the coordinator's
/// folder, which the first open creates and nothing removes, does not exist.
/// Start runs the same code as Open Coordinator. Not Now is saved, and
/// Toastty does not ask again; Open Coordinator stays in the Agent menu and
/// in the command palette.
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

    static let messageText = "Start the coordinator?"
    static let informativeText = """
    The coordinator is an agent session in its own workspace that follows your tasks. \
    It tells you what needs you, unblocks stuck tasks and turns your requests into tasks.

    You can start it later with Open Coordinator in the Agent menu or the command palette.
    """
    static let startButtonTitle = "Start Coordinator"
    static let notNowButtonTitle = "Not Now"

    private let controller: CoordinatorController
    private let store: AppStore
    /// Where the answer is saved, or `nil` for a run that never asks, such
    /// as an automation run.
    private let defaults: UserDefaults?
    private let coordinatorDirectoryURL: URL
    private let present: Presenter
    private let presentFailure: @MainActor (String, String) -> Void

    /// Takes down the question that shows now.
    private var dismiss: (@MainActor () -> Void)?
    private var storeObserverToken: UUID?

    init(
        controller: CoordinatorController,
        store: AppStore,
        defaults: UserDefaults?,
        coordinatorDirectoryURL: URL,
        present: @escaping Presenter = CoordinatorStartOffer.presentSheet,
        presentFailure: @escaping @MainActor (String, String) -> Void = TaskActions.presentFailure
    ) {
        self.controller = controller
        self.store = store
        self.defaults = defaults
        self.coordinatorDirectoryURL = coordinatorDirectoryURL
        self.present = present
        self.presentFailure = presentFailure
    }

    /// Whether Toastty still has the question to ask.
    var shouldOffer: Bool {
        guard let defaults, defaults.bool(forKey: Self.answeredKey) == false else { return false }
        return controller.location == nil
            && FileManager.default.fileExists(atPath: coordinatorDirectoryURL.path) == false
    }

    /// Whether the question shows now.
    var isShowing: Bool { dismiss != nil }

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
        // Before the open below, which would take the question down.
        stopShowing()
        // Without an answer the question is still open: a window that gets
        // the keyboard later asks it again.
        guard let answer else { return }
        defaults?.set(true, forKey: Self.answeredKey)
        ToasttyLog.info("The user answered whether to start the coordinator", category: .tasks, metadata: [
            "answer": answer == .start ? "start" : "not_now",
        ])
        if answer == .start {
            controller.perform(.open, windowID: windowID, presentFailure: presentFailure)
        }
    }

    private func takeDown() {
        let dismiss = dismiss
        stopShowing()
        dismiss?()
    }

    private func stopShowing() {
        dismiss = nil
        if let storeObserverToken {
            store.removeActionAppliedObserver(storeObserverToken)
            self.storeObserverToken = nil
        }
    }

    // MARK: - The sheet

    /// The question as a sheet on the window. A sheet keeps the rest of the
    /// app in use: at launch, restored terminals and agents carry on while
    /// the question waits.
    static func presentSheet(
        windowID: UUID,
        answer: @escaping @MainActor (Answer?) -> Void
    ) -> (@MainActor () -> Void)? {
        guard let window = AgentLaunchUI.window(for: windowID), window.attachedSheet == nil else { return nil }
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .informational
        alert.addConfiguredButton(withTitle: startButtonTitle, behavior: .defaultAction)
        alert.addConfiguredButton(withTitle: notNowButtonTitle, behavior: .cancelAction)
        alert.window.setAccessibilityIdentifier("coordinator.start-offer")
        alert.beginSheetModal(for: window) { response in
            Task { @MainActor in
                switch response {
                case .alertFirstButtonReturn: answer(.start)
                case .alertSecondButtonReturn: answer(.notNow)
                // Taken down, or its window closed.
                default: answer(nil)
                }
            }
        }
        return { [weak window, alert] in
            window?.endSheet(alert.window, returnCode: .abort)
        }
    }
}
