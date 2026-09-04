import CoreState
import RemoteProtocol
import Testing
@testable import ToasttyApp

struct AgentLaunchArgumentOverrideAdapterTests {
    @Test
    func omittedOverridesPreserveConfiguredArgvExactly() throws {
        let configured = [
            "/usr/local/bin/agent-safehouse",
            "--telemetry=/tmp/trace.jsonl",
            "codex",
            "--model=profile-default",
            "--search",
        ]

        let result = try AgentLaunchArgumentOverrideAdapter.applying(
            model: nil,
            reasoningEffort: nil,
            to: configured,
            agent: .codex,
            profileID: "codex"
        )

        #expect(result == configured)
    }

    @Test
    func codexOverridesReplaceModelAndReasoningAcrossEquivalentFlags() throws {
        let result = try AgentLaunchArgumentOverrideAdapter.applying(
            model: "gpt-5.6-codex",
            reasoningEffort: "high\"confidence",
            to: [
                "/usr/local/bin/run-sandboxed.sh",
                "--telemetry=/tmp/trace.jsonl",
                "codex",
                "--model=first-profile-model",
                "-m", "profile-model",
                "--config=model_reasoning_effort='medium'",
                "-c", "\"model\"=\"older-model\"",
                "--config", "'model_reasoning_effort'='low'",
                "--config", "sandbox_workspace_write.network_access=true",
                "--search",
            ],
            agent: .codex,
            profileID: "codex"
        )

        #expect(result == [
            "/usr/local/bin/run-sandboxed.sh",
            "--telemetry=/tmp/trace.jsonl",
            "codex",
            "--model", "gpt-5.6-codex",
            "--config", "model_reasoning_effort=\"high\\\"confidence\"",
            "--config", "sandbox_workspace_write.network_access=true",
            "--search",
        ])
    }

    @Test
    func codexOverrideFailsClosedForComplexQuotedConfigKeys() {
        for assignment in [
            "\"mo\\u0064el\"=\"profile-model\"",
            "\"model=profile-model",
        ] {
            #expect(throws: (any Error).self) {
                _ = try AgentLaunchArgumentOverrideAdapter.applying(
                    model: "replacement",
                    reasoningEffort: nil,
                    to: ["codex", "--config", assignment],
                    agent: .codex,
                    profileID: "codex"
                )
            }
        }
    }

    @Test
    func codexOverridesAreIndependentAndPreservePassthroughArguments() throws {
        let reasoningOnly = try AgentLaunchArgumentOverrideAdapter.applying(
            model: nil,
            reasoningEffort: "high",
            to: [
                "codex", "exec",
                "--model", "profile-model",
                "--config", "model=\"config-model\"",
                "--config", "model_reasoning_effort=\"medium\"",
                "--", "--model", "literal-prompt-token",
            ],
            agent: .codex,
            profileID: "codex"
        )
        let modelOnly = try AgentLaunchArgumentOverrideAdapter.applying(
            model: "replacement-model",
            reasoningEffort: nil,
            to: [
                "codex",
                "--model", "profile-model",
                "--config", "model_reasoning_effort=\"medium\"",
            ],
            agent: .codex,
            profileID: "codex"
        )

        #expect(reasoningOnly == [
            "codex",
            "--config", "model_reasoning_effort=\"high\"",
            "exec",
            "--model", "profile-model",
            "--config", "model=\"config-model\"",
            "--", "--model", "literal-prompt-token",
        ])
        #expect(modelOnly == [
            "codex",
            "--model", "replacement-model",
            "--config", "model_reasoning_effort=\"medium\"",
        ])
    }

    @Test
    func claudeOverridesReplaceConfiguredFlagsAndPreserveUnrelatedArguments() throws {
        let result = try AgentLaunchArgumentOverrideAdapter.applying(
            model: "claude-opus-next",
            reasoningEffort: "xhigh",
            to: [
                "claude",
                "--model=profile-model",
                "--effort", "medium",
                "--permission-mode", "plan",
            ],
            agent: .claude,
            profileID: "claude"
        )

        #expect(result == [
            "claude",
            "--model", "claude-opus-next",
            "--effort", "xhigh",
            "--permission-mode", "plan",
        ])
    }

    @Test
    func cursorModelOverrideUsesCanonicalExecutableAndDocumentedLongFlag() throws {
        let result = try AgentLaunchArgumentOverrideAdapter.applying(
            model: "composer-next",
            reasoningEffort: nil,
            to: ["cursor-agent", "--model=profile-model", "--force"],
            agent: .cursor,
            profileID: "cursor"
        )

        #expect(result == ["cursor-agent", "--model", "composer-next", "--force"])
    }

    @Test
    func cursorRejectsStandaloneReasoningEffort() {
        #expect(
            throws: AgentLaunchError.launchOverrideUnsupported(
                parameter: "reasoningEffort",
                profileID: "cursor"
            )
        ) {
            _ = try AgentLaunchArgumentOverrideAdapter.applying(
                model: nil,
                reasoningEffort: "high",
                to: ["cursor-agent"],
                agent: .cursor,
                profileID: "cursor"
            )
        }
    }

    @Test
    func cursorModelOverrideDoesNotTreatGenericAgentAsCursor() {
        #expect(throws: (any Error).self) {
            _ = try AgentLaunchArgumentOverrideAdapter.applying(
                model: "composer-next",
                reasoningEffort: nil,
                to: ["agent"],
                agent: .cursor,
                profileID: "cursor"
            )
        }
    }

    @Test
    func openCodeAndMiMoMapOnlyModel() throws {
        let openCode = try AgentLaunchArgumentOverrideAdapter.applying(
            model: "openai/gpt-next",
            reasoningEffort: nil,
            to: ["opencode", "-m", "profile-model", "--print-logs"],
            agent: .opencode,
            profileID: "opencode"
        )
        let mimo = try AgentLaunchArgumentOverrideAdapter.applying(
            model: "mimo/provider-model",
            reasoningEffort: nil,
            to: ["mimo", "--model=profile-model", "--verbose"],
            agent: .mimocode,
            profileID: "mimocode"
        )

        #expect(openCode == ["opencode", "--model", "openai/gpt-next", "--print-logs"])
        #expect(mimo == ["mimo", "--model", "mimo/provider-model", "--verbose"])
        #expect(openCode.contains("--variant") == false)
        #expect(mimo.contains("--variant") == false)
    }

    @Test
    func piOverridesReplaceModelAndThinking() throws {
        let result = try AgentLaunchArgumentOverrideAdapter.applying(
            model: "provider/pi-next",
            reasoningEffort: "high",
            to: ["pi", "--model", "profile-model", "--thinking=low", "--no-session"],
            agent: .pi,
            profileID: "pi"
        )

        #expect(result == [
            "pi",
            "--model", "provider/pi-next",
            "--thinking", "high",
            "--no-session",
        ])
    }

    @Test
    func openCodeAndMiMoRejectReasoningEffortWithoutProducingArgv() {
        for agent in [AgentKind.opencode, .mimocode] {
            #expect(
                throws: AgentLaunchError.launchOverrideUnsupported(
                    parameter: "reasoningEffort",
                    profileID: agent.rawValue
                )
            ) {
                _ = try AgentLaunchArgumentOverrideAdapter.applying(
                    model: "replacement-model",
                    reasoningEffort: "high",
                    to: [agent == .mimocode ? "mimo" : "opencode", "--model", "profile-model"],
                    agent: agent,
                    profileID: agent.rawValue
                )
            }
        }
    }

    @Test
    func overrideValuesRejectBlankControlLeadingDashAndOversizedInput() {
        let invalidValues = [
            "   ",
            "-provider-model",
            "provider\nmodel",
            "provider\u{0000}model",
            String(repeating: "m", count: 257),
        ]

        for value in invalidValues {
            #expect(throws: (any Error).self) {
                _ = try AgentLaunchArgumentOverrideAdapter.applying(
                    model: value,
                    reasoningEffort: nil,
                    to: ["codex"],
                    agent: .codex,
                    profileID: "codex"
                )
            }
        }
    }

    @Test
    func overrideValueLimitIsMeasuredInUTF8Bytes() throws {
        let exactlyAtLimit = String(repeating: "é", count: 128)
        let overLimit = String(repeating: "é", count: 129)

        let result = try AgentLaunchArgumentOverrideAdapter.applying(
            model: exactlyAtLimit,
            reasoningEffort: nil,
            to: ["codex"],
            agent: .codex,
            profileID: "codex"
        )
        #expect(result == ["codex", "--model", exactlyAtLimit])
        #expect(throws: (any Error).self) {
            _ = try AgentLaunchArgumentOverrideAdapter.applying(
                model: overLimit,
                reasoningEffort: nil,
                to: ["codex"],
                agent: .codex,
                profileID: "codex"
            )
        }
    }

    @Test
    func explicitOverridesRejectOpaqueOrMalformedArgv() {
        #expect(throws: (any Error).self) {
            _ = try AgentLaunchArgumentOverrideAdapter.applying(
                model: "replacement",
                reasoningEffort: nil,
                to: ["custom-wrapper", "codex", "--model", "profile-model"],
                agent: .codex,
                profileID: "codex"
            )
        }
        #expect(throws: (any Error).self) {
            _ = try AgentLaunchArgumentOverrideAdapter.applying(
                model: "replacement",
                reasoningEffort: nil,
                to: ["codex", "--model", "--search"],
                agent: .codex,
                profileID: "codex"
            )
        }
        #expect(throws: (any Error).self) {
            _ = try AgentLaunchArgumentOverrideAdapter.applying(
                model: "replacement",
                reasoningEffort: nil,
                to: ["codex", "-mprofile-model"],
                agent: .codex,
                profileID: "codex"
            )
        }
        #expect(throws: (any Error).self) {
            _ = try AgentLaunchArgumentOverrideAdapter.applying(
                model: "replacement",
                reasoningEffort: nil,
                to: ["agent-safehouse", "-x", "codex"],
                agent: .codex,
                profileID: "codex"
            )
        }
    }

    @Test
    func executableResolutionIgnoresProviderLikeArgumentsAndKnownWrapperValues() throws {
        let direct = try AgentLaunchArgumentOverrideAdapter.applying(
            model: "replacement",
            reasoningEffort: nil,
            to: ["codex", "exec", "codex"],
            agent: .codex,
            profileID: "codex"
        )
        let wrapped = try AgentLaunchArgumentOverrideAdapter.applying(
            model: "replacement",
            reasoningEffort: nil,
            to: ["agent-safehouse", "--cwd", "codex", "codex", "exec"],
            agent: .codex,
            profileID: "codex"
        )

        #expect(direct == ["codex", "--model", "replacement", "exec", "codex"])
        #expect(wrapped == [
            "agent-safehouse", "--cwd", "codex", "codex",
            "--model", "replacement", "exec",
        ])
    }
}
