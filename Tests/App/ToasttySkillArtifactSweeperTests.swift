import CoreState
import Foundation
import XCTest
@testable import ToasttyApp

final class ToasttySkillArtifactSweeperTests: XCTestCase {
    // MARK: - user/<sourceDigest>/ retention

    func testUserRetentionKeepsNewestReceiptPlusOnePreviousVerified() throws {
        let fixture = try makeFixture(named: "user-retention")
        defer { fixture.cleanup() }
        let snapshots = try fixture.makeUserSnapshots(count: 4)
        // Oldest first: s1 < s2 < s3 < s4 by receipt mtime.
        for (index, snapshot) in snapshots.enumerated() {
            try setModificationDate(
                Date(timeIntervalSinceNow: -400 + Double(index) * 100),
                atPath: snapshot.receiptURL.path
            )
        }
        let agedStagingURL = fixture.userRootURL.appendingPathComponent(".staging-aged", isDirectory: true)
        try FileManager.default.createDirectory(at: agedStagingURL, withIntermediateDirectories: true)
        try setModificationDate(Date(timeIntervalSinceNow: -7200), atPath: agedStagingURL.path)
        let freshStagingURL = fixture.userRootURL.appendingPathComponent(".staging-fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: freshStagingURL, withIntermediateDirectories: true)

        fixture.sweeper.sweep()

        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.userRootURL.path)
        XCTAssertEqual(
            Set(remaining),
            [
                snapshots[3].sourceDigest,
                snapshots[2].sourceDigest,
                ".staging-fresh",
            ]
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.realHomeURL.appendingPathComponent(".toastty").path
            ),
            "The sweep must never touch the real home's .toastty"
        )
    }

    func testUserRetentionSkipsCorruptPreviousCandidatesInFavorOfOlderVerified() throws {
        let fixture = try makeFixture(named: "user-corrupt")
        defer { fixture.cleanup() }
        let snapshots = try fixture.makeUserSnapshots(count: 4)
        for (index, snapshot) in snapshots.enumerated() {
            try setModificationDate(
                Date(timeIntervalSinceNow: -400 + Double(index) * 100),
                atPath: snapshot.receiptURL.path
            )
        }
        // Structurally break the immediate previous candidate (s3): its
        // receipt still decodes, but a named package directory is gone.
        try FileManager.default.removeItem(
            at: snapshots[2].skillsRootURL.appendingPathComponent("alpha-skill", isDirectory: true)
        )
        // A digest-directory impostor without any receipt is also deleted.
        let junkURL = fixture.userRootURL.appendingPathComponent("not-a-snapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: junkURL, withIntermediateDirectories: true)
        try "junk".write(to: junkURL.appendingPathComponent("junk.txt"), atomically: true, encoding: .utf8)

        fixture.sweeper.sweep()

        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.userRootURL.path)
        XCTAssertEqual(
            Set(remaining),
            [snapshots[3].sourceDigest, snapshots[1].sourceDigest],
            "Expected the newest snapshot plus the older verified fallback (corrupt s3 skipped)"
        )
    }

    func testSweepAfterEmptyConvergenceIsANoOp() throws {
        let fixture = try makeFixture(named: "user-empty-convergence")
        defer { fixture.cleanup() }
        _ = try fixture.makeUserSnapshots(count: 2)
        // The user removes every skill; the next preparation converges the
        // snapshot store to empty, so the sweeper has nothing to retain.
        try FileManager.default.removeItem(at: fixture.skillsSourceRootURL)
        XCTAssertNil(try fixture.catalog.prepareSnapshot())
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.userRootURL.path),
            []
        )

        fixture.sweeper.sweep()

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.userRootURL.path),
            [],
            "Sweep after empty-convergence must be a no-op and resurrect nothing"
        )
        XCTAssertNil(fixture.catalog.existingSnapshot())
        XCTAssertEqual(fixture.catalog.existingSnapshotResolution(), .empty)
    }

    // MARK: - claude/<version>-<digest>/ retention

    func testClaudeRetentionKeepsCurrentBundledEvenWhenNotNewestPlusOneVerifiedExtra() throws {
        let fixture = try makeFixture(named: "claude-retention")
        defer { fixture.cleanup() }
        // Stage the current bundled version the way launches do.
        let current = try XCTUnwrap(fixture.claudeManager.prepareForRestoredManagedLaunch())
        let currentVersionRootURL = URL(fileURLWithPath: current.pluginRootPath)
            .deletingLastPathComponent()
        // Fabricate two verified older stagings and one junk directory.
        let olderKeptURL = try fixture.makeStagedClaudePlugin(version: "1.1.0")
        let olderDeletedURL = try fixture.makeStagedClaudePlugin(version: "1.0.0")
        let junkURL = fixture.claudeRootURL.appendingPathComponent("bogus-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: junkURL, withIntermediateDirectories: true)
        try "junk".write(to: junkURL.appendingPathComponent("junk.txt"), atomically: true, encoding: .utf8)
        // The current bundled dir is the OLDEST by mtime and must still win.
        try setModificationDate(Date(timeIntervalSinceNow: -500), atPath: currentVersionRootURL.path)
        try setModificationDate(Date(timeIntervalSinceNow: -50), atPath: olderKeptURL.path)
        try setModificationDate(Date(timeIntervalSinceNow: -200), atPath: olderDeletedURL.path)
        let agedStagingURL = fixture.claudeRootURL.appendingPathComponent(".staging-aged", isDirectory: true)
        try FileManager.default.createDirectory(at: agedStagingURL, withIntermediateDirectories: true)
        try setModificationDate(Date(timeIntervalSinceNow: -7200), atPath: agedStagingURL.path)
        let freshStagingURL = fixture.claudeRootURL.appendingPathComponent(".staging-fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: freshStagingURL, withIntermediateDirectories: true)

        fixture.sweeper.sweep()

        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.claudeRootURL.path)
        XCTAssertEqual(
            Set(remaining),
            [
                currentVersionRootURL.lastPathComponent,
                olderKeptURL.lastPathComponent,
                ".staging-fresh",
            ]
        )
        // The kept current staging still verifies for the next launch.
        XCTAssertEqual(fixture.claudeManager.existingVerifiedConfiguration(), current)
    }

    // MARK: - Codex cache litter

    func testCodexCacheLitterSweepRemovesAgedLitterOnly() throws {
        let fixture = try makeFixture(named: "codex-litter")
        defer { fixture.cleanup() }
        let codexHomeURL = fixture.rootURL.appendingPathComponent("codex-home", isDirectory: true)
        let shippedCacheURL = codexHomeURL
            .appendingPathComponent("plugins/cache/toastty", isDirectory: true)
        let userCacheURL = codexHomeURL
            .appendingPathComponent("plugins/cache/toastty-user", isDirectory: true)
        let otherMarketplaceURL = codexHomeURL
            .appendingPathComponent("plugins/cache/other-marketplace", isDirectory: true)
        let shippedActiveURL = shippedCacheURL.appendingPathComponent("toastty/1.2.3", isDirectory: true)
        let userActiveURL = userCacheURL.appendingPathComponent("toastty-user/0.1.0-abc", isDirectory: true)
        for directoryURL in [shippedActiveURL, userActiveURL, otherMarketplaceURL] {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        try "active".write(
            to: shippedActiveURL.appendingPathComponent("marker.txt"),
            atomically: true,
            encoding: .utf8
        )
        let agedDate = Date(timeIntervalSinceNow: -7200)
        let agedShippedOldURL = shippedCacheURL.appendingPathComponent(".toastty-old-aaa", isDirectory: true)
        let agedShippedStagingURL = shippedCacheURL.appendingPathComponent(".toastty-staging-bbb", isDirectory: true)
        let freshShippedOldURL = shippedCacheURL.appendingPathComponent(".toastty-old-fresh", isDirectory: true)
        let agedUserOldURL = userCacheURL.appendingPathComponent(".toastty-old-ccc", isDirectory: true)
        let agedOtherMarketplaceOldURL = otherMarketplaceURL.appendingPathComponent(".toastty-old-ddd", isDirectory: true)
        for directoryURL in [
            agedShippedOldURL, agedShippedStagingURL, freshShippedOldURL,
            agedUserOldURL, agedOtherMarketplaceOldURL,
        ] {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        for directoryURL in [agedShippedOldURL, agedShippedStagingURL, agedUserOldURL, agedOtherMarketplaceOldURL] {
            try setModificationDate(agedDate, atPath: directoryURL.path)
        }
        try fixture.writeCodexReceipts(
            homeKey: "abcdef012345",
            shippedCachePath: shippedActiveURL.path,
            userCachePath: userActiveURL.path
        )
        // A malformed receipt must never route the sweep anywhere.
        let bogusKeyURL = fixture.codexHomesRootURL.appendingPathComponent("ffffffffffff", isDirectory: true)
        try FileManager.default.createDirectory(at: bogusKeyURL, withIntermediateDirectories: true)
        try #"{"cachePath":"/private/etc"}"#.write(
            to: bogusKeyURL.appendingPathComponent("receipt.json"),
            atomically: true,
            encoding: .utf8
        )

        fixture.sweeper.sweep()

        XCTAssertFalse(FileManager.default.fileExists(atPath: agedShippedOldURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: agedShippedStagingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: agedUserOldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshShippedOldURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: shippedActiveURL.appendingPathComponent("marker.txt").path
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: userActiveURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: agedOtherMarketplaceOldURL.path),
            "Other marketplaces' cache directories must never be touched"
        )
        // Receipts are tiny and required for fast-path verification.
        let homeStateURL = fixture.codexHomesRootURL.appendingPathComponent("abcdef012345", isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: homeStateURL.appendingPathComponent("receipt.json").path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: homeStateURL.appendingPathComponent("user-receipt.json").path)
        )
    }

    // MARK: - Concurrency

    func testConcurrentPrepareSnapshotAndSweepBothComplete() throws {
        let fixture = try makeFixture(named: "concurrency")
        defer { fixture.cleanup() }
        _ = try fixture.makeUserSnapshots(count: 3)

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "sweeper-test", attributes: .concurrent)
        let preparationErrors = ErrorBox()
        group.enter()
        queue.async {
            defer { group.leave() }
            for _ in 0..<5 {
                do {
                    _ = try fixture.catalog.prepareSnapshot()
                } catch {
                    preparationErrors.append(error)
                }
            }
        }
        group.enter()
        queue.async {
            defer { group.leave() }
            fixture.sweeper.sweep()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)

        XCTAssertEqual(preparationErrors.errors.count, 0, "\(preparationErrors.errors)")
        // The surviving newest snapshot must still be fully verified,
        // including the content digest.
        let survivor = try XCTUnwrap(fixture.catalog.existingSnapshot())
        XCTAssertTrue(FileManager.default.fileExists(atPath: survivor.receiptURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: survivor.skillsRootURL.appendingPathComponent("alpha-skill/SKILL.md").path
            )
        )
    }

    // MARK: - Empty and missing state

    func testEmptyAndMissingDirectoriesAreNoOp() throws {
        let fixture = try makeFixture(named: "empty")
        defer { fixture.cleanup() }

        // Missing agent-plugins root entirely.
        fixture.sweeper.sweep()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.agentPluginsRootURL.path),
            "The sweeper must never create directories"
        )

        // Present-but-empty roots.
        for directoryURL in [fixture.userRootURL, fixture.claudeRootURL, fixture.codexHomesRootURL] {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        fixture.sweeper.sweep()
        for directoryURL in [fixture.userRootURL, fixture.claudeRootURL, fixture.codexHomesRootURL] {
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: directoryURL.path),
                []
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.realHomeURL.appendingPathComponent(".toastty").path
            )
        )
    }
}

// MARK: - Fixture

private extension ToasttySkillArtifactSweeperTests {
    final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Error] = []

        var errors: [Error] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func append(_ error: Error) {
            lock.lock()
            storage.append(error)
            lock.unlock()
        }
    }

    struct Fixture {
        let rootURL: URL
        let realHomeURL: URL
        let runtimeHomeURL: URL
        let bundledSourceURL: URL
        let catalog: ToasttyUserSkillCatalog
        let claudeManager: ClaudeSkillsBundleManager
        let sweeper: ToasttySkillArtifactSweeper

        var skillsSourceRootURL: URL {
            runtimeHomeURL.appendingPathComponent("skills", isDirectory: true)
        }

        var agentPluginsRootURL: URL {
            runtimeHomeURL.appendingPathComponent("agent-plugins", isDirectory: true)
        }

        var userRootURL: URL {
            agentPluginsRootURL.appendingPathComponent("user", isDirectory: true)
        }

        var claudeRootURL: URL {
            agentPluginsRootURL.appendingPathComponent("claude", isDirectory: true)
        }

        var codexHomesRootURL: URL {
            agentPluginsRootURL.appendingPathComponent("codex/homes", isDirectory: true)
        }

        /// Builds `count` distinct content-addressed snapshots by mutating
        /// the single accepted package between `prepareSnapshot()` calls.
        func makeUserSnapshots(count: Int) throws -> [UserSkillPluginSnapshot] {
            let packageURL = skillsSourceRootURL.appendingPathComponent("alpha-skill", isDirectory: true)
            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
            try "---\nname: alpha-skill\ndescription: Test skill.\n---\n\nBody.\n".write(
                to: packageURL.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
            var snapshots: [UserSkillPluginSnapshot] = []
            for revision in 0..<count {
                try "revision \(revision)\n".write(
                    to: packageURL.appendingPathComponent("notes.md"),
                    atomically: true,
                    encoding: .utf8
                )
                snapshots.append(try XCTUnwrap(catalog.prepareSnapshot()))
            }
            XCTAssertEqual(Set(snapshots.map(\.sourceDigest)).count, count)
            return snapshots
        }

        /// Fabricates a verified staged Claude plugin directory named
        /// `<version>-<digest>/toastty` the way
        /// `ClaudeSkillsBundleManager.destinationPluginURL` lays them out.
        func makeStagedClaudePlugin(version: String) throws -> URL {
            let temporaryPluginURL = rootURL.appendingPathComponent(
                "claude-fixture-\(version)/toastty",
                isDirectory: true
            )
            try Self.writePluginBundle(at: temporaryPluginURL, version: version)
            let descriptor = try ToasttyAgentPluginBundle.read(
                pluginRootURL: temporaryPluginURL,
                fileManager: .default
            )
            let versionRootURL = claudeRootURL.appendingPathComponent(
                "\(descriptor.version)-\(descriptor.contentDigest)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: versionRootURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(
                at: temporaryPluginURL.deletingLastPathComponent(),
                to: versionRootURL
            )
            return versionRootURL
        }

        func writeCodexReceipts(
            homeKey: String,
            shippedCachePath: String,
            userCachePath: String
        ) throws {
            let homeStateURL = codexHomesRootURL.appendingPathComponent(homeKey, isDirectory: true)
            try FileManager.default.createDirectory(at: homeStateURL, withIntermediateDirectories: true)
            try #"{"cachePath":"\#(shippedCachePath)"}"#.write(
                to: homeStateURL.appendingPathComponent("receipt.json"),
                atomically: true,
                encoding: .utf8
            )
            try #"{"cachePath":"\#(userCachePath)"}"#.write(
                to: homeStateURL.appendingPathComponent("user-receipt.json"),
                atomically: true,
                encoding: .utf8
            )
        }

        static func writePluginBundle(at rootURL: URL, version: String) throws {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let codexManifestURL = rootURL.appendingPathComponent(".codex-plugin", isDirectory: true)
            let claudeManifestURL = rootURL.appendingPathComponent(".claude-plugin", isDirectory: true)
            try FileManager.default.createDirectory(at: codexManifestURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: claudeManifestURL, withIntermediateDirectories: true)
            try """
            {"name":"toastty","version":"\(version)","skills":"./skills/"}
            """.write(to: codexManifestURL.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
            try """
            {"name":"toastty","version":"\(version)"}
            """.write(to: claudeManifestURL.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
            for skill in ToasttyAgentPluginBundle.skills {
                let skillURL = rootURL.appendingPathComponent("skills/\(skill.name)", isDirectory: true)
                try FileManager.default.createDirectory(at: skillURL, withIntermediateDirectories: true)
                try "---\nname: \(skill.name)\ndescription: Test skill.\n---\n"
                    .write(to: skillURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            }
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    func makeFixture(named name: String) throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-skill-sweeper-\(name)-\(UUID().uuidString)", isDirectory: true)
        let realHomeURL = rootURL.appendingPathComponent("real-home", isDirectory: true)
        let runtimeHomeURL = rootURL.appendingPathComponent("runtime-home", isDirectory: true)
        let bundledSourceURL = rootURL.appendingPathComponent("bundled-source/toastty", isDirectory: true)
        try FileManager.default.createDirectory(at: realHomeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: runtimeHomeURL.appendingPathComponent("skills", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Fixture.writePluginBundle(at: bundledSourceURL, version: "3.0.0")
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: realHomeURL.path,
            environment: [
                "TOASTTY_RUNTIME_HOME": runtimeHomeURL.path,
                // Hermetic override: user skills follow the real home by
                // default, so the fixture redirects the source explicitly.
                "TOASTTY_USER_SKILLS_ROOT": runtimeHomeURL
                    .appendingPathComponent("skills", isDirectory: true).path,
            ]
        )
        let catalog = ToasttyUserSkillCatalog(runtimePaths: runtimePaths)
        let claudeManager = ClaudeSkillsBundleManager(
            sourcePluginURLProvider: { bundledSourceURL },
            runtimePaths: runtimePaths
        )
        let sweeper = ToasttySkillArtifactSweeper(
            runtimePaths: runtimePaths,
            userSkillCatalog: catalog,
            claudeSkillsBundleManager: claudeManager,
            sourcePluginURLProvider: { bundledSourceURL }
        )
        return Fixture(
            rootURL: rootURL,
            realHomeURL: realHomeURL,
            runtimeHomeURL: runtimeHomeURL,
            bundledSourceURL: bundledSourceURL,
            catalog: catalog,
            claudeManager: claudeManager,
            sweeper: sweeper
        )
    }

    func setModificationDate(_ date: Date, atPath path: String) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }
}
