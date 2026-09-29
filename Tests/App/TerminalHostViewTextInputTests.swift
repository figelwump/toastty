import AppKit
@testable import ToasttyApp
import XCTest

#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

@MainActor
final class TerminalHostViewTextInputTests: TerminalHostViewTestCase {
    func testCopyKeyEquivalentReachesFocusedTerminalOnceWithCommandIntact() throws {
        let hostView = TerminalHostView()
        let window = attachToVisibleWindow(hostView)
        window.forcedIsKeyWindow = true
        let recorder = GhosttyKeyEventRecorder()
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in }, setOcclusion: { _, _ in }, refresh: { _ in },
            keyTranslationMods: { _, mods in mods },
            sendKey: { _, event in recorder.record(event); return true }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1243))
        XCTAssertTrue(window.makeFirstResponder(hostView))

        let event = try makeKeyEvent(
            type: .keyDown, keyCode: 8, modifierFlags: [.command],
            characters: "c", charactersIgnoringModifiers: "c"
        )
        XCTAssertTrue(hostView.performKeyEquivalent(with: event))
        XCTAssertEqual(recorder.events.count, 1)
        XCTAssertEqual(recorder.events.first?.keyCode, 8)
        XCTAssertEqual(recorder.events.first?.modsRawValue, GHOSTTY_MODS_SUPER.rawValue)
        XCTAssertEqual(recorder.events.first?.actionRawValue, GHOSTTY_ACTION_PRESS.rawValue)
    }

    func testCopyKeyEquivalentDoesNotReachUnfocusedTerminal() throws {
        let hostView = TerminalHostView()
        let window = attachToVisibleWindow(hostView)
        window.forcedIsKeyWindow = true
        let recorder = GhosttyKeyEventRecorder()
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in }, setOcclusion: { _, _ in }, refresh: { _ in },
            keyTranslationMods: { _, mods in mods },
            sendKey: { _, event in recorder.record(event); return true }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1244))
        let textField = NSTextView()
        XCTAssertTrue(window.makeFirstResponder(textField))
        XCTAssertFalse(hostView.performKeyEquivalent(with: try makeKeyEvent(
            type: .keyDown, keyCode: 8, modifierFlags: [.command],
            characters: "c", charactersIgnoringModifiers: "c"
        )))
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testCopyKeyEquivalentLeavesOtherShortcutsToAppKit() throws {
        let hostView = TerminalHostView()
        let window = attachToVisibleWindow(hostView)
        window.forcedIsKeyWindow = true
        let recorder = GhosttyKeyEventRecorder()
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in }, setOcclusion: { _, _ in }, refresh: { _ in },
            keyTranslationMods: { _, mods in mods },
            sendKey: { _, event in recorder.record(event); return true }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1245))
        XCTAssertTrue(window.makeFirstResponder(hostView))
        for (character, modifiers): (String, NSEvent.ModifierFlags) in [
            ("w", [.command]), ("v", [.command]), ("c", [.control]),
            ("c", [.command, .shift]), ("c", [.command, .option]),
        ] {
            XCTAssertFalse(hostView.performKeyEquivalent(with: try makeKeyEvent(
                type: .keyDown, keyCode: 8, modifierFlags: modifiers,
                characters: character, charactersIgnoringModifiers: character
            )))
        }
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testCopyKeyEquivalentDoesNotInterceptCompositionInactiveWindowOrMissingSurface() throws {
        let hostView = TerminalHostView()
        let window = attachToVisibleWindow(hostView)
        window.forcedIsKeyWindow = true
        XCTAssertTrue(window.makeFirstResponder(hostView))
        let recorder = GhosttyKeyEventRecorder()
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in }, setOcclusion: { _, _ in }, refresh: { _ in },
            keyTranslationMods: { _, mods in mods },
            sendKey: { _, event in recorder.record(event); return true },
            setPreedit: { _, _, _ in }
        )
        let event = try makeKeyEvent(
            type: .keyDown, keyCode: 8, modifierFlags: [.command],
            characters: "c", charactersIgnoringModifiers: "c"
        )
        XCTAssertFalse(hostView.performKeyEquivalent(with: event), "No live surface")
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1246))
        window.forcedIsKeyWindow = false
        XCTAssertFalse(hostView.performKeyEquivalent(with: event), "Inactive window")
        window.forcedIsKeyWindow = true
        hostView.setMarkedText("に", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange())
        XCTAssertFalse(hostView.performKeyEquivalent(with: event), "Input method owns marked text")
        XCTAssertTrue(recorder.events.isEmpty)
    }

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
