@testable import ToasttyApp
import AppKit
import CoreState
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

    func testAttachAppliesDesiredFrameOnInitialWindowBinding() {
        let desiredFrame = CGRect(x: 180, y: 220, width: 900, height: 700)
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowWillClose: {},
            screenVisibleFramesProvider: {
                [CGRect(x: 0, y: 0, width: 4_000, height: 3_000)]
            },
            scheduleOnMainActor: { _ in }
        )
        let window = TestWindow()
        window.resetSetFrameTracking()
        coordinator.desiredFrame = desiredFrame

        coordinator.attach(to: window)

        XCTAssertEqual(window.setFrameCallCount, 1)
        XCTAssertEqual(window.lastSetFrame, desiredFrame)
        XCTAssertEqual(window.frame, desiredFrame)
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

    func testAttachAndDetachDoNotMutateEnabledWindowBackgroundDragging() {
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowWillClose: {},
            scheduleOnMainActor: { _ in }
        )
        let window = TestWindow()
        window.isMovableByWindowBackground = true
        var backgroundDraggingChangeCount = 0
        let observation = window.observe(\.isMovableByWindowBackground, options: []) { _, _ in
            backgroundDraggingChangeCount += 1
        }

        withExtendedLifetime(observation) {
            coordinator.attach(to: window)
            coordinator.detach()

            XCTAssertTrue(window.isMovableByWindowBackground)
            XCTAssertEqual(backgroundDraggingChangeCount, 0)
        }
    }

    func testAttachAndDetachDoNotMutateDisabledWindowBackgroundDragging() {
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowWillClose: {},
            scheduleOnMainActor: { _ in }
        )
        let window = TestWindow()
        window.isMovableByWindowBackground = false
        var backgroundDraggingChangeCount = 0
        let observation = window.observe(\.isMovableByWindowBackground, options: []) { _, _ in
            backgroundDraggingChangeCount += 1
        }

        withExtendedLifetime(observation) {
            coordinator.attach(to: window)
            coordinator.detach()

            XCTAssertFalse(window.isMovableByWindowBackground)
            XCTAssertEqual(backgroundDraggingChangeCount, 0)
        }
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
        var closeInitiatedCallCount = 0
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowCloseInitiated: {
                closeInitiatedCallCount += 1
            },
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
        XCTAssertEqual(closeInitiatedCallCount, 1)
    }

    func testCancelingNativeCloseButtonConfirmationKeepsWindowAlive() throws {
        var confirmationHandler: (@MainActor (Bool) -> Void)?
        var closeInitiatedCallCount = 0
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowCloseInitiated: {
                closeInitiatedCallCount += 1
            },
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
        XCTAssertEqual(closeInitiatedCallCount, 0)
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
        var closeInitiatedCallCount = 0
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowCloseInitiated: {
                closeInitiatedCallCount += 1
            },
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
        XCTAssertEqual(closeInitiatedCallCount, 1)
    }

    func testNativeCloseButtonUsesUpdatedConfirmationPolicy() throws {
        var presentCallCount = 0
        var closeInitiatedCallCount = 0
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowCloseInitiated: {
                closeInitiatedCallCount += 1
            },
            onWindowWillClose: {},
            shouldConfirmWindowClose: true,
            presentWindowCloseConfirmation: { _, _ in
                presentCallCount += 1
            },
            scheduleOnMainActor: { _ in }
        )
        let window = TestWindow()

        coordinator.attach(to: window)
        coordinator.shouldConfirmWindowClose = false

        let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let target = try XCTUnwrap(closeButton.target as? NSObject)
        let action = try XCTUnwrap(closeButton.action)

        _ = target.perform(action, with: closeButton)

        XCTAssertEqual(presentCallCount, 0)
        XCTAssertTrue(window.didClose)
        XCTAssertEqual(closeInitiatedCallCount, 1)
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

    func testApplyDesiredFrameSkipsReplayingMostRecentlyPublishedWindowFrame() {
        let recorder = ScheduledCallbackRecorder()
        var publishedFrame: CGRectCodable?
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { frame in
                publishedFrame = frame
            },
            onWindowWillClose: {},
            screenVisibleFramesProvider: {
                [CGRect(x: 0, y: 0, width: 4_000, height: 3_000)]
            },
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let window = TestWindow()
        let firstFrame = CGRect(x: 120, y: 140, width: 640, height: 480)
        let secondFrame = CGRect(x: 820, y: 140, width: 640, height: 480)

        coordinator.attach(to: window)

        window.setFrame(firstFrame, display: false)
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
        XCTAssertFalse(recorder.callbacks.isEmpty)
        while recorder.callbacks.isEmpty == false {
            recorder.callbacks.removeFirst()()
        }
        XCTAssertEqual(publishedFrame?.cgRect, firstFrame)

        window.setFrame(secondFrame, display: false)
        recorder.callbacks.removeAll()
        window.resetSetFrameTracking()
        coordinator.desiredFrame = publishedFrame?.cgRect

        coordinator.applyDesiredFrameIfNeeded()

        XCTAssertEqual(window.setFrameCallCount, 0)
        XCTAssertNil(window.lastSetFrame)
        XCTAssertEqual(window.frame, secondFrame)
    }

    func testApplyDesiredFrameDoesNotClampLiveDragFrameWhileCrossingDisplayBoundary() {
        let recorder = ScheduledCallbackRecorder()
        var publishedFrame: CGRectCodable?
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { frame in
                publishedFrame = frame
            },
            onWindowWillClose: {},
            screenVisibleFramesProvider: {
                [
                    CGRect(x: 0, y: 0, width: 1_000, height: 800),
                    CGRect(x: 1_000, y: 0, width: 1_000, height: 800),
                ]
            },
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let window = TestWindow()
        let straddlingFrame = CGRect(x: 700, y: 120, width: 600, height: 500)

        coordinator.attach(to: window)

        window.setFrame(straddlingFrame, display: false)
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
        XCTAssertFalse(recorder.callbacks.isEmpty)
        while recorder.callbacks.isEmpty == false {
            recorder.callbacks.removeFirst()()
        }
        XCTAssertEqual(publishedFrame?.cgRect, straddlingFrame)

        window.resetSetFrameTracking()
        coordinator.desiredFrame = publishedFrame?.cgRect

        coordinator.applyDesiredFrameIfNeeded()

        XCTAssertEqual(window.setFrameCallCount, 0)
        XCTAssertNil(window.lastSetFrame)
        XCTAssertEqual(window.frame, straddlingFrame)
    }

    func testApplyDesiredFrameStillAppliesExplicitExternalFrameChange() {
        let recorder = ScheduledCallbackRecorder()
        var publishedFrame: CGRectCodable?
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { frame in
                publishedFrame = frame
            },
            onWindowWillClose: {},
            screenVisibleFramesProvider: {
                [CGRect(x: 0, y: 0, width: 4_000, height: 3_000)]
            },
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let window = TestWindow()
        let liveFrame = CGRect(x: 120, y: 140, width: 640, height: 480)
        let externallyRequestedFrame = CGRect(x: 260, y: 320, width: 900, height: 700)

        coordinator.attach(to: window)

        window.setFrame(liveFrame, display: false)
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
        XCTAssertFalse(recorder.callbacks.isEmpty)
        while recorder.callbacks.isEmpty == false {
            recorder.callbacks.removeFirst()()
        }
        XCTAssertEqual(publishedFrame?.cgRect, liveFrame)

        recorder.callbacks.removeAll()
        window.resetSetFrameTracking()
        coordinator.desiredFrame = externallyRequestedFrame

        coordinator.applyDesiredFrameIfNeeded()

        XCTAssertEqual(window.setFrameCallCount, 1)
        XCTAssertEqual(window.lastSetFrame, externallyRequestedFrame)
        XCTAssertEqual(window.frame, externallyRequestedFrame)
    }

    func testApplyDesiredFrameDoesNotClampOrdinaryDesiredFrameUpdates() {
        let recorder = ScheduledCallbackRecorder()
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        let liveFrame = CGRect(x: 120, y: 140, width: 640, height: 480)
        let externallyRequestedFrame = CGRect(x: 1_400, y: 100, width: 900, height: 600)
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowWillClose: {},
            screenVisibleFramesProvider: {
                [visibleFrame]
            },
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let window = TestWindow()

        coordinator.attach(to: window)
        window.setFrame(liveFrame, display: false)
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
        while recorder.callbacks.isEmpty == false {
            recorder.callbacks.removeFirst()()
        }
        window.resetSetFrameTracking()
        coordinator.desiredFrame = externallyRequestedFrame

        coordinator.applyDesiredFrameIfNeeded()

        XCTAssertEqual(window.setFrameCallCount, 1)
        XCTAssertEqual(window.lastSetFrame, externallyRequestedFrame)
        XCTAssertEqual(window.frame, externallyRequestedFrame)
    }

    func testInitialClampedAttachDoesNotReplayRawDesiredFrameOnImmediateUpdate() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        let restoredFrame = CGRect(x: 1_400, y: 100, width: 900, height: 600)
        let clampedFrame = CGRect(x: 100, y: 100, width: 900, height: 600)
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowWillClose: {},
            screenVisibleFramesProvider: {
                [visibleFrame]
            },
            scheduleOnMainActor: { _ in }
        )
        let window = TestWindow()
        coordinator.desiredFrame = restoredFrame

        coordinator.attach(to: window)

        XCTAssertEqual(window.setFrameCallCount, 1)
        XCTAssertEqual(window.lastSetFrame, clampedFrame)
        XCTAssertEqual(window.frame, clampedFrame)

        window.resetSetFrameTracking()
        coordinator.applyDesiredFrameIfNeeded(clampToVisibleScreens: false)

        XCTAssertEqual(window.setFrameCallCount, 0)
        XCTAssertNil(window.lastSetFrame)
        XCTAssertEqual(window.frame, clampedFrame)
    }

    func testApplyDesiredFrameRecoversAfterSuppressingOlderPublishedFrameEcho() {
        let recorder = ScheduledCallbackRecorder()
        var publishedFrame: CGRectCodable?
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { frame in
                publishedFrame = frame
            },
            onWindowWillClose: {},
            screenVisibleFramesProvider: {
                [CGRect(x: 0, y: 0, width: 4_000, height: 3_000)]
            },
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let window = TestWindow()
        let firstFrame = CGRect(x: 120, y: 140, width: 640, height: 480)
        let secondFrame = CGRect(x: 820, y: 140, width: 640, height: 480)

        coordinator.attach(to: window)

        window.setFrame(firstFrame, display: false)
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
        while recorder.callbacks.isEmpty == false {
            recorder.callbacks.removeFirst()()
        }

        window.setFrame(secondFrame, display: false)
        recorder.callbacks.removeAll()
        window.resetSetFrameTracking()
        coordinator.desiredFrame = firstFrame

        coordinator.applyDesiredFrameIfNeeded()

        XCTAssertEqual(window.setFrameCallCount, 0)
        XCTAssertEqual(window.frame, secondFrame)

        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
        while recorder.callbacks.isEmpty == false {
            recorder.callbacks.removeFirst()()
        }
        XCTAssertEqual(publishedFrame?.cgRect, secondFrame)

        window.resetSetFrameTracking()
        coordinator.desiredFrame = firstFrame

        coordinator.applyDesiredFrameIfNeeded()

        XCTAssertEqual(window.setFrameCallCount, 1)
        XCTAssertEqual(window.lastSetFrame, firstFrame)
        XCTAssertEqual(window.frame, firstFrame)
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

    func testApplyDesiredFrameClampsOffscreenFrameIntoVisibleScreenBounds() {
        let desiredFrame = CGRect(x: 1_400, y: 100, width: 900, height: 600)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowWillClose: {},
            screenVisibleFramesProvider: {
                [visibleFrame]
            },
            scheduleOnMainActor: { _ in }
        )
        let window = TestWindow()
        window.resetSetFrameTracking()
        coordinator.desiredFrame = desiredFrame

        coordinator.attach(to: window)

        XCTAssertEqual(window.setFrameCallCount, 1)
        XCTAssertEqual(window.lastSetFrame, CGRect(x: 100, y: 100, width: 900, height: 600))
        XCTAssertEqual(window.frame, CGRect(x: 100, y: 100, width: 900, height: 600))
    }

    func testApplyDesiredFrameShrinksOversizedFrameToVisibleScreenBounds() {
        let desiredFrame = CGRect(x: 1_400, y: 300, width: 1_400, height: 900)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowWillClose: {},
            screenVisibleFramesProvider: {
                [visibleFrame]
            },
            scheduleOnMainActor: { _ in }
        )
        let window = TestWindow()
        window.resetSetFrameTracking()
        coordinator.desiredFrame = desiredFrame

        coordinator.attach(to: window)

        XCTAssertEqual(window.setFrameCallCount, 1)
        XCTAssertEqual(window.lastSetFrame, CGRect(x: 0, y: 0, width: 1_000, height: 700))
        XCTAssertEqual(window.frame, CGRect(x: 0, y: 0, width: 1_000, height: 700))
    }

    func testScreenParametersChangeClampsLiveWindowFrameIntoRemainingVisibleScreenBounds() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        let coordinator = AppWindowSceneObserverCoordinator(
            windowID: UUID(),
            onWindowDidBecomeKey: {},
            onWindowFrameChange: { _ in },
            onWindowWillClose: {},
            screenVisibleFramesProvider: {
                [visibleFrame]
            },
            scheduleOnMainActor: { operation in
                MainActor.assumeIsolated {
                    operation()
                }
            }
        )
        let window = TestWindow()
        coordinator.attach(to: window)
        window.setFrame(CGRect(x: 1_400, y: 100, width: 900, height: 600), display: false)
        window.resetSetFrameTracking()

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        XCTAssertEqual(window.setFrameCallCount, 1)
        XCTAssertEqual(window.lastSetFrame, CGRect(x: 100, y: 100, width: 900, height: 600))
        XCTAssertEqual(window.frame, CGRect(x: 100, y: 100, width: 900, height: 600))
    }
}

private final class ScheduledCallbackRecorder: @unchecked Sendable {
    var callbacks: [@MainActor @Sendable () -> Void] = []
}

private final class TestWindow: NSWindow {
    var forcedIsKeyWindow = false
    var didClose = false
    var setFrameCallCount = 0
    var lastSetFrame: NSRect?

    override var isKeyWindow: Bool {
        forcedIsKeyWindow
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        setFrameCallCount += 1
        lastSetFrame = frameRect
        super.setFrame(frameRect, display: flag)
    }

    override func close() {
        didClose = true
    }

    func resetSetFrameTracking() {
        setFrameCallCount = 0
        lastSetFrame = nil
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
