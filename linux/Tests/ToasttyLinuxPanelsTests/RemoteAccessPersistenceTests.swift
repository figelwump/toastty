import Foundation
import Glibc
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
    typealias Smoke = PanelsBroadwaySmokeTests

    static let origin = "https://toastty-persist.example.ts.net"

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOASTTY_LINUX_SKIP_GUI_TESTS"] != "1"))
    func settingsSurviveRestart() throws {
        guard let broadwayd = Smoke.which("gtk4-broadwayd") else { Issue.record("gtk4-broadwayd not installed"); return }
        guard let binary = Smoke.appBinary() else { Issue.record("toastty-linux binary not found; build it first"); return }

        let tag = UUID().uuidString.prefix(8)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("toastty-remote-persist-\(tag)")
        let home = work.appendingPathComponent("home")
        // Keep XDG_RUNTIME_DIR short: broadwayd and the automation socket are
        // AF_UNIX sockets under it (108-byte path limit).
        let runtimeBase = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/tmp"
        let runtime = URL(fileURLWithPath: runtimeBase).appendingPathComponent("tl-ra.\(tag.prefix(4))")
        for directory in [home, runtime, work.appendingPathComponent("tmp")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        chmod(runtime.path, 0o700)
        defer {
            try? FileManager.default.removeItem(at: work)
            try? FileManager.default.removeItem(at: runtime)
        }

        let display = 30 + Int.random(in: 0..<25)
        let port = 20_000 + Int.random(in: 0..<20_000)
        var base: [String: String] = [
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "TMPDIR": work.appendingPathComponent("tmp").path + "/",
            "XDG_RUNTIME_DIR": runtime.path,
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
            "XDG_STATE_HOME": home.appendingPathComponent(".local/state").path,
            "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path,
            "XDG_CACHE_HOME": home.appendingPathComponent(".cache").path,
            "SHELL": "/bin/bash",
            "TERM": "xterm-256color",
            "GTK_A11Y": "none",
        ]
        if let lang = ProcessInfo.processInfo.environment["LANG"] { base["LANG"] = lang }

        let broadway = try Smoke.launch(broadwayd, [":\(display)"], environment: base, log: work.appendingPathComponent("broadwayd.log"))
        defer { kill(broadway.processIdentifier, SIGKILL); _ = Smoke.waitForExit(broadway, timeout: 5) }
        Thread.sleep(forTimeInterval: 0.5)

        var appEnvironment = base
        appEnvironment.merge([
            "GDK_BACKEND": "broadway",
            "BROADWAY_DISPLAY": ":\(display)",
            // A normal (non-automation) session, like the user's, in a
            // runtime home that every launch shares.
            "TOASTTY_AUTOMATION": "0",
            "TOASTTY_RUNTIME_HOME": work.appendingPathComponent("runtime-home").path,
            "TOASTTY_LINUX_FAKE_TAILNET_ORIGIN": "https://fake-serve.example.ts.net",
            "TOASTTY_LINUX_FAKE_TAILNET_PORT": "\(port)",
            "TOASTTY_LINUX_EPHEMERAL_BROWSER": "1",
            "TOASTTY_LINUX_AUTOMATION_ROOT": work.path,
            "TOASTTY_APP_RESOURCES_PATH": Smoke.repoRoot.appendingPathComponent("Sources/App/Resources").path,
        ]) { _, new in new }

        func run(_ name: String, _ script: String) throws {
            let scriptURL = work.appendingPathComponent("\(name).script")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            var environment = appEnvironment
            environment["TOASTTY_LINUX_SMOKE_SCRIPT"] = scriptURL.path
            let logURL = work.appendingPathComponent("\(name).log")
            let app = try Smoke.launch(binary, [], environment: environment, log: logURL)
            let exitStatus = Smoke.waitForExit(app, timeout: 90)
            if exitStatus == nil {
                kill(app.processIdentifier, SIGKILL)
                _ = Smoke.waitForExit(app, timeout: 5)
                Issue.record("\(name): toastty-linux did not quit within 90s")
            }
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            let failures = log.split(separator: "\n").filter { $0.contains("[automation] FAIL") }
            #expect(failures.isEmpty, "\(name) automation failures:\n\(failures.joined(separator: "\n"))")
            #expect(exitStatus == 0, "\(name) exit status \(String(describing: exitStatus)); log:\n\(log.suffix(3000))")
        }

        // 1. Turn it on and set an origin through the window, then close the window.
        try run("enable", """
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
        try run("restored", """
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
        try run("disabled", """
        wait 300
        expect remoteEnabled=false remoteAccess=off remoteOrigin=\(Self.origin)
        quit
        """)
    }
}
