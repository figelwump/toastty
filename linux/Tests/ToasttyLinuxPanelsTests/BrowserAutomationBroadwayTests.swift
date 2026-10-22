import Foundation
import Glibc
import Testing

/// `toastty browser` end to end: the real `toastty-linux` on a private GDK
/// Broadway display (never the user's session) with an isolated runtime,
/// driven by the staged `toastty` CLI over its automation socket against a
/// `file://` fixture app: open, snapshot refs, fill/press/check/select,
/// actionability (covered element), dialogs, console and network logs,
/// waits, eval, screenshot, upload, link navigation and history.
///
/// Skip with `TOASTTY_LINUX_SKIP_GUI_TESTS=1`.
@Suite("Browser automation (Broadway)", .serialized)
struct BrowserAutomationBroadwayTests {
    static let fixtureHTML = """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>Todo Fixture</title>
    <style> #cover-host { position: relative; } #cover { position: absolute; inset: 0; background: rgba(0,0,0,.2); } </style>
    </head><body>
    <main>
    <h1>Todos</h1>
    <form id="add"><label for="new">New todo</label> <input id="new"> <button type="submit">Add</button></form>
    <ul id="list"></ul>
    <label><input type="checkbox" id="done-all"> Mark all done</label>
    <select id="filter" aria-label="Filter"><option value="all">All</option><option value="done">Done items</option></select>
    <p id="status">0 items</p>
    <button id="confirm" onclick="document.getElementById('status').textContent = confirm('Sure?') ? 'confirmed' : 'cancelled'">Confirm</button>
    <div id="cover-host"><button id="covered">Covered</button><div id="cover"></div></div>
    <button id="go" onclick="location.href = 'second.html'">Go to second page</button>
    <input type="file" id="file" aria-label="Attachment"> <span id="filename"></span>
    <img src="missing.png" alt="">
    </main>
    <script>
    const items = [];
    document.getElementById('add').addEventListener('submit', (e) => {
      e.preventDefault();
      const input = document.getElementById('new');
      items.push(input.value);
      console.log('added', input.value);
      input.value = '';
      document.getElementById('list').innerHTML = items.map((t) => '<li>' + t + '</li>').join('');
      document.getElementById('status').textContent = items.length + ' items';
    });
    document.getElementById('done-all').addEventListener('change', (e) => { document.getElementById('status').textContent = 'all done: ' + e.target.checked; });
    document.getElementById('filter').addEventListener('change', (e) => { document.getElementById('status').textContent = 'filter: ' + e.target.value; });
    document.getElementById('file').addEventListener('change', (e) => { document.getElementById('filename').textContent = Array.from(e.target.files, (f) => f.name + ':' + f.size).join(','); });
    setTimeout(() => document.querySelector('main').insertAdjacentHTML('beforeend', '<p>Loaded late</p>'), 1200);
    console.error('fixture error');
    </script>
    </body></html>
    """

    struct Result {
        let status: Int32
        let output: String
        let error: String
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOASTTY_LINUX_SKIP_GUI_TESTS"] != "1"))
    func browserCommandsDriveALocalApp() throws {
        guard let broadwayd = PanelsBroadwaySmokeTests.which("gtk4-broadwayd") else { Issue.record("gtk4-broadwayd not installed"); return }
        guard let binary = PanelsBroadwaySmokeTests.appBinary() else { Issue.record("toastty-linux binary not found; build it first"); return }
        let cliPath = URL(fileURLWithPath: binary).deletingLastPathComponent().appendingPathComponent("toastty").path
        guard FileManager.default.isExecutableFile(atPath: cliPath) else { Issue.record("toastty CLI not found next to \(binary)"); return }

        // Short paths: the Broadway and automation sockets live under
        // XDG_RUNTIME_DIR, and AF_UNIX paths are limited to 108 bytes.
        let base = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? FileManager.default.temporaryDirectory.path
        let work = URL(fileURLWithPath: base).appendingPathComponent("tt-b-\(UUID().uuidString.prefix(4))")
        let runtime = work.appendingPathComponent("r")
        let fixtures = work.appendingPathComponent("app")
        for directory in [runtime, fixtures] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        defer { try? FileManager.default.removeItem(at: work) }
        try Self.fixtureHTML.write(to: fixtures.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Second</title><h1>Second page</h1>".write(to: fixtures.appendingPathComponent("second.html"), atomically: true, encoding: .utf8)
        try "upload me".write(to: fixtures.appendingPathComponent("upload.txt"), atomically: true, encoding: .utf8)

        var environment = PanelsBroadwaySmokeTests.environment([
            "XDG_RUNTIME_DIR": runtime.path,
            "NO_AT_BRIDGE": "1",
            "GDK_DEBUG": "no-portals",
            "GSETTINGS_BACKEND": "memory",
        ])
        environment.removeValue(forKey: "DBUS_SESSION_BUS_ADDRESS")
        for key in environment.keys where key.hasPrefix("TOASTTY_") { environment.removeValue(forKey: key) }

        let (broadway, display) = try BroadwayLauncher.start(
            broadwayd, displays: 55..<80, environment: environment, log: work.appendingPathComponent("broadwayd.log")
        )
        defer { kill(broadway.processIdentifier, SIGKILL); _ = PanelsBroadwaySmokeTests.waitForExit(broadway, timeout: 5) }

        let home = work.appendingPathComponent("home")
        var appEnvironment = environment
        for (key, value) in [
            "HOME": home.path,
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
            "XDG_CACHE_HOME": home.appendingPathComponent(".cache").path,
            "XDG_STATE_HOME": home.appendingPathComponent(".local/state").path,
            "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path,
            "GDK_BACKEND": "broadway",
            "BROADWAY_DISPLAY": ":\(display)",
            "TOASTTY_RUNTIME_HOME": work.appendingPathComponent("t").path,
            "TOASTTY_LINUX_EPHEMERAL_BROWSER": "1",
        ] { appEnvironment[key] = value }
        let app = try PanelsBroadwaySmokeTests.launch(binary, [], environment: appEnvironment, log: work.appendingPathComponent("app.log"))
        defer { kill(app.processIdentifier, SIGKILL); _ = PanelsBroadwaySmokeTests.waitForExit(app, timeout: 5) }

        var viewer: Process?
        if let chrome = PanelsBroadwaySmokeTests.which("google-chrome") ?? PanelsBroadwaySmokeTests.which("chromium") {
            Thread.sleep(forTimeInterval: 0.4)
            viewer = try? PanelsBroadwaySmokeTests.launch(chrome, [
                "--headless=new", "--no-first-run", "--no-default-browser-check", "--disable-gpu", "--disable-extensions",
                "--disable-background-timer-throttling", "--disable-renderer-backgrounding",
                "--user-data-dir=\(work.appendingPathComponent("chrome").path)", "--window-size=1280,800",
                "http://127.0.0.1:\(8080 + display)/",
            ], environment: environment, log: work.appendingPathComponent("chrome.log"))
        }
        defer { if let viewer { kill(viewer.processIdentifier, SIGKILL); _ = PanelsBroadwaySmokeTests.waitForExit(viewer, timeout: 5) } }

        guard let socket = Self.waitForSocket(in: runtime, timeout: 30) else {
            let log = (try? String(contentsOf: work.appendingPathComponent("app.log"), encoding: .utf8)) ?? ""
            Issue.record("automation socket did not appear:\n\(log.suffix(3000))")
            return
        }
        let cliEnvironment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        func browser(_ arguments: String...) throws -> Result {
            try Self.run(cliPath, ["--socket-path", socket, "browser"] + arguments, environment: cliEnvironment)
        }
        func expectOutput(_ result: Result, contains text: String, _ comment: String) {
            #expect(result.status == 0, "\(comment): exit \(result.status) \(result.error)")
            #expect(result.output.contains(text), "\(comment): \(result.output) \(result.error)")
        }

        let url = fixtures.appendingPathComponent("index.html").absoluteString
        expectOutput(try browser("open", url), contains: "finished", "open")
        let snapshot = try browser("snapshot")
        expectOutput(snapshot, contains: "textbox \"New todo\"", "snapshot")
        let checkboxRef = snapshot.output.range(of: #"checkbox "Mark all done" \[ref=(e\d+)\]"#, options: .regularExpression)
            .map { String(snapshot.output[$0]).components(separatedBy: "ref=").last!.dropLast() }
        #expect(checkboxRef != nil, "no checkbox ref in:\n\(snapshot.output)")

        expectOutput(try browser("fill", "label=New todo", "Buy milk"), contains: "filled textbox \"New todo\"", "fill")
        _ = try browser("press", "Enter", "--target", "#new")
        expectOutput(try browser("text", "#status"), contains: "1 items", "Enter submits the form")
        if let checkboxRef {
            expectOutput(try browser("check", String(checkboxRef)), contains: "checked checkbox", "check by ref")
            expectOutput(try browser("text", "#status"), contains: "all done: true", "checkbox change event")
        }
        _ = try browser("select", "#filter", "Done items")
        expectOutput(try browser("text", "#status"), contains: "filter: done", "select")

        let covered = try browser("click", "#covered", "--timeout", "500")
        #expect(covered.status == 1 && covered.error.contains("covered by div#cover"), "covered click: \(covered.output) \(covered.error)")

        _ = try browser("dialog", "dismiss")
        _ = try browser("click", "#confirm")
        expectOutput(try browser("text", "#status"), contains: "cancelled", "dismissed confirm")
        let console = try browser("console")
        expectOutput(console, contains: "[log] added Buy milk", "console log")
        expectOutput(console, contains: "[error] fixture error", "console error")
        expectOutput(console, contains: "[dialog] confirm \"Sure?\" dismissed", "dialog record")
        expectOutput(try browser("network", "--failed"), contains: "missing.png", "failed image load")

        expectOutput(try browser("wait", "text", "Loaded late", "--timeout", "5000"), contains: "ok after", "wait text")
        expectOutput(try browser("eval", "const a = 2; return a * 21"), contains: "42", "eval statements")
        expectOutput(try browser("eval", "document.title"), contains: "Todo Fixture", "eval expression")

        let shot = work.appendingPathComponent("shot.png")
        expectOutput(try browser("screenshot", "--out", shot.path), contains: shot.path, "screenshot")
        let png = (try? Data(contentsOf: shot)) ?? Data()
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]) && png.count > 1000, "screenshot is not a PNG (\(png.count) bytes)")

        _ = try browser("upload", "#file", fixtures.appendingPathComponent("upload.txt").path)
        expectOutput(try browser("text", "#filename"), contains: "upload.txt:9", "upload")

        // (A file:// link click opens a new tab, like a terminal click on a
        // local HTML file; a script navigation stays in the panel.)
        expectOutput(try browser("click", "text=Go to second page"), contains: "navigated to", "click that navigates")
        expectOutput(try browser("state"), contains: "\"Second\"", "state after navigation")
        expectOutput(try browser("back"), contains: "Todo Fixture", "back")
    }

    static func waitForSocket(in runtime: URL, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let enumerator = FileManager.default.enumerator(atPath: runtime.path) {
                for case let path as String in enumerator where path.hasSuffix("events-v1.sock") {
                    return runtime.appendingPathComponent(path).path
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    static func run(_ path: String, _ arguments: [String], environment: [String: String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        // Foundation reaps the child itself; poll it rather than waitpid.
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let status = process.isRunning ? -1 : process.terminationStatus
        return Result(status: status, output: String(decoding: outputData, as: UTF8.self), error: String(decoding: errorData, as: UTF8.self))
    }
}
