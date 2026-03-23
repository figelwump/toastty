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

    override var isKeyWindow: Bool {
        forcedIsKeyWindow
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
