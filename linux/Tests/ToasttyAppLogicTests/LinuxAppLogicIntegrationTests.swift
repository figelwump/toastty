import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyAppLogic

/// End-to-end checks of the Linux bootstrap: the real automation socket
/// driven by the Linux `toastty` CLI, managed-agent hook ingestion, and the
/// Remote Access gateway with a fake native client.
///
/// These bootstrap `LinuxAppLogic` in automation mode (no layout
/// persistence) inside test.sh's isolated HOME/XDG directories.
@MainActor
@Suite(.serialized)
struct LinuxAppLogicIntegrationTests {
    @MainActor
    private struct Instance {
        let logic: LinuxAppLogic
        let root: URL
        let socketPath: String
        let environment: LinuxTestSupport.ScopedEnvironment
        let cli: String

        func toastty(_ arguments: [String], stdin: Data? = nil) async throws -> LinuxTestSupport.ProcessResult {
            try await LinuxTestSupport.run(cli, ["--json", "--socket-path", socketPath] + arguments, stdin: stdin)
        }

        @MainActor
        func tearDown() {
            logic.shutdown(reason: "test_teardown")
            LinuxPlatform.install(HeadlessLinuxPlatformServices())
            // Remote Access keeps its switch and origin in user defaults;
            // later suites in this process expect them unset.
            Self.clearRemoteAccessPreferences()
            environment.restore()
            Self.clearRemoteAccessPreferences()
            try? FileManager.default.removeItem(at: root)
        }

        static func clearRemoteAccessPreferences() {
            RemoteAccessPreferences.persistEnabled(false)
            RemoteAccessPreferences.persistTailnetOrigin(nil)
        }
    }

    private func makeInstance(
        allowsRemoteAccess: Bool = false,
        platformServices: (any LinuxPlatformServices)? = nil,
        remoteAccessPort: UInt16? = nil,
        tailnetServeSetup: RemoteAccessService.TailnetServeSetup? = nil
    ) throws -> Instance {
        let cli = try LinuxTestSupport.productPath("toastty")
        let shim = try LinuxTestSupport.productPath("toastty-agent-shim")
        let root = try LinuxTestSupport.makeTemporaryDirectory("tla")
        let socketPath = root.appendingPathComponent("s.sock").path
        let environment = LinuxTestSupport.ScopedEnvironment()
        environment.set("TOASTTY_AUTOMATION", "1")
        environment.set("TOASTTY_RUN_ID", "linux-app-logic")
        environment.set("TOASTTY_ARTIFACTS_DIR", root.appendingPathComponent("artifacts").path)
        environment.set("TOASTTY_SOCKET_PATH", socketPath)
        var options = LinuxAppLogic.Options(
            cliExecutablePath: cli,
            agentShimExecutablePath: shim,
            platformServices: platformServices,
            allowsRemoteAccess: allowsRemoteAccess,
            runsBackgroundMaintenance: false
        )
        options.remoteAccessPort = remoteAccessPort
        options.remoteAccessTailnetServeSetup = tailnetServeSetup
        let logic = LinuxAppLogic(options: options)
        return Instance(logic: logic, root: root, socketPath: socketPath, environment: environment, cli: cli)
    }

    @Test func cliQueriesAndRunsActionsOverTheRealSocket() async throws {
        let instance = try makeInstance()
        defer { instance.tearDown() }
        let logic = instance.logic
        #expect(logic.automationStartupError == nil)
        #expect(logic.socketPath == instance.socketPath)
        #expect(FileManager.default.fileExists(atPath: instance.socketPath))

        let queries = try await instance.toastty(["query", "list"])
        expectSuccess(queries)
        #expect(queries.stdout.contains("workspace.list"))

        let actions = try await instance.toastty(["action", "list"])
        #expect(actions.status == 0)
        #expect(actions.stdout.contains("workspace.create"))

        let windowID = try #require(logic.state.windows.first?.id)
        let workspaceCountBefore = logic.state.workspacesByID.count
        let created = try await instance.toastty([
            "action", "run", "workspace.create", "--window", windowID.uuidString, "title=From Linux CLI",
        ])
        expectSuccess(created)
        #expect(logic.state.workspacesByID.count == workspaceCountBefore + 1)
        #expect(logic.state.workspacesByID.values.contains { $0.title == "From Linux CLI" })

        let listed = try await instance.toastty(["query", "run", "workspace.list"])
        #expect(listed.status == 0)
        #expect(listed.stdout.contains("From Linux CLI"))

        // The ready file smoke harnesses wait for.
        logic.markAutomationReady()
        let readyFile = instance.root.appendingPathComponent("artifacts/automation-ready-linux-app-logic.json")
        let ready = try JSONSerialization.jsonObject(with: Data(contentsOf: readyFile)) as? [String: Any]
        #expect(ready?["ready"] as? Bool == true)
        #expect(ready?["socketPath"] as? String == instance.socketPath)
    }

    @Test func managedAgentHookEventChangesSessionStatus() async throws {
        let instance = try makeInstance()
        defer { instance.tearDown() }
        let logic = instance.logic
        let workspace = try #require(logic.store.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)

        let started = try await instance.toastty([
            "session", "start", "--agent", "claude", "--panel", panelID.uuidString, "--session", "linux-hook-session",
        ])
        expectSuccess(started)
        try await LinuxTestSupport.waitUntil("session start") {
            logic.sessionRuntimeStore.sessionRegistry.activeSession(for: panelID)?.sessionID == "linux-hook-session"
        }

        let payload = Data(#"{"hook_event_name":"UserPromptSubmit","prompt":"port toastty to linux","session_id":"claude-native-1"}"#.utf8)
        let ingested = try await instance.toastty(
            ["session", "ingest-agent-event", "--source", "claude-hooks", "--session", "linux-hook-session", "--panel", panelID.uuidString],
            stdin: payload
        )
        expectSuccess(ingested)
        try await LinuxTestSupport.waitUntil("working status") {
            logic.sessionStatus(panelID: panelID)?.status.kind == .working
        }
        #expect(logic.sessionStatuses(workspaceID: workspace.id).contains { $0.sessionID == "linux-hook-session" })

        let stopPayload = Data(#"{"hook_event_name":"Stop","session_id":"claude-native-1"}"#.utf8)
        let stopped = try await instance.toastty(
            ["session", "ingest-agent-event", "--source", "claude-hooks", "--session", "linux-hook-session", "--panel", panelID.uuidString],
            stdin: stopPayload
        )
        #expect(stopped.status == 0)
        try await LinuxTestSupport.waitUntil("ready status") {
            logic.sessionStatus(panelID: panelID)?.status.kind == .ready
        }
    }

    @Test func terminalSeamCarriesLaunchEnvironmentAndAutomationInput() async throws {
        let instance = try makeInstance()
        defer { instance.tearDown() }
        let logic = instance.logic
        let panelID = try #require(logic.store.selectedWorkspace?.focusedPanelID)

        let launch = try #require(logic.terminalLaunchConfiguration(panelID: panelID))
        #expect(launch.environment[ToasttyLaunchContextEnvironment.socketPathKey] == instance.socketPath)
        #expect(launch.environment[ToasttyLaunchContextEnvironment.panelIDKey] == panelID.uuidString)
        #expect(launch.environment[ToasttyLaunchContextEnvironment.cliPathKey] != nil)

        let surface = RecordingTerminalSurface()
        logic.attachTerminalSurface(surface, panelID: panelID)
        logic.terminalSurfaceDidLaunch(panelID: panelID)
        try await Task.sleep(nanoseconds: 80_000_000) // input stability interval

        let sent = try await instance.toastty([
            "action", "run", "terminal.send-text", "--panel", panelID.uuidString, "text=echo hi", "submit=true",
        ])
        expectSuccess(sent)
        #expect(surface.typed == ["echo hi"])
        #expect(surface.returnCount == 1)

        surface.visibleText = "faraz@ubuntu:~$ echo hi\nhi\n"
        let read = try await instance.toastty([
            "query", "run", "terminal.visible-text", "--panel", panelID.uuidString,
        ])
        expectSuccess(read)
        #expect(read.stdout.contains("echo hi"))

        surface.prompt = .busy
        #expect(logic.terminalRuntimeRegistry.promptState(panelID: panelID) == .busy)
        logic.reportTerminalMetadata(panelID: panelID, title: "vim notes.md", workingDirectory: "/home/test/notes")
        guard case .terminal(let terminal)? = logic.store.selectedWorkspace?.panelState(for: panelID) else {
            Issue.record("expected terminal panel")
            return
        }
        #expect(terminal.cwd == "/home/test/notes")
    }

    /// The frontend entry points the GTK shell calls besides the socket:
    /// terminal link clicks (macOS command-click rules), app commands
    /// (`scratchpad.create`), browser secondary opens, and desktop
    /// notifications with click-through back to their panel.
    @Test func frontendLinksCommandsAndNotificationClickThrough() async throws {
        let services = HeadlessLinuxPlatformServices()
        var externallyOpened: [URL] = []
        services.urlOpener = { url in
            externallyOpened.append(url)
            return true
        }
        let instance = try makeInstance(platformServices: services)
        defer { instance.tearDown() }
        let logic = instance.logic
        let workspaceID = try #require(logic.store.selectedWorkspace?.id)
        let panelID = try #require(logic.store.selectedWorkspace?.focusedPanelID)
        func rightPanelWebPanels() -> [WebPanelState] {
            (logic.state.workspacesByID[workspaceID]?.rightAuxPanel.orderedTabs ?? []).compactMap {
                if case .web(let web) = $0.panelState { return web }
                return nil
            }
        }

        // Terminal links: a Markdown file opens a local document panel, an
        // https URL a Toastty browser panel, and other schemes the desktop.
        let notes = instance.root.appendingPathComponent("notes.md")
        try "# Notes\n".write(to: notes, atomically: true, encoding: .utf8)
        #expect(logic.openTerminalLink(panelID: panelID, url: notes, alternate: false))
        #expect(rightPanelWebPanels().contains { $0.definition == .localDocument && $0.localDocument?.filePath == notes.path })
        #expect(logic.openTerminalLink(panelID: panelID, url: URL(string: "https://example.com/docs")!, alternate: false))
        #expect(rightPanelWebPanels().contains { $0.definition == .browser && $0.initialURL == "https://example.com/docs" })
        let mail = URL(string: "mailto:dev@example.com")!
        #expect(logic.openTerminalLink(panelID: panelID, url: mail, alternate: false))
        #expect(externallyOpened == [mail])

        // A browser popup to a local HTML file stays in Toastty on Linux.
        let browserPanelID = try #require(logic.state.workspacesByID[workspaceID]?.rightAuxPanel.orderedTabs.first {
            if case .web(let web) = $0.panelState { return web.definition == .browser }
            return false
        }?.panelID)
        let page = instance.root.appendingPathComponent("page2.html")
        try "<title>Two</title>".write(to: page, atomically: true, encoding: .utf8)
        #expect(logic.browserRequestsSecondaryOpen(panelID: browserPanelID, url: page))
        #expect(rightPanelWebPanels().contains { $0.definition == .browser && $0.initialURL == page.absoluteString })
        #expect(externallyOpened == [mail])

        // App commands the GTK command table forwards.
        let windowID = try #require(logic.state.windows.first?.id)
        #expect(logic.performAppCommand("scratchpad.create", windowID: windowID) == .handled)
        #expect(rightPanelWebPanels().contains { $0.definition == .scratchpad })
        #expect(logic.performAppCommand("no.such.command", windowID: windowID) == .notHandled)

        // OSC 9/777 desktop notification from a terminal in a background
        // workspace, then a click on it focuses that terminal again.
        let created = try await instance.toastty([
            "action", "run", "workspace.create", "--window", windowID.uuidString, "title=Elsewhere",
        ])
        expectSuccess(created)
        try await LinuxTestSupport.waitUntil("other workspace selected") {
            logic.store.selectedWorkspace?.id != workspaceID
        }
        #expect(logic.handleTerminalRuntimeEvent(panelID: panelID, event: .desktopNotification(title: "Build", body: "done")))
        try await LinuxTestSupport.waitUntil("desktop notification delivered") {
            services.deliveredNotifications.contains { $0.body.contains("done") }
        }
        let delivered = try #require(services.deliveredNotifications.last)
        LinuxPlatform.handleNotificationActivation(identifier: delivered.identifier, userInfo: delivered.userInfo)
        try await LinuxTestSupport.waitUntil("click-through focuses the panel") {
            logic.store.selectedWorkspace?.id == workspaceID && logic.store.selectedWorkspace?.focusedPanelID == panelID
        }
    }

    @Test func remoteAccessPairsANativeClientAndStreamsTheSessionList() async throws {
        let port = try LinuxTestSupport.freeLoopbackPort()
        let origin = "https://toastty-linux.tailnet.ts.net"
        let instance = try makeInstance(
            allowsRemoteAccess: true,
            remoteAccessPort: port,
            tailnetServeSetup: { _, _, _ in origin }
        )
        defer { instance.tearDown() }
        let logic = instance.logic
        #expect(logic.isRemoteAccessAvailable)

        logic.setRemoteAccessTailnetOrigin(origin)
        logic.setRemoteAccessEnabled(true)
        try await LinuxTestSupport.waitUntil("pairing available") {
            logic.remoteAccessStatus?.canIssuePairingOffer == true
        }
        #expect(logic.remoteAccessStatus?.port == port)

        logic.issueRemoteAccessPairingOffer()
        let png = try #require(logic.remoteAccessPairingQRCodePNG)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let offer = try #require(logic.remoteAccessService?.currentNativePairingOffer)
        #expect(logic.remoteAccessStatus?.pairingFallbackCode == offer.fallbackCode)

        // A fake phone: the native pairing exchange, then REST and WebSocket
        // with the issued Bearer credential, as the iOS client does through
        // Tailscale Serve (which adds Tailscale-User-Login).
        let login = "phone-owner@example.com"
        let client = RawHTTPClient(port: port)
        let exchangeBody = try ConversationEventCoding.makeEncoder().encode(
            RemoteGatewayNativePairingExchangeRequest(deviceName: "Linux test phone", offerID: offer.id, secret: offer.qrPayload.secret)
        )
        let exchange = try await client.request(
            "POST /v1/native-pairing/exchange",
            headers: ["Tailscale-User-Login": login, "Content-Type": "application/json"],
            body: exchangeBody
        )
        if exchange.status != 200 {
            Issue.record(Comment(rawValue: "pairing exchange failed: \(exchange.status) \(String(decoding: exchange.body, as: UTF8.self))"))
        }
        let credential = try ConversationEventCoding.makeDecoder()
            .decode(RemoteGatewayNativePairingExchangeResponse.self, from: exchange.body).credential
        try await LinuxTestSupport.waitUntil("device recorded") {
            logic.remoteAccessStatus?.devices.contains { $0.name == "Linux test phone" } == true
        }

        let auth = ["Authorization": "Bearer \(credential)", "Tailscale-User-Login": login]
        let sessions = try await client.request("GET /api/sessions", headers: auth)
        #expect(sessions.status == 200)
        let snapshot = try ConversationEventCoding.makeDecoder()
            .decode(RemoteGatewaySessionListResponse.self, from: sessions.body).snapshot
        #expect(snapshot.conversations.count >= 0)

        let socket = try await RawWebSocketClient.connect(port: port, path: "/api/subscribe", headers: auth)
        defer { socket.close() }
        try await LinuxTestSupport.waitUntil("websocket registered") {
            (logic.remoteAccessStatus?.connectedClientCount ?? 0) >= 1
        }
        let text = try await socket.receiveText(timeout: 5)
        let message = try ConversationEventCoding.makeDecoder().decode(RemoteGatewayStreamMessage.self, from: Data(text.utf8))
        guard case .sessionList = message else {
            Issue.record("expected a session list, got \(text.prefix(200))")
            return
        }

        logic.setRemoteAccessEnabled(false)
        try await LinuxTestSupport.waitUntil("remote access off") { logic.remoteAccessStatus?.isEnabled == false }
    }
}

private func expectSuccess(_ result: LinuxTestSupport.ProcessResult, sourceLocation: SourceLocation = #_sourceLocation) {
    if result.status != 0 {
        Issue.record(
            Comment(rawValue: "toastty exited \(result.status): \(result.stderr) \(result.stdout)"),
            sourceLocation: sourceLocation
        )
    }
}

/// A terminal surface that records what the app layer sends it.
@MainActor
final class RecordingTerminalSurface: LinuxTerminalSurface {
    var isReadyForInput = true
    var typed: [String] = []
    var returnCount = 0
    var escapeCount = 0
    var visibleText: String?
    var prompt: LinuxTerminalPromptState = .idleAtPrompt
    var needsCloseConfirmation: Bool? = false
    var actions: [String] = []
    var invalidated = false

    func sendText(_ text: String) { typed.append(text) }
    func sendReturn() -> Bool { returnCount += 1; return true }
    func sendEscape() -> Bool { escapeCount += 1; return true }
    func readText(includeScrollback: Bool) -> String? { visibleText }
    func performBindingAction(_ action: String) -> Bool { actions.append(action); return true }
    func grabFocus() -> Bool { true }
    var promptState: LinuxTerminalPromptState { prompt }
    func invalidate() { invalidated = true }
}
