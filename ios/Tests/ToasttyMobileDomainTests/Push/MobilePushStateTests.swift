import Foundation
import RemoteProtocol
import Security
import XCTest
@testable import ToasttyMobileDomain

final class MobilePushStateTests: XCTestCase {
    func testSeparatePushRecordUsesDeviceOnlySecuritySeamAndRetainsCleanup() throws {
        let security = RecordingSecurityClient()
        security.copyResult = .status(errSecItemNotFound)
        let store = KeychainMobilePushStateStore(securityClient: security)
        var state = MobilePushState()
        state.active = Self.registration()
        state.desired = true
        try store.save(state)
        let added = try XCTUnwrap(security.addedItems.last)
        XCTAssertEqual(added.locator.service, KeychainMobilePushStateStore.defaultService)
        XCTAssertNotEqual(added.locator.service, KeychainMobileCredentialStore.defaultService)
        XCTAssertEqual(added.locator.synchronizable, .nonSynchronizable)
        security.copyResult = .data(added.data)
        var restored = try XCTUnwrap(store.load())
        restored.queueCleanup()
        try store.save(restored)
        let saved = try JSONDecoder().decode(MobilePushState.self, from: XCTUnwrap(security.updatedItems.last).1)
        XCTAssertNil(saved.active)
        XCTAssertEqual(saved.cleanup.map(\.registrationID), [state.active!.registrationID])
        XCTAssertNil(saved.cleanup.first?.nonce)
    }

    func testLockedStoreDoesNotLookLikeMissingAndInvalidCredentialIsRejected() throws {
        let security = RecordingSecurityClient()
        let store = KeychainMobilePushStateStore(securityClient: security)
        security.copyResult = .status(errSecInteractionNotAllowed)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? MobilePushStoreFailure, .locked) }
        security.copyResult = .status(errSecItemNotFound)
        XCTAssertNil(try store.load())
        var state = MobilePushState()
        state.pending = Self.registration()
        state.pending?.managementToken = "private-invalid-token"
        XCTAssertThrowsError(try store.save(state))
        XCTAssertTrue(security.addedItems.isEmpty)
    }

    static func registration(stage: MobilePushRegistration.Stage = .pending) -> MobilePushRegistration {
        MobilePushRegistration(pairingID: UUID(), gatewayURL: NativePairingClientTests.gatewayURL,
            relayURL: URL(string: "https://push.example.com")!, relayID: "toastty-push-dev-v1",
            deviceToken: String(repeating: "ab", count: 32), managementToken: String(repeating: "A", count: 43),
            sendToken: String(repeating: "A", count: 43), stage: stage)
    }
}
