import AppKit
@testable import ToasttyApp
import XCTest

#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

/// Checks the installed GhosttyKit's `ghostty_surface_is_at_prompt` end to
/// end. Toastty stops a managed agent session as `idle_at_prompt` when it
/// reads true, so a program that runs must never read as a shell prompt.
///
/// A script in a real surface stands in for the shell and for Claude Code.
/// It marks a prompt and a long typed line with OSC 133, starts its "command"
/// with `OSC 133;C`, and draws a frame. On SIGWINCH it does what Claude Code
/// does after a resize: it erases each screen row with `CSI 2 K`, draws the
/// frame again from the top row, and parks the cursor on its input row, row 6.
/// Those rows held the typed line, and Ghostty keeps their prompt mark after
/// an erase. GhosttyKit 056ffe2a8 answered from that mark and read the running
/// program as a shell prompt. The fixed API answers from the shell's OSC 133
/// state instead. Mouse reporting on or off tells the test which step the
/// script finished.
///
/// Every libghostty call goes through the app module; see
/// `GhosttyLinkHoverMouseReportingTests` for why.
@MainActor
final class GhosttyPromptStateRedrawTests: TerminalHostViewTestCase {
    private static let script = #"""
    go="$1"
    mark() { printf '\033]133;%s\007' "$1"; }
    frame() { printf 'FRAME banner\r\n\r\n\r\n\r\n\r\n----\r\n> input\r\n----\r\nfooter'; }
    redraw() {
      rows=$(stty size </dev/tty | cut -d' ' -f1)
      printf '\033[H'
      i=0
      while [ "$i" -lt "$rows" ]; do printf '\033[2K\033[1B'; i=$((i + 1)); done
      printf '\033[H'
      frame
      printf '\033[7;3H'
      printf '\033[?1000l'
    }
    printf '\033[H\033[2J'
    mark A; printf '$ '; mark B
    i=0
    while [ "$i" -lt 250 ]; do printf 'LAUNCH-%04d ' "$i"; i=$((i + 1)); done
    printf '\r\n'; mark C
    frame; printf '\r\n'
    trap redraw WINCH
    printf '\033[?1000h'
    while [ ! -f "$go" ]; do sleep 0.1; done
    trap - WINCH
    printf '\r\n'; mark D; mark A; printf '$ '; mark B
    printf '\033[?1000h'
    sleep 60
    """#

    func testRedrawOverPromptRowsDoesNotReadAsShellPrompt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-prompt-redraw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = directory.appendingPathComponent("redraw.sh")
        let goURL = directory.appendingPathComponent("go")
        try Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let hostView = TerminalHostView()
        hostView.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        let window = attachToVisibleWindow(hostView)
        _ = window

        let manager = GhosttyRuntimeManager.shared
        guard let created = manager.makeSurface(
            hostView: hostView,
            workingDirectory: directory.path,
            fontPoints: 12,
            launchConfiguration: TerminalSurfaceLaunchConfiguration(
                initialInput: "/bin/bash \(AgentLaunchInstrumentation.shellQuote(scriptURL.path)) "
                    + "\(AgentLaunchInstrumentation.shellQuote(goURL.path))\n"
            )
        ) else {
            XCTFail("Ghostty surface creation failed")
            return
        }
        let surface = created.surface
        let hooks = hostView.ghosttySurfaceHooks
        defer { manager.freeSurfaceForTesting(surface) }
        manager.setSurfaceSizeForTesting(surface, width: 900, height: 600)

        XCTAssertTrue(
            waitUntil(timeout: 30) { hooks.isMouseCaptured(surface) },
            "the script never drew its first frame"
        )
        XCTAssertEqual(GhosttySurfaceSemanticState.promptState(for: surface), .busy)

        // A narrower terminal: Ghostty reflows the typed line, then the
        // script redraws over it, as Claude Code does.
        manager.setSurfaceSizeForTesting(surface, width: 600, height: 600)
        XCTAssertTrue(
            waitUntil(timeout: 15) { !hooks.isMouseCaptured(surface) },
            "the script never redrew after the resize"
        )
        XCTAssertGreaterThan(manager.surfaceSizeForTesting(surface).rows, 12, "too few rows to reach row 6")
        XCTAssertEqual(
            GhosttySurfaceSemanticState.promptState(for: surface),
            .busy,
            "a running program read as a shell prompt; GhosttyKit lacks the OSC 133 at-prompt fix"
        )

        // The program ends and the shell shows its prompt again.
        FileManager.default.createFile(atPath: goURL.path, contents: Data())
        XCTAssertTrue(
            waitUntil(timeout: 15) { hooks.isMouseCaptured(surface) },
            "the script never printed the shell prompt"
        )
        XCTAssertEqual(GhosttySurfaceSemanticState.promptState(for: surface), .idleAtPrompt)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        return condition()
    }
}
#endif
