@testable import ToasttyApp
import CoreState
import UserNotifications
import XCTest

@MainActor
final class SystemNotificationSenderTests: XCTestCase {
    override func tearDown() {
        SystemNotificationSender.resetForTesting()
        super.tearDown()
    }

    func testSendRequestsAuthorizationAndDeliversNotificationWhenPermissionGranted() async {
        var requestAuthorizationCallCount = 0
        var deliveredRequest: UNNotificationRequest?

        SystemNotificationSender.resetForTesting(
            dependencies: .init(
                notificationAuthorizationStatus: { .notDetermined },
                requestAuthorization: {
                    requestAuthorizationCallCount += 1
                    return true
                },
                addRequest: { request in
                    deliveredRequest = request
                },
                scheduleAccessGuidance: { _ in
                    XCTFail("Did not expect notification guidance for an authorized delivery")
                }
            )
        )

        let workspaceID = UUID()
        let panelID = UUID()

        await SystemNotificationSender.send(
            title: "Build Finished",
            body: "Toastty finished running the command.",
            workspaceID: workspaceID,
            panelID: panelID
        )

        XCTAssertEqual(requestAuthorizationCallCount, 1)
        XCTAssertEqual(deliveredRequest?.content.title, "Build Finished")
        XCTAssertEqual(deliveredRequest?.content.body, "Toastty finished running the command.")
        XCTAssertEqual(
            deliveredRequest?.content.userInfo[DesktopNotificationUserInfoKey.workspaceID] as? String,
            workspaceID.uuidString
        )
        XCTAssertEqual(
            deliveredRequest?.content.userInfo[DesktopNotificationUserInfoKey.panelID] as? String,
            panelID.uuidString
        )
    }

    func testSendSkipsDeliveryAndSchedulesDeniedGuidanceWhenAuthorizationAlreadyDenied() async {
        var scheduledIssues: [SystemNotificationSender.NotificationAccessIssue] = []

        SystemNotificationSender.resetForTesting(
            dependencies: .init(
                notificationAuthorizationStatus: { .denied },
                requestAuthorization: {
                    XCTFail("Did not expect an authorization prompt when notifications are already denied")
                    return true
                },
                addRequest: { _ in
                    XCTFail("Did not expect notification delivery when notifications are denied")
                },
                scheduleAccessGuidance: { issue in
                    scheduledIssues.append(issue)
                }
            )
        )

        await SystemNotificationSender.send(
            title: "Denied",
            body: "Should not send",
            workspaceID: UUID(),
            panelID: nil
        )

        XCTAssertEqual(scheduledIssues, [.denied])
    }

    func testSendSkipsDeliveryAndSchedulesDeniedGuidanceWhenAuthorizationRequestReturnsFalse() async {
        var delivered = false
        var scheduledIssues: [SystemNotificationSender.NotificationAccessIssue] = []

        SystemNotificationSender.resetForTesting(
            dependencies: .init(
                notificationAuthorizationStatus: { .notDetermined },
                requestAuthorization: { false },
                addRequest: { _ in
                    delivered = true
                },
                scheduleAccessGuidance: { issue in
                    scheduledIssues.append(issue)
                }
            )
        )

        await SystemNotificationSender.send(
            title: "Denied",
            body: "Should not send",
            workspaceID: UUID(),
            panelID: nil
        )

        XCTAssertFalse(delivered)
        XCTAssertEqual(scheduledIssues, [.denied])
    }

    func testSendSchedulesUnavailableGuidanceWhenDeliveryFailsWithNotificationsNotAllowed() async {
        var scheduledIssues: [SystemNotificationSender.NotificationAccessIssue] = []

        SystemNotificationSender.resetForTesting(
            dependencies: .init(
                notificationAuthorizationStatus: { .authorized },
                requestAuthorization: {
                    XCTFail("Did not expect an authorization prompt when notifications are already authorized")
                    return true
                },
                addRequest: { _ in
                    throw NSError(
                        domain: UNErrorDomain,
                        code: UNError.Code.notificationsNotAllowed.rawValue
                    )
                },
                scheduleAccessGuidance: { issue in
                    scheduledIssues.append(issue)
                }
            )
        )

        await SystemNotificationSender.send(
            title: "Unavailable",
            body: "Delivery failed",
            workspaceID: UUID(),
            panelID: nil
        )

        XCTAssertEqual(scheduledIssues, [.unavailable])
    }

    func testConcurrentSendCallsSharePermissionRequestAndBothDeliverAfterGrant() async {
        var requestAuthorizationCallCount = 0
        var deliveredRequests: [UNNotificationRequest] = []
        var permissionContinuation: CheckedContinuation<Bool, Never>?

        SystemNotificationSender.resetForTesting(
            dependencies: .init(
                notificationAuthorizationStatus: { .notDetermined },
                requestAuthorization: {
                    requestAuthorizationCallCount += 1
                    return await withCheckedContinuation { continuation in
                        permissionContinuation = continuation
                    }
                },
                addRequest: { request in
                    deliveredRequests.append(request)
                },
                scheduleAccessGuidance: { _ in
                    XCTFail("Did not expect notification guidance while permission grant is pending")
                }
            )
        )

        async let firstSend: Void = SystemNotificationSender.send(
            title: "First",
            body: "One",
            workspaceID: UUID(),
            panelID: nil
        )
        async let secondSend: Void = SystemNotificationSender.send(
            title: "Second",
            body: "Two",
            workspaceID: UUID(),
            panelID: nil
        )

        while permissionContinuation == nil {
            await Task.yield()
        }
        permissionContinuation?.resume(returning: true)

        _ = await (firstSend, secondSend)

        XCTAssertEqual(requestAuthorizationCallCount, 1)
        XCTAssertEqual(deliveredRequests.map(\.content.title).sorted(), ["First", "Second"])
    }

    func testSendSchedulesDeniedGuidanceWhenPermissionIsRevokedBeforeDelivery() async {
        var scheduledIssues: [SystemNotificationSender.NotificationAccessIssue] = []
        var authorizationStatuses: [UNAuthorizationStatus] = [.authorized, .denied]

        SystemNotificationSender.resetForTesting(
            dependencies: .init(
                notificationAuthorizationStatus: {
                    if authorizationStatuses.isEmpty {
                        return .denied
                    }
                    return authorizationStatuses.removeFirst()
                },
                requestAuthorization: {
                    XCTFail("Did not expect an authorization prompt when notifications are already authorized")
                    return true
                },
                addRequest: { _ in
                    throw NSError(
                        domain: UNErrorDomain,
                        code: UNError.Code.notificationsNotAllowed.rawValue
                    )
                },
                scheduleAccessGuidance: { issue in
                    scheduledIssues.append(issue)
                }
            )
        )

        await SystemNotificationSender.send(
            title: "Revoked",
            body: "Should map to denied",
            workspaceID: UUID(),
            panelID: nil
        )

        XCTAssertEqual(scheduledIssues, [.denied])
    }
}

@MainActor
final class NotificationAccessGuidancePresenterTests: XCTestCase {
    func testScheduleDefersAlertUntilApplicationBecomesActive() {
        var activeObserver: (@MainActor () -> Void)?
        var removedObserverCount = 0
        var presentedIssues: [SystemNotificationSender.NotificationAccessIssue] = []

        let presenter = NotificationAccessGuidancePresenter(
            isAppActive: { false },
            registerDidBecomeActiveObserver: { observer in
                activeObserver = observer
                return NSObject()
            },
            removeObserver: { _ in
                removedObserverCount += 1
            },
            presentAlert: { issue in
                presentedIssues.append(issue)
                return false
            },
            openSystemSettings: {
                XCTFail("Did not expect System Settings to open")
            }
        )

        presenter.schedule(issue: .denied)
        XCTAssertTrue(presentedIssues.isEmpty)
        XCTAssertNotNil(activeObserver)

        activeObserver?()

        XCTAssertEqual(presentedIssues, [.denied])
        XCTAssertEqual(removedObserverCount, 1)
    }

    func testScheduleOpensSystemSettingsWhenAlertRequestsIt() {
        var openedSystemSettingsCount = 0
        var presentedIssues: [SystemNotificationSender.NotificationAccessIssue] = []

        let presenter = NotificationAccessGuidancePresenter(
            isAppActive: { true },
            registerDidBecomeActiveObserver: { _ in
                XCTFail("Did not expect an activation observer when the app is already active")
                return NSObject()
            },
            removeObserver: { _ in },
            presentAlert: { issue in
                presentedIssues.append(issue)
                return true
            },
            openSystemSettings: {
                openedSystemSettingsCount += 1
            }
        )

        presenter.schedule(issue: .unavailable)

        XCTAssertEqual(presentedIssues, [.unavailable])
        XCTAssertEqual(openedSystemSettingsCount, 1)
    }
}
