import Sparkle
@testable import ToasttyApp
import XCTest

final class SparkleUpdaterDiagnosticsLoggerTests: XCTestCase {
    func testImplementsOnlyObservationalLifecycleDelegateCallbacks() {
        let logger = SparkleUpdaterDiagnosticsLogger(bundle: .main)
        let expectedSelectors = [
            "updater:didFinishLoadingAppcast:",
            "updater:didFindValidUpdate:",
            "updaterDidNotFindUpdate:error:",
            "updater:userDidMakeChoice:forUpdate:state:",
            "updater:willDownloadUpdate:withRequest:",
            "updater:didDownloadUpdate:",
            "updater:failedToDownloadUpdate:error:",
            "userDidCancelDownload:",
            "updater:willExtractUpdate:",
            "updater:didExtractUpdate:",
            "updater:willInstallUpdate:",
            "updaterWillRelaunchApplication:",
            "updater:didAbortWithError:",
            "updater:didFinishUpdateCycleForUpdateCheck:error:",
        ]

        for selectorName in expectedSelectors {
            XCTAssertTrue(
                logger.responds(to: NSSelectorFromString(selectorName)),
                "Missing Sparkle delegate callback: \(selectorName)"
            )
        }

        let behavioralSelectors = [
            "updater:mayPerformUpdateCheck:error:",
            "allowedChannelsForUpdater:",
            "feedURLStringForUpdater:",
            "feedParametersForUpdater:sendingSystemProfile:",
            "updaterShouldPromptForPermissionToCheckForUpdates:",
            "allowedSystemProfileKeysForUpdater:",
            "bestValidUpdateInAppcast:forUpdater:",
            "updater:shouldProceedWithUpdate:updateCheck:error:",
            "updater:shouldDownloadReleaseNotesForUpdate:",
            "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:",
            "updaterShouldRelaunchApplication:",
            "versionComparatorForUpdater:",
            "decryptionPasswordForUpdater:",
            "updater:willInstallUpdateOnQuit:immediateInstallationBlock:",
            "updaterMayCheckForUpdates:",
        ]
        for selectorName in behavioralSelectors {
            XCTAssertFalse(
                logger.responds(to: NSSelectorFromString(selectorName)),
                "Diagnostics delegate must not alter Sparkle behavior: \(selectorName)"
            )
        }
    }

    func testErrorMetadataIncludesOnlyDomainAndCode() {
        let error = NSError(
            domain: "SparkleDiagnosticTests",
            code: 42,
            userInfo: [
                NSLocalizedDescriptionKey: "Private path /Users/example/private-project",
                NSURLErrorKey: URL(string: "https://user:secret@example.com/private")!,
            ]
        )

        let metadata = SparkleUpdaterDiagnosticsLogger.sanitizedErrorMetadata(error)

        XCTAssertEqual(
            metadata,
            [
                "error_domain": "SparkleDiagnosticTests",
                "error_code": "42",
            ]
        )
    }

    func testPreflightFailureLogsOnlyStableReasonCode() {
        var logs: [(String, [String: String])] = []
        let logger = SparkleUpdaterDiagnosticsLogger(
            bundle: .main,
            infoLogger: { logs.append(($0, $1)) },
            warningLogger: { logs.append(($0, $1)) }
        )

        logger.recordPreflightFailure(
            .feedRequestFailed(
                feedURL: "https://user:secret@example.com/private",
                reason: "Private path /Users/example/private-project"
            )
        )

        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0].0, "Sparkle update preflight failed")
        XCTAssertEqual(logs[0].1["reason_code"], "feed_request_failed")
        XCTAssertFalse(logs[0].1.values.contains { $0.contains("secret") })
        XCTAssertFalse(logs[0].1.values.contains { $0.contains("private-project") })
    }
}
