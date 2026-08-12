import Foundation
import RemoteProtocol
@testable import ToasttyMobileDomain
import XCTest

final class LiveGatewayIntegrationTests: XCTestCase {
    func testRemoteLiveEnvironmentForwardingAdmission() async throws {
        guard ProcessInfo.processInfo.environment["TOASTTY_MOBILE_LIVE_FORWARDING_PROBE"] == "1" else {
            throw XCTSkip("The remote live-environment forwarding probe was not requested.")
        }

        // Configuration validation is intentionally the assertion. Its errors
        // are categorical and never include the URL, hostname, or credential.
        _ = try await Self.liveConfiguration()
    }

    func testLiveGatewayContractPagingCloseAndReconnect() async throws {
        let configuration = try await Self.liveConfiguration()
        if configuration.allowDestructiveRevocation {
            throw XCTSkip("The destructive live test runs the contract checks before revoking the credential.")
        }

        _ = try await Self.exerciseLiveContract(configuration)
    }

    func testDestructiveRevocationClosesSocketAndRejectsCurrentDevice() async throws {
        let configuration = try await Self.liveConfiguration()
        guard configuration.allowDestructiveRevocation else {
            throw XCTSkip(
                "Set TOASTTY_MOBILE_LIVE_ALLOW_DESTRUCTIVE_REVOCATION=true to run this credential-revoking test."
            )
        }
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

    private static func liveConfiguration() async throws -> LiveGatewayConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let rawGatewayURL: String
        let credential: String
        let allowDestructiveRevocation: Bool
        let hasBrokerConfiguration = environment["TOASTTY_MOBILE_LIVE_BROKER_PORT"] != nil
            || environment["TOASTTY_MOBILE_LIVE_BROKER_TOKEN"] != nil
        let hasEnvironmentConfiguration = environment["TOASTTY_MOBILE_LIVE_GATEWAY_URL"] != nil
            || environment["TOASTTY_MOBILE_LIVE_GATEWAY_CREDENTIAL"] != nil
        if hasBrokerConfiguration {
            let brokerConfiguration = try await brokerConfiguration(environment: environment)
            rawGatewayURL = brokerConfiguration.gatewayURL
            credential = brokerConfiguration.credential
            allowDestructiveRevocation = brokerConfiguration.allowDestructiveRevocation
        } else if let environmentGatewayURL = environment["TOASTTY_MOBILE_LIVE_GATEWAY_URL"],
                  environmentGatewayURL.isEmpty == false,
                  let environmentCredential = environment["TOASTTY_MOBILE_LIVE_GATEWAY_CREDENTIAL"],
                  environmentCredential.isEmpty == false {
            rawGatewayURL = environmentGatewayURL
            credential = environmentCredential
            allowDestructiveRevocation = Self.environmentAllowsDestructiveRevocation(environment)
        } else if hasEnvironmentConfiguration {
            throw LiveGatewayTestError.invalidLiveConfiguration
        } else {
            throw XCTSkip("Set the live gateway inputs to run the live gateway suite.")
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
        return LiveGatewayConfiguration(
            gatewayURL: gatewayURL,
            credential: credential,
            allowDestructiveRevocation: allowDestructiveRevocation
        )
    }

    private static func brokerConfiguration(
        environment: [String: String]
    ) async throws -> LiveGatewayBrokerConfiguration {
        guard let rawPort = environment["TOASTTY_MOBILE_LIVE_BROKER_PORT"],
              let port = UInt16(rawPort), port > 0,
              let token = environment["TOASTTY_MOBILE_LIVE_BROKER_TOKEN"],
              token.utf8.count == 43,
              token.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 45, 48...57, 65...90, 95, 97...122: true
                  default: false
                  }
              }),
              let brokerURL = URL(string: "http://127.0.0.1:\(port)/v1/config") else {
            throw LiveGatewayTestError.invalidLiveConfiguration
        }

        let request: URLRequest = {
            var value = URLRequest(url: brokerURL)
            value.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            value.timeoutInterval = 5
            value.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return value
        }()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await withTimeout(.seconds(5)) {
                try await session.data(for: request)
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  data.count <= 512 else {
                throw LiveGatewayTestError.invalidLiveConfiguration
            }
            return try JSONDecoder().decode(LiveGatewayBrokerConfiguration.self, from: data)
        } catch {
            throw LiveGatewayTestError.invalidLiveConfiguration
        }
    }

    private static func environmentAllowsDestructiveRevocation(
        _ environment: [String: String]
    ) -> Bool {
        environment["TOASTTY_MOBILE_LIVE_ALLOW_DESTRUCTIVE_REVOCATION"]?
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
    let allowDestructiveRevocation: Bool

    init(gatewayURL: URL, credential: String, allowDestructiveRevocation: Bool) {
        self.gatewayURL = gatewayURL
        self.credential = credential
        self.allowDestructiveRevocation = allowDestructiveRevocation
    }

    var credentialProvider: StaticGatewayCredentialProvider {
        StaticGatewayCredentialProvider(.bearer(token: credential))
    }
}

private struct LiveGatewayBrokerConfiguration: Decodable, Sendable {
    let gatewayURL: String
    let credential: String
    let allowDestructiveRevocation: Bool
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
