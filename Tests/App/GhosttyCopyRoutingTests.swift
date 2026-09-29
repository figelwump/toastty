import AppKit
@testable import ToasttyApp
import XCTest

#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

/// Uses a real PTY and embedded Ghostty, including its performable copy binding.
/// C calls must go through the app module, which owns Ghostty's initialized globals.
@MainActor
final class GhosttyCopyRoutingTests: TerminalHostViewTestCase {
    func testCommandCopyReachesProgramUnlessTerminalHasSelection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputFile = directory.appendingPathComponent("input")
        let script = directory.appendingPathComponent("fixture.py")
        // Match the keyboard and mouse protocols used by fullscreen TUIs. Retain
        // every received byte so duplicate dispatch and accidental Ctrl+C are visible.
        try """
        import os, pathlib, select, sys, termios, tty
        output = pathlib.Path(__file__).with_name('input')
        original = termios.tcgetattr(0)
        try:
            tty.setraw(0)
            output.write_bytes(b'')
            os.write(1, b'\u{1b}[2J\u{1b}[HCopy routing fixture\u{1b}[>5u\u{1b}[?1000h\u{1b}[?1006h')
            while select.select([0], [], [], 60)[0]:
                data = os.read(0, 4096)
                if not data: break
                with output.open('ab') as file: file.write(data)
        finally:
            termios.tcsetattr(0, termios.TCSANOW, original)
        """.write(to: script, atomically: true, encoding: .utf8)

        let host = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        let window = attachToVisibleWindow(host)
        window.forcedIsKeyWindow = true
        XCTAssertTrue(window.makeFirstResponder(host))
        let manager = GhosttyRuntimeManager.shared
        let quotedScript = "'" + script.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let created = try XCTUnwrap(manager.makeSurface(
            hostView: host, workingDirectory: directory.path, fontPoints: 12,
            launchConfiguration: TerminalSurfaceLaunchConfiguration(
                initialInput: "/usr/bin/python3 \(quotedScript)\n"
            )
        ))
        host.setGhosttySurface(created.surface)
        defer {
            host.setGhosttySurface(nil)
            manager.freeSurfaceForTesting(created.surface)
        }
        manager.setSurfaceSizeForTesting(created.surface, width: 640, height: 240)
        // The parser processes the keyboard flags before mouse capture; observing
        // capture therefore establishes both modes, including Codex's flag value 5.
        XCTAssertTrue(waitUntil { host.ghosttySurfaceHooks.isMouseCaptured(created.surface) })

        let copy = try makeKeyEvent(
            type: .keyDown, keyCode: 8, modifierFlags: [.command],
            characters: "c", charactersIgnoringModifiers: "c"
        )
        XCTAssertTrue(host.performKeyEquivalent(with: copy))
        let encodedCopy = Data("\u{1b}[99;9u".utf8)
        XCTAssertTrue(waitUntil { (try? Data(contentsOf: inputFile)) == encodedCopy },
                      "Cmd+C must reach the PTY once as Super+C, not Ctrl+C or plain text")

        // Shift-drag creates Ghostty's own selection despite mouse capture.
        let size = manager.surfaceSizeForTesting(created.surface)
        let scale = max(window.backingScaleFactor, 1)
        let cellWidth = Double(size.cell_width_px) / scale
        let cellHeight = Double(size.cell_height_px) / scale
        let hooks = host.ghosttySurfaceHooks
        hooks.sendMousePosition(created.surface, cellWidth * 0.1, cellHeight * 0.5, GHOSTTY_MODS_SHIFT)
        _ = hooks.sendMouseButton(created.surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_SHIFT)
        hooks.sendMousePosition(created.surface, cellWidth * 4.9, cellHeight * 0.5, GHOSTTY_MODS_SHIFT)
        _ = hooks.sendMouseButton(created.surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_SHIFT)

        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { item in
            let saved = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { saved.setData(data, forType: type) }
            }
            return saved
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
        }
        pasteboard.clearContents()
        pasteboard.setString("clipboard sentinel", forType: .string)
        XCTAssertTrue(host.performKeyEquivalent(with: copy))
        XCTAssertTrue(waitUntil { pasteboard.string(forType: .string)?.hasPrefix("Copy") == true },
                      "Shift-drag selection must still copy through Ghostty")
        // Menu Copy and the shortcut agree when the terminal owns the selection.
        pasteboard.clearContents()
        host.copy(nil)
        XCTAssertTrue(waitUntil { pasteboard.string(forType: .string)?.hasPrefix("Copy") == true })

        // A positive PTY barrier proves no duplicate copy key preceded this input.
        host.keyDown(with: try makeKeyEvent(
            type: .keyDown, keyCode: 7, modifierFlags: [],
            characters: "x", charactersIgnoringModifiers: "x"
        ))
        let expectedInput = encodedCopy + Data("x".utf8)
        XCTAssertTrue(waitUntil { (try? Data(contentsOf: inputFile))?.last == UInt8(ascii: "x") })
        XCTAssertEqual(try Data(contentsOf: inputFile), expectedInput,
                       "Copying a terminal selection must not also send Cmd+C to the program")
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: 15)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        return condition()
    }
}
#endif
