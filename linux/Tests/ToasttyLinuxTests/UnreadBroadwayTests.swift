import Foundation
import Glibc
import Testing

/// The workspace unread indicator follows the user reading, end to end in
/// the real `toastty-linux` binary on a private GDK Broadway display (never
/// the user's session), with real senders: a managed agent session driven
/// through the staged `toastty` CLI from a real shell, and `toastty notify`.
///
/// 1. An agent in a background workspace finishes: the workspace's sidebar
///    dot and the session's ready mark appear, and selecting the workspace
///    reads them.
/// 2. `toastty notify` without a panel, for the workspace on screen: like
///    macOS, a click in the focused pane reads it (before, only switching
///    workspaces away and back did; the dot stayed lit).
/// 3. The focused panel's agent finishes while another application has
///    focus: the dot appears, the session row shows no ready dot for the
///    panel the user is looking at (macOS `sessionRailState`), and Toastty
///    becoming active reads it and posts AppKit's activation notifications
///    to the shared layer.
///
/// `BROADWAY_TEST_DISPLAY` picks the display number (default: random;
/// `scripts/linux/test.sh` drops `TOASTTY_*` variables).
/// Skip with `TOASTTY_LINUX_SKIP_GUI_TESTS=1`.
@Suite("Unread indicator (Broadway)", .serialized)
struct UnreadBroadwayTests {
    static let script = """
    wait 300
    terminal-wait-prompt 15000
    expect appActive=true sidebarUnread=none appKitActivations=1/0

    # 1. An agent in workspace 1 finishes while workspace 2 is on screen.
    terminal-type T="$TOASTTY_CLI_PATH"; P="$TOASTTY_PANEL_ID"; ev() { printf '%s' "$2" | "$T" session ingest-agent-event --source claude-hooks --session "$1" --panel "$P" >/dev/null; }
    terminal-key Return
    terminal-type "$T" session start --agent claude --panel "$P" --session s1 >/dev/null; ev s1 '{"hook_event_name":"UserPromptSubmit","prompt":"hi","session_id":"n1"}'; echo STARTED; sleep 3; ev s1 '{"hook_event_name":"Stop","session_id":"n1"}'; sleep 600
    terminal-key Return
    terminal-wait-text 10000 STARTED
    expect sidebarSessions=0:working
    action workspace.create
    expect workspaces=2 workspaceIndex=1
    terminal-wait-state 10000 unreadCounts=1,0
    expect sidebarUnread=0 sidebarSessions=0:ready:ready
    action workspace.select-1
    terminal-wait-state 3000 unreadCounts=0,0
    expect sidebarUnread=none sidebarSessions=0:idle

    # 2. `toastty notify` (no panel) for the workspace on screen. Seeing it
    #    does not read it (macOS parity); a click in the focused pane does.
    action workspace.select-2
    terminal-wait-prompt 15000
    terminal-type "$TOASTTY_CLI_PATH" notify Build finished && echo NOTIFIED
    terminal-key Return
    terminal-wait-text 10000 NOTIFIED
    wait 800
    expect unreadCounts=0,1 sidebarUnread=1
    panel-click
    expect unreadCounts=0,0 sidebarUnread=none
    panel-click
    expect unreadCounts=0,0 workspaceIndex=1

    # 3. The focused panel's agent finishes while another application has focus.
    terminal-type T="$TOASTTY_CLI_PATH"; P="$TOASTTY_PANEL_ID"; ev() { printf '%s' "$2" | "$T" session ingest-agent-event --source claude-hooks --session "$1" --panel "$P" >/dev/null; }
    terminal-key Return
    terminal-type "$T" session start --agent claude --panel "$P" --session s2 >/dev/null; ev s2 '{"hook_event_name":"UserPromptSubmit","prompt":"hi","session_id":"n2"}'; echo STARTED2; sleep 3; ev s2 '{"hook_event_name":"Stop","session_id":"n2"}'; sleep 600
    terminal-key Return
    terminal-wait-text 10000 STARTED2
    app-focus off
    expect appActive=false appKitActivations=1/1
    terminal-wait-state 10000 unreadCounts=0,1
    expect sidebarUnread=1 sidebarSessions=0:idle,1:idle
    app-focus on
    terminal-wait-state 3000 unreadCounts=0,0
    expect sidebarUnread=none sidebarSessions=0:idle,1:idle appKitActivations=2/1
    quit
    """

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOASTTY_LINUX_SKIP_GUI_TESTS"] != "1"))
    func unreadIndicatorFollowsReading() throws {
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

        // Short names: the Broadway and automation sockets live in
        // XDG_RUNTIME_DIR, and AF_UNIX paths are limited to 108 bytes.
        let base = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? FileManager.default.temporaryDirectory.path
        let work = URL(fileURLWithPath: base).appendingPathComponent("tt-u-\(UUID().uuidString.prefix(4))")
        let home = work.appendingPathComponent("home")
        // XDG_RUNTIME_DIR: holds toastty-runtime-<hash>/events-v1.sock.
        let runtime = work.appendingPathComponent("r")
        for directory in [home, runtime] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        defer {
            if ProcessInfo.processInfo.environment["TOASTTY_LINUX_TEST_KEEP"] != "1" {
                try? FileManager.default.removeItem(at: work)
            }
        }
        let scriptURL = work.appendingPathComponent("unread.txt")
        try Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)

        var environment = BroadwaySmokeTests.cleanEnvironment(extra: [
            "XDG_RUNTIME_DIR": runtime.path,
            "GTK_A11Y": "none",
            "NO_AT_BRIDGE": "1",
            "GDK_DEBUG": "no-portals",
            "GSETTINGS_BACKEND": "memory",
        ])
        // No desktop notifications or D-Bus services from the session bus.
        environment.removeValue(forKey: "DBUS_SESSION_BUS_ADDRESS")
        for key in environment.keys where key.hasPrefix("TOASTTY_") { environment.removeValue(forKey: key) }

        let display = ProcessInfo.processInfo.environment["BROADWAY_TEST_DISPLAY"].flatMap(Int.init)
            ?? 60 + Int.random(in: 0..<30)
        let broadway = try BroadwaySmokeTests.launch(
            broadwayd, [":\(display)"], environment: environment, log: work.appendingPathComponent("broadwayd.log")
        )
        defer { BroadwaySmokeTests.stop(broadway, signal: SIGKILL) }
        Thread.sleep(forTimeInterval: 0.5)

        let isolated = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
            "XDG_CACHE_HOME": home.appendingPathComponent(".cache").path,
            "XDG_STATE_HOME": home.appendingPathComponent(".local/state").path,
            "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path,
            "SHELL": bash,
            "GDK_BACKEND": "broadway",
            "BROADWAY_DISPLAY": ":\(display)",
            "TOASTTY_RUNTIME_HOME": work.appendingPathComponent("toastty").path,
            "TOASTTY_LINUX_SMOKE_SCRIPT": scriptURL.path,
            "TOASTTY_LINUX_AUTOMATION_ROOT": work.path,
        ]
        for (key, value) in isolated { environment[key] = value }
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
    }
}
