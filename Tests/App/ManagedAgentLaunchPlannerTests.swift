import RemoteProtocol
import CoreState
import XCTest
@testable import ToasttyApp

@MainActor
final class ManagedAgentLaunchPlannerTests: XCTestCase {
    func testFreshLaunchClearsPriorRemoteConversationContinuation() throws {
        let nativeSessionID = "01900000-aaaa-7000-8000-000000000001"
        let remoteConversationID = RemoteConversationID()
        let fixture = try makePlannerFixture(terminalState: TerminalPanelState(
            title: "Agent",
            shell: "zsh",
            cwd: "/tmp/repo",
            resumeRecord: ManagedAgentResumeRecord(
                agent: .codex,
                nativeSessionID: nativeSessionID,
                sessionFilePath: "/tmp/old-rollout.jsonl",
                cwd: "/tmp/repo",
                capturedAt: Date(timeIntervalSince1970: 1_786_000_000)
            ),
            remoteConversationID: remoteConversationID
        ))

        let plan = try fixture.planner.prepareManagedLaunch(ManagedAgentLaunchRequest(
            agent: .codex,
            panelID: fixture.panelID,
            argv: ["codex"],
            cwd: "/tmp/repo"
        ))
        defer { fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date()) }

        guard case .terminal(let terminalState)? = fixture.store.state
            .workspaceSelection(containingPanelID: fixture.panelID)?
            .workspace
            .panelState(for: fixture.panelID) else {
            XCTFail("Expected terminal panel")
            return
        }
        XCTAssertNil(terminalState.resumeRecord)
        XCTAssertNil(terminalState.remoteConversationID)
    }

    func testExplicitResumePreservesRemoteConversationContinuation() throws {
        let nativeSessionID = "01900000-aaaa-7000-8000-000000000001"
        let remoteConversationID = RemoteConversationID()
        let resumeRecord = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: nativeSessionID,
            sessionFilePath: "/tmp/old-rollout.jsonl",
            cwd: "/tmp/repo",
            capturedAt: Date(timeIntervalSince1970: 1_786_000_000)
        )
        let fixture = try makePlannerFixture(terminalState: TerminalPanelState(
            title: "Agent",
            shell: "zsh",
            cwd: "/tmp/repo",
            resumeRecord: resumeRecord,
            remoteConversationID: remoteConversationID
        ))

        let plan = try fixture.planner.prepareManagedLaunch(ManagedAgentLaunchRequest(
            agent: .codex,
            panelID: fixture.panelID,
            argv: ["codex", "resume", nativeSessionID],
            cwd: "/tmp/repo"
        ))
        defer { fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date()) }

        guard case .terminal(let terminalState)? = fixture.store.state
            .workspaceSelection(containingPanelID: fixture.panelID)?
            .workspace
            .panelState(for: fixture.panelID) else {
            XCTFail("Expected terminal panel")
            return
        }
        XCTAssertEqual(terminalState.resumeRecord, resumeRecord)
        XCTAssertEqual(terminalState.remoteConversationID, remoteConversationID)
    }

    func testCodexLaunchWithoutSkillsPostsActionableUnavailableNotice() throws {
        let fixture = try makePlannerFixture()
        let recorder = CodexSkillsUnavailableNoticeRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: .toasttyManagedCodexSkillsUnavailable,
            object: nil,
            queue: nil
        ) { notification in
            recorder.record(notification.object as? ManagedCodexSkillsUnavailableNotice)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        defer { fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date()) }

        XCTAssertEqual(recorder.notices.count, 1)
        XCTAssertEqual(recorder.notices.first?.reasonCode, "configuration_unavailable")
        XCTAssertEqual(
            recorder.notices.first?.windowID,
            fixture.store.state.windows.first?.id
        )
    }

    func testRestoredCodexPreparationUsesBoundedRestoreProvisioning() throws {
        let resolver = RecordingCodexManagedLaunchSkillsResolver(
            decision: CodexManagedLaunchSkillsDecision(configuration: nil, status: nil)
        )
        let fixture = try makePlannerFixture(codexSkillsResolver: resolver)

        _ = try fixture.planner.prepareRestoredManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )

        XCTAssertEqual(resolver.restoredResolveCount, 1)
        XCTAssertEqual(resolver.managedResolveCount, 0)
    }

    func testAsyncManagedLaunchProceedsShippedOnlyWhenSnapshotPreparationHangs() async throws {
        let provider = HangingUserSkillSnapshotProvider(hangSeconds: 3)
        let fixture = try makePlannerFixture(userSkillSnapshotProvider: provider)
        fixture.planner.userSkillSnapshotPreparationTimeout = 0.2

        let start = Date()
        let plan = try await fixture.planner.prepareManagedLaunchAsync(
            ManagedAgentLaunchRequest(
                agent: .claude,
                panelID: fixture.panelID,
                argv: ["claude"],
                cwd: "/tmp/repo"
            )
        )
        defer { fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date()) }

        // A hanging snapshot build must never stall the managed launch: the
        // preparation completes within the bound, shipped-only.
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertFalse(plan.argv.contains("--plugin-dir"))
    }

    func testAsyncCodexLaunchReportsUnavailableWhenSnapshotPreparationHangs() async throws {
        let provider = HangingUserSkillSnapshotProvider(hangSeconds: 3)
        let resolver = SnapshotCapturingCodexSkillsResolver()
        let fixture = try makePlannerFixture(
            codexSkillsResolver: resolver,
            userSkillSnapshotProvider: provider
        )
        fixture.planner.userSkillSnapshotPreparationTimeout = 0.2

        let plan = try await fixture.planner.prepareManagedLaunchAsync(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        defer { fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date()) }

        // A timed-out build is `.unavailable`, never `.empty`: the Codex host
        // must not mistake an incomplete resolution for "the user has no
        // skills" and destroy delivered user state.
        XCTAssertEqual(resolver.capturedManagedResolutions, [.unavailable])
    }

    func testAsyncClaudeLaunchFallsBackToExistingSnapshotWhenPreparationFails() async throws {
        let snapshot = makeUserSkillSnapshotFixture()
        let provider = ThrowingPrepareUserSkillSnapshotProvider(existing: snapshot)
        let fixture = try makePlannerFixture(userSkillSnapshotProvider: provider)

        let plan = try await fixture.planner.prepareManagedLaunchAsync(
            ManagedAgentLaunchRequest(
                agent: .claude,
                panelID: fixture.panelID,
                argv: ["claude"],
                cwd: "/tmp/repo"
            )
        )
        defer { fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date()) }

        // `.unavailable` falls back to the newest verified on-disk snapshot
        // instead of silently dropping user skills for the launch.
        let pluginDirIndex = try XCTUnwrap(plan.argv.firstIndex(of: "--plugin-dir"))
        XCTAssertEqual(plan.argv[safe: pluginDirIndex + 1], snapshot.pluginRootURL.path)
    }

    func testClaudeSyncLaunchDropsUserPluginAfterCatalogConvergesToEmpty() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-planner-user-converge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let catalog = ToasttyUserSkillCatalog(
            runtimePaths: .resolve(
                homeDirectoryPath: rootURL.appendingPathComponent("real-home").path,
                environment: [
                    "TOASTTY_RUNTIME_HOME": rootURL.appendingPathComponent("runtime-home").path,
                    // Hermetic override: user skills follow the real home by
                    // default, so the fixture redirects the source explicitly.
                    "TOASTTY_USER_SKILLS_ROOT": rootURL
                        .appendingPathComponent("runtime-home/skills").path,
                ]
            )
        )
        let skillsRootURL = rootURL.appendingPathComponent("runtime-home/skills", isDirectory: true)
        let packageURL = skillsRootURL.appendingPathComponent("alpha-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try "---\nname: alpha-skill\ndescription: Test skill.\n---\n".write(
            to: packageURL.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let snapshot = try XCTUnwrap(catalog.prepareSnapshot())
        let resolver = SnapshotCapturingCodexSkillsResolver()
        let fixture = try makePlannerFixture(
            codexSkillsResolver: resolver,
            userSkillSnapshotProvider: catalog
        )

        let deliveringPlan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .claude,
                panelID: fixture.panelID,
                argv: ["claude"],
                cwd: "/tmp/repo"
            )
        )
        fixture.sessionRuntimeStore.stopSession(sessionID: deliveringPlan.sessionID, at: Date())
        XCTAssertTrue(deliveringPlan.argv.contains("--plugin-dir"))
        XCTAssertTrue(deliveringPlan.argv.contains { argument in
            argument.hasSuffix("\(snapshot.sourceDigest)/marketplace/plugins/toastty-user")
        })

        // The user deletes every skill; the next preparation converges the
        // snapshot store.
        try FileManager.default.removeItem(at: skillsRootURL)
        XCTAssertNil(try catalog.prepareSnapshot())

        // Sync Claude launches stop injecting the stale root immediately.
        let convergedPlan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .claude,
                panelID: fixture.panelID,
                argv: ["claude"],
                cwd: "/tmp/repo"
            )
        )
        fixture.sessionRuntimeStore.stopSession(sessionID: convergedPlan.sessionID, at: Date())
        XCTAssertFalse(convergedPlan.argv.contains("--plugin-dir"))

        // Restored Codex launches receive the confirmed-empty resolution so
        // the manager converges the profile back to shipped-only.
        let restoredPlan = try fixture.planner.prepareRestoredManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        fixture.sessionRuntimeStore.stopSession(sessionID: restoredPlan.sessionID, at: Date())
        XCTAssertEqual(resolver.capturedRestoredResolutions, [.empty])
    }

    func testAsyncManagedLaunchPreparesOneUserSnapshotAndPassesItToCodexResolver() async throws {
        let snapshot = makeUserSkillSnapshotFixture()
        let provider = RecordingUserSkillSnapshotProvider(snapshot: snapshot)
        let resolver = SnapshotCapturingCodexSkillsResolver()
        let fixture = try makePlannerFixture(
            codexSkillsResolver: resolver,
            userSkillSnapshotProvider: provider
        )

        let plan = try await fixture.planner.prepareManagedLaunchAsync(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        defer { fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date()) }

        // The snapshot is built exactly once per launch preparation and the
        // same value reaches the Codex host.
        XCTAssertEqual(provider.prepareSnapshotCallCount, 1)
        XCTAssertEqual(provider.existingSnapshotCallCount, 0)
        XCTAssertEqual(resolver.capturedManagedResolutions, [.snapshot(snapshot)])
        // The Codex argv itself gains nothing from the user plugin.
        XCTAssertFalse(plan.argv.contains("--plugin-dir"))
    }

    func testAsyncClaudeManagedLaunchInjectsPreparedUserSnapshotPluginDir() async throws {
        let snapshot = makeUserSkillSnapshotFixture()
        let provider = RecordingUserSkillSnapshotProvider(snapshot: snapshot)
        let fixture = try makePlannerFixture(userSkillSnapshotProvider: provider)

        let plan = try await fixture.planner.prepareManagedLaunchAsync(
            ManagedAgentLaunchRequest(
                agent: .claude,
                panelID: fixture.panelID,
                argv: ["claude"],
                cwd: "/tmp/repo"
            )
        )
        defer { fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date()) }

        XCTAssertEqual(provider.prepareSnapshotCallCount, 1)
        let pluginDirIndex = try XCTUnwrap(plan.argv.firstIndex(of: "--plugin-dir"))
        XCTAssertEqual(plan.argv[safe: pluginDirIndex + 1], snapshot.pluginRootURL.path)
    }

    func testSyncManagedLaunchUsesExistingSnapshotWithoutBuilding() throws {
        let snapshot = makeUserSkillSnapshotFixture()
        let provider = RecordingUserSkillSnapshotProvider(snapshot: snapshot)
        let fixture = try makePlannerFixture(userSkillSnapshotProvider: provider)

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .claude,
                panelID: fixture.panelID,
                argv: ["claude"],
                cwd: "/tmp/repo"
            )
        )
        defer { fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date()) }

        // Synchronous preparation never builds a snapshot; it reuses the
        // existing on-disk one.
        XCTAssertEqual(provider.prepareSnapshotCallCount, 0)
        XCTAssertEqual(provider.existingSnapshotCallCount, 1)
        let pluginDirIndex = try XCTUnwrap(plan.argv.firstIndex(of: "--plugin-dir"))
        XCTAssertEqual(plan.argv[safe: pluginDirIndex + 1], snapshot.pluginRootURL.path)
    }

    func testRestoredManagedLaunchPassesExistingSnapshotToCodexResolverWithoutBuilding() throws {
        let snapshot = makeUserSkillSnapshotFixture()
        let provider = RecordingUserSkillSnapshotProvider(snapshot: snapshot)
        let resolver = SnapshotCapturingCodexSkillsResolver()
        let fixture = try makePlannerFixture(
            codexSkillsResolver: resolver,
            userSkillSnapshotProvider: provider
        )

        let plan = try fixture.planner.prepareRestoredManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        defer { fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date()) }

        XCTAssertEqual(provider.prepareSnapshotCallCount, 0)
        XCTAssertEqual(provider.existingSnapshotCallCount, 1)
        XCTAssertEqual(resolver.capturedRestoredResolutions, [.snapshot(snapshot)])
        XCTAssertEqual(resolver.capturedManagedResolutions, [])
    }

    func testSyncManagedLaunchDeliversStagedAndUserSkillsToAdditiveRuntimes() throws {
        AgentLaunchInstrumentation.piExtensionPathProviderForTesting = { "/toastty/pi-extension.js" }
        defer { AgentLaunchInstrumentation.piExtensionPathProviderForTesting = nil }
        let configuration = makeStagedSkillsConfigurationFixture()
        let snapshot = makeUserSkillSnapshotFixture()

        for agent in [AgentKind.pi, .opencode, .mimocode] {
            let provider = RecordingUserSkillSnapshotProvider(snapshot: snapshot)
            let fixture = try makePlannerFixture(
                claudeSkillsBundleManager: TestClaudeSkillsBundleManager(configuration: configuration),
                userSkillSnapshotProvider: provider
            )
            let plan = try fixture.planner.prepareManagedLaunch(
                ManagedAgentLaunchRequest(
                    agent: agent,
                    panelID: fixture.panelID,
                    argv: [agent.rawValue],
                    cwd: "/tmp/repo"
                )
            )
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())

            // Synchronous preparation reuses the existing on-disk snapshot.
            XCTAssertEqual(provider.prepareSnapshotCallCount, 0)
            XCTAssertEqual(provider.existingSnapshotCallCount, 1)
            XCTAssertEqual(plan.environment["TOASTTY_SKILLS_ROOT"], configuration.skillsRootPath)

            guard agent != .pi else {
                XCTAssertEqual(
                    plan.argv,
                    [
                        "pi",
                        "--extension",
                        "/toastty/pi-extension.js",
                        "--skill",
                        configuration.skillsRootPath,
                        "--skill",
                        snapshot.skillsRootURL.path,
                    ]
                )
                continue
            }

            let configContentKey = agent == .opencode ? "OPENCODE_CONFIG_CONTENT" : "MIMOCODE_CONFIG_CONTENT"
            let configContent = try XCTUnwrap(plan.environment[configContentKey])
            let configObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(configContent.utf8)) as? [String: Any]
            )
            let skills = try XCTUnwrap(configObject["skills"] as? [String: Any])
            XCTAssertEqual(
                skills["paths"] as? [String],
                [configuration.skillsRootPath, snapshot.skillsRootURL.path]
            )
        }
    }

    func testRestoredManagedLaunchReusesExistingSnapshotForAdditiveRuntimes() throws {
        AgentLaunchInstrumentation.piExtensionPathProviderForTesting = { "/toastty/pi-extension.js" }
        defer { AgentLaunchInstrumentation.piExtensionPathProviderForTesting = nil }
        let snapshot = makeUserSkillSnapshotFixture()
        let provider = RecordingUserSkillSnapshotProvider(snapshot: snapshot)
        let fixture = try makePlannerFixture(
            claudeSkillsBundleManager: TestClaudeSkillsBundleManager(
                configuration: makeStagedSkillsConfigurationFixture()
            ),
            userSkillSnapshotProvider: provider
        )

        let plan = try fixture.planner.prepareRestoredManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .pi,
                panelID: fixture.panelID,
                argv: ["pi"],
                cwd: "/tmp/repo"
            )
        )
        defer { fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date()) }

        XCTAssertEqual(provider.prepareSnapshotCallCount, 0)
        XCTAssertEqual(provider.existingSnapshotCallCount, 1)
        XCTAssertEqual(plan.argv.last, snapshot.skillsRootURL.path)
    }

    func testAsyncAdditiveRuntimeLaunchBuildsSnapshotAndFallsBackWhenPreparationFails() async throws {
        let snapshot = makeUserSkillSnapshotFixture()
        let configuration = makeStagedSkillsConfigurationFixture()

        let provider = RecordingUserSkillSnapshotProvider(snapshot: snapshot)
        let fixture = try makePlannerFixture(
            claudeSkillsBundleManager: TestClaudeSkillsBundleManager(configuration: configuration),
            userSkillSnapshotProvider: provider
        )
        let plan = try await fixture.planner.prepareManagedLaunchAsync(
            ManagedAgentLaunchRequest(
                agent: .opencode,
                panelID: fixture.panelID,
                argv: ["opencode"],
                cwd: "/tmp/repo"
            )
        )
        fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
        XCTAssertEqual(provider.prepareSnapshotCallCount, 1)
        XCTAssertEqual(
            try skillsPaths(in: plan, configContentKey: "OPENCODE_CONFIG_CONTENT"),
            [configuration.skillsRootPath, snapshot.skillsRootURL.path]
        )

        // `.unavailable` falls back to the newest verified on-disk snapshot
        // instead of silently dropping user skills for the launch.
        let fallbackFixture = try makePlannerFixture(
            claudeSkillsBundleManager: TestClaudeSkillsBundleManager(configuration: configuration),
            userSkillSnapshotProvider: ThrowingPrepareUserSkillSnapshotProvider(existing: snapshot)
        )
        let fallbackPlan = try await fallbackFixture.planner.prepareManagedLaunchAsync(
            ManagedAgentLaunchRequest(
                agent: .opencode,
                panelID: fallbackFixture.panelID,
                argv: ["opencode"],
                cwd: "/tmp/repo"
            )
        )
        fallbackFixture.sessionRuntimeStore.stopSession(sessionID: fallbackPlan.sessionID, at: Date())
        XCTAssertEqual(
            try skillsPaths(in: fallbackPlan, configContentKey: "OPENCODE_CONFIG_CONTENT"),
            [configuration.skillsRootPath, snapshot.skillsRootURL.path]
        )
    }

    func testAsyncManagedLaunchPostsSkillsNoticeForAdditiveRuntimes() async throws {
        AgentLaunchInstrumentation.piExtensionPathProviderForTesting = { "/toastty/pi-extension.js" }
        defer { AgentLaunchInstrumentation.piExtensionPathProviderForTesting = nil }
        let snapshot = makeUserSkillSnapshotFixture()

        for agent in [AgentKind.pi, .opencode, .mimocode] {
            let recorder = SkillsProvisionedNoticeRecorder()
            let observer = NotificationCenter.default.addObserver(
                forName: .toasttyManagedAgentSkillsProvisioned,
                object: nil,
                queue: nil
            ) { notification in
                recorder.record(notification.object as? ManagedAgentSkillsProvisionedNotice)
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            let fixture = try makePlannerFixture(
                claudeSkillsBundleManager: TestClaudeSkillsBundleManager(
                    configuration: makeStagedSkillsConfigurationFixture()
                ),
                userSkillSnapshotProvider: RecordingUserSkillSnapshotProvider(snapshot: snapshot)
            )
            let plan = try await fixture.planner.prepareManagedLaunchAsync(
                ManagedAgentLaunchRequest(
                    agent: agent,
                    panelID: fixture.panelID,
                    argv: [agent.rawValue],
                    cwd: "/tmp/repo"
                )
            )
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())

            XCTAssertEqual(
                recorder.notices,
                [
                    ManagedAgentSkillsProvisionedNotice(
                        windowID: try XCTUnwrap(fixture.store.state.windows.first?.id),
                        agent: agent,
                        shippedSkillCount: ToasttyAgentPluginBundle.skills.count,
                        deliveredUserSkillCount: snapshot.acceptedPackageNames.count
                    ),
                ]
            )
        }
    }

    func testAsyncManagedLaunchSkipsSkillsNoticeForAdditiveRuntimeWithoutStagedConfiguration() async throws {
        let recorder = SkillsProvisionedNoticeRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: .toasttyManagedAgentSkillsProvisioned,
            object: nil,
            queue: nil
        ) { notification in
            recorder.record(notification.object as? ManagedAgentSkillsProvisionedNotice)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let fixture = try makePlannerFixture(
            userSkillSnapshotProvider: RecordingUserSkillSnapshotProvider(
                snapshot: makeUserSkillSnapshotFixture()
            )
        )
        let plan = try await fixture.planner.prepareManagedLaunchAsync(
            ManagedAgentLaunchRequest(
                agent: .opencode,
                panelID: fixture.panelID,
                argv: ["opencode"],
                cwd: "/tmp/repo"
            )
        )
        fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())

        XCTAssertEqual(recorder.notices, [])
    }

    func testAsyncManagedLaunchSkipsSkillsNoticeWhenPiCallerOptsOut() async throws {
        AgentLaunchInstrumentation.piExtensionPathProviderForTesting = { "/toastty/pi-extension.js" }
        defer { AgentLaunchInstrumentation.piExtensionPathProviderForTesting = nil }

        for optOutArguments in [["--no-skills"], ["-ns"], ["--no-extensions"], ["-ne"]] {
            let recorder = SkillsProvisionedNoticeRecorder()
            let observer = NotificationCenter.default.addObserver(
                forName: .toasttyManagedAgentSkillsProvisioned,
                object: nil,
                queue: nil
            ) { notification in
                recorder.record(notification.object as? ManagedAgentSkillsProvisionedNotice)
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            let fixture = try makePlannerFixture(
                claudeSkillsBundleManager: TestClaudeSkillsBundleManager(
                    configuration: makeStagedSkillsConfigurationFixture()
                ),
                userSkillSnapshotProvider: RecordingUserSkillSnapshotProvider(
                    snapshot: makeUserSkillSnapshotFixture()
                )
            )
            let plan = try await fixture.planner.prepareManagedLaunchAsync(
                ManagedAgentLaunchRequest(
                    agent: .pi,
                    panelID: fixture.panelID,
                    argv: ["pi"] + optOutArguments,
                    cwd: "/tmp/repo"
                )
            )
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())

            XCTAssertEqual(recorder.notices, [], "expected no notice for pi \(optOutArguments)")
        }
    }

    func testDeliveredUserSkillCountCoversEveryAdditiveRuntime() {
        let snapshot = makeUserSkillSnapshotFixture()

        for agent in [AgentKind.claude, .pi, .opencode, .mimocode] {
            XCTAssertEqual(
                ManagedAgentLaunchPlanner.deliveredUserSkillCount(
                    agent: agent,
                    codexUserSkills: nil,
                    userSkillSnapshot: snapshot
                ),
                snapshot.acceptedPackageNames.count,
                agent.rawValue
            )
        }
        XCTAssertEqual(
            ManagedAgentLaunchPlanner.deliveredUserSkillCount(
                agent: .processWatch,
                codexUserSkills: nil,
                userSkillSnapshot: snapshot
            ),
            0
        )
    }

    func testClaudeArtifactsRemainAfterSessionStops() async throws {
        let fixture = try makePlannerFixture()
        let claudePlan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .claude,
                panelID: fixture.panelID,
                argv: ["claude"],
                cwd: "/tmp/repo"
            )
        )
        let artifactsDirectoryURL = try claudeArtifactsDirectory(from: claudePlan)
        let codexPlan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        let codexArtifactsDirectoryURL = try codexArtifactsDirectory(from: codexPlan)
        defer {
            try? fixture.fileManager.removeItem(at: artifactsDirectoryURL)
            try? fixture.fileManager.removeItem(at: codexArtifactsDirectoryURL)
        }

        XCTAssertTrue(fixture.fileManager.fileExists(atPath: artifactsDirectoryURL.path))
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: codexArtifactsDirectoryURL.path))

        fixture.sessionRuntimeStore.stopSession(sessionID: claudePlan.sessionID, at: Date())
        fixture.sessionRuntimeStore.stopSession(sessionID: codexPlan.sessionID, at: Date())
        await waitUntil {
            fixture.fileManager.fileExists(atPath: codexArtifactsDirectoryURL.path) == false
        }

        XCTAssertTrue(
            fixture.fileManager.fileExists(atPath: artifactsDirectoryURL.path),
            "Claude hook artifacts should remain available across later cleanup passes"
        )
    }

    func testCodexArtifactsDeleteImmediatelyAfterSessionStops() async throws {
        let fixture = try makePlannerFixture()
        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        let artifactsDirectoryURL = try codexArtifactsDirectory(from: plan)

        XCTAssertTrue(fixture.fileManager.fileExists(atPath: artifactsDirectoryURL.path))

        fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
        await waitUntil {
            fixture.fileManager.fileExists(atPath: artifactsDirectoryURL.path) == false
        }

        XCTAssertFalse(
            fixture.fileManager.fileExists(atPath: artifactsDirectoryURL.path),
            "Codex launch artifacts should continue deleting on session stop"
        )
    }

    func testCodexLaunchPlanDisablesEnhancedKeyboardReporting() throws {
        let fixture = try makePlannerFixture()
        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        let artifactsDirectoryURL = try codexArtifactsDirectory(from: plan)
        defer {
            try? fixture.fileManager.removeItem(at: artifactsDirectoryURL)
        }

        XCTAssertEqual(plan.environment["CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT"], "1")
        XCTAssertEqual(plan.environment["CODEX_TUI_RECORD_SESSION"], "1")
        XCTAssertEqual(
            plan.environment["TOASTTY_PANEL_ID"],
            fixture.panelID.uuidString
        )
    }

    func testManagedLaunchAdvertisesUserSkillsRootForEveryAgentKind() throws {
        AgentLaunchInstrumentation.piExtensionPathProviderForTesting = { "/toastty/pi-extension.js" }
        defer { AgentLaunchInstrumentation.piExtensionPathProviderForTesting = nil }
        let fixture = try makePlannerFixture()
        let expectedPath = ToasttyRuntimePaths.resolve().userSkillsDirectoryURL.path

        for (agent, argv) in [
            (AgentKind.codex, ["codex"]),
            (.claude, ["claude"]),
            (.opencode, ["opencode"]),
            (.mimocode, ["mimocode"]),
            (.pi, ["pi"]),
        ] {
            let plan = try fixture.planner.prepareManagedLaunch(
                ManagedAgentLaunchRequest(
                    agent: agent,
                    panelID: fixture.panelID,
                    argv: argv,
                    cwd: "/tmp/repo"
                )
            )
            defer {
                fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            }

            XCTAssertEqual(
                plan.environment["TOASTTY_USER_SKILLS_ROOT"],
                expectedPath,
                "\(agent.rawValue) launch must advertise the user skills root"
            )
        }
    }

    /// User skills are user state: a runtime-home override in the launch
    /// request no longer redirects the advertised source directory.
    func testRequestRuntimeHomeNoLongerRedirectsAdvertisedUserSkillsRoot() throws {
        let fixture = try makePlannerFixture()
        let isolatedRuntimeHome = "/tmp/toastty-planner-user-skills-tests/runtime-home"

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo",
                environment: ["TOASTTY_RUNTIME_HOME": isolatedRuntimeHome]
            )
        )
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
        }

        XCTAssertNotEqual(
            plan.environment["TOASTTY_USER_SKILLS_ROOT"],
            "\(isolatedRuntimeHome)/skills"
        )
        XCTAssertEqual(
            plan.environment["TOASTTY_USER_SKILLS_ROOT"],
            ToasttyRuntimePaths.resolve().userSkillsDirectoryURL.path
        )
    }

    /// `TOASTTY_USER_SKILLS_ROOT` in the app's own process environment (the
    /// hermetic harness override) is honored and re-advertised to children;
    /// per-launch callers remain unable to set it (reserved at the service).
    func testProcessEnvironmentUserSkillsRootOverrideIsAdvertised() throws {
        let overridePath = "/tmp/toastty-planner-user-skills-tests/hermetic-skills"
        let fixture = try makePlannerFixture(
            processEnvironmentProvider: { ["TOASTTY_USER_SKILLS_ROOT": overridePath] }
        )

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
        }

        XCTAssertEqual(plan.environment["TOASTTY_USER_SKILLS_ROOT"], overridePath)
    }

    func testPendingPanelParentClaimAdoptsLiveParentForManagedLaunch() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_010)
        let fixture = try makePlannerFixture(nowProvider: { now })
        let workspaceID = try XCTUnwrap(fixture.store.selectedWorkspace?.id)
        let targetPanelID = try splitTargetPanel(
            in: fixture.store,
            workspaceID: workspaceID,
            excluding: fixture.panelID
        )
        let parentSessionID = "pending-parent-live"
        try startManagedSession(
            in: fixture.sessionRuntimeStore,
            sessionID: parentSessionID,
            panelID: fixture.panelID,
            store: fixture.store,
            workspaceID: workspaceID
        )
        XCTAssertTrue(
            fixture.sessionRuntimeStore.recordPendingPanelParentSessionID(
                parentSessionID: parentSessionID,
                forPanelID: targetPanelID,
                at: now
            )
        )

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: targetPanelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )

        XCTAssertEqual(
            fixture.sessionRuntimeStore.sessionRegistry.sessionsByID[plan.sessionID]?.parentSessionID,
            parentSessionID
        )
    }

    func testExpiredPendingPanelParentClaimDoesNotAdoptParent() throws {
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let fixture = try makePlannerFixture(
            nowProvider: { recordedAt.addingTimeInterval(121) }
        )
        let workspaceID = try XCTUnwrap(fixture.store.selectedWorkspace?.id)
        let targetPanelID = try splitTargetPanel(
            in: fixture.store,
            workspaceID: workspaceID,
            excluding: fixture.panelID
        )
        let parentSessionID = "pending-parent-expired"
        try startManagedSession(
            in: fixture.sessionRuntimeStore,
            sessionID: parentSessionID,
            panelID: fixture.panelID,
            store: fixture.store,
            workspaceID: workspaceID
        )
        XCTAssertTrue(
            fixture.sessionRuntimeStore.recordPendingPanelParentSessionID(
                parentSessionID: parentSessionID,
                forPanelID: targetPanelID,
                at: recordedAt
            )
        )

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: targetPanelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )

        XCTAssertNil(fixture.sessionRuntimeStore.sessionRegistry.sessionsByID[plan.sessionID]?.parentSessionID)
    }

    func testPendingPanelParentClaimWithStoppedParentDoesNotAdoptParent() throws {
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let fixture = try makePlannerFixture(
            nowProvider: { recordedAt.addingTimeInterval(2) }
        )
        let workspaceID = try XCTUnwrap(fixture.store.selectedWorkspace?.id)
        let targetPanelID = try splitTargetPanel(
            in: fixture.store,
            workspaceID: workspaceID,
            excluding: fixture.panelID
        )
        let parentSessionID = "pending-parent-stopped"
        try startManagedSession(
            in: fixture.sessionRuntimeStore,
            sessionID: parentSessionID,
            panelID: fixture.panelID,
            store: fixture.store,
            workspaceID: workspaceID,
            at: recordedAt
        )
        XCTAssertTrue(
            fixture.sessionRuntimeStore.recordPendingPanelParentSessionID(
                parentSessionID: parentSessionID,
                forPanelID: targetPanelID,
                at: recordedAt
            )
        )
        fixture.sessionRuntimeStore.stopSession(
            sessionID: parentSessionID,
            at: recordedAt.addingTimeInterval(1)
        )

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: targetPanelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )

        XCTAssertNil(fixture.sessionRuntimeStore.sessionRegistry.sessionsByID[plan.sessionID]?.parentSessionID)
    }

    func testPendingPanelParentClaimIsNotRecordedForOwnPanel() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_010)
        let fixture = try makePlannerFixture(nowProvider: { now })
        let workspaceID = try XCTUnwrap(fixture.store.selectedWorkspace?.id)
        let parentSessionID = "pending-parent-own-panel"
        try startManagedSession(
            in: fixture.sessionRuntimeStore,
            sessionID: parentSessionID,
            panelID: fixture.panelID,
            store: fixture.store,
            workspaceID: workspaceID
        )

        XCTAssertFalse(
            fixture.sessionRuntimeStore.recordPendingPanelParentSessionID(
                parentSessionID: parentSessionID,
                forPanelID: fixture.panelID,
                at: now
            )
        )
        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )

        XCTAssertNil(fixture.sessionRuntimeStore.sessionRegistry.sessionsByID[plan.sessionID]?.parentSessionID)
    }

    func testExplicitParentSessionIDWinsOverPendingPanelParentClaim() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_010)
        let fixture = try makePlannerFixture(nowProvider: { now })
        let workspaceID = try XCTUnwrap(fixture.store.selectedWorkspace?.id)
        let targetPanelID = try splitTargetPanel(
            in: fixture.store,
            workspaceID: workspaceID,
            excluding: fixture.panelID
        )
        let pendingParentSessionID = "pending-parent-loses"
        let explicitParentSessionID = "explicit-parent-wins"
        try startManagedSession(
            in: fixture.sessionRuntimeStore,
            sessionID: pendingParentSessionID,
            panelID: fixture.panelID,
            store: fixture.store,
            workspaceID: workspaceID
        )
        try startManagedSession(
            in: fixture.sessionRuntimeStore,
            sessionID: explicitParentSessionID,
            panelID: UUID(),
            store: fixture.store,
            workspaceID: workspaceID
        )
        XCTAssertTrue(
            fixture.sessionRuntimeStore.recordPendingPanelParentSessionID(
                parentSessionID: pendingParentSessionID,
                forPanelID: targetPanelID,
                at: now
            )
        )

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: targetPanelID,
                argv: ["codex"],
                cwd: "/tmp/repo",
                parentSessionID: explicitParentSessionID
            )
        )

        XCTAssertEqual(
            fixture.sessionRuntimeStore.sessionRegistry.sessionsByID[plan.sessionID]?.parentSessionID,
            explicitParentSessionID
        )
    }

    func testPendingPanelParentClaimIsConsumedAfterAdoption() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_010)
        let fixture = try makePlannerFixture(nowProvider: { now })
        let workspaceID = try XCTUnwrap(fixture.store.selectedWorkspace?.id)
        let targetPanelID = try splitTargetPanel(
            in: fixture.store,
            workspaceID: workspaceID,
            excluding: fixture.panelID
        )
        let parentSessionID = "pending-parent-consumed"
        try startManagedSession(
            in: fixture.sessionRuntimeStore,
            sessionID: parentSessionID,
            panelID: fixture.panelID,
            store: fixture.store,
            workspaceID: workspaceID
        )
        XCTAssertTrue(
            fixture.sessionRuntimeStore.recordPendingPanelParentSessionID(
                parentSessionID: parentSessionID,
                forPanelID: targetPanelID,
                at: now
            )
        )

        let firstPlan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: targetPanelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        let secondPlan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: targetPanelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )

        XCTAssertEqual(
            fixture.sessionRuntimeStore.sessionRegistry.sessionsByID[firstPlan.sessionID]?.parentSessionID,
            parentSessionID
        )
        XCTAssertNil(fixture.sessionRuntimeStore.sessionRegistry.sessionsByID[secondPlan.sessionID]?.parentSessionID)
    }

    func testCodexLaunchPlanUsesHooksForStatusAndRecordsSessionContextWhenHooksAreAvailable() throws {
        let fixture = try makePlannerFixture(
            codexStatusTrackingSourceProvider: { .hooks }
        )
        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex", "--model", "gpt-5.4"],
                cwd: "/tmp/repo"
            )
        )
        let logURL = try codexSessionLogURL(from: plan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: logURL.deletingLastPathComponent())
        }

        XCTAssertEqual(plan.argv, ["codex", "--model", "gpt-5.4"])
        XCTAssertEqual(plan.environment["CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT"], "1")
        XCTAssertEqual(plan.environment["TOASTTY_PANEL_ID"], fixture.panelID.uuidString)
        XCTAssertEqual(plan.environment["CODEX_TUI_RECORD_SESSION"], "1")
        XCTAssertEqual(plan.environment["CODEX_TUI_SESSION_LOG_PATH"], logURL.path)
    }

    func testCodexSessionLogIsContextOnlyWhenHooksAreAvailable() async throws {
        let fixture = try makePlannerFixture(
            codexStatusTrackingSourceProvider: { .hooks }
        )
        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        let logURL = try codexSessionLogURL(from: plan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: logURL.deletingLastPathComponent())
        }

        _ = fixture.sessionRuntimeStore.handleCodexHookEvent(
            sessionID: plan.sessionID,
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: Date()
        )
        try appendCodexSessionLogLine(
            """
            {"ts":"2026-05-28T16:00:00.000Z","dir":"from_tui","kind":"op","payload":{"type":"user_turn","turn_id":"turn-root","items":[{"type":"text","text":"Run checks"}],"approval_policy":"never","approvals_reviewer":"reviewer"}}
            """,
            to: logURL
        )
        try await Task.sleep(nanoseconds: 500_000_000)

        let accepted = fixture.sessionRuntimeStore.handleCodexHookEvent(
            sessionID: plan.sessionID,
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: Date()
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: plan.sessionID)?.status?.kind,
            .working
        )
    }

    func testCodexSessionLogOverrideContextPersistsAcrossUserTurnsWhenHooksAreAvailable() async throws {
        let fixture = try makePlannerFixture(
            codexStatusTrackingSourceProvider: { .hooks }
        )
        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        let logURL = try codexSessionLogURL(from: plan)
        let promptFingerprint = CodexInputFingerprint.fingerprint(for: "go ahead")
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: logURL.deletingLastPathComponent())
        }

        try appendCodexSessionLogLine(
            """
            {"ts":"2026-05-28T19:22:32.686Z","dir":"from_tui","kind":"op","payload":{"OverrideTurnContext":{"cwd":null,"approval_policy":"on-request","approvals_reviewer":"guardian_subagent","permission_profile":{"type":"managed"}}}}
            """,
            to: logURL
        )
        try appendCodexSessionLogLine(
            """
            {"ts":"2026-05-28T19:24:59.371Z","dir":"from_tui","kind":"op","payload":{"UserTurn":{"items":[{"type":"text","text":"ok make a plan","text_elements":[]}],"cwd":"/tmp/repo","approval_policy":"on-request","approvals_reviewer":null}}}
            """,
            to: logURL
        )
        try appendCodexSessionLogLine(
            """
            {"ts":"2026-05-28T19:56:55.411Z","dir":"from_tui","kind":"op","payload":{"UserTurn":{"items":[{"type":"text","text":"go ahead","text_elements":[]}],"cwd":"/tmp/repo","approval_policy":"on-request","approvals_reviewer":null}}}
            """,
            to: logURL
        )
        try await Task.sleep(nanoseconds: 500_000_000)

        _ = fixture.sessionRuntimeStore.handleCodexHookEvent(
            sessionID: plan.sessionID,
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: promptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "go ahead"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: Date()
        )
        let accepted = fixture.sessionRuntimeStore.handleCodexHookEvent(
            sessionID: plan.sessionID,
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: Date()
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: plan.sessionID)?.status?.kind,
            .working
        )
    }

    func testCodexSessionLogApprovalDoesNotDriveStatusWhenHooksAreAvailable() async throws {
        let fixture = try makePlannerFixture(
            codexStatusTrackingSourceProvider: { .hooks }
        )
        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        let logURL = try codexSessionLogURL(from: plan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: logURL.deletingLastPathComponent())
        }

        try appendCodexSessionLogLine(
            """
            {"dir":"to_tui","kind":"codex_event","payload":{"turn_id":"turn-root","msg":{"type":"exec_approval_request","command":"xcodebuild test"}}}
            """,
            to: logURL
        )
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: plan.sessionID)?.status?.kind,
            .idle
        )
    }

    func testCodexSessionLogFallbackSuppressesApprovalWhenAutoReviewerIsConfigured() async throws {
        let fixture = try makePlannerFixture()
        let threadID = "019e316e-auto-review"
        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        let logURL = try codexSessionLogURL(from: plan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: logURL.deletingLastPathComponent())
        }

        try appendCodexSessionLogLine(
            """
            {"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"session_configured","session_id":"\(threadID)","thread_id":"\(threadID)","cwd":"/tmp/repo","rollout_path":"/tmp/codex-sessions/rollout-\(threadID).jsonl"}}}
            """,
            to: logURL
        )
        try appendCodexSessionLogLine(
            """
            {"timestamp":"2026-06-02T17:53:00.654Z","type":"turn_context","payload":{"turn_id":"turn-root","cwd":"/tmp/repo","approval_policy":"on-request","approvals_reviewer":"auto_review"}}
            """,
            to: logURL
        )
        await waitUntil {
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: plan.sessionID)?.status?.kind == .working
        }

        try appendCodexSessionLogLine(
            """
            {"dir":"to_tui","kind":"codex_event","payload":{"turn_id":"turn-root","msg":{"type":"exec_approval_request","command":"xcodebuild test"}}}
            """,
            to: logURL
        )
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: plan.sessionID)?.status?.kind,
            .working
        )
    }

    func testCodexSessionLogFallbackSuppressesApprovalWhenReviewerContextIsMissing() async throws {
        let fixture = try makePlannerFixture()
        let threadID = "019e316e-missing-reviewer"
        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        let logURL = try codexSessionLogURL(from: plan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: logURL.deletingLastPathComponent())
        }

        try appendCodexSessionLogLine(
            """
            {"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"session_configured","session_id":"\(threadID)","thread_id":"\(threadID)","cwd":"/tmp/repo","rollout_path":"/tmp/codex-sessions/rollout-\(threadID).jsonl"}}}
            """,
            to: logURL
        )
        try appendCodexSessionLogLine(
            """
            {"timestamp":"2026-06-02T17:53:00.654Z","type":"turn_context","payload":{"turn_id":"turn-root","cwd":"/tmp/repo","approval_policy":"on-request"}}
            """,
            to: logURL
        )
        await waitUntil {
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: plan.sessionID)?.status?.kind == .working
        }

        try appendCodexSessionLogLine(
            """
            {"dir":"to_tui","kind":"codex_event","payload":{"turn_id":"turn-root","msg":{"type":"exec_approval_request","command":"xcodebuild test"}}}
            """,
            to: logURL
        )
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: plan.sessionID)?.status?.kind,
            .working
        )
    }

    func testCodexSessionLogFallbackPublishesApprovalWhenReviewerIsExplicitlyCleared() async throws {
        let fixture = try makePlannerFixture()
        let threadID = "019e316e-human-review"
        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        let logURL = try codexSessionLogURL(from: plan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: logURL.deletingLastPathComponent())
        }

        try appendCodexSessionLogLine(
            """
            {"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"session_configured","session_id":"\(threadID)","thread_id":"\(threadID)","cwd":"/tmp/repo","rollout_path":"/tmp/codex-sessions/rollout-\(threadID).jsonl"}}}
            """,
            to: logURL
        )
        try appendCodexSessionLogLine(
            """
            {"ts":"2026-05-28T17:30:32.495Z","dir":"from_tui","kind":"op","payload":{"OverrideTurnContext":{"approval_policy":"on-request","approvals_reviewer":null}}}
            """,
            to: logURL
        )
        try appendCodexSessionLogLine(
            """
            {"timestamp":"2026-06-02T17:53:00.654Z","type":"turn_context","payload":{"turn_id":"turn-root","cwd":"/tmp/repo","approval_policy":"on-request"}}
            """,
            to: logURL
        )
        await waitUntil {
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: plan.sessionID)?.status?.kind == .working
        }

        try appendCodexSessionLogLine(
            """
            {"dir":"to_tui","kind":"codex_event","payload":{"turn_id":"turn-root","msg":{"type":"exec_approval_request","command":"xcodebuild test"}}}
            """,
            to: logURL
        )

        await waitUntil {
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: plan.sessionID)?.status?.kind ==
                .needsApproval
        }
        XCTAssertEqual(
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: plan.sessionID)?.status?.kind,
            .needsApproval
        )
    }

    func testCodexSessionLogFallbackIgnoresChildTaskCompleteBeforeRootCompletes() async throws {
        let fixture = try makePlannerFixture()
        let threadID = "019e316e-9f7f-7a33-aad9-33fe27b0f2cd"
        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
        }
        let logURL = try codexSessionLogURL(from: plan)

        try appendCodexSessionLogLine(
            """
            {"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"session_configured","session_id":"\(threadID)","thread_id":"\(threadID)","cwd":"/tmp/repo","rollout_path":"/tmp/codex-sessions/rollout-\(threadID).jsonl"}}}
            """,
            to: logURL
        )
        try appendCodexSessionLogLine(
            """
            {"dir":"to_tui","kind":"codex_event","payload":{"turn_id":"turn-root","msg":{"type":"user_message","message":"Fix sidebar state"}}}
            """,
            to: logURL
        )

        await waitUntil {
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: plan.sessionID)?.status ==
                SessionStatus(kind: .working, summary: "Working", detail: "Fix sidebar state")
        }
        XCTAssertEqual(
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: plan.sessionID)?.status,
            SessionStatus(kind: .working, summary: "Working", detail: "Fix sidebar state")
        )

        try appendCodexSessionLogLine(
            """
            {"dir":"to_tui","kind":"codex_event","payload":{"turn_id":"turn-child","msg":{"type":"task_complete","thread_id":"thread-child","last_agent_message":"Child finished"}}}
            """,
            to: logURL
        )
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: plan.sessionID)?.status,
            SessionStatus(kind: .working, summary: "Working", detail: "Fix sidebar state")
        )

        try appendCodexSessionLogLine(
            """
            {"dir":"to_tui","kind":"codex_event","payload":{"turn_id":"turn-root","msg":{"type":"task_complete","thread_id":"\(threadID)","last_agent_message":"Root finished"}}}
            """,
            to: logURL
        )

        let expectedRootCompletionStatuses = [
            SessionStatus(kind: .ready, summary: "Ready", detail: "Root finished"),
            SessionStatus(kind: .idle, summary: "Waiting", detail: "Root finished"),
        ]
        await waitUntil {
            guard let status = fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: plan.sessionID)?.status else {
                return false
            }
            return expectedRootCompletionStatuses.contains(status)
        }
        let finalStatus = fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: plan.sessionID)?.status
        XCTAssertNotNil(finalStatus)
        if let finalStatus {
            XCTAssertTrue(expectedRootCompletionStatuses.contains(finalStatus))
        }
    }

    func testLaunchPlanUsesRestoredLaunchWorkingDirectoryWhenLiveCWDIsEmpty() throws {
        let restoredCWD = "/tmp/restored-agent-pane"
        let observer = StubManagedAgentNativeSessionObserver()
        let fixture = try makePlannerFixture(
            terminalState: TerminalPanelState(
                title: "Terminal 1",
                shell: "zsh",
                cwd: "",
                launchWorkingDirectory: restoredCWD
            ),
            nativeSessionObserverRegistry: observer
        )

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: nil
            )
        )
        let artifactsDirectoryURL = try codexArtifactsDirectory(from: plan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: artifactsDirectoryURL)
        }

        XCTAssertEqual(plan.cwd, restoredCWD)
        XCTAssertEqual(plan.environment["TOASTTY_CWD"], restoredCWD)
        XCTAssertEqual(
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: plan.sessionID)?.cwd,
            restoredCWD
        )
        XCTAssertEqual(observer.observations.first?.cwd, restoredCWD)
        XCTAssertEqual(observer.observations.first?.panelID, fixture.panelID)
        XCTAssertNil(observer.observations.first?.expectedNativeSessionID)
    }

    func testPrepareManagedLaunchPassesExpectedNativeSessionIDForResumeArgv() throws {
        let observer = StubManagedAgentNativeSessionObserver()
        let fixture = try makePlannerFixture(nativeSessionObserverRegistry: observer)
        let nativeSessionID = "019e2823-f520-7690-91b6-cd84eb52dd8a"

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex", "resume", nativeSessionID],
                cwd: "/tmp/repo"
            )
        )
        let artifactsDirectoryURL = try codexArtifactsDirectory(from: plan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: artifactsDirectoryURL)
        }

        XCTAssertEqual(observer.observations.first?.expectedNativeSessionID, nativeSessionID)
        XCTAssertEqual(observer.observations.first?.panelID, fixture.panelID)
    }

    func testLaunchPlanContinuesWhenRepositoryRootResolutionTimesOut() throws {
        let cwd = "/tmp/repo-root-timeout"
        let fixture = try makePlannerFixture(
            repositoryRootResolver: { requestedCWD in
                XCTAssertEqual(requestedCWD, cwd)
                return RepositoryRootResolution(repoRoot: nil, duration: 0.2, timedOut: true)
            }
        )

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: cwd
            )
        )
        let artifactsDirectoryURL = try codexArtifactsDirectory(from: plan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: artifactsDirectoryURL)
        }

        XCTAssertEqual(plan.cwd, cwd)
        XCTAssertNil(plan.repoRoot)
        XCTAssertNil(plan.environment[ToasttyLaunchContextEnvironment.repoRootKey])
        XCTAssertEqual(
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: plan.sessionID)?.repoRoot,
            nil
        )
    }

    func testLaunchPlanUsesResolvedRepositoryRootWhenAvailable() throws {
        let cwd = "/tmp/repo-root-available/subdir"
        let repoRoot = "/tmp/repo-root-available"
        let fixture = try makePlannerFixture(
            repositoryRootResolver: { requestedCWD in
                XCTAssertEqual(requestedCWD, cwd)
                return RepositoryRootResolution(repoRoot: repoRoot, duration: 0.001, timedOut: false)
            }
        )

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .claude,
                panelID: fixture.panelID,
                argv: ["claude"],
                cwd: cwd
            )
        )
        let artifactsDirectoryURL = try claudeArtifactsDirectory(from: plan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: artifactsDirectoryURL)
        }

        XCTAssertEqual(plan.repoRoot, repoRoot)
        XCTAssertEqual(plan.environment[ToasttyLaunchContextEnvironment.repoRootKey], repoRoot)
        XCTAssertEqual(plan.environment[ToasttyLaunchContextEnvironment.agentKey], AgentKind.claude.rawValue)
        XCTAssertEqual(
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: plan.sessionID)?.repoRoot,
            repoRoot
        )
    }

    func testCodexSessionConfiguredEventPersistsResumeRecordAndCancelsLaunchScanner() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-codex-session-configured-\(UUID().uuidString)", isDirectory: true)
        let cwdURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let codexSessionsURL = rootURL.appendingPathComponent("codex-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: cwdURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexSessionsURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let observer = StubManagedAgentNativeSessionObserver()
        let resolver = CodexManagedSessionResolver(codexSessionsDirectory: codexSessionsURL)
        let fixture = try makePlannerFixture(
            nativeSessionObserverRegistry: observer,
            codexResumeResolver: resolver
        )
        let threadID = "019e316e-9f7f-7a33-aad9-33fe27b0f2cd"
        let rolloutURL = codexSessionsURL.appendingPathComponent("rollout-\(threadID).jsonl", isDirectory: false)
        try Data(
            #"{"type":"session_meta","payload":{"id":"\#(threadID)","cwd":"\#(cwdURL.path)"}}"#.utf8
        ).write(to: rolloutURL)

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: cwdURL.path
            )
        )
        let artifactsDirectoryURL = try codexArtifactsDirectory(from: plan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: artifactsDirectoryURL)
        }
        let logURL = try codexSessionLogURL(from: plan)

        try appendCodexSessionLogLine(
            """
            {"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"session_configured","session_id":"\(threadID)","thread_id":"\(threadID)","cwd":"\(cwdURL.path)","rollout_path":"\(rolloutURL.path)"}}}
            """,
            to: logURL
        )

        await waitUntil {
            (try? terminalState(panelID: fixture.panelID, state: fixture.store.state).resumeRecord?.nativeSessionID) == threadID
        }

        let resumeRecord = try XCTUnwrap(terminalState(panelID: fixture.panelID, state: fixture.store.state).resumeRecord)
        XCTAssertEqual(resumeRecord.agent, .codex)
        XCTAssertEqual(resumeRecord.nativeSessionID, threadID)
        XCTAssertEqual(resumeRecord.sessionFilePath, rolloutURL.path)
        XCTAssertEqual(resumeRecord.cwd, cwdURL.path)
        XCTAssertTrue(observer.cancelledSessionIDs.contains(plan.sessionID))
    }

    func testCodexSessionConfiguredEventDoesNotStealResumeRecordFromLivePanel() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-codex-session-configured-live-owner-\(UUID().uuidString)", isDirectory: true)
        let cwdURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let codexSessionsURL = rootURL.appendingPathComponent("codex-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: cwdURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexSessionsURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let observer = StubManagedAgentNativeSessionObserver()
        let resolver = CodexManagedSessionResolver(codexSessionsDirectory: codexSessionsURL)
        let fixture = try makePlannerFixture(
            nativeSessionObserverRegistry: observer,
            codexResumeResolver: resolver
        )
        let threadID = "019e316e-9f7f-7a33-aad9-33fe27b0f2ce"
        let rolloutURL = codexSessionsURL.appendingPathComponent("rollout-\(threadID).jsonl", isDirectory: false)
        try Data(
            #"{"type":"session_meta","payload":{"id":"\#(threadID)","cwd":"\#(cwdURL.path)"}}"#.utf8
        ).write(to: rolloutURL)

        let ownerPlan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: cwdURL.path
            )
        )
        let ownerArtifactsURL = try codexArtifactsDirectory(from: ownerPlan)
        let ownerRecord = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: threadID,
            sessionFilePath: rolloutURL.path,
            cwd: cwdURL.path,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            scopedWorkspaceIDs: [UUID()]
        )
        XCTAssertTrue(
            fixture.store.send(.updateTerminalPanelResumeRecord(panelID: fixture.panelID, resumeRecord: ownerRecord))
        )

        let workspaceID = try XCTUnwrap(fixture.store.state.selectedWorkspaceSelection()?.workspaceID)
        XCTAssertTrue(
            fixture.store.send(.splitFocusedSlotInDirection(workspaceID: workspaceID, direction: .right))
        )
        let claimantPanelID = try XCTUnwrap(fixture.store.state.workspacesByID[workspaceID]?.focusedPanelID)
        let claimantPlan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: claimantPanelID,
                argv: ["codex"],
                cwd: cwdURL.path
            )
        )
        let claimantArtifactsURL = try codexArtifactsDirectory(from: claimantPlan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: ownerPlan.sessionID, at: Date())
            fixture.sessionRuntimeStore.stopSession(sessionID: claimantPlan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: ownerArtifactsURL)
            try? fixture.fileManager.removeItem(at: claimantArtifactsURL)
        }
        let claimantLogURL = try codexSessionLogURL(from: claimantPlan)

        try appendCodexSessionLogLine(
            """
            {"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"session_configured","session_id":"\(threadID)","thread_id":"\(threadID)","cwd":"\(cwdURL.path)","rollout_path":"\(rolloutURL.path)"}}}
            """,
            to: claimantLogURL
        )
        try appendCodexSessionLogLine(
            """
            {"dir":"to_tui","kind":"codex_event","payload":{"turn_id":"turn-root","msg":{"type":"user_message","message":"Check ownership"}}}
            """,
            to: claimantLogURL
        )

        await waitUntil {
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: claimantPlan.sessionID)?.status ==
                SessionStatus(kind: .working, summary: "Working", detail: "Check ownership")
        }

        XCTAssertEqual(
            try terminalState(panelID: fixture.panelID, state: fixture.store.state).resumeRecord,
            ownerRecord
        )
        XCTAssertNil(try terminalState(panelID: claimantPanelID, state: fixture.store.state).resumeRecord)
        XCTAssertFalse(observer.cancelledSessionIDs.contains(claimantPlan.sessionID))
    }

    func testCodexRolloutClaimStartsCollabWatcherForActiveSession() throws {
        let fixture = try makePlannerFixture()
        let rolloutURL = temporaryJSONLURL()
        defer { try? fixture.fileManager.removeItem(at: rolloutURL) }

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        let artifactsDirectoryURL = try codexArtifactsDirectory(from: plan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: artifactsDirectoryURL)
        }

        XCTAssertTrue(
            fixture.store.send(
                .updateTerminalPanelResumeRecord(
                    panelID: fixture.panelID,
                    resumeRecord: codexResumeRecord(sessionFilePath: rolloutURL.path)
                )
            )
        )

        XCTAssertEqual(
            fixture.planner.codexRolloutWatcherPathsForTesting[plan.sessionID],
            rolloutURL.path
        )
    }

    func testCodexRolloutClaimBeforeLaunchRegistrationStartsCollabWatcher() throws {
        let launchStart = Date(timeIntervalSince1970: 1_800_000_000)
        let rolloutURL = temporaryJSONLURL()
        defer { try? FileManager.default.removeItem(at: rolloutURL) }
        let fixture = try makePlannerFixture(
            terminalState: TerminalPanelState(
                title: "Terminal 1",
                shell: "zsh",
                cwd: "/tmp/repo",
                resumeRecord: codexResumeRecord(
                    sessionFilePath: rolloutURL.path,
                    capturedAt: launchStart
                )
            ),
            nowProvider: { launchStart }
        )

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        let artifactsDirectoryURL = try codexArtifactsDirectory(from: plan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: artifactsDirectoryURL)
        }

        XCTAssertEqual(
            fixture.planner.codexRolloutWatcherPathsForTesting[plan.sessionID],
            rolloutURL.path
        )
    }

    func testCodexRolloutWatcherIgnoresStalePreexistingResumeRecord() throws {
        let launchStart = Date(timeIntervalSince1970: 1_800_000_000)
        let rolloutURL = temporaryJSONLURL()
        defer { try? FileManager.default.removeItem(at: rolloutURL) }
        let fixture = try makePlannerFixture(
            terminalState: TerminalPanelState(
                title: "Terminal 1",
                shell: "zsh",
                cwd: "/tmp/repo",
                resumeRecord: codexResumeRecord(
                    sessionFilePath: rolloutURL.path,
                    capturedAt: launchStart.addingTimeInterval(-1)
                )
            ),
            nowProvider: { launchStart }
        )

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        let artifactsDirectoryURL = try codexArtifactsDirectory(from: plan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: artifactsDirectoryURL)
        }

        XCTAssertNil(fixture.planner.codexRolloutWatcherPathsForTesting[plan.sessionID])
    }

    func testCodexRolloutWatcherRestartsOnPathChangeAndStopsWithSession() async throws {
        let fixture = try makePlannerFixture()
        let firstRolloutURL = temporaryJSONLURL()
        let secondRolloutURL = temporaryJSONLURL()
        defer {
            try? fixture.fileManager.removeItem(at: firstRolloutURL)
            try? fixture.fileManager.removeItem(at: secondRolloutURL)
        }

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        let artifactsDirectoryURL = try codexArtifactsDirectory(from: plan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: artifactsDirectoryURL)
        }

        XCTAssertTrue(
            fixture.store.send(
                .updateTerminalPanelResumeRecord(
                    panelID: fixture.panelID,
                    resumeRecord: codexResumeRecord(
                        nativeSessionID: "first-\(UUID().uuidString)",
                        sessionFilePath: firstRolloutURL.path
                    )
                )
            )
        )
        XCTAssertEqual(
            fixture.planner.codexRolloutWatcherPathsForTesting[plan.sessionID],
            firstRolloutURL.path
        )

        // Subagent rows sourced from the first rollout are stale once the
        // claim moves to a different file and must not survive the swap.
        let staleActivityDate = Date()
        _ = fixture.sessionRuntimeStore.updateBackgroundActivity(
            sessionID: plan.sessionID,
            activity: SessionBackgroundActivity(
                id: "stale-collab-agent",
                kind: .subagent,
                displayName: "Stale",
                startedAt: staleActivityDate,
                lastUpdatedAt: staleActivityDate
            ),
            at: staleActivityDate
        )
        XCTAssertEqual(
            fixture.sessionRuntimeStore.sessionRegistry
                .sessionsByID[plan.sessionID]?.backgroundActivitiesByID.count,
            1
        )

        XCTAssertTrue(
            fixture.store.send(
                .updateTerminalPanelResumeRecord(
                    panelID: fixture.panelID,
                    resumeRecord: codexResumeRecord(
                        nativeSessionID: "second-\(UUID().uuidString)",
                        sessionFilePath: secondRolloutURL.path
                    )
                )
            )
        )
        await waitUntil {
            fixture.planner.codexRolloutWatcherPathsForTesting[plan.sessionID] == secondRolloutURL.path
        }
        XCTAssertEqual(
            fixture.planner.codexRolloutWatcherPathsForTesting[plan.sessionID],
            secondRolloutURL.path
        )
        XCTAssertEqual(
            fixture.planner.codexSessionLogCursorStateCountForTesting,
            2,
            "Launch and canonical streams retain at most one cursor each when paths change"
        )
        XCTAssertEqual(
            fixture.sessionRuntimeStore.sessionRegistry
                .sessionsByID[plan.sessionID]?.backgroundActivitiesByID.isEmpty,
            true
        )

        fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
        await waitUntil {
            fixture.planner.codexRolloutWatcherPathsForTesting[plan.sessionID] == nil
        }

        XCTAssertNil(fixture.planner.codexRolloutWatcherPathsForTesting[plan.sessionID])
    }

    func testCodexRolloutWatcherReusesRuntimeCursorWhenSamePathReattaches() async throws {
        let fixture = try makePlannerFixture()
        let rolloutURL = temporaryJSONLURL()
        defer { try? fixture.fileManager.removeItem(at: rolloutURL) }

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        let artifactsDirectoryURL = try codexArtifactsDirectory(from: plan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: artifactsDirectoryURL)
        }

        XCTAssertTrue(fixture.store.send(
            .updateTerminalPanelResumeRecord(
                panelID: fixture.panelID,
                resumeRecord: codexResumeRecord(sessionFilePath: rolloutURL.path)
            )
        ))

        let freshEventDate = Date().addingTimeInterval(60)
        let occurredAtMilliseconds = Int(freshEventDate.timeIntervalSince1970 * 1_000)
        try appendCodexSessionLogLine(
            #"{"timestamp":"2026-07-12T18:44:11.355Z","type":"event_msg","payload":{"type":"sub_agent_activity","event_id":"call_cursor_resume","occurred_at_ms":\#(occurredAtMilliseconds),"agent_path":"/root/cursor_resume","kind":"started"}}"#,
            to: rolloutURL
        )
        await waitUntil {
            fixture.sessionRuntimeStore
                .sessionRegistry
                .activeSession(sessionID: plan.sessionID)?
                .backgroundActivitiesByID["/root/cursor_resume"] != nil
        }
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(fixture.sessionRuntimeStore.finishBackgroundActivity(
            sessionID: plan.sessionID,
            activityID: "/root/cursor_resume",
            at: Date()
        ))
        XCTAssertNil(
            fixture.sessionRuntimeStore
                .sessionRegistry
                .activeSession(sessionID: plan.sessionID)?
                .backgroundActivitiesByID["/root/cursor_resume"]
        )

        XCTAssertTrue(fixture.store.send(
            .updateTerminalPanelResumeRecord(
                panelID: fixture.panelID,
                resumeRecord: nil
            )
        ))
        XCTAssertTrue(fixture.store.send(
            .updateTerminalPanelResumeRecord(
                panelID: fixture.panelID,
                resumeRecord: codexResumeRecord(sessionFilePath: rolloutURL.path)
            )
        ))
        await waitUntil {
            fixture.planner.codexRolloutWatcherTransitionCountForTesting == 0 &&
                fixture.planner.codexRolloutWatcherPathsForTesting[plan.sessionID] == rolloutURL.path
        }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(
            fixture.sessionRuntimeStore
                .sessionRegistry
                .activeSession(sessionID: plan.sessionID)?
                .backgroundActivitiesByID["/root/cursor_resume"],
            "Reattaching the same session and path must not replay the consumed spawn"
        )
        XCTAssertEqual(fixture.planner.codexSessionLogCursorStateCountForTesting, 2)

        fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
        await waitUntil {
            fixture.planner.codexSessionLogCursorStateCountForTesting == 0
        }
    }

    func testCodexRolloutWatcherRejectsFinalDrainEventsAfterDetach() async throws {
        let fixture = try makePlannerFixture()
        let rolloutURL = temporaryJSONLURL()
        defer { try? fixture.fileManager.removeItem(at: rolloutURL) }

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        let artifactsDirectoryURL = try codexArtifactsDirectory(from: plan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: artifactsDirectoryURL)
        }

        XCTAssertTrue(fixture.store.send(
            .updateTerminalPanelResumeRecord(
                panelID: fixture.panelID,
                resumeRecord: codexResumeRecord(sessionFilePath: rolloutURL.path)
            )
        ))
        try await Task.sleep(for: .milliseconds(50))

        let occurredAtMilliseconds = Int(Date().addingTimeInterval(60).timeIntervalSince1970 * 1_000)
        try appendCodexSessionLogLine(
            #"{"timestamp":"2026-07-12T18:44:11.355Z","type":"event_msg","payload":{"type":"sub_agent_activity","event_id":"call_detach_drain","occurred_at_ms":\#(occurredAtMilliseconds),"agent_path":"/root/detach_drain","kind":"started"}}"#,
            to: rolloutURL
        )
        XCTAssertTrue(fixture.store.send(
            .updateTerminalPanelResumeRecord(
                panelID: fixture.panelID,
                resumeRecord: nil
            )
        ))

        await waitUntil {
            fixture.planner.codexRolloutWatcherTransitionCountForTesting == 0 &&
                fixture.planner.codexRolloutWatcherPathsForTesting[plan.sessionID] == nil
        }
        XCTAssertNil(
            fixture.sessionRuntimeStore
                .sessionRegistry
                .activeSession(sessionID: plan.sessionID)?
                .backgroundActivitiesByID["/root/detach_drain"],
            "Final-drain events must not mutate state after the rollout claim is detached"
        )
    }

    func testCodexRolloutWatcherAttachesWhenCodexInstrumentationFails() async throws {
        let fixture = try makePlannerFixture(fileManager: ThrowingCreateDirectoryFileManager())
        let rolloutURL = temporaryJSONLURL()
        defer { try? FileManager.default.removeItem(at: rolloutURL) }

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        XCTAssertNil(plan.environment["CODEX_TUI_SESSION_LOG_PATH"])

        XCTAssertTrue(
            fixture.store.send(
                .updateTerminalPanelResumeRecord(
                    panelID: fixture.panelID,
                    resumeRecord: codexResumeRecord(sessionFilePath: rolloutURL.path)
                )
            )
        )
        XCTAssertEqual(
            fixture.planner.codexRolloutWatcherPathsForTesting[plan.sessionID],
            rolloutURL.path
        )

        fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
        await waitUntil {
            fixture.planner.codexRolloutWatcherPathsForTesting[plan.sessionID] == nil
        }
        XCTAssertNil(fixture.planner.codexRolloutWatcherPathsForTesting[plan.sessionID])
    }

    func testCodexRolloutWatcherDoesNotAttachForNonCodexSession() throws {
        let fixture = try makePlannerFixture()
        let rolloutURL = temporaryJSONLURL()
        defer { try? fixture.fileManager.removeItem(at: rolloutURL) }

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .claude,
                panelID: fixture.panelID,
                argv: ["claude"],
                cwd: "/tmp/repo"
            )
        )
        let artifactsDirectoryURL = try claudeArtifactsDirectory(from: plan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: artifactsDirectoryURL)
        }

        XCTAssertTrue(
            fixture.store.send(
                .updateTerminalPanelResumeRecord(
                    panelID: fixture.panelID,
                    resumeRecord: ManagedAgentResumeRecord(
                        agent: .claude,
                        nativeSessionID: UUID().uuidString,
                        sessionFilePath: rolloutURL.path,
                        cwd: "/tmp/repo",
                        capturedAt: Date()
                    )
                )
            )
        )

        XCTAssertNil(fixture.planner.codexRolloutWatcherPathsForTesting[plan.sessionID])
    }

    func testCodexRolloutWatcherOnlyHandlesBackgroundActivityEvents() async throws {
        let fixture = try makePlannerFixture()
        let rolloutURL = temporaryJSONLURL()
        defer { try? fixture.fileManager.removeItem(at: rolloutURL) }

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        let artifactsDirectoryURL = try codexArtifactsDirectory(from: plan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: artifactsDirectoryURL)
        }

        XCTAssertTrue(
            fixture.store.send(
                .updateTerminalPanelResumeRecord(
                    panelID: fixture.panelID,
                    resumeRecord: codexResumeRecord(sessionFilePath: rolloutURL.path)
                )
            )
        )
        XCTAssertEqual(
            fixture.planner.codexRolloutWatcherPathsForTesting[plan.sessionID],
            rolloutURL.path
        )

        try appendCodexSessionLogLine(
            #"{"dir":"to_tui","kind":"codex_event","payload":{"turn_id":"turn-root","msg":{"type":"task_started"}}}"#,
            to: rolloutURL
        )
        // Entries must postdate the session start or the multi-agent replay
        // cutoff (correctly) discards them as prior-launch history.
        let freshEntryTimestamp = Date().addingTimeInterval(60)
            .ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        try appendCodexSessionLogLine(
            #"{"timestamp":"\#(freshEntryTimestamp)","type":"response_item","payload":{"type":"function_call","id":"fc_spawn","name":"spawn_agent","namespace":"multi_agent_v1","arguments":"{\"agent_type\":\"default\",\"message\":\"Run focused checks\"}","call_id":"call_spawn"}}"#,
            to: rolloutURL
        )
        try appendCodexSessionLogLine(
            #"{"timestamp":"\#(freshEntryTimestamp)","type":"response_item","payload":{"type":"function_call_output","call_id":"call_spawn","output":"{\"agent_id\":\"agent-1\",\"nickname\":\"Focused check\"}"}}"#,
            to: rolloutURL
        )

        await waitUntil {
            fixture.sessionRuntimeStore
                .sessionRegistry
                .activeSession(sessionID: plan.sessionID)?
                .backgroundActivitiesByID["agent-1"] != nil
        }

        let activeSession = try XCTUnwrap(
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: plan.sessionID)
        )
        XCTAssertEqual(
            activeSession.status,
            SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt")
        )
        XCTAssertEqual(activeSession.backgroundActivitiesByID["agent-1"]?.displayName, "Focused check")
        XCTAssertEqual(activeSession.backgroundActivitiesByID["agent-1"]?.command, "Run focused checks")
    }

    func testCodexRolloutWatcherProjectsCurrentCollaborationLifecycle() async throws {
        let fixture = try makePlannerFixture()
        let rolloutURL = temporaryJSONLURL()
        defer { try? fixture.fileManager.removeItem(at: rolloutURL) }

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        let artifactsDirectoryURL = try codexArtifactsDirectory(from: plan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: artifactsDirectoryURL)
        }

        XCTAssertTrue(
            fixture.store.send(
                .updateTerminalPanelResumeRecord(
                    panelID: fixture.panelID,
                    resumeRecord: codexResumeRecord(sessionFilePath: rolloutURL.path)
                )
            )
        )

        let freshEventDate = Date().addingTimeInterval(60)
        let occurredAtMilliseconds = Int(freshEventDate.timeIntervalSince1970 * 1_000)
        let freshEntryTimestamp = freshEventDate
            .ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        try appendCodexSessionLogLine(
            #"{"timestamp":"2026-07-12T18:44:11.355Z","type":"event_msg","payload":{"type":"sub_agent_activity","event_id":"call_spawn","occurred_at_ms":\#(occurredAtMilliseconds),"agent_path":"/root/scroll_implementation","kind":"started"}}"#,
            to: rolloutURL
        )

        await waitUntil {
            fixture.sessionRuntimeStore
                .sessionRegistry
                .activeSession(sessionID: plan.sessionID)?
                .backgroundActivitiesByID["/root/scroll_implementation"] != nil
        }

        let activeSession = try XCTUnwrap(
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: plan.sessionID)
        )
        XCTAssertEqual(
            activeSession.status,
            SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt")
        )
        XCTAssertEqual(
            activeSession.backgroundActivitiesByID["/root/scroll_implementation"]?.displayName,
            "scroll_implementation"
        )

        try appendCodexSessionLogLine(
            #"{"timestamp":"\#(freshEntryTimestamp)","type":"response_item","payload":{"type":"agent_message","author":"/root/scroll_implementation","recipient":"/root","content":[{"type":"input_text","text":"Message Type: FINAL_ANSWER\\nTask name: /root"}]}}"#,
            to: rolloutURL
        )

        await waitUntil {
            fixture.sessionRuntimeStore
                .sessionRegistry
                .activeSession(sessionID: plan.sessionID)?
                .backgroundActivitiesByID["/root/scroll_implementation"] == nil
        }

        let followUpEventDate = freshEventDate.addingTimeInterval(1)
        let followUpTimestamp = followUpEventDate
            .ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        try appendCodexSessionLogLine(
            #"{"timestamp":"\#(followUpTimestamp)","type":"response_item","payload":{"type":"agent_message","author":"/root","recipient":"/root/scroll_implementation","content":[{"type":"input_text","text":"Message Type: NEW_TASK\\nTask name: /root/scroll_implementation"}]}}"#,
            to: rolloutURL
        )

        await waitUntil {
            fixture.sessionRuntimeStore
                .sessionRegistry
                .activeSession(sessionID: plan.sessionID)?
                .backgroundActivitiesByID["/root/scroll_implementation"] != nil
        }

        let secondFinalTimestamp = followUpEventDate.addingTimeInterval(1)
            .ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        try appendCodexSessionLogLine(
            #"{"timestamp":"\#(secondFinalTimestamp)","type":"response_item","payload":{"type":"agent_message","author":"/root/scroll_implementation","recipient":"/root","content":[{"type":"input_text","text":"Message Type: FINAL_ANSWER\\nTask name: /root"}]}}"#,
            to: rolloutURL
        )

        await waitUntil {
            fixture.sessionRuntimeStore
                .sessionRegistry
                .activeSession(sessionID: plan.sessionID)?
                .backgroundActivitiesByID["/root/scroll_implementation"] == nil
        }
    }

    func testCodexRolloutWatcherEnrichesHookActivityWithoutTakingLifecycleOwnership() async throws {
        let fixture = try makePlannerFixture(codexStatusTrackingSourceProvider: { .hooks })
        let firstRolloutURL = temporaryJSONLURL()
        let secondRolloutURL = temporaryJSONLURL()
        defer {
            try? fixture.fileManager.removeItem(at: firstRolloutURL)
            try? fixture.fileManager.removeItem(at: secondRolloutURL)
        }

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
        }

        XCTAssertTrue(
            fixture.store.send(
                .updateTerminalPanelResumeRecord(
                    panelID: fixture.panelID,
                    resumeRecord: codexResumeRecord(sessionFilePath: firstRolloutURL.path)
                )
            )
        )

        let metadataHookEvent = CodexHookEvent(
            hookEventName: "PreToolUse",
            threadID: "thread-root",
            turnID: "turn-root",
            promptFingerprint: nil,
            status: nil,
            nativeSessionID: "thread-root",
            sessionFilePath: nil,
            cwd: nil,
            spawnMetadata: CodexSpawnHookMetadata(
                toolUseID: "call_spawn",
                taskName: "hook_owned",
                message: "Review the hook metadata path"
            )
        )
        XCTAssertTrue(fixture.sessionRuntimeStore.handleCodexHookEvent(
            sessionID: plan.sessionID,
            event: metadataHookEvent,
            at: Date()
        ))
        XCTAssertTrue(fixture.sessionRuntimeStore
            .sessionRegistry
            .activeSession(sessionID: plan.sessionID)?
            .backgroundActivitiesByID.isEmpty == true)

        XCTAssertTrue(
            fixture.store.send(
                .updateTerminalPanelResumeRecord(
                    panelID: fixture.panelID,
                    resumeRecord: codexResumeRecord(sessionFilePath: secondRolloutURL.path)
                )
            )
        )
        let freshEventDate = Date().addingTimeInterval(60)
        let occurredAtMilliseconds = Int(freshEventDate.timeIntervalSince1970 * 1_000)
        let freshEntryTimestamp = freshEventDate
            .ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        try appendCodexSessionLogLine(
            #"{"timestamp":"\#(freshEntryTimestamp)","type":"response_item","payload":{"type":"function_call","name":"spawn_agent","namespace":"collaboration","arguments":"{\"message\":\"gAAAAABqVShH-encrypted-payload\",\"task_name\":\"hook_owned\"}","call_id":"call_spawn"}}"#,
            to: secondRolloutURL
        )
        try appendCodexSessionLogLine(
            #"{"timestamp":"\#(freshEntryTimestamp)","type":"event_msg","payload":{"type":"sub_agent_activity","event_id":"call_spawn","occurred_at_ms":\#(occurredAtMilliseconds),"agent_thread_id":"hook-owned","agent_path":"/root/hook_owned","kind":"started"}}"#,
            to: secondRolloutURL
        )
        try appendCodexSessionLogLine(
            #"{"timestamp":"\#(freshEntryTimestamp)","type":"response_item","payload":{"type":"function_call_output","call_id":"call_spawn","output":"{\"task_name\":\"/root/hook_owned\"}"}}"#,
            to: secondRolloutURL
        )

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(fixture.sessionRuntimeStore
            .sessionRegistry
            .activeSession(sessionID: plan.sessionID)?
            .backgroundActivitiesByID.isEmpty == true)

        let lifecycleHookEvent = CodexHookEvent(
            hookEventName: "SubagentStart",
            threadID: "thread-root",
            turnID: "turn-root",
            promptFingerprint: nil,
            status: nil,
            nativeSessionID: "thread-root",
            sessionFilePath: nil,
            cwd: nil,
            subagentID: "hook-owned",
            subagentType: "default"
        )
        XCTAssertTrue(fixture.sessionRuntimeStore.handleCodexHookEvent(
            sessionID: plan.sessionID,
            event: lifecycleHookEvent,
            at: Date()
        ))

        await waitUntil {
            fixture.sessionRuntimeStore
                .sessionRegistry
                .activeSession(sessionID: plan.sessionID)?
                .backgroundActivitiesByID["hook-owned"]?
                .command == "Review the hook metadata path"
        }
        let enrichedActivity = try XCTUnwrap(
            fixture.sessionRuntimeStore
                .sessionRegistry
                .activeSession(sessionID: plan.sessionID)?
                .backgroundActivitiesByID["hook-owned"]
        )
        XCTAssertEqual(enrichedActivity.displayName, "hook_owned")
        XCTAssertEqual(enrichedActivity.command, "Review the hook metadata path")
        XCTAssertNil(
            fixture.sessionRuntimeStore
                .sessionRegistry
                .activeSession(sessionID: plan.sessionID)?
                .backgroundActivitiesByID["/root/hook_owned"]
        )

        let finalTimestamp = freshEventDate.addingTimeInterval(1)
            .ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        try appendCodexSessionLogLine(
            #"{"timestamp":"\#(finalTimestamp)","type":"response_item","payload":{"type":"agent_message","author":"/root/hook_owned","recipient":"/root","content":[{"type":"input_text","text":"Message Type: FINAL_ANSWER\nTask name: /root"}]}}"#,
            to: secondRolloutURL
        )
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(
            fixture.sessionRuntimeStore
                .sessionRegistry
                .activeSession(sessionID: plan.sessionID)?
                .backgroundActivitiesByID["hook-owned"]
        )

        let unmatchedTimestamp = freshEventDate.addingTimeInterval(2)
            .ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        try appendCodexSessionLogLine(
            #"{"timestamp":"\#(unmatchedTimestamp)","type":"response_item","payload":{"type":"function_call","name":"spawn_agent","arguments":"{\"message\":\"This row must not be created\",\"task_name\":\"missing_hook\"}","call_id":"call_missing_hook"}}"#,
            to: secondRolloutURL
        )
        try appendCodexSessionLogLine(
            #"{"timestamp":"\#(unmatchedTimestamp)","type":"event_msg","payload":{"type":"sub_agent_activity","event_id":"call_missing_hook","agent_thread_id":"missing-hook","agent_path":"/root/missing_hook","kind":"started"}}"#,
            to: secondRolloutURL
        )
        try appendCodexSessionLogLine(
            #"{"timestamp":"\#(unmatchedTimestamp)","type":"response_item","payload":{"type":"function_call_output","call_id":"call_missing_hook","output":"{\"task_name\":\"/root/missing_hook\"}"}}"#,
            to: secondRolloutURL
        )
        try await Task.sleep(for: .milliseconds(200))
        let activeActivities = try XCTUnwrap(
            fixture.sessionRuntimeStore
                .sessionRegistry
                .activeSession(sessionID: plan.sessionID)?
                .backgroundActivitiesByID
        )
        XCTAssertNil(activeActivities["missing-hook"])
        XCTAssertNil(activeActivities["/root/missing_hook"])
    }

    func testCodexLaunchPlanDisablesEnhancedKeyboardReportingWhenInstrumentationFails() throws {
        let fixture = try makePlannerFixture(fileManager: ThrowingCreateDirectoryFileManager())
        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )

        XCTAssertEqual(plan.argv, ["codex"])
        XCTAssertEqual(plan.environment["CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT"], "1")
        XCTAssertNil(plan.environment["CODEX_TUI_RECORD_SESSION"])
        XCTAssertEqual(
            plan.environment["TOASTTY_PANEL_ID"],
            fixture.panelID.uuidString
        )
    }

    func testOpenCodeLaunchPlanPreservesUserConfigContentWhenInstrumentationIsSkipped() throws {
        let fixture = try makePlannerFixture()
        let userConfigContent = #"{"plugin":["user-plugin"]}"#
        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .opencode,
                panelID: fixture.panelID,
                argv: ["opencode"],
                cwd: "/tmp/repo",
                environment: [
                    "OPENCODE_CONFIG_CONTENT": userConfigContent,
                ]
            )
        )
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
        }

        XCTAssertEqual(plan.argv, ["opencode"])
        XCTAssertEqual(plan.environment["OPENCODE_CONFIG_CONTENT"], userConfigContent)
        XCTAssertNil(plan.environment["MIMOCODE_CONFIG_CONTENT"])
        XCTAssertEqual(
            plan.environment["TOASTTY_PANEL_ID"],
            fixture.panelID.uuidString
        )
        XCTAssertEqual(
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: plan.sessionID)?.agent,
            .opencode
        )
    }
}

@MainActor
private func makePlannerFixture(
    terminalState: TerminalPanelState? = nil,
    fileManager: FileManager = .default,
    repositoryRootResolver: @escaping @MainActor (String?) -> RepositoryRootResolution = {
        RepositoryRootLocator.inferRepoRootBestEffort(from: $0)
    },
    nowProvider: @escaping @Sendable () -> Date = Date.init,
    nativeSessionObserverRegistry: (any ManagedAgentNativeSessionObserving)? = nil,
    codexResumeResolver: (any CodexManagedSessionResolving)? = nil,
    codexStatusTrackingSourceProvider: @escaping @MainActor () -> CodexStatusTrackingSource = {
        .sessionLogFallback(reason: "test")
    },
    codexSkillsResolver: (any CodexManagedLaunchSkillsResolving)? = nil,
    claudeSkillsBundleManager: (any ClaudeSkillsBundleManaging)? = nil,
    userSkillSnapshotProvider: (any ToasttyUserSkillSnapshotProviding)? = nil,
    processEnvironmentProvider: (@Sendable () -> [String: String])? = nil
) throws -> (
    store: AppStore,
    planner: ManagedAgentLaunchPlanner,
    sessionRuntimeStore: SessionRuntimeStore,
    panelID: UUID,
    fileManager: FileManager
) {
    var state = AppState.bootstrap()
    let window = try XCTUnwrap(state.windows.first)
    let workspaceID = try XCTUnwrap(window.selectedWorkspaceID ?? window.workspaceIDs.first)
    var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
    let panelID = try XCTUnwrap(workspace.focusedPanelID)
    if let terminalState {
        _ = workspace.updateSelectedTab { tab in
            tab.panels[panelID] = .terminal(terminalState)
        }
        state.workspacesByID[workspaceID] = workspace
    }

    let store = AppStore(state: state, persistTerminalFontPreference: false)
    let sessionRuntimeStore = SessionRuntimeStore()
    sessionRuntimeStore.bind(store: store)

    let resolvedCodexSkillsResolver = codexSkillsResolver
        ?? TestCodexManagedLaunchSkillsResolver(
            decision: CodexManagedLaunchSkillsDecision(configuration: nil, status: nil)
        )
    let planner = ManagedAgentLaunchPlanner(
        store: store,
        sessionRuntimeStore: sessionRuntimeStore,
        fileManager: fileManager,
        repositoryRootResolver: repositoryRootResolver,
        nowProvider: nowProvider,
        cliExecutablePathProvider: { "/bin/sh" },
        socketPathProvider: { "/tmp/toastty-tests.sock" },
        codexStatusTrackingSourceProvider: codexStatusTrackingSourceProvider,
        readVisibleText: { _ in nil },
        promptState: { _ in .unavailable },
        nativeSessionObserverRegistry: nativeSessionObserverRegistry,
        codexResumeResolver: codexResumeResolver,
        codexSkillsResolver: resolvedCodexSkillsResolver,
        claudeSkillsBundleManager: claudeSkillsBundleManager ?? TestClaudeSkillsBundleManager(configuration: nil),
        userSkillSnapshotProvider: userSkillSnapshotProvider
            ?? RecordingUserSkillSnapshotProvider(snapshot: nil),
        processEnvironmentProvider: processEnvironmentProvider
    )

    return (store, planner, sessionRuntimeStore, panelID, .default)
}

private final class RecordingUserSkillSnapshotProvider: ToasttyUserSkillSnapshotProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let snapshot: UserSkillPluginSnapshot?
    private var preparedCount = 0
    private var existingCount = 0

    init(snapshot: UserSkillPluginSnapshot?) {
        self.snapshot = snapshot
    }

    var prepareSnapshotCallCount: Int { lock.withLock { preparedCount } }
    var existingSnapshotCallCount: Int { lock.withLock { existingCount } }

    func prepareSnapshot() throws -> UserSkillPluginSnapshot? {
        lock.withLock { preparedCount += 1 }
        return snapshot
    }

    func existingSnapshot() -> UserSkillPluginSnapshot? {
        lock.withLock { existingCount += 1 }
        return snapshot
    }
}

private final class ThrowingPrepareUserSkillSnapshotProvider: ToasttyUserSkillSnapshotProviding, @unchecked Sendable {
    private let existing: UserSkillPluginSnapshot?

    init(existing: UserSkillPluginSnapshot?) {
        self.existing = existing
    }

    func prepareSnapshot() throws -> UserSkillPluginSnapshot? {
        throw ToasttyUserSkillCatalogError.snapshotWriteFailed("/tmp/fixture-staging")
    }

    func existingSnapshot() -> UserSkillPluginSnapshot? { existing }
}

private final class HangingUserSkillSnapshotProvider: ToasttyUserSkillSnapshotProviding, @unchecked Sendable {
    private let hangSeconds: TimeInterval

    init(hangSeconds: TimeInterval) {
        self.hangSeconds = hangSeconds
    }

    func prepareSnapshot() throws -> UserSkillPluginSnapshot? {
        Thread.sleep(forTimeInterval: hangSeconds)
        return nil
    }

    func existingSnapshot() -> UserSkillPluginSnapshot? { nil }
}

private final class SnapshotCapturingCodexSkillsResolver: CodexManagedLaunchSkillsResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var managedResolutions: [UserSkillSnapshotResolution] = []
    private var restoredResolutions: [UserSkillSnapshotResolution] = []

    var capturedManagedResolutions: [UserSkillSnapshotResolution] { lock.withLock { managedResolutions } }
    var capturedRestoredResolutions: [UserSkillSnapshotResolution] { lock.withLock { restoredResolutions } }

    func resolve(
        request _: ManagedAgentLaunchRequest,
        workingDirectory _: String?
    ) -> CodexManagedLaunchSkillsDecision {
        CodexManagedLaunchSkillsDecision(configuration: nil, status: nil)
    }

    func resolveForManagedLaunch(
        request _: ManagedAgentLaunchRequest,
        workingDirectory _: String?,
        userSkillResolution: UserSkillSnapshotResolution
    ) async -> CodexManagedLaunchSkillsDecision {
        lock.withLock { managedResolutions.append(userSkillResolution) }
        return CodexManagedLaunchSkillsDecision(configuration: nil, status: nil)
    }

    func resolveForRestoredManagedLaunch(
        request _: ManagedAgentLaunchRequest,
        workingDirectory _: String?,
        userSkillResolution: UserSkillSnapshotResolution
    ) -> CodexManagedLaunchSkillsDecision {
        lock.withLock { restoredResolutions.append(userSkillResolution) }
        return CodexManagedLaunchSkillsDecision(configuration: nil, status: nil)
    }
}

private func makeUserSkillSnapshotFixture(
    rootPath: String = "/tmp/toastty-user-snapshot-fixture"
) -> UserSkillPluginSnapshot {
    let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
    let marketplaceRootURL = rootURL.appendingPathComponent("marketplace", isDirectory: true)
    let pluginRootURL = marketplaceRootURL
        .appendingPathComponent("plugins", isDirectory: true)
        .appendingPathComponent("toastty-user", isDirectory: true)
    return UserSkillPluginSnapshot(
        pluginName: "toastty-user",
        version: "0.1.0-abcdefabcdef",
        sourceDigest: "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd",
        pluginContentDigest: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
        pluginRootURL: pluginRootURL,
        marketplaceRootURL: marketplaceRootURL,
        skillsRootURL: pluginRootURL.appendingPathComponent("skills", isDirectory: true),
        receiptURL: rootURL.appendingPathComponent("receipt.json"),
        acceptedPackageNames: ["alpha-skill"]
    )
}

private func makeStagedSkillsConfigurationFixture() -> ClaudeSkillsLaunchConfiguration {
    ClaudeSkillsLaunchConfiguration(
        pluginRootPath: "/tmp/toastty-staged-plugin",
        skillsRootPath: "/tmp/toastty-staged-plugin/skills",
        version: "1.0.0",
        contentDigest: "abc123"
    )
}

@MainActor
private func skillsPaths(
    in plan: ManagedAgentLaunchPlan,
    configContentKey: String
) throws -> [String] {
    let configContent = try XCTUnwrap(plan.environment[configContentKey])
    let configObject = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(configContent.utf8)) as? [String: Any]
    )
    let skills = try XCTUnwrap(configObject["skills"] as? [String: Any])
    return try XCTUnwrap(skills["paths"] as? [String])
}

private final class SkillsProvisionedNoticeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ManagedAgentSkillsProvisionedNotice] = []

    var notices: [ManagedAgentSkillsProvisionedNotice] { lock.withLock { storage } }

    func record(_ notice: ManagedAgentSkillsProvisionedNotice?) {
        guard let notice else { return }
        lock.withLock { storage.append(notice) }
    }
}

private final class CodexSkillsUnavailableNoticeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ManagedCodexSkillsUnavailableNotice] = []

    var notices: [ManagedCodexSkillsUnavailableNotice] { lock.withLock { storage } }

    func record(_ notice: ManagedCodexSkillsUnavailableNotice?) {
        guard let notice else { return }
        lock.withLock { storage.append(notice) }
    }
}

private final class TestClaudeSkillsBundleManager: ClaudeSkillsBundleManaging, @unchecked Sendable {
    private let configuration: ClaudeSkillsLaunchConfiguration?

    init(configuration: ClaudeSkillsLaunchConfiguration?) {
        self.configuration = configuration
    }

    func existingVerifiedConfiguration() -> ClaudeSkillsLaunchConfiguration? {
        configuration
    }

    func deliveryStatus() async -> ClaudeSkillsDeliveryStatus {
        if let configuration {
            return .providedAtLaunch(configuration)
        }
        return .unavailable(detail: "test")
    }

    func prepareForManagedLaunch() async -> ClaudeSkillsLaunchConfiguration? {
        configuration
    }
}

private final class TestCodexManagedLaunchSkillsResolver: CodexManagedLaunchSkillsResolving, @unchecked Sendable {
    private let decision: CodexManagedLaunchSkillsDecision

    init(decision: CodexManagedLaunchSkillsDecision) {
        self.decision = decision
    }

    func resolve(
        request _: ManagedAgentLaunchRequest,
        workingDirectory _: String?
    ) -> CodexManagedLaunchSkillsDecision {
        decision
    }
}

private final class RecordingCodexManagedLaunchSkillsResolver: CodexManagedLaunchSkillsResolving, @unchecked Sendable {
    private let lock = NSLock()
    private let decision: CodexManagedLaunchSkillsDecision
    private var managedCount = 0
    private var restoredCount = 0

    init(decision: CodexManagedLaunchSkillsDecision) {
        self.decision = decision
    }

    var managedResolveCount: Int { lock.withLock { managedCount } }
    var restoredResolveCount: Int { lock.withLock { restoredCount } }

    func resolve(
        request _: ManagedAgentLaunchRequest,
        workingDirectory _: String?
    ) -> CodexManagedLaunchSkillsDecision {
        decision
    }

    func resolveForManagedLaunch(
        request _: ManagedAgentLaunchRequest,
        workingDirectory _: String?
    ) async -> CodexManagedLaunchSkillsDecision {
        lock.withLock { managedCount += 1 }
        return decision
    }

    func resolveForRestoredManagedLaunch(
        request _: ManagedAgentLaunchRequest,
        workingDirectory _: String?
    ) -> CodexManagedLaunchSkillsDecision {
        lock.withLock { restoredCount += 1 }
        return decision
    }
}

@MainActor
private func splitTargetPanel(
    in store: AppStore,
    workspaceID: UUID,
    excluding sourcePanelID: UUID
) throws -> UUID {
    XCTAssertTrue(store.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal)))
    return try XCTUnwrap(
        store.state.workspacesByID[workspaceID]?
            .layoutTree
            .allSlotInfos
            .map(\.panelID)
            .first { $0 != sourcePanelID }
    )
}

@MainActor
private func startManagedSession(
    in sessionRuntimeStore: SessionRuntimeStore,
    sessionID: String,
    panelID: UUID,
    store: AppStore,
    workspaceID: UUID,
    at now: Date = Date(timeIntervalSince1970: 1_700_000_000),
    agent: AgentKind = .claude
) throws {
    sessionRuntimeStore.startSession(
        sessionID: sessionID,
        agent: agent,
        panelID: panelID,
        windowID: try XCTUnwrap(store.state.windows.first?.id),
        workspaceID: workspaceID,
        cwd: "/tmp/repo",
        repoRoot: "/tmp/repo",
        at: now
    )
}

private func claudeArtifactsDirectory(from plan: ManagedAgentLaunchPlan) throws -> URL {
    let settingsIndex = try XCTUnwrap(plan.argv.firstIndex(of: "--settings"))
    let settingsPath = try XCTUnwrap(plan.argv[safe: settingsIndex + 1])
    return URL(fileURLWithPath: settingsPath).deletingLastPathComponent()
}

private func codexArtifactsDirectory(from plan: ManagedAgentLaunchPlan) throws -> URL {
    let configIndex = try XCTUnwrap(plan.argv.firstIndex(of: "-c"))
    let configValue = try XCTUnwrap(plan.argv[safe: configIndex + 1])
    let prefix = "notify=[\"/bin/sh\",\""
    let suffix = "\"]"

    XCTAssertTrue(configValue.hasPrefix(prefix))
    XCTAssertTrue(configValue.hasSuffix(suffix))

    let startIndex = configValue.index(configValue.startIndex, offsetBy: prefix.count)
    let endIndex = configValue.index(configValue.endIndex, offsetBy: -suffix.count)
    let notifyScriptPath = String(configValue[startIndex..<endIndex])
    return URL(fileURLWithPath: notifyScriptPath).deletingLastPathComponent()
}

private func codexSessionLogURL(from plan: ManagedAgentLaunchPlan) throws -> URL {
    let path = try XCTUnwrap(plan.environment["CODEX_TUI_SESSION_LOG_PATH"])
    return URL(fileURLWithPath: path)
}

private func temporaryJSONLURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("toastty-codex-rollout-\(UUID().uuidString).jsonl", isDirectory: false)
}

private func codexResumeRecord(
    nativeSessionID: String = UUID().uuidString,
    sessionFilePath: String,
    cwd: String = "/tmp/repo",
    capturedAt: Date = Date()
) -> ManagedAgentResumeRecord {
    ManagedAgentResumeRecord(
        agent: .codex,
        nativeSessionID: nativeSessionID,
        sessionFilePath: sessionFilePath,
        cwd: cwd,
        capturedAt: capturedAt
    )
}

private func appendCodexSessionLogLine(_ line: String, to url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) == false {
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((line.hasSuffix("\n") ? line : line + "\n").utf8))
}

@MainActor
private func terminalState(panelID: UUID, state: AppState) throws -> TerminalPanelState {
    let workspace = try XCTUnwrap(state.workspacesByID.values.first { $0.panelState(for: panelID) != nil })
    guard case .terminal(let terminalState) = workspace.panelState(for: panelID) else {
        XCTFail("expected terminal panel state")
        throw ManagedAgentLaunchPlannerTestError.expectedTerminalPanel
    }
    return terminalState
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000)
    while condition() == false && Date() < deadline {
        await Task.yield()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

private final class ThrowingCreateDirectoryFileManager: FileManager {
    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private enum ManagedAgentLaunchPlannerTestError: Error {
    case expectedTerminalPanel
}

@MainActor
private final class StubManagedAgentNativeSessionObserver: ManagedAgentNativeSessionObserving {
    private(set) var observations: [ManagedAgentNativeSessionObservationContext] = []
    private(set) var cancelledSessionIDs: [String] = []

    func startObservation(_ observation: ManagedAgentNativeSessionObservationContext) {
        observations.append(observation)
    }

    func cancelObservation(sessionID: String) {
        cancelledSessionIDs.append(sessionID)
    }
}
