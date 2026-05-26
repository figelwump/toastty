#if TOASTTY_HAS_GHOSTTY_KIT
import AppKit
@testable import ToasttyApp
import XCTest

@MainActor
final class TerminalSurfaceDiagnosticsTests: XCTestCase {
    func testIsEnabledFlagAcceptsCommonTruthyValues() {
        XCTAssertTrue(TerminalSurfaceDiagnostics.isEnabledFlag("1"))
        XCTAssertTrue(TerminalSurfaceDiagnostics.isEnabledFlag(" true "))
        XCTAssertTrue(TerminalSurfaceDiagnostics.isEnabledFlag("YES"))
        XCTAssertTrue(TerminalSurfaceDiagnostics.isEnabledFlag("on"))

        XCTAssertFalse(TerminalSurfaceDiagnostics.isEnabledFlag(nil))
        XCTAssertFalse(TerminalSurfaceDiagnostics.isEnabledFlag(""))
        XCTAssertFalse(TerminalSurfaceDiagnostics.isEnabledFlag("0"))
        XCTAssertFalse(TerminalSurfaceDiagnostics.isEnabledFlag("false"))
    }

    func testBackgroundSurfaceCreationDeferralRequiresFlag() {
        let hostView = makeHostView(ancestorAlpha: 0)

        XCTAssertFalse(
            TerminalSurfaceDiagnostics.shouldDeferSurfaceCreationForPresentationVisibility(
                hostView: hostView,
                deferBackgroundSurfaceCreation: false
            )
        )
    }

    func testBackgroundSurfaceCreationDefersTransparentMountedHostWhenFlagged() {
        let hostView = makeHostView(ancestorAlpha: 0)

        XCTAssertTrue(
            TerminalSurfaceDiagnostics.shouldDeferSurfaceCreationForPresentationVisibility(
                hostView: hostView,
                deferBackgroundSurfaceCreation: true
            )
        )
    }

    func testBackgroundSurfaceCreationDefersTransparentMountedHostWhenWindowOcclusionIsUnresolved() {
        let hostView = makeHostView(ancestorAlpha: 0, occlusionState: [])

        XCTAssertTrue(
            TerminalSurfaceDiagnostics.shouldDeferSurfaceCreationForPresentationVisibility(
                hostView: hostView,
                deferBackgroundSurfaceCreation: true
            )
        )
    }

    func testBackgroundSurfaceCreationDoesNotDeferVisibleHostWhenFlagged() {
        let hostView = makeHostView(ancestorAlpha: 1)

        XCTAssertFalse(
            TerminalSurfaceDiagnostics.shouldDeferSurfaceCreationForPresentationVisibility(
                hostView: hostView,
                deferBackgroundSurfaceCreation: true
            )
        )
    }

    func testBackgroundSurfaceCreationDoesNotDeferGenericView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))

        XCTAssertFalse(
            TerminalSurfaceDiagnostics.shouldDeferSurfaceCreationForPresentationVisibility(
                hostView: view,
                deferBackgroundSurfaceCreation: true
            )
        )
    }

    private func makeHostView(
        ancestorAlpha: CGFloat,
        occlusionState: NSWindow.OcclusionState = [.visible]
    ) -> TerminalHostView {
        let window = TerminalSurfaceDiagnosticsTestWindow()
        let contentView = NSView(frame: window.frame)
        let ancestor = NSView(frame: contentView.bounds)
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        window.forcedOcclusionState = occlusionState
        window.contentView = contentView
        ancestor.alphaValue = ancestorAlpha

        contentView.addSubview(ancestor)
        ancestor.addSubview(hostView)
        return hostView
    }
}

private final class TerminalSurfaceDiagnosticsTestWindow: NSWindow {
    var forcedOcclusionState: NSWindow.OcclusionState = []

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    override var occlusionState: NSWindow.OcclusionState {
        forcedOcclusionState
    }
}
#endif
