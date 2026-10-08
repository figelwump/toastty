import UserNotifications
import XCTest
@testable import ToasttyMobileApp

@MainActor
final class AppIconBadgeControllerTests: XCTestCase {
    // Failure modes: bootstrap clears a retained badge; permission is requested
    // in the background; a stale permission/write result restores a cleared
    // count; disabled badges or transient failures prevent later recovery.
    func testUnknownCountPreservesBadgeAndDoesNotRequestPermission() async {
        let client = BadgeClientSpy()
        let controller = AppIconBadgeController(client: client)
        await controller.update(count: nil, isActive: true)?.value
        XCTAssertTrue(client.writes.isEmpty)
        XCTAssertEqual(client.permissionRequests, 0)

        await controller.update(count: 7, isActive: true)?.value
        await controller.update(count: nil, isActive: false)?.value
        XCTAssertEqual(client.writes.last, 7)
        XCTAssertFalse(client.writes.contains(0))
    }

    func testPermissionWaitsForActiveSceneAndAttention() async {
        let client = BadgeClientSpy(authorizationStatus: .notDetermined)
        let controller = AppIconBadgeController(client: client)
        await controller.update(count: 0, isActive: true)?.value
        await controller.update(count: 3, isActive: false)?.value
        XCTAssertEqual(client.permissionRequests, 0)
        XCTAssertFalse(client.writes.contains(3))

        await controller.update(count: 3, isActive: true)?.value
        XCTAssertEqual(client.permissionRequests, 1)
        XCTAssertEqual(client.writes.last, 3)
    }

    func testDeniedOrDisabledBadgesDoNotWriteAttentionCount() async {
        for status: UNAuthorizationStatus in [.denied, .authorized] {
            let client = BadgeClientSpy(authorizationStatus: status, badgesEnabled: false)
            let controller = AppIconBadgeController(client: client)
            await controller.update(count: 4, isActive: true)?.value
            XCTAssertFalse(client.writes.contains(4))
            XCTAssertEqual(client.permissionRequests, 0)
        }
    }

    func testForegroundRechecksSettingsAndAppliesRetainedCount() async {
        let client = BadgeClientSpy(authorizationStatus: .denied, badgesEnabled: false)
        let controller = AppIconBadgeController(client: client)
        await controller.update(count: 4, isActive: true)?.value
        await controller.update(count: nil, isActive: false)?.value
        client.settings = AppIconBadgeSettings(authorizationStatus: .authorized, badgesEnabled: true)
        await controller.update(count: nil, isActive: true)?.value
        XCTAssertEqual(client.writes.last, 4)
        XCTAssertEqual(client.permissionRequests, 0)
    }

    func testUnpairWhilePermissionIsPendingNeverWritesOldCount() async {
        let client = BadgeClientSpy(authorizationStatus: .notDetermined)
        client.holdsPermission = true
        let requested = expectation(description: "Permission requested")
        client.onPermissionRequest = { requested.fulfill() }
        let controller = AppIconBadgeController(client: client)
        let pending = controller.update(count: 7, isActive: true)
        await fulfillment(of: [requested], timeout: 2)

        controller.update(count: 0, isActive: false)
        client.finishPermission()
        await pending?.value
        XCTAssertEqual(client.writes, [0])
    }

    func testPermissionAlertSceneChangesDoNotLoseGrantedBadge() async {
        let client = BadgeClientSpy(authorizationStatus: .notDetermined)
        client.holdsPermission = true
        let requested = expectation(description: "Permission requested")
        client.onPermissionRequest = { requested.fulfill() }
        let controller = AppIconBadgeController(client: client)
        let pending = controller.update(count: 7, isActive: true)
        await fulfillment(of: [requested], timeout: 2)

        controller.update(count: 7, isActive: false)
        client.finishPermission()
        await pending?.value
        XCTAssertEqual(client.writes.last, 7)
        XCTAssertEqual(client.permissionRequests, 1)
    }

    func testWritesStayOrderedWhenCountChangesDuringSystemWrite() async {
        let client = BadgeClientSpy()
        client.holdsFirstWrite = true
        let writing = expectation(description: "First write started")
        client.onFirstWrite = { writing.fulfill() }
        let controller = AppIconBadgeController(client: client)
        let pending = controller.update(count: 7, isActive: true)
        await fulfillment(of: [writing], timeout: 2)

        controller.update(count: 3, isActive: true)
        controller.update(count: 0, isActive: false)
        XCTAssertEqual(client.writes, [7])
        client.finishWrite()
        await pending?.value
        XCTAssertEqual(client.writes, [7, 0])
    }

    func testFailedWriteCanRecoverOnNextForeground() async {
        let client = BadgeClientSpy()
        client.failsWrites = true
        let controller = AppIconBadgeController(client: client)
        await controller.update(count: 2, isActive: true)?.value
        XCTAssertEqual(client.writes, [2])

        client.failsWrites = false
        await controller.update(count: nil, isActive: true)?.value
        XCTAssertEqual(client.writes, [2, 2])
    }
}

@MainActor
private final class BadgeClientSpy: AppIconBadgeClient {
    var settings: AppIconBadgeSettings
    var writes: [Int] = []
    var permissionRequests = 0
    var holdsPermission = false
    var holdsFirstWrite = false
    var failsWrites = false
    var onPermissionRequest: (() -> Void)?
    var onFirstWrite: (() -> Void)?
    private var permissionContinuation: CheckedContinuation<Void, Never>?
    private var writeContinuation: CheckedContinuation<Void, Never>?

    init(authorizationStatus: UNAuthorizationStatus = .authorized, badgesEnabled: Bool = true) {
        settings = AppIconBadgeSettings(authorizationStatus: authorizationStatus, badgesEnabled: badgesEnabled)
    }

    func notificationSettings() async -> AppIconBadgeSettings { settings }

    func requestBadgeAuthorization() async throws {
        permissionRequests += 1
        if holdsPermission {
            await withCheckedContinuation { continuation in
                permissionContinuation = continuation
                onPermissionRequest?()
            }
        }
        settings = AppIconBadgeSettings(authorizationStatus: .authorized, badgesEnabled: true)
    }

    func setBadgeCount(_ count: Int) async throws {
        writes.append(count)
        if holdsFirstWrite, writes.count == 1 {
            await withCheckedContinuation { continuation in
                writeContinuation = continuation
                onFirstWrite?()
            }
        }
        if failsWrites { throw CocoaError(.fileWriteUnknown) }
    }

    func finishPermission() {
        permissionContinuation?.resume()
        permissionContinuation = nil
    }

    func finishWrite() {
        writeContinuation?.resume()
        writeContinuation = nil
    }
}
