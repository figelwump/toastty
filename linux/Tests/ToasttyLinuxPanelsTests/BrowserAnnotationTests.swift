import CGtk
import Foundation
import Glibc
import Testing
import ToasttyAppLogic
@testable import ToasttyLinuxUI

/// The cairo screenshot renderer installed into the app-logic layer.
@Suite("Annotated screenshot renderer")
struct AnnotatedScreenshotRendererTests {
    /// A white PNG of the given size (encoded by the renderer's own decoder
    /// path: GdkMemoryTexture → PNG).
    static func whitePNG(width: Int, height: Int) throws -> Data {
        let stride = width * 4
        let pixels = [UInt8](repeating: 255, count: stride * height)
        let bytes = pixels.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
        defer { g_bytes_unref(bytes) }
        let texture = try #require(gdk_memory_texture_new(Int32(width), Int32(height), GDK_MEMORY_R8G8B8A8, bytes, gsize(stride)))
        defer { g_object_unref(UnsafeMutableRawPointer(texture)) }
        return try #require(pngData(fromTexture: texture))
    }

    static func isMarkRed(_ pixel: (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)?) -> Bool {
        guard let pixel else { return false }
        return abs(Int(pixel.red) - 229) < 20 && abs(Int(pixel.green) - 72) < 20 && abs(Int(pixel.blue) - 77) < 20
    }

    static func isWhite(_ pixel: (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)?) -> Bool {
        guard let pixel else { return false }
        return pixel.red > 245 && pixel.green > 245 && pixel.blue > 245
    }

    @Test func drawsNumberedPointsAndRectanglesAtTheirNormalizedPositions() throws {
        let png = try Self.whitePNG(width: 200, height: 100)
        let request = LinuxAnnotationRenderRequest(
            pngData: png,
            viewportSize: CGSize(width: 200, height: 100),
            marks: [
                .init(number: 1, kind: .point(CGPoint(x: 0.5, y: 0.5))),
                .init(number: 2, kind: .rectangle(CGRect(x: 0.1, y: 0.2, width: 0.25, height: 0.6))),
            ]
        )
        let rendered = try LinuxAnnotationScreenshotRenderer.render(request)
        let size = try #require(LinuxAnnotationScreenshotRenderer.size(png: rendered))
        #expect(size.width == 200 && size.height == 100)
        let pixel = { (x: Int, y: Int) in LinuxAnnotationScreenshotRenderer.pixel(png: rendered, x: x, y: y) }

        // Point: red disc (radius 11) inside a white ring, white digit in the middle.
        #expect(Self.isMarkRed(pixel(100 + 7, 50)))
        #expect(Self.isMarkRed(pixel(100, 50 - 8)))
        #expect(Self.isWhite(pixel(100 + 12, 50 - 1)))
        // Rectangle (20,20)-(70,80): red outline, faint red fill, badge on the top-left corner.
        #expect(Self.isMarkRed(pixel(70, 60)))
        #expect(Self.isMarkRed(pixel(45, 80)))
        let fill = try #require(pixel(50, 60))
        #expect(fill.red > 245 && fill.green < 245 && fill.green > 225)
        #expect(Self.isMarkRed(pixel(20 + 7, 20)))
        // Untouched background.
        #expect(Self.isWhite(pixel(180, 10)))
        #expect(Self.isWhite(pixel(150, 90)))
    }

    @Test func marksScaleWithTheScreenshotDensity() throws {
        // A 2x screenshot of a 100x50 viewport: the disc radius doubles to 22.
        let png = try Self.whitePNG(width: 200, height: 100)
        let request = LinuxAnnotationRenderRequest(
            pngData: png, viewportSize: CGSize(width: 100, height: 50),
            marks: [.init(number: 3, kind: .point(CGPoint(x: 0.5, y: 0.5)))]
        )
        let rendered = try LinuxAnnotationScreenshotRenderer.render(request)
        #expect(Self.isMarkRed(LinuxAnnotationScreenshotRenderer.pixel(png: rendered, x: 100 + 18, y: 50)))
        #expect(Self.isWhite(LinuxAnnotationScreenshotRenderer.pixel(png: rendered, x: 100 + 26, y: 49)) == false)
        #expect(request.markScale(imagePixelWidth: 200) == 2)
    }

    @Test func rejectsDataThatIsNotAnImage() {
        #expect(throws: LinuxAnnotationScreenshotRendererError.invalidPNG) {
            try LinuxAnnotationScreenshotRenderer.render(.init(pngData: Data("nope".utf8), viewportSize: .zero, marks: []))
        }
    }

    @Test func mouseSideButtonsMapToNavigationHistory() {
        #expect(BrowserPanelController.navigationCommand(forMouseButton: 8) == "navigation.back")
        #expect(BrowserPanelController.navigationCommand(forMouseButton: 9) == "navigation.forward")
        #expect(BrowserPanelController.navigationCommand(forMouseButton: 1) == nil)
        #expect(BrowserPanelController.navigationCommand(forMouseButton: 2) == nil)
        #expect(BrowserPanelController.navigationCommand(forMouseButton: 3) == nil)
    }

    @Test func annotateShortcutIsPanelScoped() {
        let binding = LinuxCommandTable.binding("browser.annotate.toggle")
        #expect(binding?.accelerators == ["<Control><Shift>a"])
        // Never taken from a terminal (Ghostty's Ctrl+Shift+A selects all).
        #expect(binding?.scope == .panel)
        #expect(LinuxCommandTable.globalBindings.contains { $0.accelerators.contains("<Control><Shift>a") } == false)
    }
}

/// Launches `toastty-linux` on a private GDK Broadway display (never the
/// user's session) with an isolated HOME and runtime home, then drives
/// browser annotation mode end to end with the automation script: a bash
/// terminal registers a managed session (`toastty session start` + `session
/// status ready`) and runs `cat > handoff.txt`; the browser enters
/// annotation mode with the panel command, a point and a region get
/// comments through the real popover editor, an existing mark opens its
/// detail popover, and "Send to Agent" renders the annotated screenshot and
/// types the payload into that terminal. The test then checks the payload
/// cat wrote, the PNG, and a mark pixel. Screenshots land in
/// `artifacts/manual/linux-annotation/`.
///
/// Skip with `TOASTTY_LINUX_SKIP_GUI_TESTS=1`.
@Suite("Browser annotation Broadway", .serialized)
struct BrowserAnnotationBroadwayTests {
    static let artifacts = "artifacts/manual/linux-annotation"

    static func script(fixtures: URL, handoff: URL) -> String {
        let a = artifacts
        return """
        wait 300
        terminal-wait-prompt 15000
        terminal-type "$TOASTTY_CLI_PATH" session start --agent claude --session annot-e2e && "$TOASTTY_CLI_PATH" session status --session annot-e2e --kind ready --summary Ready && cat > \(handoff.path)
        terminal-key Return
        wait 1500
        terminal-dump \(a)/terminal-before.txt
        browser-open file://\(fixtures.path)/page.html
        web-wait ready
        web-wait text Annotation fixture
        expect webKind=browser annotationMode=false annotationDrafts=0 annotationModeBar=false
        screenshot \(a)/01-browser.png
        web-command browser.annotate.toggle
        wait 300
        expect annotationMode=true annotationModeBar=true annotationPopover=none
        annotate-click 120 90
        expect annotationPopover=create annotationPopoverShown=true
        annotate-comment Make the headline larger
        wait 300
        screenshot \(a)/02-pending-mark.png
        annotate-popover-screenshot \(a)/02b-comment-popover.png
        annotate-save
        expect annotationDrafts=1 annotationPopover=none annotationComments=1:Make_the_headline_larger
        annotate-drag 40 150 360 260
        expect annotationPopover=create
        annotate-comment Tighten the spacing in this card
        annotate-save
        expect annotationDrafts=2 annotationComments=1:Make_the_headline_larger|2:Tighten_the_spacing_in_this_card
        wait 300
        screenshot \(a)/03-marks.png
        annotate-click 120 90
        expect annotationPopover=view annotationPopoverShown=true
        wait 300
        annotate-popover-screenshot \(a)/04-detail-popover.png
        annotate-escape
        expect annotationPopover=none annotationMode=true annotationDrafts=2
        annotate-send first
        expect annotationDrafts=0 annotationMode=false annotationModeBar=false annotationSentTo=annot-e2e annotationSentScreenshots=1
        annotate-expect-payload Browser annotation feedback from Toastty.
        annotate-expect-payload 1. Make the headline larger
        annotate-expect-payload 2. Tighten the spacing in this card
        annotate-expect-payload Page: Annotation Fixture
        annotate-copy-screenshot \(a)/05-annotated-screenshot.png
        annotate-expect-pixel 127 90 229 72 77
        annotate-expect-pixel 200 150 229 72 77
        wait 500
        terminal-key <Control>d
        wait 800
        screenshot \(a)/06-after-send.png
        state \(a)/state.json
        quit
        """
    }

    static func writeFixtures(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        <!doctype html><html><head><meta charset="utf-8"><title>Annotation Fixture</title>
        <style>
        body { margin: 0; font-family: sans-serif; background: #f6f5f4; color: #241f31; }
        header { padding: 28px 40px 12px; } h1 { margin: 0; font-size: 26px; }
        .card { margin: 16px 40px; padding: 14px 18px; background: white; border-radius: 12px; box-shadow: 0 1px 3px rgba(0,0,0,.15); }
        .card p { margin: 4px 0; } .tall { height: 1400px; }
        </style></head>
        <body><header><h1>Annotation fixture</h1><p>Toastty browser annotation test page.</p></header>
        <div class="card"><p><strong>Card title</strong></p><p>Some body text inside a card that needs tighter spacing.</p><p>Another line.</p></div>
        <div class="tall"></div></body></html>
        """.write(to: directory.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOASTTY_LINUX_SKIP_GUI_TESTS"] != "1"))
    func annotateAndSendToAgent() throws {
        typealias S = PanelsBroadwaySmokeTests
        guard let broadwayd = S.which("gtk4-broadwayd") else { Issue.record("gtk4-broadwayd not installed"); return }
        guard let binary = S.appBinary() else { Issue.record("toastty-linux binary not found; build it first"); return }
        guard let bash = S.which("bash") else { Issue.record("bash not found"); return }

        let output = S.repoRoot.appendingPathComponent(Self.artifacts)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Short base: Broadway and automation sockets live in XDG_RUNTIME_DIR
        // (108-byte AF_UNIX limit).
        let base = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? FileManager.default.temporaryDirectory.path
        let work = URL(fileURLWithPath: base).appendingPathComponent("tta-\(UUID().uuidString.prefix(4))")
        let home = work.appendingPathComponent("home")
        let runtime = work.appendingPathComponent("r")
        let runtimeHome = work.appendingPathComponent("h")
        for directory in [home, runtime, runtimeHome] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        defer { if ProcessInfo.processInfo.environment["TOASTTY_LINUX_TEST_KEEP"] != "1" { try? FileManager.default.removeItem(at: work) } }
        let fixtures = work.appendingPathComponent("fixtures")
        try Self.writeFixtures(fixtures)
        let handoff = work.appendingPathComponent("handoff.txt")
        let scriptURL = work.appendingPathComponent("annotation.txt")
        try Self.script(fixtures: fixtures, handoff: handoff).write(to: scriptURL, atomically: true, encoding: .utf8)

        var environment = S.environment([
            "XDG_RUNTIME_DIR": runtime.path,
            "NO_AT_BRIDGE": "1",
            "GDK_DEBUG": "no-portals",
            "GSETTINGS_BACKEND": "memory",
        ])
        environment.removeValue(forKey: "DBUS_SESSION_BUS_ADDRESS")
        for key in environment.keys where key.hasPrefix("TOASTTY_GHOSTTY_CONFIG") { environment.removeValue(forKey: key) }

        let display = 90 + Int.random(in: 0..<10)
        let broadway = try S.launch(broadwayd, [":\(display)"], environment: environment, log: work.appendingPathComponent("broadwayd.log"))
        defer { kill(broadway.processIdentifier, SIGKILL); _ = S.waitForExit(broadway, timeout: 5) }
        Thread.sleep(forTimeInterval: 0.5)

        for (key, value) in [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
            "XDG_CACHE_HOME": home.appendingPathComponent(".cache").path,
            "XDG_STATE_HOME": home.appendingPathComponent(".local/state").path,
            "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path,
            "TMPDIR": work.path,
            "SHELL": bash,
            "GDK_BACKEND": "broadway",
            "BROADWAY_DISPLAY": ":\(display)",
            "TOASTTY_RUNTIME_HOME": runtimeHome.path,
            "TOASTTY_LINUX_NON_UNIQUE": "1",
            "TOASTTY_LINUX_EPHEMERAL_BROWSER": "1",
            "TOASTTY_LINUX_SMOKE_SCRIPT": scriptURL.path,
            "TOASTTY_LINUX_AUTOMATION_ROOT": S.repoRoot.path,
            "TOASTTY_APP_RESOURCES_PATH": S.repoRoot.appendingPathComponent("Sources/App/Resources").path,
        ] { environment[key] = value }
        let app = try S.launch(binary, [], environment: environment, log: work.appendingPathComponent("app.log"))

        var viewer: Process?
        if let chrome = S.which("google-chrome") ?? S.which("chromium") {
            Thread.sleep(forTimeInterval: 0.4)
            viewer = try? S.launch(chrome, [
                "--headless=new", "--no-first-run", "--no-default-browser-check", "--disable-gpu", "--disable-extensions",
                "--disable-background-timer-throttling", "--disable-renderer-backgrounding",
                "--user-data-dir=\(work.appendingPathComponent("chrome").path)", "--window-size=1280,800",
                "http://127.0.0.1:\(8080 + display)/",
            ], environment: S.environment([:]), log: work.appendingPathComponent("chrome.log"))
        }
        defer { if let viewer { kill(viewer.processIdentifier, SIGKILL); _ = S.waitForExit(viewer, timeout: 5) } }

        let exitStatus = S.waitForExit(app, timeout: 240)
        if exitStatus == nil {
            kill(app.processIdentifier, SIGKILL)
            Issue.record("toastty-linux did not quit within 240s")
        }
        let log = (try? String(contentsOf: work.appendingPathComponent("app.log"), encoding: .utf8)) ?? ""
        let failures = log.split(separator: "\n").filter { $0.contains("[automation] FAIL") }
        #expect(failures.isEmpty, "automation failures:\n\(failures.joined(separator: "\n"))\n\(log.suffix(3000))")
        #expect(exitStatus == 0, "exit status \(String(describing: exitStatus)); log:\n\(log.suffix(4000))")
        let criticals = log.split(separator: "\n").filter { $0.contains("-CRITICAL") }
        #expect(criticals.isEmpty, "GTK criticals:\n\(criticals.joined(separator: "\n"))")

        // What the "agent" (cat in the managed terminal) received.
        let received = (try? String(contentsOf: handoff, encoding: .utf8)) ?? ""
        #expect(received.contains("Browser annotation feedback from Toastty."), "handoff:\n\(received)")
        #expect(received.contains("1. Make the headline larger"))
        #expect(received.contains("2. Tighten the spacing in this card"))
        #expect(received.contains("URL: file://\(fixtures.path)/page.html"))
        let screenshotLine = received.split(separator: "\n").first { $0.hasPrefix("Screenshot 1: ") }
        #expect(screenshotLine?.contains("toastty-browser-annotations") == true)

        let annotated = output.appendingPathComponent("05-annotated-screenshot.png")
        let png = try #require(FileManager.default.contents(atPath: annotated.path))
        #expect(png.count > 5_000)
        #expect(AnnotatedScreenshotRendererTests.isMarkRed(LinuxAnnotationScreenshotRenderer.pixel(png: png, x: 127, y: 90)))
        for name in ["01-browser.png", "02-pending-mark.png", "03-marks.png", "06-after-send.png"] {
            let size = (try? FileManager.default.attributesOfItem(atPath: output.appendingPathComponent(name).path)[.size] as? Int) ?? 0
            #expect(size > 10_000, "\(name) missing or empty")
        }
        for name in ["02b-comment-popover.png", "04-detail-popover.png"] {
            let size = (try? FileManager.default.attributesOfItem(atPath: output.appendingPathComponent(name).path)[.size] as? Int) ?? 0
            #expect(size > 1_000, "\(name) missing or empty")
        }
    }
}
