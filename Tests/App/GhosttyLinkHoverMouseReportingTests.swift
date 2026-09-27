import AppKit
@testable import ToasttyApp
import XCTest

#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

/// Exercises the embedded Ghostty runtime end to end: a real surface runs a
/// shell that enables mouse reporting (as fullscreen TUIs such as Claude Code
/// do) and prints a URL. Ghostty must still report the hovered link while
/// Command is held, because that is what Toastty's Command-click routing
/// consumes. Without Command the program owns the pointer and no link is
/// reported.
///
/// Every libghostty call goes through the app module (`GhosttyRuntimeManager`
/// or `GhosttySurfaceHooks.live`). The test bundle links a second copy of
/// libghostty whose globals are never initialized; calling its C functions
/// directly panics inside Ghostty.
@MainActor
final class GhosttyLinkHoverMouseReportingTests: TerminalHostViewTestCase {
    private static let linkURL = "https://example.com/toastty-mouse-reporting-link"

    func testCommandHoverReportsLinkWhileProgramHasMouseReportingEnabled() throws {
        let hostView = TerminalHostView()
        hostView.frame = CGRect(x: 0, y: 0, width: 640, height: 240)
        let window = attachToVisibleWindow(hostView)
        _ = window

        let manager = GhosttyRuntimeManager.shared
        // Enable normal mouse tracking plus SGR encoding, print the link on
        // its own line, then keep the program alive so the modes stay set.
        let initialInput = "printf '\\033[?1000h\\033[?1006h'; printf '%s\\n' '\(Self.linkURL)'; sleep 60\n"
        guard let created = manager.makeSurface(
            hostView: hostView,
            workingDirectory: NSTemporaryDirectory(),
            fontPoints: 12,
            launchConfiguration: TerminalSurfaceLaunchConfiguration(initialInput: initialInput)
        ) else {
            XCTFail("Ghostty surface creation failed")
            return
        }
        let surface = created.surface
        let hooks = hostView.ghosttySurfaceHooks
        defer { manager.freeSurfaceForTesting(surface) }
        manager.setSurfaceSizeForTesting(surface, width: 640, height: 240)

        // The shell must run the printf before hover checks mean anything.
        XCTAssertTrue(
            waitUntil(timeout: 30) { hooks.isMouseCaptured(surface) },
            "program never enabled mouse reporting"
        )

        // Command hover: scan rows until Ghostty reports the printed link.
        var linkRow: Int32?
        XCTAssertTrue(
            waitUntil(timeout: 15) {
                let size = manager.surfaceSizeForTesting(surface)
                guard size.cell_height_px > 0, size.rows > 0 else { return false }
                for row in 0..<Int32(size.rows) {
                    hover(surface, hostView: hostView, row: row, size: size, mods: GHOSTTY_MODS_SUPER)
                    if hostView.hoveredGhosttyLinkURLForTesting == Self.linkURL {
                        linkRow = row
                        return true
                    }
                }
                return false
            },
            "Command hover never reported the link while mouse reporting was enabled"
        )
        guard let linkRow else { return }
        XCTAssertTrue(hooks.isMouseCaptured(surface), "mouse reporting turned off during the test")

        // Releasing Command while the pointer slides one cell along the same
        // link, reported only through the mouse event's modifiers (no leave,
        // no key event), must clear the hovered link: the program owns the
        // pointer again. Ghostty drops moves at an identical position, so the
        // pointer has to move.
        let size = manager.surfaceSizeForTesting(surface)
        let point = cellPoint(hostView: hostView, row: linkRow, size: size, column: 4.5)
        hooks.sendMousePosition(surface, point.x, point.y, GHOSTTY_MODS_NONE)
        pumpRunLoop(0.01)
        XCTAssertNil(hostView.hoveredGhosttyLinkURLForTesting)

        // Without Command no link is reported even after a fresh enter.
        hover(surface, hostView: hostView, row: linkRow, size: size, mods: GHOSTTY_MODS_NONE)
        XCTAssertNil(hostView.hoveredGhosttyLinkURLForTesting)

        // Pressing Command again over the same cell re-detects the link.
        hover(surface, hostView: hostView, row: linkRow, size: size, mods: GHOSTTY_MODS_SUPER)
        XCTAssertEqual(hostView.hoveredGhosttyLinkURLForTesting, Self.linkURL)
    }

    /// Mirrors TerminalHostView's Command-click refresh: leave the surface so
    /// Ghostty forgets its last link point, then re-enter at the target cell.
    /// Coordinates are in unscaled points, as Toastty sends them.
    private func hover(
        _ surface: ghostty_surface_t,
        hostView: TerminalHostView,
        row: Int32,
        size: ghostty_surface_size_s,
        mods: ghostty_input_mods_e
    ) {
        let point = cellPoint(hostView: hostView, row: row, size: size)
        let hooks = hostView.ghosttySurfaceHooks
        hooks.sendMousePosition(surface, -1, -1, mods)
        hooks.sendMousePosition(surface, point.x, point.y, mods)
        pumpRunLoop(0.01)
    }

    /// The center of a cell in `row` at `column`, in unscaled points.
    private func cellPoint(
        hostView: TerminalHostView,
        row: Int32,
        size: ghostty_surface_size_s,
        column: Double = 3.5
    ) -> CGPoint {
        let scale = max(hostView.window?.backingScaleFactor ?? 1, 1)
        let cellWidth = Double(size.cell_width_px) / scale
        let cellHeight = Double(size.cell_height_px) / scale
        return CGPoint(x: cellWidth * column, y: (Double(row) + 0.5) * cellHeight)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            pumpRunLoop(0.1)
        }
        return condition()
    }

    private func pumpRunLoop(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }
}
#endif
