import CoreState
import Testing

struct AgentKindTests {
    @Test
    func displayNameUsesKnownAgentLabels() {
        #expect(AgentKind.codex.displayName == "Codex")
        #expect(AgentKind.claude.displayName == "Claude Code")
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
                    ]
                ),
                AgentProfile(
                    id: "claude",
                    displayName: "Claude Code",
                    argv: ["sclaude"]
                ),
                AgentProfile(
                    id: "claude",
                    displayName: "Claude Prefix Wrapper",
                    argv: ["agent-safehouse", "claude", "--dangerously-skip-permissions"]
                ),
                AgentProfile(
                    id: "gemini",
                    displayName: "Gemini",
                    argv: ["sandbox-wrapper", "gemini"]
                ),
            ]
        )

        let shimCommandNames = ManagedAgentCommandResolver.shimCommandNames(for: catalog)

        #expect(shimCommandNames.contains("codex"))
        #expect(shimCommandNames.contains("claude"))
        #expect(shimCommandNames.contains("run-sandboxed.sh"))
        #expect(shimCommandNames.contains("agent-safehouse"))
        #expect(shimCommandNames.contains("sclaude") == false)
        #expect(shimCommandNames.contains("sandbox-wrapper") == false)
    }
}
