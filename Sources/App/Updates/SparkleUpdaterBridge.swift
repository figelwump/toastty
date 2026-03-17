import AppKit
import Combine
import Sparkle

@MainActor
final class SparkleUpdaterBridge: ObservableObject {
    @Published private(set) var canCheckForUpdates: Bool

    private let updaterController: SPUStandardUpdaterController
    private var canCheckForUpdatesObservation: NSKeyValueObservation?

    init(startingUpdater: Bool) {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
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
        updaterController.checkForUpdates(nil)
    }
}
