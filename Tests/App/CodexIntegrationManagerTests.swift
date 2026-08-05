import CoreState
import CryptoKit
import Foundation
import XCTest
@testable import ToasttyApp

final class CodexSkillsManagerTests: XCTestCase {
    func testFirstLaunchPopulatesCacheProfileAndReceiptThroughThrowawayHome() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runtime = fixture.runtime()

        let preparation = try fixture.manager.prepareForManagedLaunch(runtime: runtime)

        let configuration = try XCTUnwrap(preparation.configuration)
        XCTAssertEqual(configuration.profileName, "toastty-managed")
        XCTAssertEqual(configuration.codexHomePath, runtime.codexHomeURL.path)
        XCTAssertEqual(preparation.status.availability, .ready)
        XCTAssertTrue(preparation.installedOrUpdated)
        XCTAssertTrue(preparation.firstInstallSucceeded)
        XCTAssertEqual(fixture.recorder.operations, ["marketplace.add", "plugin.install"])

        // Population never runs against the real Codex home.
        let populationHome = try XCTUnwrap(fixture.pluginClient.recordedPopulationHomes.first)
        XCTAssertNotEqual(populationHome, runtime.codexHomeURL.path)

        // Single-version cache subtree in the real home carries the skills.
        let versionDirectories = try fixture.cacheVersionDirectories(runtime: runtime)
        XCTAssertEqual(versionDirectories.count, 1)
        XCTAssertEqual(
            configuration.skillsRootPath,
            versionDirectories[0].appendingPathComponent("skills")
                .standardizedFileURL.resolvingSymlinksInPath().path
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: versionDirectories[0]
                    .appendingPathComponent("skills/toastty-capabilities/SKILL.md").path
            )
        )

        // Ownership-marked profile overlay and receipt sidecar exist.
        let profileContents = try String(
            contentsOf: fixture.profileConfigURL(runtime: runtime),
            encoding: .utf8
        )
        XCTAssertEqual(profileContents, CodexManagedProfileConfig.fileContents)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.receiptURL(runtime: runtime).path))

        // The user's config.toml is never created or written.
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: runtime.codexHomeURL.appendingPathComponent("config.toml").path
            )
        )
    }

    func testVerifiedSecondLaunchPerformsNoCLIOrWriteWork() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.manager.prepareForManagedLaunch(runtime: fixture.runtime())
        fixture.recorder.reset()

        let preparation = try fixture.manager.prepareForManagedLaunch(runtime: fixture.runtime())

        XCTAssertNotNil(preparation.configuration)
        XCTAssertFalse(preparation.installedOrUpdated)
        XCTAssertEqual(fixture.recorder.operations, [])
    }

    func testUpdateIsAppliedImmediatelyAndKeepsSingleVersionCache() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.manager.prepareForManagedLaunch(runtime: fixture.runtime())
        try fixture.changeBundledPlugin(version: "0.2.1")
        fixture.recorder.reset()

        let updated = try fixture.manager.prepareForManagedLaunch(runtime: fixture.runtime())

        XCTAssertNotEqual(updated.configuration?.contentDigest, first.configuration?.contentDigest)
        XCTAssertEqual(updated.configuration?.version, "0.2.1")
        XCTAssertFalse(updated.status.updatePending)
        XCTAssertTrue(fixture.recorder.operations.contains("plugin.install"))
        let versionDirectories = try fixture.cacheVersionDirectories(runtime: fixture.runtime())
        XCTAssertEqual(versionDirectories.map(\.lastPathComponent), ["0.2.1"])
    }

    func testRestoredLaunchAfterAppRestartReusesCurrentInstallWithoutSubprocessWork() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.manager.prepareForManagedLaunch(runtime: fixture.runtime())
        fixture.recorder.reset()
        let restartedManager = fixture.makeRestartedManager()

        let restored = try restartedManager.prepareForRestoredManagedLaunch(runtime: fixture.runtime())

        XCTAssertEqual(restored.configuration, first.configuration)
        XCTAssertEqual(fixture.recorder.operations, [])
    }

    func testRestoredLaunchAfterAppRestartUpdatesBeforeResume() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.manager.prepareForManagedLaunch(runtime: fixture.runtime())
        try fixture.changeBundledPlugin(version: "0.2.1")
        fixture.recorder.reset()
        let restartedManager = fixture.makeRestartedManager()

        let updated = try restartedManager.prepareForRestoredManagedLaunch(runtime: fixture.runtime())

        XCTAssertNotEqual(updated.configuration?.contentDigest, first.configuration?.contentDigest)
        XCTAssertEqual(updated.configuration?.version, "0.2.1")
        XCTAssertTrue(fixture.recorder.operations.contains("plugin.install"))
    }

    func testRestoredLaunchDoesNotReuseStaleCacheAfterInstalledFilesChange() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.manager.prepareForManagedLaunch(runtime: fixture.runtime())
        let cachePath = try XCTUnwrap(first.status.cachePath)
        let skillURL = URL(fileURLWithPath: cachePath, isDirectory: true)
            .appendingPathComponent("skills/toastty-capabilities/SKILL.md")
        try "\nCorrupted after verification.\n".append(to: skillURL)
        fixture.recorder.reset()

        let restored = try fixture.manager.prepareForRestoredManagedLaunch(runtime: fixture.runtime())

        XCTAssertEqual(restored.configuration?.contentDigest, first.configuration?.contentDigest)
        XCTAssertTrue(fixture.recorder.operations.contains("plugin.install"))
    }

    func testStaleExtraCacheVersionTriggersRepopulation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.manager.prepareForManagedLaunch(runtime: fixture.runtime())
        let junk = fixture.cacheRootURL(runtime: fixture.runtime())
            .appendingPathComponent("9.9.9", isDirectory: true)
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        fixture.recorder.reset()

        let preparation = try fixture.manager.prepareForRestoredManagedLaunch(runtime: fixture.runtime())

        XCTAssertNotNil(preparation.configuration)
        XCTAssertTrue(fixture.recorder.operations.contains("plugin.install"))
        let versionDirectories = try fixture.cacheVersionDirectories(runtime: fixture.runtime())
        XCTAssertEqual(versionDirectories.count, 1)
        XCTAssertNotEqual(versionDirectories[0].lastPathComponent, "9.9.9")
    }

    func testFailedUpdateKeepsUsingPreviousVerifiedVersion() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.manager.prepareForManagedLaunch(runtime: fixture.runtime())
        try fixture.changeBundledPlugin(version: "0.2.1")
        fixture.pluginClient.installError = CodexPluginCLIError.commandFailed(
            "plugin add",
            1,
            "fixture update failure"
        )

        let fallback = try fixture.manager.prepareForManagedLaunch(runtime: fixture.runtime())

        XCTAssertEqual(fallback.configuration, first.configuration)
        XCTAssertEqual(fallback.status.availability, .failed)
        XCTAssertTrue(fallback.status.updatePending)
        XCTAssertFalse(fallback.installedOrUpdated)
    }

    func testFailedUpdateThrowsWhenPreviousCacheIsNotVerifiable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.manager.prepareForManagedLaunch(runtime: fixture.runtime())
        try fixture.changeBundledPlugin(version: "0.2.1")
        let cachePath = try XCTUnwrap(first.status.cachePath)
        try "\nUser-modified installed bytes.\n".append(
            to: URL(fileURLWithPath: cachePath, isDirectory: true)
                .appendingPathComponent("skills/toastty-capabilities/SKILL.md")
        )
        fixture.pluginClient.installError = CodexPluginCLIError.commandFailed(
            "plugin add",
            1,
            "fixture failure"
        )

        XCTAssertThrowsError(
            try fixture.manager.prepareForManagedLaunch(runtime: fixture.runtime())
        )
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
                try fixture.manager.prepareForManagedLaunch(runtime: fixture.runtime())
            )
        }
        fixture.recorder.reset()

        let paused = try fixture.manager.prepareForManagedLaunch(runtime: fixture.runtime())

        XCTAssertNil(paused.configuration)
        XCTAssertEqual(paused.status.availability, .failed)
        XCTAssertTrue(paused.status.detail.contains("Repair"))
        XCTAssertEqual(fixture.recorder.operations, [])

        fixture.pluginClient.installError = nil
        let repaired = try fixture.manager.repair(runtime: fixture.runtime())
        XCTAssertEqual(repaired.availability, .ready)
    }

    func testPausedAutomaticUpdateDoesNotReturnCachedPreviousConfiguration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.manager.prepareForManagedLaunch(runtime: fixture.runtime())
        try fixture.changeBundledPlugin(version: "0.2.1")
        fixture.pluginClient.installError = CodexPluginCLIError.commandFailed(
            "plugin add",
            1,
            "fixture update failure"
        )
        _ = try fixture.manager.prepareForManagedLaunch(runtime: fixture.runtime())
        _ = try fixture.manager.prepareForManagedLaunch(runtime: fixture.runtime())
        fixture.recorder.reset()

        let paused = try fixture.manager.prepareForManagedLaunch(runtime: fixture.runtime())

        XCTAssertNil(paused.configuration)
        XCTAssertEqual(paused.status.availability, .failed)
        XCTAssertEqual(fixture.recorder.operations, [])
    }

    func testForeignProfileConfigIsPreservedAndDeliversNoSkills() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runtime = fixture.runtime()
        let profileURL = fixture.profileConfigURL(runtime: runtime)
        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let foreignContents = "# user-owned overlay\nmodel = \"gpt-5\"\n"
        try foreignContents.write(to: profileURL, atomically: true, encoding: .utf8)

        let preparation = try fixture.manager.prepareForManagedLaunch(runtime: runtime)

        XCTAssertNil(preparation.configuration)
        XCTAssertEqual(preparation.status.availability, .failed)
        XCTAssertTrue(preparation.status.detail.contains(profileURL.path))
        XCTAssertEqual(try String(contentsOf: profileURL, encoding: .utf8), foreignContents)
        // The conflict is detected before any subprocess or cache work.
        XCTAssertEqual(fixture.recorder.operations, [])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.cacheRootURL(runtime: runtime).path)
        )
    }

    func testForeignProfileConfigOnVerifiedInstallDeliversNoSkills() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runtime = fixture.runtime()
        _ = try fixture.manager.prepareForManagedLaunch(runtime: runtime)
        let profileURL = fixture.profileConfigURL(runtime: runtime)
        let foreignContents = "# user-owned overlay\n"
        try foreignContents.write(to: profileURL, atomically: true, encoding: .utf8)
        fixture.recorder.reset()

        let preparation = try fixture.manager.prepareForManagedLaunch(runtime: runtime)

        XCTAssertNil(preparation.configuration)
        XCTAssertEqual(preparation.status.availability, .failed)
        XCTAssertEqual(try String(contentsOf: profileURL, encoding: .utf8), foreignContents)
        XCTAssertEqual(fixture.recorder.operations, [])
    }

    func testMissingProfileConfigIsRestoredWithoutSubprocessWork() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runtime = fixture.runtime()
        _ = try fixture.manager.prepareForManagedLaunch(runtime: runtime)
        let profileURL = fixture.profileConfigURL(runtime: runtime)
        try FileManager.default.removeItem(at: profileURL)
        fixture.recorder.reset()

        let preparation = try fixture.manager.prepareForManagedLaunch(runtime: runtime)

        XCTAssertNotNil(preparation.configuration)
        XCTAssertEqual(fixture.recorder.operations, [])
        XCTAssertEqual(
            try String(contentsOf: profileURL, encoding: .utf8),
            CodexManagedProfileConfig.fileContents
        )
    }

    func testDriftedOwnedProfileConfigIsRewritten() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runtime = fixture.runtime()
        _ = try fixture.manager.prepareForManagedLaunch(runtime: runtime)
        let profileURL = fixture.profileConfigURL(runtime: runtime)
        try "\(CodexManagedProfileConfig.ownershipMarker)\n# drifted\n"
            .write(to: profileURL, atomically: true, encoding: .utf8)
        fixture.recorder.reset()

        let preparation = try fixture.manager.prepareForManagedLaunch(runtime: runtime)

        XCTAssertNotNil(preparation.configuration)
        XCTAssertEqual(fixture.recorder.operations, [])
        XCTAssertEqual(
            try String(contentsOf: profileURL, encoding: .utf8),
            CodexManagedProfileConfig.fileContents
        )
    }

    func testLegacyStateTriggersOneShotCleanupBeforeInstall() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runtime = fixture.defaultHomeRuntime()
        let legacyMarketplaceURL = fixture.legacyStableMarketplaceURL
        try fixture.installLegacyState(
            runtime: runtime,
            marketplacePath: legacyMarketplaceURL.path
        )
        fixture.pluginClient.registerLegacyMarketplace(
            CodexPluginMarketplace(
                name: "toastty",
                rootPath: legacyMarketplaceURL.path,
                sourcePath: legacyMarketplaceURL.path
            ),
            runtime: runtime
        )
        fixture.pluginClient.registerLegacyPlugin(
            CodexInstalledPlugin(
                pluginID: "toastty@toastty",
                name: "toastty",
                marketplaceName: "toastty",
                version: "0.2.0",
                sourcePath: legacyMarketplaceURL.path,
                marketplaceSourcePath: legacyMarketplaceURL.path
            ),
            runtime: runtime
        )

        let preparation = try fixture.manager.prepareForManagedLaunch(runtime: runtime)

        XCTAssertNotNil(preparation.configuration)
        XCTAssertEqual(
            fixture.recorder.operations,
            [
                "marketplace.list",
                "plugin.list",
                "plugin.remove",
                "marketplace.remove",
                "marketplace.add",
                "plugin.install",
            ]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyMarketplaceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyStateURL(runtime: runtime).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyVersionsRootURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.receiptURL(runtime: runtime).path))
    }

    func testLegacyCleanupPreservesForeignToasttyMarketplaceRegistration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runtime = fixture.defaultHomeRuntime()
        try fixture.installLegacyState(
            runtime: runtime,
            marketplacePath: fixture.legacyStableMarketplaceURL.path
        )
        let foreignPath = fixture.rootURL.appendingPathComponent("foreign-marketplace").path
        fixture.pluginClient.registerLegacyMarketplace(
            CodexPluginMarketplace(
                name: "toastty",
                rootPath: foreignPath,
                sourcePath: foreignPath
            ),
            runtime: runtime
        )

        let preparation = try fixture.manager.prepareForManagedLaunch(runtime: runtime)

        XCTAssertNotNil(preparation.configuration)
        XCTAssertFalse(fixture.recorder.operations.contains("plugin.remove"))
        XCTAssertFalse(fixture.recorder.operations.contains("marketplace.remove"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyStateURL(runtime: runtime).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyStableMarketplaceURL.path))
    }

    func testCachedConfigurationIsNotServedAfterOnDiskStateRemoval() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runtime = fixture.runtime()
        _ = try fixture.manager.prepareForManagedLaunch(runtime: runtime)
        XCTAssertNotNil(fixture.manager.cachedLaunchConfiguration(runtime: runtime))

        // Simulate another manager instance uninstalling behind this one.
        try FileManager.default.removeItem(at: fixture.cacheRootURL(runtime: runtime))

        XCTAssertNil(fixture.manager.cachedLaunchConfiguration(runtime: runtime))
    }

    func testLegacyCleanupIsDeferredWhenCodexCLICannotRun() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runtime = fixture.defaultHomeRuntime()
        try fixture.installLegacyState(
            runtime: runtime,
            marketplacePath: fixture.legacyStableMarketplaceURL.path
        )
        fixture.pluginClient.listMarketplacesError = CodexPluginCLIError.commandFailed(
            "plugin marketplace list",
            127,
            "no such file or directory"
        )

        let preparation = try fixture.manager.prepareForManagedLaunch(runtime: runtime)

        // Provisioning still makes forward progress with the new mechanism.
        XCTAssertNotNil(preparation.configuration)
        XCTAssertEqual(preparation.status.availability, .ready)
        // All legacy state survives so a later launch with a working CLI can
        // retry the deregistration.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.legacyStateURL(runtime: runtime).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.legacyStableMarketplaceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.legacyVersionsRootURL.path))
        XCTAssertEqual(
            fixture.recorder.operations,
            ["marketplace.list", "marketplace.add", "plugin.install"]
        )
    }

    func testCorruptLegacyStateStillDeregistersDefaultMarketplaceIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runtime = fixture.defaultHomeRuntime()
        try fixture.installCorruptLegacyState(runtime: runtime)
        fixture.pluginClient.registerLegacyMarketplace(
            CodexPluginMarketplace(
                name: "toastty",
                rootPath: fixture.legacyStableMarketplaceURL.path,
                sourcePath: fixture.legacyStableMarketplaceURL.path
            ),
            runtime: runtime
        )
        fixture.pluginClient.registerLegacyPlugin(
            CodexInstalledPlugin(
                pluginID: "toastty@toastty",
                name: "toastty",
                marketplaceName: "toastty",
                version: "0.2.0",
                sourcePath: fixture.legacyStableMarketplaceURL.path,
                marketplaceSourcePath: fixture.legacyStableMarketplaceURL.path
            ),
            runtime: runtime
        )

        let preparation = try fixture.manager.prepareForManagedLaunch(runtime: runtime)

        XCTAssertNotNil(preparation.configuration)
        XCTAssertEqual(
            fixture.recorder.operations,
            [
                "marketplace.list",
                "plugin.list",
                "plugin.remove",
                "marketplace.remove",
                "marketplace.add",
                "plugin.install",
            ]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyStateURL(runtime: runtime).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyStableMarketplaceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyVersionsRootURL.path))
    }

    func testGlobalSkillsAreNeverModified() throws {
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

        _ = try fixture.manager.prepareForManagedLaunch(runtime: fixture.runtime())

        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: modified.path))
    }

    func testUninstallRemovesOnlyOwnedStateAndLeavesHooksUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runtime = fixture.runtime()
        _ = try fixture.manager.prepareForManagedLaunch(runtime: runtime)
        let hooksURL = runtime.codexHomeURL.appendingPathComponent("hooks.json")
        let hooksData = Data(#"{"hooks":{"Stop":[{"command":"/usr/bin/true"}]}}"#.utf8)
        try hooksData.write(to: hooksURL)
        fixture.recorder.reset()

        let status = try fixture.manager.uninstall(
            runtime: runtime,
            hasActiveManagedCodexSession: false
        )

        XCTAssertEqual(status.availability, .notInstalled)
        XCTAssertEqual(try Data(contentsOf: hooksURL), hooksData)
        // Filesystem-only removal: no Codex subprocesses run.
        XCTAssertEqual(fixture.recorder.operations, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheRootURL(runtime: runtime).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.profileConfigURL(runtime: runtime).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receiptURL(runtime: runtime).path))
    }

    func testUninstallLeavesForeignProfileFileInPlace() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runtime = fixture.runtime()
        _ = try fixture.manager.prepareForManagedLaunch(runtime: runtime)
        let profileURL = fixture.profileConfigURL(runtime: runtime)
        let foreignContents = "# user-owned overlay\n"
        try foreignContents.write(to: profileURL, atomically: true, encoding: .utf8)

        _ = try fixture.manager.uninstall(
            runtime: runtime,
            hasActiveManagedCodexSession: false
        )

        XCTAssertEqual(try String(contentsOf: profileURL, encoding: .utf8), foreignContents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheRootURL(runtime: runtime).path))
    }

    func testUninstallRejectsActiveManagedCodexSession() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runtime = fixture.runtime()
        _ = try fixture.manager.prepareForManagedLaunch(runtime: runtime)
        fixture.recorder.reset()

        XCTAssertThrowsError(
            try fixture.manager.uninstall(
                runtime: runtime,
                hasActiveManagedCodexSession: true
            )
        ) { error in
            XCTAssertEqual(error as? CodexSkillsManagerError, .activeSessions)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.cacheRootURL(runtime: runtime).path))
    }

    func testUninstallPreservesUserModifiedCacheBytes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runtime = fixture.runtime()
        let preparation = try fixture.manager.prepareForManagedLaunch(runtime: runtime)
        let cachePath = try XCTUnwrap(preparation.status.cachePath)
        try "\nUser-modified installed bytes.\n".append(
            to: URL(fileURLWithPath: cachePath, isDirectory: true)
                .appendingPathComponent("skills/toastty-capabilities/SKILL.md")
        )

        XCTAssertThrowsError(
            try fixture.manager.uninstall(
                runtime: runtime,
                hasActiveManagedCodexSession: false
            )
        ) { error in
            guard case .installedPluginMismatch = error as? CodexSkillsManagerError else {
                return XCTFail("Expected installedPluginMismatch, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.profileConfigURL(runtime: runtime).path))
    }

    func testCustomCodexHomesUseIndependentState() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let firstRuntime = fixture.runtime(name: "codex-one")
        let secondRuntime = fixture.runtime(name: "codex-two")

        let first = try fixture.manager.prepareForManagedLaunch(runtime: firstRuntime)
        let second = try fixture.manager.prepareForManagedLaunch(runtime: secondRuntime)

        XCTAssertNotEqual(first.status.cachePath, second.status.cachePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.cacheRootURL(runtime: firstRuntime).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.cacheRootURL(runtime: secondRuntime).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.profileConfigURL(runtime: firstRuntime).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.profileConfigURL(runtime: secondRuntime).path))
    }

    func testRuntimeIsolatedManagerKeepsToasttyStateUnderIsolatedRootOnly() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let isolatedHomeURL = fixture.rootURL.appendingPathComponent("runtime-home", isDirectory: true)
        let realHomeURL = fixture.rootURL.appendingPathComponent("real-home", isDirectory: true)
        try FileManager.default.createDirectory(at: realHomeURL, withIntermediateDirectories: true)
        let manager = CodexSkillsManager(
            runtimePaths: .resolve(
                homeDirectoryPath: realHomeURL.path,
                environment: ["TOASTTY_RUNTIME_HOME": isolatedHomeURL.path]
            ),
            homeDirectoryURL: realHomeURL,
            sourcePluginURLProvider: { [sourcePluginURL = fixture.sourcePluginURL] in sourcePluginURL },
            sourceMarketplaceURLProvider: { [sourceMarketplaceURL = fixture.sourceMarketplaceURL] in
                sourceMarketplaceURL
            },
            pluginClient: fixture.pluginClient
        )
        let runtime = fixture.runtime(name: "isolated-codex-home")

        let preparation = try manager.prepareForManagedLaunch(runtime: runtime)

        XCTAssertNotNil(preparation.configuration)
        // The receipt sidecar lands under the isolated runtime home.
        let isolatedStateRootURL = isolatedHomeURL
            .appendingPathComponent("agent-plugins/codex", isDirectory: true)
        XCTAssertEqual(manager.stateRootURL.path, isolatedStateRootURL.path)
        let homeDirectories = try FileManager.default.contentsOfDirectory(
            at: isolatedStateRootURL.appendingPathComponent("homes", isDirectory: true),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        XCTAssertEqual(homeDirectories.count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: homeDirectories[0].appendingPathComponent("receipt.json").path
            )
        )
        // Nothing is ever written into the real home's .toastty.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: realHomeURL.appendingPathComponent(".toastty").path)
        )
    }

    func testSkillsManagerHasNoHookAppServerOrReconciliationDependency() throws {
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
            "CodexAppServer",
            "skills/config",
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
            manager = CodexSkillsManager(
                runtimePaths: .resolve(homeDirectoryPath: homeURL.path, environment: [:]),
                homeDirectoryURL: homeURL,
                sourcePluginURLProvider: { [sourcePluginURL] in sourcePluginURL },
                sourceMarketplaceURLProvider: { [sourceMarketplaceURL] in sourceMarketplaceURL },
                pluginClient: pluginClient
            )
        }

        func makeRestartedManager() -> CodexSkillsManager {
            CodexSkillsManager(
                runtimePaths: .resolve(homeDirectoryPath: homeURL.path, environment: [:]),
                homeDirectoryURL: homeURL,
                sourcePluginURLProvider: { [sourcePluginURL] in sourcePluginURL },
                sourceMarketplaceURLProvider: { [sourceMarketplaceURL] in sourceMarketplaceURL },
                pluginClient: pluginClient
            )
        }

        func runtime(name: String = "codex-home") -> CodexIntegrationRuntime {
            CodexIntegrationRuntime(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                codexHomeURL: rootURL.appendingPathComponent(name, isDirectory: true),
                workingDirectoryURL: rootURL
            )
        }

        /// Runtime whose `CODEX_HOME` is the default `<home>/.codex`, the only
        /// layout that used the legacy `~/.toastty/codex-plugin` staging.
        func defaultHomeRuntime() -> CodexIntegrationRuntime {
            CodexIntegrationRuntime(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                codexHomeURL: homeURL.appendingPathComponent(".codex", isDirectory: true),
                workingDirectoryURL: rootURL
            )
        }

        var stateRootURL: URL {
            homeURL.appendingPathComponent(".toastty/agent-plugins/codex", isDirectory: true)
        }

        var legacyStableMarketplaceURL: URL {
            homeURL.appendingPathComponent(".toastty/codex-plugin", isDirectory: true)
        }

        var legacyVersionsRootURL: URL {
            stateRootURL.appendingPathComponent("versions", isDirectory: true)
        }

        func homeStateURL(runtime: CodexIntegrationRuntime) -> URL {
            let standardized = runtime.codexHomeURL.standardizedFileURL
                .resolvingSymlinksInPath().path
            let key = SHA256.hash(data: Data(standardized.utf8))
                .prefix(12)
                .map { String(format: "%02x", $0) }
                .joined()
            return stateRootURL
                .appendingPathComponent("homes", isDirectory: true)
                .appendingPathComponent(key, isDirectory: true)
        }

        func receiptURL(runtime: CodexIntegrationRuntime) -> URL {
            homeStateURL(runtime: runtime).appendingPathComponent("receipt.json")
        }

        func legacyStateURL(runtime: CodexIntegrationRuntime) -> URL {
            homeStateURL(runtime: runtime).appendingPathComponent("state.json")
        }

        func profileConfigURL(runtime: CodexIntegrationRuntime) -> URL {
            runtime.codexHomeURL.appendingPathComponent("toastty-managed.config.toml")
        }

        func cacheRootURL(runtime: CodexIntegrationRuntime) -> URL {
            runtime.codexHomeURL.appendingPathComponent("plugins/cache/toastty/toastty", isDirectory: true)
        }

        func cacheVersionDirectories(runtime: CodexIntegrationRuntime) throws -> [URL] {
            try FileManager.default.contentsOfDirectory(
                at: cacheRootURL(runtime: runtime),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        func installLegacyState(
            runtime: CodexIntegrationRuntime,
            marketplacePath: String
        ) throws {
            let legacyRecord: [String: Any] = [
                "schemaVersion": 1,
                "marketplaceName": "toastty",
                "marketplacePath": marketplacePath,
                "installedPath": rootURL.appendingPathComponent("legacy-installed").path,
                "installedVersion": "0.2.0",
                "installedDigest": "legacy-digest",
                "skillNames": ["toastty-capabilities"],
            ]
            try writeLegacyState(
                JSONSerialization.data(withJSONObject: legacyRecord, options: [.sortedKeys]),
                runtime: runtime
            )
        }

        func installCorruptLegacyState(runtime: CodexIntegrationRuntime) throws {
            try writeLegacyState(Data("not json".utf8), runtime: runtime)
        }

        private func writeLegacyState(
            _ stateData: Data,
            runtime: CodexIntegrationRuntime
        ) throws {
            let stateURL = legacyStateURL(runtime: runtime)
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try stateData.write(to: stateURL, options: .atomic)

            let stagedLink = legacyStableMarketplaceURL.appendingPathComponent("plugins/toastty")
            try FileManager.default.createDirectory(
                at: stagedLink.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "legacy staging".write(
                to: legacyStableMarketplaceURL.appendingPathComponent("marker.txt"),
                atomically: true,
                encoding: .utf8
            )
            let versionsDirectory = legacyVersionsRootURL
                .appendingPathComponent("0.2.0-legacy-digest/toastty", isDirectory: true)
            try FileManager.default.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)
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

/// Emulates the Codex plugin CLI: population installs stage canonical cache
/// bytes inside whichever `CODEX_HOME` the manager targets (a throwaway home
/// in the new mechanism), while list/remove serve the legacy-cleanup path
/// against preregistered per-home state.
private final class FakeCodexPluginClient: CodexPluginCLIManaging, @unchecked Sendable {
    private let recorder: OperationRecorder
    private let lock = NSLock()
    private var marketplaceSourcesByHome: [String: String] = [:]
    private var legacyMarketplacesByHome: [String: CodexPluginMarketplace] = [:]
    private var legacyPluginsByHome: [String: [CodexInstalledPlugin]] = [:]
    private var populationHomes: [String] = []
    var installError: Error?
    var listMarketplacesError: Error?

    init(recorder: OperationRecorder) {
        self.recorder = recorder
    }

    var recordedPopulationHomes: [String] {
        lock.withLock { populationHomes }
    }

    func listMarketplaces(runtime: CodexIntegrationRuntime, deadline: Date) throws -> [CodexPluginMarketplace] {
        recorder.append("marketplace.list")
        if let listMarketplacesError { throw listMarketplacesError }
        return lock.withLock {
            legacyMarketplacesByHome[key(runtime)].map { [$0] } ?? []
        }
    }

    func listInstalledPlugins(runtime: CodexIntegrationRuntime, deadline: Date) throws -> [CodexInstalledPlugin] {
        recorder.append("plugin.list")
        return lock.withLock { legacyPluginsByHome[key(runtime)] ?? [] }
    }

    func addMarketplace(
        runtime: CodexIntegrationRuntime,
        sourcePath: String,
        deadline: Date
    ) throws -> String {
        recorder.append("marketplace.add")
        lock.withLock {
            populationHomes.append(key(runtime))
            marketplaceSourcesByHome[key(runtime)] = sourcePath
        }
        return "toastty"
    }

    func installPlugin(
        runtime: CodexIntegrationRuntime,
        selector: String,
        deadline: Date
    ) throws -> CodexPluginInstallation {
        recorder.append("plugin.install")
        if let installError { throw installError }
        let sourcePath = lock.withLock { marketplaceSourcesByHome[key(runtime)] }
        guard let sourcePath else {
            throw CodexPluginCLIError.commandFailed("plugin add", 1, "marketplace not registered")
        }
        let pluginSource = URL(fileURLWithPath: sourcePath, isDirectory: true)
            .appendingPathComponent("plugins/toastty", isDirectory: true)
        let descriptor = try ToasttyAgentPluginBundle.read(pluginRootURL: pluginSource)
        let destination = runtime.codexHomeURL
            .appendingPathComponent("plugins/cache/toastty/toastty", isDirectory: true)
            .appendingPathComponent(descriptor.version, isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: pluginSource, to: destination)
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
        lock.withLock {
            legacyPluginsByHome[key(runtime)]?.removeAll { $0.pluginID == selector }
        }
    }

    func removeMarketplace(
        runtime: CodexIntegrationRuntime,
        name: String,
        deadline: Date
    ) throws {
        recorder.append("marketplace.remove")
        _ = lock.withLock { legacyMarketplacesByHome.removeValue(forKey: key(runtime)) }
    }

    func registerLegacyMarketplace(
        _ marketplace: CodexPluginMarketplace,
        runtime: CodexIntegrationRuntime
    ) {
        lock.withLock { legacyMarketplacesByHome[key(runtime)] = marketplace }
    }

    func registerLegacyPlugin(
        _ plugin: CodexInstalledPlugin,
        runtime: CodexIntegrationRuntime
    ) {
        lock.withLock { legacyPluginsByHome[key(runtime), default: []].append(plugin) }
    }

    private func key(_ runtime: CodexIntegrationRuntime) -> String {
        runtime.codexHomeURL.path
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
