import CoreState
import Foundation
import Testing
@testable import ToasttyLinuxUI

@Suite("Browser link routing")
struct BrowserLinkRoutingTests {
    func decide(
        _ url: String?,
        link: Bool = true,
        newWindow: Bool = false,
        ctrl: Bool = false,
        source: String? = "https://example.com/",
        mainFrame: Bool = true
    ) -> BrowserNavigationDecision {
        BrowserLinkRouting.decision(
            url: url.flatMap(URL.init(string:)),
            isLinkActivation: link,
            opensNewWindow: newWindow,
            ctrlOrMiddleClick: ctrl,
            sourceFrameURL: source.flatMap(URL.init(string:)),
            sourceIsMainFrame: mainFrame
        )
    }

    @Test func plainWebLinksNavigateInPlace() {
        #expect(decide("https://toastty.dev/docs") == .allow)
        #expect(decide("http://localhost:3000/") == .allow)
        #expect(decide("toastty://getting-started/#shortcuts") == .allow)
    }

    @Test func ctrlOrMiddleClickOpensSecondary() {
        #expect(decide("https://toastty.dev/", ctrl: true) == .openSecondary(URL(string: "https://toastty.dev/")!))
    }

    @Test func nonWebSchemesLeaveTheBrowser() {
        #expect(decide("mailto:hi@example.com") == .openSecondary(URL(string: "mailto:hi@example.com")!))
        #expect(decide("file:///tmp/notes.md") == .openSecondary(URL(string: "file:///tmp/notes.md")!))
    }

    @Test func nonLinkNavigationsAreAllowed() {
        #expect(decide("file:///tmp/notes.md", link: false) == .allow)
        #expect(decide(nil, link: false) == .allow)
    }

    @Test func targetBlankRoutesUsableURLsAndCapturesBlankPopups() {
        #expect(decide("https://example.com/a", newWindow: true) == .openSecondary(URL(string: "https://example.com/a")!))
        #expect(decide("about:blank", newWindow: true) == .allow)
        #expect(decide(nil, newWindow: true) == .allow)
        #expect(BrowserLinkRouting.popupCaptureURL(URL(string: "about:blank")) == nil)
    }

    @Test func gettingStartedActionsOnlyFromTrustedPage() {
        let trusted = "toastty://getting-started/"
        #expect(decide("toastty://action/open-agent-profiles", source: trusted) == .dispatchAction(.openAgentProfiles))
        #expect(decide("toastty://action/open-shortcut-reference", source: trusted) == .dispatchAction(.openShortcutReference))
        #expect(decide("toastty://action/open-agent-profiles", source: "https://evil.example/") == .ignore)
        #expect(decide("toastty://action/open-agent-profiles", source: trusted, mainFrame: false) == .ignore)
        #expect(decide("toastty://action/unknown", source: trusted) == .ignore)
        #expect(decide("toastty://action/a/b", source: trusted) == .ignore)
        #expect(GettingStartedAction.openShortcutReference.commandID == "app.shortcuts")
        #expect(LinuxCommandTable.binding(GettingStartedAction.openAgentProfiles.commandID) != nil)
        #expect(LinuxCommandTable.binding(GettingStartedAction.openSkillsManagement.commandID) != nil)
    }

    @Test func userEnteredURLNormalizationMatchesMacOS() {
        let n = BrowserLinkRouting.normalizedUserEnteredURLString
        #expect(n("  ") == nil)
        #expect(n("example.com") == "https://example.com")
        #expect(n("example.com/path?q=1") == "https://example.com/path?q=1")
        #expect(n("localhost") == "http://localhost")
        #expect(n("localhost:8080") == "http://localhost:8080")
        #expect(n("127.0.0.1") == "http://127.0.0.1")
        #expect(n("192.168.1.10:3000/x") == "http://192.168.1.10:3000/x")
        #expect(n("[::1]") == "http://[::1]")
        #expect(n("https://toastty.dev") == "https://toastty.dev")
        #expect(n("about:blank") == "about:blank")
        #expect(n("toastty://getting-started/") == "toastty://getting-started/")
        #expect(n("search words") == "search words")
        #expect(n("intranet") == "intranet")
        #expect(n("/tmp/a b.html") == "file:///tmp/a%20b.html")
    }

    @Test func secondaryTargetsForFallbackRouting() throws {
        #expect(LinuxSecondaryURLTarget.resolve(URL(string: "https://x.dev/")!) == .browser("https://x.dev/"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("panels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let markdown = directory.appendingPathComponent("README.md")
        try "# hi".write(to: markdown, atomically: true, encoding: .utf8)
        #expect(LinuxSecondaryURLTarget.resolve(markdown) == .localDocument(filePath: markdown.path, format: .markdown))
        let html = directory.appendingPathComponent("page.html")
        try "<p>".write(to: html, atomically: true, encoding: .utf8)
        #expect(LinuxSecondaryURLTarget.resolve(html) == .browser(html.absoluteString))
        let missing = directory.appendingPathComponent("gone.md")
        #expect(LinuxSecondaryURLTarget.resolve(missing) == .external(missing))
        #expect(LinuxSecondaryURLTarget.resolve(URL(string: "mailto:a@b.c")!) == .external(URL(string: "mailto:a@b.c")!))
    }
}

@Suite("toastty:// scheme")
struct ToasttyPageSchemeRouterTests {
    @Test func resolvesInsideBundleAndRejectsTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scheme-\(UUID().uuidString)")
        let page = root.appendingPathComponent("local-document-panel")
        try FileManager.default.createDirectory(at: page, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["index.html", "app.js", "onig.wasm"] {
            try Data().write(to: page.appendingPathComponent(name))
        }
        try "secret".write(to: root.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        let directories = ["local-document": page]
        let resolve = { (value: String) in ToasttyPageSchemeRouter.resolve(url: URL(string: value)!, pageDirectories: directories) }

        #expect(resolve("toastty://local-document/")?.fileURL.lastPathComponent == "index.html")
        #expect(resolve("toastty://local-document/index.html")?.mimeType == "text/html")
        #expect(resolve("toastty://local-document/app.js")?.mimeType == "text/javascript")
        #expect(resolve("toastty://local-document/onig.wasm")?.mimeType == "application/wasm")
        #expect(resolve("toastty://local-document/%2E%2E/secret.txt") == nil)
        #expect(resolve("toastty://local-document/..%2Fsecret.txt") == nil)
        #expect(resolve("toastty://unknown/index.html") == nil)
        #expect(resolve("https://local-document/index.html") == nil)
    }

    @Test func bundledPageDirectoriesExistInCheckout() {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/", FileManager.default.fileExists(atPath: directory.appendingPathComponent("Sources/App/Resources/WebPanels").path) == false {
            directory = directory.deletingLastPathComponent()
        }
        let resources = directory.appendingPathComponent("Sources/App/Resources")
        for (_, directory) in WebPanelResources.pageDirectories(resources: resources) {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.html").path), "\(directory.path)")
        }
    }
}

@Suite("Local document navigation")
struct LocalDocumentNavigationTests {
    @Test func onlyTheBundleStaysInThePanel() {
        let policy = LocalDocumentPanelController.navigationPolicy
        #expect(policy("toastty://local-document/index.html", false) == .allow)
        #expect(policy("toastty://local-document/index.html#heading", true) == .allow)
        #expect(policy("about:blank", false) == .allow)
        #expect(policy("https://example.com", true) == .route)
        #expect(policy("https://example.com", false) == .ignore)
        #expect(policy("toastty://local-document/other.md", true) == .route)
    }

    @Test func relativeLinksResolveNextToTheDocument() {
        let target = LocalDocumentPanelController.linkTarget(for: "toastty://local-document/docs/guide.md", documentPath: "/repo/README.md")
        #expect(target?.path == "/repo/docs/guide.md")
        #expect(LocalDocumentPanelController.linkTarget(for: "https://x.dev/", documentPath: nil) == URL(string: "https://x.dev/"))
        #expect(LocalDocumentPanelController.linkTarget(for: "toastty://local-document/index.html", documentPath: "/repo/README.md") == nil)
        #expect(ScratchpadPanelController.allowsNavigation(to: "about:srcdoc"))
        #expect(ScratchpadPanelController.allowsNavigation(to: "https://example.com") == false)
    }
}

@Suite("Downloads")
struct DownloadNamingTests {
    @Test func uniqueDestinationsDoNotOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(WebDownloads.uniqueDestination(directory: directory, suggestedName: "report.pdf").lastPathComponent == "report.pdf")
        try Data().write(to: directory.appendingPathComponent("report.pdf"))
        try Data().write(to: directory.appendingPathComponent("report (2).pdf"))
        #expect(WebDownloads.uniqueDestination(directory: directory, suggestedName: "report.pdf").lastPathComponent == "report (3).pdf")
        #expect(WebDownloads.uniqueDestination(directory: directory, suggestedName: "../../etc/passwd").lastPathComponent == "passwd")
        #expect(WebDownloads.uniqueDestination(directory: directory, suggestedName: "").lastPathComponent == "download")
    }
}
