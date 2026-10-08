import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

@MainActor
final class ToasttyPushControllerTests: XCTestCase {
    func testAllowPersistsIntentAndStartsProofWithoutBlockingHomeWithASuccessScreen() async throws {
        let h = try await Harness.make()
        await h.controller.reconcile()
        XCTAssertTrue(h.controller.canIntroduce)
        await h.controller.continueIntroduction()
        XCTAssertTrue(h.controller.desired)
        XCTAssertEqual(h.notifications.permissionRequests, 1)
        XCTAssertEqual(h.controller.presentation, .pending)
        await h.controller.reconcile()
        XCTAssertEqual(h.notifications.registrationRequests, 1)
        h.controller.receivedToken(Harness.token)
        await h.controller.reconcile()
        let pending = try XCTUnwrap(h.controller.storedState?.pending)
        XCTAssertEqual(try h.store.load()?.pending?.registrationID, pending.registrationID)
        await assertBeginCount(1, h.relay)
        let suppressed = await h.controller.receiveForeground(Harness.proof(pending))
        XCTAssertTrue(suppressed)
        await h.controller.reconcile()
        XCTAssertEqual(h.controller.presentation, .enabled)
        XCTAssertNil(h.controller.storedState?.pending)
        XCTAssertNil(h.controller.errorMessage)
        let handoffs = await h.native.grants
        XCTAssertEqual(handoffs.compactMap { $0?.registrationID }, [pending.registrationID])
    }

    func testDeclineAndNotNowAreRememberedWithoutAutomaticPermissionRequests() async throws {
        let h = try await Harness.make()
        await h.controller.reconcile()
        h.controller.deferIntroduction()
        await h.controller.reconcile()
        XCTAssertFalse(h.controller.canIntroduce)
        XCTAssertFalse(h.controller.desired)
        XCTAssertEqual(h.notifications.permissionRequests, 0)
        let declined = try await Harness.make()
        declined.notifications.grantsPermission = false
        await declined.controller.reconcile()
        await declined.controller.continueIntroduction()
        await declined.controller.reconcile()
        XCTAssertEqual(declined.controller.presentation, .permissionDenied)
        XCTAssertFalse(declined.controller.canIntroduce)
        XCTAssertTrue(declined.controller.desired)
        XCTAssertTrue(try XCTUnwrap(declined.store.load()).desired)
        await assertBeginCount(0, declined.relay)
        declined.notifications.currentPermission = .allowed
        declined.controller.enteredForeground()
        declined.controller.receivedToken(Harness.token)
        await declined.controller.reconcile()
        XCTAssertEqual(declined.controller.presentation, .pending)
        await assertBeginCount(1, declined.relay)
    }

    func testDeliveredProofIsRetainedUntilItsNonceCanBeSaved() async throws {
        let h = try await Harness.make(desired: true)
        h.controller.receivedToken(Harness.token)
        await h.controller.reconcile()
        let pending = try XCTUnwrap(h.controller.storedState?.pending)
        h.notifications.delivered = [Harness.proof(pending)]
        h.store.saveFailure = .locked
        await h.controller.reconcile()
        XCTAssertEqual(h.notifications.delivered.count, 1)
        XCTAssertNil(h.controller.storedState?.pending?.nonce)
        await assertCompleteCount(0, h.relay)
        h.store.saveFailure = nil
        await h.controller.reconcile()
        XCTAssertTrue(h.notifications.delivered.isEmpty)
        XCTAssertEqual(h.controller.presentation, .enabled)
        await assertCompleteCount(1, h.relay)
    }

    func testProofCompletesBeforeBeginHTTPResponseAndCannotBeRevertedByIt() async throws {
        let h = try await Harness.make(desired: true)
        await h.relay.pauseBegin()
        h.controller.receivedToken(Harness.token)
        let beginning = Task { await h.controller.reconcile() }
        for _ in 0..<100 {
            if await h.relay.beginCount > 0 { break }
            await Task.yield()
        }
        let pending = try XCTUnwrap(h.controller.storedState?.pending)
        _ = await h.controller.receiveForeground(Harness.proof(pending))
        await assertCompleteCount(1, h.relay)
        XCTAssertEqual(h.controller.storedState?.pending?.stage, .relayActive)
        await h.relay.finishBegin()
        await beginning.value
        XCTAssertEqual(h.controller.presentation, .enabled)
        XCTAssertNil(h.controller.storedState?.pending)
    }

    func testBackgroundProofIsPersistedAndCompletesOnNextForeground() async throws {
        let h = try await Harness.make(desired: true)
        h.controller.receivedToken(Harness.token)
        await h.controller.reconcile()
        let pending = try XCTUnwrap(h.controller.storedState?.pending)
        h.controller.enteredBackground()
        _ = await h.controller.receiveForeground(Harness.proof(pending))
        await assertCompleteCount(0, h.relay)
        XCTAssertNotNil(try h.store.load()?.pending?.nonce)
        h.controller.enteredForeground()
        await h.controller.reconcile()
        XCTAssertEqual(h.controller.presentation, .enabled)
        await assertBeginCount(1, h.relay)
    }

    func testLostCompleteAndHandoffResponsesRetryWithoutAnotherVerificationPush() async throws {
        let h = try await Harness.make(desired: true)
        await h.relay.failCompletionOnce()
        await h.native.failHandoffOnce()
        h.controller.receivedToken(Harness.token)
        await h.controller.reconcile()
        let pending = try XCTUnwrap(h.controller.storedState?.pending)
        _ = await h.controller.receiveForeground(Harness.proof(pending))
        XCTAssertNotNil(try h.store.load()?.pending?.nonce)
        await h.controller.reconcile()
        XCTAssertEqual(h.controller.storedState?.pending?.stage, .relayActive)
        XCTAssertNotNil(h.controller.errorMessage)
        await h.controller.reconcile()
        XCTAssertEqual(h.controller.presentation, .enabled)
        await assertBeginCount(1, h.relay)
        await assertCompleteCount(2, h.relay)
    }

    func testTokenReplacementKeepsWorkingRegistrationUntilProofAndHandoffFinish() async throws {
        let h = try await Harness.make(desired: true)
        h.controller.receivedToken(Harness.token)
        await h.controller.reconcile()
        let original = try XCTUnwrap(h.controller.storedState?.pending)
        _ = await h.controller.receiveForeground(Harness.proof(original))
        await h.controller.reconcile()
        h.controller.receivedToken(String(repeating: "cd", count: 32))
        await h.controller.reconcile()
        XCTAssertEqual(h.controller.storedState?.active?.registrationID, original.registrationID)
        let replacement = try XCTUnwrap(h.controller.storedState?.pending)
        XCTAssertNotEqual(replacement.registrationID, original.registrationID)
        _ = await h.controller.receiveForeground(Harness.proof(original))
        XCTAssertEqual(h.controller.storedState?.pending?.stage, .pending)
        _ = await h.controller.receiveForeground(Harness.proof(replacement))
        await h.controller.reconcile()
        XCTAssertEqual(h.controller.storedState?.active?.registrationID, replacement.registrationID)
        XCTAssertTrue(h.controller.storedState?.cleanup.contains { $0.registrationID == original.registrationID } == true)
    }

    func testOfflineUnpairAndMacRevocationKeepIndependentCleanupAfterCredentialDeletion() async throws {
        let h = try await Harness.make(desired: true)
        h.controller.receivedToken(Harness.token)
        await h.controller.reconcile()
        await h.relay.setRevokeFailure(true)
        await h.controller.prepareForUnpair()
        try await h.vault.delete()
        h.controller.updateConnection(gatewayURL: nil, pairingID: nil, connected: false, supported: false)
        await h.controller.reconcile()
        XCTAssertFalse(h.controller.desired)
        XCTAssertEqual(h.controller.storedState?.cleanup.count, 1)
        XCTAssertNil(h.controller.storedState?.pending)
        let retained = try XCTUnwrap(try h.store.load()?.cleanup.first)
        XCTAssertTrue(KeychainMobilePushStateStore.isCapability(retained.managementToken))
        await h.relay.setRevokeFailure(false)
        h.clock.advance(31)
        await h.controller.reconcile()
        XCTAssertTrue(h.controller.storedState?.cleanup.isEmpty == true)
    }

    func testOldAlertsFromCurrentPairingStillRouteAfterOffAndOtherPairingAlertsAreIgnored() async throws {
        let h = try await Harness.make()
        let conversation = UUID()
        let current = RemotePushPayload(kind: .session, registrationID: UUID(), pairingID: h.credential.device.id,
            conversationID: RemoteConversationID(rawValue: conversation), eventID: UUID())
        h.controller.receiveTap(current)
        XCTAssertEqual(h.controller.pendingConversationID, conversation)
        h.controller.consumedConversationTap()
        var oldPairing = current; oldPairing.pairingID = UUID()
        h.controller.receiveTap(oldPairing)
        XCTAssertNil(h.controller.pendingConversationID)
        h.controller.setOpenConversation(conversation)
        await assertSuppressed(true, controller: h.controller, payload: current)
        h.controller.setOpenConversation(UUID())
        await assertSuppressed(false, controller: h.controller, payload: current)
    }

    func testGatewayAndDeviceProviderPinsBeforeSupplyingNewPairingCredential() async throws {
        let h = try await Harness.make()
        let generation = await h.vault.currentGeneration()
        let provider = ToasttyPushCredentialProvider(vault: h.vault, gatewayURL: h.credential.gatewayURL,
            pairingID: h.credential.device.id, generation: generation)
        let replacement = try Harness.credential(gateway: URL(string: "https://other-mac.example.ts.net")!, id: UUID())
        _ = try await h.vault.install(replacement)
        do { _ = try await provider.credential(); XCTFail("Expected stale pairing rejection") }
        catch let failure as NativeGatewayFailure {
            XCTAssertEqual(failure, .unauthenticated(operation: .pushRegistration, reason: .credentialInvalid))
        }
    }

    func testLockedStateAndRelayMismatchCannotMintOrSendAnAttempt() async throws {
        let h = try await Harness.make()
        h.store.loadFailure = .locked
        let locked = h.makeController()
        locked.updateConnection(gatewayURL: h.credential.gatewayURL, pairingID: h.credential.device.id,
            connected: true, supported: true)
        await locked.reconcile()
        XCTAssertNil(locked.storedState)
        await assertBeginCount(0, h.relay)
        XCTAssertNotNil(locked.errorMessage)
        h.store.loadFailure = nil
        await h.native.setMismatch()
        await h.controller.setDesired(true)
        h.controller.receivedToken(Harness.token)
        await h.controller.reconcile()
        XCTAssertFalse(h.controller.configurationMatches)
        await assertBeginCount(0, h.relay)
    }

    func testNewInstallationQueuesLeftoverKeychainRegistrationBeforeResettingIntent() async throws {
        let h = try await Harness.make(desired: true)
        h.controller.receivedToken(Harness.token)
        await h.controller.reconcile()
        h.marker.installationID = nil
        let reinstalled = h.makeController()
        await reinstalled.restore()
        XCTAssertFalse(reinstalled.desired)
        XCTAssertNil(reinstalled.storedState?.pending)
        XCTAssertEqual(reinstalled.storedState?.cleanup.count, 1)
        XCTAssertFalse(reinstalled.storedState?.introHandled ?? true)
    }

    func testLockedStateResumesAfterUnlockWithoutReplacingTheSavedAttempt() async throws {
        let h = try await Harness.make(desired: true)
        h.controller.receivedToken(Harness.token)
        await h.controller.reconcile()
        let savedID = h.controller.storedState?.pending?.registrationID
        h.store.loadFailure = .locked
        let restored = h.makeController()
        await restored.restore()
        XCTAssertFalse(restored.stateIsLoaded)
        h.store.loadFailure = nil
        restored.updateConnection(gatewayURL: h.credential.gatewayURL, pairingID: h.credential.device.id, connected: true, supported: true)
        restored.receivedToken(Harness.token)
        await restored.reconcile()
        XCTAssertEqual(restored.storedState?.pending?.registrationID, savedID)
        await assertBeginCount(1, h.relay)
    }

    func testEarlyAndTappedVerificationProofsAreBufferedThroughBridgeAndRestore() async throws {
        let h = try await Harness.make(desired: true)
        h.controller.receivedToken(Harness.token)
        await h.controller.reconcile()
        let pending = try XCTUnwrap(h.controller.storedState?.pending)
        let bridge = ToasttyPushNotificationBridge()
        let suppressed = await bridge.receivedForeground(Harness.proof(pending))
        XCTAssertTrue(suppressed)
        let restored = h.makeController()
        restored.attachBridge(bridge)
        bridge.receivedTap(Harness.proof(pending))
        for _ in 0..<10 { await Task.yield() }
        await restored.restore()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNotNil(restored.storedState?.pending?.nonce)
        restored.updateConnection(gatewayURL: h.credential.gatewayURL, pairingID: h.credential.device.id, connected: true, supported: true)
        restored.receivedToken(Harness.token)
        await restored.reconcile()
        XCTAssertEqual(restored.presentation, .enabled)
        XCTAssertNil(restored.pendingConversationID)
        await assertCompleteCount(1, h.relay)
    }

    func testDuplicateProofsCompleteOnlyOnceAndCannotRegressRelayActiveStage() async throws {
        let h = try await Harness.make(desired: true)
        h.controller.receivedToken(Harness.token)
        await h.controller.reconcile()
        let pending = try XCTUnwrap(h.controller.storedState?.pending)
        async let first = h.controller.receiveForeground(Harness.proof(pending))
        async let duplicate = h.controller.receiveForeground(Harness.proof(pending))
        _ = await (first, duplicate)
        _ = await h.controller.receiveForeground(Harness.proof(pending))
        await assertCompleteCount(1, h.relay)
        XCTAssertEqual(h.controller.storedState?.pending?.stage, .relayActive)
        XCTAssertNil(h.controller.storedState?.pending?.nonce)
    }

    func testExpiryAndLostBeginRenewOnlyWithFreshIDsAndKeys() async throws {
        let h = try await Harness.make(desired: true)
        await h.relay.failBeginOnce(.network)
        h.controller.receivedToken(Harness.token)
        await h.controller.reconcile()
        let first = try XCTUnwrap(h.controller.storedState?.pending)
        await h.controller.reconcile()
        XCTAssertEqual(h.controller.storedState?.pending?.registrationID, first.registrationID)
        await assertBeginCount(2, h.relay)
        h.clock.advance(301)
        await h.controller.reconcile()
        let renewed = try XCTUnwrap(h.controller.storedState?.pending)
        XCTAssertNotEqual(renewed.registrationID, first.registrationID)
        XCTAssertNotEqual(renewed.managementToken, first.managementToken)
        XCTAssertNotEqual(renewed.sendToken, first.sendToken)
        await assertBeginCount(3, h.relay)
    }

    func testRateLimitReceivedWhileBackgroundedPersistsAndIsHonoredOnForeground() async throws {
        let h = try await Harness.make(desired: true)
        await h.relay.pauseBegin()
        await h.relay.failBeginOnce(.rateLimited(retryAfter: 120))
        h.controller.receivedToken(Harness.token)
        let beginning = Task { await h.controller.reconcile() }
        for _ in 0..<100 { if await h.relay.beginCount > 0 { break }; await Task.yield() }
        h.controller.enteredBackground()
        await h.relay.finishBegin()
        await beginning.value
        XCTAssertNotNil(try h.store.load()?.retryAfter)
        h.controller.enteredForeground()
        await h.controller.reconcile()
        await assertBeginCount(1, h.relay)
        h.clock.advance(121)
        await h.controller.reconcile()
        await assertBeginCount(2, h.relay)
    }

    func testInvalidAPNsTokenBlockSurvivesRestartUntilTokenOrBuildChanges() async throws {
        let h = try await Harness.make(desired: true)
        await h.relay.failBeginOnce(.invalidDeviceToken)
        h.controller.receivedToken(Harness.token)
        await h.controller.reconcile()
        let first = try XCTUnwrap(h.controller.storedState?.pending)
        let restored = h.makeController()
        restored.updateConnection(gatewayURL: h.credential.gatewayURL, pairingID: h.credential.device.id, connected: true, supported: true)
        restored.receivedToken(Harness.token)
        await restored.reconcile()
        await assertBeginCount(1, h.relay)
        XCTAssertNotNil(restored.errorMessage)
        let upgraded = h.makeController(buildID: "next-build")
        upgraded.updateConnection(gatewayURL: h.credential.gatewayURL, pairingID: h.credential.device.id, connected: true, supported: true)
        upgraded.receivedToken(Harness.token)
        await upgraded.reconcile()
        XCTAssertNotEqual(upgraded.storedState?.pending?.registrationID, first.registrationID)
        await assertBeginCount(2, h.relay)
    }

    func testDeviceClockSkewDoesNotAbandonAChallengeBeforeItsLocalWindow() async throws {
        let h = try await Harness.make(desired: true)
        h.clock.advance(3600)
        h.controller.receivedToken(Harness.token)
        await h.controller.reconcile()
        let first = try XCTUnwrap(h.controller.storedState?.pending)
        await h.controller.reconcile()
        XCTAssertEqual(h.controller.storedState?.pending?.registrationID, first.registrationID)
        await assertBeginCount(1, h.relay)
        _ = await h.controller.receiveForeground(Harness.proof(first))
        await h.controller.reconcile()
        XCTAssertEqual(h.controller.presentation, .enabled)
    }

    func testUnpairDoesNotDeletePairingWhenDurableCleanupCannotBeSaved() async throws {
        let h = try await Harness.make(desired: true)
        h.controller.receivedToken(Harness.token)
        await h.controller.reconcile()
        h.store.saveFailure = .unavailable
        let session = AppSessionController(runtimeMode: .fixture, usesFixtureHarness: true,
            credentialVault: h.vault, pairingClient: TestAppPairingClient(), scanner: TestAppPairingScanner(),
            deviceName: { "Test iPhone" }, initialState: .paired(.live),
            initialPairedDevice: PairedDevicePresentation(credential: h.credential),
            initialSnapshot: ToasttyMobileFixture.home, initialConnectionState: .live, pushController: h.controller)
        let result = await session.unpair(revoke: {})
        XCTAssertFalse(result)
        let credential = await h.vault.currentCredential()
        XCTAssertEqual(credential, h.credential)
        XCTAssertTrue(session.state.isPaired)
        XCTAssertNotNil(h.controller.errorMessage)
    }

    private func assertBeginCount(_ expected: Int, _ relay: PushRelaySpy) async {
        let value = await relay.beginCount
        XCTAssertEqual(value, expected)
    }
    private func assertCompleteCount(_ expected: Int, _ relay: PushRelaySpy) async {
        let value = await relay.completeCount
        XCTAssertEqual(value, expected)
    }
    private func assertSuppressed(_ expected: Bool, controller: ToasttyPushController, payload: RemotePushPayload) async {
        let value = await controller.receiveForeground(payload)
        XCTAssertEqual(value, expected)
    }

    @MainActor
    private struct Harness {
        let controller: ToasttyPushController
        let credential: StoredMobileCredential
        let vault: TestAppCredentialVault
        let store: PushMemoryStore
        let marker: PushInstallationSpy
        let notifications: PushNotificationsSpy
        let relay: PushRelaySpy
        let native: PushNativeSpy
        let clock: PushClock
        static let token = String(repeating: "ab", count: 32)
        static let config = ToasttyPushConfiguration(relayURL: URL(string: "https://push.example.com")!,
            relayID: "toastty-push-dev-v1", apnsEnvironment: .development)

        static func make(desired: Bool = false) async throws -> Harness {
            let credential = try credential()
            let vault = TestAppCredentialVault(initialCredential: credential)
            _ = await vault.restore()
            let state = MobilePushState()
            let marker = PushInstallationSpy(state.installationID)
            let store = PushMemoryStore(state)
            let notifications = PushNotificationsSpy()
            let relay = PushRelaySpy()
            let native = PushNativeSpy()
            let clock = PushClock()
            let controller = ToasttyPushController(configuration: config, vault: vault, store: store,
                notifications: notifications, installation: marker, relayFactory: { _ in relay },
                nativeFactory: { _, provider in PushNativeClientSpy(spy: native, provider: provider) },
                now: { clock.date() }, buildID: "test-build", automaticallyReconciles: false)
            await controller.restore()
            controller.updateConnection(gatewayURL: credential.gatewayURL, pairingID: credential.device.id,
                connected: true, supported: true)
            if desired { await controller.setDesired(true) }
            return Harness(controller: controller, credential: credential, vault: vault, store: store,
                marker: marker, notifications: notifications, relay: relay, native: native, clock: clock)
        }
        func makeController(buildID: String = "test-build") -> ToasttyPushController {
            ToasttyPushController(configuration: Self.config, vault: vault, store: store,
                notifications: notifications, installation: marker, relayFactory: { _ in relay },
                nativeFactory: { _, provider in PushNativeClientSpy(spy: native, provider: provider) },
                now: { clock.date() }, buildID: buildID, automaticallyReconciles: false)
        }
        static func credential(gateway: URL = URL(string: "https://mac.example.ts.net")!, id: UUID = UUID()) throws -> StoredMobileCredential {
            try StoredMobileCredential(gatewayURL: gateway,
                device: RemoteGatewayDeviceSummary(id: id, name: "Test iPhone", scopes: [.read]),
                credentialCreatedAt: Date(), bearerToken: String(repeating: "A", count: 43))
        }
        static func proof(_ registration: MobilePushRegistration) -> RemotePushPayload {
            RemotePushPayload(kind: .verification, registrationID: registration.registrationID,
                pairingID: registration.pairingID, nonce: String(repeating: "A", count: 43))
        }
    }
}

private final class PushMemoryStore: MobilePushStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state: MobilePushState?
    var loadFailure: MobilePushStoreFailure?
    var saveFailure: MobilePushStoreFailure?
    init(_ state: MobilePushState?) { self.state = state }
    func load() throws -> MobilePushState? {
        try lock.withLock { if let loadFailure { throw loadFailure }; return state }
    }
    func save(_ state: MobilePushState) throws {
        try lock.withLock { if let saveFailure { throw saveFailure }; self.state = state }
    }
}

@MainActor
private final class PushInstallationSpy: ToasttyPushInstallationIdentifying {
    var installationID: UUID?
    init(_ id: UUID?) { installationID = id }
}

@MainActor
private final class PushNotificationsSpy: ToasttyPushNotificationClient {
    var grantsPermission = true
    var currentPermission: ToasttyNotificationPermission = .undetermined
    var permissionRequests = 0
    var registrationRequests = 0
    var delivered: [RemotePushPayload] = []
    func permission() async -> ToasttyNotificationPermission { currentPermission }
    func requestPermission() async throws -> Bool {
        permissionRequests += 1
        currentPermission = grantsPermission ? .allowed : .denied
        return grantsPermission
    }
    func register() { registrationRequests += 1 }
    func deliveredPayloads() async -> [RemotePushPayload] { delivered }
    func removeVerificationNotifications(registrationIDs: Set<UUID>) async {
        delivered.removeAll { $0.kind == .verification && registrationIDs.contains($0.registrationID) }
    }
}

private actor PushRelaySpy: PushRelayClientProtocol {
    private(set) var beginCount = 0
    private(set) var completeCount = 0
    private var completionFailures = 0
    private var revokeFailure = false
    private var paused = false
    private var beginFailure: PushRelayFailure?
    private var beginContinuation: CheckedContinuation<Void, Never>?
    func pauseBegin() { paused = true }
    func finishBegin() { paused = false; beginContinuation?.resume(); beginContinuation = nil }
    func failCompletionOnce() { completionFailures = 1 }
    func failBeginOnce(_ error: PushRelayFailure) { beginFailure = error }
    func setRevokeFailure(_ value: Bool) { revokeFailure = value }
    func begin(_ registration: MobilePushRegistration) async throws -> PushRelayBeginResponse {
        beginCount += 1
        if paused { await withCheckedContinuation { beginContinuation = $0 } }
        if let failure = beginFailure { beginFailure = nil; throw failure }
        return PushRelayBeginResponse(registrationID: registration.registrationID, state: "pending",
            expiresAt: Date().addingTimeInterval(300).timeIntervalSince1970)
    }
    func complete(_ registration: MobilePushRegistration, nonce: String) async throws -> PushRelayStatus {
        completeCount += 1
        if completionFailures > 0 { completionFailures -= 1; throw PushRelayFailure.network }
        return PushRelayStatus(registrationID: registration.registrationID, pairingID: registration.pairingID, state: "active")
    }
    func status(_ registration: MobilePushRegistration) async throws -> PushRelayStatus {
        PushRelayStatus(registrationID: registration.registrationID, pairingID: registration.pairingID, state: "active")
    }
    func revoke(_ registration: MobilePushRegistration) async throws {
        if revokeFailure { throw PushRelayFailure.network }
    }
}

private final class PushClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func date() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

private actor PushNativeSpy {
    private(set) var grants: [RemoteGatewayPushRegistration?] = []
    private var handoffFailures = 0
    private var mismatch = false
    private var registrationID: UUID?
    func failHandoffOnce() { handoffFailures = 1 }
    func setMismatch() { mismatch = true }
    func configuration() -> RemoteGatewayPushConfigurationResponse {
        RemoteGatewayPushConfigurationResponse(relayID: mismatch ? "other-relay" : "toastty-push-dev-v1",
            apnsEnvironment: .development, registrationID: registrationID)
    }
    func setRegistration(_ grant: RemoteGatewayPushRegistration?) throws -> RemoteGatewayPushRegistrationResponse {
        if handoffFailures > 0 { handoffFailures -= 1; throw PushRelayFailure.network }
        grants.append(grant); registrationID = grant?.registrationID
        return RemoteGatewayPushRegistrationResponse(registrationID: grant?.registrationID)
    }
}

private struct PushNativeClientSpy: NativePushClientProtocol {
    let spy: PushNativeSpy
    let provider: any GatewayCredentialProvider
    func configuration() async throws -> RemoteGatewayPushConfigurationResponse {
        _ = try await provider.credential()
        return await spy.configuration()
    }
    func setRegistration(_ registration: RemoteGatewayPushRegistration?) async throws -> RemoteGatewayPushRegistrationResponse {
        _ = try await provider.credential()
        return try await spy.setRegistration(registration)
    }
}
