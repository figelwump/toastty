import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct AgentProfileStateAppControlTests {
    private func makeService(
        profiles: [AgentProfile],
        environment: [String: String],
        shimDirectoryPaths: [String?]
    ) -> AgentLaunchService {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        return AgentLaunchService(
            store: store,
            terminalCommandRouter: TestTerminalCommandRouter(),
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: TestAgentCatalogProvider(profiles: profiles),
            managedAgentResolutionContextProvider: {
                ManagedAgentResolutionContext(
                    environment: environment,
                    shimDirectoryPaths: shimDirectoryPaths
                )
            }
        )
    }

    private func makeExecutable(named name: String, in directoryURL: URL) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let executableURL = directoryURL.appendingPathComponent(name, isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    }

    /// The reason this query exists: a caller's own PATH resolves the shim, so the
    /// query must report the binary a launch would exec instead.
    @Test
    func reportsTheRealExecutableRatherThanTheShimOnPath() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-profile-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let shimURL = rootURL.appendingPathComponent("shim", isDirectory: true)
        let toolsURL = rootURL.appendingPathComponent("tools", isDirectory: true)
        try makeExecutable(named: "claude", in: shimURL)
        try makeExecutable(named: "claude", in: toolsURL)

        let service = makeService(
            profiles: [AgentProfile(id: "claude", displayName: "Claude Code", argv: ["claude"])],
            environment: [
                "PATH": "\(shimURL.path):\(toolsURL.path)",
                ToasttyLaunchContextEnvironment.agentBasePathKey: toolsURL.path,
            ],
            shimDirectoryPaths: [shimURL.path]
        )

        let state = try service.profileExecutableState(profileID: "claude")

        #expect(state.executablePath == toolsURL.appendingPathComponent("claude").path)
        #expect(state.source == .configured)
        #expect(state.commandIsExplicitPath == false)
        #expect(state.failure == nil)
    }

    /// A built-in profile with no agents.toml override still resolves, and reports
    /// that its command name was implied rather than configured.
    @Test
    func resolvesImplicitProfileAndMarksItsSource() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-profile-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let toolsURL = rootURL.appendingPathComponent("tools", isDirectory: true)
        try makeExecutable(named: "codex", in: toolsURL)

        let service = makeService(
            profiles: [AgentProfile(id: "claude", displayName: "Claude Code", argv: ["claude"])],
            environment: ["PATH": toolsURL.path],
            shimDirectoryPaths: []
        )

        let state = try service.profileExecutableState(profileID: "codex")

        #expect(state.source == .implicit)
        #expect(state.executablePath == toolsURL.appendingPathComponent("codex").path)
    }

    /// An argv[0] with a path separator is run as-is, so it is checked directly
    /// instead of being looked up on PATH.
    @Test
    func checksAnExplicitArgvPathWithoutAPathLookup() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-profile-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let toolsURL = rootURL.appendingPathComponent("tools", isDirectory: true)
        try makeExecutable(named: "cursor-agent", in: toolsURL)
        let explicitPath = toolsURL.appendingPathComponent("cursor-agent").path

        let service = makeService(
            profiles: [AgentProfile(id: "cursor", displayName: "Cursor", argv: [explicitPath])],
            environment: ["PATH": ""],
            shimDirectoryPaths: []
        )

        let state = try service.profileExecutableState(profileID: "cursor")

        #expect(state.commandIsExplicitPath)
        #expect(state.executablePath == explicitPath)
        #expect(state.failure == nil)
    }

    /// Reporting the failure is the point: a preflight must be able to say it is
    /// blocked rather than silently verifying some other binary.
    @Test
    func reportsFailureWhenTheCommandCannotBeResolved() throws {
        let service = makeService(
            profiles: [AgentProfile(id: "claude", displayName: "Claude Code", argv: ["toastty-absent-command"])],
            environment: ["PATH": "/nonexistent-\(UUID().uuidString)"],
            shimDirectoryPaths: []
        )

        let state = try service.profileExecutableState(profileID: "claude")

        #expect(state.executablePath == nil)
        #expect(state.failure == .commandNotFound)
    }

    /// Toastty quotes argv, so the shell never expands `~`. Reporting an expanded
    /// path would name a file the launch would not use.
    @Test
    func reportsTildeAndRelativeArgvPathsInsteadOfResolvingThem() throws {
        for command in ["~/bin/agent-tool", "./agent-tool"] {
            let service = makeService(
                profiles: [AgentProfile(id: "claude", displayName: "Claude Code", argv: [command])],
                environment: ["PATH": "/usr/bin"],
                shimDirectoryPaths: []
            )

            let state = try service.profileExecutableState(profileID: "claude")

            #expect(state.commandIsExplicitPath)
            #expect(state.executablePath == nil)
            #expect(state.failure == .explicitPathNotAbsolute)
        }
    }

    /// The query runs on the main actor, so a miss must return promptly rather than
    /// blocking on login-shell probes.
    @Test
    func aMissReturnsWithoutSpawningALoginShell() throws {
        let service = makeService(
            profiles: [AgentProfile(id: "claude", displayName: "Claude Code", argv: ["toastty-absent-\(UUID().uuidString)"])],
            environment: ["PATH": "/nonexistent-\(UUID().uuidString)"],
            shimDirectoryPaths: []
        )

        let start = Date()
        let state = try service.profileExecutableState(profileID: "claude")

        #expect(state.failure == .commandNotFound)
        #expect(state.fallbackProbeUsed == false)
        #expect(state.directExecutableProbeUsed == false)
        // A login-shell probe would take seconds; the PATH-only path is immediate.
        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    /// The profile's remaining arguments are deliberately not returned, since they
    /// do not affect which executable runs.
    @Test
    func reportsArgumentCountWithoutTheArgumentsThemselves() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-profile-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let toolsURL = rootURL.appendingPathComponent("tools", isDirectory: true)
        try makeExecutable(named: "codex", in: toolsURL)

        let service = makeService(
            profiles: [AgentProfile(
                id: "codex",
                displayName: "Shipper",
                argv: ["codex", "--ask-for-approval", "never"]
            )],
            environment: ["PATH": toolsURL.path],
            shimDirectoryPaths: []
        )

        let state = try service.profileExecutableState(profileID: "codex")

        #expect(state.command == "codex")
        #expect(state.argumentCount == 2)
    }

    /// Both shim directories can shadow the real binary, so both must be excluded.
    @Test
    func excludesTheCompatibilityShimDirectoryAsWellAsTheInstalledOne() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-profile-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let installedShimURL = rootURL.appendingPathComponent("instance-shim", isDirectory: true)
        let compatibilityShimURL = rootURL.appendingPathComponent("compat-shim", isDirectory: true)
        let toolsURL = rootURL.appendingPathComponent("tools", isDirectory: true)
        try makeExecutable(named: "claude", in: installedShimURL)
        try makeExecutable(named: "claude", in: compatibilityShimURL)
        try makeExecutable(named: "claude", in: toolsURL)

        let service = makeService(
            profiles: [AgentProfile(id: "claude", displayName: "Claude Code", argv: ["claude"])],
            environment: [
                "PATH": "\(installedShimURL.path):\(compatibilityShimURL.path):\(toolsURL.path)",
            ],
            shimDirectoryPaths: [installedShimURL.path, compatibilityShimURL.path]
        )

        let state = try service.profileExecutableState(profileID: "claude")

        #expect(state.executablePath == toolsURL.appendingPathComponent("claude").path)
    }

    /// A configuration reload recomputes the base path and reinstalls shims; later
    /// queries must see the new context rather than the one captured at startup.
    @Test
    func contextStoreUpdatesAreVisibleToLaterQueries() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-profile-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let firstURL = rootURL.appendingPathComponent("first", isDirectory: true)
        let secondURL = rootURL.appendingPathComponent("second", isDirectory: true)
        try makeExecutable(named: "claude", in: firstURL)
        try makeExecutable(named: "claude", in: secondURL)

        let store = ManagedAgentResolutionContextStore(
            context: ManagedAgentResolutionContext(
                environment: ["PATH": firstURL.path],
                shimDirectoryPaths: []
            )
        )
        let appStore = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: appStore)
        let service = AgentLaunchService(
            store: appStore,
            terminalCommandRouter: TestTerminalCommandRouter(),
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: TestAgentCatalogProvider(
                profiles: [AgentProfile(id: "claude", displayName: "Claude Code", argv: ["claude"])]
            ),
            managedAgentResolutionContextProvider: { store.current() }
        )

        #expect(try service.profileExecutableState(profileID: "claude").executablePath
            == firstURL.appendingPathComponent("claude").path)

        store.update(ManagedAgentResolutionContext(
            environment: ["PATH": secondURL.path],
            shimDirectoryPaths: []
        ))

        #expect(try service.profileExecutableState(profileID: "claude").executablePath
            == secondURL.appendingPathComponent("claude").path)
    }

    @Test
    func rejectsAnUnknownProfile() {
        let service = makeService(
            profiles: [AgentProfile(id: "claude", displayName: "Claude Code", argv: ["claude"])],
            environment: ["PATH": "/usr/bin"],
            shimDirectoryPaths: []
        )

        #expect(throws: AgentLaunchError.self) {
            try service.profileExecutableState(profileID: "not-a-profile")
        }
    }

    @Test
    func queryIsRegisteredAsAReadOnlyProfileScopedQuery() throws {
        let descriptor = try #require(AppControlQueryID.resolve("agent.profile.state")?.descriptor)

        #expect(descriptor.kind == .query)
        #expect(descriptor.selectors.isEmpty)
        #expect(descriptor.parameters.map(\.name) == ["profileID"])
    }
}
