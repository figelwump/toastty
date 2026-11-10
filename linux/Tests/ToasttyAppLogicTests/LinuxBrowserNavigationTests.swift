import CoreState
import Foundation
import Testing
@testable import ToasttyAppLogic

/// A browser host that records what the runtime asks of it.
@MainActor
final class RecordingBrowserHost: LinuxBrowserPanelHost {
    var currentURLString: String?
    var currentTitle: String?
    var isLoading = false
    var isInWindow = true
    var pageZoom: Double = 1.25
    var synchronized: [WebPanelState] = []
    var reloads: [String] = []

    func focus() -> Bool { true }
    func load(urlString: String) -> Bool { true }
    func goBack() -> Bool { false }
    func goForward() -> Bool { false }
    func reloadOrStop() -> Bool { true }
    func reload(urlString: String) -> Bool { reloads.append(urlString); return true }
    func synchronize(webState: WebPanelState) { synchronized.append(webState) }
    func focusLocationField() {}
    var canGoBack: Bool { false }
    var canGoForward: Bool { false }
    var faviconPNG: Data? { nil }
    var viewportSize: CGSize { CGSize(width: 800, height: 600) }
    func captureScreenshotPNG() async throws -> Data { Data() }
    func pageScrollOffset() async -> CGPoint? { .zero }
}

@MainActor
@Suite(.serialized)
struct LinuxBrowserNavigationStateTests {
    private static let pageURL = "https://example.com/page"

    private func makeRuntime() -> BrowserPanelRuntime {
        BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            responderDidRequestFocus: { _ in },
            openSecondaryURL: { _, _ in false }
        )
    }

    private var webState: WebPanelState {
        WebPanelState(definition: .browser, initialURL: Self.pageURL)
    }

    @Test func withoutAHostTheStateIsIdleAndReportsNoObservedPage() {
        let runtime = makeRuntime()
        runtime.apply(webState: webState)
        let state = runtime.automationState()
        #expect(state.navigationState == .idle)
        #expect(state.observedURL == nil)
        #expect(state.title == nil)
        #expect(state.lifecycleState == .detached)
        #expect(state.pageZoom == WebPanelState.defaultBrowserPageZoom)
    }

    @Test func navigationEventsDriveTheReportedResult() {
        let runtime = makeRuntime()
        let host = RecordingBrowserHost()
        runtime.attach(host: host)
        #expect(runtime.automationState().navigationState == .idle)

        runtime.hostDidReport(.started)
        host.isLoading = true
        #expect(runtime.automationState().navigationState == .loading)

        host.isLoading = false
        host.currentURLString = Self.pageURL
        host.currentTitle = "  Example  "
        runtime.hostDidReport(.finished)
        let finished = runtime.automationState()
        #expect(finished.navigationState == .finished)
        #expect(finished.navigationError == nil)
        #expect(finished.observedURL == Self.pageURL)
        #expect(finished.title == "Example")
        #expect(finished.pageZoom == 1.25)
        #expect(finished.lifecycleState.attachmentToken != nil)
    }

    @Test func aFailureStaysTheResultThroughWebKitsFinishedEvent() {
        let runtime = makeRuntime()
        runtime.attach(host: RecordingBrowserHost())
        runtime.hostDidReport(.started)
        runtime.hostDidReport(.failed(domain: "WebKitNetworkError", code: 404, message: "not found"))
        runtime.hostDidReport(.finished)
        let state = runtime.automationState()
        #expect(state.navigationState == .failed)
        #expect(state.navigationError?.domain == "WebKitNetworkError")
        #expect(state.navigationError?.code == 404)
        #expect(state.navigationError?.message == "not found")

        // A settled result does not turn into a failure (macOS `finishNavigation`).
        runtime.hostDidReport(.started)
        runtime.hostDidReport(.finished)
        runtime.hostDidReport(.failed(domain: "WebKitWebProcessTerminated", code: 0, message: "terminated"))
        #expect(runtime.automationState().navigationState == .finished)
        #expect(runtime.automationState().navigationError == nil)
    }

    @Test func anOffScreenHostReportsDetached() {
        let runtime = makeRuntime()
        let host = RecordingBrowserHost()
        host.isInWindow = false
        runtime.attach(host: host)
        #expect(runtime.automationState().lifecycleState == .detached)
        host.isInWindow = true
        #expect(runtime.automationState().lifecycleState.attachmentToken != nil)
    }

    @Test func stateQueriesAndReloadsMaterializeAHostForAHiddenPanel() {
        let runtime = makeRuntime()
        let host = RecordingBrowserHost()
        host.isInWindow = false
        var materialized: [UUID] = []
        LinuxBrowserHostMaterializer.materialize = { panelID in
            materialized.append(panelID)
            runtime.attach(host: host)
        }
        defer { LinuxBrowserHostMaterializer.materialize = nil }

        runtime.apply(webState: webState)
        #expect(materialized == [runtime.panelID])
        #expect(host.synchronized.map(\.restorableURL) == [Self.pageURL])

        // The host now exists: no second materialization.
        #expect(runtime.reload(webState: webState))
        #expect(materialized.count == 1)
        #expect(host.reloads == [Self.pageURL])
        #expect(runtime.automationState().navigationState == .loading)
    }

    @Test func reloadWithoutADestinationOrHostFails() {
        let runtime = makeRuntime()
        #expect(runtime.reload(webState: webState) == false)
        let host = RecordingBrowserHost()
        runtime.attach(host: host)
        #expect(runtime.reload(webState: WebPanelState(definition: .browser)) == false)
        #expect(host.reloads.isEmpty)
    }

    @Test func detachingClearsTheResult() {
        let runtime = makeRuntime()
        runtime.attach(host: RecordingBrowserHost())
        runtime.hostDidReport(.started)
        runtime.hostDidReport(.finished)
        runtime.detachHost()
        #expect(runtime.automationState().navigationState == .idle)
    }
}

/// `ToasttyAgentPluginBundle.linuxBundleRootURL`: the shipped skills come
/// from an install's resources or, in a checkout, the repository root.
@Suite
struct LinuxAgentPluginBundleLocationTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func environment(resources: URL) -> [String: String] {
        [ToasttyLaunchContextEnvironment.appResourcesPathKey: resources.path]
    }

    @Test func aCheckoutUsesTheRepositoryRoot() throws {
        let resources = Self.repoRoot.appendingPathComponent("Sources/App/Resources", isDirectory: true)
        let root = try #require(ToasttyAgentPluginBundle.linuxBundleRootURL(environment: Self.environment(resources: resources)))
        #expect(root.standardizedFileURL.path == Self.repoRoot.standardizedFileURL.path)
        let descriptor = try ToasttyAgentPluginBundle.read(
            pluginRootURL: root.appendingPathComponent("plugins/toastty", isDirectory: true)
        )
        #expect(descriptor.skillNames == ToasttyShippedSkillCatalog.skills.map(\.name))
    }

    @Test func anInstallUsesTheBundleInItsResources() throws {
        let resources = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-plugin-bundle-\(UUID().uuidString)/share/toastty/Resources", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: resources.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let bundle = resources.appendingPathComponent(ToasttyAgentPluginBundle.bundleDirectoryName, isDirectory: true)
        let manifest = bundle.appendingPathComponent("plugins/toastty/.claude-plugin", isDirectory: true)
        let marketplace = bundle.appendingPathComponent(".agents/plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: marketplace, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: manifest.appendingPathComponent("plugin.json"))
        try Data("{}".utf8).write(to: marketplace.appendingPathComponent("marketplace.json"))

        let root = ToasttyAgentPluginBundle.linuxBundleRootURL(environment: Self.environment(resources: resources))
        #expect(root?.standardizedFileURL.path == bundle.standardizedFileURL.path)
    }

    @Test func resourcesWithoutABundleResolveToNothing() throws {
        let resources = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-no-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        #expect(ToasttyAgentPluginBundle.linuxBundleRootURL(environment: Self.environment(resources: resources)) == nil)
        #expect(ToasttyAgentPluginBundle.linuxBundleRootURL(environment: [:]) == nil)
    }
}
