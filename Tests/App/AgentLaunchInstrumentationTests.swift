import RemoteProtocol
import Foundation
import XCTest
import CoreState
@testable import ToasttyApp

final class AgentLaunchInstrumentationTests: XCTestCase {
    override func tearDown() {
        AgentLaunchInstrumentation.piExtensionPathProviderForTesting = nil
        super.tearDown()
    }

    func testPrepareClaudeLaunchMergesInlineSettingsArgument() throws {
        let fileManager = FileManager.default
        let sessionID = "test-\(UUID().uuidString)"

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .claude,
            argv: [
                "claude",
                "--settings={\"model\":\"sonnet\",\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"/bin/echo existing\"}]}]}}",
            ],
            cliExecutablePath: "/bin/sh",
            sessionID: sessionID,
            workingDirectory: nil,
            fileManager: fileManager
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? fileManager.removeItem(at: artifacts.directoryURL)
            }
        }

        XCTAssertEqual(preparedLaunch.argv.first, "claude")
        let settingsIndex = try XCTUnwrap(preparedLaunch.argv.firstIndex(of: "--settings"))
        let settingsPath = try XCTUnwrap(preparedLaunch.argv[safe: settingsIndex + 1])
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["model"] as? String, "sonnet")
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["SessionStart"])
        XCTAssertNotNil(hooks["UserPromptSubmit"])
        XCTAssertNotNil(hooks["Stop"])
        XCTAssertNotNil(hooks["SubagentStart"])
        XCTAssertNotNil(hooks["SubagentStop"])
        XCTAssertNotNil(hooks["PreToolUse"])
        XCTAssertNotNil(hooks["PostToolUse"])
        XCTAssertNil(hooks["PostToolUseFailure"])
        XCTAssertNotNil(hooks["PermissionRequest"])
        XCTAssertNotNil(hooks["Notification"])

        let postToolUseEntries = try XCTUnwrap(hooks["PostToolUse"] as? [[String: Any]])
        XCTAssertNotNil(postToolUseEntries.first { ($0["matcher"] as? String) == "Agent" })
        XCTAssertNotNil(postToolUseEntries.first { ($0["matcher"] as? String) == "Task" })

        let notificationEntries = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])
        let matcherEntry = notificationEntries.first { entry in
            (entry["matcher"] as? String) == "*"
        }
        XCTAssertNotNil(matcherEntry, "Notification hook should have a wildcard matcher entry")
    }

    func testPrepareClaudeLaunchAddsToasttyPluginAlongsideUserPluginDirectories() throws {
        let configuration = ClaudeSkillsLaunchConfiguration(
            pluginRootPath: "/tmp/toastty plugin",
            skillsRootPath: "/tmp/toastty plugin/skills",
            version: "1.0.0",
            contentDigest: "abc123"
        )
        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .claude,
            argv: ["claude", "--plugin-dir", "/tmp/user-one", "--plugin-dir=/tmp/user-two", "--model", "opus"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default,
            stagedSkillsIntegration: configuration
        )
        defer { try? preparedLaunch.artifacts.map { try FileManager.default.removeItem(at: $0.directoryURL) } }

        XCTAssertEqual(preparedLaunch.argv.filter { $0 == "--plugin-dir" }.count, 2)
        XCTAssertTrue(preparedLaunch.argv.contains("/tmp/toastty plugin"))
        XCTAssertTrue(preparedLaunch.argv.contains("/tmp/user-one"))
        XCTAssertTrue(preparedLaunch.argv.contains("--plugin-dir=/tmp/user-two"))
        XCTAssertEqual(preparedLaunch.environment["TOASTTY_SKILLS_ROOT"], configuration.skillsRootPath)
    }

    func testPrepareClaudeLaunchAddsToasttyPluginAfterSupportedWrapperCommand() throws {
        let configuration = ClaudeSkillsLaunchConfiguration(
            pluginRootPath: "/tmp/toastty-plugin",
            skillsRootPath: "/tmp/toastty-plugin/skills",
            version: "1.0.0",
            contentDigest: "abc123"
        )
        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .claude,
            argv: ["agent-safehouse", "--cwd", "/tmp/repo", "claude", "--model", "opus"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default,
            stagedSkillsIntegration: configuration
        )
        defer { try? preparedLaunch.artifacts.map { try FileManager.default.removeItem(at: $0.directoryURL) } }

        let claudeIndex = try XCTUnwrap(preparedLaunch.argv.firstIndex(of: "claude"))
        XCTAssertEqual(preparedLaunch.argv[safe: claudeIndex + 3], "--plugin-dir")
        XCTAssertEqual(preparedLaunch.argv[safe: claudeIndex + 4], configuration.pluginRootPath)
        XCTAssertEqual(preparedLaunch.environment["TOASTTY_SKILLS_ROOT"], configuration.skillsRootPath)
    }

    func testPrepareClaudeLaunchAddsUserPluginDirAfterShippedPluginDir() throws {
        let configuration = ClaudeSkillsLaunchConfiguration(
            pluginRootPath: "/tmp/toastty-plugin",
            skillsRootPath: "/tmp/toastty-plugin/skills",
            version: "1.0.0",
            contentDigest: "abc123"
        )
        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .claude,
            argv: ["claude", "--model", "opus"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default,
            stagedSkillsIntegration: configuration,
            deliveredUserSkillsRootPath: "/tmp/user-plugin-root/toastty-user"
        )
        defer { try? preparedLaunch.artifacts.map { try FileManager.default.removeItem(at: $0.directoryURL) } }

        let pluginDirIndices = preparedLaunch.argv.indices.filter {
            preparedLaunch.argv[$0] == "--plugin-dir"
        }
        XCTAssertEqual(pluginDirIndices.count, 2)
        // Shipped plugin first, user plugin second.
        XCTAssertEqual(preparedLaunch.argv[safe: pluginDirIndices[0] + 1], configuration.pluginRootPath)
        XCTAssertEqual(
            preparedLaunch.argv[safe: pluginDirIndices[1] + 1],
            "/tmp/user-plugin-root/toastty-user"
        )
        XCTAssertEqual(preparedLaunch.environment["TOASTTY_SKILLS_ROOT"], configuration.skillsRootPath)
    }

    func testPrepareClaudeLaunchInjectsUserPluginDirIndependentlyOfShippedConfiguration() throws {
        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .claude,
            argv: ["claude"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default,
            stagedSkillsIntegration: nil,
            deliveredUserSkillsRootPath: "/tmp/user-plugin-root/toastty-user"
        )
        defer { try? preparedLaunch.artifacts.map { try FileManager.default.removeItem(at: $0.directoryURL) } }

        XCTAssertEqual(preparedLaunch.argv.filter { $0 == "--plugin-dir" }.count, 1)
        XCTAssertTrue(preparedLaunch.argv.contains("/tmp/user-plugin-root/toastty-user"))
        XCTAssertNil(preparedLaunch.environment["TOASTTY_SKILLS_ROOT"])
    }

    func testPrepareClaudeLaunchOmitsUserPluginDirWhenNoUserRootProvided() throws {
        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .claude,
            argv: ["claude"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default,
            stagedSkillsIntegration: nil,
            deliveredUserSkillsRootPath: nil
        )
        defer { try? preparedLaunch.artifacts.map { try FileManager.default.removeItem(at: $0.directoryURL) } }

        XCTAssertFalse(preparedLaunch.argv.contains("--plugin-dir"))
    }

    func testPrepareClaudeLaunchUserPluginDirCoexistsWithCallerPluginDirs() throws {
        let configuration = ClaudeSkillsLaunchConfiguration(
            pluginRootPath: "/tmp/toastty plugin",
            skillsRootPath: "/tmp/toastty plugin/skills",
            version: "1.0.0",
            contentDigest: "abc123"
        )
        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .claude,
            argv: ["claude", "--plugin-dir", "/tmp/caller-one", "--plugin-dir=/tmp/caller-two", "--model", "opus"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default,
            stagedSkillsIntegration: configuration,
            deliveredUserSkillsRootPath: "/tmp/user-plugin-root/toastty-user"
        )
        defer { try? preparedLaunch.artifacts.map { try FileManager.default.removeItem(at: $0.directoryURL) } }

        XCTAssertEqual(preparedLaunch.argv.filter { $0 == "--plugin-dir" }.count, 3)
        XCTAssertTrue(preparedLaunch.argv.contains("/tmp/toastty plugin"))
        XCTAssertTrue(preparedLaunch.argv.contains("/tmp/user-plugin-root/toastty-user"))
        XCTAssertTrue(preparedLaunch.argv.contains("/tmp/caller-one"))
        XCTAssertTrue(preparedLaunch.argv.contains("--plugin-dir=/tmp/caller-two"))
    }

    func testPrepareClaudeLaunchOmitsUserPluginDirForOpaqueWrapper() throws {
        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .claude,
            argv: ["custom-wrapper", "claude", "--model", "opus"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default,
            stagedSkillsIntegration: nil,
            deliveredUserSkillsRootPath: "/tmp/user-plugin-root/toastty-user"
        )
        defer { try? preparedLaunch.artifacts.map { try FileManager.default.removeItem(at: $0.directoryURL) } }

        XCTAssertFalse(preparedLaunch.argv.contains("--plugin-dir"))
    }

    func testPrepareCodexLaunchGainsOnlyTheProfileFlagForSkills() throws {
        let configuration = CodexSkillsLaunchConfiguration(
            profileName: "toastty-managed",
            codexHomePath: "/tmp/codex-home",
            skillsRootPath: "/tmp/codex-home/plugins/cache/toastty/toastty/1.0.0/skills",
            version: "1.0.0",
            contentDigest: "abc123"
        )
        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .codex,
            argv: ["codex"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default,
            codexStatusTrackingSource: .hooks,
            codexSkillsIntegration: configuration
        )
        defer { try? preparedLaunch.artifacts.map { try FileManager.default.removeItem(at: $0.directoryURL) } }

        // The user plugin rides entirely in the profile overlay: the Codex
        // argv gains only the profile flag, never plugin-dir style arguments.
        XCTAssertEqual(preparedLaunch.argv, ["codex", "--profile", "toastty-managed"])
        XCTAssertEqual(preparedLaunch.codexSkillsInjectionResult, .injected)
    }

    func testPrepareClaudeLaunchOmitsToasttyPluginForOpaqueWrapper() throws {
        let configuration = ClaudeSkillsLaunchConfiguration(
            pluginRootPath: "/tmp/toastty-plugin",
            skillsRootPath: "/tmp/toastty-plugin/skills",
            version: "1.0.0",
            contentDigest: "abc123"
        )
        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .claude,
            argv: ["custom-wrapper", "claude", "--model", "opus"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default,
            stagedSkillsIntegration: configuration
        )
        defer { try? preparedLaunch.artifacts.map { try FileManager.default.removeItem(at: $0.directoryURL) } }

        XCTAssertFalse(preparedLaunch.argv.contains("--plugin-dir"))
        XCTAssertNil(preparedLaunch.environment["TOASTTY_SKILLS_ROOT"])
    }

    func testPrepareCodexLaunchFormatsNotifyOverrideAsTomlArray() throws {
        let fileManager = FileManager.default
        let sessionID = "test-\(UUID().uuidString)"

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .codex,
            argv: ["codex", "--yolo"],
            cliExecutablePath: "/bin/sh",
            sessionID: sessionID,
            workingDirectory: nil,
            fileManager: fileManager
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? fileManager.removeItem(at: artifacts.directoryURL)
            }
        }

        XCTAssertEqual(preparedLaunch.argv.first, "codex")
        let configIndex = try XCTUnwrap(preparedLaunch.argv.firstIndex(of: "-c"))
        let configValue = try XCTUnwrap(preparedLaunch.argv[safe: configIndex + 1])
        let notifyScriptPath = try XCTUnwrap(preparedLaunch.artifacts?.directoryURL.appendingPathComponent("codex-notify.sh").path)

        XCTAssertEqual(
            configValue,
            "notify=[\"/bin/sh\",\"\(notifyScriptPath)\"]"
        )
        XCTAssertFalse(configValue.contains("\\/"))
        XCTAssertEqual(preparedLaunch.argv.last, "--yolo")
        XCTAssertEqual(preparedLaunch.environment["CODEX_TUI_RECORD_SESSION"], "1")
        XCTAssertEqual(preparedLaunch.environment["CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT"], "1")
        XCTAssertEqual(
            preparedLaunch.environment["CODEX_TUI_SESSION_LOG_PATH"],
            preparedLaunch.artifacts?.codexSessionLogURL?.path
        )
    }

    func testPrepareCodexLaunchUsesHooksForStatusAndRecordsSessionContext() throws {
        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .codex,
            argv: ["codex", "--yolo"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default,
            codexStatusTrackingSource: .hooks
        )
        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? FileManager.default.removeItem(at: artifacts.directoryURL)
            }
        }

        XCTAssertEqual(preparedLaunch.argv, ["codex", "--yolo"])
        XCTAssertNotNil(preparedLaunch.artifacts)
        XCTAssertEqual(preparedLaunch.environment["CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT"], "1")
        XCTAssertEqual(preparedLaunch.environment["CODEX_TUI_RECORD_SESSION"], "1")
        XCTAssertEqual(
            preparedLaunch.environment["CODEX_TUI_SESSION_LOG_PATH"],
            preparedLaunch.artifacts?.codexSessionLogURL?.path
        )
    }

    func testPrepareCodexLaunchInsertsNotifyAfterWrappedCodexCommand() throws {
        let fileManager = FileManager.default
        let sessionID = "test-\(UUID().uuidString)"

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .codex,
            argv: [
                "/Users/vishal/.config/sandbox-exec/run-sandboxed.sh",
                "--workdir=/tmp/repo",
                "codex",
                "--dangerously-bypass-approvals-and-sandbox",
            ],
            cliExecutablePath: "/bin/sh",
            sessionID: sessionID,
            workingDirectory: nil,
            fileManager: fileManager
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? fileManager.removeItem(at: artifacts.directoryURL)
            }
        }

        XCTAssertEqual(
            preparedLaunch.argv,
            [
                "/Users/vishal/.config/sandbox-exec/run-sandboxed.sh",
                "--workdir=/tmp/repo",
                "codex",
                "-c",
                "notify=[\"/bin/sh\",\"\(try XCTUnwrap(preparedLaunch.artifacts?.directoryURL.appendingPathComponent("codex-notify.sh").path))\"]",
                "--dangerously-bypass-approvals-and-sandbox",
            ]
        )
    }

    func testPrepareCodexLaunchInjectsManagedProfileDeterministically() throws {
        let configuration = codexSkillsConfiguration(
            skillsRootPath: "/tmp/Skills ü\\root"
        )

        let first = try prepareCodex(
            argv: ["codex", "resume", "thread-id"],
            source: .hooks,
            configuration: configuration
        )
        let second = try prepareCodex(
            argv: ["codex", "resume", "thread-id"],
            source: .hooks,
            configuration: configuration
        )
        defer { cleanup([first, second]) }

        XCTAssertEqual(first.argv, second.argv)
        XCTAssertEqual(first.codexSkillsInjectionResult, .injected)
        XCTAssertEqual(
            first.argv,
            ["codex", "--profile", "toastty-managed", "resume", "thread-id"]
        )
        XCTAssertEqual(first.environment["TOASTTY_SKILLS_ROOT"], "/tmp/Skills ü\\root")
        XCTAssertEqual(configOverrides(in: first.argv), [])
    }

    func testPrepareCodexLaunchInjectsAfterDirectAliasWrapperResumeAndForkExecutable() throws {
        let configuration = codexSkillsConfiguration()
        let cases: [([String], Int, String)] = [
            (["codex", "--search"], 0, "direct"),
            (["cdx", "resume", "abc"], 0, "alias"),
            (["agent-safehouse", "--cwd", "/tmp/repo", "/opt/homebrew/bin/codex", "fork", "abc"], 3, "wrapper fork"),
            (["run-sandboxed.sh", "codex", "resume", "--last"], 1, "wrapper resume"),
        ]

        for (argv, executableIndex, label) in cases {
            let prepared = try prepareCodex(argv: argv, source: .hooks, configuration: configuration)
            defer { cleanup([prepared]) }
            XCTAssertEqual(prepared.codexSkillsInjectionResult, .injected, label)
            XCTAssertEqual(prepared.argv[executableIndex], argv[executableIndex], label)
            XCTAssertEqual(prepared.argv[executableIndex + 1], "--profile", label)
            XCTAssertEqual(prepared.argv[executableIndex + 2], "toastty-managed", label)
        }
    }

    func testPrepareCodexLaunchKeepsNotifyFallbackIndependentFromSkills() throws {
        let prepared = try prepareCodex(
            argv: ["codex", "exec", "prompt"],
            source: .sessionLogFallback(reason: "hooks_untrusted"),
            configuration: codexSkillsConfiguration()
        )
        defer { cleanup([prepared]) }

        XCTAssertEqual(prepared.codexSkillsInjectionResult, .injected)
        let overrides = configOverrides(in: prepared.argv)
        XCTAssertEqual(overrides.count, 1)
        XCTAssertTrue(overrides.contains { $0.hasPrefix("notify=[") })
        XCTAssertTrue(prepared.argv.contains("--profile"))
        XCTAssertTrue(prepared.argv.contains("toastty-managed"))
    }

    func testPrepareCodexLaunchRefusesOpaqueSkillsWithoutChangingHookStatusMode() throws {
        let configuration = codexSkillsConfiguration()
        for argv in [
            ["my-codex-wrapper", "resume", "abc"],
            ["opaque-wrapper", "unexpected", "codex", "resume", "abc"],
            ["wrapper", "--", "codex", "resume", "abc"],
            ["codex", "wrapper", "codex"],
        ] {
            let prepared = try prepareCodex(argv: argv, source: .hooks, configuration: configuration)
            defer { cleanup([prepared]) }
            XCTAssertEqual(
                prepared.codexSkillsInjectionResult,
                .refused(reason: "opaque_or_unsafe_codex_argv")
            )
            XCTAssertEqual(prepared.argv, argv)
            XCTAssertNil(prepared.environment["TOASTTY_SKILLS_ROOT"])
            XCTAssertNotNil(prepared.artifacts?.codexSessionLogURL)
        }
    }

    func testPrepareCodexLaunchRefusesWrapperFlagValuesAndShellIndirection() throws {
        let configuration = codexSkillsConfiguration()
        for argv in [
            ["agent-safehouse", "--profile", "codex", "npm", "test"],
            ["agent-safehouse", "sh", "-c", "codex"],
            ["run-sandboxed.sh", "bash", "-lc", "codex"],
        ] {
            let prepared = try prepareCodex(argv: argv, source: .hooks, configuration: configuration)
            defer { cleanup([prepared]) }

            XCTAssertEqual(
                prepared.codexSkillsInjectionResult,
                .refused(reason: "opaque_or_unsafe_codex_argv")
            )
            XCTAssertEqual(prepared.argv, argv)
            XCTAssertNotNil(prepared.artifacts?.codexSessionLogURL)
        }
    }

    func testPrepareCodexLaunchRefusesCallerProfileFlags() throws {
        let configuration = codexSkillsConfiguration()
        let cases = [
            ["codex", "--profile", "other", "exec", "prompt"],
            ["codex", "--profile=other", "resume"],
            ["codex", "-p", "other", "fork", "thread"],
            ["codex", "-p=other"],
            // clap attached short form: `-pfoo` selects profile "foo".
            ["codex", "-pfoo", "exec", "prompt"],
            ["codex", "-p=foo", "resume"],
            ["run-sandboxed.sh", "codex", "--profile", "other", "resume", "--last"],
        ]

        for argv in cases {
            let prepared = try prepareCodex(argv: argv, source: .hooks, configuration: configuration)
            defer { cleanup([prepared]) }

            XCTAssertEqual(
                prepared.codexSkillsInjectionResult,
                .refused(reason: "caller_profile_flag")
            )
            XCTAssertNil(prepared.environment["TOASTTY_SKILLS_ROOT"])
            XCTAssertNotNil(prepared.artifacts?.codexSessionLogURL)
            XCTAssertFalse(prepared.argv.contains("toastty-managed"))
        }
    }

    func testPrepareCodexLaunchInjectsWhenProfileTokenOnlyFollowsTerminator() throws {
        let prepared = try prepareCodex(
            argv: ["codex", "exec", "--", "--profile"],
            source: .hooks,
            configuration: codexSkillsConfiguration()
        )
        defer { cleanup([prepared]) }

        XCTAssertEqual(prepared.codexSkillsInjectionResult, .injected)
        XCTAssertEqual(
            prepared.argv,
            ["codex", "--profile", "toastty-managed", "exec", "--", "--profile"]
        )
    }

    func testPrepareCodexLaunchInjectsForHintResolvedCustomHomeWithEmptyLaunchEnvironment() throws {
        // Standard shim flow: the shell's real CODEX_HOME travels only in the
        // capability hint, the resolver provisions that home into the
        // configuration, and request.environment stays empty for Codex.
        // Injection must succeed for the provisioned custom home.
        let configuration = codexSkillsConfiguration(
            codexHomePath: "/tmp/toastty-custom-codex-home"
        )

        let prepared = try prepareCodex(
            argv: ["codex", "resume", "abc"],
            source: .hooks,
            configuration: configuration,
            launchEnvironment: [:]
        )
        defer { cleanup([prepared]) }

        XCTAssertEqual(prepared.codexSkillsInjectionResult, .injected)
        XCTAssertEqual(
            prepared.argv,
            ["codex", "--profile", "toastty-managed", "resume", "abc"]
        )
        XCTAssertEqual(prepared.environment["TOASTTY_SKILLS_ROOT"], configuration.skillsRootPath)
    }

    func testPrepareCodexLaunchRefusesReplacedCodexHome() throws {
        let configuration = codexSkillsConfiguration(codexHomePath: "/tmp/toastty-home-a")

        let replaced = try prepareCodex(
            argv: ["codex", "resume", "abc"],
            source: .hooks,
            configuration: configuration,
            launchEnvironment: ["CODEX_HOME": "/tmp/toastty-home-b"]
        )
        let matching = try prepareCodex(
            argv: ["codex", "resume", "abc"],
            source: .hooks,
            configuration: configuration,
            launchEnvironment: ["CODEX_HOME": "/tmp/toastty-home-a"]
        )
        defer { cleanup([replaced, matching]) }

        XCTAssertEqual(
            replaced.codexSkillsInjectionResult,
            .refused(reason: "codex_home_replaced")
        )
        XCTAssertEqual(replaced.argv, ["codex", "resume", "abc"])
        XCTAssertNil(replaced.environment["TOASTTY_SKILLS_ROOT"])
        XCTAssertEqual(matching.codexSkillsInjectionResult, .injected)
        XCTAssertTrue(matching.argv.contains("toastty-managed"))
    }

    func testPrepareCodexLaunchAllowsCallerConfigOverridesIncludingSkillsConfig() throws {
        // The retired `-c skills.config` mechanism treated skills overrides as
        // conflicts; the profile mechanism has no such conflict, and caller
        // `skills.config` toggles are honored by Codex under the profile.
        for argv in [
            ["codex", "-c", "skills.config=[]", "exec", "prompt"],
            ["codex", "-c", "hooks={}", "exec", "prompt"],
            ["codex", "--config", "notify=[\"/usr/bin/true\"]", "resume"],
        ] {
            let prepared = try prepareCodex(
                argv: argv,
                source: .hooks,
                configuration: codexSkillsConfiguration()
            )
            defer { cleanup([prepared]) }

            XCTAssertEqual(prepared.codexSkillsInjectionResult, .injected)
            XCTAssertTrue(prepared.argv.contains("toastty-managed"))
            XCTAssertEqual(configOverrides(in: prepared.argv), configOverrides(in: argv))
        }
    }

    func testPrepareOpenCodeLaunchInjectsFilePluginThroughConfigContent() throws {
        let fileManager = FileManager.default
        let sessionID = "test-\(UUID().uuidString)"

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .opencode,
            argv: ["agent-safehouse", "opencode", "--model", "anthropic/claude-sonnet-4"],
            cliExecutablePath: "/Applications/Toastty.app/Contents/MacOS/toastty",
            sessionID: sessionID,
            workingDirectory: nil,
            fileManager: fileManager
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? fileManager.removeItem(at: artifacts.directoryURL)
            }
        }

        XCTAssertEqual(preparedLaunch.argv, ["agent-safehouse", "opencode", "--model", "anthropic/claude-sonnet-4"])
        XCTAssertNil(preparedLaunch.environment["MIMOCODE_CONFIG_CONTENT"])
        let configContent = try XCTUnwrap(preparedLaunch.environment["OPENCODE_CONFIG_CONTENT"])
        let configObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(configContent.utf8)) as? [String: Any])
        let plugins = try XCTUnwrap(configObject["plugin"] as? [String])
        let pluginSpec = try XCTUnwrap(plugins.first)
        XCTAssertTrue(pluginSpec.hasPrefix("file://"))
        XCTAssertTrue(pluginSpec.hasSuffix("/toastty-opencode-status-plugin.js"))

        let pluginURL = try XCTUnwrap(URL(string: pluginSpec))
        let plugin = try String(contentsOf: pluginURL, encoding: .utf8)
        XCTAssertTrue(plugin.contains("export async function ToasttyOpenCodeFamilyStatusPlugin()"))
        XCTAssertTrue(plugin.contains("const cliPath = "))
        XCTAssertTrue(plugin.contains("Applications"))
        XCTAssertTrue(plugin.contains("Toastty.app"))
        XCTAssertTrue(plugin.contains("Contents"))
        XCTAssertTrue(plugin.contains("MacOS"))
        XCTAssertTrue(plugin.contains("toastty"))
        XCTAssertTrue(plugin.contains(#"const source = "opencode-plugin";"#))
        XCTAssertTrue(plugin.contains(#"const resumeDirectoryPath = "#))
        XCTAssertTrue(plugin.contains(#"managed-agent-resume"#))
        XCTAssertTrue(plugin.contains(#""toastty.native_session""#))
        XCTAssertTrue(plugin.contains(#""permission.replied""#))
        XCTAssertTrue(plugin.contains(#""tool.execute.after""#))
        XCTAssertTrue(plugin.contains(#""experimental.text.complete""#))
        XCTAssertTrue(plugin.contains(#""toastty.final""#))
        XCTAssertTrue(plugin.contains(#""ingest-agent-event""#))
        XCTAssertTrue(plugin.contains(#"const terminalWorkingSuppressMs = 2000;"#))
        XCTAssertTrue(plugin.contains(#"function shouldSuppressWorkingAfterTerminal(event)"#))
        XCTAssertTrue(plugin.contains(#"function flush(event, options)"#))
        XCTAssertTrue(plugin.contains(#"return enqueue(event, options);"#))
        XCTAssertTrue(plugin.contains(#"function questionApprovalStatus()"#))
        XCTAssertTrue(plugin.contains(#"toolAfterDetail(input, output)"#))
        XCTAssertTrue(plugin.contains(#""Approval resolved""#))
        XCTAssertTrue(plugin.contains(#"const openCodeFinalQuietMs = 250;"#))
        XCTAssertTrue(plugin.contains(#"function scheduleOpenCodeFinal(text)"#))
        XCTAssertTrue(plugin.contains(#"if (!isMiMoCode) return;"#))
        XCTAssertTrue(plugin.contains(#"lastForwardedStatusKey = """#))
        XCTAssertTrue(plugin.contains(#"suppressFollowingWorking: true"#))
        XCTAssertFalse(plugin.contains(#"enqueue(toasttyFinal(finalTextFrom(input, output)))"#))
    }

    func testPrepareMiMoCodeLaunchInjectsMiMoConfigContent() throws {
        let fileManager = FileManager.default
        let sessionID = "test-\(UUID().uuidString)"

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .mimocode,
            argv: ["mimo"],
            cliExecutablePath: "/Applications/Toastty.app/Contents/MacOS/toastty",
            sessionID: sessionID,
            workingDirectory: nil,
            fileManager: fileManager
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? fileManager.removeItem(at: artifacts.directoryURL)
            }
        }

        XCTAssertEqual(preparedLaunch.argv, ["mimo"])
        XCTAssertNil(preparedLaunch.environment["OPENCODE_CONFIG_CONTENT"])
        let configContent = try XCTUnwrap(preparedLaunch.environment["MIMOCODE_CONFIG_CONTENT"])
        let configObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(configContent.utf8)) as? [String: Any])
        let plugins = try XCTUnwrap(configObject["plugin"] as? [String])
        let pluginSpec = try XCTUnwrap(plugins.first)
        XCTAssertTrue(pluginSpec.hasPrefix("file://"))
        XCTAssertTrue(pluginSpec.hasSuffix("/toastty-mimocode-status-plugin.js"))

        let pluginURL = try XCTUnwrap(URL(string: pluginSpec))
        let plugin = try String(contentsOf: pluginURL, encoding: .utf8)
        XCTAssertTrue(plugin.contains(#"const source = "mimocode-plugin";"#))
        XCTAssertTrue(plugin.contains(#"const resumeDirectoryPath = "#))
        XCTAssertTrue(plugin.contains(#"managed-agent-resume"#))
        XCTAssertTrue(plugin.contains(#""toastty.native_session""#))
        XCTAssertTrue(plugin.contains(#"hooks["session.userQuery.post"]"#))
        XCTAssertTrue(plugin.contains(#"hooks["session.post"]"#))
        XCTAssertTrue(plugin.contains(#""tool.execute.after""#))
        XCTAssertTrue(plugin.contains(#"resetTurnState();"#))
        XCTAssertTrue(plugin.contains(#"rememberFinalTextCandidate(input, output);"#))
        XCTAssertTrue(plugin.contains(#"return flush(toasttyFinal(text), { suppressFollowingWorking: true });"#))
        XCTAssertTrue(plugin.contains(#"return flush(toasttyFinal(finalTextFrom(input, output) || lastCompletedTextCandidate), { suppressFollowingWorking: true });"#))

        let userQueryPostStart = try XCTUnwrap(plugin.range(of: #"hooks["session.userQuery.post"]"#))
        let sessionPostStart = try XCTUnwrap(plugin.range(of: #"hooks["session.post"]"#))
        let userQueryPostHook = String(plugin[userQueryPostStart.lowerBound..<sessionPostStart.lowerBound])
        XCTAssertTrue(userQueryPostHook.contains("toasttyFinal"))
    }

    func testMiMoCodePluginFlushesUserQueryFinalAndSuppressesLateWorking() throws {
        let events = try runOpenCodeFamilyPluginScenario(
            agent: .mimocode,
            commandName: "mimo",
            configContentEnvironmentKey: "MIMOCODE_CONFIG_CONTENT",
            runnerBody: """
            await hooks["session.pre"]?.({}, {});
            await hooks["session.userQuery.post"]?.({ finalText: "per-step text" }, {});
            hooks["tool.execute.before"]?.({ tool: "bash" });
            await hooks["session.post"]?.({}, {});
            hooks.event?.({
              type: "message.part.updated",
              properties: { part: { type: "text", text: "late text" } },
            });
            """
        )

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0]["type"] as? String, "toastty.status")
        let firstProperties = try XCTUnwrap(events[0]["properties"] as? [String: Any])
        XCTAssertEqual(firstProperties["kind"] as? String, "working")
        XCTAssertEqual(firstProperties["detail"] as? String, "Starting")

        XCTAssertEqual(events[1]["type"] as? String, "toastty.final")
        let secondProperties = try XCTUnwrap(events[1]["properties"] as? [String: Any])
        XCTAssertEqual(secondProperties["text"] as? String, "per-step text")

        XCTAssertFalse(String(describing: events).contains("Using Bash"))
        XCTAssertFalse(String(describing: events).contains("Writing response"))
    }

    func testMiMoCodePluginSuppressesDelayedGenericWorkingAfterUserQueryFinalWithoutSessionPost() throws {
        let events = try runOpenCodeFamilyPluginScenario(
            agent: .mimocode,
            commandName: "mimo",
            configContentEnvironmentKey: "MIMOCODE_CONFIG_CONTENT",
            runnerBody: """
            await hooks["session.pre"]?.({}, {});
            await hooks["session.userQuery.post"]?.({ finalText: "per-step text" }, {});
            const realNow = Date.now;
            const afterFinal = realNow() + 3000;
            Date.now = () => afterFinal;
            hooks.event?.({
              type: "message.part.updated",
              properties: { part: { type: "text", text: "delayed late text" } },
            });
            hooks.event?.({
              type: "session.status",
              properties: { status: { type: "busy" } },
            });
            hooks.event?.({
              type: "message.part.updated",
              properties: { part: { type: "reasoning" } },
            });
            Date.now = realNow;
            """
        )

        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0]["type"] as? String, "toastty.status")
        let firstProperties = try XCTUnwrap(events[0]["properties"] as? [String: Any])
        XCTAssertEqual(firstProperties["kind"] as? String, "working")
        XCTAssertEqual(firstProperties["detail"] as? String, "Starting")

        XCTAssertEqual(events[1]["type"] as? String, "toastty.final")
        let finalProperties = try XCTUnwrap(events[1]["properties"] as? [String: Any])
        XCTAssertEqual(finalProperties["text"] as? String, "per-step text")

        XCTAssertEqual(events[2]["type"] as? String, "toastty.status")
        let resumedProperties = try XCTUnwrap(events[2]["properties"] as? [String: Any])
        XCTAssertEqual(resumedProperties["kind"] as? String, "working")
        XCTAssertEqual(resumedProperties["detail"] as? String, "Reasoning")
        XCTAssertFalse(String(describing: events).contains("Writing response"))
    }

    func testMiMoCodePluginAllowsGenericWorkingAfterNextTurnReset() throws {
        let events = try runOpenCodeFamilyPluginScenario(
            agent: .mimocode,
            commandName: "mimo",
            configContentEnvironmentKey: "MIMOCODE_CONFIG_CONTENT",
            runnerBody: """
            await hooks["session.pre"]?.({}, {});
            await hooks["session.userQuery.post"]?.({ finalText: "per-step text" }, {});
            await hooks["session.post"]?.({}, {});
            const realNow = Date.now;
            const afterFinal = realNow() + 3000;
            Date.now = () => afterFinal;
            hooks.event?.({
              type: "message.part.updated",
              properties: { part: { type: "text", text: "delayed late text" } },
            });
            hooks["session.userQuery.pre"]?.({}, {});
            hooks.event?.({
              type: "message.part.updated",
              properties: { part: { type: "text", text: "new turn text" } },
            });
            Date.now = realNow;
            """
        )

        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0]["type"] as? String, "toastty.status")
        let firstProperties = try XCTUnwrap(events[0]["properties"] as? [String: Any])
        XCTAssertEqual(firstProperties["kind"] as? String, "working")
        XCTAssertEqual(firstProperties["detail"] as? String, "Starting")

        XCTAssertEqual(events[1]["type"] as? String, "toastty.final")
        let finalProperties = try XCTUnwrap(events[1]["properties"] as? [String: Any])
        XCTAssertEqual(finalProperties["text"] as? String, "per-step text")

        XCTAssertEqual(events[2]["type"] as? String, "toastty.status")
        let nextTurnProperties = try XCTUnwrap(events[2]["properties"] as? [String: Any])
        XCTAssertEqual(nextTurnProperties["kind"] as? String, "working")
        XCTAssertEqual(nextTurnProperties["detail"] as? String, "Running query")

        XCTAssertEqual(events[3]["type"] as? String, "toastty.status")
        let writingProperties = try XCTUnwrap(events[3]["properties"] as? [String: Any])
        XCTAssertEqual(writingProperties["kind"] as? String, "working")
        XCTAssertEqual(writingProperties["detail"] as? String, "Writing response")
    }

    func testOpenCodeFamilyPluginMapsQuestionToolHooksToApprovalStatus() throws {
        for scenario in [
            (agent: AgentKind.opencode, commandName: "opencode", environmentKey: "OPENCODE_CONFIG_CONTENT"),
            (agent: AgentKind.mimocode, commandName: "mimo", environmentKey: "MIMOCODE_CONFIG_CONTENT"),
        ] {
            let events = try runOpenCodeFamilyPluginScenario(
                agent: scenario.agent,
                commandName: scenario.commandName,
                configContentEnvironmentKey: scenario.environmentKey,
                runnerBody: """
                hooks["tool.execute.before"]?.({ name: "question" });
                hooks["tool.execute.after"]?.({ name: "question" }, {});
                """
            )

            XCTAssertEqual(events.count, 2, scenario.commandName)
            let firstProperties = try XCTUnwrap(events[0]["properties"] as? [String: Any])
            XCTAssertEqual(firstProperties["kind"] as? String, "needs_approval", scenario.commandName)
            XCTAssertEqual(firstProperties["summary"] as? String, "Needs approval", scenario.commandName)
            XCTAssertEqual(firstProperties["detail"] as? String, "Agent is waiting for approval", scenario.commandName)

            let secondProperties = try XCTUnwrap(events[1]["properties"] as? [String: Any])
            XCTAssertEqual(secondProperties["kind"] as? String, "working", scenario.commandName)
            XCTAssertEqual(secondProperties["detail"] as? String, "Approval resolved", scenario.commandName)
            XCTAssertFalse(String(describing: events).contains("Using Question"), scenario.commandName)
        }
    }

    func testOpenCodeFamilyPluginRecordsNativeSessionWithToasttyMarker() throws {
        let nativeSessionID = "ses_provider/with space-" + String(repeating: "x", count: 170)
        for scenario in [
            (agent: AgentKind.opencode, commandName: "opencode", environmentKey: "OPENCODE_CONFIG_CONTENT"),
            (agent: AgentKind.mimocode, commandName: "mimo", environmentKey: "MIMOCODE_CONFIG_CONTENT"),
        ] {
            let result = try runOpenCodeFamilyPluginScenarioResult(
                agent: scenario.agent,
                commandName: scenario.commandName,
                configContentEnvironmentKey: scenario.environmentKey,
                runnerBody: """
                hooks.event?.({
                  type: "session.status",
                  properties: { sessionID: "\(nativeSessionID)", status: { type: "busy", message: "Indexing" } },
                });
                hooks.event?.({
                  type: "session.status",
                  properties: { sessionID: "\(nativeSessionID)", status: { type: "busy", message: "Indexing" } },
                });
                """
            )

            XCTAssertEqual(result.events.count, 2, scenario.commandName)
            XCTAssertEqual(result.events[0]["type"] as? String, "toastty.native_session", scenario.commandName)
            let nativeProperties = try XCTUnwrap(result.events[0]["properties"] as? [String: Any], scenario.commandName)
            XCTAssertEqual(nativeProperties["nativeSessionID"] as? String, nativeSessionID, scenario.commandName)
            XCTAssertTrue((nativeProperties["cwd"] as? String)?.hasSuffix("/repo") == true, scenario.commandName)
            let sessionFilePath = try XCTUnwrap(nativeProperties["sessionFilePath"] as? String, scenario.commandName)
            XCTAssertTrue(sessionFilePath.contains("managed-agent-resume"), scenario.commandName)
            XCTAssertTrue(sessionFilePath.contains(scenario.agent == .opencode ? "opencode-plugin-" : "mimocode-plugin-"), scenario.commandName)
            XCTAssertFalse(sessionFilePath.contains(nativeSessionID.prefix(12)), scenario.commandName)
            XCTAssertFalse(sessionFilePath.contains("/with space"), scenario.commandName)

            let markerContents = try XCTUnwrap(result.markerContentsByPath[sessionFilePath], scenario.commandName)
            let marker = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(markerContents.utf8)) as? [String: Any],
                scenario.commandName
            )
            XCTAssertEqual(marker["source"] as? String, scenario.agent == .opencode ? "opencode-plugin" : "mimocode-plugin", scenario.commandName)
            XCTAssertEqual(marker["version"] as? Int, 1, scenario.commandName)
            XCTAssertNil(marker["nativeSessionID"], scenario.commandName)
            XCTAssertNil(marker["cwd"], scenario.commandName)

            XCTAssertEqual(result.events[1]["type"] as? String, "toastty.status", scenario.commandName)
            let statusProperties = try XCTUnwrap(result.events[1]["properties"] as? [String: Any], scenario.commandName)
            XCTAssertEqual(statusProperties["kind"] as? String, "working", scenario.commandName)
            XCTAssertEqual(statusProperties["detail"] as? String, "Indexing", scenario.commandName)
        }
    }

    func testOpenCodeFamilyPluginMapsQuestionMessagePartToApprovalStatus() throws {
        for scenario in [
            (agent: AgentKind.opencode, commandName: "opencode", environmentKey: "OPENCODE_CONFIG_CONTENT"),
            (agent: AgentKind.mimocode, commandName: "mimo", environmentKey: "MIMOCODE_CONFIG_CONTENT"),
        ] {
            let events = try runOpenCodeFamilyPluginScenario(
                agent: scenario.agent,
                commandName: scenario.commandName,
                configContentEnvironmentKey: scenario.environmentKey,
                runnerBody: """
                hooks.event?.({
                  type: "message.part.updated",
                  properties: { part: { type: "tool", tool: "question" } },
                });
                """
            )

            XCTAssertEqual(events.count, 1, scenario.commandName)
            let properties = try XCTUnwrap(events[0]["properties"] as? [String: Any])
            XCTAssertEqual(properties["kind"] as? String, "needs_approval", scenario.commandName)
            XCTAssertEqual(properties["summary"] as? String, "Needs approval", scenario.commandName)
            XCTAssertEqual(properties["detail"] as? String, "Agent is waiting for approval", scenario.commandName)
            XCTAssertFalse(String(describing: events).contains("Using Question"), scenario.commandName)
        }
    }

    func testOpenCodeFamilyPluginMapsCompletedQuestionMessagePartToResolvedStatus() throws {
        let events = try runOpenCodeFamilyPluginScenario(
            agent: .opencode,
            commandName: "opencode",
            configContentEnvironmentKey: "OPENCODE_CONFIG_CONTENT",
            runnerBody: """
            hooks.event?.({
              type: "message.part.updated",
              properties: { part: { type: "tool", tool: "question", state: { status: "completed" } } },
            });
            """
        )

        XCTAssertEqual(events.count, 1)
        let properties = try XCTUnwrap(events[0]["properties"] as? [String: Any])
        XCTAssertEqual(properties["kind"] as? String, "working")
        XCTAssertEqual(properties["detail"] as? String, "Approval resolved")
        XCTAssertFalse(String(describing: events).contains("needs_approval"))
        XCTAssertFalse(String(describing: events).contains("Using Question"))
    }

    func testOpenCodeFamilyPluginSuppressesTrailingQuestionMessagePartAfterToolResolution() throws {
        let events = try runOpenCodeFamilyPluginScenario(
            agent: .opencode,
            commandName: "opencode",
            configContentEnvironmentKey: "OPENCODE_CONFIG_CONTENT",
            runnerBody: """
            hooks["tool.execute.before"]?.({ tool: "question" });
            hooks["tool.execute.after"]?.({ tool: "question" }, {});
            hooks.event?.({
              type: "message.part.updated",
              properties: { part: { type: "tool", tool: "question" } },
            });
            """
        )

        XCTAssertEqual(events.count, 2)
        let firstProperties = try XCTUnwrap(events[0]["properties"] as? [String: Any])
        XCTAssertEqual(firstProperties["kind"] as? String, "needs_approval")
        let secondProperties = try XCTUnwrap(events[1]["properties"] as? [String: Any])
        XCTAssertEqual(secondProperties["kind"] as? String, "working")
        XCTAssertEqual(secondProperties["detail"] as? String, "Approval resolved")
        XCTAssertEqual(String(describing: events).components(separatedBy: "needs_approval").count - 1, 1)
        XCTAssertFalse(String(describing: events).contains("Using Question"))
    }

    func testOpenCodeFamilyPluginAllowsInitialBlankBusyStatus() throws {
        let events = try runOpenCodeFamilyPluginScenario(
            agent: .opencode,
            commandName: "opencode",
            configContentEnvironmentKey: "OPENCODE_CONFIG_CONTENT",
            runnerBody: """
            hooks.event?.({
              type: "session.status",
              properties: { status: { type: "busy" } },
            });
            """
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["type"] as? String, "toastty.status")
        let properties = try XCTUnwrap(events[0]["properties"] as? [String: Any])
        XCTAssertEqual(properties["kind"] as? String, "working")
        XCTAssertNil(properties["detail"])
    }

    func testOpenCodeFamilyPluginSuppressesBlankBusyAfterVisibleWorkingDetail() throws {
        for scenario in [
            (agent: AgentKind.opencode, commandName: "opencode", environmentKey: "OPENCODE_CONFIG_CONTENT"),
            (agent: AgentKind.mimocode, commandName: "mimo", environmentKey: "MIMOCODE_CONFIG_CONTENT"),
        ] {
            let events = try runOpenCodeFamilyPluginScenario(
                agent: scenario.agent,
                commandName: scenario.commandName,
                configContentEnvironmentKey: scenario.environmentKey,
                runnerBody: """
                hooks["tool.execute.before"]?.({ tool: "bash" });
                hooks.event?.({
                  type: "session.status",
                  properties: { status: { type: "busy" } },
                });
                hooks.event?.({
                  type: "message.part.updated",
                  properties: { part: { type: "reasoning" } },
                });
                """
            )

            XCTAssertEqual(events.count, 2, scenario.commandName)
            let properties = try events.map { event in
                try XCTUnwrap(event["properties"] as? [String: Any])
            }
            XCTAssertEqual(properties.compactMap { $0["kind"] as? String }, ["working", "working"], scenario.commandName)
            XCTAssertEqual(properties.compactMap { $0["detail"] as? String }, ["Using Bash", "Reasoning"], scenario.commandName)
        }
    }

    func testOpenCodeFamilyPluginAllowsBlankBusyAfterSuppressionWindow() throws {
        let events = try runOpenCodeFamilyPluginScenario(
            agent: .opencode,
            commandName: "opencode",
            configContentEnvironmentKey: "OPENCODE_CONFIG_CONTENT",
            runnerBody: """
            hooks["tool.execute.before"]?.({ tool: "bash" });
            await new Promise((resolve) => setTimeout(resolve, 850));
            hooks.event?.({
              type: "session.status",
              properties: { status: { type: "busy" } },
            });
            """
        )

        XCTAssertEqual(events.count, 2)
        let firstProperties = try XCTUnwrap(events[0]["properties"] as? [String: Any])
        XCTAssertEqual(firstProperties["kind"] as? String, "working")
        XCTAssertEqual(firstProperties["detail"] as? String, "Using Bash")
        let secondProperties = try XCTUnwrap(events[1]["properties"] as? [String: Any])
        XCTAssertEqual(secondProperties["kind"] as? String, "working")
        XCTAssertNil(secondProperties["detail"])
    }

    func testOpenCodeFamilyPluginAllowsBlankBusyAfterTerminalStatusClearsSuppression() throws {
        let events = try runOpenCodeFamilyPluginScenario(
            agent: .opencode,
            commandName: "opencode",
            configContentEnvironmentKey: "OPENCODE_CONFIG_CONTENT",
            runnerBody: """
            hooks["tool.execute.before"]?.({ tool: "bash" });
            hooks.event?.({
              type: "session.status",
              properties: { status: { type: "idle" } },
            });
            hooks.event?.({
              type: "session.status",
              properties: { status: { type: "busy" } },
            });
            """
        )

        XCTAssertEqual(events.count, 3)
        let firstProperties = try XCTUnwrap(events[0]["properties"] as? [String: Any])
        XCTAssertEqual(firstProperties["kind"] as? String, "working")
        XCTAssertEqual(firstProperties["detail"] as? String, "Using Bash")
        let secondProperties = try XCTUnwrap(events[1]["properties"] as? [String: Any])
        XCTAssertEqual(secondProperties["kind"] as? String, "ready")
        let thirdProperties = try XCTUnwrap(events[2]["properties"] as? [String: Any])
        XCTAssertEqual(thirdProperties["kind"] as? String, "working")
        XCTAssertNil(thirdProperties["detail"])
    }

    func testOpenCodePluginDelaysFinalUntilIdleAndSuppressesLateGenericWorking() throws {
        let events = try runOpenCodeFamilyPluginScenario(
            agent: .opencode,
            commandName: "opencode",
            configContentEnvironmentKey: "OPENCODE_CONFIG_CONTENT",
            runnerBody: """
            await hooks["experimental.text.complete"]?.({}, { text: "complete text" });
            hooks.event?.({
              type: "message.part.updated",
              properties: { part: { type: "text", text: "late text" } },
            });
            hooks.event?.({
              type: "session.status",
              properties: { status: { type: "idle" } },
            });
            await new Promise((resolve) => setTimeout(resolve, 300));
            hooks["tool.execute.before"]?.({ tool: "bash" });
            """
        )

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0]["type"] as? String, "toastty.final")
        let finalProperties = try XCTUnwrap(events[0]["properties"] as? [String: Any])
        XCTAssertEqual(finalProperties["text"] as? String, "complete text")

        XCTAssertEqual(events[1]["type"] as? String, "toastty.status")
        let workingProperties = try XCTUnwrap(events[1]["properties"] as? [String: Any])
        XCTAssertEqual(workingProperties["kind"] as? String, "working")
        XCTAssertEqual(workingProperties["detail"] as? String, "Using Bash")
        XCTAssertFalse(String(describing: events).contains("Writing response"))
    }

    func testOpenCodePluginSurfacesMeaningfulWorkingAfterIntermediateTextComplete() throws {
        let events = try runOpenCodeFamilyPluginScenario(
            agent: .opencode,
            commandName: "opencode",
            configContentEnvironmentKey: "OPENCODE_CONFIG_CONTENT",
            runnerBody: """
            await hooks["experimental.text.complete"]?.({}, { text: "intermediate text" });
            hooks.event?.({
              type: "message.part.updated",
              properties: { part: { type: "text", text: "late text" } },
            });
            hooks["tool.execute.before"]?.({ tool: "bash" });
            hooks.event?.({
              type: "session.status",
              properties: { status: { type: "idle" } },
            });
            """
        )

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0]["type"] as? String, "toastty.status")
        let workingProperties = try XCTUnwrap(events[0]["properties"] as? [String: Any])
        XCTAssertEqual(workingProperties["kind"] as? String, "working")
        XCTAssertEqual(workingProperties["detail"] as? String, "Using Bash")

        XCTAssertEqual(events[1]["type"] as? String, "toastty.status")
        let readyProperties = try XCTUnwrap(events[1]["properties"] as? [String: Any])
        XCTAssertEqual(readyProperties["kind"] as? String, "ready")
        XCTAssertNil(readyProperties["detail"])
        XCTAssertFalse(String(describing: events).contains("Writing response"))
        XCTAssertFalse(String(describing: events).contains("intermediate text"))
    }

    func testPrepareOpenCodeFamilyLaunchRefusesToOverwriteExistingConfigContent() {
        XCTAssertThrowsError(
            try AgentLaunchInstrumentation.prepare(
                agent: .opencode,
                argv: ["opencode"],
                cliExecutablePath: "/bin/sh",
                sessionID: "test-\(UUID().uuidString)",
                workingDirectory: nil,
                fileManager: .default,
                launchEnvironment: ["OPENCODE_CONFIG_CONTENT": #"{"plugin":["user-plugin"]}"#]
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("OPENCODE_CONFIG_CONTENT"))
        }
    }

    func testPrepareOpenCodeFamilyLaunchInjectsSkillsPathsAlongsidePlugin() throws {
        let configuration = stagedSkillsConfiguration()

        for (agent, commandName, configContentEnvironmentKey, otherEnvironmentKey) in [
            (AgentKind.opencode, "opencode", "OPENCODE_CONFIG_CONTENT", "MIMOCODE_CONFIG_CONTENT"),
            (AgentKind.mimocode, "mimo", "MIMOCODE_CONFIG_CONTENT", "OPENCODE_CONFIG_CONTENT"),
        ] {
            let preparedLaunch = try AgentLaunchInstrumentation.prepare(
                agent: agent,
                argv: [commandName],
                cliExecutablePath: "/bin/sh",
                sessionID: "test-\(UUID().uuidString)",
                workingDirectory: nil,
                fileManager: .default,
                stagedSkillsIntegration: configuration,
                deliveredUserSkillsRootPath: "/tmp/user-snapshot/toastty-user/skills"
            )
            defer { cleanup([preparedLaunch]) }

            XCTAssertEqual(preparedLaunch.argv, [commandName])
            XCTAssertNil(preparedLaunch.environment[otherEnvironmentKey])
            let configContent = try XCTUnwrap(preparedLaunch.environment[configContentEnvironmentKey])
            let configObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(configContent.utf8)) as? [String: Any]
            )
            let skills = try XCTUnwrap(configObject["skills"] as? [String: Any])
            // Plain absolute paths only: a `file://` URI discovers nothing here.
            XCTAssertEqual(
                skills["paths"] as? [String],
                [configuration.skillsRootPath, "/tmp/user-snapshot/toastty-user/skills"]
            )
            let plugins = try XCTUnwrap(configObject["plugin"] as? [String])
            XCTAssertTrue(try XCTUnwrap(plugins.first).hasPrefix("file://"))
            XCTAssertEqual(preparedLaunch.environment["TOASTTY_SKILLS_ROOT"], configuration.skillsRootPath)
        }
    }

    func testPrepareOpenCodeFamilyLaunchOmitsSkillsWithoutStagedConfiguration() throws {
        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .opencode,
            argv: ["opencode"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default,
            stagedSkillsIntegration: nil,
            deliveredUserSkillsRootPath: "/tmp/user-snapshot/toastty-user/skills"
        )
        defer { cleanup([preparedLaunch]) }

        // `skills` replaces the user's own config layers wholesale, so it is
        // only ever emitted alongside the shipped tree.
        let configContent = try XCTUnwrap(preparedLaunch.environment["OPENCODE_CONFIG_CONTENT"])
        let configObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(configContent.utf8)) as? [String: Any]
        )
        XCTAssertNil(configObject["skills"])
        XCTAssertNotNil(configObject["plugin"])
        XCTAssertNil(preparedLaunch.environment["TOASTTY_SKILLS_ROOT"])
    }

    func testPrepareOpenCodeFamilyLaunchStillRefusesCallerConfigContentWhenSkillsAreStaged() {
        XCTAssertThrowsError(
            try AgentLaunchInstrumentation.prepare(
                agent: .mimocode,
                argv: ["mimo"],
                cliExecutablePath: "/bin/sh",
                sessionID: "test-\(UUID().uuidString)",
                workingDirectory: nil,
                fileManager: .default,
                launchEnvironment: ["MIMOCODE_CONFIG_CONTENT": #"{"plugin":["user-plugin"]}"#],
                stagedSkillsIntegration: stagedSkillsConfiguration(),
                deliveredUserSkillsRootPath: "/tmp/user-snapshot/toastty-user/skills"
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("MIMOCODE_CONFIG_CONTENT"))
        }
    }

    func testPrepareClaudeLaunchInsertsSettingsAfterWrappedClaudeCommand() throws {
        let fileManager = FileManager.default
        let sessionID = "test-\(UUID().uuidString)"

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .claude,
            argv: [
                "/Users/vishal/.config/sandbox-exec/run-sandboxed.sh",
                "claude",
                "--dangerously-skip-permissions",
            ],
            cliExecutablePath: "/bin/sh",
            sessionID: sessionID,
            workingDirectory: nil,
            fileManager: fileManager
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? fileManager.removeItem(at: artifacts.directoryURL)
            }
        }

        let settingsIndex = try XCTUnwrap(preparedLaunch.argv.firstIndex(of: "--settings"))
        let settingsPath = try XCTUnwrap(preparedLaunch.argv[safe: settingsIndex + 1])
        XCTAssertEqual(
            Array(preparedLaunch.argv.prefix(4)),
            [
                "/Users/vishal/.config/sandbox-exec/run-sandboxed.sh",
                "claude",
                "--settings",
                settingsPath,
            ]
        )
        XCTAssertEqual(preparedLaunch.argv.last, "--dangerously-skip-permissions")
    }

    func testPreparePiLaunchInsertsToasttyExtensionAfterPiCommand() throws {
        let fileManager = FileManager.default
        let sessionID = "test-\(UUID().uuidString)"
        AgentLaunchInstrumentation.piExtensionPathProviderForTesting = {
            "/Applications/Toastty.app/Contents/Resources/AgentExtensions/toastty-pi-extension.js"
        }

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .pi,
            argv: ["agent-safehouse", "--cwd", "/tmp/repo", "pi", "--mode", "text"],
            cliExecutablePath: "/bin/sh",
            sessionID: sessionID,
            workingDirectory: nil,
            fileManager: fileManager
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? fileManager.removeItem(at: artifacts.directoryURL)
            }
        }

        XCTAssertEqual(
            preparedLaunch.argv,
            [
                "agent-safehouse",
                "--cwd",
                "/tmp/repo",
                "pi",
                "--extension",
                "/Applications/Toastty.app/Contents/Resources/AgentExtensions/toastty-pi-extension.js",
                "--mode",
                "text",
            ]
        )
        XCTAssertEqual(
            preparedLaunch.environment["TOASTTY_PI_TELEMETRY_LOG_PATH"],
            preparedLaunch.artifacts?.directoryURL.appendingPathComponent("pi-telemetry.jsonl").path
        )
    }

    func testPreparePiLaunchPreservesUserExtensionAndAddsToasttyExtension() throws {
        AgentLaunchInstrumentation.piExtensionPathProviderForTesting = { "/toastty/pi-extension.js" }

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .pi,
            argv: ["pi", "--extension", "/user/ext.js"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? FileManager.default.removeItem(at: artifacts.directoryURL)
            }
        }

        XCTAssertEqual(
            preparedLaunch.argv,
            ["pi", "--extension", "/toastty/pi-extension.js", "--extension", "/user/ext.js"]
        )
    }

    func testPreparePiLaunchSkipsToasttyExtensionForNoExtensionsBeforeTerminator() throws {
        AgentLaunchInstrumentation.piExtensionPathProviderForTesting = { "/toastty/pi-extension.js" }

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .pi,
            argv: ["pi", "--no-extensions", "--extension", "/user/ext.js"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? FileManager.default.removeItem(at: artifacts.directoryURL)
            }
        }

        XCTAssertEqual(preparedLaunch.argv, ["pi", "--no-extensions", "--extension", "/user/ext.js"])
        XCTAssertNotNil(preparedLaunch.environment["TOASTTY_PI_TELEMETRY_LOG_PATH"])
    }

    func testPreparePiLaunchTreatsShortNoExtensionFlagAsOptOutBeforeTerminatorOnly() throws {
        AgentLaunchInstrumentation.piExtensionPathProviderForTesting = { "/toastty/pi-extension.js" }

        let optedOutLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .pi,
            argv: ["pi", "-ne"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default
        )
        let terminatorLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .pi,
            argv: ["pi", "--", "--no-extensions"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default
        )

        defer {
            for artifacts in [optedOutLaunch.artifacts, terminatorLaunch.artifacts].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: artifacts.directoryURL)
            }
        }

        XCTAssertEqual(optedOutLaunch.argv, ["pi", "-ne"])
        XCTAssertEqual(terminatorLaunch.argv, ["pi", "--extension", "/toastty/pi-extension.js", "--", "--no-extensions"])
    }

    func testPreparePiLaunchInjectsStagedAndUserSkillTreesAfterExtension() throws {
        AgentLaunchInstrumentation.piExtensionPathProviderForTesting = { "/toastty/pi-extension.js" }
        let configuration = stagedSkillsConfiguration()

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .pi,
            argv: ["agent-safehouse", "--cwd", "/tmp/repo", "pi", "--mode", "text"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default,
            stagedSkillsIntegration: configuration,
            deliveredUserSkillsRootPath: "/tmp/user-snapshot/toastty-user/skills"
        )
        defer { cleanup([preparedLaunch]) }

        XCTAssertEqual(
            preparedLaunch.argv,
            [
                "agent-safehouse",
                "--cwd",
                "/tmp/repo",
                "pi",
                "--extension",
                "/toastty/pi-extension.js",
                "--skill",
                configuration.skillsRootPath,
                "--skill",
                "/tmp/user-snapshot/toastty-user/skills",
                "--mode",
                "text",
            ]
        )
        // A bare `--` is an unknown-option hard error in pi.
        XCTAssertFalse(preparedLaunch.argv.contains("--"))
        XCTAssertEqual(preparedLaunch.environment["TOASTTY_SKILLS_ROOT"], configuration.skillsRootPath)
    }

    func testPreparePiLaunchKeepsCallerSkillFlagsAndAddsStagedTrees() throws {
        AgentLaunchInstrumentation.piExtensionPathProviderForTesting = { "/toastty/pi-extension.js" }
        let configuration = stagedSkillsConfiguration()

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .pi,
            argv: ["pi", "--skill", "/user/skills"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default,
            stagedSkillsIntegration: configuration,
            deliveredUserSkillsRootPath: "/tmp/user-snapshot/toastty-user/skills"
        )
        defer { cleanup([preparedLaunch]) }

        XCTAssertEqual(
            preparedLaunch.argv,
            [
                "pi",
                "--extension",
                "/toastty/pi-extension.js",
                "--skill",
                configuration.skillsRootPath,
                "--skill",
                "/tmp/user-snapshot/toastty-user/skills",
                "--skill",
                "/user/skills",
            ]
        )
    }

    func testPreparePiLaunchInjectsUserSkillTreeIndependentlyOfStagedConfiguration() throws {
        AgentLaunchInstrumentation.piExtensionPathProviderForTesting = { "/toastty/pi-extension.js" }

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .pi,
            argv: ["pi"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default,
            stagedSkillsIntegration: nil,
            deliveredUserSkillsRootPath: "/tmp/user-snapshot/toastty-user/skills"
        )
        defer { cleanup([preparedLaunch]) }

        XCTAssertEqual(
            preparedLaunch.argv,
            [
                "pi",
                "--extension",
                "/toastty/pi-extension.js",
                "--skill",
                "/tmp/user-snapshot/toastty-user/skills",
            ]
        )
        XCTAssertNil(preparedLaunch.environment["TOASTTY_SKILLS_ROOT"])
    }

    func testPreparePiLaunchSkipsOnlySkillsForCallerNoSkillsOptOut() throws {
        AgentLaunchInstrumentation.piExtensionPathProviderForTesting = { "/toastty/pi-extension.js" }
        let configuration = stagedSkillsConfiguration()

        // pi has no end-of-flags boundary, so the opt-out counts anywhere after
        // the resolved command — including after positional message tokens.
        for argv in [
            ["pi", "--no-skills"],
            ["pi", "-ns"],
            ["pi", "-p", "hi", "--no-skills"],
        ] {
            let preparedLaunch = try AgentLaunchInstrumentation.prepare(
                agent: .pi,
                argv: argv,
                cliExecutablePath: "/bin/sh",
                sessionID: "test-\(UUID().uuidString)",
                workingDirectory: nil,
                fileManager: .default,
                stagedSkillsIntegration: configuration,
                deliveredUserSkillsRootPath: "/tmp/user-snapshot/toastty-user/skills"
            )
            defer { cleanup([preparedLaunch]) }

            XCTAssertFalse(preparedLaunch.argv.contains("--skill"))
            XCTAssertNil(preparedLaunch.environment["TOASTTY_SKILLS_ROOT"])
            // Everything else about pi preparation is unaffected.
            XCTAssertEqual(preparedLaunch.argv[safe: 1], "--extension")
            XCTAssertEqual(preparedLaunch.argv[safe: 2], "/toastty/pi-extension.js")
            XCTAssertNotNil(preparedLaunch.environment["TOASTTY_PI_TELEMETRY_LOG_PATH"])
        }
    }

    func testPreparePiLaunchSkipsSkillsWhenExtensionInjectionIsRefused() throws {
        AgentLaunchInstrumentation.piExtensionPathProviderForTesting = { "/toastty/pi-extension.js" }
        let configuration = stagedSkillsConfiguration()

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .pi,
            argv: ["pi", "--no-extensions"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default,
            stagedSkillsIntegration: configuration,
            deliveredUserSkillsRootPath: "/tmp/user-snapshot/toastty-user/skills"
        )
        defer { cleanup([preparedLaunch]) }

        XCTAssertEqual(preparedLaunch.argv, ["pi", "--no-extensions"])
        XCTAssertNil(preparedLaunch.environment["TOASTTY_SKILLS_ROOT"])
    }

    func testPreparedClaudeHookScriptLogsTelemetryFailuresWithoutWritingToStdout() throws {
        let fileManager = FileManager.default
        let sessionID = "test-\(UUID().uuidString)"

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .claude,
            argv: ["claude"],
            cliExecutablePath: "/definitely/missing-toastty-cli",
            sessionID: sessionID,
            workingDirectory: nil,
            fileManager: fileManager
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? fileManager.removeItem(at: artifacts.directoryURL)
            }
        }

        let artifactsURL = try XCTUnwrap(preparedLaunch.artifacts?.directoryURL)
        let scriptURL = artifactsURL.appendingPathComponent("claude-hook.sh", isDirectory: false)
        let telemetryLogURL = artifactsURL.appendingPathComponent("telemetry-failures.log", isDirectory: false)

        let result = try runScript(
            at: scriptURL,
            environment: ["TOASTTY_SOCKET_PATH": "/tmp/test-claude-hooks.sock"]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")

        let telemetryLog = try String(contentsOf: telemetryLogURL, encoding: .utf8)
        XCTAssertTrue(telemetryLog.contains("source=claude-hooks"))
        XCTAssertTrue(telemetryLog.contains("socket_path=/tmp/test-claude-hooks.sock"))
        XCTAssertTrue(telemetryLog.contains("exit_code="))
        XCTAssertTrue(telemetryLog.contains("stderr: "))
    }

    func testPreparedClaudeHookScriptForwardsHookPayload() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-claude-hook-forward-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let capturedArgsURL = rootURL.appendingPathComponent("args.txt", isDirectory: false)
        let capturedPayloadURL = rootURL.appendingPathComponent("payload.json", isDirectory: false)
        let fakeCLIURL = rootURL.appendingPathComponent("toastty-cli", isDirectory: false)
        try Data(
            """
            #!/bin/sh
            printf '%s\\n' "$@" > '\(capturedArgsURL.path)'
            cat > '\(capturedPayloadURL.path)'
            exit 0

            """.utf8
        ).write(to: fakeCLIURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLIURL.path)

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .claude,
            argv: ["claude"],
            cliExecutablePath: fakeCLIURL.path,
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: fileManager
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? fileManager.removeItem(at: artifacts.directoryURL)
            }
        }

        let scriptURL = try XCTUnwrap(preparedLaunch.artifacts?.directoryURL.appendingPathComponent("claude-hook.sh"))
        let payload = #"{"hook_event_name":"SessionStart","session_id":"claude-session","transcript_path":"/tmp/claude.jsonl"}"#
        let result = try runScript(
            at: scriptURL,
            environment: ["TOASTTY_SOCKET_PATH": "/tmp/test-claude-hooks.sock"],
            standardInput: Data(payload.utf8)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(try String(contentsOf: capturedPayloadURL, encoding: .utf8), payload)
        XCTAssertEqual(
            try String(contentsOf: capturedArgsURL, encoding: .utf8),
            "session\ningest-agent-event\n--source\nclaude-hooks\n"
        )
    }

    func testPreparedCodexNotifyScriptLogsTelemetryFailuresWithoutWritingToStdout() throws {
        let fileManager = FileManager.default
        let sessionID = "test-\(UUID().uuidString)"

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .codex,
            argv: ["codex"],
            cliExecutablePath: "/definitely/missing-toastty-cli",
            sessionID: sessionID,
            workingDirectory: nil,
            fileManager: fileManager
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? fileManager.removeItem(at: artifacts.directoryURL)
            }
        }

        let artifactsURL = try XCTUnwrap(preparedLaunch.artifacts?.directoryURL)
        let scriptURL = artifactsURL.appendingPathComponent("codex-notify.sh", isDirectory: false)
        let telemetryLogURL = artifactsURL.appendingPathComponent("telemetry-failures.log", isDirectory: false)

        let result = try runScript(
            at: scriptURL,
            environment: ["TOASTTY_SOCKET_PATH": "/tmp/test-codex-hooks.sock"],
            arguments: ["{\"kind\":\"task_complete\"}"]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")

        let telemetryLog = try String(contentsOf: telemetryLogURL, encoding: .utf8)
        XCTAssertTrue(telemetryLog.contains("source=codex-notify"))
        XCTAssertTrue(telemetryLog.contains("socket_path=/tmp/test-codex-hooks.sock"))
        XCTAssertTrue(telemetryLog.contains("exit_code="))
        XCTAssertTrue(telemetryLog.contains("stderr: "))
    }

    func testTomlBasicStringLiteralEscapesSpecialCharacters() {
        let literal = AgentLaunchInstrumentation.tomlBasicStringLiteralForTesting("line\n\t\"\\\u{7F}\u{0001}")

        XCTAssertEqual(literal, "\"line\\n\\t\\\"\\\\\\u007f\\u0001\"")
    }

    func testTomlStringArrayLiteralEscapesEmbeddedSpecialCharacters() {
        let literal = AgentLaunchInstrumentation.tomlStringArrayLiteralForTesting([
            "/bin/sh",
            "path with quote \" and slash \\ and newline \n",
        ])

        XCTAssertEqual(
            literal,
            "[\"/bin/sh\",\"path with quote \\\" and slash \\\\ and newline \\n\"]"
        )
    }

    private func stagedSkillsConfiguration(
        pluginRootPath: String = "/tmp/toastty-plugin",
        skillsRootPath: String = "/tmp/toastty-plugin/skills"
    ) -> ClaudeSkillsLaunchConfiguration {
        ClaudeSkillsLaunchConfiguration(
            pluginRootPath: pluginRootPath,
            skillsRootPath: skillsRootPath,
            version: "1.0.0",
            contentDigest: "abc123"
        )
    }

    private func codexSkillsConfiguration(
        codexHomePath: String = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true).path,
        skillsRootPath: String = "/tmp/toastty plugin/skills"
    ) -> CodexSkillsLaunchConfiguration {
        CodexSkillsLaunchConfiguration(
            profileName: CodexSkillsContract.profileName,
            codexHomePath: codexHomePath,
            skillsRootPath: skillsRootPath,
            version: "0.2.0",
            contentDigest: "abc123"
        )
    }

    private func prepareCodex(
        argv: [String],
        source: CodexStatusTrackingSource,
        configuration: CodexSkillsLaunchConfiguration,
        launchEnvironment: [String: String] = [:]
    ) throws -> PreparedAgentLaunchCommand {
        try AgentLaunchInstrumentation.prepare(
            agent: .codex,
            argv: argv,
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default,
            launchEnvironment: launchEnvironment,
            codexStatusTrackingSource: source,
            codexSkillsIntegration: configuration
        )
    }

    private func configOverrides(in argv: [String]) -> [String] {
        argv.indices.compactMap { index in
            guard argv[index] == "-c", index + 1 < argv.count else { return nil }
            return argv[index + 1]
        }
    }

    private func cleanup(_ launches: [PreparedAgentLaunchCommand]) {
        for artifacts in launches.compactMap(\.artifacts) {
            try? FileManager.default.removeItem(at: artifacts.directoryURL)
        }
    }

    private func runOpenCodeFamilyPluginScenario(
        agent: AgentKind,
        commandName: String,
        configContentEnvironmentKey: String,
        runnerBody: String
    ) throws -> [[String: Any]] {
        try runOpenCodeFamilyPluginScenarioResult(
            agent: agent,
            commandName: commandName,
            configContentEnvironmentKey: configContentEnvironmentKey,
            runnerBody: runnerBody
        ).events
    }

    private struct OpenCodeFamilyPluginScenarioResult {
        let events: [[String: Any]]
        let markerContentsByPath: [String: String]
    }

    private func runOpenCodeFamilyPluginScenarioResult(
        agent: AgentKind,
        commandName: String,
        configContentEnvironmentKey: String,
        runnerBody: String
    ) throws -> OpenCodeFamilyPluginScenarioResult {
        let fileManager = FileManager.default
        guard let nodeURL = nodeExecutableURLForTests(fileManager: fileManager) else {
            throw XCTSkip("node is unavailable")
        }
        let nodeCheck = try runScript(
            at: nodeURL,
            environment: [:],
            arguments: ["--version"]
        )
        guard nodeCheck.exitCode == 0 else {
            throw XCTSkip("node is unavailable")
        }

        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-opencode-family-plugin-test-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directoryURL)
        }

        let captureURL = directoryURL.appendingPathComponent("events.ndjson", isDirectory: false)
        let cliURL = directoryURL.appendingPathComponent("toastty-test-cli", isDirectory: false)
        let runnerURL = directoryURL.appendingPathComponent("runner.mjs", isDirectory: false)
        let runtimeHomeURL = directoryURL.appendingPathComponent("runtime-home", isDirectory: true)
        let workingDirectoryURL = directoryURL.appendingPathComponent("repo", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectoryURL, withIntermediateDirectories: true)

        let fakeCLI = """
        #!/bin/sh
        cat >> "$TOASTTY_CAPTURE_PATH"
        printf '\\n' >> "$TOASTTY_CAPTURE_PATH"
        """
        try Data(fakeCLI.appending("\n").utf8).write(to: cliURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: agent,
            argv: [commandName],
            cliExecutablePath: cliURL.path,
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: workingDirectoryURL.path,
            fileManager: fileManager,
            launchEnvironment: [
                ToasttyRuntimePaths.environmentKey: runtimeHomeURL.path,
            ]
        )
        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? fileManager.removeItem(at: artifacts.directoryURL)
            }
        }
        let configContent = try XCTUnwrap(preparedLaunch.environment[configContentEnvironmentKey])
        let configObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(configContent.utf8)) as? [String: Any])
        let plugins = try XCTUnwrap(configObject["plugin"] as? [String])
        let pluginSpec = try XCTUnwrap(plugins.first)

        let runner = """
        import { ToasttyOpenCodeFamilyStatusPlugin } from "\(pluginSpec)";

        process.env.TOASTTY_SESSION_ID = "sess";
        process.env.TOASTTY_PANEL_ID = "11111111-1111-1111-1111-111111111111";
        process.env.TOASTTY_SOCKET_PATH = "/tmp/toastty-test.sock";

        const hooks = await ToasttyOpenCodeFamilyStatusPlugin();
        \(runnerBody)
        await new Promise((resolve) => setTimeout(resolve, 250));
        """
        try Data(runner.utf8).write(to: runnerURL)

        let result = try runScript(
            at: nodeURL,
            environment: ["TOASTTY_CAPTURE_PATH": captureURL.path],
            arguments: [runnerURL.path]
        )
        XCTAssertEqual(result.exitCode, 0, result.stderr)

        let lines = try String(contentsOf: captureURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let events = try lines.map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let markerContentsByPath: [String: String] = Dictionary(
            uniqueKeysWithValues: events.compactMap { event in
                guard let properties = event["properties"] as? [String: Any],
                      let path = properties["sessionFilePath"] as? String,
                      let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                    return nil
                }
                return (path, contents)
            }
        )
        return OpenCodeFamilyPluginScenarioResult(
            events: events,
            markerContentsByPath: markerContentsByPath
        )
    }

    private func runScript(
        at scriptURL: URL,
        environment: [String: String],
        arguments: [String] = [],
        standardInput: Data? = nil
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = scriptURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let inputPipe = Pipe()
        process.standardInput = inputPipe

        try process.run()
        if let standardInput {
            inputPipe.fileHandleForWriting.write(standardInput)
        }
        try inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private func nodeExecutableURLForTests(fileManager: FileManager) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []

        if let explicitNodePath = environment["TOASTTY_NODE_EXECUTABLE"] {
            candidates.append(explicitNodePath)
        }
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/node" })
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ])
        if let home = environment["HOME"] {
            let nvmVersionsURL = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".nvm/versions/node", isDirectory: true)
            if let versionURLs = try? fileManager.contentsOfDirectory(
                at: nvmVersionsURL,
                includingPropertiesForKeys: nil
            ) {
                candidates.append(contentsOf: versionURLs
                    .sorted { $0.lastPathComponent > $1.lastPathComponent }
                    .map { $0.appendingPathComponent("bin/node", isDirectory: false).path })
            }
        }

        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0, isDirectory: false) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
