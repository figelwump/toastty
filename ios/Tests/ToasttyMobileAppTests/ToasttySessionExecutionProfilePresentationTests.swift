import RemoteProtocol
import SwiftUI
import UIKit
import XCTest
@testable import ToasttyMobileApp

final class ToasttySessionExecutionProfilePresentationTests: XCTestCase {
    @MainActor
    func testMaximumProfileLeavesRoomForComposerAtCompactWidthAndLargestTextSize() throws {
        let profile = RemoteSessionExecutionProfile(
            modelIdentifier: String(repeating: "model-", count: 33) + "v1",
            reasoningEffort: String(repeating: "effort-", count: 11) + "max"
        )
        let presentation = try XCTUnwrap(ToasttySessionExecutionProfilePresentation(
            profile: profile, isLastReported: true
        ))
        let host = UIHostingController(rootView: ToasttySessionExecutionProfileView(presentation: presentation)
            .environment(\.dynamicTypeSize, .accessibility5))
        // A compact phone must leave room for the field, keyboard, and
        // existing notices, even at the maximum accepted metadata length.
        let size = host.sizeThatFits(in: CGSize(width: 284, height: 2_000))
        XCTAssertLessThanOrEqual(size.height, 120)
        XCTAssertEqual(presentation.accessibilityLabel,
                       "Last reported. Model: \(profile.modelIdentifier!). Reasoning: \(profile.reasoningEffort!)")
    }

    func testAbsentAndEmptyProfilesHaveNoRowEvenWhenDisconnected() {
        for isLastReported in [false, true] {
            XCTAssertNil(ToasttySessionExecutionProfilePresentation(profile: nil, isLastReported: isLastReported))
            XCTAssertNil(ToasttySessionExecutionProfilePresentation(
                profile: RemoteSessionExecutionProfile(), isLastReported: isLastReported
            ))
        }
    }

    func testFullProfilePreservesProviderSpellingAndLabelsAccessibilityFields() throws {
        let profile = RemoteSessionExecutionProfile(modelIdentifier: "Provider/Model-vNext", reasoningEffort: "xHigh")
        let live = try XCTUnwrap(ToasttySessionExecutionProfilePresentation(profile: profile, isLastReported: false))
        XCTAssertEqual(live.text, "Provider/Model-vNext · xHigh reasoning")
        XCTAssertEqual(live.accessibilityLabel, "Model: Provider/Model-vNext. Reasoning: xHigh")
        let stale = try XCTUnwrap(ToasttySessionExecutionProfilePresentation(profile: profile, isLastReported: true))
        XCTAssertEqual(stale.text, "Last reported · Provider/Model-vNext · xHigh reasoning")
        XCTAssertEqual(stale.accessibilityLabel, "Last reported. Model: Provider/Model-vNext. Reasoning: xHigh")
    }

    func testPartialProfilesOmitUnknownFieldsAndSeparators() throws {
        let modelOnly = try XCTUnwrap(ToasttySessionExecutionProfilePresentation(
            profile: RemoteSessionExecutionProfile(modelIdentifier: "custom-model"), isLastReported: false
        ))
        XCTAssertEqual(modelOnly.text, "custom-model")
        XCTAssertEqual(modelOnly.accessibilityLabel, "Model: custom-model")
        let effortOnly = try XCTUnwrap(ToasttySessionExecutionProfilePresentation(
            profile: RemoteSessionExecutionProfile(reasoningEffort: "adaptive"), isLastReported: true
        ))
        XCTAssertEqual(effortOnly.text, "Last reported · adaptive reasoning")
        XCTAssertEqual(effortOnly.accessibilityLabel, "Last reported. Reasoning: adaptive")
    }
}
