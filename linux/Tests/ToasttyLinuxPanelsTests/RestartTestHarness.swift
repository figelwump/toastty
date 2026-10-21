import Foundation
import Glibc
import Testing

/// Launches `toastty-linux` repeatedly as a normal (non-automation) session
/// against one isolated home, for "survives a restart" tests: a private
/// Broadway display, isolated HOME / XDG dirs, and a runtime home every
/// launch shares. Each `run` executes an automation script and expects the
/// app to quit by itself, cleanly and without automation failures.
final class RestartTestHarness {
    typealias Smoke = PanelsBroadwaySmokeTests

    let work: URL
    let home: URL
    let runtimeHome: URL
    private let runtime: URL
    private let binary: String
    private let broadway: Process
    private var appEnvironment: [String: String]

    var configHome: URL { home.appendingPathComponent(".config") }

    /// nil (with an issue recorded) when Broadway or the app binary is missing.
    init?(name: String, extraEnvironment: [String: String] = [:]) throws {
        guard let broadwayd = Smoke.which("gtk4-broadwayd") else { Issue.record("gtk4-broadwayd not installed"); return nil }
        guard let binary = Smoke.appBinary() else { Issue.record("toastty-linux binary not found; build it first"); return nil }
        self.binary = binary

        let tag = UUID().uuidString.prefix(8)
        work = FileManager.default.temporaryDirectory.appendingPathComponent("toastty-\(name)-\(tag)")
        home = work.appendingPathComponent("home")
        runtimeHome = work.appendingPathComponent("runtime-home")
        // Keep XDG_RUNTIME_DIR short: broadwayd and the automation socket are
        // AF_UNIX sockets under it (108-byte path limit).
        let runtimeBase = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/tmp"
        runtime = URL(fileURLWithPath: runtimeBase).appendingPathComponent("tl-\(name.prefix(2)).\(tag.prefix(4))")
        for directory in [home, runtime, work.appendingPathComponent("tmp")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        chmod(runtime.path, 0o700)

        let display = 30 + Int.random(in: 0..<25)
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

        do {
            broadway = try Smoke.launch(broadwayd, [":\(display)"], environment: base, log: work.appendingPathComponent("broadwayd.log"))
        } catch {
            try? FileManager.default.removeItem(at: work)
            try? FileManager.default.removeItem(at: runtime)
            throw error
        }
        Thread.sleep(forTimeInterval: 0.5)

        appEnvironment = base
        appEnvironment.merge([
            "GDK_BACKEND": "broadway",
            "BROADWAY_DISPLAY": ":\(display)",
            // A normal (non-automation) session, like the user's, in a
            // runtime home that every launch shares.
            "TOASTTY_AUTOMATION": "0",
            "TOASTTY_RUNTIME_HOME": runtimeHome.path,
            "TOASTTY_LINUX_EPHEMERAL_BROWSER": "1",
            "TOASTTY_LINUX_AUTOMATION_ROOT": work.path,
            "TOASTTY_APP_RESOURCES_PATH": Smoke.repoRoot.appendingPathComponent("Sources/App/Resources").path,
        ]) { _, new in new }
        appEnvironment.merge(extraEnvironment) { _, new in new }
    }

    deinit {
        kill(broadway.processIdentifier, SIGKILL)
        _ = Smoke.waitForExit(broadway, timeout: 5)
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.removeItem(at: runtime)
    }

    /// Runs one launch with `script`; the app must quit within 90 s with
    /// status 0 and no `[automation] FAIL` lines.
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

    /// The app's UserDefaults suite as written to disk
    /// (`$XDG_CONFIG_HOME/com.GiantThings.toastty.runtime.<hash>.plist`).
    func storedDefaults() throws -> [String: Any] {
        let plists = try FileManager.default.contentsOfDirectory(atPath: configHome.path)
            .filter { $0.hasPrefix("com.GiantThings.toastty.runtime.") && $0.hasSuffix(".plist") }
        let name = try #require(plists.count == 1 ? plists.first : nil, "expected one runtime defaults plist, found \(plists)")
        let data = try Data(contentsOf: configHome.appendingPathComponent(name))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
}
