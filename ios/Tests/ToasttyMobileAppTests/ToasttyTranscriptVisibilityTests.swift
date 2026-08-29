import Foundation
import SwiftUI
import ToasttyMobileDomain
import XCTest
@testable import ToasttyMobileApp

final class ToasttyTranscriptVisibilityTests: XCTestCase {
    func testScrollMetricsUseInsetAdjustedVisibleRectAtLiveEdge() {
        XCTAssertTrue(
            TranscriptScrollMetrics(
                contentHeight: 2_160,
                visibleMaxY: 2_300.7,
                visibleHeight: 800
            ).isAtLiveEdge,
            "The inset-adjusted visible rect can extend beyond content at the physical bottom"
        )
        XCTAssertTrue(
            TranscriptScrollMetrics(
                contentHeight: 2_160,
                visibleMaxY: 2_089,
                visibleHeight: 800
            ).isAtLiveEdge
        )
        XCTAssertFalse(
            TranscriptScrollMetrics(
                contentHeight: 2_160,
                visibleMaxY: 2_088,
                visibleHeight: 800
            ).isAtLiveEdge,
            "The 72-point threshold is exclusive"
        )
    }

    func testScrollMetricsUseTightTolerantPhysicalCompletionThreshold() {
        XCTAssertTrue(
            TranscriptScrollMetrics(
                contentHeight: 2_160,
                visibleMaxY: 2_159.25,
                visibleHeight: 800
            ).hasReachedPhysicalLiveEdge
        )
        XCTAssertTrue(
            TranscriptScrollMetrics(
                contentHeight: 2_160,
                visibleMaxY: 2_300.7,
                visibleHeight: 800
            ).hasReachedPhysicalLiveEdge,
            "Inset-adjusted overshoot is still the physical tail"
        )
        XCTAssertFalse(
            TranscriptScrollMetrics(
                contentHeight: 2_160,
                visibleMaxY: 2_158.75,
                visibleHeight: 800
            ).hasReachedPhysicalLiveEdge
        )
        XCTAssertTrue(
            TranscriptScrollMetrics(
                contentHeight: 2_160,
                visibleMaxY: 2_089,
                visibleHeight: 800
            ).isNearLiveEdge,
            "The broader threshold remains available for the user-facing state"
        )
    }

    func testScrollMetricsIgnoreSubpointViewportJitter() {
        let baseline = TranscriptScrollMetrics(
            contentHeight: 2_160,
            visibleMaxY: 2_160,
            visibleHeight: 800
        )

        XCTAssertFalse(
            TranscriptScrollMetrics(
                contentHeight: 2_160,
                visibleMaxY: 2_160,
                visibleHeight: 799.51
            ).hasViewportHeightChange(comparedTo: baseline)
        )
        XCTAssertTrue(
            TranscriptScrollMetrics(
                contentHeight: 2_160,
                visibleMaxY: 2_160,
                visibleHeight: 799.5
            ).hasViewportHeightChange(comparedTo: baseline)
        )
    }

    func testScrollMetricsTreatContentAndViewportChangesAsLiveEdgeLayoutChanges() {
        let baseline = TranscriptScrollMetrics(
            contentHeight: 2_160,
            visibleMaxY: 2_160,
            visibleHeight: 800
        )

        XCTAssertFalse(
            TranscriptScrollMetrics(
                contentHeight: 2_160.49,
                visibleMaxY: 2_160,
                visibleHeight: 799.51
            ).hasLiveEdgeLayoutChange(comparedTo: baseline)
        )
        XCTAssertTrue(
            TranscriptScrollMetrics(
                contentHeight: 2_160.5,
                visibleMaxY: 2_160,
                visibleHeight: 800
            ).hasLiveEdgeLayoutChange(comparedTo: baseline)
        )
        XCTAssertTrue(
            TranscriptScrollMetrics(
                contentHeight: 2_160,
                visibleMaxY: 2_160,
                visibleHeight: 799.5
            ).hasLiveEdgeLayoutChange(comparedTo: baseline)
        )
    }

    func testEquivalentReinforcementsCoalesceBeforeExecution() {
        var coordinator = TranscriptScrollCoordinator()

        coordinator.requestSend(41)
        let send = coordinator.command
        let initialCandidate = send.flatMap { coordinator.executionCandidate(for: $0) }
        XCTAssertEqual(send?.target, .liveEdge)
        XCTAssertEqual(send?.motion, .stable)
        XCTAssertEqual(send?.liveEdgeOwner, .send(41))
        XCTAssertTrue(coordinator.ownsLiveEdge)

        coordinator.reinforceLiveEdge()
        let reinforcedCandidate = send.flatMap { coordinator.executionCandidate(for: $0) }
        XCTAssertEqual(coordinator.command?.target, .liveEdge)
        XCTAssertEqual(coordinator.command?.motion, .stable)
        XCTAssertEqual(coordinator.command?.liveEdgeOwner, .send(41))
        XCTAssertEqual(coordinator.command?.sequence, send?.sequence)
        XCTAssertGreaterThan(
            reinforcedCandidate?.layoutGeneration ?? 0,
            initialCandidate?.layoutGeneration ?? 0
        )
        XCTAssertFalse(coordinator.markExecuted(initialCandidate!))
        XCTAssertTrue(coordinator.markExecuted(reinforcedCandidate!))
    }

    func testStableSettlingExecutesAfterBoundDuringSustainedLayoutChanges() {
        for completedCheck in 1 ..< TranscriptScrollCoordinator.maximumStableSettleChecks {
            XCTAssertFalse(
                TranscriptScrollCoordinator.shouldExecuteStableCandidate(
                    isQuiet: false,
                    completedSettleChecks: completedCheck
                )
            )
        }
        XCTAssertTrue(
            TranscriptScrollCoordinator.shouldExecuteStableCandidate(
                isQuiet: false,
                completedSettleChecks: TranscriptScrollCoordinator.maximumStableSettleChecks
            ),
            "Continuous generation changes must not starve the first live-edge move"
        )
        XCTAssertTrue(
            TranscriptScrollCoordinator.shouldExecuteStableCandidate(
                isQuiet: true,
                completedSettleChecks: 1
            ),
            "A quiet generation still executes after one 50ms interval"
        )
    }

    func testLateReinforcementAfterExecutionSchedulesFollowUp() {
        var coordinator = TranscriptScrollCoordinator()

        coordinator.requestInitialLiveEdge()
        let initialCommand = coordinator.command!
        let initialCandidate = coordinator.executionCandidate(for: initialCommand)!
        XCTAssertTrue(coordinator.markExecuted(initialCandidate))

        coordinator.reinforceLiveEdge()

        XCTAssertGreaterThan(coordinator.command?.sequence ?? 0, initialCommand.sequence)
        XCTAssertEqual(coordinator.command?.motion, .stable)
        XCTAssertEqual(coordinator.command?.liveEdgeOwner, .automatic)
        XCTAssertNotNil(coordinator.command.flatMap { coordinator.executionCandidate(for: $0) })
    }

    func testSendOwnerSurvivesLayoutSettlingAndLateFollowUp() {
        var coordinator = TranscriptScrollCoordinator()

        coordinator.requestSend(41)
        let sendCommand = coordinator.command!
        coordinator.reinforceLiveEdge()
        coordinator.reinforceLiveEdge()
        let settledCandidate = coordinator.executionCandidate(for: sendCommand)!

        XCTAssertEqual(coordinator.liveEdgeOwner, .send(41))
        XCTAssertEqual(settledCandidate.command.liveEdgeOwner, .send(41))
        XCTAssertTrue(coordinator.markExecuted(settledCandidate))

        coordinator.reinforceLiveEdge()

        XCTAssertEqual(coordinator.liveEdgeOwner, .send(41))
        XCTAssertEqual(coordinator.command?.liveEdgeOwner, .send(41))
        XCTAssertGreaterThan(coordinator.command?.sequence ?? 0, sendCommand.sequence)
    }

    func testLatestExplicitLiveEdgeRequestWins() {
        var coordinator = TranscriptScrollCoordinator()

        coordinator.requestJump()
        let jump = coordinator.command
        XCTAssertEqual(jump?.motion, .animated)
        XCTAssertEqual(jump?.liveEdgeOwner, .jump(1))

        coordinator.reinforceLiveEdge()
        XCTAssertEqual(coordinator.command?.motion, .animated)
        XCTAssertEqual(coordinator.command?.liveEdgeOwner, .jump(1))

        coordinator.requestSend(73)
        XCTAssertEqual(coordinator.command?.motion, .stable)
        XCTAssertEqual(coordinator.command?.liveEdgeOwner, .send(73))
        XCTAssertGreaterThan(coordinator.command?.sequence ?? 0, jump?.sequence ?? 0)
    }

    func testDirectInteractionCancelsAutomaticScrollOwnership() {
        var coordinator = TranscriptScrollCoordinator()
        coordinator.requestSend(9)

        coordinator.cancelForInteraction()

        XCTAssertNil(coordinator.command)
        XCTAssertFalse(coordinator.ownsLiveEdge)
    }

    func testTrackingWithoutDragStillResolvesFollowingAtIdle() {
        XCTAssertTrue(TranscriptScrollCoordinator.shouldResolveFollowing(
            oldPhase: .tracking,
            newPhase: .idle
        ))
        XCTAssertFalse(TranscriptScrollCoordinator.shouldResolveFollowing(
            oldPhase: .animating,
            newPhase: .idle
        ))
        XCTAssertFalse(TranscriptScrollCoordinator.shouldResolveFollowing(
            oldPhase: .tracking,
            newPhase: .interacting
        ))
    }

    func testFailedSendTailAcquisitionReleasesOwnershipForRecovery() {
        var coordinator = TranscriptScrollCoordinator()
        coordinator.requestSend(9)
        let candidate = coordinator.executionCandidate(for: coordinator.command!)!
        XCTAssertTrue(coordinator.markExecuted(candidate))

        XCTAssertFalse(coordinator.finishSend(atLiveEdge: false))

        XCTAssertNil(coordinator.command)
        XCTAssertFalse(coordinator.ownsLiveEdge)
    }

    func testSuccessfulSendTailAcquisitionReturnsToAutomaticFollowing() {
        var coordinator = TranscriptScrollCoordinator()
        coordinator.requestSend(9)
        let candidate = coordinator.executionCandidate(for: coordinator.command!)!
        XCTAssertTrue(coordinator.markExecuted(candidate))

        XCTAssertTrue(coordinator.finishSend(atLiveEdge: true))

        XCTAssertNil(coordinator.command)
        XCTAssertEqual(coordinator.liveEdgeOwner, .automatic)
        XCTAssertTrue(coordinator.ownsLiveEdge)
    }

    func testPendingSendCannotCompleteBeforeSettledExecution() {
        var coordinator = TranscriptScrollCoordinator()
        coordinator.requestSend(9)
        coordinator.reinforceLiveEdge()

        XCTAssertFalse(coordinator.finishSend(atLiveEdge: true))
        XCTAssertEqual(coordinator.liveEdgeOwner, .send(9))
        XCTAssertNotNil(coordinator.command)
    }

    func testHistoryAnchorDoesNotSupersedeExplicitLiveEdgeOwnership() {
        var coordinator = TranscriptScrollCoordinator()
        coordinator.requestSend(9)
        let anchor = ToasttyTranscriptBlockID(rowID: rowID(sequence: 4))

        XCTAssertFalse(coordinator.requestHistoryAnchor(anchor))

        XCTAssertEqual(coordinator.command?.target, .liveEdge)
        XCTAssertEqual(coordinator.command?.motion, .stable)
        XCTAssertEqual(coordinator.command?.liveEdgeOwner, .send(9))
        XCTAssertTrue(coordinator.ownsLiveEdge)
    }

    func testHistoryAnchorSupersedesAutomaticLiveEdgeFollowing() {
        var coordinator = TranscriptScrollCoordinator()
        coordinator.requestInitialLiveEdge()
        let anchor = ToasttyTranscriptBlockID(rowID: rowID(sequence: 4))

        XCTAssertTrue(coordinator.requestHistoryAnchor(anchor))

        XCTAssertEqual(coordinator.command?.target, .transcript(anchor))
        XCTAssertEqual(coordinator.command?.motion, .stable)
        XCTAssertNil(coordinator.command?.liveEdgeOwner)
        XCTAssertFalse(coordinator.ownsLiveEdge)
    }

    func testVisibleLiveEdgeRequiresActiveLiveMeasuredNonemptyBoundary() {
        let boundary = rowID(sequence: 7)

        XCTAssertTrue(key(boundary: boundary, measuredBoundary: boundary).isEligible)
        XCTAssertTrue(
            key(boundary: nil, measuredBoundary: nil).isEligible,
            "An authoritative empty live transcript is visibly read"
        )
        XCTAssertFalse(key(boundary: boundary, measuredBoundary: nil).isEligible)
        XCTAssertFalse(
            key(
                boundary: nil,
                measuredBoundary: nil,
                hasMeasuredScrollGeometry: false
            ).isEligible
        )
        XCTAssertFalse(
            key(boundary: boundary, measuredBoundary: rowID(sequence: 6)).isEligible
        )
        XCTAssertFalse(
            key(boundary: boundary, measuredBoundary: boundary, phase: .resyncing).isEligible
        )
        XCTAssertFalse(
            key(
                boundary: boundary,
                measuredBoundary: boundary,
                scenePhase: .background
            ).isEligible
        )
        XCTAssertFalse(
            key(boundary: boundary, measuredBoundary: boundary, isVisible: false).isEligible
        )
        XCTAssertFalse(
            key(boundary: boundary, measuredBoundary: boundary, isAtLiveEdge: false).isEligible
        )
        XCTAssertNotEqual(
            key(boundary: boundary, measuredBoundary: boundary, readAcknowledgementEpoch: .working),
            key(boundary: boundary, measuredBoundary: boundary, readAcknowledgementEpoch: .ready),
            "A new ready epoch at the same transcript boundary must retrigger acknowledgement"
        )
    }

    private func key(
        boundary: ToasttyTranscriptRowID?,
        measuredBoundary: ToasttyTranscriptRowID?,
        phase: ToasttyConversationPresentationPhase = .live,
        scenePhase: ScenePhase = .active,
        isVisible: Bool = true,
        isAtLiveEdge: Bool = true,
        hasMeasuredScrollGeometry: Bool = true,
        readAcknowledgementEpoch: MobileSessionStatus? = .ready
    ) -> TranscriptLiveEdgeVisibilityKey {
        TranscriptLiveEdgeVisibilityKey(
            phase: phase,
            scenePhase: scenePhase,
            isVisible: isVisible,
            isAtLiveEdge: isAtLiveEdge,
            hasMeasuredScrollGeometry: hasMeasuredScrollGeometry,
            measuredBoundaryID: measuredBoundary,
            latestBoundaryID: boundary,
            readAcknowledgementEpoch: readAcknowledgementEpoch
        )
    }

    private func rowID(sequence: UInt64) -> ToasttyTranscriptRowID {
        ToasttyTranscriptRowID(
            projectionRunID: UUID(uuidString: "D2000000-0000-0000-0000-000000000001")!,
            projectionGeneration: 1,
            conversationID: UUID(uuidString: "B1000000-0000-0000-0000-000000000001")!,
            sequence: sequence
        )
    }
}
