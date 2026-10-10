import AppKit
@testable import ToasttyApp
import XCTest

#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

final class GhosttyClipboardBridgeTests: XCTestCase {
    func testStandardClipboardUsesSystemPasteboard() {
        let pasteboard = GhosttyClipboardBridge.pasteboard(for: GHOSTTY_CLIPBOARD_STANDARD)

        XCTAssertEqual(pasteboard?.name, NSPasteboard.general.name)
    }

    func testSelectionClipboardUsesToasttyPrivatePasteboard() {
        let pasteboard = GhosttyClipboardBridge.pasteboard(for: GHOSTTY_CLIPBOARD_SELECTION)

        XCTAssertEqual(pasteboard?.name, GhosttyClipboardBridge.selectionPasteboardName)
        XCTAssertNotEqual(pasteboard?.name, NSPasteboard.general.name)
    }

    func testGhosttyRuntimeAdvertisesSelectionClipboardSupport() {
        XCTAssertTrue(GhosttyClipboardBridge.runtimeSupportsSelectionClipboard)
    }

    func testLengthDelimitedWritePreservesBinaryAndEmptyRepresentations() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let bytes: [CChar] = [65, 0, -1, 66]
        let mime = "application/octet-stream"
        mime.withCString { mimePointer in
            bytes.withUnsafeBufferPointer { buffer in
                var content = ghostty_clipboard_content_s(mime: mimePointer, data: buffer.baseAddress, len: buffer.count)
                let entries = GhosttyClipboardBridge.entries(from: &content, count: 1)
                GhosttyClipboardBridge.write(entries, to: pasteboard)
            }
        }
        let result = GhosttyClipboardBridge.read(from: pasteboard, mimes: [mime], list: false)
        XCTAssertEqual(result?.contents.first?.data, Data([65, 0, 255, 66]))
        "text/plain".withCString { mimePointer in
            var content = ghostty_clipboard_content_s(mime: mimePointer, data: nil, len: 0)
            GhosttyClipboardBridge.write(GhosttyClipboardBridge.entries(from: &content, count: 1), to: pasteboard)
        }
        XCTAssertEqual(GhosttyClipboardBridge.read(from: pasteboard, mimes: ["text/plain"], list: false)?.contents.first?.data, Data())
    }

    func testTextWriteRepairsInvalidUTF8WithoutDroppingEmbeddedNUL() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        GhosttyClipboardBridge.write([.init(mime: "text/plain", data: Data([65, 0, 255, 66]))], to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "A\0\u{fffd}B")
    }

    func testReadFiltersDeduplicatesAndListsWithoutReadingUnrequestedData() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string, .png], owner: nil)
        pasteboard.setString("hello", forType: .string)
        pasteboard.setData(Data([0, 1, 255]), forType: .png)
        let text = GhosttyClipboardBridge.read(from: pasteboard, mimes: ["text/plain", "image/jpeg", "text/plain"], list: false)
        XCTAssertEqual(text?.contents.map(\.mime), ["text/plain"])
        XCTAssertEqual(text?.contents.first?.data, Data("hello".utf8))
        XCTAssertEqual(text?.available, [])
        XCTAssertNil(GhosttyClipboardBridge.read(from: pasteboard, mimes: [], list: false))
        XCTAssertNil(GhosttyClipboardBridge.read(from: pasteboard, mimes: ["image/jpeg"], list: false))
        let listing = GhosttyClipboardBridge.read(from: pasteboard, mimes: [], list: true)
        XCTAssertEqual(listing?.contents.count, 0)
        let available = listing?.available ?? []
        // macOS may also offer derived image representations, such as TIFF.
        XCTAssertTrue(Set(["text/plain", "image/png"]).isSubset(of: Set(available)))
        XCTAssertEqual(available.count, Set(available).count)
        pasteboard.clearContents()
        XCTAssertNotNil(GhosttyClipboardBridge.read(from: pasteboard, mimes: [], list: true))
    }

    func testListOnlyDoesNotReadLazyPasteboardData() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let provider = ClipboardDataProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.png])
        pasteboard.writeObjects([item])
        let result = GhosttyClipboardBridge.read(from: pasteboard, mimes: [], list: true)
        let available = result?.available ?? []
        XCTAssertTrue(available.contains("image/png"))
        XCTAssertEqual(available.count, Set(available).count)
        XCTAssertEqual(provider.readCount, 0)
    }

    private final class ClipboardDataProvider: NSObject, NSPasteboardItemDataProvider {
        var readCount = 0
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            readCount += 1
            item.setData(Data([1]), forType: type)
        }
    }

    func testFileURLsKeepEscapedTextPasteAndListTextRepresentation() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/a'b c")])
        let result = GhosttyClipboardBridge.read(from: pasteboard, mimes: ["text/plain"], list: true)
        XCTAssertEqual(result?.contents.first?.data, Data("'/tmp/a'\\''b c'".utf8))
        XCTAssertTrue(result?.available.contains("text/plain") == true)
    }

    func testCompletionKeepsAllBorrowedRepresentationsAliveDuringNestedUse() {
        let payload = GhosttyClipboardBridge.ReadContents(
            contents: [.init(mime: "text/plain", data: Data([65, 0, 66])), .init(mime: "image/png", data: Data([255, 1]))],
            available: ["text/plain", "image/png"]
        )
        payload.withCompletion(confirmed: false) { pointer in
            let outer = pointer.pointee
            XCTAssertFalse(outer.confirmed)
            XCTAssertFalse(outer.remember)
            payload.withCompletion(confirmed: true) { nested in
                XCTAssertTrue(nested.pointee.confirmed)
                XCTAssertEqual(GhosttyClipboardBridge.entries(from: outer.contents, count: outer.contents_len).map(\.data), payload.contents.map(\.data))
                XCTAssertEqual(GhosttyClipboardBridge.mimeStrings(from: outer.available, count: outer.available_len), payload.available)
            }
        }
    }

    func testSelectionWritesAreIsolatedFromSystemClipboard() throws {
        let selection = try XCTUnwrap(GhosttyClipboardBridge.pasteboard(for: GHOSTTY_CLIPBOARD_SELECTION))
        let systemChangeCount = NSPasteboard.general.changeCount
        GhosttyClipboardBridge.write([.init(mime: "text/plain", data: Data("selection only".utf8))], to: selection)
        XCTAssertEqual(selection.string(forType: .string), "selection only")
        XCTAssertEqual(NSPasteboard.general.changeCount, systemChangeCount)
        XCTAssertNil(GhosttyClipboardBridge.pasteboard(for: GHOSTTY_CLIPBOARD_PRIMARY))
    }

}

@MainActor
final class TerminalHostViewGhosttyBridgeTests: TerminalHostViewTestCase {
    func testFlagsChangedReturnsPressForLeftCommandPress() {
        let action = TerminalHostView.ghosttyModifierActionForFlagsChanged(
            keyCode: 0x37,
            modifierFlags: [.command]
        )

        XCTAssertEqual(action?.rawValue, GHOSTTY_ACTION_PRESS.rawValue)
    }

    func testFlagsChangedReturnsReleaseForRightCommandReleaseWhileLeftRemainsHeld() {
        let action = TerminalHostView.ghosttyModifierActionForFlagsChanged(
            keyCode: 0x36,
            modifierFlags: [.command]
        )

        XCTAssertEqual(action?.rawValue, GHOSTTY_ACTION_RELEASE.rawValue)
    }

    func testFlagsChangedReturnsPressForRightShiftPress() {
        let modifierFlags = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
        )
        let action = TerminalHostView.ghosttyModifierActionForFlagsChanged(
            keyCode: 0x3C,
            modifierFlags: modifierFlags
        )

        XCTAssertEqual(action?.rawValue, GHOSTTY_ACTION_PRESS.rawValue)
    }

    func testFlagsChangedReturnsNilForNonModifierKeyCode() {
        let action = TerminalHostView.ghosttyModifierActionForFlagsChanged(
            keyCode: 0x24,
            modifierFlags: []
        )

        XCTAssertNil(action)
    }

    func testGhosttyLinkHoverModifierFlagsStripsShiftWhenCommandIsPressed() {
        let flags = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.command.rawValue
                | NSEvent.ModifierFlags.shift.rawValue
                | UInt(NX_DEVICERSHIFTKEYMASK)
        )

        let normalized = TerminalHostView.ghosttyLinkHoverModifierFlags(for: flags)

        XCTAssertTrue(normalized.contains(.command))
        XCTAssertFalse(normalized.contains(.shift))
        XCTAssertEqual(normalized.rawValue & UInt(NX_DEVICERSHIFTKEYMASK), 0)
    }

    func testGhosttyLinkHoverModifierFlagsKeepsShiftWithoutCommand() {
        let flags = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
        )

        let normalized = TerminalHostView.ghosttyLinkHoverModifierFlags(for: flags)

        XCTAssertEqual(normalized, flags)
    }

    func testUnshiftedCodepointSkipsCharacterLookupForFlagsChangedEvents() {
        var providerWasCalled = false

        let codepoint = TerminalHostView.ghosttyUnshiftedCodepoint(eventType: .flagsChanged) {
            providerWasCalled = true
            return "x"
        }

        XCTAssertEqual(codepoint, 0)
        XCTAssertFalse(providerWasCalled)
    }

    func testUnshiftedCodepointUsesFirstScalarForKeyDownEvents() {
        let codepoint = TerminalHostView.ghosttyUnshiftedCodepoint(eventType: .keyDown) {
            "A"
        }

        XCTAssertEqual(codepoint, UnicodeScalar("A").value)
    }

    func testGhosttyTextPreservesBacktabForShiftTab() {
        let text = TerminalHostView.ghosttyText(
            eventType: .keyDown,
            keyCode: 48,
            modifierFlags: [.shift],
            characterProvider: { "\u{19}" },
            translatedCharacterProvider: { "\t" }
        )

        XCTAssertNil(text)
    }

    func testGhosttyTextPreservesBareTabAsText() {
        let text = TerminalHostView.ghosttyText(
            eventType: .keyDown,
            keyCode: 48,
            modifierFlags: [],
            characterProvider: { "\t" },
            translatedCharacterProvider: { "\t" }
        )

        XCTAssertEqual(text, "\t")
    }

    func testGhosttyTextSuppressesModifiedTabTextForControlTab() {
        let text = TerminalHostView.ghosttyText(
            eventType: .keyDown,
            keyCode: 48,
            modifierFlags: [.control],
            characterProvider: { "\t" },
            translatedCharacterProvider: { "\t" }
        )

        XCTAssertNil(text)
    }

    func testGhosttyTextNormalizesControlCharacterWhenNeeded() {
        let text = TerminalHostView.ghosttyText(
            eventType: .keyDown,
            keyCode: 8,
            modifierFlags: [.control],
            characterProvider: { "\u{03}" },
            translatedCharacterProvider: { "c" }
        )

        XCTAssertEqual(text, "c")
    }

    func testHeldKeyRepeatsCountAsLocalInput() throws {
        // Remote draft protection relies on every change to the composer,
        // including auto-repeat, reporting local input.
        let host = TerminalHostView()
        var localInputs = 0
        host.handleLocalInput = { localInputs += 1 }
        for isARepeat in [false, true, true] {
            host.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                isARepeat: isARepeat, keyCode: 0
            )))
        }
        XCTAssertEqual(localInputs, 3)
    }

    func testLocalInterruptKeyRecognizesEscape() {
        XCTAssertTrue(
            TerminalHostView.isLocalInterruptKey(
                keyCode: 53,
                modifierFlags: [],
                charactersIgnoringModifiers: nil
            )
        )
    }

    func testLocalInterruptKeyRecognizesControlC() {
        XCTAssertTrue(
            TerminalHostView.isLocalInterruptKey(
                keyCode: 8,
                modifierFlags: [.control],
                charactersIgnoringModifiers: "c"
            )
        )
    }

    func testLocalInterruptKeyIgnoresPlainC() {
        XCTAssertFalse(
            TerminalHostView.isLocalInterruptKey(
                keyCode: 8,
                modifierFlags: [],
                charactersIgnoringModifiers: "c"
            )
        )
    }

    func testLocalInterruptKeyIgnoresCommandC() {
        XCTAssertFalse(
            TerminalHostView.isLocalInterruptKey(
                keyCode: 8,
                modifierFlags: [.command],
                charactersIgnoringModifiers: "c"
            )
        )
    }
}
#endif
