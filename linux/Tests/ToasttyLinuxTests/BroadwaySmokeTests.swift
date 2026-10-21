import Foundation
import Glibc
import Testing

/// Launches the real `toastty-linux` binary on a private GDK Broadway
/// display (never the user's Wayland/X session), drives it through GActions
/// with an in-process automation script, asserts on the app's own state
/// summary, and writes screenshots to `artifacts/manual/linux-ui/smoke/`.
///
/// A headless Chrome viewer is attached when `google-chrome` is installed:
/// Broadway only advances the frame clock while a viewer is connected, so
/// without one the run still checks state but screenshots go stale.
///
/// Skip with `TOASTTY_LINUX_SKIP_GUI_TESTS=1`.
@Suite("Broadway smoke", .serialized)
struct BroadwaySmokeTests {
    static let repoRoot = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let script = """
    wait 300
    expect windows=1 workspaces=1 tabs=1 panes=1 sidebar=true zoomed=false gtkPaneds=0 gtkPanelFrames=1
    screenshot artifacts/manual/linux-ui/smoke/01-launch.png
    action layout.split.horizontal
    action layout.split.vertical
    expect panes=3 gtkPaneds=2 gtkPanelFrames=3 focusedPane=2 focusedFrameHighlighted=true
    screenshot artifacts/manual/linux-ui/smoke/02-splits.png
    action layout.split.navigate-left
    expect focusedPane=0
    action workspace.tab.create
    expect tabs=2 tabIndex=1 panes=1
    action workspace.tab.select-previous
    expect tabIndex=0 panes=3 rebuilds=3
    action workspace.create
    expect workspaces=2 workspaceIndex=1 sidebarRows=2
    action workspace.select-1
    expect workspaceIndex=0 panes=3
    action panel.focus-mode.toggle
    expect zoomed=true gtkPaneds=0 gtkPanelFrames=1
    screenshot artifacts/manual/linux-ui/smoke/03-zoomed.png
    action panel.focus-mode.toggle
    expect zoomed=false gtkPaneds=2 gtkPanelFrames=3
    action window.toggle-sidebar
    expect sidebar=false
    screenshot artifacts/manual/linux-ui/smoke/04-sidebar-hidden.png
    action window.toggle-sidebar
    expect sidebar=true
    action window.toggle-right-panel
    expect rightPanel=true
    action window.toggle-right-panel
    expect rightPanel=false
    palette split
    expect dialog=AdwDialog paletteTop=layout.split.horizontal
    close-dialog
    action workspace.rename
    dialog-respond rename Smoke Workspace
    expect workspace=Smoke_Workspace dialog=none
    action layout.split.equalize
    action panel.close
    expect panes=2
    screenshot artifacts/manual/linux-ui/smoke/05-final.png
    state artifacts/manual/linux-ui/smoke/state.json
    quit
    """

    static func which(_ tool: String) -> String? {
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let path = "\(directory)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static func appBinary() -> String? {
        if let explicit = ProcessInfo.processInfo.environment["TOASTTY_LINUX_BINARY"] { return explicit }
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<3 {
            let candidate = directory.appendingPathComponent("toastty-linux").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    /// Polls with `waitpid` instead of `Process.isRunning`/`waitUntilExit`,
    /// which depend on a run loop the test thread does not spin.
    static func waitForExit(_ process: Process, timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        while Date() < deadline {
            let result = waitpid(process.processIdentifier, &status, WNOHANG)
            if result == process.processIdentifier {
                // WIFEXITED / WEXITSTATUS
                return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            }
            if result < 0 { return process.isRunning ? nil : process.terminationStatus }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    static func stop(_ process: Process, signal: Int32) {
        kill(process.processIdentifier, signal)
        _ = waitForExit(process, timeout: 5)
    }

    static func cleanEnvironment(extra: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // Never touch the user's desktop session.
        environment.removeValue(forKey: "WAYLAND_DISPLAY")
        environment.removeValue(forKey: "DISPLAY")
        environment["GTK_A11Y"] = "none"
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    static func launch(_ path: String, _ arguments: [String], environment: [String: String], log: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        return process
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOASTTY_LINUX_SKIP_GUI_TESTS"] != "1"))
    func workspaceSplitTabZoomSidebar() throws {
        guard let broadwayd = Self.which("gtk4-broadwayd") else {
            Issue.record("gtk4-broadwayd not installed")
            return
        }
        guard let binary = Self.appBinary() else {
            Issue.record("toastty-linux binary not found; build it first (swift build --product toastty-linux)")
            return
        }

        let smokeDirectory = Self.repoRoot.appendingPathComponent("artifacts/manual/linux-ui/smoke")
        try? FileManager.default.removeItem(at: smokeDirectory)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("toastty-linux-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let scriptURL = work.appendingPathComponent("smoke.txt")
        try Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let display = 60 + Int.random(in: 0..<30)
        let broadway = try Self.launch(
            broadwayd, [":\(display)"],
            environment: Self.cleanEnvironment(extra: [:]),
            log: work.appendingPathComponent("broadwayd.log")
        )
        // gtk4-broadwayd ignores SIGTERM.
        defer { Self.stop(broadway, signal: SIGKILL) }
        Thread.sleep(forTimeInterval: 0.5)

        let app = try Self.launch(
            binary, [],
            environment: Self.cleanEnvironment(extra: [
                "GDK_BACKEND": "broadway",
                "BROADWAY_DISPLAY": ":\(display)",
                "TOASTTY_LINUX_SMOKE_SCRIPT": scriptURL.path,
                "TOASTTY_LINUX_AUTOMATION_ROOT": Self.repoRoot.path,
            ]),
            log: work.appendingPathComponent("app.log")
        )

        var viewer: Process?
        if let chrome = Self.which("google-chrome") ?? Self.which("chromium") {
            Thread.sleep(forTimeInterval: 0.4)
            viewer = try? Self.launch(
                chrome,
                [
                    "--headless=new", "--no-first-run", "--no-default-browser-check", "--disable-gpu",
                    "--disable-extensions", "--disable-sync", "--disable-background-timer-throttling",
                    "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows",
                    "--user-data-dir=\(work.appendingPathComponent("chrome").path)", "--window-size=1280,800",
                    "http://127.0.0.1:\(8080 + display)/",
                ],
                environment: Self.cleanEnvironment(extra: [:]),
                log: work.appendingPathComponent("chrome.log")
            )
        }
        defer { if let viewer { Self.stop(viewer, signal: SIGKILL) } }

        let exitStatus = Self.waitForExit(app, timeout: 120)
        if exitStatus == nil {
            Self.stop(app, signal: SIGKILL)
            Issue.record("toastty-linux did not quit within 120s")
        }

        let log = (try? String(contentsOf: work.appendingPathComponent("app.log"), encoding: .utf8)) ?? ""
        let failures = log.split(separator: "\n").filter { $0.contains("[automation] FAIL") }
        #expect(failures.isEmpty, "automation failures:\n\(failures.joined(separator: "\n"))")
        #expect(exitStatus == 0, "exit status \(String(describing: exitStatus)); log:\n\(log.suffix(4000))")
        let criticals = log.split(separator: "\n").filter { $0.contains("-CRITICAL") }
        #expect(criticals.isEmpty, "GTK criticals:\n\(criticals.joined(separator: "\n"))")

        for name in ["01-launch.png", "02-splits.png", "03-zoomed.png", "04-sidebar-hidden.png", "05-final.png"] {
            let path = smokeDirectory.appendingPathComponent(name).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            #expect(size > 10_000, "\(name) missing or empty")
        }
    }
}
