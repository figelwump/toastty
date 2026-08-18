import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

final class ToasttyAppDiagnosticProjectionTests: XCTestCase {
    func testSessionTransitionsProjectOnlyCategoricalAuthAndStreamEvents() {
        XCTAssertEqual(
            ToasttyAppDiagnosticProjection.events(from: nil, to: .restoring),
            []
        )
        XCTAssertEqual(
            ToasttyAppDiagnosticProjection.events(from: .restoring, to: .paired(.connecting)),
            [.authSucceeded, .streamConnecting]
        )
        XCTAssertEqual(
            ToasttyAppDiagnosticProjection.events(from: .paired(.connecting), to: .paired(.live)),
            [.streamConnected]
        )
        XCTAssertEqual(
            ToasttyAppDiagnosticProjection.events(from: .restoring, to: .paired(.reconnecting)),
            [.authSucceeded, .streamReconnecting]
        )
        XCTAssertEqual(
            ToasttyAppDiagnosticProjection.events(from: .paired(.reconnecting), to: .paired(.live)),
            [.streamConnected]
        )
        XCTAssertEqual(
            ToasttyAppDiagnosticProjection.events(from: .paired(.live), to: .paired(.unreachable)),
            [.streamDisconnected]
        )
        XCTAssertEqual(
            ToasttyAppDiagnosticProjection.events(from: .paired(.unreachable), to: .unpaired),
            [.authRevoked]
        )
        XCTAssertEqual(
            ToasttyAppDiagnosticProjection.events(from: .restoring, to: .unpaired),
            [.authRequired]
        )
    }

    func testSameSessionStateDoesNotDuplicateEvents() {
        XCTAssertEqual(
            ToasttyAppDiagnosticProjection.events(
                from: .paired(.reconnecting),
                to: .paired(.reconnecting)
            ),
            []
        )
    }

    func testSendOutcomesProjectWithoutAssociatedValues() {
        XCTAssertEqual(
            ToasttyAppDiagnosticProjection.event(for: .enqueued(clientRequestID: "sensitive-id")),
            .sendAccepted
        )
        XCTAssertEqual(
            ToasttyAppDiagnosticProjection.event(for: .notEnqueued(.deviceSendScopeDenied)),
            .sendRejected
        )
    }
}
