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
        XCTAssertNotNil(hooks["PreToolUse"])
        XCTAssertNil(hooks["PostToolUse"])
        XCTAssertNil(hooks["PostToolUseFailure"])
        XCTAssertNotNil(hooks["PermissionRequest"])
        XCTAssertNotNil(hooks["Notification"])

        let notificationEntries = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])
        let matcherEntry = notificationEntries.first { entry in
            (entry["matcher"] as? String) == "*"
        }
        XCTAssertNotNil(matcherEntry, "Notification hook should have a wildcard matcher entry")
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
        XCTAssertTrue(plugin.contains(#""permission.replied""#))
        XCTAssertTrue(plugin.contains(#""tool.execute.after""#))
        XCTAssertTrue(plugin.contains(#""experimental.text.complete""#))
        XCTAssertTrue(plugin.contains(#""toastty.final""#))
        XCTAssertTrue(plugin.contains(#""ingest-agent-event""#))
        XCTAssertTrue(plugin.contains(#"const terminalWorkingSuppressMs = 2000;"#))
        XCTAssertTrue(plugin.contains(#"function shouldSuppressWorkingAfterTerminal(event)"#))
        XCTAssertTrue(plugin.contains(#"function flush(event, options)"#))
        XCTAssertTrue(plugin.contains(#"return enqueue(event, options);"#))
        XCTAssertTrue(plugin.contains(#"fire(toasttyStatus("working", "Working", toolAfterDetail(input, output)))"#))
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
        XCTAssertTrue(plugin.contains(#"hooks["session.userQuery.post"]"#))
        XCTAssertTrue(plugin.contains(#"hooks["session.post"]"#))
        XCTAssertTrue(plugin.contains(#""tool.execute.after""#))
        XCTAssertTrue(plugin.contains(#"resetTurnState();"#))
        XCTAssertTrue(plugin.contains(#"rememberFinalTextCandidate(input, output);"#))
        XCTAssertTrue(plugin.contains(#"return flush(toasttyFinal(finalTextFrom(input, output) || lastCompletedTextCandidate), { suppressFollowingWorking: true });"#))

        let userQueryPostStart = try XCTUnwrap(plugin.range(of: #"hooks["session.userQuery.post"]"#))
        let sessionPostStart = try XCTUnwrap(plugin.range(of: #"hooks["session.post"]"#))
        let userQueryPostHook = String(plugin[userQueryPostStart.lowerBound..<sessionPostStart.lowerBound])
        XCTAssertFalse(userQueryPostHook.contains("toasttyFinal"))
    }

    func testMiMoCodePluginFlushesSessionPostFinalAndSuppressesLateWorking() throws {
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

        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0]["type"] as? String, "toastty.status")
        let firstProperties = try XCTUnwrap(events[0]["properties"] as? [String: Any])
        XCTAssertEqual(firstProperties["kind"] as? String, "working")
        XCTAssertEqual(firstProperties["detail"] as? String, "Starting")

        XCTAssertEqual(events[1]["type"] as? String, "toastty.status")
        let secondProperties = try XCTUnwrap(events[1]["properties"] as? [String: Any])
        XCTAssertEqual(secondProperties["kind"] as? String, "working")
        XCTAssertEqual(secondProperties["detail"] as? String, "Using Bash")

        XCTAssertEqual(events[2]["type"] as? String, "toastty.final")
        let finalProperties = try XCTUnwrap(events[2]["properties"] as? [String: Any])
        XCTAssertEqual(finalProperties["text"] as? String, "per-step text")
        XCTAssertFalse(String(describing: events).contains("Writing response"))
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

    private func runOpenCodeFamilyPluginScenario(
        agent: AgentKind,
        commandName: String,
        configContentEnvironmentKey: String,
        runnerBody: String
    ) throws -> [[String: Any]] {
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
            workingDirectory: nil,
            fileManager: fileManager
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
        return try lines.map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
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
