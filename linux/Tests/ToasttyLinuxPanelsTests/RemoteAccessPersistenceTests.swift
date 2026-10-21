import Foundation
import Testing

/// Remote Access settings survive a restart: turn Remote Access on and type a
/// tailnet origin in the Remote Access window, close the window (the title
/// bar's close button), relaunch with the same home, and check both are
/// restored; then switch it off, Quit, and check that sticks too.
///
/// Both settings live in UserDefaults (`toastty.remoteAccess.enabled`,
/// `toastty.remoteAccess.tailnetOrigin`), which swift-corelibs-foundation
/// only writes to `$XDG_CONFIG_HOME/<suite>.plist` on `synchronize()`.
///
/// Runs on a private Broadway display with an isolated HOME / XDG dirs and a
/// fake Tailscale Serve step on a random loopback port (never the real
/// tailnet). Skip with `TOASTTY_LINUX_SKIP_GUI_TESTS=1`.
@Suite("Remote Access persistence", .serialized)
struct RemoteAccessPersistenceTests {
    static let origin = "https://toastty-persist.example.ts.net"

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOASTTY_LINUX_SKIP_GUI_TESTS"] != "1"))
    func settingsSurviveRestart() throws {
        let port = 20_000 + Int.random(in: 0..<20_000)
        guard let harness = try RestartTestHarness(name: "remote-persist", extraEnvironment: [
            "TOASTTY_LINUX_FAKE_TAILNET_ORIGIN": "https://fake-serve.example.ts.net",
            "TOASTTY_LINUX_FAKE_TAILNET_PORT": "\(port)",
        ]) else { return }

        // 1. Turn it on and set an origin through the window, then close the window.
        try harness.run("enable", """
        wait 300
        expect remoteEnabled=false remoteOrigin=none
        action app.remote-access.open
        wait 300
        remote-access switch on
        expect remoteEnabled=true remoteAccess=ready
        remote-access origin \(Self.origin)
        expect remoteEnabled=true remoteOrigin=\(Self.origin)
        close-dialog
        window-close
        expect dialog=AdwAlertDialog dialogDefault=confirm
        dialog-click confirm
        """)
        // 2. Relaunch: both restored. Switch it off and Quit.
        try harness.run("restored", """
        wait 300
        expect remoteEnabled=true remoteOrigin=\(Self.origin)
        action app.remote-access.open
        wait 300
        remote-access switch off
        expect remoteEnabled=false remoteAccess=off
        close-dialog
        quit
        """)
        // 3. Relaunch: off sticks; the origin is kept.
        try harness.run("disabled", """
        wait 300
        expect remoteEnabled=false remoteAccess=off remoteOrigin=\(Self.origin)
        quit
        """)
    }
}
