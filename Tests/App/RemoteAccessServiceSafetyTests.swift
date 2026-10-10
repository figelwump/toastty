import AppKit
import CoreState
import Foundation
import Network
import RemoteProtocol
import Testing
@testable import ToasttyApp

@Suite(.serialized)
struct RemoteAccessTailnetSetupLifecycleTests {
    @MainActor
    @Test func portConflictExplainsRecoveryAndNeverRunsServe() async throws {
        for synchronousFailure in [false, true] {
            let fixture = try RemoteAccessTailnetSetupFixture()
            defer { fixture.cleanup() }
            if synchronousFailure { fixture.server.startError = .posix(.EADDRINUSE) }
            fixture.service.setEnabledFromSettings(true, persist: false)
            if !synchronousFailure { fixture.server.reportFailure(.portInUse) }
            await Task.yield()
            let message = try #require(fixture.service.startupError)
            #expect(message.contains("42990"))
            #expect(message.contains("already in use"))
            #expect(message.contains("another Toastty"))
            #expect(await fixture.setup.calls.isEmpty)
            #expect(!fixture.service.canIssueNativePairingOffer)
            #expect(!fixture.service.isEnabled)

            fixture.server.startError = nil
            fixture.service.setEnabledFromSettings(true, persist: false)
            fixture.server.reportReady(port: 42_990)
            _ = try await fixture.setup.waitForCalls(1)
            await fixture.setup.finishCall(0, with: .success("https://retry.example.ts.net"))
            try await fixture.waitForState(.configured)
        }
    }

    @MainActor
    @Test func ordinaryEnableKeepsItsListenerOnlyBehavior() async throws {
        let fixture = try RemoteAccessTailnetSetupFixture(origin: "https://manual.example.ts.net")
        defer { fixture.cleanup() }
        fixture.service.setEnabled(true, persist: false)
        fixture.server.reportReady(port: 42_990)
        await Task.yield()
        #expect(await fixture.setup.calls.isEmpty)
        #expect(fixture.service.tailnetSetupState == .unchecked)
        #expect(fixture.service.canIssueNativePairingOffer)
    }

    @MainActor
    @Test func explicitEnablePreparesSetupBeforeSynchronousListenerReadiness() async throws {
        let fixture = try RemoteAccessTailnetSetupFixture()
        defer { fixture.cleanup() }
        fixture.server.readyPortOnStart = 42_992
        fixture.service.setEnabledFromSettings(true, persist: false)
        let calls = try await fixture.setup.waitForCalls(1)
        #expect(calls == [.init(port: 42_992, configuredOrigin: "", configureIfNeeded: true)])
        await fixture.setup.finishCall(0, with: .success("https://sync.example.ts.net"))
        try await fixture.waitForState(.configured)
    }

    @MainActor
    @Test func restoredAccessDoesNotConfigureTailscaleAndSettingsVerificationIsReadOnly() async throws {
        let fixture = try RemoteAccessTailnetSetupFixture(initiallyEnabled: true)
        defer { fixture.cleanup() }
        #expect(fixture.service.activationState == .starting)
        fixture.server.reportReady(port: 42_990)
        await Task.yield()
        #expect(await fixture.setup.calls.isEmpty)
        #expect(fixture.service.tailnetSetupState == .unchecked)

        fixture.service.verifyTailnetSetupIfNeeded()
        fixture.service.verifyTailnetSetupIfNeeded()
        let calls = try await fixture.setup.waitForCalls(1)
        #expect(calls == [.init(port: 42_990, configuredOrigin: "", configureIfNeeded: false)])
        await fixture.setup.finishCall(0, with: .success("https://restored.example.ts.net"))
        try await fixture.waitForState(.configured)
        #expect(fixture.service.tailnetOrigin == "https://restored.example.ts.net")
        #expect(fixture.service.canIssueNativePairingOffer)
        fixture.service.verifyTailnetSetupIfNeeded()
        await Task.yield()
        #expect(await fixture.setup.calls.count == 1)
    }

    @MainActor
    @Test func explicitEnableWaitsForListenerAndUsesItsReportedPort() async throws {
        let fixture = try RemoteAccessTailnetSetupFixture()
        defer { fixture.cleanup() }
        fixture.service.setEnabledFromSettings(true, persist: false)
        #expect(fixture.service.tailnetSetupState == .waitingForListener)
        #expect(fixture.service.activationState == .starting)
        await Task.yield()
        #expect(await fixture.setup.calls.isEmpty)
        #expect(fixture.service.canIssueNativePairingOffer == false)

        fixture.server.reportReady(port: 42_991)
        fixture.service.verifyTailnetSetupIfNeeded()
        let calls = try await fixture.setup.waitForCalls(1)
        #expect(calls == [.init(port: 42_991, configuredOrigin: "", configureIfNeeded: true)])
        #expect(fixture.service.tailnetSetupState == .configuring)
        await fixture.setup.finishCall(0, with: .success("https://setup.example.ts.net"))
        try await fixture.waitForState(.configured)
        #expect(fixture.service.activationState == .ready(port: 42_991))
        #expect(fixture.service.tailnetOrigin == "https://setup.example.ts.net")
        fixture.service.issueNativePairingOffer()
        #expect(fixture.service.currentNativePairingOffer?.qrPayload.gatewayURL.absoluteString == "https://setup.example.ts.net")
    }

    @MainActor
    @Test func verificationPreservesTheUserEnteredOrigin() async throws {
        let origin = "https://MANUAL.example.ts.net/"
        let fixture = try RemoteAccessTailnetSetupFixture(initiallyEnabled: true, origin: origin)
        defer { fixture.cleanup() }
        fixture.server.reportReady(port: 42_990)
        fixture.service.verifyTailnetSetupIfNeeded()
        let calls = try await fixture.setup.waitForCalls(1)
        #expect(calls == [.init(port: 42_990, configuredOrigin: origin, configureIfNeeded: false)])
        await fixture.setup.finishCall(0, with: .success("https://manual.example.ts.net"))
        try await fixture.waitForState(.configured)
        #expect(fixture.service.tailnetOrigin == origin)
        #expect(fixture.service.canIssueNativePairingOffer)
    }

    @MainActor
    @Test func disableAndListenerFailureRejectLateSetupCompletion() async throws {
        for listenerFails in [false, true] {
            let fixture = try RemoteAccessTailnetSetupFixture()
            defer { fixture.cleanup() }
            fixture.service.setEnabledFromSettings(true, persist: false)
            fixture.server.reportReady(port: 42_990)
            _ = try await fixture.setup.waitForCalls(1)
            if listenerFails {
                fixture.server.reportFailure()
            } else {
                fixture.service.setEnabled(false, persist: false)
            }
            await fixture.setup.finishCall(0, with: .success("https://late.example.ts.net"))
            try await fixture.waitForState(.unchecked)
            await Task.yield()
            #expect(fixture.service.tailnetOrigin.isEmpty)
            #expect(fixture.service.isReady == false)
            #expect(fixture.service.canIssueNativePairingOffer == false)
            #expect(fixture.service.currentNativePairingOffer == nil)
        }
    }

    @MainActor
    @Test func originEditRejectsLateSetupCompletionAndPreservesManualPairing() async throws {
        let fixture = try RemoteAccessTailnetSetupFixture()
        defer { fixture.cleanup() }
        fixture.service.setEnabledFromSettings(true, persist: false)
        fixture.server.reportReady(port: 42_990)
        _ = try await fixture.setup.waitForCalls(1)
        fixture.service.tailnetOrigin = "https://manual.example.ts.net"
        await fixture.setup.finishCall(0, with: .success("https://late.example.ts.net"))
        try await fixture.waitForState(.unchecked)
        await Task.yield()
        #expect(fixture.service.tailnetOrigin == "https://manual.example.ts.net")
        #expect(fixture.service.canIssueNativePairingOffer)
        fixture.service.issueNativePairingOffer()
        #expect(fixture.service.currentNativePairingOffer?.qrPayload.gatewayURL.absoluteString == "https://manual.example.ts.net")
    }

    @MainActor
    @Test func retryWaitsForCancelledAttemptAndRejectsItsLateFailure() async throws {
        let fixture = try RemoteAccessTailnetSetupFixture()
        defer { fixture.cleanup() }
        fixture.service.setEnabledFromSettings(true, persist: false)
        fixture.server.reportReady(port: 42_990)
        _ = try await fixture.setup.waitForCalls(1)
        fixture.service.setUpTailnetAccess()
        fixture.service.verifyTailnetSetupIfNeeded()
        await Task.yield()
        #expect(await fixture.setup.calls.count == 1)
        #expect(fixture.service.canIssueNativePairingOffer == false)

        // The fixture deliberately ignores cancellation until it is released.
        await fixture.setup.finishCall(0, with: .failure(.funnelEnabled))
        _ = try await fixture.setup.waitForCalls(2)
        #expect(fixture.service.tailnetSetupState == .configuring)
        #expect(await fixture.setup.maximumActiveCallCount == 1)
        await fixture.setup.finishCall(1, with: .success("https://retry.example.ts.net"))
        try await fixture.waitForState(.configured)
        #expect(fixture.service.tailnetOrigin == "https://retry.example.ts.net")
    }

    @MainActor
    @Test func explicitSetupReplacesReadOnlyVerificationWithoutOverlappingCalls() async throws {
        let fixture = try RemoteAccessTailnetSetupFixture(initiallyEnabled: true)
        defer { fixture.cleanup() }
        fixture.server.reportReady(port: 42_990)
        fixture.service.verifyTailnetSetupIfNeeded()
        _ = try await fixture.setup.waitForCalls(1)
        fixture.service.setUpTailnetAccess()
        await fixture.setup.finishCall(0, with: .failure(.notConfigured))
        let calls = try await fixture.setup.waitForCalls(2)
        #expect(calls.map(\.configureIfNeeded) == [false, true])
        #expect(await fixture.setup.maximumActiveCallCount == 1)
        await fixture.setup.finishCall(1, with: .success("https://retry.example.ts.net"))
        try await fixture.waitForState(.configured)
    }

    @MainActor
    @Test func setupFailuresGatePairingWithoutStoppingExistingClients() async throws {
        for error: TailscaleServeSetupError in [.notConfigured, .originMismatch, .portInUse(443), .funnelEnabled, .statusUnavailable] {
            let fixture = try RemoteAccessTailnetSetupFixture(origin: "https://manual.example.ts.net")
            defer { fixture.cleanup() }
            fixture.service.setEnabledFromSettings(true, persist: false)
            fixture.server.reportReady(port: 42_990)
            fixture.server.reportWebSocketCounts(total: 1, native: 1)
            _ = try await fixture.setup.waitForCalls(1)
            fixture.service.issueNativePairingOffer()
            #expect(fixture.service.currentNativePairingOffer == nil)
            await fixture.setup.finishCall(0, with: .failure(error))
            try await fixture.waitForState(.failed(error))
            #expect(fixture.service.activationState == .ready(port: 42_990))
            #expect(fixture.service.connectedNativeClientCount == 1)
            #expect(fixture.server.stopCallCount == 0)
            #expect(fixture.service.canIssueNativePairingOffer == (error == .statusUnavailable))
            fixture.service.issueNativePairingOffer()
            #expect((fixture.service.currentNativePairingOffer != nil) == (error == .statusUnavailable))
        }
    }

    @MainActor
    @Test func approvalLinkSurvivesRepeatedSettingsVerification() async throws {
        let fixture = try RemoteAccessTailnetSetupFixture()
        defer { fixture.cleanup() }
        let approvalURL = try #require(URL(string: "https://login.tailscale.com/admin/serve"))
        let error = TailscaleServeSetupError.approvalRequired(approvalURL)
        fixture.service.setEnabledFromSettings(true, persist: false)
        fixture.server.reportReady(port: 42_990)
        _ = try await fixture.setup.waitForCalls(1)
        await fixture.setup.finishCall(0, with: .failure(error))
        try await fixture.waitForState(.failed(error))

        fixture.service.verifyTailnetSetupIfNeeded()
        fixture.service.verifyTailnetSetupIfNeeded()
        await Task.yield()
        #expect(await fixture.setup.calls.count == 1)
        #expect(fixture.service.tailnetSetupState == .failed(error))
        #expect(fixture.service.tailnetSetupState.approvalURL == approvalURL)
        #expect(fixture.service.canIssueNativePairingOffer == false)
    }

    @MainActor
    @Test func originEditPreservesFunnelBlockUntilExplicitSetupSucceeds() async throws {
        let fixture = try RemoteAccessTailnetSetupFixture(origin: "https://manual.example.ts.net")
        defer { fixture.cleanup() }
        fixture.service.setEnabledFromSettings(true, persist: false)
        fixture.server.reportReady(port: 42_990)
        _ = try await fixture.setup.waitForCalls(1)
        await fixture.setup.finishCall(0, with: .failure(.funnelEnabled))
        try await fixture.waitForState(.failed(.funnelEnabled))

        fixture.service.tailnetOrigin = "https://updated.example.ts.net"
        fixture.service.verifyTailnetSetupIfNeeded()
        fixture.service.issueNativePairingOffer()
        await Task.yield()
        #expect(await fixture.setup.calls.count == 1)
        #expect(fixture.service.tailnetSetupState == .failed(.funnelEnabled))
        #expect(fixture.service.canIssueNativePairingOffer == false)
        #expect(fixture.service.currentNativePairingOffer == nil)

        fixture.service.setUpTailnetAccess()
        let calls = try await fixture.setup.waitForCalls(2)
        #expect(calls.last == .init(port: 42_990, configuredOrigin: "https://updated.example.ts.net", configureIfNeeded: true))
        await fixture.setup.finishCall(1, with: .success("https://updated.example.ts.net"))
        try await fixture.waitForState(.configured)
        #expect(fixture.service.canIssueNativePairingOffer)
    }

    @MainActor
    @Test func manualPairingOfferSurvivesRepeatedSettingsVerificationAfterUnknownFailure() async throws {
        let fixture = try RemoteAccessTailnetSetupFixture(initiallyEnabled: true, origin: "https://manual.example.ts.net")
        defer { fixture.cleanup() }
        fixture.server.reportReady(port: 42_990)
        fixture.service.verifyTailnetSetupIfNeeded()
        _ = try await fixture.setup.waitForCalls(1)
        await fixture.setup.finishCall(0, with: .failure(.statusUnavailable))
        try await fixture.waitForState(.failed(.statusUnavailable))
        fixture.service.issueNativePairingOffer()
        let offer = try #require(fixture.service.currentNativePairingOffer)

        fixture.service.verifyTailnetSetupIfNeeded()
        fixture.service.verifyTailnetSetupIfNeeded()
        await Task.yield()
        #expect(await fixture.setup.calls.count == 1)
        #expect(fixture.service.tailnetSetupState == .failed(.statusUnavailable))
        #expect(fixture.service.currentNativePairingOffer?.id == offer.id)
        #expect(fixture.service.canIssueNativePairingOffer)
    }

    @MainActor
    @Test func selectedCustomOriginPersistsThroughEnableAndReadOnlyRestart() async throws {
        let fixture = try RemoteAccessTailnetSetupFixture()
        defer { fixture.cleanup() }
        let chosenOrigin = "https://custom.example.ts.net:8443"
        fixture.service.setEnabledFromSettings(true, persist: false)
        fixture.server.reportReady(port: 42_990)
        _ = try await fixture.setup.waitForCalls(1)
        await fixture.setup.finishCall(0, with: .success(chosenOrigin))
        try await fixture.waitForState(.configured)
        #expect(fixture.service.tailnetOrigin == chosenOrigin)
        fixture.service.issueNativePairingOffer()
        #expect(fixture.service.currentNativePairingOffer?.qrPayload.gatewayURL.absoluteString == chosenOrigin)

        fixture.service.setEnabled(false, persist: false)
        fixture.service.setEnabled(true, persist: false)
        fixture.server.reportReady(port: 42_990)
        fixture.service.verifyTailnetSetupIfNeeded()
        let calls = try await fixture.setup.waitForCalls(2)
        #expect(calls.last == .init(port: 42_990, configuredOrigin: chosenOrigin, configureIfNeeded: false))
        await fixture.setup.finishCall(1, with: .success(chosenOrigin))
        try await fixture.waitForState(.configured)
        fixture.service.setEnabled(false, persist: false)

        let restored = try fixture.makeRestoredService()
        defer { restored.service.setEnabled(false, persist: false) }
        #expect(restored.service.tailnetOrigin == chosenOrigin)
        fixture.server.reportReady(port: 42_990)
        await Task.yield()
        #expect(await fixture.setup.calls.count == 2)
        restored.service.verifyTailnetSetupIfNeeded()
        let restoredCalls = try await fixture.setup.waitForCalls(3)
        #expect(restoredCalls.last == .init(port: 42_990, configuredOrigin: chosenOrigin, configureIfNeeded: false))
        await fixture.setup.finishCall(2, with: .success(chosenOrigin))
        await SessionRuntimeStoreTestSupport.waitUntil { restored.service.tailnetSetupState == .configured }
        #expect(restored.service.tailnetSetupState == .configured)
        restored.service.issueNativePairingOffer()
        #expect(restored.service.currentNativePairingOffer?.qrPayload.gatewayURL.absoluteString == chosenOrigin)
    }

    @MainActor
    @Test func savedDefaultOriginIsNeverRewrittenByASetupResultOnAnotherPort() async throws {
        let fixture = try RemoteAccessTailnetSetupFixture(origin: "https://saved.example.ts.net")
        defer { fixture.cleanup() }
        fixture.service.setEnabledFromSettings(true, persist: false)
        fixture.server.reportReady(port: 42_990)
        let calls = try await fixture.setup.waitForCalls(1)
        #expect(calls.first?.configuredOrigin == "https://saved.example.ts.net")
        await fixture.setup.finishCall(0, with: .success("https://saved.example.ts.net:8443"))
        try await fixture.waitForState(.configured)
        #expect(fixture.service.tailnetOrigin == "https://saved.example.ts.net")
        fixture.service.issueNativePairingOffer()
        #expect(fixture.service.currentNativePairingOffer?.qrPayload.gatewayURL.absoluteString == "https://saved.example.ts.net")
    }

    @MainActor
    @Test func unpairedSavedPortConflictCanRecoverByClearingThenRetrying() async throws {
        let fixture = try RemoteAccessTailnetSetupFixture(origin: "https://saved.example.ts.net")
        defer { fixture.cleanup() }
        fixture.service.setEnabledFromSettings(true, persist: false)
        fixture.server.reportReady(port: 42_990)
        _ = try await fixture.setup.waitForCalls(1)
        await fixture.setup.finishCall(0, with: .failure(.portInUse(443)))
        try await fixture.waitForState(.failed(.portInUse(443)))
        #expect(fixture.statusPresentation.detail.contains("clear Tailnet origin"))
        #expect(fixture.statusPresentation.detail.contains("Do not use Detect"))
        #expect(fixture.service.tailnetOrigin == "https://saved.example.ts.net")

        fixture.service.tailnetOrigin = ""
        #expect(fixture.service.canIssueNativePairingOffer == false)
        #expect(await fixture.setup.calls.count == 1)
        fixture.service.setUpTailnetAccess()
        let calls = try await fixture.setup.waitForCalls(2)
        #expect(calls.last?.configuredOrigin == "")
        await fixture.setup.finishCall(1, with: .success("https://saved.example.ts.net:8443"))
        try await fixture.waitForState(.configured)
        #expect(fixture.service.tailnetOrigin == "https://saved.example.ts.net:8443")
        fixture.service.issueNativePairingOffer()
        #expect(fixture.service.currentNativePairingOffer?.qrPayload.gatewayURL.port == 8443)
    }

    @MainActor
    @Test func pairedDeviceAndCredentialSurviveSavedPortFailureDisableAndRetry() async throws {
        let fixture = try RemoteAccessTailnetSetupFixture(origin: "https://paired.example.ts.net", hasPairedDevice: true)
        defer { fixture.cleanup() }
        let deviceID = try #require(fixture.pairedDeviceID)
        #expect(fixture.service.devices.contains { $0.id == deviceID && !$0.isRevoked })
        #expect(try fixture.currentDeviceResponse(from: fixture.handler).device.id == deviceID)
        fixture.service.setEnabledFromSettings(true, persist: false)
        fixture.server.reportReady(port: 42_990)
        _ = try await fixture.setup.waitForCalls(1)
        await fixture.setup.finishCall(0, with: .failure(.portInUse(443)))
        try await fixture.waitForState(.failed(.portInUse(443)))
        #expect(fixture.statusPresentation.detail.contains("clear Tailnet origin") == false)
        #expect(fixture.statusPresentation.detail.contains("Restore the Toastty mapping"))
        #expect(try fixture.currentDeviceResponse(from: fixture.handler).device.id == deviceID)
        fixture.service.setEnabled(false, persist: false)
        #expect(fixture.service.devices.contains { $0.id == deviceID && !$0.isRevoked })

        fixture.service.setEnabledFromSettings(true, persist: false)
        fixture.server.reportReady(port: 42_990)
        let calls = try await fixture.setup.waitForCalls(2)
        #expect(calls.last?.configuredOrigin == "https://paired.example.ts.net")
        await fixture.setup.finishCall(1, with: .success("https://paired.example.ts.net"))
        try await fixture.waitForState(.configured)
        #expect(try fixture.currentDeviceResponse(from: fixture.handler).device.id == deviceID)
        fixture.service.setEnabled(false, persist: false)

        let restored = try fixture.makeRestoredService()
        defer { restored.service.setEnabled(false, persist: false) }
        #expect(restored.service.devices.contains { $0.id == deviceID && !$0.isRevoked })
        #expect(try fixture.currentDeviceResponse(from: restored.handler).device.id == deviceID)
    }

    @MainActor
    @Test func revokedDevicesPermitRecoveryButPendingBrowserPairingDoesNot() async throws {
        let fixture = try RemoteAccessTailnetSetupFixture(origin: "https://paired.example.ts.net", hasPairedDevice: true)
        defer { fixture.cleanup() }
        let deviceID = try #require(fixture.pairedDeviceID)
        fixture.service.revokeDevice(deviceID)
        fixture.service.setEnabledFromSettings(true, persist: false)
        fixture.server.reportReady(port: 42_990)
        _ = try await fixture.setup.waitForCalls(1)
        await fixture.setup.finishCall(0, with: .failure(.portInUse(443)))
        try await fixture.waitForState(.failed(.portInUse(443)))
        #expect(fixture.statusPresentation.detail.contains("clear Tailnet origin"))
        fixture.service.issuePairingCode()
        #expect(fixture.service.currentPairingCode != nil)
        #expect(fixture.statusPresentation.detail.contains("clear Tailnet origin") == false)
    }

    @MainActor
    @Test func handlerAcceptsOnlyTheCanonicalSavedHTTPSOriginIncludingItsPort() throws {
        let cases: [(String, String, [String])] = [
            ("HTTPS://CUSTOM.EXAMPLE.TS.NET:8443/", "https://custom.example.ts.net:8443", [
                "https://custom.example.ts.net", "https://custom.example.ts.net:8444", "https://another.example.ts.net:8443",
            ]),
            ("https://default.example.ts.net:443/", "https://default.example.ts.net", [
                "https://default.example.ts.net:8443", "https://another.example.ts.net",
            ]),
        ]
        for (savedOrigin, canonicalOrigin, rejectedOrigins) in cases {
            let fixture = try RemoteAccessTailnetSetupFixture(origin: savedOrigin)
            defer { fixture.cleanup() }
            #expect(try fixture.responseStatus(origin: canonicalOrigin) == 404)
            if canonicalOrigin == "https://default.example.ts.net" {
                #expect(try fixture.responseStatus(origin: "https://default.example.ts.net:443") == 404)
            }
            for origin in rejectedOrigins {
                #expect(try fixture.responseStatus(origin: origin) == 403)
            }
        }
    }
}

@MainActor
private final class RemoteAccessTailnetSetupFixture {
    let setup = RemoteAccessTailnetSetupSpy()
    let server = RemoteAccessGatewayServerSpy()
    let service: RemoteAccessService
    let handler: RemoteGatewayRequestHandler
    let pairedDeviceID: UUID?
    private let nativeCredential: String?
    private let originalOrigin: String
    private let runtimePaths: ToasttyRuntimePaths
    private let runtimeHome = "/tmp/toastty-tailnet-setup-lifecycle-\(UUID().uuidString)"

    init(initiallyEnabled: Bool = false, origin: String = "", hasPairedDevice: Bool = false) throws {
        runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/toastty-remote-access-test-home",
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome]
        )
        if hasPairedDevice {
            let deviceStore = RemoteDeviceStore(fileURL: runtimePaths.remoteAccessDevicesFileURL)
            let gatewayURL = try #require(RemoteAccessService.publicGatewayURL(from: origin))
            let offer = try deviceStore.issueNativePairingOffer(gatewayURL: gatewayURL, at: .now)
            guard case .paired(let device, let credential) = try deviceStore.redeemNativePairingOffer(
                using: .qr(offerID: offer.id, secret: offer.qrPayload.secret),
                deviceName: "Fixture phone", tailscaleLogin: "fixture@example.com", at: .now
            ) else { throw CocoaError(.coderValueNotFound) }
            pairedDeviceID = device.id
            nativeCredential = credential
        } else {
            pairedDeviceID = nil
            nativeCredential = nil
        }
        let components = try Self.makeService(
            runtimePaths: runtimePaths, setup: setup, server: server, initiallyEnabled: initiallyEnabled
        )
        service = components.0
        handler = components.1
        originalOrigin = service.tailnetOrigin
        service.tailnetOrigin = origin
    }

    private static func makeService(
        runtimePaths: ToasttyRuntimePaths,
        setup: RemoteAccessTailnetSetupSpy,
        server: RemoteAccessGatewayServerSpy,
        initiallyEnabled: Bool
    ) throws -> (RemoteAccessService, RemoteGatewayRequestHandler) {
        var capturedHandler: RemoteGatewayRequestHandler?
        let service = RemoteAccessService(
            store: AppStore(state: .bootstrap(), persistTerminalFontPreference: false),
            annotationStyleStore: AnnotationStyleStore(runtimePaths: runtimePaths),
            sessionRuntimeStore: SessionRuntimeStore(),
            terminalRuntimeRegistry: TerminalRuntimeRegistry(),
            runtimePaths: runtimePaths,
            port: 42_990,
            initiallyEnabled: initiallyEnabled,
            tailnetServeSetup: { port, configuredOrigin, configureIfNeeded in
                try await setup.run(port: port, configuredOrigin: configuredOrigin, configureIfNeeded: configureIfNeeded)
            },
            gatewayServerFactory: {
                capturedHandler = $0
                return server
            }
        )
        return (service, try #require(capturedHandler))
    }

    func makeRestoredService() throws -> (service: RemoteAccessService, handler: RemoteGatewayRequestHandler) {
        try Self.makeService(runtimePaths: runtimePaths, setup: setup, server: server, initiallyEnabled: true)
    }

    var statusPresentation: RemoteAccessConnectionStatusPresentation {
        .make(
            activationState: service.activationState,
            tailnetSetupState: service.tailnetSetupState,
            connectedNativeClientCount: service.connectedNativeClientCount,
            hasPairedNativeDevice: service.devices.contains { $0.authKind == .native && !$0.isRevoked },
            hasUnrevokedDevice: service.devices.contains { !$0.isRevoked },
            hasPendingPairing: service.currentPairingCode != nil || service.currentNativePairingOffer != nil
        )
    }

    func responseStatus(origin: String) throws -> Int {
        guard case .respond(let response) = handler.handle(
            .init(method: "GET", path: "/unknown-fixture-route", headers: ["origin": origin], body: Data()), at: .now
        ) else { throw CocoaError(.coderValueNotFound) }
        return response.status
    }

    func currentDeviceResponse(from handler: RemoteGatewayRequestHandler) throws -> RemoteGatewayCurrentDeviceResponse {
        let credential = try #require(nativeCredential)
        guard case .respond(let response) = handler.handle(.init(
            method: "GET", path: "/v1/native-device",
            headers: ["authorization": "Bearer \(credential)", "tailscale-user-login": "fixture@example.com"], body: Data()
        ), at: .now) else { throw CocoaError(.coderValueNotFound) }
        #expect(response.status == 200)
        return try ConversationEventCoding.makeDecoder().decode(RemoteGatewayCurrentDeviceResponse.self, from: response.body)
    }

    func waitForState(_ expected: RemoteAccessTailnetSetupState) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while service.tailnetSetupState != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(service.tailnetSetupState == expected)
    }

    func cleanup() {
        service.setEnabled(false, persist: false)
        service.tailnetOrigin = originalOrigin
        try? FileManager.default.removeItem(atPath: runtimeHome)
    }
}

private actor RemoteAccessTailnetSetupSpy {
    struct Call: Equatable, Sendable {
        let port: UInt16
        let configuredOrigin: String
        let configureIfNeeded: Bool
    }
    private(set) var calls: [Call] = []
    private(set) var maximumActiveCallCount = 0
    private var completions: [Int: CheckedContinuation<String, any Error>] = [:]

    func run(port: UInt16, configuredOrigin: String, configureIfNeeded: Bool) async throws -> String {
        let index = calls.count
        calls.append(.init(port: port, configuredOrigin: configuredOrigin, configureIfNeeded: configureIfNeeded))
        return try await withCheckedThrowingContinuation { completion in
            completions[index] = completion
            maximumActiveCallCount = max(maximumActiveCallCount, completions.count)
        }
    }

    func waitForCalls(_ count: Int) async throws -> [Call] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while calls.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(calls.count == count)
        guard calls.count == count else { throw CocoaError(.coderValueNotFound) }
        return calls
    }

    func finishCall(_ index: Int, with result: Result<String, TailscaleServeSetupError>) {
        guard let completion = completions.removeValue(forKey: index) else {
            Issue.record("Expected a pending Tailscale setup call")
            return
        }
        completion.resume(with: result.mapError { $0 as any Error })
    }
}

struct RemoteAccessServiceSafetyTests {
    @MainActor
    @Test func acceptedSessionEventSendsDurableConversationAndCurrentTitle() async throws {
        let relay = RemotePushRelaySpy()
        let configuration = RemotePushConfiguration(relayURL: URL(string: "https://push.example.com")!)!
        let fixture = try RemoteBootstrapFixture(pairNativeDevice: true, pushConfiguration: configuration, pushRelay: relay)
        defer { fixture.removeRuntimeFiles() }
        let registration = RemoteGatewayPushRegistration(registrationID: UUID(), sendToken: Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""), relayID: configuration.relayID)
        try fixture.setPushRegistration(registration)
        let title = fixture.summary.title
        fixture.sessionRuntimeStore.updateStatus(sessionID: fixture.sessionID, status: .init(kind: .working, summary: "Working"), at: fixture.confirmedAt.addingTimeInterval(1))
        fixture.sessionRuntimeStore.updateStatus(sessionID: fixture.sessionID, status: .init(kind: .ready, summary: "Ready", detail: "Private details"), at: fixture.confirmedAt.addingTimeInterval(2))
        await SessionRuntimeStoreTestSupport.waitUntil { relay.notifications.count == 1 }
        let sent = try #require(relay.notifications.first)
        #expect(sent.conversationID == fixture.conversationID)
        #expect(sent.sessionTitle == title)
        #expect(sent.status == .ready)
        #expect(relay.registrations.first?.registrationID == registration.registrationID)

        let event = ManagedSessionActionableEvent(eventID: UUID(), kind: .needsApproval, timestamp: .now, sessionID: "stale-session", agent: .codex, workspaceID: fixture.summary.placement.workspaceID!, panelID: fixture.panelID)
        fixture.sessionRuntimeStore.onActionableEvent?(event)
        fixture.service.setEnabled(false, persist: false)
        fixture.sessionRuntimeStore.onActionableEvent?(.init(eventID: UUID(), kind: .needsApproval, timestamp: .now, sessionID: fixture.sessionID, agent: .codex, workspaceID: event.workspaceID, panelID: fixture.panelID))
        await Task.yield()
        #expect(relay.notifications.count == 1)
    }

    @MainActor
    @Test func temporaryRelayFailureKeepsGrantButDeadGrantClearsDurablyAndRetainsCleanup() async throws {
        let relay = RemotePushRelaySpy()
        relay.sendOutcome = .dropped
        let configuration = RemotePushConfiguration(relayURL: URL(string: "https://push.example.com")!)!
        let fixture = try RemoteBootstrapFixture(pairNativeDevice: true, pushConfiguration: configuration, pushRelay: relay)
        defer { fixture.removeRuntimeFiles() }
        let registration = RemoteGatewayPushRegistration(registrationID: UUID(), sendToken: Data(repeating: 2, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""), relayID: configuration.relayID)
        try fixture.setPushRegistration(registration)
        func event() -> ManagedSessionActionableEvent {
            .init(eventID: UUID(), kind: .needsApproval, timestamp: .now, sessionID: fixture.sessionID, agent: .codex, workspaceID: fixture.summary.placement.workspaceID!, panelID: fixture.panelID)
        }
        fixture.sessionRuntimeStore.onActionableEvent?(event())
        await SessionRuntimeStoreTestSupport.waitUntil { relay.notifications.count == 1 }
        #expect(try fixture.pushConfigurationResponse().registrationID == registration.registrationID)
        relay.sendOutcome = .registrationUnavailable
        fixture.sessionRuntimeStore.onActionableEvent?(event())
        await SessionRuntimeStoreTestSupport.waitUntil { relay.revoked.count == 1 }
        #expect(try fixture.pushConfigurationResponse().registrationID == nil)
        let runtimePaths = ToasttyRuntimePaths.resolve(homeDirectoryPath: "/tmp", environment: [ToasttyRuntimePaths.environmentKey: fixture.runtimeHome])
        #expect(RemoteDeviceStore(fileURL: runtimePaths.remoteAccessDevicesFileURL).pendingPushCleanup.map(\.registrationID) == [registration.registrationID])
        relay.revokeSucceeds = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await SessionRuntimeStoreTestSupport.waitUntil { relay.revoked.count == 2 }
        await Task.yield()
        #expect(RemoteDeviceStore(fileURL: runtimePaths.remoteAccessDevicesFileURL).pendingPushCleanup.isEmpty)
        #expect(relay.notifications.count == 2)
    }

    @MainActor
    @Test func revocationBeforeQueuedSendPreventsDeliveryAndLateFailurePreservesReplacement() async throws {
        let relay = RemotePushRelaySpy()
        relay.holdSend = true
        let configuration = RemotePushConfiguration(relayURL: URL(string: "https://push.example.com")!)!
        let fixture = try RemoteBootstrapFixture(pairNativeDevice: true, pushConfiguration: configuration, pushRelay: relay)
        defer { fixture.removeRuntimeFiles() }
        let first = RemoteGatewayPushRegistration(registrationID: UUID(), sendToken: String(repeating: "A", count: 43), relayID: configuration.relayID)
        try fixture.setPushRegistration(first)
        let workspaceID = try #require(fixture.summary.placement.workspaceID)
        func event() -> ManagedSessionActionableEvent {
            .init(eventID: UUID(), kind: .needsApproval, timestamp: .now, sessionID: fixture.sessionID, agent: .codex, workspaceID: workspaceID, panelID: fixture.panelID)
        }
        fixture.sessionRuntimeStore.onActionableEvent?(event())
        await SessionRuntimeStoreTestSupport.waitUntil { relay.sendContinuation != nil }
        let replacement = RemoteGatewayPushRegistration(registrationID: UUID(), sendToken: String(repeating: "A", count: 43), relayID: configuration.relayID)
        try fixture.setPushRegistration(replacement)
        relay.sendContinuation?.resume(returning: .registrationUnavailable)
        relay.sendContinuation = nil
        await Task.yield()
        #expect(try fixture.pushConfigurationResponse().registrationID == replacement.registrationID)
        relay.holdSend = false
        fixture.sessionRuntimeStore.onActionableEvent?(event())
        fixture.service.revokeDevice(try #require(fixture.service.devices.first { $0.authKind == .native }?.id))
        await Task.yield()
        #expect(relay.notifications.count == 1)
    }

    @MainActor
    @Test func boundedCleanupRotationReachesLaterRecordsAfterOldRelayFailures() async throws {
        let relay = RemotePushRelaySpy()
        let configuration = RemotePushConfiguration(relayURL: URL(string: "https://push.example.com")!)!
        let fixture = try RemoteBootstrapFixture(pairNativeDevice: true, pushConfiguration: configuration, pushRelay: relay, pendingPushCleanupCount: 17)
        defer { fixture.removeRuntimeFiles() }
        await SessionRuntimeStoreTestSupport.waitUntil { relay.revoked.count == 16 }
        #expect(Set(relay.revoked.map(\.registrationID)).count == 16)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await SessionRuntimeStoreTestSupport.waitUntil { relay.revoked.count == 32 }
        #expect(Set(relay.revoked.map(\.registrationID)).count == 17)
        let paths = ToasttyRuntimePaths.resolve(homeDirectoryPath: "/tmp", environment: [ToasttyRuntimePaths.environmentKey: fixture.runtimeHome])
        #expect(RemoteDeviceStore(fileURL: paths.remoteAccessDevicesFileURL).pendingPushCleanup.count == 17)
    }

    @MainActor
    @Test func stalledDeviceDoesNotDelayAnotherEnrolledDevice() async throws {
        let relay = RemotePushRelaySpy()
        let configuration = RemotePushConfiguration(relayURL: URL(string: "https://push.example.com")!)!
        let fixture = try RemoteBootstrapFixture(pairNativeDevice: true, pushConfiguration: configuration, pushRelay: relay)
        defer { fixture.removeRuntimeFiles() }
        defer {
            relay.sendContinuation?.resume(returning: .accepted)
            relay.sendContinuation = nil
        }
        let first = RemoteGatewayPushRegistration(registrationID: UUID(), sendToken: String(repeating: "A", count: 43), relayID: configuration.relayID)
        try fixture.setPushRegistration(first)
        let secondID = try fixture.pairAnotherPushDevice(configuration: configuration)
        relay.holdSend = true
        relay.heldRegistrationID = first.registrationID
        fixture.sessionRuntimeStore.onActionableEvent?(.init(eventID: UUID(), kind: .needsApproval, timestamp: .now,
            sessionID: fixture.sessionID, agent: .codex, workspaceID: try #require(fixture.summary.placement.workspaceID), panelID: fixture.panelID))
        await SessionRuntimeStoreTestSupport.waitUntil { relay.notifications.count == 2 }
        #expect(Set(relay.registrations.map(\.registrationID)) == [first.registrationID, secondID])
        #expect(relay.sendContinuation != nil)
    }

    @MainActor
    @Test func cleanupQueuedDuringBatchRunsWithoutAnotherForeground() async throws {
        let relay = RemotePushRelaySpy()
        relay.holdRevoke = true
        let configuration = RemotePushConfiguration(relayURL: URL(string: "https://push.example.com")!)!
        let fixture = try RemoteBootstrapFixture(pairNativeDevice: true, pushConfiguration: configuration, pushRelay: relay, pendingPushCleanupCount: 16)
        defer { fixture.removeRuntimeFiles() }
        defer {
            relay.revokeContinuation?.resume(returning: false)
            relay.revokeContinuation = nil
        }
        await SessionRuntimeStoreTestSupport.waitUntil { relay.revokeContinuation != nil }
        let registration = RemoteGatewayPushRegistration(registrationID: UUID(), sendToken: String(repeating: "A", count: 43), relayID: configuration.relayID)
        try fixture.setPushRegistration(registration)
        try fixture.setPushRegistration(nil)
        relay.holdRevoke = false
        relay.revokeContinuation?.resume(returning: false)
        relay.revokeContinuation = nil
        await SessionRuntimeStoreTestSupport.waitUntil { relay.revoked.contains { $0.registrationID == registration.registrationID } }
        #expect(relay.revoked.contains { $0.registrationID == registration.registrationID })
    }

    @MainActor
    @Test func terminalOnlyTabRenameAndResetPublishPlacementWithoutActivity() async throws {
        let fixture = try RemoteBootstrapFixture()
        defer { fixture.removeRuntimeFiles() }
        let original = fixture.summary
        let workspaceID = try #require(original.placement.workspaceID)
        let tabID = try #require(original.placement.workspaceTabID)
        #expect(fixture.service.facadeSessionList(at: .now).workspaces.allSatisfy { $0.panels.isEmpty })

        let titles: [String?] = ["iOS navigation 👩🏽‍💻", nil]
        for title in titles {
            fixture.server.removeAllBroadcasts()
            #expect(fixture.store.send(.setWorkspaceTabCustomTitle(
                workspaceID: workspaceID, tabID: tabID, title: title
            )))
            let expected = title ?? original.placement.workspaceTabTitle
            await SessionRuntimeStoreTestSupport.waitUntil {
                fixture.server.sessionListSnapshots.last?.conversations.first {
                    $0.conversationID == fixture.conversationID
                }?.placement.workspaceTabTitle == expected
            }
            let summary = try #require(fixture.server.sessionListSnapshots.last?.conversations.first {
                $0.conversationID == fixture.conversationID
            })
            #expect(summary.placement.workspaceTabID == tabID)
            #expect(summary.placement.workspaceTabTitle == expected)
            #expect(summary.title == original.title)
            #expect(summary.updatedAt == original.updatedAt)
            #expect(summary.latestSequence == original.latestSequence)
            #expect(summary.inputAvailability == original.inputAvailability)
            #expect(summary.presentationStatus == original.presentationStatus)
            #expect(fixture.service.facadeConversationSnapshot(
                for: fixture.conversationID, at: .now
            )?.summary.placement == summary.placement)
        }
    }

    @MainActor
    @Test func closedPanelSnapshotOmitsTabPlacement() throws {
        let fixture = try RemoteBootstrapFixture()
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.summary.placement.workspaceTabID != nil)
        #expect(fixture.store.send(.closePanel(panelID: fixture.panelID)))
        let snapshot = try #require(fixture.service.facadeConversationSnapshot(
            for: fixture.conversationID, at: .now
        ))
        #expect(snapshot.summary.placement.workspaceTabID == nil)
        #expect(snapshot.summary.placement.workspaceTabTitle == nil)
    }

    @MainActor
    @Test func movingConversationToAnotherWorkspacePublishesNewTabIdentity() async throws {
        let fixture = try RemoteBootstrapFixture()
        defer { fixture.removeRuntimeFiles() }
        let selection = try #require(fixture.store.state.selectedWorkspaceSelection())
        let originalTabID = try #require(fixture.summary.placement.workspaceTabID)
        #expect(fixture.store.send(.createWorkspace(windowID: selection.windowID, title: "Destination", activate: true)))
        let workspaceID = try #require(fixture.store.state.selectedWorkspaceSelection()).workspaceID
        let destination = try #require(fixture.store.state.workspacesByID[workspaceID]?.selectedTab)
        #expect(destination.id != originalTabID)
        #expect(fixture.store.send(.setWorkspaceTabCustomTitle(
            workspaceID: workspaceID, tabID: destination.id, title: "Release prep"
        )))
        let slotID = try #require(destination.layoutTree.allSlotInfos.first?.slotID)
        fixture.server.removeAllBroadcasts()
        #expect(fixture.store.send(.movePanelToWorkspace(panelID: fixture.panelID, targetWorkspaceID: workspaceID, targetSlotID: slotID)))
        await SessionRuntimeStoreTestSupport.waitUntil {
            fixture.server.sessionListSnapshots.last?.conversations.first {
                $0.conversationID == fixture.conversationID
            }?.placement.workspaceTabID == destination.id
        }
        let summary = try #require(fixture.server.sessionListSnapshots.last?.conversations.first {
            $0.conversationID == fixture.conversationID
        })
        #expect(summary.placement.panelID == fixture.panelID)
        #expect(summary.placement.workspaceID == workspaceID)
        #expect(summary.placement.workspaceTabID == destination.id)
        #expect(summary.placement.workspaceTabTitle == "Release prep")
    }

    @MainActor
    @Test func rootModelSwitchesPublishWithoutTranscriptOrInputChanges() async throws {
        let fixture = try RemoteBootstrapFixture()
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.confirmCurrentLaunchBinding())
        let original = fixture.summary
        #expect(original.executionProfile == nil)

        let transcript = try FileHandle(forWritingTo: URL(filePath: fixture.resumeRecord.sessionFilePath))
        defer { try? transcript.close() }
        // Repeated values with the same timestamp are distinct reports in
        // file order. The third report must not be deduplicated against A.
        for model in ["model-A", "model-B", "model-A"] {
            fixture.server.removeAllBroadcasts()
            let line = #"{"timestamp":"2026-08-07T10:00:05.200Z","type":"turn_context","payload":{"model":"\#(model)","effort":"high"}}"# + "\n"
            try transcript.write(contentsOf: Data(line.utf8))
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline,
                  !fixture.server.sessionListSnapshots.contains(where: { snapshot in
                      snapshot.conversations.contains {
                          $0.conversationID == fixture.conversationID && $0.executionProfile?.modelIdentifier == model
                      }
                  }) {
                try await Task.sleep(for: .milliseconds(20))
            }
            let delivered = try #require(fixture.server.sessionListSnapshots.last?.conversations.first {
                $0.conversationID == fixture.conversationID
            })
            #expect(delivered.executionProfile == .init(modelIdentifier: model, reasoningEffort: "high"))
            #expect(delivered.latestSequence == original.latestSequence)
            #expect(delivered.inputAvailability == original.inputAvailability)
            #expect(delivered.state == original.state)
            #expect(fixture.summary.executionProfile == delivered.executionProfile)
            #expect(!fixture.server.broadcasts.contains {
                if case .conversationEvents = $0 { return true }
                return false
            })
        }
    }

    @MainActor
    @Test func workspaceInventoryCarriesSortedAnnotationsWithResolvedColors() throws {
        var state = AppState.bootstrap()
        let workspaceID = try #require(state.selectedWorkspaceSelection()?.workspaceID)
        state.workspacesByID[workspaceID]?.annotations = [
            "task-status": WorkspaceAnnotation(text: "Working"),
            "github-pr": WorkspaceAnnotation(text: "PR #12", url: "https://github.com/example/repo/pull/12"),
            "edited": WorkspaceAnnotation(text: "Hand edited", url: "file:///etc/hosts"),
        ]

        let inventory = RemoteAccessService.workspaceInventory(
            state: state, annotationColorTokens: ["github-pr": .named(.green)])
        let annotations = try #require(inventory.first { $0.id == workspaceID }?.annotations)

        #expect(annotations.map(\.key) == ["edited", "github-pr", "task-status"])
        #expect(annotations[0].url == nil, "A link the sidebar would not open is not sent")
        #expect(annotations[1].url == URL(string: "https://github.com/example/repo/pull/12"))
        #expect(annotations[1].color == "#5BA08A")
        #expect(annotations[2].color == WorkspaceAnnotationChipPalette.hexString(
            AnnotationStyleStore.fallbackColorToken(forKey: "task-status").baseHexValue))
    }

    @MainActor
    @Test func annotationSetColorChangeAndClearEachRebroadcastTheSessionList() async throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let workspaceID = try #require(store.state.selectedWorkspaceSelection()?.workspaceID)
        let server = RemoteAccessGatewayServerSpy()
        let runtimeHome = "/tmp/toastty-remote-access-annotations-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: runtimeHome) }
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/toastty-remote-access-test-home",
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome]
        )
        let annotationStyleStore = AnnotationStyleStore(runtimePaths: runtimePaths)
        // No sessions exist, so nothing else keeps publishing session lists
        // after setup; without the style-store subscription the color step
        // times out.
        let service = RemoteAccessService(
            store: store,
            annotationStyleStore: annotationStyleStore,
            sessionRuntimeStore: SessionRuntimeStore(),
            terminalRuntimeRegistry: TerminalRuntimeRegistry(),
            runtimePaths: runtimePaths,
            port: 42_995,
            initiallyEnabled: false,
            gatewayServerFactory: { _ in server }
        )
        defer { service.setEnabled(false, persist: false) }
        service.setEnabled(true, persist: false)
        server.reportReady(port: 42_995)

        server.removeAllBroadcasts()
        #expect(store.send(.setWorkspaceAnnotation(
            workspaceID: workspaceID,
            key: "github-pr",
            annotation: WorkspaceAnnotation(text: "PR #12", url: "https://github.com/example/repo/pull/12")
        )))
        let set = try await Self.deliveredAnnotations(in: workspaceID, from: server) { !$0.isEmpty }
        #expect(set.map(\.text) == ["PR #12"])

        // A color-only change never touches AppState.
        server.removeAllBroadcasts()
        #expect(try annotationStyleStore.setColor(.named(.red), forKey: "github-pr"))
        let recolored = try await Self.deliveredAnnotations(in: workspaceID, from: server) { !$0.isEmpty }
        #expect(recolored.map(\.color) == ["#E55C5C"])

        server.removeAllBroadcasts()
        #expect(store.send(.clearWorkspaceAnnotation(workspaceID: workspaceID, key: "github-pr")))
        let cleared = try await Self.deliveredAnnotations(in: workspaceID, from: server) { $0.isEmpty }
        #expect(cleared.isEmpty)
    }

    @MainActor
    @Test func remoteDoneMarksOnlySubspacesAndRebroadcastsTheNestedWorkspace() async throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try #require(store.state.windows.first?.id)
        let parentID = try #require(store.state.selectedWorkspaceSelection()?.workspaceID)
        #expect(store.send(.createWorkspace(windowID: windowID, title: "task", activate: false)))
        let subspaceID = try #require(store.state.windows.first?.workspaceIDs.last)
        #expect(subspaceID != parentID)
        #expect(store.send(.setWorkspaceParent(
            workspaceID: subspaceID, parentWorkspaceID: parentID, spawningSessionID: "session-1")))
        #expect(store.send(.setWorkspaceAnnotation(
            workspaceID: subspaceID,
            key: "github-pr",
            annotation: WorkspaceAnnotation(text: "PR #12", url: "https://github.com/example/repo/pull/12")
        )))

        let server = RemoteAccessGatewayServerSpy()
        let runtimeHome = "/tmp/toastty-remote-access-done-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: runtimeHome) }
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/toastty-remote-access-test-home",
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome]
        )
        let service = RemoteAccessService(
            store: store,
            annotationStyleStore: AnnotationStyleStore(runtimePaths: runtimePaths),
            sessionRuntimeStore: SessionRuntimeStore(),
            terminalRuntimeRegistry: TerminalRuntimeRegistry(),
            runtimePaths: runtimePaths,
            port: 42_996,
            initiallyEnabled: false,
            gatewayServerFactory: { _ in server }
        )
        defer { service.setEnabled(false, persist: false) }
        service.setEnabled(true, persist: false)
        server.reportReady(port: 42_996)
        let device = RemoteDeviceRecord(name: "Phone", scopes: [.read, .send], createdAt: Date())
        func delivered(
            where isExpected: (RemoteWorkspaceSummary) -> Bool
        ) async throws -> RemoteWorkspaceSummary {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline {
                if let summary = server.sessionListSnapshots.last?
                    .workspaces.first(where: { $0.id == subspaceID }),
                   isExpected(summary) {
                    return summary
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw CocoaError(.coderValueNotFound)
        }

        // A top-level workspace cannot hold a done mark.
        #expect(service.setWorkspaceDone(.init(workspaceID: parentID, done: true), device: device) == .notSubspace)
        #expect(service.setWorkspaceDone(.init(workspaceID: UUID(), done: true), device: device) == .workspaceNotFound)

        server.removeAllBroadcasts()
        #expect(service.setWorkspaceDone(.init(workspaceID: subspaceID, done: true), device: device) == .updated)
        let done = try await delivered { $0.doneAt != nil }
        #expect(done.parentWorkspaceID == parentID)
        #expect(done.annotations.map(\.key) == ["github-pr"])
        let markedAt = try #require(store.state.workspacesByID[subspaceID]?.doneAt)

        // A retry keeps the original time and publishes nothing new.
        server.removeAllBroadcasts()
        #expect(service.setWorkspaceDone(.init(workspaceID: subspaceID, done: true), device: device) == .unchanged)
        #expect(store.state.workspacesByID[subspaceID]?.doneAt == markedAt)

        #expect(service.setWorkspaceDone(.init(workspaceID: subspaceID, done: false), device: device) == .updated)
        #expect(try await delivered { $0.doneAt == nil }.parentWorkspaceID == parentID)

        // A change of spawner alone republishes the list.
        server.removeAllBroadcasts()
        #expect(store.send(.setWorkspaceParent(
            workspaceID: subspaceID, parentWorkspaceID: parentID, spawningSessionID: "session-2")))
        _ = try await delivered { _ in true }

        // A mark set on the Mac reaches clients too, and leaves with the
        // nesting when the workspace moves to top level.
        server.removeAllBroadcasts()
        #expect(store.send(.setWorkspaceDone(workspaceID: subspaceID, doneAt: Date())))
        _ = try await delivered { $0.doneAt != nil }
        server.removeAllBroadcasts()
        #expect(store.send(.setWorkspaceParent(
            workspaceID: subspaceID, parentWorkspaceID: nil, spawningSessionID: nil)))
        let promoted = try await delivered { $0.parentWorkspaceID == nil }
        #expect(promoted.doneAt == nil)
    }

    @Test func remoteDoneRefusesALateRequestWhileWorkIsInProgress() {
        func result(
            done: Bool, isSubspace: Bool = true, isDone: Bool = false, busy: Bool = false
        ) -> RemoteWorkspaceDoneResult {
            RemoteAccessService.workspaceDoneResult(
                requestedDone: done, isSubspace: isSubspace, isDone: isDone, hasWorkInProgress: busy)
        }
        #expect(result(done: true) == .updated)
        // An agent started new work after the tap; its turn cleared or will
        // clear the mark, and the late request must not restore it.
        #expect(result(done: true, busy: true) == .workInProgress)
        #expect(result(done: false, isDone: true, busy: true) == .updated)
        #expect(result(done: true, isDone: true, busy: true) == .unchanged)
        #expect(result(done: true, isSubspace: false) == .notSubspace)
    }

    @MainActor
    @Test func workspaceInventoryNamesSpawnersByListedConversationAndOnlyKnownPrimaryKeys() throws {
        var state = AppState.bootstrap()
        let parentID = try #require(state.selectedWorkspaceSelection()?.workspaceID)
        var subspace = WorkspaceState.bootstrap(title: "task")
        subspace.parentWorkspaceID = parentID
        subspace.spawningSessionID = "session-1"
        subspace.annotations = ["ticket": WorkspaceAnnotation(text: "TOAST-7")]
        subspace.primaryAnnotationKey = "ticket"
        state.workspacesByID[subspace.id] = subspace
        state.windows[0].workspaceIDs.append(subspace.id)
        let conversationID = RemoteConversationID()

        let named = RemoteAccessService.workspaceInventory(
            state: state, conversationIDsBySessionID: ["session-1": conversationID])
        let summary = try #require(named.first { $0.id == subspace.id })
        #expect(summary.parentWorkspaceID == parentID)
        #expect(summary.spawningConversationID == conversationID)
        #expect(summary.primaryAnnotationKey == "ticket")
        #expect(named.first { $0.id == parentID }?.parentWorkspaceID == nil)

        // A spawner the snapshot does not list is left out rather than sent
        // as an ID the client cannot open.
        let unlisted = RemoteAccessService.workspaceInventory(state: state)
        #expect(unlisted.first { $0.id == subspace.id }?.spawningConversationID == nil)

        // A link to a missing parent is not one the sidebar honors.
        state.workspacesByID[subspace.id]?.parentWorkspaceID = UUID()
        state.workspacesByID[subspace.id]?.doneAt = Date()
        let dangling = RemoteAccessService.workspaceInventory(state: state)
        let flat = try #require(dangling.first { $0.id == subspace.id })
        #expect(flat.parentWorkspaceID == nil)
        #expect(flat.doneAt == nil)
    }

    /// Waits for a broadcast session list whose annotations for the workspace
    /// satisfy `isExpected`.
    @MainActor
    private static func deliveredAnnotations(
        in workspaceID: UUID,
        from server: RemoteAccessGatewayServerSpy,
        where isExpected: ([RemoteWorkspaceAnnotation]) -> Bool
    ) async throws -> [RemoteWorkspaceAnnotation] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let annotations = server.sessionListSnapshots.last?
                .workspaces.first(where: { $0.id == workspaceID })?.annotations,
               isExpected(annotations) {
                return annotations
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("No session_list broadcast delivered the expected annotations")
        return []
    }

    @Test func readAcknowledgementAcceptsAuthoritativeEmptyAndRejectsStaleBoundaries() {
        let runID = RemoteProjectionRunID()
        let empty = RemoteConversationReadAcknowledgementRequest(
            conversationID: RemoteConversationID(),
            projectionRunID: runID,
            projectionGeneration: 2,
            observedThroughSequence: 0
        )
        let matching = RemoteConversationReadAcknowledgementRequest(
            conversationID: RemoteConversationID(),
            projectionRunID: runID,
            projectionGeneration: 2,
            observedThroughSequence: 8
        )

        #expect(RemoteAccessService.readAcknowledgementResult(
            request: empty,
            currentProjectionRunID: runID,
            currentProjectionGeneration: 2,
            currentLatestSequence: 0,
            isUnread: true
        ) == .acknowledged)
        #expect(RemoteAccessService.readAcknowledgementResult(
            request: matching,
            currentProjectionRunID: runID,
            currentProjectionGeneration: 2,
            currentLatestSequence: 0,
            isUnread: true
        ) == .staleBoundary)
        #expect(RemoteAccessService.readAcknowledgementResult(
            request: matching,
            currentProjectionRunID: RemoteProjectionRunID(),
            currentProjectionGeneration: 2,
            currentLatestSequence: 8,
            isUnread: true
        ) == .staleBoundary)
        #expect(RemoteAccessService.readAcknowledgementResult(
            request: matching,
            currentProjectionRunID: runID,
            currentProjectionGeneration: 3,
            currentLatestSequence: 8,
            isUnread: true
        ) == .staleBoundary)
        #expect(RemoteAccessService.readAcknowledgementResult(
            request: matching,
            currentProjectionRunID: runID,
            currentProjectionGeneration: 2,
            currentLatestSequence: 9,
            isUnread: true
        ) == .staleBoundary)
        #expect(RemoteAccessService.readAcknowledgementResult(
            request: matching,
            currentProjectionRunID: runID,
            currentProjectionGeneration: 2,
            currentLatestSequence: 7,
            isUnread: true
        ) == .staleBoundary)
    }

    @Test func readAcknowledgementIsIdempotentAfterCurrentBoundaryIsRead() {
        let runID = RemoteProjectionRunID()
        let request = RemoteConversationReadAcknowledgementRequest(
            conversationID: RemoteConversationID(),
            projectionRunID: runID,
            projectionGeneration: 2,
            observedThroughSequence: 8
        )

        #expect(RemoteAccessService.readAcknowledgementResult(
            request: request,
            currentProjectionRunID: runID,
            currentProjectionGeneration: 2,
            currentLatestSequence: 8,
            isUnread: true
        ) == .acknowledged)
        #expect(RemoteAccessService.readAcknowledgementResult(
            request: request,
            currentProjectionRunID: runID,
            currentProjectionGeneration: 2,
            currentLatestSequence: 8,
            isUnread: false
        ) == .alreadyRead)
    }

    @Test func desktopSessionStatusMapsToRemotePresentationStatusWithUnreadReadySemantics() {
        let cases: [(SessionStatusKind, RemoteSessionPresentationStatus)] = [
            (.idle, .idle),
            (.working, .working),
            (.needsApproval, .needsApproval),
            (.error, .error),
        ]

        for (desktop, remote) in cases {
            #expect(RemoteAccessService.remotePresentationStatus(
                for: desktop,
                isUnread: false
            ) == remote)
            #expect(RemoteAccessService.remotePresentationStatus(
                for: desktop,
                isUnread: true
            ) == remote)
        }
        #expect(RemoteAccessService.remotePresentationStatus(
            for: .ready,
            isUnread: true
        ) == .ready)
        #expect(RemoteAccessService.remotePresentationStatus(
            for: .ready,
            isUnread: false
        ) == .idle)
    }

    @MainActor
    @Test func remoteFlagSetsAndClearsTheSessionsLaterFlagAndPublishesIt() throws {
        let fixture = try RemoteBootstrapFixture(agent: .claude, statusKind: .ready)
        defer { fixture.removeRuntimeFiles() }
        let device = RemoteDeviceRecord(name: "Phone", scopes: [.read, .send], createdAt: fixture.confirmedAt)
        func summary() throws -> RemoteConversationSummary {
            try #require(fixture.service.facadeSessionList(at: fixture.confirmedAt).conversations.first {
                $0.conversationID == fixture.conversationID
            })
        }
        #expect(try summary().isFlaggedForLater == false)

        fixture.server.removeAllBroadcasts()
        #expect(fixture.service.setConversationFlag(
            .init(conversationID: fixture.conversationID, flagged: true), device: device) == .updated)
        #expect(fixture.sessionRuntimeStore.isLaterFlagged(sessionID: fixture.sessionID))
        #expect(try summary().isFlaggedForLater)
        #expect(fixture.server.sessionListSnapshots.last?.conversations.first {
            $0.conversationID == fixture.conversationID
        }?.isFlaggedForLater == true)

        #expect(fixture.service.setConversationFlag(
            .init(conversationID: fixture.conversationID, flagged: true), device: device) == .unchanged)
        #expect(fixture.service.setConversationFlag(
            .init(conversationID: fixture.conversationID, flagged: false), device: device) == .updated)
        #expect(try summary().isFlaggedForLater == false)
        #expect(fixture.service.setConversationFlag(
            .init(conversationID: RemoteConversationID(), flagged: true), device: device) == .conversationNotFound)

        // A session that just ended is refused even before the debounced
        // conversation map catches up.
        fixture.sessionRuntimeStore.setLaterFlag(sessionID: fixture.sessionID, isFlagged: true)
        fixture.sessionRuntimeStore.stopSession(sessionID: fixture.sessionID, at: fixture.confirmedAt.addingTimeInterval(1))
        #expect(fixture.service.setConversationFlag(
            .init(conversationID: fixture.conversationID, flagged: false), device: device) == .conversationNotFound)
    }

    @Test func conversationSummaryCarriesTurnTimingAndOmitsAbsentMarks() throws {
        let startedAt = Date(timeIntervalSince1970: 1_788_696_000)
        let full = RemoteConversationSummary(
            conversationID: RemoteConversationID(), provider: .claude, title: "Session",
            state: .working, inputAvailability: .unavailable(reason: .unknownProviderState),
            isFlaggedForLater: true, turnStartedAt: startedAt, lastTurnDuration: 42,
            latestSequence: 0, updatedAt: startedAt
        )
        let encoder = ConversationEventCoding.makeEncoder()
        let decoded = try ConversationEventCoding.makeDecoder().decode(
            RemoteConversationSummary.self, from: try encoder.encode(full))
        #expect(decoded.isFlaggedForLater)
        #expect(decoded.turnStartedAt == startedAt)
        #expect(decoded.lastTurnDuration == 42)

        // Absent marks leave the JSON as older clients expect it.
        let quiet = RemoteConversationSummary(
            conversationID: RemoteConversationID(), provider: .claude, title: "Session",
            state: .ready, inputAvailability: .unavailable(reason: .unknownProviderState),
            lastTurnDuration: -1, latestSequence: 0, updatedAt: startedAt
        )
        let json = try #require(String(data: try encoder.encode(quiet), encoding: .utf8))
        #expect(json.contains("isFlaggedForLater") == false)
        #expect(json.contains("turnStartedAt") == false)
        #expect(json.contains("lastTurnDuration") == false)
    }

    @MainActor
    @Test func readAcknowledgementPublishesReadReadyConversationAsIdle() throws {
        let fixture = try RemoteBootstrapFixture(agent: .claude, statusKind: .ready)
        defer { fixture.removeRuntimeFiles() }
        let workspaceID = try #require(fixture.summary.placement.workspaceID)

        #expect(fixture.store.send(.recordDesktopNotification(
            workspaceID: workspaceID,
            panelID: fixture.panelID
        )))
        let before = fixture.service.facadeSessionList(at: fixture.confirmedAt)
        let beforeSummary = try #require(before.conversations.first {
            $0.conversationID == fixture.conversationID
        })
        #expect(beforeSummary.presentationStatus == .ready)

        let result = fixture.service.acknowledgeConversationRead(
            RemoteConversationReadAcknowledgementRequest(
                conversationID: fixture.conversationID,
                projectionRunID: before.projectionRunID,
                projectionGeneration: beforeSummary.projectionGeneration,
                observedThroughSequence: beforeSummary.latestSequence
            ),
            device: RemoteDeviceRecord(
                name: "Test iPhone",
                scopes: [.read],
                createdAt: fixture.confirmedAt
            )
        )

        #expect(result == .acknowledged)
        #expect(fixture.summary.presentationStatus == .idle)
        #expect(fixture.server.sessionListSnapshots.last?.conversations.first {
            $0.conversationID == fixture.conversationID
        }?.presentationStatus == .idle)
    }

    @MainActor
    @Test func readReadyRestorableClaudeConversationProjectsIdleAfterRead() throws {
        let fixture = try RemoteBootstrapFixture(agent: .claude, statusKind: .ready)
        defer { fixture.removeRuntimeFiles() }
        let workspaceID = try #require(fixture.summary.placement.workspaceID)

        #expect(fixture.store.send(.recordDesktopNotification(
            workspaceID: workspaceID,
            panelID: fixture.panelID
        )))
        fixture.sessionRuntimeStore.stopSession(
            sessionID: fixture.sessionID,
            at: fixture.confirmedAt.addingTimeInterval(1)
        )
        #expect(fixture.publishResumeRecord())
        #expect(fixture.summary.presentationStatus == .ready)

        #expect(fixture.store.send(.markPanelNotificationsRead(
            workspaceID: workspaceID,
            panelID: fixture.panelID
        )))

        #expect(fixture.summary.presentationStatus == .idle)
    }

    @MainActor
    @Test func restorableClaudeSessionsRemainVisibleAcrossWorkspaceTabSelection() throws {
        let workspaceID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let tabAID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let tabBID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        let panelAID = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
        let panelBID = UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!
        let conversationA = RemoteConversationID(
            rawValue: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        )
        let conversationB = RemoteConversationID(
            rawValue: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        )
        let capturedAt = Date(timeIntervalSince1970: 1_787_500_000)
        let runtimeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-remote-access-background-tabs-\(UUID().uuidString)")
        let transcriptA = runtimeHome.appendingPathComponent("claude-a.jsonl")
        let transcriptB = runtimeHome.appendingPathComponent("claude-b.jsonl")
        try FileManager.default.createDirectory(at: runtimeHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeHome) }
        try #"{"type":"user","sessionId":"native-claude-a","uuid":"user-a","parentUuid":null,"isSidechain":false,"timestamp":"2026-08-24T12:00:00Z","message":{"role":"user","content":"Resume A"}}"#
            .write(to: transcriptA, atomically: true, encoding: .utf8)
        try #"{"type":"user","sessionId":"native-claude-b","uuid":"user-b","parentUuid":null,"isSidechain":false,"timestamp":"2026-08-24T12:00:00Z","message":{"role":"user","content":"Resume B"}}"#
            .write(to: transcriptB, atomically: true, encoding: .utf8)

        let resumeRecordA = ManagedAgentResumeRecord(
            agent: .claude,
            nativeSessionID: "native-claude-a",
            sessionFilePath: transcriptA.path,
            cwd: "/repo/a",
            capturedAt: capturedAt
        )
        let resumeRecordB = ManagedAgentResumeRecord(
            agent: .claude,
            nativeSessionID: "native-claude-b",
            sessionFilePath: transcriptB.path,
            cwd: "/repo/b",
            capturedAt: capturedAt.addingTimeInterval(1)
        )
        let tabA = WorkspaceTabState(
            id: tabAID,
            layoutTree: .slot(slotID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!, panelID: panelAID),
            panels: [
                panelAID: .terminal(TerminalPanelState(
                    title: "Claude A",
                    shell: "zsh",
                    cwd: "/repo/a",
                    resumeRecord: resumeRecordA,
                    remoteConversationID: conversationA
                )),
            ],
            focusedPanelID: panelAID
        )
        let tabB = WorkspaceTabState(
            id: tabBID,
            layoutTree: .slot(slotID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!, panelID: panelBID),
            panels: [
                panelBID: .terminal(TerminalPanelState(
                    title: "Claude B",
                    shell: "zsh",
                    cwd: "/repo/b",
                    resumeRecord: resumeRecordB,
                    remoteConversationID: conversationB
                )),
            ],
            focusedPanelID: panelBID
        )
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Claude Workspace",
            selectedTabID: tabAID,
            tabIDs: [tabAID, tabBID],
            tabsByID: [tabAID: tabA, tabBID: tabB]
        )
        let windowID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let state = AppState(
            windows: [WindowState(
                id: windowID,
                frame: CGRectCodable(x: 120, y: 120, width: 1280, height: 760),
                workspaceIDs: [workspaceID],
                selectedWorkspaceID: workspaceID
            )],
            workspacesByID: [workspaceID: workspace],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let server = RemoteAccessGatewayServerSpy()
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: runtimeHome.path,
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome.path]
        )
        let service = RemoteAccessService(
            store: store,
            annotationStyleStore: AnnotationStyleStore(runtimePaths: runtimePaths),
            sessionRuntimeStore: sessionRuntimeStore,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            runtimePaths: runtimePaths,
            port: 42_996,
            initiallyEnabled: false,
            gatewayServerFactory: { _ in server }
        )
        defer { service.setEnabled(false, persist: false) }

        service.setEnabled(true, persist: false)
        server.reportReady(port: 42_996)

        let initialSnapshot = service.facadeSessionList(at: capturedAt)
        #expect(store.state.workspacesByID[workspaceID]?.selectedTabID == tabAID)
        #expect(initialSnapshot.conversations.count == 2)
        #expect(Set(initialSnapshot.conversations.map(\.conversationID)) == Set([conversationA, conversationB]))

        #expect(store.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: tabBID)))
        let afterSelectionSnapshot = service.facadeSessionList(at: capturedAt.addingTimeInterval(2))
        #expect(store.state.workspacesByID[workspaceID]?.selectedTabID == tabBID)
        #expect(afterSelectionSnapshot.conversations.count == 2)
        #expect(Set(afterSelectionSnapshot.conversations.map(\.conversationID)) == Set([conversationA, conversationB]))
    }

    @MainActor
    @Test func scratchpadAssociationsRequireExactLiveSessionAndMatchingSummary() throws {
        let fixture = try RemoteBootstrapFixture(agent: .claude)
        defer { fixture.removeRuntimeFiles() }
        var state = fixture.store.state
        let summary = fixture.summary
        let workspaceID = try #require(summary.placement.workspaceID)
        let tabID = try #require(state.workspacesByID[workspaceID]?.selectedTabID)
        let link = ScratchpadSessionLink(
            sessionID: fixture.sessionID, agent: .claude,
            sourcePanelID: UUID(), sourceWorkspaceID: UUID())
        let firstID = UUID()
        let secondID = UUID()
        let standaloneID = UUID()
        for panelID in [firstID, secondID, standaloneID] {
            let documentID = UUID()
            state.workspacesByID[workspaceID]?.tabsByID[tabID]?.rightAuxPanel.appendTab(
                .init(
                    id: UUID(), identity: .scratchpad(id: documentID), panelID: panelID,
                    panelState: .web(.init(
                        definition: .scratchpad,
                        scratchpad: .init(documentID: documentID,
                            sessionLink: panelID == standaloneID ? nil : link, revision: 1)))))
        }
        var registry = fixture.sessionRuntimeStore.sessionRegistry
        let associations = RemoteAccessService.scratchpadConversationAssociations(
            state: state, registry: registry, conversations: [summary])
        #expect(associations == [firstID: fixture.conversationID, secondID: fixture.conversationID])
        let inventory = RemoteAccessService.workspaceInventory(state: state, associations: associations)
        #expect(inventory.flatMap(\.panels).filter { $0.associatedConversationID == fixture.conversationID }.count == 2)
        #expect(RemoteAccessService.scratchpadConversationAssociations(
            state: state, registry: registry, conversations: []).isEmpty)
        var staleSummary = summary
        staleSummary.conversationID = RemoteConversationID()
        #expect(RemoteAccessService.scratchpadConversationAssociations(
            state: state, registry: registry, conversations: [staleSummary]).isEmpty)
        for summaries in [[summary, staleSummary], [staleSummary, summary]] {
            #expect(RemoteAccessService.scratchpadConversationAssociations(
                state: state, registry: registry, conversations: summaries) == associations)
        }
        var wrongProvider = summary
        wrongProvider.provider = .codex
        #expect(RemoteAccessService.scratchpadConversationAssociations(
            state: state, registry: registry, conversations: [wrongProvider]).isEmpty)
        registry.stopSession(sessionID: fixture.sessionID, at: .now)
        #expect(RemoteAccessService.scratchpadConversationAssociations(
            state: state, registry: registry, conversations: [summary]).isEmpty)
        registry.startSession(
            sessionID: "replacement", agent: .claude, panelID: fixture.panelID,
            windowID: UUID(), workspaceID: workspaceID, cwd: nil, repoRoot: nil, at: .now)
        #expect(RemoteAccessService.scratchpadConversationAssociations(
            state: state, registry: registry, conversations: [summary]).isEmpty)
    }

    @MainActor
    @Test func scratchpadLinkOnlyChangeBroadcastsAssociationWithoutRevisionChange() async throws {
        let fixture = try RemoteBootstrapFixture(agent: .claude)
        defer { fixture.removeRuntimeFiles() }
        let workspaceID = try #require(fixture.summary.placement.workspaceID)
        let documentID = UUID()
        let scratchpad = ScratchpadState(documentID: documentID, revision: 1)
        #expect(fixture.store.send(.createWebPanel(
            workspaceID: workspaceID,
            panel: .init(definition: .scratchpad, scratchpad: scratchpad), placement: .rightPanel)))
        let panelID = try #require(fixture.service.facadeSessionList(at: .now).workspaces
            .flatMap(\.panels).first { $0.kind == "scratchpad" }?.panelID)
        await SessionRuntimeStoreTestSupport.waitUntil {
            fixture.server.sessionListSnapshots.last?.workspaces.flatMap(\.panels)
                .contains { $0.panelID == panelID } == true
        }
        fixture.server.removeAllBroadcasts()
        var linked = scratchpad
        linked.sessionLink = .init(
            sessionID: fixture.sessionID, agent: .claude,
            sourcePanelID: fixture.panelID, sourceWorkspaceID: workspaceID)
        #expect(fixture.store.send(.updateScratchpadPanelState(
            panelID: panelID, scratchpad: linked, title: nil)))
        await SessionRuntimeStoreTestSupport.waitUntil {
            fixture.server.sessionListSnapshots.last?.workspaces.flatMap(\.panels)
                .first { $0.panelID == panelID }?.associatedConversationID == fixture.conversationID
        }
        let panel = try #require(fixture.server.sessionListSnapshots.last?.workspaces.flatMap(\.panels)
            .first { $0.panelID == panelID })
        #expect(panel.associatedConversationID == fixture.conversationID)
        #expect(panel.revision == 1)
    }

    @MainActor
    @Test func desktopReadTransitionSchedulesFreshIdleSessionList() async throws {
        let fixture = try RemoteBootstrapFixture(agent: .claude, statusKind: .ready)
        defer { fixture.removeRuntimeFiles() }
        let workspaceID = try #require(fixture.summary.placement.workspaceID)

        #expect(fixture.store.send(.recordDesktopNotification(
            workspaceID: workspaceID,
            panelID: fixture.panelID
        )))
        fixture.server.removeAllBroadcasts()
        #expect(fixture.store.send(.markPanelNotificationsRead(
            workspaceID: workspaceID,
            panelID: fixture.panelID
        )))

        await SessionRuntimeStoreTestSupport.waitUntil {
            fixture.server.sessionListSnapshots.last?.conversations.first {
                $0.conversationID == fixture.conversationID
            }?.presentationStatus == .idle
        }
        #expect(fixture.server.sessionListSnapshots.count == 1)
    }

    @MainActor
    @Test func desktopUnreadTransitionSchedulesFreshReadySessionList() async throws {
        let fixture = try RemoteBootstrapFixture(agent: .claude, statusKind: .ready)
        defer { fixture.removeRuntimeFiles() }
        let workspaceID = try #require(fixture.summary.placement.workspaceID)

        #expect(fixture.summary.presentationStatus == .idle)
        fixture.server.removeAllBroadcasts()
        #expect(fixture.store.send(.recordDesktopNotification(
            workspaceID: workspaceID,
            panelID: fixture.panelID
        )))

        await SessionRuntimeStoreTestSupport.waitUntil {
            fixture.server.sessionListSnapshots.last?.conversations.first {
                $0.conversationID == fixture.conversationID
            }?.presentationStatus == .ready
        }
        #expect(fixture.server.sessionListSnapshots.count == 1)
    }

    @Test func desktopSessionDetailProjectsThroughSharedWireNormalization() {
        #expect(RemoteAccessService.remoteStatusDetail(from: nil) == nil)
        #expect(RemoteAccessService.remoteStatusDetail(from: " \n ") == nil)
        #expect(RemoteAccessService.remoteStatusDetail(
            from: "  Indexing\u{0000} workspace\u{202E}  "
        ) == "Indexing workspace")

        let grapheme = "👩🏽‍💻"
        let projected = RemoteAccessService.remoteStatusDetail(
            from: String(
                repeating: grapheme,
                count: RemoteConversationSummary.maximumStatusDetailLength + 1
            )
        )
        #expect(projected?.count == RemoteConversationSummary.maximumStatusDetailLength)
        #expect(projected == String(
            repeating: grapheme,
            count: RemoteConversationSummary.maximumStatusDetailLength
        ))
    }

    @Test func transcriptReplacementExpiresPendingSendBeforeIdenticalHistoryReplay() throws {
        let conversationID = RemoteConversationID()
        let unaffectedConversationID = RemoteConversationID()
        let pendingText = "Please run the focused tests."
        var correlator = RemotePendingSendCorrelator()
        correlator.record(RemoteMessageSendRequest(
            conversationID: conversationID,
            clientRequestID: "new-request",
            expectedInputEpoch: RemoteInputEpoch(bindingID: UUID(), counter: 1),
            text: pendingText
        ))
        correlator.record(RemoteMessageSendRequest(
            conversationID: unaffectedConversationID,
            clientRequestID: "unaffected-request",
            expectedInputEpoch: RemoteInputEpoch(bindingID: UUID(), counter: 1),
            text: pendingText
        ))

        // `.fileReplaced` replays the transcript from byte zero. The service
        // invokes this expiration before it starts the replacement tailer.
        correlator.discard(for: conversationID)
        let replayed = correlator.stamp(
            [Self.userObservation(text: pendingText, fingerprint: "historical")],
            for: conversationID
        )
        let replayedPayload = try #require(Self.userPayload(from: replayed[0]))

        #expect(replayedPayload.origin == .unknown)
        #expect(replayedPayload.clientRequestID == nil)

        // Expiration is conversation-scoped, not a global correlation reset.
        let unaffected = correlator.stamp(
            [Self.userObservation(text: pendingText, fingerprint: "current")],
            for: unaffectedConversationID
        )
        let unaffectedPayload = try #require(Self.userPayload(from: unaffected[0]))
        #expect(unaffectedPayload.origin == .remote)
        #expect(unaffectedPayload.clientRequestID == "unaffected-request")
        #expect(unaffectedPayload.text == pendingText)
    }

    @Test func pendingSendCorrelationRemainsFIFOAndExpiresOldestMismatch() throws {
        let conversationID = RemoteConversationID()
        var correlator = RemotePendingSendCorrelator()
        correlator.record(Self.request(
            conversationID: conversationID,
            clientRequestID: "first-request",
            text: "first text"
        ))
        correlator.record(Self.request(
            conversationID: conversationID,
            clientRequestID: "second-request",
            text: "second text"
        ))

        let firstObservation = correlator.stamp(
            [Self.userObservation(text: "second text", fingerprint: "first-observation")],
            for: conversationID
        )
        let firstPayload = try #require(Self.userPayload(from: firstObservation[0]))
        #expect(firstPayload.origin == .unknown)
        #expect(firstPayload.clientRequestID == nil)

        let secondObservation = correlator.stamp(
            [Self.userObservation(text: "second text", fingerprint: "second-observation")],
            for: conversationID
        )
        let secondPayload = try #require(Self.userPayload(from: secondObservation[0]))
        #expect(secondPayload.origin == .remote)
        #expect(secondPayload.clientRequestID == "second-request")
    }

    @Test func pendingSendCorrelationRetainsOnlyNewestThirtyTwoRequests() throws {
        let conversationID = RemoteConversationID()
        var correlator = RemotePendingSendCorrelator()
        for index in 1...33 {
            correlator.record(Self.request(
                conversationID: conversationID,
                clientRequestID: "request-\(index)",
                text: "text \(index)"
            ))
        }

        let observation = correlator.stamp(
            [Self.userObservation(text: "text 2", fingerprint: "oldest-retained")],
            for: conversationID
        )
        let payload = try #require(Self.userPayload(from: observation[0]))
        #expect(payload.origin == .remote)
        #expect(payload.clientRequestID == "request-2")
    }

    @Test func finalPendingConsumptionRemovesConversationTrackingForMatchAndMismatch() {
        let matchingConversationID = RemoteConversationID()
        let mismatchingConversationID = RemoteConversationID()
        var correlator = RemotePendingSendCorrelator()
        correlator.record(Self.request(
            conversationID: matchingConversationID,
            clientRequestID: "matching-request",
            text: "matching text"
        ))
        correlator.record(Self.request(
            conversationID: mismatchingConversationID,
            clientRequestID: "mismatching-request",
            text: "expected text"
        ))

        _ = correlator.stamp(
            [Self.userObservation(text: "matching text", fingerprint: "match")],
            for: matchingConversationID
        )
        #expect(correlator.conversationIDs == Set([mismatchingConversationID]))

        _ = correlator.stamp(
            [Self.userObservation(text: "different text", fingerprint: "mismatch")],
            for: mismatchingConversationID
        )
        #expect(correlator.conversationIDs.isEmpty)
    }

    @MainActor
    @Test func persistedResumeRecordStaysLockedUntilCurrentLaunchOwnershipIsConfirmed() throws {
        let fixture = try RemoteBootstrapFixture()
        defer { fixture.removeRuntimeFiles() }

        #expect(fixture.summary.inputAvailability ==
            .unavailable(reason: .unknownProviderState))

        #expect(fixture.confirmCurrentLaunchBinding())
        guard case .openPrompt(let epoch) = fixture.summary.inputAvailability else {
            Issue.record("Expected current-launch Codex ownership to open the resumed prompt")
            return
        }
        #expect(epoch.counter == 1)

        // Re-publishing the same ownership fact must not mint a second epoch.
        #expect(fixture.publishResumeRecord(
            capturedAt: fixture.confirmedAt.addingTimeInterval(1)
        ))
        #expect(fixture.summary.inputAvailability == .openPrompt(epoch: epoch))
    }

    @MainActor
    @Test func localInputBeforeCurrentLaunchConfirmationPreventsPromptBootstrap() throws {
        let fixture = try RemoteBootstrapFixture()
        defer { fixture.removeRuntimeFiles() }

        fixture.terminalRuntimeRegistry.localInputObserver?(fixture.panelID)
        #expect(fixture.confirmCurrentLaunchBinding())

        #expect(fixture.summary.inputAvailability ==
            .unavailable(reason: .unknownProviderState))
    }

    @MainActor
    @Test func currentLaunchConfirmationBootstrapsEveryReadyManagedProviderButNotWorking() throws {
        let workingFixture = try RemoteBootstrapFixture(statusKind: .working)
        defer { workingFixture.removeRuntimeFiles() }
        #expect(workingFixture.confirmCurrentLaunchBinding())
        #expect(workingFixture.summary.inputAvailability ==
            .unavailable(reason: .unknownProviderState))

        for provider in [AgentKind.claude, .opencode, .mimocode, .pi] {
            let fixture = try RemoteBootstrapFixture(agent: provider)
            defer { fixture.removeRuntimeFiles() }
            #expect(fixture.confirmCurrentLaunchBinding(), "\(provider.rawValue)")
            guard case .openPrompt = fixture.summary.inputAvailability else {
                Issue.record("Expected current-launch \(provider.rawValue) prompt")
                continue
            }
        }
    }

    /// Remote clients title a conversation the way the sidebar names its row,
    /// so a provider's generated name replaces the panel label.
    @MainActor
    @Test func providerSessionNameTitlesTheRemoteConversation() throws {
        let fixture = try RemoteBootstrapFixture(agent: .opencode)
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.confirmCurrentLaunchBinding())
        let panelLabelTitle = fixture.summary.title

        #expect(fixture.sessionRuntimeStore.applyReportedProviderSessionName(
            sessionID: fixture.sessionID,
            agent: .opencode,
            nativeSessionID: fixture.resumeRecord.nativeSessionID,
            name: "Build system explanation"
        ))

        #expect(panelLabelTitle != "Build system explanation")
        #expect(fixture.summary.title == "Build system explanation")
    }

    /// The user typed on the Mac, cleared it, and released the lock from the
    /// phone. Clients learn each newer draft epoch, a release naming an older
    /// one is refused, and the released prompt accepts one send.
    @MainActor
    @Test func releasedMacDraftReopensTheBootstrappedPromptForASend() async throws {
        let fixture = try RemoteBootstrapFixture(localDraftEpochBroadcastInterval: .milliseconds(20))
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.confirmCurrentLaunchBinding())
        guard case .openPrompt(let prompt) = fixture.summary.inputAvailability else {
            Issue.record("Expected confirmed Codex prompt")
            return
        }
        var delivered: [String] = []
        fixture.terminalRuntimeRegistry.setAutomationPromptStateHandlerForTesting { _ in .idleAtPrompt }
        fixture.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting { text, _, _, _ in
            delivered.append(text)
            return true
        }
        let device = RemoteDeviceRecord(name: "Test iPhone", scopes: [.read, .send], createdAt: fixture.confirmedAt)
        func release(_ epoch: RemoteInputEpoch) -> RemoteConversationLocalDraftReleaseResult {
            fixture.service.performLocalDraftRelease(
                RemoteConversationLocalDraftReleaseRequest(conversationID: fixture.conversationID, expectedDraftEpoch: epoch),
                device: device
            )
        }

        fixture.terminalRuntimeRegistry.localInputObserver?(fixture.panelID)
        guard case .localDraft(let seen) = fixture.summary.inputAvailability else {
            Issue.record("Expected a Mac draft")
            return
        }
        #expect(release(prompt) == .rejected(reason: .draftChanged))

        // A second keystroke clears the draft; clients get its epoch shortly.
        let broadcastsBefore = fixture.server.sessionListSnapshots.count
        fixture.terminalRuntimeRegistry.localInputObserver?(fixture.panelID)
        guard case .localDraft(let current) = fixture.summary.inputAvailability, current != seen else {
            Issue.record("Expected the keystroke to advance the draft epoch")
            return
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.server.sessionListSnapshots.dropFirst(broadcastsBefore).contains { snapshot in
            snapshot.conversations.contains {
                $0.conversationID == fixture.conversationID && $0.inputAvailability == .localDraft(epoch: current)
            }
        })

        #expect(release(seen) == .rejected(reason: .draftChanged))
        #expect(delivered.isEmpty)
        #expect(release(current) == .released)
        #expect(fixture.summary.inputAvailability == .openPrompt(epoch: prompt))
        #expect(release(current) == .rejected(reason: .noLocalDraft))

        let send = RemoteMessageSendRequest(
            conversationID: fixture.conversationID,
            clientRequestID: "after-release",
            expectedInputEpoch: prompt,
            text: "Carry on"
        )
        #expect(fixture.service.performRemoteSend(send, device: device) == .accepted(epoch: prompt))
        #expect(delivered == ["Carry on"])
    }

    @MainActor
    @Test func bootstrappedPromptClosesWhenDesktopStartsWorking() async throws {
        let fixture = try RemoteBootstrapFixture()
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.confirmCurrentLaunchBinding())
        guard case .openPrompt(let epoch) = fixture.summary.inputAvailability else {
            Issue.record("Expected confirmed Codex prompt")
            return
        }

        fixture.sessionRuntimeStore.updateStatus(
            sessionID: fixture.sessionID,
            status: SessionStatus(kind: .working, summary: "Working"),
            at: fixture.confirmedAt.addingTimeInterval(1)
        )
        try await Task.sleep(for: .milliseconds(250))
        #expect(fixture.summary.state == .working)
        #expect(fixture.summary.inputAvailability == .unavailable(reason: .working))

        let result = fixture.service.performRemoteSend(
            RemoteMessageSendRequest(
                conversationID: fixture.conversationID,
                clientRequestID: "status-race",
                expectedInputEpoch: epoch,
                text: "Do not deliver"
            ),
            device: RemoteDeviceRecord(
                name: "Test iPhone",
                scopes: [.read, .send],
                createdAt: fixture.confirmedAt
            )
        )

        #expect(result == .rejected(reason: .surfaceUnavailable))
    }

    @MainActor
    @Test func conversationFilePreviewServesOnlyReferencesTheAgentLinked() async throws {
        let fixture = try RemoteBootstrapFixture(agent: .pi)
        defer { fixture.removeRuntimeFiles() }
        // Outside the session's project root, like a sibling worktree or /tmp.
        let directory = URL(fileURLWithPath: "/tmp/toastty-linked-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let linked = directory.appendingPathComponent("plan.md")
        let unlinked = directory.appendingPathComponent("secret.md")
        try Data("# Linked plan".utf8).write(to: linked)
        try Data("# Secret".utf8).write(to: unlinked)

        #expect(fixture.confirmCurrentLaunchBinding())
        #expect(fixture.sessionRuntimeStore.resetProviderConversationFeed(
            managedSessionID: fixture.sessionID,
            provider: .pi,
            nativeSessionID: fixture.resumeRecord.nativeSessionID,
            snapshotID: "pi-snapshot-1",
            at: fixture.confirmedAt
        ))
        func ingest(_ payload: ConversationEventPayload, _ fingerprint: String) -> Bool {
            fixture.sessionRuntimeStore.ingestProviderConversationObservation(
                managedSessionID: fixture.sessionID,
                provider: .pi,
                nativeSessionID: fixture.resumeRecord.nativeSessionID,
                snapshotID: "pi-snapshot-1",
                observation: ProviderTranscriptObservation(
                    timestamp: fixture.confirmedAt.addingTimeInterval(1),
                    fingerprint: fingerprint,
                    payload: .transcript(payload),
                    mayAuthorizeCurrentRuntime: false
                )
            )
        }
        // A link the user typed must not become a grant; only agent output does.
        #expect(ingest(.userMessage(.init(text: "Read [it](\(unlinked.path))")), "managed:pi:user-1"))
        #expect(ingest(
            .assistantMessage(.init(text: "Wrote [the plan](\(linked.path):1).")),
            "managed:pi:assistant-1"
        ))
        _ = fixture.summary

        let previewHandler = try #require(fixture.gatewayHandler.previewHandler)
        func preview(_ reference: String) async throws -> RemotePreviewResponse {
            let response = await previewHandler(.init(
                deviceID: UUID(),
                request: .preview(.init(target: .conversationFile(
                    conversationID: fixture.conversationID, fileReference: reference)))
            ))
            return try JSONDecoder().decode(RemotePreviewResponse.self, from: response.body)
        }

        guard case .document(let document) = try await preview("\(linked.path):1").content else {
            Issue.record("Expected the linked file to preview")
            return
        }
        #expect(document.content == "# Linked plan")
        #expect(document.line == 1)
        // A neighbouring file, even one the user's own message linked, is not granted.
        let refused = try await preview(unlinked.path)
        #expect(refused.content == nil)
        #expect(refused.error != nil)
    }

    @MainActor
    @Test func providerFeedProjectsPiConversationContentWithoutGrantingHistoricalAuthority() throws {
        let fixture = try RemoteBootstrapFixture(agent: .pi)
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.confirmCurrentLaunchBinding())
        #expect(fixture.sessionRuntimeStore.resetProviderConversationFeed(
            managedSessionID: fixture.sessionID,
            provider: .pi,
            nativeSessionID: fixture.resumeRecord.nativeSessionID,
            snapshotID: "pi-snapshot-1",
            at: fixture.confirmedAt
        ))
        #expect(fixture.sessionRuntimeStore.ingestProviderConversationObservation(
            managedSessionID: fixture.sessionID,
            provider: .pi,
            nativeSessionID: fixture.resumeRecord.nativeSessionID,
            snapshotID: "pi-snapshot-1",
            observation: ProviderTranscriptObservation(
                timestamp: fixture.confirmedAt.addingTimeInterval(1),
                fingerprint: "managed:pi:assistant-1",
                payload: .transcript(.assistantMessage(.init(text: "Pi finished the work"))),
                mayAuthorizeCurrentRuntime: false
            )
        ))

        guard case .page(let page) = fixture.service.facadeConversationEvents(
            for: fixture.conversationID,
            after: nil,
            limit: 100
        ) else {
            Issue.record("Expected Pi conversation event page")
            return
        }
        #expect(page.events.contains { event in
            guard case .assistantMessage(let payload) = event.payload else { return false }
            return payload.text == "Pi finished the work"
        })
        guard case .openPrompt = fixture.summary.inputAvailability else {
            Issue.record("Historical feed replay closed the confirmed current prompt")
            return
        }
    }

    @MainActor
    @Test func claudeProviderFeedStabilizationSurvivesLatePassiveObservation() async throws {
        let fixture = try RemoteBootstrapFixture(
            agent: .claude,
            claudePromptStabilizationDelay: .milliseconds(40)
        )
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.confirmCurrentLaunchBinding())
        #expect(fixture.sessionRuntimeStore.resetProviderConversationFeed(
            managedSessionID: fixture.sessionID,
            provider: .claude,
            nativeSessionID: fixture.resumeRecord.nativeSessionID,
            snapshotID: "claude-stabilization",
            at: fixture.confirmedAt
        ))
        #expect(fixture.sessionRuntimeStore.ingestProviderConversationObservation(
            managedSessionID: fixture.sessionID,
            provider: .claude,
            nativeSessionID: fixture.resumeRecord.nativeSessionID,
            snapshotID: "claude-stabilization",
            observation: ProviderTranscriptObservation(
                timestamp: fixture.confirmedAt.addingTimeInterval(1),
                fingerprint: "managed:claude:user-1",
                payload: .transcript(.userMessage(.init(text: "Run it")))
            )
        ))
        #expect(fixture.sessionRuntimeStore.ingestProviderConversationObservation(
            managedSessionID: fixture.sessionID,
            provider: .claude,
            nativeSessionID: fixture.resumeRecord.nativeSessionID,
            snapshotID: "claude-stabilization",
            observation: ProviderTranscriptObservation(
                timestamp: fixture.confirmedAt.addingTimeInterval(2),
                fingerprint: "managed:claude:turn-end-1",
                payload: .turnEnded(turnID: "turn-1", reason: .completed)
            )
        ))

        #expect(fixture.summary.state == .awaitingInput)
        #expect(fixture.summary.inputAvailability ==
            .unavailable(reason: .unknownProviderState))

        #expect(fixture.sessionRuntimeStore.ingestProviderConversationObservation(
            managedSessionID: fixture.sessionID,
            provider: .claude,
            nativeSessionID: fixture.resumeRecord.nativeSessionID,
            snapshotID: "claude-stabilization",
            observation: ProviderTranscriptObservation(
                timestamp: fixture.confirmedAt.addingTimeInterval(2.1),
                turnID: "turn-1",
                fingerprint: "managed:claude:assistant-late",
                payload: .transcript(.assistantMessage(.init(text: "Done")))
            )
        ))
        #expect(fixture.summary.inputAvailability ==
            .unavailable(reason: .unknownProviderState))

        await SessionRuntimeStoreTestSupport.waitUntil {
            fixture.summary.inputAvailability.allowsRemoteSend
        }
        #expect(fixture.summary.inputAvailability.allowsRemoteSend)
    }


    @MainActor
    @Test func attachmentSendStagesExactBytesDeliversToBoundPanelAndSuppressesReplay() async throws {
        let fixture = try RemoteBootstrapFixture(pairNativeDevice: true)
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.confirmCurrentLaunchBinding())
        guard case .openPrompt(let epoch) = fixture.summary.inputAvailability else { Issue.record("Expected prompt"); return }
        fixture.terminalRuntimeRegistry.setAutomationPromptStateHandlerForTesting { _ in .idleAtPrompt }
        var delivered: [String] = []
        fixture.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting { text, submit, panelID, _ in
            #expect(panelID == fixture.panelID)
            #expect(submit)
            delivered.append(text)
            return true
        }
        let attachment = RemoteMessageAttachment(filename: "original.txt", data: Data("uploaded file bytes".utf8))
        let request = RemoteMessageSendRequest(conversationID: fixture.conversationID, clientRequestID: "attachment-delivery",
            expectedInputEpoch: epoch, text: "Read this", attachments: [attachment])
        let http = RemoteGatewayHTTPRequest(method: "POST", path: RemoteAttachmentPolicy.sendPath,
            headers: ["authorization": "Bearer \(try #require(fixture.nativeCredential))", "tailscale-user-login": "owner@example.com"],
            body: try JSONEncoder().encode(request))
        func send() async throws -> RemoteMessageSendResult {
            guard case .deferredAttachments(let deviceID, let body) = fixture.gatewayHandler.handle(http, at: Date()) else {
                throw CocoaError(.coderInvalidValue)
            }
            let response = await fixture.gatewayHandler.resolveAttachments(deviceID: deviceID, body: body)
            return try JSONDecoder().decode(RemoteMessageSendResult.self, from: response.body)
        }
        #expect(try await send() == .accepted(epoch: epoch))
        #expect(delivered.count == 1)
        let directories = try FileManager.default.contentsOfDirectory(at: fixture.attachmentRoot, includingPropertiesForKeys: nil)
        #expect(directories.count == 1)
        let files = try FileManager.default.contentsOfDirectory(at: #require(directories.first), includingPropertiesForKeys: nil)
        let file = try #require(files.first)
        #expect(try Data(contentsOf: file) == attachment.data)
        // Enumeration can resolve /tmp to /private/tmp. Delivery uses the
        // configured runtime spelling, so derive that exact path here.
        let deliveredFile = fixture.attachmentRoot
            .appendingPathComponent(try #require(directories.first).lastPathComponent)
            .appendingPathComponent(file.lastPathComponent)
        #expect(delivered.first == "Read this\n\nRead the following files attached to this message on this Mac:\n" + TerminalDropPayloadBuilder.shellEscapedPath(deliveredFile.path))
        #expect(try await send() == .duplicate)
        #expect(delivered.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(at: fixture.attachmentRoot, includingPropertiesForKeys: nil).count == 1)

        // Exercise the actual transcript tailer/projection using the exact
        // payload captured at the terminal boundary.
        let observation: [String: Any] = ["timestamp": "2026-08-07T10:00:05.000Z", "type": "event_msg",
            "payload": ["type": "user_message", "message": try #require(delivered.first)]]
        var line = try JSONSerialization.data(withJSONObject: observation)
        line.append(10)
        let transcript = try FileHandle(forWritingTo: URL(filePath: fixture.resumeRecord.sessionFilePath))
        try transcript.seekToEnd()
        try transcript.write(contentsOf: line)
        try transcript.close()
        await SessionRuntimeStoreTestSupport.waitUntil {
            guard case .page(let page) = fixture.service.facadeConversationEvents(for: fixture.conversationID, after: nil, limit: 100) else { return false }
            return page.events.contains { event in
                guard case .userMessage(let payload) = event.payload else { return false }
                return payload.clientRequestID == request.clientRequestID && payload.text == request.displayText
            }
        }
        guard case .page(let page) = fixture.service.facadeConversationEvents(for: fixture.conversationID, after: nil, limit: 100) else { Issue.record("Missing projection"); return }
        #expect(page.events.contains { event in
            guard case .userMessage(let payload) = event.payload else { return false }
            return payload.clientRequestID == request.clientRequestID && payload.text == request.displayText
        })
    }

    @MainActor
    @Test func attachmentStagingIsRemovedWhenFinalEpochGateRejects() async throws {
        let fixture = try RemoteBootstrapFixture(pairNativeDevice: true)
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.confirmCurrentLaunchBinding())
        guard case .openPrompt(let epoch) = fixture.summary.inputAvailability else { Issue.record("Expected prompt"); return }
        fixture.terminalRuntimeRegistry.setAutomationPromptStateHandlerForTesting { _ in .idleAtPrompt }
        var deliveries = 0
        fixture.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting { _, _, _, _ in deliveries += 1; return true }
        let request = RemoteMessageSendRequest(conversationID: fixture.conversationID, clientRequestID: "attachment-stale",
            expectedInputEpoch: epoch.next(), text: "", attachments: [.init(filename: "x.txt", data: Data("private bytes".utf8))])
        let http = RemoteGatewayHTTPRequest(method: "POST", path: RemoteAttachmentPolicy.sendPath,
            headers: ["authorization": "Bearer \(try #require(fixture.nativeCredential))", "tailscale-user-login": "owner@example.com"],
            body: try JSONEncoder().encode(request))
        guard case .deferredAttachments(let deviceID, let body) = fixture.gatewayHandler.handle(http, at: Date()) else { Issue.record("Expected deferred send"); return }
        let response = await fixture.gatewayHandler.resolveAttachments(deviceID: deviceID, body: body)
        #expect(try JSONDecoder().decode(RemoteMessageSendResult.self, from: response.body) == .rejected(reason: .epochMismatch))
        #expect(deliveries == 0)
        #expect(try FileManager.default.contentsOfDirectory(at: fixture.attachmentRoot, includingPropertiesForKeys: nil).isEmpty)
    }

    @Test func attachmentCorrelationRequiresExactDeliveredPromptBeforeProjectingDisplayText() throws {
        let conversationID = RemoteConversationID()
        var request = Self.request(conversationID: conversationID, clientRequestID: "attachment-correlation", text: "Look")
        request.attachments = [.init(filename: "photo.jpg", data: Data([255, 216, 255]))]
        let deliveredText = "Look\nRead files '/private/generated.jpg'"
        var correlator = RemotePendingSendCorrelator()
        correlator.record(request, deliveredText: deliveredText)
        let stamped = correlator.stamp([Self.userObservation(text: deliveredText, fingerprint: "delivered")], for: conversationID)
        let payload = try #require(Self.userPayload(from: stamped[0]))
        #expect(payload.clientRequestID == request.clientRequestID)
        #expect(payload.text == request.displayText)
        correlator.record(request, deliveredText: deliveredText)
        let unmatched = correlator.stamp([Self.userObservation(text: request.displayText, fingerprint: "not-delivered-text")], for: conversationID)
        #expect(Self.userPayload(from: unmatched[0])?.clientRequestID == nil)
    }

    @MainActor
    @Test func acceptedSendWithoutProviderEchoEmitsUnconfirmedReceipt() async throws {
        let fixture = try RemoteBootstrapFixture(
            sendConfirmationTimeout: .seconds(2)
        )
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.confirmCurrentLaunchBinding())
        guard case .openPrompt(let epoch) = fixture.summary.inputAvailability else {
            Issue.record("Expected confirmed prompt")
            return
        }
        fixture.terminalRuntimeRegistry.setAutomationPromptStateHandlerForTesting { _ in
            .idleAtPrompt
        }
        let panelID = fixture.panelID
        fixture.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting {
            _, _, deliveredPanelID, _ in deliveredPanelID == panelID
        }

        let request = RemoteMessageSendRequest(
            conversationID: fixture.conversationID,
            clientRequestID: "missing-provider-echo",
            expectedInputEpoch: epoch,
            text: "Please continue"
        )
        #expect(fixture.service.performRemoteSend(
            request,
            device: RemoteDeviceRecord(
                name: "Test iPhone",
                scopes: [.read, .send],
                createdAt: fixture.confirmedAt
            )
        ).isAccepted)

        await SessionRuntimeStoreTestSupport.waitUntil(timeoutNanoseconds: 3_000_000_000) {
            guard case .page(let page) = fixture.service.facadeConversationEvents(
                for: fixture.conversationID,
                after: nil,
                limit: 100
            ) else {
                return false
            }
            return page.events.contains { event in
                guard case .sendDeliveryUnconfirmed(let payload) = event.payload else {
                    return false
                }
                return payload.clientRequestID == request.clientRequestID
            }
        }
        guard case .page(let page) = fixture.service.facadeConversationEvents(
            for: fixture.conversationID,
            after: nil,
            limit: 100
        ) else {
            Issue.record("Expected conversation event page")
            return
        }
        #expect(page.events.contains { event in
            guard case .sendDeliveryUnconfirmed(let payload) = event.payload else {
                return false
            }
            return payload.clientRequestID == request.clientRequestID
        })

        // The expired request must not consume the next provider echo.
        let transcript = try FileHandle(forWritingTo: URL(filePath: fixture.resumeRecord.sessionFilePath))
        defer { try? transcript.close() }
        try transcript.write(contentsOf: Self.codexLine(
            #"{"type":"task_complete","turn_id":"missing-echo-turn"}"#,
            at: "2026-08-07T10:00:05.000Z"
        ))
        let reopened = try await Self.waitForSummary(fixture) { $0.inputAvailability.allowsRemoteSend }
        guard case .openPrompt(let nextEpoch) = reopened.inputAvailability else {
            Issue.record("Expected next prompt after the unconfirmed send")
            return
        }
        let next = RemoteMessageSendRequest(
            conversationID: fixture.conversationID, clientRequestID: "next-confirmed-send",
            expectedInputEpoch: nextEpoch, text: "A different next message"
        )
        #expect(fixture.service.performRemoteSend(next, device: .init(
            name: "Test iPhone", scopes: [.read, .send], createdAt: fixture.confirmedAt
        )).isAccepted)
        try transcript.write(contentsOf: Self.codexLine(
            #"{"type":"user_message","message":"A different next message"}"#,
            at: "2026-08-07T10:00:06.000Z"
        ))
        try await Self.waitForReceipt(next.clientRequestID, mode: nil, in: fixture)
    }

    @MainActor
    @Test func activationMintsIdentityBeforeListeningAndDisableRemovesLiveTracking() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let selection = try #require(store.state.selectedWorkspaceSelection())
        let panelID = try #require(selection.workspace.focusedPanelID)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.startSession(
            sessionID: "remote-lifecycle-session",
            agent: .codex,
            panelID: panelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: Date(timeIntervalSince1970: 1_786_000_000)
        )
        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let server = RemoteAccessGatewayServerSpy()
        let runtimeHome = "/tmp/toastty-remote-access-lifecycle-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: runtimeHome) }
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/toastty-remote-access-test-home",
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome]
        )
        let service = RemoteAccessService(
            store: store,
            annotationStyleStore: AnnotationStyleStore(runtimePaths: runtimePaths),
            sessionRuntimeStore: sessionRuntimeStore,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            runtimePaths: runtimePaths,
            port: 42_999,
            initiallyEnabled: false,
            gatewayServerFactory: { _ in server }
        )

        #expect(service.activationState == .off)
        #expect(terminalRuntimeRegistry.localInputObserver == nil)
        #expect(Self.remoteConversationID(panelID: panelID, in: store) == nil)
        #expect(server.startCallCount == 0)

        service.setEnabled(true, persist: false)

        let conversationID = try #require(Self.remoteConversationID(panelID: panelID, in: store))
        #expect(service.activationState == .starting)
        #expect(service.isEnabled)
        #expect(service.isReady == false)
        #expect(service.listeningPort == nil)
        #expect(terminalRuntimeRegistry.localInputObserver != nil)
        #expect(server.startedPorts == [42_999])
        service.issuePairingCode()
        #expect(service.currentPairingCode == nil)
        #expect(service.facadeConversationEvents(
            for: conversationID,
            after: nil,
            limit: 10
        ) != .conversationNotFound)

        server.reportReady(port: 42_999)

        #expect(service.activationState == .ready(port: 42_999))
        #expect(service.isReady)
        #expect(service.listeningPort == 42_999)

        server.reportWebSocketCounts(total: 2, native: 1)
        #expect(service.connectedClientCount == 2)
        #expect(service.connectedNativeClientCount == 1)

        service.setEnabled(false, persist: false)

        #expect(service.activationState == .off)
        #expect(service.isEnabled == false)
        #expect(service.connectedClientCount == 0)
        #expect(service.connectedNativeClientCount == 0)
        #expect(terminalRuntimeRegistry.localInputObserver == nil)
        #expect(server.stopCallCount == 1)
        #expect(Self.remoteConversationID(panelID: panelID, in: store) == conversationID)
        #expect(service.facadeConversationEvents(
            for: conversationID,
            after: nil,
            limit: 10
        ) == .conversationNotFound)

        // A delayed callback from a cancelled listener cannot reopen access.
        server.reportReady(port: 42_999)
        #expect(service.activationState == .off)
        #expect(server.stopCallCount == 2)

        server.reportFailure()
        #expect(service.activationState == .off)
        #expect(server.stopCallCount == 2)
    }

    @MainActor
    @Test func listenerFailureReturnsToNonPairableStateAndRemovesObservers() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let server = RemoteAccessGatewayServerSpy()
        let runtimeHome = "/tmp/toastty-remote-access-failure-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: runtimeHome) }
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/toastty-remote-access-test-home",
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome]
        )
        let service = RemoteAccessService(
            store: store,
            annotationStyleStore: AnnotationStyleStore(runtimePaths: runtimePaths),
            sessionRuntimeStore: sessionRuntimeStore,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            runtimePaths: runtimePaths,
            port: 42_998,
            initiallyEnabled: false,
            gatewayServerFactory: { _ in server }
        )

        service.setEnabled(true, persist: false)
        #expect(service.activationState == .starting)
        #expect(terminalRuntimeRegistry.localInputObserver != nil)

        server.reportFailure()

        #expect(service.isEnabled == false)
        #expect(service.isReady == false)
        #expect(service.startupError != nil)
        #expect(terminalRuntimeRegistry.localInputObserver == nil)
        #expect(server.stopCallCount == 1)

        service.setEnabled(true, persist: false)
        #expect(service.activationState == .starting)
        #expect(terminalRuntimeRegistry.localInputObserver != nil)
        #expect(server.startCallCount == 2)

        server.reportReady(port: 42_998)
        #expect(service.activationState == .ready(port: 42_998))

        server.reportFailure()
        #expect(service.isEnabled == false)
        #expect(service.isReady == false)
        #expect(service.startupError != nil)
        #expect(terminalRuntimeRegistry.localInputObserver == nil)
        #expect(server.stopCallCount == 2)
    }

    @MainActor
    private static func remoteConversationID(panelID: UUID, in store: AppStore) -> RemoteConversationID? {
        for workspace in store.state.workspacesByID.values {
            guard case .terminal(let terminalState) = workspace.panels[panelID] else { continue }
            return terminalState.remoteConversationID
        }
        return nil
    }

    private static func request(
        conversationID: RemoteConversationID,
        clientRequestID: String,
        text: String
    ) -> RemoteMessageSendRequest {
        RemoteMessageSendRequest(
            conversationID: conversationID,
            clientRequestID: clientRequestID,
            expectedInputEpoch: RemoteInputEpoch(bindingID: UUID(), counter: 1),
            text: text
        )
    }

    private static func userObservation(
        text: String,
        fingerprint: String
    ) -> ProviderTranscriptObservation {
        ProviderTranscriptObservation(
            timestamp: Date(timeIntervalSince1970: 1_786_000_000),
            fingerprint: fingerprint,
            payload: .transcript(.userMessage(ConversationUserMessagePayload(
                text: text,
                origin: .unknown
            )))
        )
    }

    private static func userPayload(
        from observation: ProviderTranscriptObservation
    ) -> ConversationUserMessagePayload? {
        guard case .transcript(.userMessage(let payload)) = observation.payload else {
            return nil
        }
        return payload
    }
}

@MainActor
private final class RemoteBootstrapFixture {
    let store: AppStore
    let sessionRuntimeStore: SessionRuntimeStore
    let terminalRuntimeRegistry: TerminalRuntimeRegistry
    let server: RemoteAccessGatewayServerSpy
    let gatewayHandler: RemoteGatewayRequestHandler
    let service: RemoteAccessService
    let panelID: UUID
    let sessionID: String
    let conversationID: RemoteConversationID
    let resumeRecord: ManagedAgentResumeRecord
    let confirmedAt: Date
    let runtimeHome: String
    let nativeCredential: String?
    let attachmentRoot: URL

    init(
        agent: AgentKind = .codex,
        statusKind: SessionStatusKind = .idle,
        codexStatusTrackingSource: CodexStatusTrackingSource? = nil,
        claudePromptStabilizationDelay: Duration = .milliseconds(500),
        sendConfirmationTimeout: Duration = .seconds(10),
        localDraftEpochBroadcastInterval: Duration = .milliseconds(500),
        pairNativeDevice: Bool = false,
        pushConfiguration: RemotePushConfiguration? = nil,
        pushRelay: any RemotePushRelaying = RemotePushRelayClient(),
        pendingPushCleanupCount: Int = 0
    ) throws {
        store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let selection = try #require(store.state.selectedWorkspaceSelection())
        panelID = try #require(selection.workspace.focusedPanelID)
        sessionID = "remote-bootstrap-\(UUID().uuidString)"
        confirmedAt = Date(timeIntervalSince1970: 1_786_000_000)
        runtimeHome = "/tmp/toastty-remote-bootstrap-\(UUID().uuidString)"
        let transcriptURL = URL(filePath: runtimeHome + "-transcript.jsonl")
        try Data().write(to: transcriptURL)
        resumeRecord = ManagedAgentResumeRecord(
            agent: agent,
            nativeSessionID: "native-\(UUID().uuidString)",
            sessionFilePath: transcriptURL.path,
            cwd: "/repo",
            capturedAt: confirmedAt
        )

        sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.startSession(
            sessionID: sessionID,
            agent: agent,
            panelID: panelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: codexStatusTrackingSource != nil,
            codexStatusTrackingSource: codexStatusTrackingSource,
            cwd: "/repo",
            repoRoot: "/repo",
            at: confirmedAt
        )
        sessionRuntimeStore.updateStatus(
            sessionID: sessionID,
            status: SessionStatus(kind: statusKind, summary: String(describing: statusKind)),
            at: confirmedAt
        )
        terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let gatewayServer = RemoteAccessGatewayServerSpy()
        server = gatewayServer
        var capturedHandler: RemoteGatewayRequestHandler?
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/toastty-remote-access-test-home",
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome]
        )
        attachmentRoot = runtimePaths.remoteAccessDirectoryURL.appendingPathComponent("attachments")
        if pairNativeDevice {
            let devices = RemoteDeviceStore(fileURL: runtimePaths.remoteAccessDevicesFileURL)
            let now = Date()
            let offer = try devices.issueNativePairingOffer(gatewayURL: URL(string: "https://test.tailnet.ts.net")!, at: now)
            guard case .paired(let device, let token) = try devices.redeemNativePairingOffer(using: .qr(offerID: offer.id, secret: offer.qrPayload.secret), deviceName: "Test phone", tailscaleLogin: "owner@example.com", at: now) else { throw CocoaError(.coderInvalidValue) }
            nativeCredential = token
            if pendingPushCleanupCount > 0 {
                let configuration = try #require(pushConfiguration)
                for _ in 0..<pendingPushCleanupCount {
                    try devices.setPushRegistration(.init(registrationID: UUID(), sendToken: String(repeating: "A", count: 43), relayID: configuration.relayID), forDevice: device.id, configuration: configuration)
                    try devices.setPushRegistration(nil, forDevice: device.id, configuration: configuration)
                }
            }
        } else { nativeCredential = nil }
        service = RemoteAccessService(
            store: store,
            annotationStyleStore: AnnotationStyleStore(runtimePaths: runtimePaths),
            sessionRuntimeStore: sessionRuntimeStore,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            runtimePaths: runtimePaths,
            port: 42_997,
            initiallyEnabled: false,
            claudePromptStabilizationDelay: claudePromptStabilizationDelay,
            sendConfirmationTimeout: sendConfirmationTimeout,
            localDraftEpochBroadcastInterval: localDraftEpochBroadcastInterval,
            pushConfiguration: pushConfiguration,
            pushRelay: pushRelay,
            gatewayServerFactory: { handler in
                capturedHandler = handler
                return gatewayServer
            }
        )
        gatewayHandler = try #require(capturedHandler)
        service.setEnabled(true, persist: false)
        server.reportReady(port: 42_997)
        conversationID = try #require(Self.remoteConversationID(panelID: panelID, in: store))
        guard publishResumeRecord(
            capturedAt: confirmedAt.addingTimeInterval(-60)
        ) else {
            throw RemoteBootstrapFixtureError.couldNotPublishResumeRecord
        }
    }

    var summary: RemoteConversationSummary {
        service.facadeSessionList(at: confirmedAt).conversations.first {
            $0.conversationID == conversationID
        }!
    }

    func setPushRegistration(_ registration: RemoteGatewayPushRegistration?) throws {
        let request = RemoteGatewayHTTPRequest(method: "POST", path: RemotePushPolicy.registrationPath,
            headers: ["authorization": "Bearer \(try #require(nativeCredential))", "tailscale-user-login": "owner@example.com"],
            body: try JSONEncoder().encode(RemoteGatewayPushRegistrationRequest(registration: registration)))
        guard case .respond(let response) = gatewayHandler.handle(request, at: .now), response.status == 200 else { throw CocoaError(.coderInvalidValue) }
    }

    func pushConfigurationResponse() throws -> RemoteGatewayPushConfigurationResponse {
        let request = RemoteGatewayHTTPRequest(method: "GET", path: RemotePushPolicy.configurationPath,
            headers: ["authorization": "Bearer \(try #require(nativeCredential))", "tailscale-user-login": "owner@example.com"], body: Data())
        guard case .respond(let response) = gatewayHandler.handle(request, at: .now) else { throw CocoaError(.coderInvalidValue) }
        return try JSONDecoder().decode(RemoteGatewayPushConfigurationResponse.self, from: response.body)
    }

    func pairAnotherPushDevice(configuration: RemotePushConfiguration) throws -> UUID {
        service.tailnetOrigin = "https://test.tailnet.ts.net"
        service.issueNativePairingOffer()
        let offer = try #require(service.currentNativePairingOffer)
        let exchange = RemoteGatewayNativePairingExchangeRequest(deviceName: "Second phone", offerID: offer.id, secret: offer.qrPayload.secret)
        let headers = ["tailscale-user-login": "second@example.com"]
        guard case .respond(let paired) = gatewayHandler.handle(.init(method: "POST", path: "/v1/native-pairing/exchange", headers: headers,
            body: try JSONEncoder().encode(exchange)), at: .now), paired.status == 200 else { throw CocoaError(.coderInvalidValue) }
        let native = try ConversationEventCoding.makeDecoder().decode(RemoteGatewayNativePairingExchangeResponse.self, from: paired.body)
        let registration = RemoteGatewayPushRegistration(registrationID: UUID(), sendToken: String(repeating: "A", count: 43), relayID: configuration.relayID)
        guard case .respond(let saved) = gatewayHandler.handle(.init(method: "POST", path: RemotePushPolicy.registrationPath,
            headers: ["authorization": "Bearer \(native.credential)", "tailscale-user-login": "second@example.com"],
            body: try JSONEncoder().encode(RemoteGatewayPushRegistrationRequest(registration: registration))), at: .now), saved.status == 200 else { throw CocoaError(.coderInvalidValue) }
        return registration.registrationID
    }

    func confirmCurrentLaunchBinding() -> Bool {
        let confirmed = sessionRuntimeStore.confirmNativeSessionBinding(
            managedSessionID: sessionID,
            panelID: panelID,
            record: resumeRecord
        )
        let published = publishResumeRecord()
        return confirmed && published
    }

    var currentResumeRecord: ManagedAgentResumeRecord? {
        for workspace in store.state.workspacesByID.values {
            guard case .terminal(let terminalState) = workspace.panels[panelID] else { continue }
            return terminalState.resumeRecord
        }
        return nil
    }

    func publishResumeRecord(capturedAt: Date? = nil) -> Bool {
        var record = resumeRecord
        if let capturedAt {
            record.capturedAt = capturedAt
        }
        return store.send(.updateTerminalPanelResumeRecord(
            panelID: panelID,
            resumeRecord: record
        ))
    }

    func removeRuntimeFiles() {
        service.setEnabled(false, persist: false)
        try? FileManager.default.removeItem(atPath: runtimeHome)
        try? FileManager.default.removeItem(atPath: resumeRecord.sessionFilePath)
    }

    private static func remoteConversationID(
        panelID: UUID,
        in store: AppStore
    ) -> RemoteConversationID? {
        for workspace in store.state.workspacesByID.values {
            guard case .terminal(let terminalState) = workspace.panels[panelID] else { continue }
            return terminalState.remoteConversationID
        }
        return nil
    }
}

private enum RemoteBootstrapFixtureError: Error {
    case couldNotPublishResumeRecord
}

extension RemoteAccessServiceSafetyTests {
    @MainActor
    @Test func cursorHookHistoryAndRemoteSendWorkWithoutAResumeRecord() throws {
        let fixture = try Self.cursorFixtureWithoutResumeRecord()
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.currentResumeRecord == nil)
        var delivered: [String] = []
        fixture.terminalRuntimeRegistry.setAutomationPromptStateHandlerForTesting { _ in .idleAtPrompt }
        fixture.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting { text, submit, panelID, _ in
            #expect(panelID == fixture.panelID)
            #expect(submit)
            delivered.append(text)
            return true
        }
        let device = RemoteDeviceRecord(name: "Phone", scopes: [.read, .send], createdAt: fixture.confirmedAt)
        #expect(fixture.observeCursorHook("sessionStart"))
        #expect(fixture.summary.inputAvailability.allowsRemoteSend == false)
        let binding = try #require(fixture.sessionRuntimeStore.nativeSessionBindingConfirmation(for: fixture.sessionID))
        #expect(binding.nativeSessionID == "cursor-root")
        #expect(binding.sessionFilePath.isEmpty)
        #expect(fixture.service.performRemoteSend(
            .init(conversationID: fixture.conversationID, clientRequestID: "cursor-startup-send",
                  expectedInputEpoch: .init(bindingID: UUID(), counter: 1), text: "Do not deliver"),
            device: device
        ) == .rejected(reason: .promptNotOpen))
        #expect(delivered.isEmpty)

        let firstPrompt = "  Explain the change\nwith examples. "
        #expect(fixture.observeCursorHook("beforeSubmitPrompt", generationID: "generation-1", text: firstPrompt))
        #expect(fixture.observeCursorHook("afterAgentResponse", generationID: "generation-1", text: "The change is complete."))
        #expect(fixture.summary.inputAvailability.allowsRemoteSend == false)
        #expect(fixture.observeCursorHook("stop", generationID: "generation-1"))
        let events = try Self.cursorEvents(in: fixture)
        #expect(events.contains {
            guard case .userMessage(let message) = $0.payload else { return false }
            return message.text == firstPrompt && $0.provider == .cursor && $0.turnID == "generation-1"
        })
        #expect(events.contains {
            guard case .assistantMessage(let message) = $0.payload else { return false }
            return message.text == "The change is complete." && $0.provider == .cursor
        })
        guard case .openPrompt(let epoch) = fixture.summary.inputAvailability else {
            Issue.record("Expected a matching Cursor stop to open the root prompt")
            return
        }

        let request = RemoteMessageSendRequest(
            conversationID: fixture.conversationID, clientRequestID: "cursor-send",
            expectedInputEpoch: epoch, text: "  Continue\nwith the next change. "
        )
        #expect(fixture.service.performRemoteSend(request, device: device) == .accepted(epoch: epoch))
        #expect(fixture.service.performRemoteSend(request, device: device) == .duplicate)
        #expect(delivered == [request.text])
        #expect(fixture.observeCursorHook("beforeSubmitPrompt", generationID: "generation-2", text: request.text))
        let confirmedEvents = try Self.cursorEvents(in: fixture)
        #expect(confirmedEvents.contains {
            guard case .userMessage(let message) = $0.payload else { return false }
            return message.text == request.text && message.clientRequestID == request.clientRequestID
        })
        #expect(fixture.currentResumeRecord == nil)
    }

    @MainActor
    @Test func cursorNestedStaleAndDuplicateCompletionCannotChangeRemoteAuthority() throws {
        let fixture = try Self.cursorFixtureWithoutResumeRecord()
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.observeCursorHook("sessionStart"))
        #expect(fixture.observeCursorHook("sessionStart", conversationID: "nested-root") == false)
        #expect(fixture.observeCursorHook("beforeSubmitPrompt", generationID: "generation-1", text: "First turn"))
        #expect(fixture.observeCursorHook("beforeSubmitPrompt", generationID: "generation-2", text: "Current turn"))
        #expect(fixture.observeCursorHook("stop", generationID: "generation-1") == false)
        #expect(fixture.observeCursorHook("afterAgentResponse", conversationID: "nested-root", generationID: "generation-2", text: "Wrong answer") == false)
        #expect(fixture.observeCursorHook("stop", conversationID: "nested-root", generationID: "generation-2") == false)
        #expect(fixture.summary.inputAvailability.allowsRemoteSend == false)
        #expect(fixture.observeCursorHook("afterAgentResponse", generationID: "generation-2", text: "Current answer"))
        #expect(fixture.observeCursorHook("stop", generationID: "generation-2"))
        let availability = fixture.summary.inputAvailability
        #expect(availability.allowsRemoteSend)
        let events = try Self.cursorEvents(in: fixture)
        #expect(fixture.observeCursorHook("stop", generationID: "generation-2") == false)
        #expect(fixture.observeCursorHook("beforeSubmitPrompt", generationID: "generation-1", text: "Stale prompt") == false)
        #expect(fixture.summary.inputAvailability == availability)
        #expect(try Self.cursorEvents(in: fixture) == events)
    }

    @MainActor
    @Test func cursorDelayedResponsePreservesLocalDraftAndCannotReopenRemoteSend() throws {
        let fixture = try Self.cursorFixtureWithoutResumeRecord()
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.observeCursorHook("sessionStart"))
        #expect(fixture.observeCursorHook("beforeSubmitPrompt", generationID: "generation-1", text: "First turn"))
        #expect(fixture.observeCursorHook("stop", generationID: "generation-1"))
        guard case .openPrompt(let epoch) = fixture.summary.inputAvailability else {
            Issue.record("Expected completed Cursor root prompt")
            return
        }
        fixture.service.noteLocalInput(panelID: fixture.panelID)
        let draftAvailability = fixture.summary.inputAvailability
        #expect(draftAvailability.allowsRemoteSend == false)
        #expect(fixture.observeCursorHook("afterAgentResponse", generationID: "generation-1", text: "Delayed answer"))
        #expect(fixture.summary.inputAvailability == draftAvailability)
        #expect(try Self.cursorEvents(in: fixture).contains {
            guard case .assistantMessage(let message) = $0.payload else { return false }
            return message.text == "Delayed answer"
        })

        var deliveries = 0
        fixture.terminalRuntimeRegistry.setAutomationPromptStateHandlerForTesting { _ in .idleAtPrompt }
        fixture.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting { _, _, _, _ in
            deliveries += 1
            return true
        }
        let result = fixture.service.performRemoteSend(
            .init(conversationID: fixture.conversationID, clientRequestID: "cursor-local-draft",
                  expectedInputEpoch: epoch, text: "Do not deliver"),
            device: .init(name: "Phone", scopes: [.read, .send], createdAt: fixture.confirmedAt)
        )
        #expect(result == .rejected(reason: .localDraftPresent))
        #expect(deliveries == 0)
    }

    @MainActor
    @Test func cursorSessionEndClosesRemotePromptAndNewRootStartsFreshHistory() throws {
        let fixture = try Self.cursorFixtureWithoutResumeRecord()
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.observeCursorHook("sessionStart"))
        #expect(fixture.observeCursorHook("beforeSubmitPrompt", generationID: "generation-1", text: "Old prompt"))
        #expect(fixture.observeCursorHook("afterAgentResponse", generationID: "generation-1", text: "Old answer"))
        #expect(fixture.observeCursorHook("stop", generationID: "generation-1"))
        #expect(fixture.summary.inputAvailability.allowsRemoteSend)
        let oldGeneration = fixture.summary.projectionGeneration

        #expect(fixture.observeCursorHook("sessionEnd"))
        #expect(fixture.summary.inputAvailability.allowsRemoteSend == false)
        #expect(fixture.sessionRuntimeStore.nativeSessionBindingConfirmation(for: fixture.sessionID) == nil)
        #expect(fixture.observeCursorHook("afterAgentResponse", generationID: "generation-1", text: "Ended response") == false)
        #expect(fixture.observeCursorHook("stop", generationID: "generation-1") == false)

        #expect(fixture.observeCursorHook("sessionStart", conversationID: "cursor-new-root"))
        #expect(fixture.summary.inputAvailability.allowsRemoteSend == false)
        #expect(fixture.observeCursorHook("beforeSubmitPrompt", conversationID: "cursor-new-root", generationID: "generation-new", text: "New prompt"))
        #expect(fixture.observeCursorHook("afterAgentResponse", conversationID: "cursor-new-root", generationID: "generation-new", text: "New answer"))
        #expect(fixture.observeCursorHook("stop", conversationID: "cursor-new-root", generationID: "generation-new"))
        #expect(fixture.summary.inputAvailability.allowsRemoteSend)
        #expect(fixture.summary.projectionGeneration != oldGeneration)
        let events = try Self.cursorEvents(in: fixture)
        let text = events.compactMap { event -> String? in
            switch event.payload {
            case .userMessage(let message): return message.text
            case .assistantMessage(let message): return message.text
            default: return nil
            }
        }
        #expect(text == ["New prompt", "New answer"])
        #expect(fixture.currentResumeRecord == nil)
    }

    @MainActor
    private static func cursorFixtureWithoutResumeRecord() throws -> RemoteBootstrapFixture {
        let fixture = try RemoteBootstrapFixture(agent: .cursor)
        #expect(fixture.store.send(.updateTerminalPanelResumeRecord(panelID: fixture.panelID, resumeRecord: nil)))
        try FileManager.default.removeItem(atPath: fixture.resumeRecord.sessionFilePath)
        #expect(fixture.currentResumeRecord == nil)
        return fixture
    }

    @MainActor
    private static func cursorEvents(in fixture: RemoteBootstrapFixture) throws -> [ConversationEvent] {
        guard case .page(let page) = fixture.service.facadeConversationEvents(
            for: fixture.conversationID, after: nil, limit: 100
        ) else {
            Issue.record("Expected Cursor remote API history")
            return []
        }
        return page.events
    }
}

@MainActor
private extension RemoteBootstrapFixture {
    func observeCursorHook(
        _ name: String,
        conversationID: String = "cursor-root",
        generationID: String? = nil,
        text: String? = nil
    ) -> Bool {
        let status: SessionStatus?
        switch name {
        case "sessionStart": status = .init(kind: .idle, summary: "Waiting")
        case "beforeSubmitPrompt": status = .init(kind: .working, summary: "Working")
        case "stop": status = .init(kind: .ready, summary: "Ready")
        default: status = nil
        }
        return sessionRuntimeStore.handleCursorHookEvent(
            sessionID: sessionID,
            event: .init(hookEventName: name, conversationID: conversationID,
                         generationID: generationID, status: status, text: text),
            at: confirmedAt.addingTimeInterval(1)
        )
    }
}

@MainActor
private final class RemotePushRelaySpy: RemotePushRelaying {
    var notifications: [RemotePushSessionNotification] = []
    var registrations: [RemoteDevicePushRegistration] = []
    var revoked: [RemoteDevicePushRegistration] = []
    var sendOutcome: RemotePushSendOutcome = .accepted
    var revokeSucceeds = false
    var holdSend = false
    var heldRegistrationID: UUID?
    var sendContinuation: CheckedContinuation<RemotePushSendOutcome, Never>?
    var holdRevoke = false
    var revokeContinuation: CheckedContinuation<Bool, Never>?

    func send(_ notification: RemotePushSessionNotification, to registration: RemoteDevicePushRegistration) async -> RemotePushSendOutcome {
        notifications.append(notification)
        registrations.append(registration)
        if holdSend && (heldRegistrationID == nil || heldRegistrationID == registration.registrationID) {
            return await withCheckedContinuation { sendContinuation = $0 }
        }
        return sendOutcome
    }

    func revoke(_ registration: RemoteDevicePushRegistration) async -> Bool {
        revoked.append(registration)
        if holdRevoke { return await withCheckedContinuation { revokeContinuation = $0 } }
        return revokeSucceeds
    }
}

@MainActor
private final class RemoteAccessGatewayServerSpy: RemoteAccessGatewayServing {
    var onWebSocketCountsChanged: ((RemoteAccessWebSocketCounts) -> Void)?
    var onDeviceRevoked: ((UUID) -> Void)?
    var onListenerReady: ((UInt16) -> Void)?
    var onListenerFailed: ((RemoteAccessListenerFailure) -> Void)?
    var readyPortOnStart: UInt16?
    var startError: NWError?

    private(set) var startedPorts: [UInt16] = []
    private(set) var stopCallCount = 0
    private(set) var broadcasts: [RemoteGatewayStreamMessage] = []

    var sessionListSnapshots: [RemoteSessionListSnapshot] {
        broadcasts.compactMap { message in
            guard case .sessionList(let snapshot) = message else { return nil }
            return snapshot
        }
    }

    var startCallCount: Int {
        startedPorts.count
    }

    func start(port: UInt16) throws {
        startedPorts.append(port)
        if let startError { throw startError }
        if let readyPortOnStart { reportReady(port: readyPortOnStart) }
    }

    func stop() {
        stopCallCount += 1
    }

    func disconnectWebSockets(for _: UUID) {}
    func disconnectAllWebSockets() {}
    func broadcast(_ message: RemoteGatewayStreamMessage) {
        broadcasts.append(message)
    }

    func removeAllBroadcasts() {
        broadcasts.removeAll()
    }

    func reportReady(port: UInt16) {
        onListenerReady?(port)
    }

    func reportFailure(_ failure: RemoteAccessListenerFailure = .unavailable) {
        onListenerFailed?(failure)
    }

    func reportWebSocketCounts(total: Int, native: Int) {
        onWebSocketCountsChanged?(RemoteAccessWebSocketCounts(total: total, native: native))
    }
}

extension RemoteAccessServiceSafetyTests {
    @MainActor
    @Test func claudeQuestionAnswerHoursLaterUsesExactPendingEpochAndWritePolicyWithoutTerminalInput() throws {
        let fixture = try RemoteBootstrapFixture(agent: .claude, statusKind: .working)
        defer { fixture.removeRuntimeFiles(); fixture.sessionRuntimeStore.reset() }
        #expect(fixture.confirmCurrentLaunchBinding())
        let questions = [RemoteInteractionQuestion(id: "q0", header: "Choice", question: "Choose a color",
            options: [.init(id: "q0:o0", label: "Blue"), .init(id: "q0:o1", label: "Green")])]
        let responseID = UUID().uuidString
        let now = Date()
        let askedAt = now.addingTimeInterval(-2 * 60 * 60)
        func hook(_ phase: ClaudeQuestionHookRequest.Phase, name: ClaudeQuestionHookEvent.EventName) -> ClaudeQuestionHookRequest {
            .init(phase: phase, sessionID: fixture.sessionID, panelID: fixture.panelID,
                event: .init(eventName: name, nativeSessionID: fixture.resumeRecord.nativeSessionID,
                    promptID: "prompt", transcriptPath: fixture.resumeRecord.sessionFilePath,
                    providerCallID: name == .preToolUse ? "question-call" : nil, questions: questions, timestamp: askedAt),
                responseID: phase == .begin ? responseID : nil)
        }
        #expect(fixture.sessionRuntimeStore.handleClaudeQuestion(hook(.observe, name: .preToolUse), at: askedAt).status == .observed)
        #expect(fixture.sessionRuntimeStore.handleClaudeQuestion(hook(.begin, name: .permissionRequest), at: askedAt).status == .pending)
        let poll = ClaudeQuestionHookRequest(phase: .poll, sessionID: fixture.sessionID,
            panelID: fixture.panelID, responseID: responseID)
        // The phone has not connected yet, but the launch hook remains alive.
        for second in stride(from: 5, through: 2 * 60 * 60, by: 5) {
            #expect(fixture.sessionRuntimeStore.handleClaudeQuestion(poll,
                at: askedAt.addingTimeInterval(Double(second))).status == .pending)
        }
        let snapshot = try #require(fixture.service.facadeConversationSnapshot(for: fixture.conversationID, at: now))
        let interaction = try #require(snapshot.pendingInteractions.first)
        #expect(interaction.responseID == responseID)
        #expect(snapshot.summary.presentationStatus == .needsApproval)
        let request = RemoteQuestionAnswerRequest(conversationID: fixture.conversationID, interactionID: interaction.id,
            responseID: responseID, expectedInputEpoch: interaction.inputEpoch, clientRequestID: "mobile",
            answers: [.init(questionID: "q0", selectedOptionIDs: ["q0:o0"])])
        let device = RemoteDeviceRecord(name: "Phone", scopes: [.read, .send], createdAt: now)
        var readOnlyDevice = device
        readOnlyDevice.scopes = [.read]
        #expect(fixture.service.performQuestionAnswer(request, device: readOnlyDevice) == .rejected(reason: .sendScopeDenied))
        fixture.service.setSessionWriteEnabled(false, for: fixture.conversationID)
        #expect(fixture.service.performQuestionAnswer(request, device: device) == .rejected(reason: .sessionWritesDisabled))
        fixture.service.setSessionWriteEnabled(true, for: fixture.conversationID)
        var stale = request
        stale.expectedInputEpoch = .init(bindingID: UUID(), counter: 99)
        #expect(fixture.service.performQuestionAnswer(stale, device: device) == .rejected(reason: .epochMismatch))
        // Exercise the actual native authorization -> service -> broker bridge.
        let originalOrigin = fixture.service.tailnetOrigin
        defer { fixture.service.tailnetOrigin = originalOrigin }
        fixture.service.tailnetOrigin = "https://question-test.ts.net"
        fixture.service.issueNativePairingOffer(at: now)
        let offer = try #require(fixture.service.currentNativePairingOffer)
        let exchange = RemoteGatewayNativePairingExchangeRequest(deviceName: "Question Phone",
            offerID: offer.id, secret: offer.qrPayload.secret)
        guard case .respond(let pairingResponse) = fixture.gatewayHandler.handle(.init(method: "POST",
            path: "/v1/native-pairing/exchange", headers: ["tailscale-user-login": "owner@example.com"],
            body: try ConversationEventCoding.makeEncoder().encode(exchange)), at: now) else {
            Issue.record("Expected native pairing response")
            return
        }
        #expect(pairingResponse.status == 200)
        let pairing = try ConversationEventCoding.makeDecoder().decode(RemoteGatewayNativePairingExchangeResponse.self, from: pairingResponse.body)
        let gatewayRequest = RemoteGatewayHTTPRequest(method: "POST", path: "/api/conversation.question.answer",
            headers: ["authorization": "Bearer \(pairing.credential)", "tailscale-user-login": "owner@example.com"],
            body: try ConversationEventCoding.makeEncoder().encode(request))
        // Typing in the native modal must not use the free-form send draft gate.
        fixture.service.noteLocalInput(panelID: fixture.panelID)
        for expected in [RemoteQuestionAnswerResult.submitted, .duplicate] {
            guard case .respond(let response) = fixture.gatewayHandler.handle(gatewayRequest, at: now) else {
                Issue.record("Expected question answer response")
                return
            }
            #expect(response.status == 200)
            #expect(try ConversationEventCoding.makeDecoder().decode(RemoteQuestionAnswerResult.self, from: response.body) == expected)
        }
        #expect(fixture.sessionRuntimeStore.handleClaudeQuestion(poll, at: now).answers == request.answers)
        let completed = ClaudeQuestionHookRequest(phase: .observe, sessionID: fixture.sessionID, panelID: fixture.panelID,
            event: .init(eventName: .postToolUse, nativeSessionID: fixture.resumeRecord.nativeSessionID,
                promptID: "prompt", transcriptPath: fixture.resumeRecord.sessionFilePath, providerCallID: "question-call",
                answers: ["Choose a color": "Blue"], timestamp: now.addingTimeInterval(1)))
        #expect(fixture.sessionRuntimeStore.handleClaudeQuestion(completed, at: now.addingTimeInterval(1)).status == .observed)
        let finished = try #require(fixture.service.facadeConversationSnapshot(for: fixture.conversationID, at: now.addingTimeInterval(1)))
        #expect(finished.pendingInteractions.isEmpty)
        let feed = try #require(fixture.sessionRuntimeStore.providerConversationFeed(managedSessionID: fixture.sessionID))
        guard case .transcript(.interactionResolved(let resolution)) = try #require(feed.observations.last).payload else {
            Issue.record("Expected accepted answers in provider feed")
            return
        }
        #expect(resolution.answers == request.answers)
    }
}

// MARK: - Queue, steer, and stop

extension RemoteAccessServiceSafetyTests {
    private static func codexLine(_ payload: String, at timestamp: String) -> Data {
        Data((#"{"timestamp":"\#(timestamp)","type":"event_msg","payload":\#(payload)}"# + "\n").utf8)
    }

    private static func claudeUserLine(_ text: String, id: String) throws -> Data {
        try claudeLine([
            "type": "user", "uuid": id, "promptId": id,
            "message": ["role": "user", "content": text], "origin": ["kind": "human"],
        ])
    }

    private static func claudeSteerLines(_ text: String, id: String) throws -> Data {
        var data = try claudeLine(["type": "queue-operation", "operation": "enqueue", "content": text])
        data.append(try claudeLine([
            "type": "queue-operation", "operation": "remove", "reason": "absorbed_mid_turn",
            "content": text, "commandUuid": id, "deliveryId": "delivery-\(id)",
        ]))
        data.append(try claudeLine([
            "type": "attachment", "uuid": "attachment-\(id)",
            "attachment": [
                "type": "queued_command", "prompt": text, "source_uuid": id,
                "delivery_id": "delivery-\(id)", "commandMode": "prompt",
                "origin": ["kind": "human"], "humanTurn": true,
            ],
        ]))
        return data
    }

    private static func claudeLine(_ fields: [String: Any]) throws -> Data {
        var record = fields
        record["timestamp"] = "2026-08-07T10:00:05.000Z"
        var data = try JSONSerialization.data(withJSONObject: record)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    @MainActor
    private static func waitForReceipt(
        _ clientRequestID: String, mode: RemoteMessageDeliveryMode?, in fixture: RemoteBootstrapFixture
    ) async throws {
        await SessionRuntimeStoreTestSupport.waitUntil {
            guard case .page(let page) = fixture.service.facadeConversationEvents(
                for: fixture.conversationID, after: nil, limit: 100
            ) else { return false }
            return page.events.contains { event in
                guard case .userMessage(let payload) = event.payload else { return false }
                return payload.clientRequestID == clientRequestID
            }
        }
        guard case .page(let page) = fixture.service.facadeConversationEvents(
            for: fixture.conversationID, after: nil, limit: 100
        ) else {
            Issue.record("Expected a send receipt")
            return
        }
        let receipts = page.events.compactMap { event -> ConversationUserMessagePayload? in
            guard case .userMessage(let payload) = event.payload,
                  payload.clientRequestID == clientRequestID else { return nil }
            return payload
        }
        #expect(receipts.count == 1)
        #expect(receipts.first?.origin == .remote)
        #expect(receipts.first?.deliveryMode == mode)
        #expect(!page.events.contains { event in
            guard case .sendDeliveryUnconfirmed(let payload) = event.payload else { return false }
            return payload.clientRequestID == clientRequestID
        })
    }

    @MainActor
    private static func waitForSummary(
        _ fixture: RemoteBootstrapFixture,
        _ predicate: (RemoteConversationSummary) -> Bool
    ) async throws -> RemoteConversationSummary {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let summary = fixture.summary
            if predicate(summary) { return summary }
            try await Task.sleep(for: .milliseconds(20))
        }
        return fixture.summary
    }

    @MainActor
    @Test func remoteStopUpdatesHookTrackedStatusOnlyAfterSuccessfulDelivery() async throws {
        let fixture = try RemoteBootstrapFixture(
            statusKind: .working,
            codexStatusTrackingSource: .hooks,
            pairNativeDevice: true
        )
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.confirmCurrentLaunchBinding())
        let device = try #require(fixture.service.devices.first { $0.authKind == .native })
        fixture.terminalRuntimeRegistry.setAutomationPromptStateHandlerForTesting { _ in .idleAtPrompt }
        var canDeliver = false
        var interrupts = 0
        var delivered: [String] = []
        fixture.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting { text, _, _, _ in
            delivered.append(text)
            return true
        }
        let targetPanelID = fixture.panelID
        fixture.terminalRuntimeRegistry.setAutomationSendInterruptHandlerForTesting { panelID in
            #expect(panelID == targetPanelID)
            interrupts += 1
            return canDeliver
        }
        let transcript = try FileHandle(forWritingTo: URL(filePath: fixture.resumeRecord.sessionFilePath))
        defer { try? transcript.close() }
        try transcript.write(contentsOf: Self.codexLine(
            #"{"type":"task_started","turn_id":"turn-1"}"#,
            at: "2026-08-07T10:00:05.000Z"
        ))
        let working = try await Self.waitForSummary(fixture) { $0.inputControl?.turnEpoch != nil }
        let turnEpoch = try #require(working.inputControl?.turnEpoch)
        #expect(working.presentationStatus == .working)
        let queued = RemoteMessageSendRequest(
            conversationID: fixture.conversationID,
            clientRequestID: "after-stop",
            expectedInputEpoch: turnEpoch,
            text: "Continue after review",
            deliveryMode: .queue
        )
        #expect(fixture.service.performRemoteSend(queued, device: device) == .queued(position: 1))

        // A stale request and an unavailable terminal must keep both sidebars working.
        #expect(fixture.service.performRemoteInterrupt(
            .init(conversationID: fixture.conversationID, expectedTurnEpoch: turnEpoch.next()), device: device
        ) == .rejected(reason: .turnMismatch))
        #expect(interrupts == 0)
        let request = RemoteConversationInterruptRequest(
            conversationID: fixture.conversationID, expectedTurnEpoch: turnEpoch
        )
        #expect(fixture.service.performRemoteInterrupt(request, device: device) == .rejected(reason: .surfaceUnavailable))
        #expect(fixture.sessionRuntimeStore.panelStatus(for: fixture.panelID)?.status.kind == .working)
        #expect(fixture.summary.presentationStatus == .working)
        #expect(fixture.summary.inputControl?.isQueuePaused == false)

        // Successful Escape delivery uses the same status update as a local interrupt.
        canDeliver = true
        fixture.server.removeAllBroadcasts()
        #expect(fixture.service.performRemoteInterrupt(request, device: device) == .accepted)
        #expect(interrupts == 2)
        #expect(fixture.sessionRuntimeStore.panelStatus(for: fixture.panelID)?.status.kind == .idle)
        #expect(fixture.summary.presentationStatus == .idle)
        #expect(fixture.summary.statusDetail == "Ready for prompt")
        #expect(fixture.summary.inputControl?.isQueuePaused == true)
        #expect(delivered.isEmpty)
        let broadcast = try #require(fixture.server.sessionListSnapshots.last?.conversations.first {
            $0.conversationID == fixture.conversationID
        })
        #expect(broadcast.presentationStatus == .idle)
        #expect(broadcast.inputControl?.isQueuePaused == true)

        // The provider confirms the abort and opens the prompt. Stop must still
        // hold the queued message, even when the shared session is already idle.
        try transcript.write(contentsOf: Self.codexLine(
            #"{"type":"turn_aborted","turn_id":"turn-1"}"#,
            at: "2026-08-07T10:00:06.000Z"
        ))
        let stopped = try await Self.waitForSummary(fixture) { $0.inputAvailability.allowsRemoteSend }
        #expect(stopped.inputAvailability.allowsRemoteSend)
        #expect(stopped.presentationStatus == .idle)
        #expect(stopped.inputControl?.isQueuePaused == true)
        #expect(stopped.inputControl?.queuedMessages.map(\.clientRequestID) == ["after-stop"])
        #expect(delivered.isEmpty)

        // Provider status remains authoritative when the agent starts work again.
        fixture.sessionRuntimeStore.updateStatus(
            sessionID: fixture.sessionID,
            status: SessionStatus(kind: .working, summary: "Working", detail: "New prompt"),
            at: .now
        )
        #expect(fixture.sessionRuntimeStore.panelStatus(for: fixture.panelID)?.status.kind == .working)
        #expect(fixture.summary.presentationStatus == .working)
    }

    @MainActor
    @Test(arguments: [AgentKind.codex, .claude])
    func queuedSendWaitsForTheNextPromptAndSteerTypesIntoTheRunningTurn(agent: AgentKind) async throws {
        let fixture = try RemoteBootstrapFixture(agent: agent, pairNativeDevice: true)
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.confirmCurrentLaunchBinding())
        var delivered: [String] = []
        var interrupts = 0
        fixture.terminalRuntimeRegistry.setAutomationPromptStateHandlerForTesting { _ in .idleAtPrompt }
        fixture.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting { text, submit, _, _ in
            #expect(submit)
            delivered.append(text)
            return true
        }
        fixture.terminalRuntimeRegistry.setAutomationSendInterruptHandlerForTesting { _ in
            interrupts += 1
            return true
        }
        // Queued delivery re-reads the device from the store, so the paired
        // record stands in for the phone.
        let device = try #require(fixture.service.devices.first { $0.authKind == .native })
        guard case .openPrompt = fixture.summary.inputAvailability else {
            Issue.record("Expected the bootstrapped prompt")
            return
        }
        let idleControl = try #require(fixture.summary.inputControl)
        #expect(idleControl.canQueue)
        #expect(idleControl.turnEpoch == nil)
        #expect(idleControl.canSteer == false)
        #expect(idleControl.canInterrupt == false)

        // Claude's hooks publish lifecycle observations through the managed
        // feed; its transcript has no authoritative turn-end record.
        func observeClaude(_ payload: ProviderObservationPayload, fingerprint: String, offset: TimeInterval) {
            #expect(fixture.sessionRuntimeStore.ingestProviderConversationObservation(
                managedSessionID: fixture.sessionID,
                provider: .claude,
                nativeSessionID: fixture.resumeRecord.nativeSessionID,
                snapshotID: "claude-queue-steer",
                observation: ProviderTranscriptObservation(
                    timestamp: fixture.confirmedAt.addingTimeInterval(offset),
                    fingerprint: fingerprint,
                    payload: payload
                )
            ))
        }

        // The Mac user starts a turn: the provider reports it under the
        // consumed prompt's epoch.
        let transcript = try FileHandle(forWritingTo: URL(filePath: fixture.resumeRecord.sessionFilePath))
        defer { try? transcript.close() }
        if agent == .claude {
            #expect(fixture.sessionRuntimeStore.resetProviderConversationFeed(
                managedSessionID: fixture.sessionID,
                provider: .claude,
                nativeSessionID: fixture.resumeRecord.nativeSessionID,
                snapshotID: "claude-queue-steer",
                at: fixture.confirmedAt
            ))
            observeClaude(.transcript(.userMessage(.init(text: "Fix the flicker"))), fingerprint: "user-1", offset: 1)
            observeClaude(.turnStarted(turnID: "turn-1"), fingerprint: "start-1", offset: 1.1)
        } else {
            try transcript.write(contentsOf: Self.codexLine(
                #"{"type":"user_message","message":"Fix the flicker","images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}"#,
                at: "2026-08-07T10:00:05.000Z"
            ))
            try transcript.write(contentsOf: Self.codexLine(
                #"{"type":"task_started","turn_id":"turn-1","started_at":1786000805,"model_context_window":258400,"collaboration_mode_kind":"default"}"#,
                at: "2026-08-07T10:00:05.100Z"
            ))
        }
        let working = try await Self.waitForSummary(fixture) { $0.inputControl?.turnEpoch != nil }
        let turnEpoch = try #require(working.inputControl?.turnEpoch)
        #expect(working.state == .working)
        #expect(working.inputControl?.canSteer == true)
        #expect(working.inputControl?.canInterrupt == true)

        if agent == .claude {
            // A permission prompt must never receive Steer text or Enter.
            observeClaude(.interactionPresented(.init(
                kind: .permission, providerCallID: "approval-1", prompt: "Run the command?"
            )), fingerprint: "approval-1", offset: 1.2)
            let awaitingApproval = try await Self.waitForSummary(fixture) {
                $0.inputControl?.turnEpoch == nil
            }
            #expect(awaitingApproval.inputControl?.canSteer == false)
            #expect(fixture.service.performRemoteSend(.init(
                conversationID: fixture.conversationID, clientRequestID: "steer-during-approval",
                expectedInputEpoch: turnEpoch, text: "Use 300 ms", deliveryMode: .steer
            ), device: device) == .rejected(reason: .notWorking))
            #expect(delivered.isEmpty)
            observeClaude(.transcript(.toolFinished(.init(callID: "approval-1"))),
                          fingerprint: "approval-resolved", offset: 1.3)
            let resumed = try await Self.waitForSummary(fixture) {
                $0.inputControl?.canSteer == true
            }
            #expect(resumed.inputControl?.turnEpoch == turnEpoch)
        }

        // Queue: held, listed, not typed.
        let queued = RemoteMessageSendRequest(
            conversationID: fixture.conversationID, clientRequestID: "queued-1",
            expectedInputEpoch: turnEpoch, text: "Also add a UI test", deliveryMode: .queue
        )
        #expect(fixture.service.performRemoteSend(queued, device: device) == .queued(position: 1))
        #expect(fixture.service.performRemoteSend(queued, device: device) == .duplicate)
        #expect(fixture.summary.inputControl?.queuedMessages.map(\.clientRequestID) == ["queued-1"])
        #expect(delivered.isEmpty)
        var stale = queued
        stale.clientRequestID = "stale-binding"
        stale.expectedInputEpoch = RemoteInputEpoch(bindingID: UUID(), counter: 1)
        #expect(fixture.service.performRemoteSend(stale, device: device) == .rejected(reason: .turnMismatch))

        // Steer: typed into the running turn now, prompt still closed.
        let steer = RemoteMessageSendRequest(
            conversationID: fixture.conversationID, clientRequestID: "steer-1",
            expectedInputEpoch: turnEpoch, text: "Use 300 ms", deliveryMode: .steer
        )
        #expect(fixture.service.performRemoteSend(steer, device: device) == .accepted(epoch: turnEpoch))
        #expect(fixture.service.performRemoteSend(steer, device: device) == .duplicate)
        #expect(delivered == ["Use 300 ms"])
        #expect(fixture.summary.inputAvailability.allowsRemoteSend == false)
        if agent == .claude {
            try transcript.write(contentsOf: Self.claudeSteerLines(steer.text, id: "steer-echo"))
            try await Self.waitForReceipt(steer.clientRequestID, mode: .steer, in: fixture)
            guard case .page(let page) = fixture.service.facadeConversationEvents(
                for: fixture.conversationID, after: nil, limit: 100
            ) else {
                Issue.record("Expected Claude's Steer receipt")
                return
            }
            #expect(page.events.contains { event in
                guard case .userMessage(let payload) = event.payload else { return false }
                return payload.clientRequestID == steer.clientRequestID
                    && payload.origin == .remote && payload.deliveryMode == .steer
            })
            #expect(fixture.summary.inputControl?.turnEpoch == turnEpoch)
            #expect(fixture.summary.inputControl?.queuedMessages.count == 1)
        }
        var wrongTurn = steer
        wrongTurn.clientRequestID = "steer-2"
        wrongTurn.expectedInputEpoch = turnEpoch.next()
        #expect(fixture.service.performRemoteSend(wrongTurn, device: device) == .rejected(reason: .turnMismatch))

        // Local typing on the Mac closes steer for this turn but not stop.
        fixture.service.noteLocalInput(panelID: fixture.panelID)
        let touched = try await Self.waitForSummary(fixture) { $0.inputControl?.canSteer == false }
        #expect(touched.inputControl?.canSteer == false)
        #expect(touched.inputControl?.canInterrupt == true)
        var steerAfterTyping = steer
        steerAfterTyping.clientRequestID = "steer-3"
        #expect(fixture.service.performRemoteSend(steerAfterTyping, device: device) == .rejected(reason: .steerUnavailable))

        // Stop: Escape reaches the terminal and the queue holds.
        #expect(fixture.service.performRemoteInterrupt(
            .init(conversationID: fixture.conversationID, expectedTurnEpoch: turnEpoch.next()), device: device
        ) == .rejected(reason: .turnMismatch))
        #expect(fixture.service.performRemoteInterrupt(
            .init(conversationID: fixture.conversationID, expectedTurnEpoch: turnEpoch), device: device
        ) == .accepted)
        #expect(interrupts == 1)
        #expect(fixture.summary.inputControl?.isQueuePaused == true)
        #expect(fixture.service.performQueueUpdate(
            .init(conversationID: fixture.conversationID, action: .resume), device: device
        ) == .updated)
        #expect(fixture.summary.inputControl?.isQueuePaused == false)

        // The Mac user submitted their typing, then the turn ends: the next
        // prompt opens and the queued message is typed, once, as a prompt.
        if agent == .claude {
            try transcript.write(contentsOf: Self.claudeSteerLines("typed on the mac", id: "mac-mid-turn"))
            await SessionRuntimeStoreTestSupport.waitUntil {
                guard case .page(let page) = fixture.service.facadeConversationEvents(
                    for: fixture.conversationID, after: nil, limit: 100
                ) else { return false }
                return page.events.contains { event in
                    guard case .userMessage(let payload) = event.payload else { return false }
                    return payload.text == "typed on the mac" && payload.clientRequestID == nil
                }
            }
            #expect(fixture.summary.inputControl?.turnEpoch == turnEpoch)
            observeClaude(.turnEnded(turnID: "turn-1", reason: .completed), fingerprint: "end-1", offset: 3)
        } else {
            try transcript.write(contentsOf: Self.codexLine(
                #"{"type":"user_message","message":"typed on the mac","images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}"#,
                at: "2026-08-07T10:00:06.000Z"
            ))
            try transcript.write(contentsOf: Self.codexLine(
                #"{"type":"task_complete","turn_id":"turn-1","last_agent_message":"Done.","started_at":1786000805,"completed_at":1786000821,"duration_ms":16000}"#,
                at: "2026-08-07T10:00:21.000Z"
            ))
        }
        let drained = try await Self.waitForSummary(fixture) { $0.inputControl?.queuedMessages.isEmpty == true }
        #expect(drained.inputControl?.queuedMessages.isEmpty == true)
        #expect(delivered == ["Use 300 ms", "Also add a UI test"])
        // Delivery consumed the prompt, so nothing else can type until the
        // provider opens the next one.
        #expect(drained.inputAvailability.allowsRemoteSend == false)
        #expect(fixture.service.performRemoteSend(queued, device: device) == .duplicate)
        if agent == .claude {
            try transcript.write(contentsOf: Self.claudeUserLine(queued.text, id: "queued-echo"))
            try await Self.waitForReceipt(queued.clientRequestID, mode: .queue, in: fixture)
            observeClaude(.turnEnded(turnID: "queued-turn", reason: .completed), fingerprint: "queued-end", offset: 4)
            let reopened = try await Self.waitForSummary(fixture) { $0.inputAvailability.allowsRemoteSend }
            guard case .openPrompt(let epoch) = reopened.inputAvailability else {
                Issue.record("Expected prompt after the queued turn")
                return
            }
            let direct = RemoteMessageSendRequest(
                conversationID: fixture.conversationID, clientRequestID: "direct-after-queue",
                expectedInputEpoch: epoch, text: "One more message"
            )
            #expect(fixture.service.performRemoteSend(direct, device: device).isAccepted)
            try transcript.write(contentsOf: Self.claudeUserLine(direct.text, id: "direct-echo"))
            try await Self.waitForReceipt(direct.clientRequestID, mode: nil, in: fixture)
        }
    }

    @MainActor
    @Test func claudeSteerStartingTheNextTurnKeepsToasttyQueueHeld() async throws {
        let fixture = try RemoteBootstrapFixture(
            agent: .claude, claudePromptStabilizationDelay: .milliseconds(40), pairNativeDevice: true
        )
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.confirmCurrentLaunchBinding())
        var delivered: [String] = []
        fixture.terminalRuntimeRegistry.setAutomationPromptStateHandlerForTesting { _ in .idleAtPrompt }
        fixture.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting { text, submit, _, _ in
            #expect(submit)
            delivered.append(text)
            return true
        }
        let device = try #require(fixture.service.devices.first { $0.authKind == .native })
        #expect(fixture.sessionRuntimeStore.resetProviderConversationFeed(
            managedSessionID: fixture.sessionID, provider: .claude,
            nativeSessionID: fixture.resumeRecord.nativeSessionID,
            snapshotID: "claude-steer-next-turn", at: fixture.confirmedAt
        ))
        func observe(_ payload: ProviderObservationPayload, fingerprint: String, offset: TimeInterval) {
            #expect(fixture.sessionRuntimeStore.ingestProviderConversationObservation(
                managedSessionID: fixture.sessionID, provider: .claude,
                nativeSessionID: fixture.resumeRecord.nativeSessionID,
                snapshotID: "claude-steer-next-turn",
                observation: .init(timestamp: fixture.confirmedAt.addingTimeInterval(offset),
                                   fingerprint: fingerprint, payload: payload)
            ))
        }
        observe(.transcript(.userMessage(.init(text: "Original task"))), fingerprint: "first-user", offset: 1)
        let working = try await Self.waitForSummary(fixture) { $0.inputControl?.turnEpoch != nil }
        let firstTurn = try #require(working.inputControl?.turnEpoch)
        let queued = RemoteMessageSendRequest(
            conversationID: fixture.conversationID, clientRequestID: "queued-next",
            expectedInputEpoch: firstTurn, text: "Next queued task", deliveryMode: .queue
        )
        #expect(fixture.service.performRemoteSend(queued, device: device) == .queued(position: 1))
        let steer = RemoteMessageSendRequest(
            conversationID: fixture.conversationID, clientRequestID: "steer-next",
            expectedInputEpoch: firstTurn, text: "Correction", deliveryMode: .steer
        )
        #expect(fixture.service.performRemoteSend(steer, device: device) == .accepted(epoch: firstTurn))

        // Claude may read a Steer only after its original turn ends. That
        // next turn must cancel the old prompt-opening delay and hold Queue.
        observe(.turnEnded(turnID: "turn-1", reason: .completed), fingerprint: "first-end", offset: 2)
        observe(.transcript(.userMessage(.init(text: steer.text))), fingerprint: "steer-user", offset: 2.1)
        let nextTurn = try await Self.waitForSummary(fixture) { $0.inputControl?.turnEpoch == firstTurn.next() }
        #expect(nextTurn.inputControl?.turnEpoch == firstTurn.next())
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.summary.inputAvailability.allowsRemoteSend == false)
        #expect(fixture.summary.inputControl?.queuedMessages.map(\.clientRequestID) == [queued.clientRequestID])
        #expect(delivered == [steer.text])

        observe(.turnEnded(turnID: "turn-2", reason: .completed), fingerprint: "second-end", offset: 3)
        let drained = try await Self.waitForSummary(fixture) { $0.inputControl?.queuedMessages.isEmpty == true }
        #expect(drained.inputControl?.queuedMessages.isEmpty == true)
        #expect(delivered == [steer.text, queued.text])
    }

    @MainActor
    @Test func queuedMessagesAreRemovableAndExpireWithTheirBinding() async throws {
        let fixture = try RemoteBootstrapFixture(pairNativeDevice: true)
        defer { fixture.removeRuntimeFiles() }
        #expect(fixture.confirmCurrentLaunchBinding())
        var delivered: [String] = []
        fixture.terminalRuntimeRegistry.setAutomationPromptStateHandlerForTesting { _ in .idleAtPrompt }
        fixture.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting { text, _, _, _ in
            delivered.append(text)
            return true
        }
        let device = try #require(fixture.service.devices.first { $0.authKind == .native })
        let transcript = try FileHandle(forWritingTo: URL(filePath: fixture.resumeRecord.sessionFilePath))
        defer { try? transcript.close() }
        try transcript.write(contentsOf: Self.codexLine(
            #"{"type":"user_message","message":"Go","images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}"#,
            at: "2026-08-07T10:00:05.000Z"
        ))
        let working = try await Self.waitForSummary(fixture) { $0.inputControl?.turnEpoch != nil }
        let turnEpoch = try #require(working.inputControl?.turnEpoch)

        for index in 1...RemoteSendQueue.capacity {
            #expect(fixture.service.performRemoteSend(.init(
                conversationID: fixture.conversationID, clientRequestID: "q-\(index)",
                expectedInputEpoch: turnEpoch, text: "message \(index)", deliveryMode: .queue
            ), device: device) == .queued(position: index))
        }
        #expect(fixture.service.performRemoteSend(.init(
            conversationID: fixture.conversationID, clientRequestID: "q-overflow",
            expectedInputEpoch: turnEpoch, text: "too many", deliveryMode: .queue
        ), device: device) == .rejected(reason: .queueFull))

        fixture.server.removeAllBroadcasts()
        #expect(fixture.service.performQueueUpdate(
            .init(conversationID: fixture.conversationID, action: .remove, clientRequestID: "q-2"), device: device
        ) == .updated)
        #expect(fixture.service.performQueueUpdate(
            .init(conversationID: fixture.conversationID, action: .remove, clientRequestID: "q-2"), device: device
        ) == .unchanged)
        // The removing phone (and any other device) learns it will not be typed.
        #expect(fixture.server.broadcasts.contains { broadcast in
            guard case .conversationEvents(let page) = broadcast else { return false }
            return page.events.contains { event in
                guard case .sendDeliveryUnconfirmed(let payload) = event.payload else { return false }
                return payload.clientRequestID == "q-2"
            }
        })
        #expect(fixture.summary.inputControl?.queuedMessages.map(\.clientRequestID) == ["q-1", "q-3", "q-4", "q-5"])
        #expect(fixture.service.performRemoteSend(.init(
            conversationID: fixture.conversationID, clientRequestID: "q-2",
            expectedInputEpoch: turnEpoch, text: "message 2", deliveryMode: .queue
        ), device: device) == .duplicate)

        // A relaunched runtime is a different conversation to queued text.
        fixture.server.removeAllBroadcasts()
        try transcript.write(contentsOf: Self.codexLine(
            #"{"type":"task_complete","turn_id":"turn-1","last_agent_message":"Done.","started_at":1786000805,"completed_at":1786000821,"duration_ms":16000}"#,
            at: "2026-08-07T10:00:21.000Z"
        ))
        let afterPrompt = try await Self.waitForSummary(fixture) { $0.inputControl?.queuedMessages.count == 3 }
        #expect(delivered == ["message 1"])
        #expect(afterPrompt.inputControl?.queuedMessages.map(\.clientRequestID) == ["q-3", "q-4", "q-5"])
        // Delivery consumed the prompt; the next entry waits for the turn
        // the first one started to end.
        #expect(afterPrompt.inputAvailability.allowsRemoteSend == false)

        // The runtime moves to another provider file: a new binding. The
        // remaining entries expire and the phone hears each one was dropped.
        fixture.server.removeAllBroadcasts()
        var rebound = fixture.resumeRecord
        rebound.sessionFilePath = fixture.resumeRecord.sessionFilePath + ".resumed"
        try Data().write(to: URL(filePath: rebound.sessionFilePath))
        defer { try? FileManager.default.removeItem(atPath: rebound.sessionFilePath) }
        #expect(fixture.store.send(.updateTerminalPanelResumeRecord(panelID: fixture.panelID, resumeRecord: rebound)))
        let expired = try await Self.waitForSummary(fixture) { $0.inputControl?.queuedMessages.isEmpty == true }
        #expect(expired.inputControl?.queuedMessages.isEmpty == true)
        #expect(delivered == ["message 1"])
        let droppedIDs = fixture.server.broadcasts.flatMap { broadcast -> [String] in
            guard case .conversationEvents(let page) = broadcast else { return [] }
            return page.events.compactMap { event in
                guard case .sendDeliveryUnconfirmed(let payload) = event.payload else { return nil }
                return payload.clientRequestID
            }
        }
        #expect(Set(droppedIDs) == ["q-3", "q-4", "q-5"])
    }
}
