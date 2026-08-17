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
