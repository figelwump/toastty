import Foundation
import Glibc
import Testing

/// Launches `toastty-linux` on a private GDK Broadway display (never the
/// user's session) with an isolated runtime home and drives the WebKitGTK
/// panels with the in-process automation script: a browser on a local
/// `file://` page (target=_blank → new tab, page zoom), Getting Started on
/// `toastty://`, a Markdown local document (rendered text checked through
/// JavaScript, edit → save → disk, external change → reload, find), and a
/// Scratchpad. Screenshots land in `artifacts/manual/linux-panels/`.
///
/// Skip with `TOASTTY_LINUX_SKIP_GUI_TESTS=1`.
@Suite("Panels Broadway smoke", .serialized)
struct PanelsBroadwaySmokeTests {
    static let repoRoot: URL = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/", FileManager.default.fileExists(atPath: directory.appendingPathComponent("linux/Package.swift").path) == false {
            directory = directory.deletingLastPathComponent()
        }
        return directory
    }()

    static func script(fixtures: URL) -> String {
        let f = fixtures.path
        return """
        wait 300
        browser-open file://\(f)/page.html
        web-wait ready
        expect webKind=browser webTitle=Fixture_Page rightPanel=true rightPanelTabs=1
        web-wait text Hello from file page
        screenshot artifacts/manual/linux-panels/01-browser.png
        web-eval document.getElementById("blank").click()
        wait 800
        web-wait ready
        expect rightPanelTabs=2 webTitle=Second_Page
        action text-size.increase
        wait 200
        expect webZoom=1.10
        action text-size.reset
        action help.getting-started
        wait 500
        web-wait ready
        web-wait text Get Started with Toastty
        expect rightPanelTabs=3
        screenshot artifacts/manual/linux-panels/02-getting-started.png
        doc-open \(f)/notes.md
        web-wait ready
        web-wait text Rendered
        web-expect window.ToasttyLocalDocumentPanel.getCurrentBootstrap().format => "markdown"
        expect webKind=localDocument rightPanelTabs=4 webEditing=false
        screenshot artifacts/manual/linux-panels/03-document.png
        web-command local-document.edit
        wait 300
        expect webEditing=true
        web-expect (() => { const b = window.ToasttyLocalDocumentPanel.getCurrentBootstrap(); window.webkit.messageHandlers.toasttyLocalDocumentPanel.postMessage({type: "draftDidChange", content: "Edited Title\\n\\nSaved from smoke", baseContentRevision: b.contentRevision}); return b.isEditing; })() => true
        wait 200
        expect webDirty=true
        wait 500
        screenshot artifacts/manual/linux-panels/04-editing.png
        web-command local-document.save
        wait 600
        expect webEditing=false webDirty=false
        web-wait text Saved from smoke
        file-write \(f)/notes.md Changed On Disk\\n\\nExternal edit reloads the panel.
        wait 800
        web-wait text External edit reloads
        doc-search panel
        wait 300
        expect webSearchMatches=1
        screenshot artifacts/manual/linux-panels/05-find.png
        scratchpad-open \(f)/scratch.html Fixture Scratchpad
        web-wait ready
        web-wait text Scratchpad fixture
        expect webKind=scratchpad rightPanelTabs=5 webTitle=Fixture_Scratchpad
        screenshot artifacts/manual/linux-panels/06-scratchpad.png
        state artifacts/manual/linux-panels/state.json
        quit
        """
    }

    static func writeFixtures(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        <!doctype html><html><head><meta charset="utf-8"><title>Fixture Page</title></head>
        <body style="font-family:sans-serif"><h1>Hello from file page</h1><p>Toastty browser fixture.</p>
        <a id="blank" href="page2.html" target="_blank">open page 2 in a new tab</a></body></html>
        """.write(to: directory.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        try """
        <!doctype html><html><head><meta charset="utf-8"><title>Second Page</title></head><body><h1>Second page</h1></body></html>
        """.write(to: directory.appendingPathComponent("page2.html"), atomically: true, encoding: .utf8)
        try """
        # Panel Notes

        Rendered **Markdown** in the local document panel.

        - alpha
        - beta

        ```swift
        let greeting = "hello"
        ```
        """.write(to: directory.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try """
        <div style="padding:16px;font-family:sans-serif"><h2>Scratchpad fixture</h2><p>Diagram goes here.</p></div>
        """.write(to: directory.appendingPathComponent("scratch.html"), atomically: true, encoding: .utf8)
    }

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

    static func waitForExit(_ process: Process, timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        while Date() < deadline {
            let result = waitpid(process.processIdentifier, &status, WNOHANG)
            if result == process.processIdentifier {
                return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            }
            if result < 0 { return process.isRunning ? nil : process.terminationStatus }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    static func environment(_ extra: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
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
    func browserDocumentScratchpad() throws {
        guard let broadwayd = Self.which("gtk4-broadwayd") else { Issue.record("gtk4-broadwayd not installed"); return }
        guard let binary = Self.appBinary() else { Issue.record("toastty-linux binary not found; build it first"); return }

        let output = Self.repoRoot.appendingPathComponent("artifacts/manual/linux-panels")
        try? FileManager.default.removeItem(at: output)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("toastty-panels-smoke-\(UUID().uuidString)")
        let fixtures = work.appendingPathComponent("fixtures")
        try Self.writeFixtures(fixtures)
        let scriptURL = work.appendingPathComponent("smoke.txt")
        try Self.script(fixtures: fixtures).write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: work) }

        let display = 30 + Int.random(in: 0..<25)
        let broadway = try Self.launch(broadwayd, [":\(display)"], environment: Self.environment([:]), log: work.appendingPathComponent("broadwayd.log"))
        defer { kill(broadway.processIdentifier, SIGKILL); _ = Self.waitForExit(broadway, timeout: 5) }
        Thread.sleep(forTimeInterval: 0.5)

        let runtimeHome = work.appendingPathComponent("runtime-home")
        try FileManager.default.createDirectory(at: runtimeHome, withIntermediateDirectories: true)
        let app = try Self.launch(binary, [], environment: Self.environment([
            "GDK_BACKEND": "broadway",
            "BROADWAY_DISPLAY": ":\(display)",
            "TOASTTY_RUNTIME_HOME": runtimeHome.path,
            "TOASTTY_LINUX_EPHEMERAL_BROWSER": "1",
            "TOASTTY_LINUX_SMOKE_SCRIPT": scriptURL.path,
            "TOASTTY_LINUX_AUTOMATION_ROOT": Self.repoRoot.path,
            "TOASTTY_APP_RESOURCES_PATH": Self.repoRoot.appendingPathComponent("Sources/App/Resources").path,
        ]), log: work.appendingPathComponent("app.log"))

        var viewer: Process?
        if let chrome = Self.which("google-chrome") ?? Self.which("chromium") {
            Thread.sleep(forTimeInterval: 0.4)
            viewer = try? Self.launch(chrome, [
                "--headless=new", "--no-first-run", "--no-default-browser-check", "--disable-gpu", "--disable-extensions",
                "--disable-background-timer-throttling", "--disable-renderer-backgrounding",
                "--user-data-dir=\(work.appendingPathComponent("chrome").path)", "--window-size=1280,800",
                "http://127.0.0.1:\(8080 + display)/",
            ], environment: Self.environment([:]), log: work.appendingPathComponent("chrome.log"))
        }
        defer { if let viewer { kill(viewer.processIdentifier, SIGKILL); _ = Self.waitForExit(viewer, timeout: 5) } }

        let exitStatus = Self.waitForExit(app, timeout: 240)
        if exitStatus == nil {
            kill(app.processIdentifier, SIGKILL)
            Issue.record("toastty-linux did not quit within 240s")
        }
        let log = (try? String(contentsOf: work.appendingPathComponent("app.log"), encoding: .utf8)) ?? ""
        let failures = log.split(separator: "\n").filter { $0.contains("[automation] FAIL") }
        #expect(failures.isEmpty, "automation failures:\n\(failures.joined(separator: "\n"))")
        #expect(exitStatus == 0, "exit status \(String(describing: exitStatus)); log:\n\(log.suffix(4000))")
        let criticals = log.split(separator: "\n").filter { $0.contains("-CRITICAL") && $0.contains("webkit") }
        #expect(criticals.isEmpty, "WebKit criticals:\n\(criticals.joined(separator: "\n"))")
        let saved = try String(contentsOf: fixtures.appendingPathComponent("notes.md"), encoding: .utf8)
        #expect(saved.hasPrefix("Changed On Disk"))
        for name in ["01-browser.png", "02-getting-started.png", "03-document.png", "04-editing.png", "05-find.png", "06-scratchpad.png"] {
            let size = (try? FileManager.default.attributesOfItem(atPath: output.appendingPathComponent(name).path)[.size] as? Int) ?? 0
            #expect(size > 10_000, "\(name) missing or empty")
        }
    }
}
