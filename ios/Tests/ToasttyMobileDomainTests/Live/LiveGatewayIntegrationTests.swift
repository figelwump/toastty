import Foundation
import RemoteProtocol
@testable import ToasttyMobileDomain
import XCTest

final class LiveGatewayIntegrationTests: XCTestCase {
    func testLiveGatewayContractPagingCloseAndReconnect() async throws {
        let configuration = try Self.liveConfiguration()
        if Self.destructiveRevocationIsEnabled {
            throw XCTSkip("The destructive live test runs the contract checks before revoking the credential.")
        }

        _ = try await Self.exerciseLiveContract(configuration)
    }

    func testDestructiveRevocationClosesSocketAndRejectsCurrentDevice() async throws {
        guard Self.destructiveRevocationIsEnabled else {
            throw XCTSkip(
                "Set TOASTTY_MOBILE_LIVE_ALLOW_DESTRUCTIVE_REVOCATION=true to run this credential-revoking test."
            )
        }
        let configuration = try Self.liveConfiguration()
        let evidence = try await Self.exerciseLiveContract(configuration)
        let credentialProvider = configuration.credentialProvider
        let streamClient = EventStreamClient(
            baseURL: configuration.gatewayURL,
            credentialProvider: credentialProvider
        )
        let deviceClient = NativeDeviceClient(
            baseURL: configuration.gatewayURL,
            credentialProvider: credentialProvider
        )

        let subscription = try await Self.withTimeout {
            try await streamClient.connect()
        }
        let socketProbe = LiveGatewaySocketProbe(subscription: subscription)
        do {
            _ = try await Self.withTimeout {
                try await socketProbe.nextSessionList()
            }
        } catch {
            await socketProbe.close()
            throw error
        }

        // Keep a receive pending while the host revokes this device. The
        // revocation contract closes already-authenticated sockets, not only
        // future connection attempts.
        let remoteClosure = Task {
            try await socketProbe.waitForRemoteClosure()
        }
        do {
            let clock = ContinuousClock()
            let revocationStarted = clock.now
            let revoked = try await Self.withTimeout {
                try await deviceClient.revokeCurrentDevice()
            }
            XCTAssertEqual(revoked.protocolVersion, RemoteGatewayProtocol.version)
            XCTAssertEqual(revoked.revokedDeviceID, evidence.deviceID)

            let closedAt = try await Self.withTimeout(.seconds(10)) {
                try await withTaskCancellationHandler {
                    try await remoteClosure.value
                } onCancel: {
                    remoteClosure.cancel()
                }
            }
            guard closedAt >= revocationStarted else {
                throw LiveGatewayTestError.socketClosedBeforeRevocation
            }

            // The provider still contains the in-memory credential, so an
            // unauthenticated result here can only come from the gateway's
            // HTTP 401 response after durable revocation.
            do {
                _ = try await Self.withTimeout {
                    try await deviceClient.currentDevice()
                }
                throw LiveGatewayTestError.revokedCredentialAccepted
            } catch let failure as NativeGatewayFailure {
                guard case .unauthenticated(operation: .currentDevice, reason: _) = failure else {
                    throw LiveGatewayTestError.unexpectedCurrentDeviceResult
                }
            }
        } catch {
            remoteClosure.cancel()
            await socketProbe.close()
            _ = try? await remoteClosure.value
            throw error
        }
        await socketProbe.close()
    }

    private static func exerciseLiveContract(
        _ configuration: LiveGatewayConfiguration
    ) async throws -> LiveGatewayEvidence {
        let credentialProvider = configuration.credentialProvider
        let gatewayClient = GatewayClient(
            baseURL: configuration.gatewayURL,
            credentialProvider: credentialProvider
        )
        let deviceClient = NativeDeviceClient(
            baseURL: configuration.gatewayURL,
            credentialProvider: credentialProvider
        )
        let streamClient = EventStreamClient(
            baseURL: configuration.gatewayURL,
            credentialProvider: credentialProvider
        )

        let hello = try await withTimeout {
            try await gatewayClient.hello()
        }
        XCTAssertEqual(hello.protocolVersion, RemoteGatewayProtocol.version)
        XCTAssertEqual(
            hello.minimumSupportedProtocolVersion,
            RemoteGatewayProtocol.minimumSupportedVersion
        )
        XCTAssertTrue(hello.capabilities.contains(.nativeBearerPairing))
        XCTAssertTrue(hello.capabilities.contains(.conversationBackwardPaging))

        let currentDevice = try await withTimeout {
            try await deviceClient.currentDevice()
        }
        XCTAssertEqual(currentDevice.protocolVersion, RemoteGatewayProtocol.version)
        XCTAssertFalse(currentDevice.device.name.isEmpty)
        XCTAssertTrue(currentDevice.device.scopes.contains(.read))

        let sessions = try await withTimeout {
            try await gatewayClient.sessions()
        }
        if let conversation = sessions.conversations.max(by: {
            $0.latestSequence < $1.latestSequence
        }) {
            try await exercisePaging(conversation, gatewayClient: gatewayClient)
        }

        _ = try await openReadAndClose(streamClient)

        // A second successful open after the explicit close proves the live
        // transport is reusable rather than only validating one connection.
        _ = try await openReadAndClose(streamClient)

        return LiveGatewayEvidence(deviceID: currentDevice.device.id)
    }

    private static func exercisePaging(
        _ conversation: CompatibleConversationSummary,
        gatewayClient: GatewayClient
    ) async throws {
        let pageLimit = 25
        let tailResponse = try await withTimeout {
            try await gatewayClient.events(RemoteGatewayEventsRequest(
                conversationID: conversation.conversationID,
                limit: pageLimit,
                backward: .latest
            ))
        }
        guard case .page(let tailPage) = tailResponse else {
            throw LiveGatewayTestError.unexpectedPagingResult
        }
        XCTAssertEqual(tailPage.conversationID, conversation.conversationID)
        XCTAssertLessThanOrEqual(tailPage.events.count, pageLimit)

        guard let firstSequence = tailPage.events.first?.sequence,
              let firstAvailableSequence = tailPage.firstAvailableSequence,
              firstSequence > firstAvailableSequence else {
            return
        }
        let olderResponse = try await withTimeout {
            try await gatewayClient.events(RemoteGatewayEventsRequest(
                conversationID: conversation.conversationID,
                limit: pageLimit,
                backward: .before(ConversationEventBackwardCursor(
                    projectionRunID: tailPage.projectionRunID,
                    projectionGeneration: tailPage.projectionGeneration,
                    beforeSequence: firstSequence
                ))
            ))
        }
        guard case .page(let olderPage) = olderResponse else {
            throw LiveGatewayTestError.unexpectedPagingResult
        }
        XCTAssertEqual(olderPage.conversationID, conversation.conversationID)
        XCTAssertLessThanOrEqual(olderPage.events.count, pageLimit)
        XCTAssertTrue(olderPage.events.allSatisfy { $0.sequence < firstSequence })
    }

    private static func openReadAndClose(
        _ streamClient: EventStreamClient
    ) async throws -> CompatibleSessionListSnapshot {
        let subscription = try await withTimeout {
            try await streamClient.connect()
        }
        do {
            let snapshot = try await withTimeout {
                try await nextSessionList(from: subscription)
            }
            await subscription.close()
            return snapshot
        } catch {
            await subscription.close()
            throw error
        }
    }

    private static func nextSessionList(
        from subscription: any EventStreamSubscriptionProtocol
    ) async throws -> CompatibleSessionListSnapshot {
        // The current host sends session_list first. Keep the read bounded in
        // count as well as time so future ignorable messages cannot spin.
        for _ in 0..<8 {
            switch try await subscription.nextMessage() {
            case .sessionList(let snapshot):
                return snapshot
            case .conversationEvents, .resnapshotRequired, .ignoredUnknown:
                continue
            }
        }
        throw LiveGatewayTestError.missingSessionList
    }

    private static func liveConfiguration() throws -> LiveGatewayConfiguration {
        let environment = ProcessInfo.processInfo.environment
        guard let rawGatewayURL = environment["TOASTTY_MOBILE_LIVE_GATEWAY_URL"],
              rawGatewayURL.isEmpty == false else {
            throw XCTSkip("Set TOASTTY_MOBILE_LIVE_GATEWAY_URL to run the live gateway suite.")
        }
        guard let credential = environment["TOASTTY_MOBILE_LIVE_GATEWAY_CREDENTIAL"],
              credential.isEmpty == false else {
            throw XCTSkip("Set TOASTTY_MOBILE_LIVE_GATEWAY_CREDENTIAL to run the live gateway suite.")
        }

        let gatewayURL: URL
        do {
            gatewayURL = try PairingInputParser.canonicalGatewayURL(rawGatewayURL)
        } catch {
            throw LiveGatewayTestError.invalidGatewayURL
        }
        guard gatewayURL.absoluteString == rawGatewayURL,
              PairingInputParser.isValidCredentialMaterial(credential) else {
            throw LiveGatewayTestError.invalidLiveConfiguration
        }
        return LiveGatewayConfiguration(gatewayURL: gatewayURL, credential: credential)
    }

    private static var destructiveRevocationIsEnabled: Bool {
        ProcessInfo.processInfo.environment["TOASTTY_MOBILE_LIVE_ALLOW_DESTRUCTIVE_REVOCATION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
    }

    private static func withTimeout<Value: Sendable>(
        _ duration: Duration = .seconds(15),
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await ContinuousClock().sleep(for: duration)
                throw LiveGatewayTestError.timedOut
            }
            guard let value = try await group.next() else {
                throw LiveGatewayTestError.timedOut
            }
            group.cancelAll()
            return value
        }
    }
}

/// Owns the existential subscription across the destructive test's concurrent
/// revoke/read operations. Keeping that transfer behind an actor also avoids a
/// Swift 6 region-isolation compiler limitation around task-captured existentials.
private actor LiveGatewaySocketProbe {
    private let subscription: any EventStreamSubscriptionProtocol

    init(subscription: any EventStreamSubscriptionProtocol) {
        self.subscription = subscription
    }

    func nextSessionList() async throws -> CompatibleSessionListSnapshot {
        for _ in 0..<8 {
            switch try await subscription.nextMessage() {
            case .sessionList(let snapshot):
                return snapshot
            case .conversationEvents, .resnapshotRequired, .ignoredUnknown:
                continue
            }
        }
        throw LiveGatewayTestError.missingSessionList
    }

    func waitForRemoteClosure() async throws -> ContinuousClock.Instant {
        do {
            while true {
                _ = try await subscription.nextMessage()
            }
        } catch is CancellationError {
            throw LiveGatewayTestError.socketWaitCancelled
        } catch let failure as GatewayFailure {
            guard case .network = failure else {
                throw LiveGatewayTestError.unexpectedSocketTermination
            }
            return ContinuousClock().now
        } catch {
            throw LiveGatewayTestError.unexpectedSocketTermination
        }
    }

    func close() async {
        await subscription.close()
    }
}

private struct LiveGatewayConfiguration: Sendable {
    let gatewayURL: URL
    private let credential: String

    init(gatewayURL: URL, credential: String) {
        self.gatewayURL = gatewayURL
        self.credential = credential
    }

    var credentialProvider: StaticGatewayCredentialProvider {
        StaticGatewayCredentialProvider(.bearer(token: credential))
    }
}

private struct LiveGatewayEvidence: Sendable {
    let deviceID: UUID
}

private enum LiveGatewayTestError: Error, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case invalidGatewayURL
    case invalidLiveConfiguration
    case missingSessionList
    case revokedCredentialAccepted
    case socketClosedBeforeRevocation
    case socketWaitCancelled
    case timedOut
    case unexpectedCurrentDeviceResult
    case unexpectedPagingResult
    case unexpectedSocketTermination

    var description: String { "<redacted live gateway test failure>" }
    var debugDescription: String { description }
}
