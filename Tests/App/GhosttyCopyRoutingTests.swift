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
        let requestsFile = directory.appendingPathComponent("requests")
        let script = directory.appendingPathComponent("fixture.py")
        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .codex,
            argv: ["codex"],
            cliExecutablePath: "/bin/sh",
            sessionID: "copy-test-\(UUID().uuidString)",
            workingDirectory: directory.path,
            fileManager: .default
        )
        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? FileManager.default.removeItem(at: artifacts.directoryURL)
            }
        }
        // Match the keyboard and mouse protocols used by fullscreen TUIs. Retain
        // every received byte so duplicate dispatch and accidental Ctrl+C are visible.
        try """
        import os, pathlib, select, sys, termios, time, tty
        output = pathlib.Path(__file__).with_name('input')
        requests = pathlib.Path(__file__).with_name('requests')
        original = termios.tcgetattr(0)
        try:
            tty.setraw(0)
            output.write_bytes(b'')
            os.write(1, b'\u{1b}[2J\u{1b}[HCopy routing fixture')
            if os.environ.get('CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT') != '1':
                os.write(1, b'\u{1b}[>5u')
            os.write(1, b'\u{1b}[?1000h\u{1b}[?1006h')
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                if requests.exists():
                    packet = requests.read_bytes()
                    requests.unlink()
                    os.write(1, packet)
                if not select.select([0], [], [], 0.02)[0]: continue
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
        // Pin policy so the real protocol tests do not depend on a user's config.
        let configFile = directory.appendingPathComponent("ghostty-config")
        try """
        clipboard-read = ask
        clipboard-write = ask
        clipboard-paste-protection = true
        clipboard-paste-bracketed-safe = false
        """.write(to: configFile, atomically: true, encoding: .utf8)
        let savedConfigPath = ProcessInfo.processInfo.environment["TOASTTY_GHOSTTY_CONFIG_PATH"]
        setenv("TOASTTY_GHOSTTY_CONFIG_PATH", configFile.path, 1)
        XCTAssertTrue(manager.reloadConfiguration())
        defer {
            if let savedConfigPath { setenv("TOASTTY_GHOSTTY_CONFIG_PATH", savedConfigPath, 1) }
            else { unsetenv("TOASTTY_GHOSTTY_CONFIG_PATH") }
            _ = manager.reloadConfiguration()
        }
        let quotedScript = "'" + script.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let created = try XCTUnwrap(manager.makeSurface(
            hostView: host, workingDirectory: directory.path, fontPoints: 12,
            launchConfiguration: TerminalSurfaceLaunchConfiguration(
                environmentVariables: preparedLaunch.environment,
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
        guard waitUntil({ (try? Data(contentsOf: inputFile)) == encodedCopy }) else {
            XCTFail("Managed Codex launch must enable Super+C delivery, not Ctrl+C or plain text")
            return
        }

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

        // Ctrl+C and Escape must remain distinct from the copy shortcut.
        for (keyCode, modifiers, characters): (UInt16, NSEvent.ModifierFlags, String) in [
            (8, [.control], "c"), (53, [], "\u{1b}"), (6, [], "z"),
        ] {
            host.keyDown(with: try makeKeyEvent(
                type: .keyDown, keyCode: keyCode, modifierFlags: modifiers,
                characters: characters, charactersIgnoringModifiers: characters
            ))
        }
        XCTAssertTrue(waitUntil { (try? Data(contentsOf: inputFile))?.last == UInt8(ascii: "z") })
        XCTAssertEqual(
            try Data(contentsOf: inputFile).map { String(format: "%02x", $0) }.joined(),
            (expectedInput + Data("\u{1b}[99;5u\u{1b}[27uz".utf8))
                .map { String(format: "%02x", $0) }.joined()
        )

        // Menu Paste exercises the real length-delimited read callback and PTY.
        // The pasteboard is already saved above and restored when this test exits.
        let inputBeforePaste = try Data(contentsOf: inputFile)
        let pastedText = "clipboard café"
        pasteboard.clearContents()
        pasteboard.setString(pastedText, forType: .string)
        host.paste(nil)
        let inputAfterPaste = inputBeforePaste + Data(pastedText.utf8)
        XCTAssertTrue(waitUntil { (try? Data(contentsOf: inputFile)) == inputAfterPaste },
                      "Menu Paste must complete Ghostty's requested text representation")

        pasteboard.clearContents()
        pasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/a'b c")])
        host.paste(nil)
        let escapedPath = "'/tmp/a'\\''b c'"
        XCTAssertTrue(waitUntil { (try? Data(contentsOf: inputFile)) == inputAfterPaste + Data(escapedPath.utf8) },
                      "File paste must keep Toastty's existing shell escaping")

        // Unsafe multiline paste enters the nested legacy confirmation callback.
        let beforeMultiline = try Data(contentsOf: inputFile)
        pasteboard.clearContents()
        pasteboard.setString("first\nsecond", forType: .string)
        host.paste(nil)
        XCTAssertTrue(waitUntil { (try? Data(contentsOf: inputFile)) == beforeMultiline + Data("first\rsecond".utf8) })

        func emit(_ packet: String, expecting response: String) throws {
            let before = try Data(contentsOf: inputFile)
            try Data(packet.utf8).write(to: requestsFile, options: .atomic)
            XCTAssertTrue(waitUntil { (try? Data(contentsOf: inputFile)) == before + Data(response.utf8) },
                          "Clipboard protocol must return exactly its expected response")
        }
        pasteboard.clearContents()
        pasteboard.setString("legacy", forType: .string)
        // OSC 52 read remains auto-confirmed under ask, including nested completion.
        try emit("\u{1b}]52;c;?\u{7}", expecting: "\u{1b}]52;c;bGVnYWN5\u{1b}\\")
        // The new Kitty request kinds require real approval UI; ask must deny them.
        try emit("\u{1b}]5522;type=read:id=read;dGV4dC9wbGFpbg==\u{7}",
                 expecting: "\u{1b}]5522;type=read:status=EPERM:id=read\u{7}")
        let kittyWrite = "\u{1b}]5522;type=write:id=write\u{7}"
            + "\u{1b}]5522;type=wdata:mime=dGV4dC9wbGFpbg==;bmV3\u{7}"
            + "\u{1b}]5522;type=wdata\u{7}"
        try emit(kittyWrite, expecting: "\u{1b}]5522;type=write:status=EPERM:id=write\u{7}")
        XCTAssertEqual(pasteboard.string(forType: .string), "legacy",
                       "Denied Kitty write must preserve the clipboard")
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
