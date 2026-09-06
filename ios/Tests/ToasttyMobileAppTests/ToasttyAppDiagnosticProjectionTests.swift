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
            .sendEnqueued
        )
        XCTAssertEqual(
            ToasttyAppDiagnosticProjection.event(for: .notEnqueued(.deviceSendScopeDenied)),
            .sendRejected
        )
    }
    func testSendDeliveryEventsDistinguishAcceptanceAndDeduplicateConfirmation() {
        func state(_ delivery: SendDeliveryState) -> SendReconciliationState {
            SendReconciliationState(records: [.init(
                clientRequestID: "private-request", text: "private-message",
                projectionRunID: nil, deliveryState: delivery
            )])
        }
        XCTAssertEqual(ToasttyAppDiagnosticProjection.events(from: .init(), to: state(.pending(.awaitingResponse))), [])
        XCTAssertEqual(ToasttyAppDiagnosticProjection.events(from: state(.pending(.awaitingResponse)), to: state(.pending(.accepted))), [.sendAccepted])
        XCTAssertEqual(ToasttyAppDiagnosticProjection.events(from: state(.pending(.accepted)), to: state(.confirmed(sequence: 3))), [])
        XCTAssertEqual(ToasttyAppDiagnosticProjection.events(from: state(.pending(.accepted)), to: state(.uncertain)), [.sendUncertain])
        XCTAssertEqual(ToasttyAppDiagnosticProjection.events(from: state(.pending(.awaitingResponse)), to: state(.operationFailed)), [.sendRejected])
    }

}
