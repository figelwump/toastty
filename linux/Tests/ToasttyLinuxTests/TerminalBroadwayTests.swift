import Foundation
import Glibc
import Testing

/// Closed-loop test for Ghostty terminals in the real `toastty-linux`
/// binary, on a private GDK Broadway display (never the user's session):
/// types into real shells and reads the screen back, checks title/cwd
/// propagation to state and the panel header, per-window font size, find in
/// scrollback, Ghostty keybind routing (goto_split, toggle_split_zoom),
/// close confirmation for a running process, `exit` closing a pane, a
/// terminal-profile split with its startup command and environment, file
/// drops, bell / OSC 9 unread marking, and the context menu.
///
/// Uses an isolated HOME and bash so shell integration and prompts are
/// deterministic. Screenshots go to `artifacts/manual/linux-terminal/`.
/// Skip with `TOASTTY_LINUX_SKIP_GUI_TESTS=1`.
@Suite("Ghostty terminals (Broadway)", .serialized)
struct TerminalBroadwayTests {
    static let artifacts = "artifacts/manual/linux-terminal"

    static func script(dropPath: String) -> String {
        """
        wait 500
        terminal-wait-prompt 15000
        expect terminalBackend=ghostty terminals=1 panes=1 terminalHasFocus=true
        terminal-type echo toastty-$((6*7))
        terminal-key Return
        terminal-wait-text 5000 toastty-42
        screenshot \(artifacts)/01-echo.png

        # Split: a second real shell; the first keeps running.
        action layout.split.horizontal
        expect panes=2 terminals=2 focusedPane=1 unfocusedOverlays=1
        terminal-wait-prompt 15000
        terminal-type cd /usr/share
        terminal-key Return
        terminal-wait-state 5000 focusedTerminalCwd=/usr/share focusedTerminalTitle=/usr/share focusedHeaderSubtitle=/usr/share
        terminal-type seq 1 60 | sed 's/^/line-/'
        terminal-key Return
        terminal-wait-text 5000 line-60

        # Text size (Ctrl++ / Ctrl+0) applies to every terminal in the window.
        action text-size.increase
        action text-size.increase
        terminal-wait-state 3000 terminalFontPoints=14.0 terminalAppliedFont=14.0
        screenshot \(artifacts)/02-split-font-14.png
        action text-size.reset
        terminal-wait-state 3000 terminalFontPoints=12.0 terminalAppliedFont=12.0

        # Find in scrollback.
        action find.show
        terminal-wait-state 3000 searchVisible=true
        terminal-search line-4
        terminal-wait-state 3000 searchTotal=11
        action find.next
        terminal-wait-state 3000 searchSelected=0
        action find.next
        terminal-wait-state 3000 searchSelected=1
        screenshot \(artifacts)/03-find.png
        action find.hide
        terminal-wait-state 3000 searchVisible=false

        # Ghostty's own keybind actions route to Toastty commands.
        terminal-key <Control><Alt>Left
        expect focusedPane=0
        terminal-key <Control><Shift>Return
        expect zoomed=true
        terminal-key <Control><Shift>Return
        expect zoomed=false

        # Bell and OSC 9 in a background pane mark it unread.
        terminal-type sleep 1; printf '\\\\a'; printf '\\\\e]9;build done\\\\a'
        terminal-key Return
        action layout.split.navigate-right
        terminal-wait-state 5000 unreadPanels=1
        screenshot \(artifacts)/04-unread.png
        action layout.split.navigate-left
        terminal-wait-state 3000 unreadPanels=0
        action layout.split.navigate-right

        # Closing a pane with a running process asks first.
        terminal-type sleep 300
        terminal-key Return
        terminal-wait-state 5000 focusedPrompt=busy focusedNeedsCloseConfirm=true focusedTerminalTitle=sleep_300
        action panel.close
        expect dialog=AdwAlertDialog panes=2
        screenshot \(artifacts)/05-close-confirm.png
        dialog-respond cancel
        expect dialog=none panes=2
        action panel.close
        dialog-respond confirm
        expect panes=1 terminals=1

        # Terminal profile split: startup command + TOASTTY_TERMINAL_PROFILE_ID.
        terminal-command terminal-profile.split-down.demo
        expect panes=2 terminals=2
        terminal-wait-text 8000 profile-started-demo
        terminal-wait-prompt 8000

        # File drop inserts a shell-escaped path.
        terminal-drop \(dropPath)
        terminal-wait-text 3000 drop dir/it'"'"'s a file.txt'
        terminal-key <Control>c
        terminal-context-menu

        # `exit` closes the pane without asking.
        terminal-type exit
        terminal-key Return
        terminal-wait-state 5000 panes=1 terminals=1
        screenshot \(artifacts)/06-final.png
        state \(artifacts)/state.json
        quit
        """
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOASTTY_LINUX_SKIP_GUI_TESTS"] != "1"))
    func ghosttyTerminalsClosedLoop() throws {
        guard let broadwayd = BroadwaySmokeTests.which("gtk4-broadwayd") else {
            Issue.record("gtk4-broadwayd not installed")
            return
        }
        guard let binary = BroadwaySmokeTests.appBinary() else {
            Issue.record("toastty-linux binary not found; build it first (swift build --product toastty-linux)")
            return
        }
        guard let bash = BroadwaySmokeTests.which("bash") else {
            Issue.record("bash not found")
            return
        }

        let repoRoot = BroadwaySmokeTests.repoRoot
        let artifactDirectory = repoRoot.appendingPathComponent(Self.artifacts)
        try? FileManager.default.removeItem(at: artifactDirectory)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)

        // Short base: the Broadway and automation sockets live in
        // XDG_RUNTIME_DIR, and AF_UNIX paths are limited to 108 bytes.
        let base = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? FileManager.default.temporaryDirectory.path
        let work = URL(fileURLWithPath: base).appendingPathComponent("tt-term-\(UUID().uuidString.prefix(8))")
        let home = work.appendingPathComponent("home")
        let runtime = work.appendingPathComponent("rt")
        for directory in [home, runtime] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        defer {
            if ProcessInfo.processInfo.environment["TOASTTY_LINUX_TEST_KEEP"] != "1" {
                try? FileManager.default.removeItem(at: work)
            }
        }

        let profiles = work.appendingPathComponent("terminal-profiles.toml")
        try """
        [demo]
        displayName = "Demo Profile"
        badge = "DEMO"
        startupCommand = "echo profile-started-$TOASTTY_TERMINAL_PROFILE_ID"
        shortcutKey = "d"

        """.write(to: profiles, atomically: true, encoding: .utf8)
        let dropDirectory = work.appendingPathComponent("drop dir")
        try FileManager.default.createDirectory(at: dropDirectory, withIntermediateDirectories: true)
        let dropFile = dropDirectory.appendingPathComponent("it's a file.txt")
        FileManager.default.createFile(atPath: dropFile.path, contents: Data())

        let scriptURL = work.appendingPathComponent("terminal.txt")
        try Self.script(dropPath: dropFile.path).write(to: scriptURL, atomically: true, encoding: .utf8)

        var isolated: [String: String] = [
            "XDG_RUNTIME_DIR": runtime.path,
            "GTK_A11Y": "none",
            "NO_AT_BRIDGE": "1",
            "GDK_DEBUG": "no-portals",
            "GSETTINGS_BACKEND": "memory",
        ]
        var environment = BroadwaySmokeTests.cleanEnvironment(extra: isolated)
        environment.removeValue(forKey: "DBUS_SESSION_BUS_ADDRESS")

        let display = 60 + Int.random(in: 0..<30)
        let broadway = try BroadwaySmokeTests.launch(
            broadwayd, [":\(display)"], environment: environment, log: work.appendingPathComponent("broadwayd.log")
        )
        defer { BroadwaySmokeTests.stop(broadway, signal: SIGKILL) }
        Thread.sleep(forTimeInterval: 0.5)

        isolated = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
            "XDG_CACHE_HOME": home.appendingPathComponent(".cache").path,
            "XDG_STATE_HOME": home.appendingPathComponent(".local/state").path,
            "SHELL": bash,
            "GDK_BACKEND": "broadway",
            "BROADWAY_DISPLAY": ":\(display)",
            "TOASTTY_LINUX_SMOKE_SCRIPT": scriptURL.path,
            "TOASTTY_LINUX_AUTOMATION_ROOT": repoRoot.path,
            "TOASTTY_TERMINAL_PROFILES_PATH": profiles.path,
        ]
        for (key, value) in isolated { environment[key] = value }
        for key in environment.keys where key.hasPrefix("TOASTTY_GHOSTTY_CONFIG") { environment.removeValue(forKey: key) }
        let app = try BroadwaySmokeTests.launch(binary, [], environment: environment, log: work.appendingPathComponent("app.log"))

        var viewer: Process?
        if let chrome = BroadwaySmokeTests.which("google-chrome") ?? BroadwaySmokeTests.which("chromium") {
            Thread.sleep(forTimeInterval: 0.4)
            viewer = try? BroadwaySmokeTests.launch(
                chrome,
                [
                    "--headless=new", "--no-first-run", "--no-default-browser-check", "--disable-gpu",
                    "--disable-extensions", "--disable-sync", "--disable-background-timer-throttling",
                    "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows",
                    "--user-data-dir=\(work.appendingPathComponent("chrome").path)", "--window-size=1280,800",
                    "http://127.0.0.1:\(8080 + display)/",
                ],
                environment: BroadwaySmokeTests.cleanEnvironment(extra: [:]),
                log: work.appendingPathComponent("chrome.log")
            )
        }
        defer { if let viewer { BroadwaySmokeTests.stop(viewer, signal: SIGKILL) } }

        let exitStatus = BroadwaySmokeTests.waitForExit(app, timeout: 180)
        if exitStatus == nil {
            BroadwaySmokeTests.stop(app, signal: SIGKILL)
            Issue.record("toastty-linux did not quit within 180s")
        }

        let log = (try? String(contentsOf: work.appendingPathComponent("app.log"), encoding: .utf8)) ?? ""
        let failures = log.split(separator: "\n").filter { $0.contains("[automation] FAIL") }
        #expect(failures.isEmpty, "automation failures:\n\(failures.joined(separator: "\n"))\n\(log.suffix(3000))")
        #expect(exitStatus == 0, "exit status \(String(describing: exitStatus)); log:\n\(log.suffix(4000))")
        #expect(log.contains("Ghostty runtime ready"), "Ghostty did not initialize:\n\(log.prefix(2000))")
        let criticals = log.split(separator: "\n").filter { $0.contains("-CRITICAL") }
        #expect(criticals.isEmpty, "GTK criticals:\n\(criticals.joined(separator: "\n"))")

        for name in ["01-echo.png", "02-split-font-14.png", "03-find.png", "04-unread.png", "05-close-confirm.png", "06-final.png"] {
            let path = artifactDirectory.appendingPathComponent(name).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            #expect(size > 10_000, "\(name) missing or empty")
        }
    }
}
