import CoreState
import Foundation
import Sparkle

final class SparkleUpdaterDiagnosticsLogger: NSObject, SPUUpdaterDelegate {
    typealias Logger = (_ message: String, _ metadata: [String: String]) -> Void

    private let runningVersionMetadata: [String: String]
    private let infoLogger: Logger
    private let warningLogger: Logger

    init(
        bundle: Bundle,
        infoLogger: @escaping Logger = { message, metadata in
            ToasttyLog.info(message, category: .app, metadata: metadata)
        },
        warningLogger: @escaping Logger = { message, metadata in
            ToasttyLog.warning(message, category: .app, metadata: metadata)
        }
    ) {
        runningVersionMetadata = [
            "running_short_version": bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            "running_build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "unknown",
        ]
        self.infoLogger = infoLogger
        self.warningLogger = warningLogger
        super.init()
    }

    func recordInitialized(updater: SPUUpdater, startingUpdater: Bool) {
        var metadata = commonMetadata(event: "initialized")
        metadata.merge([
            "starting_updater": startingUpdater ? "true" : "false",
            "can_check_for_updates": updater.canCheckForUpdates ? "true" : "false",
            "session_in_progress": updater.sessionInProgress ? "true" : "false",
            "automatically_checks_for_updates": updater.automaticallyChecksForUpdates ? "true" : "false",
            "automatically_downloads_updates": updater.automaticallyDownloadsUpdates ? "true" : "false",
            "update_check_interval_seconds": String(updater.updateCheckInterval),
            "last_update_check_at_ms": updater.lastUpdateCheckDate.map {
                String(Int64(($0.timeIntervalSince1970 * 1000).rounded()))
            } ?? "none",
        ]) { current, _ in current }
        infoLogger("Sparkle updater initialized", metadata)
    }

    func recordManualCheckRequested() {
        infoLogger(
            "Sparkle update check requested",
            commonMetadata(event: "manual_check_requested")
        )
    }

    func recordPreflightFailure(_ issue: SparkleUpdatePreflight.Issue) {
        var metadata = commonMetadata(event: "preflight_failed")
        metadata["reason_code"] = issue.diagnosticCode
        warningLogger("Sparkle update preflight failed", metadata)
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        _ = updater
        var metadata = commonMetadata(event: "appcast_loaded")
        metadata["appcast_item_count"] = String(appcast.items.count)
        infoLogger("Sparkle update appcast loaded", metadata)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        _ = updater
        infoLogger(
            "Sparkle update found",
            updateMetadata(event: "update_found", item: item)
        )
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        _ = updater
        warningLogger(
            "Sparkle update not found",
            errorMetadata(event: "update_not_found", error: error)
        )
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        _ = updater
        var metadata = updateMetadata(event: "user_choice", item: updateItem)
        metadata["choice"] = Self.choiceName(choice)
        metadata["stage"] = Self.stageName(state.stage)
        metadata["user_initiated"] = state.userInitiated ? "true" : "false"
        infoLogger("Sparkle update user choice", metadata)
    }

    func updater(
        _ updater: SPUUpdater,
        willDownloadUpdate item: SUAppcastItem,
        with request: NSMutableURLRequest
    ) {
        _ = updater
        _ = request
        infoLogger(
            "Sparkle update download started",
            updateMetadata(event: "download_started", item: item)
        )
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        _ = updater
        infoLogger(
            "Sparkle update download completed",
            updateMetadata(event: "download_completed", item: item)
        )
    }

    func updater(
        _ updater: SPUUpdater,
        failedToDownloadUpdate item: SUAppcastItem,
        error: Error
    ) {
        _ = updater
        var metadata = updateMetadata(event: "download_failed", item: item)
        metadata.merge(errorMetadata(error: error)) { current, _ in current }
        warningLogger("Sparkle update download failed", metadata)
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        _ = updater
        infoLogger(
            "Sparkle update download canceled",
            commonMetadata(event: "download_canceled")
        )
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        _ = updater
        infoLogger(
            "Sparkle update extraction started",
            updateMetadata(event: "extraction_started", item: item)
        )
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        _ = updater
        infoLogger(
            "Sparkle update extraction completed",
            updateMetadata(event: "extraction_completed", item: item)
        )
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        _ = updater
        infoLogger(
            "Sparkle update installation started",
            updateMetadata(event: "installation_started", item: item)
        )
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        _ = updater
        infoLogger(
            "Sparkle updater will relaunch Toastty",
            commonMetadata(event: "relaunch_started")
        )
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        _ = updater
        warningLogger(
            "Sparkle update cycle aborted",
            errorMetadata(event: "cycle_aborted", error: error)
        )
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        _ = updater
        var metadata = commonMetadata(event: "cycle_finished")
        metadata["check_type"] = Self.updateCheckName(updateCheck)
        if let error {
            metadata.merge(errorMetadata(error: error)) { current, _ in current }
            warningLogger("Sparkle update cycle finished with error", metadata)
        } else {
            infoLogger("Sparkle update cycle finished", metadata)
        }
    }

    static func updateCheckName(_ updateCheck: SPUUpdateCheck) -> String {
        switch updateCheck {
        case .updates:
            return "user_initiated"
        case .updatesInBackground:
            return "background"
        case .updateInformation:
            return "information"
        @unknown default:
            return "unknown_\(updateCheck.rawValue)"
        }
    }

    static func choiceName(_ choice: SPUUserUpdateChoice) -> String {
        switch choice {
        case .skip:
            return "skip"
        case .install:
            return "install"
        case .dismiss:
            return "dismiss"
        @unknown default:
            return "unknown_\(choice.rawValue)"
        }
    }

    static func stageName(_ stage: SPUUserUpdateStage) -> String {
        switch stage {
        case .notDownloaded:
            return "not_downloaded"
        case .downloaded:
            return "downloaded"
        case .installing:
            return "installing"
        @unknown default:
            return "unknown_\(stage.rawValue)"
        }
    }

    static func sanitizedErrorMetadata(_ error: Error) -> [String: String] {
        let nsError = error as NSError
        return [
            "error_domain": nsError.domain,
            "error_code": String(nsError.code),
        ]
    }

    private func commonMetadata(event: String) -> [String: String] {
        var metadata = runningVersionMetadata
        metadata["updater_event"] = event
        return metadata
    }

    private func updateMetadata(
        event: String,
        item: SUAppcastItem
    ) -> [String: String] {
        var metadata = commonMetadata(event: event)
        metadata["target_short_version"] = item.displayVersionString
        metadata["target_build"] = item.versionString
        return metadata
    }

    private func errorMetadata(event: String, error: Error) -> [String: String] {
        var metadata = commonMetadata(event: event)
        metadata.merge(Self.sanitizedErrorMetadata(error)) { current, _ in current }
        return metadata
    }

    private func errorMetadata(error: Error) -> [String: String] {
        Self.sanitizedErrorMetadata(error)
    }
}
