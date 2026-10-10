import Foundation
import RemoteProtocol
import UserNotifications
import XCTest
@testable import ToasttyMobileApp

@MainActor
final class ToasttyPushNotificationDelegateTests: XCTestCase {
    // Exercise the system delegate boundary: completion must run once on the
    // main thread after routing, including ignored actions and invalid payloads.
    func testBackgroundCallbackRoutesBeforeCompletingOnMainThread() async {
        let delegate = ToasttyMobileApplicationDelegate()
        let payload = sessionPayload()
        let recorder = CallbackRecorder()
        delegate.pushBridge.onTap = { received in
            XCTAssertEqual(received, payload)
            XCTAssertTrue(Thread.isMainThread)
            recorder.record("routed")
        }
        await deliver(action: UNNotificationDefaultActionIdentifier, payload: payload,
                          to: delegate, recorder: recorder)

        XCTAssertEqual(recorder.events, ["routed", "completed"])
    }

    func testIgnoredActionsAndInvalidPayloadStillCompleteOnceOnMainThread() async {
        let delegate = ToasttyMobileApplicationDelegate()
        delegate.pushBridge.onTap = { _ in XCTFail("Ignored response must not route") }
        for (action, payload) in [
            (UNNotificationDismissActionIdentifier, sessionPayload()),
            ("unrecognized-action", sessionPayload()),
            (UNNotificationDefaultActionIdentifier, nil),
        ] {
            let recorder = CallbackRecorder()
            await deliver(action: action, payload: payload, to: delegate, recorder: recorder)

            XCTAssertEqual(recorder.events, ["completed"])
        }
    }

    func testTapBeforeSessionSetupCompletesAndRemainsBuffered() async {
        let delegate = ToasttyMobileApplicationDelegate()
        let payload = sessionPayload()
        let recorder = CallbackRecorder()
        await deliver(action: UNNotificationDefaultActionIdentifier, payload: payload,
                          to: delegate, recorder: recorder)

        var received: [RemotePushPayload] = []
        delegate.pushBridge.onTap = { received.append($0) }
        XCTAssertEqual(received, [payload])
        XCTAssertEqual(recorder.events, ["completed"])
    }

    private func deliver(action: String, payload: RemotePushPayload?,
                         to delegate: ToasttyMobileApplicationDelegate,
                         recorder: CallbackRecorder) async {
        let completed = expectation(description: "Notification response completed")
        DispatchQueue.global().async {
            XCTAssertFalse(Thread.isMainThread)
            do {
                let response = try Self.makeResponse(action: action, payload: payload)
                let systemDelegate: any UNUserNotificationCenterDelegate = delegate
                systemDelegate.userNotificationCenter?(.current(), didReceive: response) {
                    XCTAssertTrue(Thread.isMainThread)
                    recorder.record("completed")
                    completed.fulfill()
                }
            } catch {
                XCTFail("Notification response fixture failed: \(error)")
                completed.fulfill()
            }
        }
        await fulfillment(of: [completed], timeout: 3)
    }

    private func sessionPayload() -> RemotePushPayload {
        RemotePushPayload(kind: .session, registrationID: UUID(), pairingID: UUID(),
            conversationID: RemoteConversationID(rawValue: UUID()), eventID: UUID())
    }

    nonisolated private static func makeResponse(action: String, payload: RemotePushPayload?) throws -> UNNotificationResponse {
        let content = UNMutableNotificationContent()
        if let payload {
            content.userInfo = ["toastty": try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))]
        } else {
            content.userInfo = ["toastty": ["invalid": true]]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        // UserNotifications exposes these values through NSSecureCoding but
        // has no public response or delivered-notification initializer.
        let notificationArchive = NSKeyedArchiver(requiringSecureCoding: true)
        notificationArchive.encode(request, forKey: "request")
        notificationArchive.encode(Date(), forKey: "date")
        notificationArchive.finishEncoding()
        let notificationDecoder = try NSKeyedUnarchiver(forReadingFrom: notificationArchive.encodedData)
        let notification = try XCTUnwrap(UNNotification(coder: notificationDecoder))

        let responseArchive = NSKeyedArchiver(requiringSecureCoding: true)
        responseArchive.encode(notification, forKey: "notification")
        responseArchive.encode(action, forKey: "actionIdentifier")
        responseArchive.finishEncoding()
        let responseDecoder = try NSKeyedUnarchiver(forReadingFrom: responseArchive.encodedData)
        let response = try XCTUnwrap(UNNotificationResponse(coder: responseDecoder))
        XCTAssertEqual(response.actionIdentifier, action)
        XCTAssertEqual(ToasttyPushNotificationBridge.payload(response.notification.request.content.userInfo), payload)
        return response
    }
}

private final class CallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []

    var events: [String] { lock.withLock { recordedEvents } }

    func record(_ event: String) { lock.withLock { recordedEvents.append(event) } }
}
