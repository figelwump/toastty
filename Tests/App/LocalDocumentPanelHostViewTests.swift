@testable import ToasttyApp
import AppKit
import CoreState
import WebKit
import XCTest

@MainActor
final class LocalDocumentPanelHostViewTests: XCTestCase {
    func testCoordinatorDefersLocalDocumentStateApplyUntilScheduledCallbackRuns() async {
        let recorder = ScheduledLocalDocumentMainActorRecorder()
        let metadataExpectation = expectation(description: "Local document metadata update arrives")
        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                LocalDocumentPanelDocumentSnapshot(
                    filePath: webState.filePath,
                    displayName: webState.title,
                    format: .toml,
                    content: "title = 'Toastty'\n",
                    diskRevision: nil
                )
            }
        )
        let coordinator = LocalDocumentPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let webState = WebPanelState(
            definition: .localDocument,
            title: "terminal-profiles.toml",
            localDocument: LocalDocumentState(
                filePath: "/tmp/toastty/terminal-profiles.toml",
                format: .toml
            )
        )

        coordinator.scheduleApply(webState: webState, runtime: runtime)

        XCTAssertEqual(recorder.callbacks.count, 1)
        XCTAssertNil(runtime.automationState().currentBootstrap)

        recorder.callbacks.removeFirst()()
        await fulfillment(of: [metadataExpectation], timeout: 1)

        XCTAssertEqual(runtime.automationState().currentBootstrap?.displayName, "terminal-profiles.toml")
        XCTAssertEqual(coordinator.lastAppliedWebState, webState)
    }

    func testCoordinatorIgnoresStaleScheduledLocalDocumentStateApply() async {
        let recorder = ScheduledLocalDocumentMainActorRecorder()
        let metadataExpectation = expectation(description: "Only latest local document metadata update arrives")
        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, title, _ in
                if title == "second.toml" {
                    metadataExpectation.fulfill()
                }
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                LocalDocumentPanelDocumentSnapshot(
                    filePath: webState.filePath,
                    displayName: webState.title,
                    format: .toml,
                    content: "key = 'value'\n",
                    diskRevision: nil
                )
            }
        )
        let coordinator = LocalDocumentPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let firstState = WebPanelState(
            definition: .localDocument,
            title: "first.toml",
            localDocument: LocalDocumentState(
                filePath: "/tmp/toastty/first.toml",
                format: .toml
            )
        )
        let secondState = WebPanelState(
            definition: .localDocument,
            title: "second.toml",
            localDocument: LocalDocumentState(
                filePath: "/tmp/toastty/second.toml",
                format: .toml
            )
        )

        coordinator.scheduleApply(webState: firstState, runtime: runtime)
        coordinator.scheduleApply(webState: secondState, runtime: runtime)

        XCTAssertEqual(recorder.callbacks.count, 2)

        recorder.callbacks.removeFirst()()
        XCTAssertNil(runtime.automationState().currentBootstrap)

        recorder.callbacks.removeFirst()()
        await fulfillment(of: [metadataExpectation], timeout: 1)

        XCTAssertEqual(runtime.automationState().currentBootstrap?.displayName, "second.toml")
        XCTAssertEqual(coordinator.lastAppliedWebState, secondState)
    }

    func testCoordinatorDoesNotReschedulePendingLocalDocumentState() {
        let recorder = ScheduledLocalDocumentMainActorRecorder()
        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = LocalDocumentPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let webState = WebPanelState(
            definition: .localDocument,
            title: "README.md",
            localDocument: LocalDocumentState(
                filePath: "/tmp/toastty/README.md",
                format: .markdown
            )
        )

        coordinator.scheduleApply(webState: webState, runtime: runtime)
        coordinator.scheduleApply(webState: webState, runtime: runtime)

        XCTAssertEqual(recorder.callbacks.count, 1)
    }

    func testCoordinatorDoesNotRescheduleAppliedLocalDocumentState() async {
        let recorder = ScheduledLocalDocumentMainActorRecorder()
        let metadataExpectation = expectation(description: "Initial local document metadata update arrives")
        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                metadataExpectation.fulfill()
            },
            interactionDidRequestFocus: { _ in },
            documentLoader: { webState in
                LocalDocumentPanelDocumentSnapshot(
                    filePath: webState.filePath,
                    displayName: webState.title,
                    format: .markdown,
                    content: "# Toastty\n",
                    diskRevision: nil
                )
            }
        )
        let coordinator = LocalDocumentPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let webState = WebPanelState(
            definition: .localDocument,
            title: "README.md",
            localDocument: LocalDocumentState(
                filePath: "/tmp/toastty/README.md",
                format: .markdown
            )
        )

        coordinator.scheduleApply(webState: webState, runtime: runtime)
        recorder.callbacks.removeFirst()()
        await fulfillment(of: [metadataExpectation], timeout: 1)

        coordinator.scheduleApply(webState: webState, runtime: runtime)

        XCTAssertTrue(recorder.callbacks.isEmpty)
    }

    func testCoordinatorResetPreventsPendingLocalDocumentStateApply() {
        let recorder = ScheduledLocalDocumentMainActorRecorder()
        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in
                XCTFail("Reset should cancel pending local-document applies")
            },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = LocalDocumentPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let webState = WebPanelState(
            definition: .localDocument,
            title: "README.md",
            localDocument: LocalDocumentState(
                filePath: "/tmp/toastty/README.md",
                format: .markdown
            )
        )

        coordinator.scheduleApply(webState: webState, runtime: runtime)
        coordinator.reset()

        recorder.callbacks.removeFirst()()

        XCTAssertNil(runtime.automationState().currentBootstrap)
        XCTAssertNil(coordinator.lastAppliedWebState)
    }

    func testCoordinatorRequestsFocusOnlyWhenPanelBecomesActive() {
        let recorder = ScheduledLocalDocumentMainActorRecorder()
        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = LocalDocumentPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )

        coordinator.requestFocusIfNeeded(isActivePanel: false, runtime: runtime)
        coordinator.requestFocusIfNeeded(isActivePanel: true, runtime: runtime)
        coordinator.requestFocusIfNeeded(isActivePanel: true, runtime: runtime)

        XCTAssertEqual(recorder.callbacks.count, 1)

        coordinator.requestFocusIfNeeded(isActivePanel: false, runtime: runtime)
        coordinator.requestFocusIfNeeded(isActivePanel: true, runtime: runtime)

        XCTAssertEqual(recorder.callbacks.count, 2)
    }

    func testCoordinatorDeferredFocusTargetsWebViewAfterAttachment() throws {
        let recorder = ScheduledLocalDocumentMainActorRecorder()
        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = LocalDocumentPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )

        coordinator.requestFocusIfNeeded(isActivePanel: true, runtime: runtime)
        XCTAssertEqual(recorder.callbacks.count, 1)

        let window = LocalDocumentFocusTestWindow()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let attachment = PanelHostAttachmentToken.next()
        window.contentView?.addSubview(container)
        runtime.attachHost(to: container, attachment: attachment)

        recorder.callbacks.removeFirst()()

        let webView = try XCTUnwrap(container.subviews.first as? WKWebView)
        XCTAssertTrue(window.makeFirstResponderCalled)
        XCTAssertTrue(window.firstResponder === webView)
    }

    func testCoordinatorDeferredFocusRetriesUntilAttachmentSucceeds() throws {
        let recorder = ScheduledLocalDocumentMainActorRecorder()
        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = LocalDocumentPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )

        coordinator.requestFocusIfNeeded(isActivePanel: true, runtime: runtime)
        XCTAssertEqual(recorder.callbacks.count, 1)

        recorder.callbacks.removeFirst()()
        XCTAssertEqual(recorder.callbacks.count, 1)

        let window = LocalDocumentFocusTestWindow()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let attachment = PanelHostAttachmentToken.next()
        window.contentView?.addSubview(container)
        runtime.attachHost(to: container, attachment: attachment)

        recorder.callbacks.removeFirst()()

        let webView = try XCTUnwrap(container.subviews.first as? WKWebView)
        XCTAssertTrue(window.makeFirstResponderCalled)
        XCTAssertTrue(window.firstResponder === webView)
        XCTAssertTrue(recorder.callbacks.isEmpty)
    }

    func testCoordinatorDoesNotRefocusWebViewWhilePanelRemainsActive() {
        let recorder = ScheduledLocalDocumentMainActorRecorder()
        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = LocalDocumentPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )

        let window = LocalDocumentFocusTestWindow()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let attachment = PanelHostAttachmentToken.next()
        window.contentView?.addSubview(container)
        runtime.attachHost(to: container, attachment: attachment)

        coordinator.requestFocusIfNeeded(isActivePanel: true, runtime: runtime)
        XCTAssertEqual(window.makeFirstResponderCallCount, 1)
        XCTAssertTrue(window.makeFirstResponderCalled)
        XCTAssertTrue(recorder.callbacks.isEmpty)

        coordinator.requestFocusIfNeeded(isActivePanel: true, runtime: runtime)
        XCTAssertEqual(window.makeFirstResponderCallCount, 1)
        XCTAssertTrue(recorder.callbacks.isEmpty)
    }

    func testCoordinatorDoesNotStealFocusFromSearchField() {
        let recorder = ScheduledLocalDocumentMainActorRecorder()
        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = LocalDocumentPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )

        let window = LocalDocumentFocusTestWindow()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let attachment = PanelHostAttachmentToken.next()
        window.contentView?.addSubview(container)
        runtime.attachHost(to: container, attachment: attachment)
        runtime.setSearchFieldFocused(true)

        coordinator.requestFocusIfNeeded(isActivePanel: true, runtime: runtime)

        XCTAssertEqual(window.makeFirstResponderCallCount, 0)
        XCTAssertTrue(recorder.callbacks.isEmpty)
    }

    func testCoordinatorDeferredFocusCancelsWhenSearchFieldTakesFocus() throws {
        let recorder = ScheduledLocalDocumentMainActorRecorder()
        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = LocalDocumentPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )

        coordinator.requestFocusIfNeeded(isActivePanel: true, runtime: runtime)
        XCTAssertEqual(recorder.callbacks.count, 1)

        let window = LocalDocumentFocusTestWindow()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let attachment = PanelHostAttachmentToken.next()
        window.contentView?.addSubview(container)
        runtime.attachHost(to: container, attachment: attachment)
        runtime.setSearchFieldFocused(true)

        recorder.callbacks.removeFirst()()

        let webView = try XCTUnwrap(container.subviews.first as? WKWebView)
        XCTAssertEqual(window.makeFirstResponderCallCount, 0)
        XCTAssertFalse(window.firstResponder === webView)
        XCTAssertTrue(recorder.callbacks.isEmpty)
    }

    func testCoordinatorResetCancelsPendingDeferredFocus() throws {
        let recorder = ScheduledLocalDocumentMainActorRecorder()
        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = LocalDocumentPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )

        coordinator.requestFocusIfNeeded(isActivePanel: true, runtime: runtime)
        XCTAssertEqual(recorder.callbacks.count, 1)

        let window = LocalDocumentFocusTestWindow()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let attachment = PanelHostAttachmentToken.next()
        window.contentView?.addSubview(container)
        runtime.attachHost(to: container, attachment: attachment)

        coordinator.reset()
        recorder.callbacks.removeFirst()()

        let webView = try XCTUnwrap(container.subviews.first as? WKWebView)
        XCTAssertFalse(window.makeFirstResponderCalled)
        XCTAssertFalse(window.firstResponder === webView)
    }

    func testShouldRequestWebViewFocusOnlyForInactiveToActiveTransition() {
        XCTAssertFalse(
            LocalDocumentPanelHostView.Coordinator.shouldRequestWebViewFocus(
                previousIsActivePanel: false,
                nextIsActivePanel: false
            )
        )
        XCTAssertTrue(
            LocalDocumentPanelHostView.Coordinator.shouldRequestWebViewFocus(
                previousIsActivePanel: false,
                nextIsActivePanel: true
            )
        )
        XCTAssertFalse(
            LocalDocumentPanelHostView.Coordinator.shouldRequestWebViewFocus(
                previousIsActivePanel: true,
                nextIsActivePanel: true
            )
        )
        XCTAssertFalse(
            LocalDocumentPanelHostView.Coordinator.shouldRequestWebViewFocus(
                previousIsActivePanel: true,
                nextIsActivePanel: false
            )
        )
    }
}

private final class ScheduledLocalDocumentMainActorRecorder: @unchecked Sendable {
    var callbacks: [@MainActor @Sendable () -> Void] = []
}

@MainActor
private final class LocalDocumentFocusTestWindow: NSWindow {
    private(set) var makeFirstResponderCalled = false
    private(set) var makeFirstResponderCallCount = 0
    private var storedFirstResponder: NSResponder?

    override var firstResponder: NSResponder? {
        storedFirstResponder
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        makeFirstResponderCalled = true
        makeFirstResponderCallCount += 1
        storedFirstResponder = responder
        return true
    }
}
