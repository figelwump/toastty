import CoreState
import Foundation
import Testing

struct ManagedAgentExecutableResolverTests {
    /// Builds a shim directory that shadows a real tools directory, mirroring the
    /// launch PATH where Toastty's shims come first.
    private func makeFixture(
        commandNames: [String],
        shimCommandNames: [String]
    ) throws -> (shimDirectory: URL, toolsDirectory: URL) {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("managed-agent-executable-resolver-\(UUID().uuidString)", isDirectory: true)
        let shimDirectoryURL = rootURL.appendingPathComponent("shim", isDirectory: true)
        let toolsDirectoryURL = rootURL.appendingPathComponent("tools", isDirectory: true)
        try fileManager.createDirectory(at: shimDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: toolsDirectoryURL, withIntermediateDirectories: true)

        for (directoryURL, names) in [(toolsDirectoryURL, commandNames), (shimDirectoryURL, shimCommandNames)] {
            for name in names {
                let executableURL = directoryURL.appendingPathComponent(name, isDirectory: false)
                try "#!/bin/sh\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
            }
        }
        return (shimDirectoryURL, toolsDirectoryURL)
    }

    /// The behavior `agent.profile.state` exists for: the shim shadows the real
    /// binary on PATH, and resolution must skip past it.
    @Test
    func resolvesPastTheShimDirectoryToTheRealBinary() throws {
        let fixture = try makeFixture(commandNames: ["claude"], shimCommandNames: ["claude"])

        let resolution = ManagedAgentExecutableResolver.resolve(
            commandName: "claude",
            environment: [
                "PATH": "\(fixture.shimDirectory.path):\(fixture.toolsDirectory.path)",
                ToasttyLaunchContextEnvironment.agentBasePathKey: fixture.toolsDirectory.path,
            ],
            excludedDirectoryPaths: [fixture.shimDirectory.path],
            makeBasePathResolver: { _, _ in
                Issue.record("PATH lookup should have resolved without a login-shell probe")
                return ManagedAgentBasePathResolver(environment: [:], fallbackPath: nil)
            }
        )

        #expect(resolution?.executablePath == fixture.toolsDirectory.appendingPathComponent("claude").path)
        #expect(resolution?.fallbackProbeUsed == false)
        #expect(resolution?.directExecutableProbeUsed == false)
    }

    @Test
    func resolvesFirstPartyAliasWhenTheCommandNameIsAbsent() throws {
        let fixture = try makeFixture(commandNames: ["mimo"], shimCommandNames: [])

        let resolution = ManagedAgentExecutableResolver.resolve(
            commandName: "mimocode",
            environment: ["PATH": fixture.toolsDirectory.path],
            excludedDirectoryPaths: [fixture.shimDirectory.path]
        )

        #expect(resolution?.executablePath == fixture.toolsDirectory.appendingPathComponent("mimo").path)
    }

    /// A missing command must report nothing rather than falling back to the shim,
    /// so a preflight can say it is blocked instead of verifying the wrong binary.
    @Test
    func returnsNilWhenOnlyTheShimMatches() throws {
        // A name no real installation can provide, so the login-shell probe cannot
        // rescue the lookup on whichever host runs this.
        let commandName = "toastty-test-agent-\(UUID().uuidString)"
        let fixture = try makeFixture(commandNames: [], shimCommandNames: [commandName])

        let resolution = ManagedAgentExecutableResolver.resolve(
            commandName: commandName,
            environment: ["PATH": fixture.shimDirectory.path],
            excludedDirectoryPaths: [fixture.shimDirectory.path]
        )

        #expect(resolution == nil)
    }

    @Test
    func firstPartyAliasesCoverMimocodeOnly() {
        #expect(ManagedAgentExecutableResolver.firstPartyCommandAliases(for: "MimoCode") == ["mimo"])
        #expect(ManagedAgentExecutableResolver.firstPartyCommandAliases(for: "claude").isEmpty)
    }

    /// A caller on the main actor opts out of the blocking login-shell stages.
    @Test
    func skipsLoginShellProbesWhenTheyAreNotAllowed() throws {
        let fixture = try makeFixture(commandNames: [], shimCommandNames: [])

        let resolution = ManagedAgentExecutableResolver.resolve(
            commandName: "toastty-test-agent-\(UUID().uuidString)",
            environment: ["PATH": fixture.toolsDirectory.path],
            allowsLoginShellProbe: false,
            makeBasePathResolver: { _, _ in
                Issue.record("No login-shell probe should be constructed when probing is disabled")
                return ManagedAgentBasePathResolver(environment: [:], fallbackPath: nil)
            }
        )

        #expect(resolution == nil)
    }
}
