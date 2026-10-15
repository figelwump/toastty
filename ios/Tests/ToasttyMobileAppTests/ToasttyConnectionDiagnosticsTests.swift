import Foundation
import XCTest
@testable import ToasttyMobileApp

final class ToasttyConnectionDiagnosticsTests: XCTestCase {
    func testRingBufferRetainsOnlyTheNewestEntriesAtCapacity() {
        var subject = ToasttyConnectionDiagnosticLog(capacity: 3)
        subject.append(.streamConnecting, recordedAt: date(0))
        subject.append(.streamConnected, recordedAt: date(1))
        subject.append(.gatewayRequestStarted, recordedAt: date(2))
        subject.append(.gatewayRequestSucceeded, recordedAt: date(3))

        XCTAssertEqual(subject.capacity, 3)
        XCTAssertEqual(subject.count, 3)
        XCTAssertEqual(
            subject.entries.map(\.event),
            [.streamConnected, .gatewayRequestStarted, .gatewayRequestSucceeded]
        )
        XCTAssertEqual(subject.entries.map(\.sequence), [1, 2, 3])
    }

    func testConnectionEventsRemainAFrozenCategoricalAllowlist() {
        XCTAssertEqual(
            ToasttyConnectionDiagnosticEvent.allCases.map(\.rawValue),
            [
                "request_started", "request_succeeded", "request_failed",
                "connecting", "connected", "reconnecting", "disconnected",
                "send_started", "send_enqueued", "send_accepted", "send_rejected", "send_uncertain",
                "auth_started", "auth_succeeded", "auth_required", "auth_revoked",
                "push_registration_missing", "push_token_changed", "push_relay_changed",
                "push_pairing_changed", "push_proof_expired", "push_registration_expired",
                "push_state_unavailable", "push_mac_configuration_failed", "push_relay_status_failed",
                "push_relay_begin_failed", "push_relay_complete_failed", "push_mac_registration_failed",
                "push_relay_revoke_failed", "push_rate_limited", "push_registration_enabled",
                "push_registration_reused",
            ]
        )
    }

    func testEveryConnectionEventMapsToItsDeclaredCategory() {
        let expected: [ToasttyConnectionDiagnosticEvent: ToasttyDiagnosticCategory] = [
            .gatewayRequestStarted: .gateway,
            .gatewayRequestSucceeded: .gateway,
            .gatewayRequestFailed: .gateway,
            .streamConnecting: .stream,
            .streamConnected: .stream,
            .streamReconnecting: .stream,
            .streamDisconnected: .stream,
            .sendStarted: .send,
            .sendEnqueued: .send,
            .sendAccepted: .send,
            .sendRejected: .send,
            .sendUncertain: .send,
            .authStarted: .auth,
            .authSucceeded: .auth,
            .authRequired: .auth,
            .authRevoked: .auth,
            .pushRegistrationMissing: .gateway,
            .pushTokenChanged: .gateway,
            .pushRelayChanged: .gateway,
            .pushPairingChanged: .gateway,
            .pushProofExpired: .gateway,
            .pushRegistrationExpired: .gateway,
            .pushStateUnavailable: .gateway,
            .pushMacConfigurationFailed: .gateway,
            .pushRelayStatusFailed: .gateway,
            .pushRelayBeginFailed: .gateway,
            .pushRelayCompleteFailed: .gateway,
            .pushMacRegistrationFailed: .gateway,
            .pushRelayRevokeFailed: .gateway,
            .pushRateLimited: .gateway,
            .pushRegistrationEnabled: .gateway,
            .pushRegistrationReused: .gateway,
        ]

        XCTAssertEqual(expected.count, ToasttyConnectionDiagnosticEvent.allCases.count)
        for event in ToasttyConnectionDiagnosticEvent.allCases {
            XCTAssertEqual(event.category, expected[event], "Unexpected category for \(event)")
        }
    }

    func testSystemLoggingPreferencesAreIndependentAndOffByDefault() {
        var subject = ToasttyDiagnosticsState()

        for category in ToasttyDiagnosticCategory.allCases {
            XCTAssertFalse(subject.isSystemLoggingEnabled(category))
        }

        subject.setSystemLoggingEnabled(true, for: .gateway)
        subject.setSystemLoggingEnabled(true, for: .auth)
        XCTAssertTrue(subject.isSystemLoggingEnabled(.gateway))
        XCTAssertFalse(subject.isSystemLoggingEnabled(.stream))
        XCTAssertFalse(subject.isSystemLoggingEnabled(.send))
        XCTAssertTrue(subject.isSystemLoggingEnabled(.auth))

        subject.setSystemLoggingEnabled(false, for: .gateway)
        XCTAssertFalse(subject.isSystemLoggingEnabled(.gateway))
        XCTAssertTrue(subject.isSystemLoggingEnabled(.auth))
    }

    func testLoggerAlwaysRecordsInMemoryButEmitsOnlyEnabledCategories() {
        var subject = ToasttyDiagnosticsState()
        var emissions: [(ToasttyDiagnosticCategory, ToasttyConnectionDiagnosticEvent)] = []

        ToasttyDiagnosticLogger.record(.streamConnecting, in: &subject) {
            emissions.append(($0, $1))
        }
        XCTAssertEqual(subject.connectionLog.entries.map(\.event), [.streamConnecting])
        XCTAssertTrue(emissions.isEmpty)

        subject.setSystemLoggingEnabled(true, for: .stream)
        ToasttyDiagnosticLogger.record(.streamConnected, in: &subject) {
            emissions.append(($0, $1))
        }
        XCTAssertEqual(subject.connectionLog.entries.map(\.event), [
            .streamConnecting,
            .streamConnected,
        ])
        XCTAssertEqual(emissions.count, 1)
        XCTAssertEqual(emissions.first?.0, .stream)
        XCTAssertEqual(emissions.first?.1, .streamConnected)
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + offset)
    }
}
