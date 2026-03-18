import AppKit
import Combine
import Sparkle

@MainActor
final class SparkleUpdaterBridge: ObservableObject {
    typealias DiagnosticAlertPresenter = @MainActor (SparkleUpdatePreflight.Issue) -> Void

    @Published private(set) var canCheckForUpdates: Bool

    private let updaterController: SPUStandardUpdaterController
    private let updatePreflight: SparkleUpdatePreflight?
    private let presentDiagnosticAlert: DiagnosticAlertPresenter
    private var canCheckForUpdatesObservation: NSKeyValueObservation?

    init(
        startingUpdater: Bool,
        enableDetailedDiagnostics: Bool = SparkleUpdateDiagnosticsMode.isEnabled(),
        bundle: Bundle = .main,
        feedLoader: @escaping SparkleUpdatePreflight.FeedLoader = SparkleUpdatePreflight.defaultFeedLoader,
        presentDiagnosticAlert: @escaping DiagnosticAlertPresenter = { issue in
            SparkleUpdateDiagnosticsPresenter.present(issue: issue)
        }
    ) {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updatePreflight = enableDetailedDiagnostics
            ? SparkleUpdatePreflight(bundle: bundle, feedLoader: feedLoader)
            : nil
        self.presentDiagnosticAlert = presentDiagnosticAlert
        canCheckForUpdates = updaterController.updater.canCheckForUpdates
        canCheckForUpdatesObservation = updaterController.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            let canCheckForUpdates = updater.canCheckForUpdates
            Task { @MainActor [weak self, canCheckForUpdates] in
                self?.canCheckForUpdates = canCheckForUpdates
            }
        }
    }

    func checkForUpdates() {
        guard let updatePreflight else {
            updaterController.checkForUpdates(nil)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            if let issue = await updatePreflight.validate() {
                self.presentDiagnosticAlert(issue)
                return
            }

            self.updaterController.checkForUpdates(nil)
        }
    }
}
