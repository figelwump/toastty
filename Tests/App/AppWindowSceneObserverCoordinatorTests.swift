@testable import ToasttyApp
import AppKit
import XCTest

@MainActor
final class AppWindowSceneObserverCoordinatorTests: XCTestCase {
    func testAttachDefersInitialKeyWindowCallback() {
        let recorder = ScheduledCallbackRecorder()
        var didBecomeKeyCallCount = 0
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {
                didBecomeKeyCallCount += 1
            },
            onWindowFrameChange: { _ in },
            onWindowWillClose: {},
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let window = TestWindow()
        window.forcedIsKeyWindow = true

        coordinator.attach(to: window)

        XCTAssertEqual(didBecomeKeyCallCount, 0)
        XCTAssertEqual(recorder.callbacks.count, 1)

        recorder.callbacks.removeFirst()()

        XCTAssertEqual(didBecomeKeyCallCount, 1)
    }

    func testAttachAppliesSelectedWorkspaceTitleToWindowPreview() {
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            windowTitle: "Workspace 1",
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowWillClose: {},
            defaultWindowTitle: { "Toastty" },
            scheduleOnMainActor: { _ in }
        )
        let window = TestWindow()

        coordinator.attach(to: window)

        XCTAssertEqual(window.title, "Workspace 1")
    }

    func testAttachPersistsWindowIdentifierFromWindowID() {
        let windowID = UUID()
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: windowID,
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowWillClose: {},
            scheduleOnMainActor: { _ in }
        )
        let window = TestWindow()

        coordinator.attach(to: window)

        XCTAssertEqual(window.identifier?.rawValue, windowID.uuidString)
    }

    func testAttachRetargetsNativeCloseButtonToPresentWindowCloseConfirmation() throws {
        var willCloseCallCount = 0
        var presentedWindow: NSWindow?
        var confirmationHandler: (@MainActor (Bool) -> Void)?
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowWillClose: {
                willCloseCallCount += 1
            },
            shouldConfirmWindowClose: true,
            presentWindowCloseConfirmation: { window, completion in
                presentedWindow = window
                confirmationHandler = completion
            },
            scheduleOnMainActor: { operation in
                Task { @MainActor in
                    operation()
                }
            }
        )
        let window = TestWindow()

        coordinator.attach(to: window)

        let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let target = try XCTUnwrap(closeButton.target as? NSObject)
        let action = try XCTUnwrap(closeButton.action)

        _ = target.perform(action, with: closeButton)

        XCTAssertTrue(presentedWindow === window)
        XCTAssertNotNil(confirmationHandler)
        XCTAssertFalse(window.didClose)
        XCTAssertEqual(willCloseCallCount, 0)
    }

    func testConfirmingNativeCloseButtonConfirmationClosesWindow() throws {
        var confirmationHandler: (@MainActor (Bool) -> Void)?
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowWillClose: {},
            shouldConfirmWindowClose: true,
            presentWindowCloseConfirmation: { _, completion in
                confirmationHandler = completion
            },
            scheduleOnMainActor: { _ in }
        )
        let window = TestWindow()

        coordinator.attach(to: window)

        let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let target = try XCTUnwrap(closeButton.target as? NSObject)
        let action = try XCTUnwrap(closeButton.action)

        _ = target.perform(action, with: closeButton)
        let confirmClose = try XCTUnwrap(confirmationHandler)
        confirmClose(true)

        XCTAssertTrue(window.didClose)
    }

    func testCancelingNativeCloseButtonConfirmationKeepsWindowAlive() throws {
        var confirmationHandler: (@MainActor (Bool) -> Void)?
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowWillClose: {},
            shouldConfirmWindowClose: true,
            presentWindowCloseConfirmation: { _, completion in
                confirmationHandler = completion
            },
            scheduleOnMainActor: { _ in }
        )
        let window = TestWindow()

        coordinator.attach(to: window)

        let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let target = try XCTUnwrap(closeButton.target as? NSObject)
        let action = try XCTUnwrap(closeButton.action)

        _ = target.perform(action, with: closeButton)
        let cancelClose = try XCTUnwrap(confirmationHandler)
        cancelClose(false)

        XCTAssertFalse(window.didClose)
    }

    func testNativeCloseButtonDoesNotPresentDuplicateConfirmationWhilePending() throws {
        var presentCallCount = 0
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowWillClose: {},
            shouldConfirmWindowClose: true,
            presentWindowCloseConfirmation: { _, _ in
                presentCallCount += 1
            },
            scheduleOnMainActor: { _ in }
        )
        let window = TestWindow()

        coordinator.attach(to: window)

        let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let target = try XCTUnwrap(closeButton.target as? NSObject)
        let action = try XCTUnwrap(closeButton.action)

        _ = target.perform(action, with: closeButton)
        _ = target.perform(action, with: closeButton)

        XCTAssertEqual(presentCallCount, 1)
    }

    func testNativeCloseButtonClosesWindowImmediatelyWhenConfirmationDisabled() throws {
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowWillClose: {},
            shouldConfirmWindowClose: false,
            scheduleOnMainActor: { _ in }
        )
        let window = TestWindow()

        coordinator.attach(to: window)

        let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let target = try XCTUnwrap(closeButton.target as? NSObject)
        let action = try XCTUnwrap(closeButton.action)

        _ = target.perform(action, with: closeButton)

        XCTAssertTrue(window.didClose)
    }

    func testDidExitFullScreenReinstallsNativeCloseButtonOverride() throws {
        var presentCallCount = 0
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowWillClose: {},
            shouldConfirmWindowClose: true,
            presentWindowCloseConfirmation: { _, _ in
                presentCallCount += 1
            },
            scheduleOnMainActor: { operation in
                Task { @MainActor in
                    operation()
                }
            }
        )
        let window = TestWindow()

        coordinator.attach(to: window)

        let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
        closeButton.target = nil
        closeButton.action = nil

        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        let reinstallExpectation = expectation(description: "reinstall close button override after full-screen exit")
        DispatchQueue.main.async {
            reinstallExpectation.fulfill()
        }
        wait(for: [reinstallExpectation], timeout: 1)

        let target = try XCTUnwrap(closeButton.target as? NSObject)
        let action = try XCTUnwrap(closeButton.action)
        _ = target.perform(action, with: closeButton)

        XCTAssertEqual(presentCallCount, 1)
    }

    func testDidDeminiaturizeReinstallsNativeCloseButtonOverride() throws {
        var presentCallCount = 0
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowWillClose: {},
            shouldConfirmWindowClose: true,
            presentWindowCloseConfirmation: { _, _ in
                presentCallCount += 1
            },
            scheduleOnMainActor: { operation in
                Task { @MainActor in
                    operation()
                }
            }
        )
        let window = TestWindow()

        coordinator.attach(to: window)

        let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
        closeButton.target = nil
        closeButton.action = nil

        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        let reinstallExpectation = expectation(description: "reinstall close button override after deminiaturize")
        DispatchQueue.main.async {
            reinstallExpectation.fulfill()
        }
        wait(for: [reinstallExpectation], timeout: 1)

        let target = try XCTUnwrap(closeButton.target as? NSObject)
        let action = try XCTUnwrap(closeButton.action)
        _ = target.perform(action, with: closeButton)

        XCTAssertEqual(presentCallCount, 1)
    }

    func testAttachLeavesWindowChromeConfigurationToSceneStyle() {
        // Window chrome is owned by the scene-level hidden-titlebar style.
        // The observer should stay neutral and only track lifecycle/frame events.
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowWillClose: {},
            scheduleOnMainActor: { _ in }
        )
        let window = TestWindow()
        let initialStyleMask = window.styleMask
        let initialTitleVisibility = window.titleVisibility
        let initialSeparatorStyle = window.titlebarSeparatorStyle
        let initialTransparentTitlebar = window.titlebarAppearsTransparent

        coordinator.attach(to: window)

        XCTAssertEqual(window.styleMask, initialStyleMask)
        XCTAssertEqual(window.titleVisibility, initialTitleVisibility)
        XCTAssertEqual(window.titlebarSeparatorStyle, initialSeparatorStyle)
        XCTAssertEqual(window.titlebarAppearsTransparent, initialTransparentTitlebar)
    }

    func testAttachFallsBackToDefaultWindowTitleWhenWorkspaceTitleMissing() {
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            windowTitle: nil,
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowWillClose: {},
            defaultWindowTitle: { "Toastty" },
            scheduleOnMainActor: { _ in }
        )
        let window = TestWindow()

        coordinator.attach(to: window)

        XCTAssertEqual(window.title, "Toastty")
    }

    func testApplyWindowTitleUpdatesAttachedWindowWhenWorkspaceTitleChanges() {
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            windowTitle: "Workspace 1",
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowWillClose: {},
            defaultWindowTitle: { "Toastty" },
            scheduleOnMainActor: { _ in }
        )
        let window = TestWindow()

        coordinator.attach(to: window)
        coordinator.windowTitle = "Workspace 2"
        coordinator.applyWindowTitleIfNeeded()
        XCTAssertEqual(window.title, "Workspace 2")

        coordinator.windowTitle = nil
        coordinator.applyWindowTitleIfNeeded()
        XCTAssertEqual(window.title, "Toastty")
    }

    func testAttachDoesNotScheduleKeyCallbackForNonKeyWindow() {
        let recorder = ScheduledCallbackRecorder()
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {
                XCTFail("Unexpected key-window callback for a non-key window")
            },
            onWindowFrameChange: { _ in },
            onWindowWillClose: {},
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )

        coordinator.attach(to: TestWindow())

        XCTAssertTrue(recorder.callbacks.isEmpty)
    }
}

private final class ScheduledCallbackRecorder: @unchecked Sendable {
    var callbacks: [@MainActor @Sendable () -> Void] = []
}

private final class TestWindow: NSWindow {
    var forcedIsKeyWindow = false
    var didClose = false

    override var isKeyWindow: Bool {
        forcedIsKeyWindow
    }

    override func close() {
        didClose = true
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }
}
