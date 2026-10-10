import SwiftUI
import UserNotifications
import XCTest
@testable import ToasttyMobileApp

@MainActor
final class AppIconBadgeControllerTests: XCTestCase {
#if DEBUG
    func testContinueRefreshesBadgeWithoutCountOrSceneChange() async throws {
        let configuration = ToasttyMobileAppConfiguration(environment: [
            "TOASTTY_MOBILE_USE_FIXTURE": "1", "TOASTTY_MOBILE_FIXTURE_NOTIFICATIONS": "intro",
        ], infoDictionary: [:])
        let session = configuration.makeSessionController()
        let push = try XCTUnwrap(session.pushController)
        for _ in 0..<100 where !push.canIntroduce {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(push.canIntroduce)
        let count = try XCTUnwrap(session.appIconBadgeCount)
        XCTAssertGreaterThan(count, 0)
        let client = BadgeClientSpy(authorizationStatus: .notDetermined, badgesEnabled: false)
        let controller = AppIconBadgeController(client: client)
        let initialRead = expectation(description: "Initial badge settings read")
        client.onSettingsRead = { initialRead.fulfill() }
        let host = UIHostingController(rootView: AppIconBadgeSync(sessionController: session, controller: controller)
            .environment(\.scenePhase, .active))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        await fulfillment(of: [initialRead], timeout: 3)
        client.onSettingsRead = nil
        XCTAssertTrue(client.writes.isEmpty)

        let written = expectation(description: "Permission change writes retained badge count")
        written.assertForOverFulfill = false
        client.onWrite = { written.fulfill() }
        client.settings = AppIconBadgeSettings(authorizationStatus: .authorized, badgesEnabled: true)
        await push.continueIntroduction()
        await fulfillment(of: [written], timeout: 3)
        XCTAssertEqual(session.appIconBadgeCount, count)
        XCTAssertEqual(client.writes.last, count)
    }
#endif

    // Failure modes: bootstrap clears a retained badge; attention writes before
    // an explicit permission grant; a stale settings/write result restores a
    // cleared count; disabled badges or transient failures prevent recovery.
    func testUnknownCountPreservesBadge() async {
        let client = BadgeClientSpy()
        let controller = AppIconBadgeController(client: client)
        await controller.update(count: nil)?.value
        XCTAssertTrue(client.writes.isEmpty)

        await controller.update(count: 7)?.value
        await controller.update(count: nil)?.value
        XCTAssertEqual(client.writes.last, 7)
        XCTAssertFalse(client.writes.contains(0))
    }

    func testDeniedOrDisabledBadgesDoNotWriteAttentionCount() async {
        for status: UNAuthorizationStatus in [.denied, .authorized] {
            let client = BadgeClientSpy(authorizationStatus: status, badgesEnabled: false)
            let controller = AppIconBadgeController(client: client)
            await controller.update(count: 4)?.value
            XCTAssertFalse(client.writes.contains(4))
        }
    }

    func testAttentionWaitsForPermissionAndAppliesCountAfterGrant() async {
        let client = BadgeClientSpy(authorizationStatus: .notDetermined, badgesEnabled: false)
        let controller = AppIconBadgeController(client: client)
        await controller.update(count: nil)?.value
        await controller.update(count: 7)?.value
        await controller.update(count: 7)?.value
        XCTAssertTrue(client.writes.isEmpty)

        // Continue grants permission while the count and scene stay unchanged.
        client.settings = AppIconBadgeSettings(authorizationStatus: .authorized, badgesEnabled: true)
        await controller.update(count: 7)?.value
        XCTAssertEqual(client.writes, [7])

        await controller.update(count: 0)?.value
        XCTAssertEqual(client.writes, [7, 0])
    }

    func testForegroundRechecksSettingsAndAppliesRetainedCount() async {
        let client = BadgeClientSpy(authorizationStatus: .denied, badgesEnabled: false)
        let controller = AppIconBadgeController(client: client)
        await controller.update(count: 4)?.value
        await controller.update(count: nil)?.value
        client.settings = AppIconBadgeSettings(authorizationStatus: .authorized, badgesEnabled: true)
        await controller.update(count: nil)?.value
        XCTAssertEqual(client.writes.last, 4)
    }

    func testUnpairWhileSettingsArePendingNeverWritesOldCount() async {
        let client = BadgeClientSpy()
        client.holdsFirstSettingsRead = true
        let reading = expectation(description: "Settings read started")
        client.onSettingsRead = { reading.fulfill() }
        let controller = AppIconBadgeController(client: client)
        let pending = controller.update(count: 7)
        await fulfillment(of: [reading], timeout: 2)

        controller.update(count: 0)
        client.finishSettingsRead()
        await pending?.value
        XCTAssertEqual(client.writes, [0])
    }

    func testUnpairWhileDeniedStaysClearWhenPermissionIsEnabled() async {
        let client = BadgeClientSpy(authorizationStatus: .denied, badgesEnabled: false)
        let controller = AppIconBadgeController(client: client)
        await controller.update(count: 7)?.value
        await controller.update(count: 0)?.value
        client.settings = AppIconBadgeSettings(authorizationStatus: .authorized, badgesEnabled: true)
        await controller.update(count: nil)?.value
        XCTAssertFalse(client.writes.contains(7))
        XCTAssertEqual(client.writes.last, 0)
    }

    func testWritesStayOrderedWhenCountChangesDuringSystemWrite() async {
        let client = BadgeClientSpy()
        client.holdsFirstWrite = true
        let writing = expectation(description: "First write started")
        client.onFirstWrite = { writing.fulfill() }
        let controller = AppIconBadgeController(client: client)
        let pending = controller.update(count: 7)
        await fulfillment(of: [writing], timeout: 2)

        controller.update(count: 3)
        controller.update(count: 0)
        XCTAssertEqual(client.writes, [7])
        client.finishWrite()
        await pending?.value
        XCTAssertEqual(client.writes, [7, 0])
    }

    func testFailedWriteCanRecoverOnNextForeground() async {
        let client = BadgeClientSpy()
        client.failsWrites = true
        let controller = AppIconBadgeController(client: client)
        await controller.update(count: 2)?.value
        XCTAssertEqual(client.writes, [2])

        client.failsWrites = false
        await controller.update(count: nil)?.value
        XCTAssertEqual(client.writes, [2, 2])
    }
}

@MainActor
private final class BadgeClientSpy: AppIconBadgeClient {
    var settings: AppIconBadgeSettings
    var writes: [Int] = []
    var holdsFirstSettingsRead = false
    private var settingsReads = 0
    var holdsFirstWrite = false
    var failsWrites = false
    var onFirstWrite: (() -> Void)?
    var onSettingsRead: (() -> Void)?
    var onWrite: (() -> Void)?
    private var settingsContinuation: CheckedContinuation<Void, Never>?
    private var writeContinuation: CheckedContinuation<Void, Never>?

    init(authorizationStatus: UNAuthorizationStatus = .authorized, badgesEnabled: Bool = true) {
        settings = AppIconBadgeSettings(authorizationStatus: authorizationStatus, badgesEnabled: badgesEnabled)
    }

    func notificationSettings() async -> AppIconBadgeSettings {
        settingsReads += 1
        if holdsFirstSettingsRead, settingsReads == 1 {
            await withCheckedContinuation { continuation in
                settingsContinuation = continuation
                onSettingsRead?()
            }
        } else {
            onSettingsRead?()
        }
        return settings
    }

    func setBadgeCount(_ count: Int) async throws {
        writes.append(count)
        onWrite?()
        if holdsFirstWrite, writes.count == 1 {
            await withCheckedContinuation { continuation in
                writeContinuation = continuation
                onFirstWrite?()
            }
        }
        if failsWrites { throw CocoaError(.fileWriteUnknown) }
    }

    func finishSettingsRead() {
        settingsContinuation?.resume()
        settingsContinuation = nil
    }

    func finishWrite() {
        writeContinuation?.resume()
        writeContinuation = nil
    }
}
