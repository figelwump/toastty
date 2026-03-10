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
