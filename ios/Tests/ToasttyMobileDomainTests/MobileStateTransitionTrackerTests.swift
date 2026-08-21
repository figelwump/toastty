import XCTest
@testable import ToasttyMobileDomain

final class MobileStateTransitionTrackerTests: XCTestCase {
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    func testFirstObservationSeedsAnchorFromReportedActivity() {
        var tracker = MobileStateTransitionTracker()
        let reported = MobileActivityAge(secondsAtReceipt: 300, receivedAtMonotonicTime: 1_000)

        let anchor = tracker.stateEnteredAge(
            for: id,
            state: .working,
            activityAge: reported,
            receivedAtMonotonicTime: 1_000
        )

        XCTAssertEqual(anchor, reported)
    }

    func testAnchorHoldsWhileBucketUnchangedDespiteNewerActivity() {
        var tracker = MobileStateTransitionTracker()
        let seeded = tracker.stateEnteredAge(
            for: id,
            state: .working,
            activityAge: MobileActivityAge(secondsAtReceipt: 300, receivedAtMonotonicTime: 1_000),
            receivedAtMonotonicTime: 1_000
        )

        let heldAcrossActivity = tracker.stateEnteredAge(
            for: id,
            state: .working,
            activityAge: MobileActivityAge(secondsAtReceipt: 0, receivedAtMonotonicTime: 1_060),
            receivedAtMonotonicTime: 1_060
        )

        XCTAssertEqual(heldAcrossActivity, seeded)
    }

    func testBucketTransitionRestampsAnchorToNow() {
        var tracker = MobileStateTransitionTracker()
        _ = tracker.stateEnteredAge(
            for: id,
            state: .working,
            activityAge: MobileActivityAge(secondsAtReceipt: 300, receivedAtMonotonicTime: 1_000),
            receivedAtMonotonicTime: 1_000
        )

        let transitioned = tracker.stateEnteredAge(
            for: id,
            state: .ready,
            activityAge: MobileActivityAge(secondsAtReceipt: 240, receivedAtMonotonicTime: 1_060),
            receivedAtMonotonicTime: 1_060
        )

        XCTAssertEqual(
            transitioned,
            MobileActivityAge(secondsAtReceipt: 0, receivedAtMonotonicTime: 1_060)
        )
    }

    func testRetainDropsVanishedSessionsSoReappearanceReseeds() {
        var tracker = MobileStateTransitionTracker()
        _ = tracker.stateEnteredAge(
            for: id,
            state: .working,
            activityAge: MobileActivityAge(secondsAtReceipt: 0, receivedAtMonotonicTime: 1_000),
            receivedAtMonotonicTime: 1_000
        )
        tracker.retain([])

        let reported = MobileActivityAge(secondsAtReceipt: 600, receivedAtMonotonicTime: 2_000)
        let reseeded = tracker.stateEnteredAge(
            for: id,
            state: .working,
            activityAge: reported,
            receivedAtMonotonicTime: 2_000
        )

        XCTAssertEqual(reseeded, reported)
    }

    func testUnsupportedStatusVariantsShareOneBucketAnchor() {
        var tracker = MobileStateTransitionTracker()
        let seeded = tracker.stateEnteredAge(
            for: id,
            state: .unsupported(rawValue: "future-a"),
            activityAge: MobileActivityAge(secondsAtReceipt: 300, receivedAtMonotonicTime: 1_000),
            receivedAtMonotonicTime: 1_000
        )

        let heldAcrossVariants = tracker.stateEnteredAge(
            for: id,
            state: .unsupported(rawValue: "future-b"),
            activityAge: MobileActivityAge(secondsAtReceipt: 0, receivedAtMonotonicTime: 1_060),
            receivedAtMonotonicTime: 1_060
        )

        XCTAssertEqual(heldAcrossVariants, seeded)
    }
}
