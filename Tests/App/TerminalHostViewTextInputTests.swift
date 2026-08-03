import AppKit
@testable import ToasttyApp
import XCTest

#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

@MainActor
final class TerminalHostViewTextInputTests: TerminalHostViewTestCase {
    func testSetMarkedTextSyncsGhosttyPreeditImmediately() {
        let hostView = TerminalHostView()
        let preeditRecorder = GhosttyPreeditRecorder()
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            setPreedit: { _, text, length in
                preeditRecorder.record(text, length: length)
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1240))

        hostView.setMarkedText(
            "你好",
            selectedRange: NSRange(location: 0, length: 2),
            replacementRange: NSRange()
        )

        XCTAssertTrue(hostView.hasMarkedText())
        XCTAssertEqual(hostView.markedRange(), NSRange(location: 0, length: 2))
        XCTAssertEqual(preeditRecorder.values, ["你好"])
    }

    func testInsertTextSendsCommittedTextAndClearsPreedit() {
        let hostView = TerminalHostView()
        let preeditRecorder = GhosttyPreeditRecorder()
        let textRecorder = GhosttyTextRecorder()
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            setPreedit: { _, text, length in
                preeditRecorder.record(text, length: length)
            },
            sendText: { _, text, length in
                textRecorder.record(text, length: length)
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1241))
        hostView.setMarkedText(
            "你好",
            selectedRange: NSRange(location: 0, length: 2),
            replacementRange: NSRange()
        )

        hostView.insertText("你", replacementRange: NSRange())

        XCTAssertFalse(hostView.hasMarkedText())
        XCTAssertEqual(textRecorder.values, ["你"])
        XCTAssertEqual(preeditRecorder.values, ["你好", nil])
    }

    func testFlagsChangedIgnoresModifierTransitionsDuringMarkedTextComposition() throws {
        let hostView = TerminalHostView()
        let keyRecorder = GhosttyKeyEventRecorder()
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendKey: { _, keyEvent in
                keyRecorder.record(keyEvent)
                return true
            },
            setPreedit: { _, _, _ in }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1242))
        hostView.setMarkedText(
            "n",
            selectedRange: NSRange(location: 0, length: 1),
            replacementRange: NSRange()
        )

        hostView.flagsChanged(
            with: try makeKeyEvent(
                type: .flagsChanged,
                keyCode: 0x3B,
                modifierFlags: [.control]
            )
        )

        XCTAssertTrue(keyRecorder.events.isEmpty)
    }
}
#endif
