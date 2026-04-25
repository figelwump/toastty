import CoreState
import Testing

struct AgentKindTests {
    @Test
    func displayNameUsesKnownAgentLabels() {
        #expect(AgentKind.codex.displayName == "Codex")
        #expect(AgentKind.claude.displayName == "Claude Code")
        #expect(AgentKind.pi.displayName == "Pi")
    }

    @Test
    func displayNameHumanizesCustomAgentIDs() throws {
        let gemini = try #require(AgentKind(rawValue: "gemini-cli"))
        #expect(gemini.displayName == "Gemini Cli")
    }

    @Test
    func managedCommandResolverPrefersWrappedBuiltInExecutableForInsertion() {
        let wrapperArgv = [
            "/Users/vishal/.config/sandbox-exec/run-sandboxed.sh",
            "--workdir=/tmp/repo",
            "codex",
            "--dangerously-bypass-approvals-and-sandbox",
        ]

        #expect(
            ManagedAgentCommandResolver.launchInsertionIndex(for: .codex, argv: wrapperArgv)
                == 2
        )
        #expect(
            ManagedAgentCommandResolver.launchInsertionIndex(
                for: .claude,
                argv: ["/Applications/Claude Code.app/Contents/MacOS/cc"]
            ) == 0
        )
        #expect(
            ManagedAgentCommandResolver.launchInsertionIndex(
                for: .codex,
                argv: ["scodex", "--dangerously-bypass-approvals-and-sandbox"]
            ) == 0
        )
        #expect(
            ManagedAgentCommandResolver.launchInsertionIndex(
                for: .pi,
                argv: ["agent-safehouse", "pi", "--mode", "text"]
            ) == 1
        )
    }

    @Test
    func managedCommandResolverInfersWrappedBuiltInsFromCommandNameOrPrefixArguments() {
        #expect(
            ManagedAgentCommandResolver.inferManagedAgent(
                commandName: "run-sandboxed.sh",
                argv: ["run-sandboxed.sh", "--workdir=/tmp/repo", "codex", "--dangerous"]
            ) == .codex
        )
        #expect(
            ManagedAgentCommandResolver.inferManagedAgent(
                commandName: "run-sandboxed.sh",
                argv: ["run-sandboxed.sh", "--cwd", "/tmp/repo", "claude", "--dangerous"]
            ) == .claude
        )
        #expect(
            ManagedAgentCommandResolver.inferManagedAgent(
                commandName: "agent-safehouse",
                argv: ["agent-safehouse", "--cwd", "/tmp/repo", "pi", "--mode", "text"]
            ) == .pi
        )
        #expect(
            ManagedAgentCommandResolver.inferManagedAgent(
                commandName: "sandbox-helper",
                argv: ["sandbox-helper", "npm", "test"]
            ) == nil
        )
        #expect(
            ManagedAgentCommandResolver.inferManagedAgent(
                commandName: "sandbox-helper",
                argv: ["sandbox-helper", "--profile", "codex", "npm", "test"]
            ) == nil
        )
        #expect(
            ManagedAgentCommandResolver.inferManagedAgent(
                commandName: "scodex",
                argv: ["scodex"]
            ) == nil
        )
        #expect(
            ManagedAgentCommandResolver.inferManagedAgent(
                commandName: "claudetools",
                argv: ["claudetools"]
            ) == nil
        )
    }

    @Test
    func managedCommandResolverCollectsConfiguredWrapperShimNamesForBuiltIns() {
        let catalog = AgentCatalog(
            profiles: [
                AgentProfile(
                    id: "codex",
                    displayName: "Codex",
                    argv: [
                        "/Users/vishal/.config/sandbox-exec/run-sandboxed.sh",
                        "codex",
                        "--dangerously-bypass-approvals-and-sandbox",
                    ],
                    manualCommandNames: ["cdx"]
                ),
                AgentProfile(
                    id: "claude",
                    displayName: "Claude Code",
                    argv: ["agent-safehouse", "claude", "--dangerously-skip-permissions"],
                    manualCommandNames: []
                ),
                AgentProfile(
                    id: "claude-helper",
                    displayName: "Claude Helper",
                    argv: ["sandbox-wrapper", "claude"],
                    manualCommandNames: ["sandbox-wrapper"]
                ),
                AgentProfile(
                    id: "pi",
                    displayName: "Pi",
                    argv: ["pi"],
                    manualCommandNames: ["safe-pi"]
                ),
                AgentProfile(
                    id: "gemini",
                    displayName: "Gemini",
                    argv: ["sandbox-wrapper", "gemini"],
                    manualCommandNames: ["sandbox-wrapper"]
                ),
            ]
        )

        let shimCommandNames = ManagedAgentCommandResolver.shimCommandNames(for: catalog)

        #expect(shimCommandNames.contains("codex"))
        #expect(shimCommandNames.contains("claude"))
        #expect(shimCommandNames.contains("pi"))
        #expect(shimCommandNames.contains("cdx"))
        #expect(shimCommandNames.contains("safe-pi"))
        #expect(shimCommandNames.contains("agent-safehouse"))
        #expect(shimCommandNames.contains("sandbox-wrapper") == false)
    }

    @Test
    func managedCommandResolverSuppressesImplicitWrapperDiscoveryWhenManualCommandNamesAreConfigured() {
        let catalog = AgentCatalog(
            profiles: [
                AgentProfile(
                    id: "codex",
                    displayName: "Codex",
                    argv: [
                        "/Users/vishal/.config/sandbox-exec/run-sandboxed.sh",
                        "codex",
                        "--dangerously-bypass-approvals-and-sandbox",
                    ],
                    manualCommandNames: ["cdx"]
                )
            ]
        )

        let shimCommandNames = ManagedAgentCommandResolver.shimCommandNames(for: catalog)

        #expect(shimCommandNames.contains("codex"))
        #expect(shimCommandNames.contains("cdx"))
        #expect(shimCommandNames.contains("run-sandboxed.sh") == false)
    }

    @Test
    func managedCommandResolverKeepsImplicitWrapperDiscoveryAsCompatibilityFallback() {
        let catalog = AgentCatalog(
            profiles: [
                AgentProfile(
                    id: "claude",
                    displayName: "Claude Code",
                    argv: ["agent-safehouse", "claude", "--dangerously-skip-permissions"],
                    manualCommandNames: []
                )
            ]
        )

        let shimCommandNames = ManagedAgentCommandResolver.shimCommandNames(for: catalog)

        #expect(shimCommandNames.contains("claude"))
        #expect(shimCommandNames.contains("agent-safehouse"))
    }

    @Test
    func managedCommandResolverIgnoresManualCommandNamesForNonBuiltIns() {
        let catalog = AgentCatalog(
            profiles: [
                AgentProfile(
                    id: "gemini",
                    displayName: "Gemini",
                    argv: ["sandbox-wrapper", "gemini"],
                    manualCommandNames: ["sandbox-wrapper"]
                )
            ]
        )

        let shimCommandNames = ManagedAgentCommandResolver.shimCommandNames(for: catalog)

        #expect(shimCommandNames.contains("sandbox-wrapper") == false)
    }
}
