import RemoteProtocol
import SwiftUI
import UIKit
import XCTest
@testable import ToasttyMobileApp

final class ToasttySessionExecutionProfilePresentationTests: XCTestCase {
    func testTabPresentationRetainsFullNameAndMarksLastReported() throws {
        let title = String(repeating: "Release preparation ", count: 20)
        let live = try XCTUnwrap(ToasttyWorkspaceTabPresentation(title: title, isLastReported: false))
        XCTAssertEqual(live.text, title)
        XCTAssertEqual(live.accessibilityLabel, "Mac tab: \(title)")
        let stale = try XCTUnwrap(ToasttyWorkspaceTabPresentation(title: title, isLastReported: true))
        XCTAssertEqual(stale.text, title)
        XCTAssertEqual(stale.accessibilityLabel, "Last reported. Mac tab: \(title)")
        XCTAssertNil(ToasttyWorkspaceTabPresentation(title: nil, isLastReported: true))
        XCTAssertNil(ToasttyWorkspaceTabPresentation(title: "", isLastReported: false))
    }

    @MainActor
    func testMetadataRowFitsCompactWidthWithLongNamesAndLargestTextInBothDirections() {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for hasProfile in [false, true] {
                let profile = hasProfile ? RemoteSessionExecutionProfile(
                    modelIdentifier: String(repeating: "model-", count: 33), reasoningEffort: "xhigh"
                ) : nil
                let host = UIHostingController(rootView: ToasttyComposerMetadataView(
                    profile: profile, tabTitle: String(repeating: "Release preparation ", count: 20),
                    isLastReported: true
                ).environment(\.dynamicTypeSize, .accessibility5).environment(\.layoutDirection, direction))
                let size = host.sizeThatFits(in: CGSize(width: 284, height: 2_000))
                XCTAssertLessThanOrEqual(size.width, 284)
                XCTAssertGreaterThan(size.height, 0)
                XCTAssertLessThanOrEqual(size.height, 120)
            }
        }
    }

    @MainActor
    func testMissingTabPreservesProfileSizeAndMissingBothOmitsRow() {
        let profile = RemoteSessionExecutionProfile(modelIdentifier: "gpt-6", reasoningEffort: "xhigh")
        let proposal = CGSize(width: 284, height: 2_000)
        let original = UIHostingController(rootView: ToasttySessionExecutionProfileView(
            presentation: ToasttySessionExecutionProfilePresentation(profile: profile, isLastReported: false)!
        ))
        let profileOnly = UIHostingController(rootView: ToasttyComposerMetadataView(
            profile: profile, tabTitle: nil, isLastReported: false
        ))
        XCTAssertEqual(original.sizeThatFits(in: proposal), profileOnly.sizeThatFits(in: proposal))
        let absent = UIHostingController(rootView: ToasttyComposerMetadataView(
            profile: nil, tabTitle: nil, isLastReported: false
        ))
        XCTAssertEqual(absent.sizeThatFits(in: proposal).height, 0)
    }

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
