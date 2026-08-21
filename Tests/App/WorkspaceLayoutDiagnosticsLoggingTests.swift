import CoreState
import XCTest
@testable import ToasttyApp

@MainActor
final class WorkspaceLayoutDiagnosticsLoggingTests: XCTestCase {
    func testProfileResolverUsesRecordedMainDisplayInputs() {
        let configuration = displayConfiguration(
            displays: [
                (1920, 1080, 1, false),
                (3456, 2234, 2, true),
            ],
            profileDisplayIndex: 1
        )

        let resolution = WorkspaceLayoutProfileResolver.resolution(
            environment: [:],
            displayConfiguration: configuration
        )

        XCTAssertEqual(resolution.profileID, "display-3456x2234@2x")
        XCTAssertEqual(resolution.source, .mainDisplay)
        XCTAssertEqual(resolution.logMetadata()["display_count"], "2")
        XCTAssertEqual(
            resolution.logMetadata()["display_configuration"],
            "0:1920x1080@1x,1:3456x2234@2x:main"
        )
    }

    func testDisplayObserverLogsOnlyChangedConfigurations() {
        let initial = WorkspaceLayoutProfileResolution(
            profileID: "display-3456x2234@2x",
            source: .mainDisplay,
            displayConfiguration: displayConfiguration(
                displays: [(3456, 2234, 2, true)],
                profileDisplayIndex: 0
            )
        )
        let changed = WorkspaceLayoutProfileResolution(
            profileID: "display-2560x1440@1x",
            source: .mainDisplay,
            displayConfiguration: displayConfiguration(
                displays: [
                    (3456, 2234, 2, false),
                    (2560, 1440, 1, true),
                ],
                profileDisplayIndex: 1
            )
        )
        let resolutionBox = ResolutionBox(initial)
        var logs: [(String, [String: String])] = []
        let observer = WorkspaceLayoutDisplayDiagnosticsObserver(
            persistenceProfileID: initial.profileID,
            notificationCenter: NotificationCenter(),
            resolutionProvider: { resolutionBox.value },
            logger: { logs.append(($0, $1)) }
        )

        observer.recordDisplayChangeIfNeeded()
        XCTAssertTrue(logs.isEmpty)

        resolutionBox.value = changed
        observer.recordDisplayChangeIfNeeded()
        observer.recordDisplayChangeIfNeeded()

        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0].0, "Workspace display configuration changed")
        XCTAssertEqual(logs[0].1["persistence_profile_id"], initial.profileID)
        XCTAssertEqual(logs[0].1["previous_display_count"], "1")
        XCTAssertEqual(logs[0].1["current_display_count"], "2")
        XCTAssertEqual(logs[0].1["current_profile_candidate_id"], changed.profileID)
        XCTAssertEqual(logs[0].1["profile_candidate_changed"], "true")
    }

    func testTerminationSummaryIncludesSaveProfileAndCurrentDisplayCandidate() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-diagnostics-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("workspace-layout-profiles.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let currentResolution = WorkspaceLayoutProfileResolution(
            profileID: "display-2560x1440@1x",
            source: .mainDisplay,
            displayConfiguration: displayConfiguration(
                displays: [(2560, 1440, 1, true)],
                profileDisplayIndex: 0
            )
        )
        var logs: [(String, [String: String])] = []
        let coordinator = WorkspaceLayoutPersistenceCoordinator(
            context: WorkspaceLayoutPersistenceContext(
                profileID: "display-3456x2234@2x",
                fileURL: fileURL,
                shouldMigrateLegacyStore: false
            ),
            layoutLifecycleLogger: { logs.append(($0, $1)) },
            profileResolutionProvider: { currentResolution }
        )

        coordinator.flushCurrentState(.bootstrap(), reason: "application_will_terminate")

        let summary = try XCTUnwrap(logs.first { $0.0 == "Workspace layout termination summary" })
        XCTAssertEqual(summary.1["persistence_profile_id"], "display-3456x2234@2x")
        XCTAssertEqual(summary.1["current_profile_candidate_id"], "display-2560x1440@1x")
        XCTAssertEqual(summary.1["profile_candidate_matches_persistence_profile"], "false")
        XCTAssertEqual(summary.1["write_needed"], "true")
        XCTAssertEqual(summary.1["write_status"], "succeeded")
        XCTAssertEqual(summary.1["profile_workspace_count"], "1")
        XCTAssertEqual(summary.1["profile_fingerprint"]?.count, 64)
    }

    private func displayConfiguration(
        displays: [(Int, Int, Double, Bool)],
        profileDisplayIndex: Int?
    ) -> WorkspaceLayoutDisplayConfiguration {
        let descriptors = displays.map {
            WorkspaceLayoutDisplayDescriptor(
                pixelWidth: $0.0,
                pixelHeight: $0.1,
                scale: $0.2,
                isMain: $0.3
            )
        }
        return WorkspaceLayoutDisplayConfiguration(
            displays: descriptors,
            profileDisplay: profileDisplayIndex.flatMap { index in
                descriptors.indices.contains(index) ? descriptors[index] : nil
            }
        )
    }
}

@MainActor
private final class ResolutionBox {
    var value: WorkspaceLayoutProfileResolution

    init(_ value: WorkspaceLayoutProfileResolution) {
        self.value = value
    }
}
