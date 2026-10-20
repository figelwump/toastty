import Foundation
import RemoteProtocol
import UserNotifications
import XCTest
@testable import ToasttyMobileApp

@MainActor
final class ToasttyPushReceiverDiagnosticsTests: XCTestCase {
    func testDeliveredScanClassifiesMalformedAndUnknownPayloads() throws {
        var unknown = try envelope(verification())
        var object = try XCTUnwrap(unknown["toastty"] as? [String: Any])
        object["kind"] = "future-kind"
        unknown["toastty"] = object
        let notifications = try [
            Self.makeNotification(userInfo: [:]),
            Self.makeNotification(userInfo: ["toastty": ["invalid": true]]),
            Self.makeNotification(userInfo: unknown),
        ]
        let result = classify(notifications)

        XCTAssertTrue(result.payloads.isEmpty)
        XCTAssertEqual(result.snapshot.raw, 3)
        XCTAssertEqual(result.snapshot.malformed, 3)
        XCTAssertEqual(result.snapshot.verification, 0)
        XCTAssertEqual(result.snapshot.session, 0)
    }

    func testSenderVerificationEnvelopePassesActualReceiverParser() throws {
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "push-verification", withExtension: "json", subdirectory: "v1"))
        let senderEnvelope = try Data(contentsOf: fixtureURL)
        let userInfo = try XCTUnwrap(JSONSerialization.jsonObject(with: senderEnvelope) as? [String: Any])
        let payload = try XCTUnwrap(ToasttyPushNotificationBridge.payload(userInfo))
        let result = classify([try Self.makeNotification(userInfo: userInfo)])

        XCTAssertEqual(payload.kind, .verification)
        XCTAssertEqual(result.payloads, [payload])
        XCTAssertEqual(result.snapshot.raw, 1)
        XCTAssertEqual(result.snapshot.verification, 1)
        XCTAssertEqual(result.snapshot.malformed, 0)
    }

    func testDeliveredClientFetchesOnceAndRecordsRecoveryBeforeReturningPayloads() async throws {
        let proof = verification()
        let notifications = try [
            Self.makeNotification(userInfo: envelope(proof)),
            Self.makeNotification(userInfo: ["toastty": ["invalid": true]]),
        ]
        let bridge = ToasttyPushNotificationBridge()
        var fetchCount = 0
        let client = ToasttySystemPushNotificationClient(bridge: bridge, deliveredNotifications: {
            fetchCount += 1
            return fetchCount == 1 ? notifications : []
        })
        let context = ToasttyPushRecoveryContext(pendingRegistrationID: proof.registrationID,
            pairingID: proof.pairingID, referenceAt: nil, referenceKind: .none)

        let firstPayloads = await client.deliveredPayloads(context: context)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(firstPayloads, [proof])
        let first = try XCTUnwrap(bridge.receiverDiagnostics.snapshot.firstRecovery)
        XCTAssertEqual(bridge.receiverDiagnostics.snapshot.latestRecovery, first)
        XCTAssertEqual(first.raw, 2)
        XCTAssertEqual(first.verification, 1)
        XCTAssertEqual(first.malformed, 1)
        XCTAssertEqual(first.matchingBoth, 1)

        let laterPayloads = await client.deliveredPayloads(context: context)
        XCTAssertEqual(fetchCount, 2)
        XCTAssertTrue(laterPayloads.isEmpty)
        XCTAssertEqual(bridge.receiverDiagnostics.snapshot.firstRecovery, first)
        XCTAssertEqual(bridge.receiverDiagnostics.snapshot.latestRecovery?.raw, 0)
        XCTAssertEqual(bridge.receiverDiagnostics.snapshot.latestRecovery?.verification, 0)
    }

    func testSettingsCaptureKeepsAuthorizationAndPresentationCategories() {
        let authorizationCases: [(UNAuthorizationStatus, ToasttyPushReceiverSnapshot.Settings.Authorization)] = [
            (.notDetermined, .notDetermined),
            (.denied, .denied),
            (.authorized, .authorized),
            (.provisional, .provisional),
            (.ephemeral, .ephemeral),
        ]
        for (status, expected) in authorizationCases {
            let settings = ToasttyPushReceiverSnapshot.Settings(authorizationStatus: status,
                alert: .enabled, lockScreen: .disabled, notificationCenter: .notSupported)
            XCTAssertEqual(settings.authorization, expected)
            XCTAssertEqual(settings.alert, .enabled)
            XCTAssertEqual(settings.lockScreen, .disabled)
            XCTAssertEqual(settings.notificationCenter, .notSupported)
        }
    }

    func testRecoveryCountsKindsIdentityAndDatesFromSameDeliveredArray() throws {
        let registrationID = UUID()
        let pairingID = UUID()
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        let before = reference.addingTimeInterval(-1)
        let after = reference.addingTimeInterval(1)
        let payloads = [
            verification(registrationID: registrationID, pairingID: pairingID),
            verification(registrationID: registrationID),
            verification(pairingID: pairingID),
            session(registrationID: registrationID, pairingID: pairingID),
            session(),
        ]
        var notifications: [UNNotification] = []
        for (payload, date) in zip(payloads, [before, reference, after, after, before]) {
            notifications.append(try Self.makeNotification(userInfo: envelope(payload), date: date))
        }
        notifications.append(try Self.makeNotification(userInfo: ["toastty": ["invalid": true]], date: before))
        notifications.append(try Self.makeNotification(userInfo: ["toastty": ["kind": "future-kind"]], date: after))
        let capturedAt = after.addingTimeInterval(10)
        let result = ToasttySystemPushNotificationClient.classifyDelivered(notifications,
            context: .init(pendingRegistrationID: registrationID, pairingID: pairingID,
                           referenceAt: reference, referenceKind: .pendingCreated), capturedAt: capturedAt)
        let snapshot = result.snapshot

        XCTAssertEqual(result.payloads, payloads)
        XCTAssertEqual(snapshot.capturedAt, capturedAt)
        XCTAssertEqual(snapshot.referenceAt, reference)
        XCTAssertEqual(snapshot.referenceKind, .pendingCreated)
        XCTAssertTrue(snapshot.hasPendingRegistration)
        XCTAssertTrue(snapshot.hasPairing)
        XCTAssertEqual(snapshot.raw, 7)
        XCTAssertEqual(snapshot.verification, 3)
        XCTAssertEqual(snapshot.session, 2)
        XCTAssertEqual(snapshot.malformed, 2)
        XCTAssertEqual(snapshot.matchingRegistration, 2)
        XCTAssertEqual(snapshot.matchingPairing, 2)
        XCTAssertEqual(snapshot.matchingBoth, 1)
        XCTAssertEqual(snapshot.beforeReference, 3)
        XCTAssertEqual(snapshot.atOrAfterReference, 4)
        XCTAssertEqual(snapshot.withoutReference, 0)
        XCTAssertEqual(snapshot.verificationAtOrAfterReference, 2)
    }

    func testRecoveryWithoutReferenceDoesNotGuessNotificationAgeOrIdentity() throws {
        let notifications = try [
            Self.makeNotification(userInfo: envelope(verification()), date: Date(timeIntervalSince1970: 1)),
            Self.makeNotification(userInfo: [:], date: Date(timeIntervalSince1970: 2)),
        ]
        let result = classify(notifications)
        let snapshot = result.snapshot

        XCTAssertNil(snapshot.referenceAt)
        XCTAssertEqual(snapshot.referenceKind, .none)
        XCTAssertFalse(snapshot.hasPendingRegistration)
        XCTAssertFalse(snapshot.hasPairing)
        XCTAssertEqual(snapshot.matchingRegistration, 0)
        XCTAssertEqual(snapshot.matchingPairing, 0)
        XCTAssertEqual(snapshot.matchingBoth, 0)
        XCTAssertEqual(snapshot.beforeReference, 0)
        XCTAssertEqual(snapshot.atOrAfterReference, 0)
        XCTAssertEqual(snapshot.withoutReference, 2)
        XCTAssertEqual(snapshot.verificationAtOrAfterReference, 0)
    }

    func testDelegateCaptureReportsIdentityAndActualCallbackSelectors() {
        let expected = ToasttyMobileApplicationDelegate()
        let expectedSnapshot = ToasttyPushReceiverSnapshot.Delegate.capture(actual: expected, expected: expected)
        XCTAssertEqual(expectedSnapshot.identity, .expected)
        XCTAssertTrue(expectedSnapshot.foregroundSelector)
        XCTAssertTrue(expectedSnapshot.responseSelector)

        let absent = ToasttyPushReceiverSnapshot.Delegate.capture(actual: nil, expected: expected)
        XCTAssertEqual(absent.identity, .none)
        XCTAssertFalse(absent.foregroundSelector)
        XCTAssertFalse(absent.responseSelector)

        let other = EmptyNotificationDelegate()
        let replaced = ToasttyPushReceiverSnapshot.Delegate.capture(actual: other, expected: expected)
        XCTAssertEqual(replaced.identity, .other)
        XCTAssertFalse(replaced.foregroundSelector)
        XCTAssertFalse(replaced.responseSelector)
    }

    func testCallbackCountsSurviveRecorderAttachingAfterCallbacks() {
        let diagnostics = ToasttyPushReceiverDiagnostics()
        diagnostics.beginCallback(.foreground)
        diagnostics.decodedCallback(.foreground, payload: verification())
        diagnostics.beginCallback(.response)
        diagnostics.decodedCallback(.response, payload: nil)
        diagnostics.beginCallback(.response)
        diagnostics.decodedCallback(.response, payload: nil, ignored: true)
        let beforeAttachment = diagnostics.snapshot
        let recorder = ReceiverSnapshotRecorder()
        diagnostics.installHandler { recorder.append($0) }

        XCTAssertEqual(recorder.snapshots.last, beforeAttachment)
        XCTAssertEqual(beforeAttachment.foreground.entered, 1)
        XCTAssertEqual(beforeAttachment.foreground.verification, 1)
        XCTAssertEqual(beforeAttachment.foreground.session, 0)
        XCTAssertEqual(beforeAttachment.foreground.malformed, 0)
        XCTAssertEqual(beforeAttachment.response.entered, 2)
        XCTAssertEqual(beforeAttachment.response.malformed, 1)
        XCTAssertEqual(beforeAttachment.response.ignored, 1)
        diagnostics.beginCallback(.response)
        diagnostics.decodedCallback(.response, payload: session())
        XCTAssertEqual(recorder.snapshots.last?.response.entered, 3)
        XCTAssertEqual(recorder.snapshots.last?.response.session, 1)
        XCTAssertGreaterThan(diagnostics.snapshot.sequence, beforeAttachment.sequence)
    }

    func testActualDelegateCountsForegroundRoutingAndMalformedPayload() async throws {
        let delegate = ToasttyMobileApplicationDelegate()
        let payload = verification()
        var routed: [RemotePushPayload] = []
        delegate.pushBridge.onForeground = { received in
            routed.append(received)
            return false
        }
        let presentation = try await Self.foregroundPresentation(payload: payload, delegate: delegate)
        let invalidPresentation = try await Self.foregroundPresentation(payload: nil, delegate: delegate)

        XCTAssertEqual(routed, [payload])
        XCTAssertEqual(presentation, [.banner, .list, .sound])
        XCTAssertEqual(invalidPresentation, [])
        let counts = delegate.receiverDiagnostics.snapshot.foreground
        XCTAssertEqual(counts.entered, 2)
        XCTAssertEqual(counts.verification, 1)
        XCTAssertEqual(counts.session, 0)
        XCTAssertEqual(counts.malformed, 1)
        XCTAssertEqual(counts.ignored, 0)
    }

    func testActualDelegateCountsResponsesBeforeMainActorRoutingCompletes() async throws {
        let delegate = ToasttyMobileApplicationDelegate()
        let payload = session()
        var routed: [RemotePushPayload] = []
        delegate.pushBridge.onTap = { routed.append($0) }
        for (action, userInfo) in [
            (UNNotificationDefaultActionIdentifier, try envelope(payload)),
            (UNNotificationDefaultActionIdentifier, ["toastty": ["invalid": true]]),
            (UNNotificationDismissActionIdentifier, try envelope(payload)),
        ] {
            let response = try makeResponse(action: action, userInfo: userInfo)
            let completed = expectation(description: "Response completed")
            let enteredBefore = delegate.receiverDiagnostics.snapshot.response.entered
            delegate.userNotificationCenter(.current(), didReceive: response) {
                XCTAssertTrue(Thread.isMainThread)
                completed.fulfill()
            }
            XCTAssertEqual(delegate.receiverDiagnostics.snapshot.response.entered, enteredBefore + 1)
            await fulfillment(of: [completed], timeout: 3)
        }

        XCTAssertEqual(routed, [payload])
        let counts = delegate.receiverDiagnostics.snapshot.response
        XCTAssertEqual(counts.entered, 3)
        XCTAssertEqual(counts.verification, 0)
        XCTAssertEqual(counts.session, 1)
        XCTAssertEqual(counts.malformed, 1)
        XCTAssertEqual(counts.ignored, 1)
    }

    func testFirstRecoveryRemainsAfterLaterRecoveryAndCallback() throws {
        let first = classify([try Self.makeNotification(userInfo: envelope(verification()))]).snapshot
        let latest = classify([]).snapshot
        let diagnostics = ToasttyPushReceiverDiagnostics()
        diagnostics.recordRecovery(first)
        diagnostics.recordRecovery(latest)
        diagnostics.beginCallback(.foreground)

        XCTAssertEqual(diagnostics.snapshot.firstRecovery, first)
        XCTAssertEqual(diagnostics.snapshot.latestRecovery, latest)
    }

    func testSnapshotJSONContainsOnlyCountsSettingsAndDelegateState() throws {
        let registrationID = UUID()
        let pairingID = UUID()
        let nonce = String(repeating: "A", count: 43)
        let payload = verification(registrationID: registrationID, pairingID: pairingID)
        let rawTitle = "private-session-title"
        let token = "private-device-token"
        var userInfo = try envelope(payload)
        userInfo["aps"] = ["alert": ["title": rawTitle, "body": token]]
        let recovery = ToasttySystemPushNotificationClient.classifyDelivered(
            [try Self.makeNotification(userInfo: userInfo)],
            context: .init(pendingRegistrationID: registrationID, pairingID: pairingID,
                           referenceAt: Date(timeIntervalSince1970: 1), referenceKind: .requestStarted),
            capturedAt: Date(timeIntervalSince1970: 2)).snapshot
        let diagnostics = ToasttyPushReceiverDiagnostics()
        diagnostics.recordRecovery(recovery)
        diagnostics.beginCallback(.foreground)
        diagnostics.decodedCallback(.foreground, payload: payload)
        let expected = ToasttyMobileApplicationDelegate()
        diagnostics.recordEnvironment(settings: .init(authorizationStatus: .authorized,
            alert: .enabled, lockScreen: .disabled, notificationCenter: .enabled),
            delegate: .capture(actual: expected, expected: expected))
        let snapshot = diagnostics.snapshot
        let data = try JSONEncoder().encode(snapshot)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(try JSONDecoder().decode(ToasttyPushReceiverSnapshot.self, from: data), snapshot)
        for secret in [registrationID.uuidString, pairingID.uuidString, nonce, rawTitle, token,
                       "registrationID", "pairingID", "nonce", "userInfo", "deviceToken"] {
            XCTAssertFalse(json.localizedCaseInsensitiveContains(secret), "Snapshot exposed \(secret)")
        }
        XCTAssertEqual(snapshot.settings?.authorization, .authorized)
        XCTAssertEqual(snapshot.settings?.alert, .enabled)
        XCTAssertEqual(snapshot.settings?.lockScreen, .disabled)
        XCTAssertEqual(snapshot.settings?.notificationCenter, .enabled)
        XCTAssertEqual(snapshot.delegate?.identity, .expected)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let foreground = try XCTUnwrap(object["foreground"] as? [String: Any])
        XCTAssertEqual(foreground["entered"] as? Int, 1)
        XCTAssertEqual(foreground["verification"] as? Int, 1)
        let encodedRecovery = try XCTUnwrap(object["firstRecovery"] as? [String: Any])
        XCTAssertEqual(encodedRecovery["raw"] as? Int, 1)
        XCTAssertEqual(encodedRecovery["matchingBoth"] as? Int, 1)
    }

    private func classify(_ notifications: [UNNotification])
        -> (payloads: [RemotePushPayload], snapshot: ToasttyPushReceiverSnapshot.Recovery) {
        ToasttySystemPushNotificationClient.classifyDelivered(notifications,
            context: .init(pendingRegistrationID: nil, pairingID: nil, referenceAt: nil, referenceKind: .none),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_100))
    }

    private func verification(registrationID: UUID = UUID(), pairingID: UUID = UUID()) -> RemotePushPayload {
        RemotePushPayload(kind: .verification, registrationID: registrationID, pairingID: pairingID,
                          nonce: String(repeating: "A", count: 43))
    }

    private func session(registrationID: UUID = UUID(), pairingID: UUID = UUID()) -> RemotePushPayload {
        RemotePushPayload(kind: .session, registrationID: registrationID, pairingID: pairingID,
                          conversationID: RemoteConversationID(rawValue: UUID()), eventID: UUID())
    }

    private func envelope(_ payload: RemotePushPayload) throws -> [String: Any] {
        ["toastty": try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))]
    }

    private func makeResponse(action: String, userInfo: [AnyHashable: Any]) throws -> UNNotificationResponse {
        let notification = try Self.makeNotification(userInfo: userInfo)
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        archive.encode(notification, forKey: "notification")
        archive.encode(action, forKey: "actionIdentifier")
        archive.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: archive.encodedData)
        let response = try XCTUnwrap(UNNotificationResponse(coder: decoder))
        XCTAssertEqual(response.actionIdentifier, action)
        return response
    }

    nonisolated private static func foregroundPresentation(payload: RemotePushPayload?,
        delegate: ToasttyMobileApplicationDelegate) async throws -> UNNotificationPresentationOptions {
        let userInfo: [AnyHashable: Any]
        if let payload {
            userInfo = ["toastty": try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))]
        } else {
            userInfo = ["toastty": ["invalid": true]]
        }
        let notification = try Self.makeNotification(userInfo: userInfo)
        return await delegate.userNotificationCenter(.current(), willPresent: notification)
    }

    nonisolated private static func makeNotification(userInfo: [AnyHashable: Any], date: Date = Date()) throws -> UNNotification {
        let content = UNMutableNotificationContent()
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        // Use the same NSSecureCoding boundary as the delegate tests. Apple
        // does not provide a public initializer for delivered notifications.
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        archive.encode(request, forKey: "request")
        archive.encode(date, forKey: "date")
        archive.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: archive.encodedData)
        let notification = try XCTUnwrap(UNNotification(coder: decoder))
        XCTAssertEqual(notification.date, date)
        XCTAssertEqual(notification.request, request)
        return notification
    }
}

private final class EmptyNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {}

private final class ReceiverSnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ToasttyPushReceiverSnapshot] = []
    var snapshots: [ToasttyPushReceiverSnapshot] { lock.withLock { stored } }
    func append(_ snapshot: ToasttyPushReceiverSnapshot) { lock.withLock { stored.append(snapshot) } }
}
