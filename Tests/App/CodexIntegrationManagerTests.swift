import Foundation
import XCTest
@testable import ToasttyApp

final class CodexSkillsManagerTests: XCTestCase {
    func testFirstLaunchDisablesBeforeInstallThenVerifiesOrdinarySkills() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let preparation = try fixture.manager.prepareForManagedLaunch(
            runtime: fixture.runtime(),
            hasActiveManagedCodexSession: false
        )

        XCTAssertEqual(preparation.configuration?.qualifiedSkillNames, fixture.expectedQualifiedNames)
        XCTAssertEqual(preparation.status.availability, .ready)
        XCTAssertTrue(preparation.installedOrUpdated)
        XCTAssertTrue(preparation.firstInstallSucceeded)
        let operations = fixture.recorder.operations
        let installIndex = try XCTUnwrap(operations.firstIndex(of: "plugin.install"))
        let writes = operations.enumerated()
            .filter { $0.element == "skills.write" }
            .map(\.offset)
        XCTAssertEqual(writes.count, 2)
        XCTAssertLessThan(writes[0], installIndex)
        XCTAssertGreaterThan(writes[1], installIndex)
        XCTAssertEqual(
            fixture.skillClient.states(for: fixture.runtime()).filter { $0.key.hasPrefix("toastty:") },
            Dictionary(uniqueKeysWithValues: (fixture.expectedQualifiedNames + ["toastty:worktree-done"]).map {
                ($0, false)
            })
        )
    }

    func testVerifiedSecondLaunchPerformsNoCLIOrConfigWork() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.manager.prepareForManagedLaunch(
            runtime: fixture.runtime(),
            hasActiveManagedCodexSession: false
        )
        fixture.recorder.reset()

        let preparation = try fixture.manager.prepareForManagedLaunch(
            runtime: fixture.runtime(),
            hasActiveManagedCodexSession: false
        )

        XCTAssertNotNil(preparation.configuration)
        XCTAssertFalse(preparation.installedOrUpdated)
        XCTAssertEqual(fixture.recorder.operations, [])
    }

    func testUpdateIsDeferredWhileSessionIsActiveAndAppliedLater() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.manager.prepareForManagedLaunch(
            runtime: fixture.runtime(),
            hasActiveManagedCodexSession: false
        )
        try fixture.changeBundledPlugin(version: "0.2.1")
        fixture.recorder.reset()

        let deferred = try fixture.manager.prepareForManagedLaunch(
            runtime: fixture.runtime(),
            hasActiveManagedCodexSession: true
        )

        XCTAssertEqual(deferred.configuration?.contentDigest, first.configuration?.contentDigest)
        XCTAssertTrue(deferred.status.updatePending)
        XCTAssertFalse(fixture.recorder.operations.contains("plugin.install"))

        fixture.recorder.reset()
        let updated = try fixture.manager.prepareForManagedLaunch(
            runtime: fixture.runtime(),
            hasActiveManagedCodexSession: false
        )

        XCTAssertNotEqual(updated.configuration?.contentDigest, first.configuration?.contentDigest)
        XCTAssertEqual(updated.configuration?.version, "0.2.1")
        XCTAssertFalse(updated.status.updatePending)
        XCTAssertTrue(fixture.recorder.operations.contains("plugin.install"))
    }

    func testFailedUpdateKeepsUsingPreviousVerifiedVersion() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.manager.prepareForManagedLaunch(
            runtime: fixture.runtime(),
            hasActiveManagedCodexSession: false
        )
        try fixture.changeBundledPlugin(version: "0.2.1")
        fixture.pluginClient.installError = CodexPluginCLIError.commandFailed(
            "plugin add",
            1,
            "fixture update failure"
        )

        let fallback = try fixture.manager.prepareForManagedLaunch(
            runtime: fixture.runtime(),
            hasActiveManagedCodexSession: false
        )

        XCTAssertEqual(fallback.configuration, first.configuration)
        XCTAssertEqual(fallback.status.availability, .failed)
        XCTAssertTrue(fallback.status.updatePending)
        XCTAssertFalse(fallback.installedOrUpdated)
    }

    func testFailedUpdateLaunchesWithoutSkillsWhenPreviousVersionCannotBeReverified() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.manager.prepareForManagedLaunch(
            runtime: fixture.runtime(),
            hasActiveManagedCodexSession: false
        )
        try fixture.changeBundledPlugin(version: "0.2.1")
        fixture.pluginClient.installErrorAfterMutation = CodexPluginCLIError.commandFailed(
            "plugin add",
            1,
            "fixture post-install failure"
        )

        XCTAssertThrowsError(
            try fixture.manager.prepareForManagedLaunch(
                runtime: fixture.runtime(),
                hasActiveManagedCodexSession: false
            )
        ) { error in
            guard case .rollbackUnverified = error as? CodexSkillsManagerError else {
                return XCTFail("Expected rollbackUnverified, got \(error)")
            }
        }
        XCTAssertNil(fixture.manager.cachedLaunchConfiguration(runtime: fixture.runtime()))
    }

    func testUnprovisionedLaunchDefersInstallWhileAnotherSessionIsActive() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let preparation = try fixture.manager.prepareForManagedLaunch(
            runtime: fixture.runtime(),
            hasActiveManagedCodexSession: true
        )

        XCTAssertNil(preparation.configuration)
        XCTAssertEqual(preparation.status.availability, .notInstalled)
        XCTAssertFalse(fixture.recorder.operations.contains("plugin.install"))
    }

    func testTwoIdenticalFailuresPauseAutomaticRetriesUntilRepair() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.pluginClient.installError = CodexPluginCLIError.commandFailed(
            "plugin add",
            1,
            "fixture failure"
        )

        for _ in 0..<2 {
            XCTAssertThrowsError(
                try fixture.manager.prepareForManagedLaunch(
                    runtime: fixture.runtime(),
                    hasActiveManagedCodexSession: false
                )
            )
        }
        fixture.recorder.reset()

        let paused = try fixture.manager.prepareForManagedLaunch(
            runtime: fixture.runtime(),
            hasActiveManagedCodexSession: false
        )

        XCTAssertNil(paused.configuration)
        XCTAssertEqual(paused.status.availability, .failed)
        XCTAssertTrue(paused.status.detail.contains("Repair"))
        XCTAssertEqual(fixture.recorder.operations, [])

        fixture.pluginClient.installError = nil
        let repaired = try fixture.manager.repair(
            runtime: fixture.runtime(),
            hasActiveManagedCodexSession: false
        )
        XCTAssertEqual(repaired.availability, .ready)
    }

    func testLegacyOwnedSkillIsBackedUpAndModifiedSkillIsPreserved() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let skillsRoot = fixture.runtime().codexHomeURL.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        let owned = skillsRoot.appendingPathComponent("toastty-capabilities", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: owned,
            withDestinationURL: fixture.sourcePluginURL
                .appendingPathComponent("skills/toastty-capabilities", isDirectory: true)
        )
        let modified = skillsRoot.appendingPathComponent("toastty-scratchpad", isDirectory: true)
        try FileManager.default.createDirectory(at: modified, withIntermediateDirectories: true)
        try "---\nname: toastty-scratchpad\ndescription: User modified.\n---\n"
            .write(to: modified.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let preparation = try fixture.manager.prepareForManagedLaunch(
            runtime: fixture.runtime(),
            hasActiveManagedCodexSession: false
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: modified.path))
        XCTAssertEqual(preparation.status.legacySkillConflictPaths, [modified.path])
        let backupRoot = fixture.homeURL.appendingPathComponent(".toastty/legacy-codex-skills-backup")
        let backups = try FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: backups[0].appendingPathComponent("codex-home/toastty-capabilities").path
        ))
    }

    func testUninstallRemovesOnlyOwnedSkillsStateAndLeavesHooksUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let preparation = try fixture.manager.prepareForManagedLaunch(
            runtime: fixture.runtime(),
            hasActiveManagedCodexSession: false
        )
        let hooksURL = fixture.runtime().codexHomeURL.appendingPathComponent("hooks.json")
        let hooksData = Data(#"{"hooks":{"Stop":[{"command":"/usr/bin/true"}]}}"#.utf8)
        try hooksData.write(to: hooksURL)

        let status = try fixture.manager.uninstall(
            runtime: fixture.runtime(),
            hasActiveManagedCodexSession: false
        )

        XCTAssertEqual(status.availability, .notInstalled)
        XCTAssertEqual(try Data(contentsOf: hooksURL), hooksData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparation.status.marketplacePath))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.manager.stateRootURL.appendingPathComponent("versions").path
        ))
        XCTAssertEqual(status.disabledNameTombstones, ["toastty:worktree-done"])
    }

    func testUninstallPreservesInstalledPluginWhoseDigestNoLongerMatchesOwnershipRecord() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let preparation = try fixture.manager.prepareForManagedLaunch(
            runtime: fixture.runtime(),
            hasActiveManagedCodexSession: false
        )
        let installedPath = try XCTUnwrap(preparation.status.installedPath)
        let skillURL = URL(fileURLWithPath: installedPath, isDirectory: true)
            .appendingPathComponent("skills/toastty-capabilities/SKILL.md")
        try "\nUser-modified installed bytes.\n".append(to: skillURL)
        fixture.recorder.reset()

        XCTAssertThrowsError(
            try fixture.manager.uninstall(
                runtime: fixture.runtime(),
                hasActiveManagedCodexSession: false
            )
        ) { error in
            guard case .installedPluginMismatch = error as? CodexSkillsManagerError else {
                return XCTFail("Expected installedPluginMismatch, got \(error)")
            }
        }
        XCTAssertFalse(fixture.recorder.operations.contains("plugin.remove"))
        XCTAssertFalse(fixture.recorder.operations.contains("marketplace.remove"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preparation.status.marketplacePath))
    }

    func testCustomCodexHomesUseIndependentMarketplaceState() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let firstRuntime = fixture.runtime(name: "codex-one")
        let secondRuntime = fixture.runtime(name: "codex-two")

        let first = try fixture.manager.prepareForManagedLaunch(
            runtime: firstRuntime,
            hasActiveManagedCodexSession: false
        )
        let second = try fixture.manager.prepareForManagedLaunch(
            runtime: secondRuntime,
            hasActiveManagedCodexSession: false
        )

        XCTAssertNotEqual(first.status.marketplacePath, second.status.marketplacePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.status.marketplacePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.status.marketplacePath))
    }

    func testForeignMarketplaceDirectoryIsPreserved() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let marketplaceURL = URL(
            fileURLWithPath: fixture.manager.status(
                runtime: fixture.runtime(),
                hasActiveManagedCodexSession: false
            ).marketplacePath,
            isDirectory: true
        )
        let marker = marketplaceURL.appendingPathComponent("foreign.txt")
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "preserve me".write(to: marker, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try fixture.manager.prepareForManagedLaunch(
                runtime: fixture.runtime(),
                hasActiveManagedCodexSession: false
            )
        ) { error in
            XCTAssertEqual(
                error as? CodexSkillsManagerError,
                .ownedStateMismatch(marketplaceURL.path)
            )
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "preserve me")
        XCTAssertFalse(fixture.recorder.operations.contains("marketplace.add"))
    }

    func testForeignRegisteredMarketplaceIsRejectedBeforeSkillConfigChanges() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let foreignPath = fixture.rootURL.appendingPathComponent("foreign-marketplace").path
        fixture.pluginClient.setMarketplaceRoot(
            foreignPath,
            runtime: fixture.runtime()
        )

        XCTAssertThrowsError(
            try fixture.manager.prepareForManagedLaunch(
                runtime: fixture.runtime(),
                hasActiveManagedCodexSession: false
            )
        ) { error in
            XCTAssertEqual(
                error as? CodexSkillsManagerError,
                .marketplaceConflict(foreignPath)
            )
        }
        XCTAssertEqual(fixture.skillClient.states(for: fixture.runtime()), [:])
        XCTAssertEqual(fixture.recorder.operations, ["marketplace.list"])
    }

    func testForeignPluginNamedToasttyIsRejectedBeforeSkillConfigChanges() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.pluginClient.setForeignToasttyPlugin(
            CodexInstalledPlugin(
                pluginID: "toastty@third-party",
                name: "toastty",
                marketplaceName: "third-party",
                version: "9.9.9",
                sourcePath: "/tmp/foreign-toastty",
                marketplaceSourcePath: "/tmp/foreign-marketplace"
            ),
            runtime: fixture.runtime()
        )

        XCTAssertThrowsError(
            try fixture.manager.prepareForManagedLaunch(
                runtime: fixture.runtime(),
                hasActiveManagedCodexSession: false
            )
        ) { error in
            XCTAssertEqual(
                error as? CodexSkillsManagerError,
                .pluginConflict("toastty@third-party")
            )
        }
        XCTAssertEqual(fixture.skillClient.states(for: fixture.runtime()), [:])
        XCTAssertEqual(fixture.recorder.operations, ["marketplace.list", "plugin.list"])
    }

    func testRepairAndUninstallPreserveMarketplaceWhoseOwnedLayoutWasReplaced() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let installed = try fixture.manager.prepareForManagedLaunch(
            runtime: fixture.runtime(),
            hasActiveManagedCodexSession: false
        )
        let marketplaceURL = URL(
            fileURLWithPath: installed.status.marketplacePath,
            isDirectory: true
        )
        let manifest = marketplaceURL
            .appendingPathComponent(".agents/plugins/marketplace.json")
        let foreignData = Data(#"{"name":"foreign"}"#.utf8)
        try foreignData.write(to: manifest, options: .atomic)
        try fixture.changeBundledPlugin(version: "0.2.1")

        XCTAssertThrowsError(
            try fixture.manager.prepareForManagedLaunch(
                runtime: fixture.runtime(),
                hasActiveManagedCodexSession: false
            )
        )
        XCTAssertEqual(try Data(contentsOf: manifest), foreignData)
        fixture.recorder.reset()
        XCTAssertThrowsError(
            try fixture.manager.uninstall(
                runtime: fixture.runtime(),
                hasActiveManagedCodexSession: false
            )
        ) { error in
            XCTAssertEqual(
                error as? CodexSkillsManagerError,
                .ownedStateMismatch(marketplaceURL.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: manifest), foreignData)
        XCTAssertFalse(fixture.recorder.operations.contains("plugin.remove"))
        XCTAssertFalse(fixture.recorder.operations.contains("marketplace.remove"))
    }

    func testSkillsManagerHasNoHookOrReconciliationDependency() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/App/Agents/CodexSkillsManager.swift"),
            encoding: .utf8
        )

        for forbidden in [
            "CodexStatusHookInstaller",
            "hooks.json",
            "hooks/list",
            "CodexReconciliation",
            "CodexStatusTrackingSource",
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }
}

private extension CodexSkillsManagerTests {
    final class Fixture {
        let rootURL: URL
        let homeURL: URL
        let sourceMarketplaceURL: URL
        let sourcePluginURL: URL
        let recorder = OperationRecorder()
        let pluginClient: FakeCodexPluginClient
        let skillClient: FakeCodexSkillClient
        let manager: CodexSkillsManager

        init() throws {
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("toastty-codex-skills-manager-\(UUID().uuidString)", isDirectory: true)
            homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
            sourceMarketplaceURL = rootURL.appendingPathComponent("source", isDirectory: true)
            sourcePluginURL = sourceMarketplaceURL.appendingPathComponent("plugins/toastty", isDirectory: true)
            try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)

            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: sourcePluginURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(
                at: repositoryRoot.appendingPathComponent("plugins/toastty", isDirectory: true),
                to: sourcePluginURL
            )
            let marketplaceManifestURL = sourceMarketplaceURL
                .appendingPathComponent(".agents/plugins/marketplace.json")
            try FileManager.default.createDirectory(
                at: marketplaceManifestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(
                at: repositoryRoot.appendingPathComponent(".agents/plugins/marketplace.json"),
                to: marketplaceManifestURL
            )

            pluginClient = FakeCodexPluginClient(recorder: recorder)
            skillClient = FakeCodexSkillClient(recorder: recorder, pluginClient: pluginClient)
            manager = CodexSkillsManager(
                homeDirectoryURL: homeURL,
                sourcePluginURLProvider: { [sourcePluginURL] in sourcePluginURL },
                sourceMarketplaceURLProvider: { [sourceMarketplaceURL] in sourceMarketplaceURL },
                pluginClient: pluginClient,
                skillClient: skillClient,
                nowProvider: { Date(timeIntervalSince1970: 1_700_000_000) }
            )
        }

        var expectedQualifiedNames: [String] {
            ToasttyAgentPluginBundle.skills.map { "toastty:\($0.name)" }
        }

        func runtime(name: String = "codex-home") -> CodexIntegrationRuntime {
            CodexIntegrationRuntime(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                codexHomeURL: rootURL.appendingPathComponent(name, isDirectory: true),
                workingDirectoryURL: rootURL
            )
        }

        func changeBundledPlugin(version: String) throws {
            for relativePath in [
                ".codex-plugin/plugin.json",
                ".claude-plugin/plugin.json",
            ] {
                let url = sourcePluginURL.appendingPathComponent(relativePath)
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
                )
                object["version"] = version
                try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                    .write(to: url, options: .atomic)
            }
            let skillURL = sourcePluginURL
                .appendingPathComponent("skills/toastty-capabilities/SKILL.md")
            var contents = try String(contentsOf: skillURL, encoding: .utf8)
            contents += "\nUpdated fixture content.\n"
            try contents.write(to: skillURL, atomically: true, encoding: .utf8)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }
}

private final class OperationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var operations: [String] {
        lock.withLock { storage }
    }

    func append(_ operation: String) {
        lock.withLock { storage.append(operation) }
    }

    func reset() {
        lock.withLock { storage.removeAll() }
    }
}

private final class FakeCodexPluginClient: CodexPluginCLIManaging, @unchecked Sendable {
    private let recorder: OperationRecorder
    private let lock = NSLock()
    private var marketplaceRoots: [String: String] = [:]
    private var installedPaths: [String: String] = [:]
    private var foreignToasttyPlugins: [String: CodexInstalledPlugin] = [:]
    var installError: Error?
    var installErrorAfterMutation: Error?

    init(recorder: OperationRecorder) {
        self.recorder = recorder
    }

    func listMarketplaces(runtime: CodexIntegrationRuntime, deadline: Date) throws -> [CodexPluginMarketplace] {
        recorder.append("marketplace.list")
        return lock.withLock {
            guard let root = marketplaceRoots[key(runtime)] else { return [] }
            return [CodexPluginMarketplace(name: "toastty", rootPath: root, sourcePath: root)]
        }
    }

    func listInstalledPlugins(runtime: CodexIntegrationRuntime, deadline: Date) throws -> [CodexInstalledPlugin] {
        recorder.append("plugin.list")
        return try lock.withLock {
            var plugins = foreignToasttyPlugins[key(runtime)].map { [$0] } ?? []
            guard let path = installedPaths[key(runtime)] else { return plugins }
            let descriptor = try ToasttyAgentPluginBundle.read(
                pluginRootURL: URL(fileURLWithPath: path)
            )
            plugins.append(
                CodexInstalledPlugin(
                    pluginID: "toastty@toastty",
                    name: "toastty",
                    marketplaceName: "toastty",
                    version: descriptor.version,
                    sourcePath: path,
                    marketplaceSourcePath: marketplaceRoots[key(runtime)]
                )
            )
            return plugins
        }
    }

    func addMarketplace(
        runtime: CodexIntegrationRuntime,
        sourcePath: String,
        deadline: Date
    ) throws -> String {
        recorder.append("marketplace.add")
        lock.withLock { marketplaceRoots[key(runtime)] = sourcePath }
        return "toastty"
    }

    func installPlugin(
        runtime: CodexIntegrationRuntime,
        selector: String,
        deadline: Date
    ) throws -> CodexPluginInstallation {
        recorder.append("plugin.install")
        if let installError { throw installError }
        let marketplaceRoot = try lock.withLock {
            try XCTUnwrap(marketplaceRoots[key(runtime)])
        }
        let source = URL(fileURLWithPath: marketplaceRoot, isDirectory: true)
            .appendingPathComponent("plugins/toastty", isDirectory: true)
            .resolvingSymlinksInPath()
        let destination = runtime.codexHomeURL
            .appendingPathComponent("plugins/cache/toastty/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
        let descriptor = try ToasttyAgentPluginBundle.read(pluginRootURL: destination)
        lock.withLock { installedPaths[key(runtime)] = destination.path }
        if let installErrorAfterMutation { throw installErrorAfterMutation }
        return CodexPluginInstallation(
            pluginID: selector,
            name: "toastty",
            marketplaceName: "toastty",
            version: descriptor.version,
            installedPath: destination.path
        )
    }

    func removePlugin(
        runtime: CodexIntegrationRuntime,
        selector: String,
        deadline: Date
    ) throws {
        recorder.append("plugin.remove")
        _ = lock.withLock { installedPaths.removeValue(forKey: key(runtime)) }
    }

    func removeMarketplace(
        runtime: CodexIntegrationRuntime,
        name: String,
        deadline: Date
    ) throws {
        recorder.append("marketplace.remove")
        _ = lock.withLock { marketplaceRoots.removeValue(forKey: key(runtime)) }
    }

    func installedDescriptor(runtime: CodexIntegrationRuntime) throws -> ToasttyAgentPluginDescriptor? {
        try lock.withLock {
            guard let path = installedPaths[key(runtime)] else { return nil }
            return try ToasttyAgentPluginBundle.read(pluginRootURL: URL(fileURLWithPath: path))
        }
    }

    func setMarketplaceRoot(_ root: String, runtime: CodexIntegrationRuntime) {
        lock.withLock { marketplaceRoots[key(runtime)] = root }
    }

    func setForeignToasttyPlugin(
        _ plugin: CodexInstalledPlugin,
        runtime: CodexIntegrationRuntime
    ) {
        lock.withLock { foreignToasttyPlugins[key(runtime)] = plugin }
    }

    private func key(_ runtime: CodexIntegrationRuntime) -> String {
        runtime.codexHomeURL.path
    }

}

private final class FakeCodexSkillClient: CodexSkillsConfiguring, @unchecked Sendable {
    private let recorder: OperationRecorder
    private let pluginClient: FakeCodexPluginClient
    private let lock = NSLock()
    private var storedStates: [String: [String: Bool]] = [:]

    init(recorder: OperationRecorder, pluginClient: FakeCodexPluginClient) {
        self.recorder = recorder
        self.pluginClient = pluginClient
    }

    func writeSkillConfigs(
        invocation: CodexAppServerInvocation,
        states: [CodexSkillState]
    ) throws {
        recorder.append("skills.write")
        lock.withLock {
            var values = storedStates[invocation.codexHomeURL.path] ?? [:]
            for state in states {
                values[state.name] = state.enabled
            }
            storedStates[invocation.codexHomeURL.path] = values
        }
    }

    func listSkills(invocation: CodexAppServerInvocation) throws -> [CodexSkillState] {
        recorder.append("skills.list")
        let runtime = CodexIntegrationRuntime(
            executableURL: invocation.executableURL,
            codexHomeURL: invocation.codexHomeURL,
            workingDirectoryURL: invocation.workingDirectoryURL
        )
        guard let descriptor = try pluginClient.installedDescriptor(runtime: runtime) else { return [] }
        let values = lock.withLock { storedStates[invocation.codexHomeURL.path] ?? [:] }
        return descriptor.qualifiedSkillNames.map {
            CodexSkillState(name: $0, enabled: values[$0] ?? true)
        }
    }

    func states(for runtime: CodexIntegrationRuntime) -> [String: Bool] {
        lock.withLock { storedStates[runtime.codexHomeURL.path] ?? [:] }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}

private extension String {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(utf8))
    }
}
