import CoreState
import Darwin
import Foundation
import XCTest
@testable import ToasttyApp

final class ToasttyUserSkillCatalogTests: XCTestCase {
    // MARK: - Validation matrix

    func testValidPackageAccepted() throws {
        let fixture = try makeFixture(named: "valid")
        defer { fixture.cleanup() }
        try fixture.writePackage(named: "alpha-skill")

        let state = fixture.catalog.scan()

        XCTAssertEqual(state.packages.count, 1)
        XCTAssertEqual(state.packages.first?.name, "alpha-skill")
        XCTAssertEqual(state.packages.first?.status, .accepted)
        XCTAssertEqual(state.globalDiagnostics, [])
        XCTAssertFalse(state.sourceFingerprint.isEmpty)
    }

    func testFingerprintChangesWhenSourcesChange() throws {
        let fixture = try makeFixture(named: "fingerprint")
        defer { fixture.cleanup() }
        try fixture.writePackage(named: "alpha-skill")
        let first = fixture.catalog.scan().sourceFingerprint

        try fixture.writePackage(named: "beta-skill")
        let second = fixture.catalog.scan().sourceFingerprint

        XCTAssertNotEqual(first, second)
    }

    /// The allowed name pattern is ASCII-only, so a decomposed (NFD)
    /// directory name can never be accepted; what NFC canonicalization must
    /// guarantee is that an NFD directory and an NFC frontmatter name compare
    /// equal (`invalidName`, not `nameMismatch`), under one canonical NFC key.
    func testNFDDirectoryNameUnifiesWithNFCFrontmatterName() throws {
        let fixture = try makeFixture(named: "nfd")
        defer { fixture.cleanup() }
        let decomposedName = "cafe\u{0301}-skill"
        let precomposedName = "café-skill".precomposedStringWithCanonicalMapping
        try fixture.writePackage(named: decomposedName, frontmatterName: precomposedName)

        let state = fixture.catalog.scan()

        XCTAssertEqual(state.packages.count, 1)
        let package = try XCTUnwrap(state.packages.first)
        XCTAssertEqual(package.name, precomposedName)
        XCTAssertEqual(package.status, .excluded(.invalidName))
    }

    func testCaseFoldCollisionExcludesBothPackages() throws {
        // The default macOS volume case-folds at least as aggressively as
        // Foundation, so colliding directory names cannot coexist on it; a
        // throwaway case-sensitive APFS image hosts the collision.
        let volumeName = "toastty-usc-\(UUID().uuidString.prefix(8))"
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(volumeName).dmg")
        let creation = try? runProcess(
            "/usr/bin/hdiutil",
            arguments: [
                "create", "-size", "16m", "-fs", "Case-sensitive APFS",
                "-volname", volumeName, "-attach", imageURL.path,
            ]
        )
        guard let creation, creation.status == 0 else {
            throw XCTSkip("hdiutil could not create a case-sensitive volume; skipped case-fold collision check")
        }
        let volumeURL = URL(fileURLWithPath: "/Volumes/\(volumeName)", isDirectory: true)
        defer {
            _ = try? runProcess("/usr/bin/hdiutil", arguments: ["detach", volumeURL.path, "-force"])
            try? FileManager.default.removeItem(at: imageURL)
        }

        let fixture = try makeFixture(named: "casefold", rootURL: volumeURL.appendingPathComponent("fixture"))
        try fixture.writePackage(named: "alpha-skill")
        try fixture.writePackage(named: "ALPHA-SKILL", frontmatterName: "ALPHA-SKILL")

        let state = fixture.catalog.scan()

        XCTAssertEqual(state.packages.count, 2)
        for package in state.packages {
            XCTAssertEqual(package.status, .excluded(.duplicateName), "\(package.name)")
        }
    }

    func testHiddenDirectoriesAndNonDirectoryChildrenAreSilentlyIgnored() throws {
        let fixture = try makeFixture(named: "hidden")
        defer { fixture.cleanup() }
        try fixture.writePackage(named: "alpha-skill")
        let hiddenURL = fixture.skillsRootURL.appendingPathComponent(".hidden-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenURL, withIntermediateDirectories: true)
        try "stray".write(
            to: fixture.skillsRootURL.appendingPathComponent("stray.txt"),
            atomically: true,
            encoding: .utf8
        )

        let state = fixture.catalog.scan()

        XCTAssertEqual(state.packages.map(\.name), ["alpha-skill"])
    }

    func testMissingSkillFileExcluded() throws {
        let fixture = try makeFixture(named: "missing-skill")
        defer { fixture.cleanup() }
        let packageURL = fixture.skillsRootURL.appendingPathComponent("alpha-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try "readme".write(
            to: packageURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(fixture.catalog.scan().packages.first?.status, .excluded(.missingSkillFile))
    }

    func testInvalidFrontmatterExcluded() throws {
        let fixture = try makeFixture(named: "bad-frontmatter")
        defer { fixture.cleanup() }
        try fixture.writePackage(named: "unclosed-skill", skillFileContents: "---\nname: unclosed-skill\n")
        try fixture.writePackage(
            named: "no-description-skill",
            skillFileContents: "---\nname: no-description-skill\ndescription:\n---\n"
        )
        try fixture.writePackage(named: "no-frontmatter-skill", skillFileContents: "# Just markdown\n")

        let state = fixture.catalog.scan()

        XCTAssertEqual(state.packages.count, 3)
        for package in state.packages {
            XCTAssertEqual(package.status, .excluded(.invalidFrontmatter), "\(package.name)")
        }
    }

    func testNameMismatchExcluded() throws {
        let fixture = try makeFixture(named: "mismatch")
        defer { fixture.cleanup() }
        try fixture.writePackage(named: "alpha-skill", frontmatterName: "beta-skill")

        XCTAssertEqual(fixture.catalog.scan().packages.first?.status, .excluded(.nameMismatch))
    }

    func testInvalidNameCharactersExcluded() throws {
        let fixture = try makeFixture(named: "invalid-name")
        defer { fixture.cleanup() }
        try fixture.writePackage(named: "under_score", frontmatterName: "under_score")
        try fixture.writePackage(named: "-leading-hyphen", frontmatterName: "-leading-hyphen")
        let longName = String(repeating: "a", count: 65)
        try fixture.writePackage(named: longName, frontmatterName: longName)

        let state = fixture.catalog.scan()

        XCTAssertEqual(state.packages.count, 3)
        for package in state.packages {
            XCTAssertEqual(package.status, .excluded(.invalidName), "\(package.name)")
        }
    }

    func testSymlinkInsidePackageRejected() throws {
        let fixture = try makeFixture(named: "inner-symlink")
        defer { fixture.cleanup() }
        let packageURL = try fixture.writePackage(named: "alpha-skill")
        try FileManager.default.createSymbolicLink(
            at: packageURL.appendingPathComponent("escape"),
            withDestinationURL: fixture.rootURL
        )

        XCTAssertEqual(fixture.catalog.scan().packages.first?.status, .excluded(.symlinkRejected))
    }

    func testSymlinkedPackageDirectoryRejected() throws {
        let fixture = try makeFixture(named: "package-symlink")
        defer { fixture.cleanup() }
        let realPackageURL = fixture.rootURL.appendingPathComponent("outside-package", isDirectory: true)
        try FileManager.default.createDirectory(at: realPackageURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.skillsRootURL.appendingPathComponent("linked-skill"),
            withDestinationURL: realPackageURL
        )

        let state = fixture.catalog.scan()

        XCTAssertEqual(state.packages.count, 1)
        XCTAssertEqual(state.packages.first?.status, .excluded(.symlinkRejected))
    }

    func testSpecialFileRejected() throws {
        let fixture = try makeFixture(named: "special-file")
        defer { fixture.cleanup() }
        let packageURL = try fixture.writePackage(named: "alpha-skill")
        let fifoPath = packageURL.appendingPathComponent("pipe").path
        guard mkfifo(fifoPath, 0o644) == 0 else {
            throw XCTSkip("mkfifo unavailable in this environment")
        }

        XCTAssertEqual(fixture.catalog.scan().packages.first?.status, .excluded(.specialFileRejected))
    }

    func testUnreadableEntryExcluded() throws {
        let fixture = try makeFixture(named: "unreadable")
        defer { fixture.cleanup() }
        let packageURL = try fixture.writePackage(named: "alpha-skill")
        let lockedURL = packageURL.appendingPathComponent("locked.txt")
        try "secret".write(to: lockedURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockedURL.path)
        }

        XCTAssertEqual(fixture.catalog.scan().packages.first?.status, .excluded(.unreadable))
    }

    func testOversizedSkillFileExcluded() throws {
        let fixture = try makeFixture(named: "big-skill-file")
        defer { fixture.cleanup() }
        let padding = String(repeating: "x", count: 256 * 1024)
        try fixture.writePackage(
            named: "alpha-skill",
            skillFileContents: "---\nname: alpha-skill\ndescription: Big.\n---\n\(padding)\n"
        )

        XCTAssertEqual(fixture.catalog.scan().packages.first?.status, .excluded(.skillFileTooLarge))
    }

    func testOversizedPackageExcluded() throws {
        let fixture = try makeFixture(named: "big-package")
        defer { fixture.cleanup() }
        let packageURL = try fixture.writePackage(named: "alpha-skill")
        try Data(repeating: 0x61, count: 5 * 1024 * 1024 + 1)
            .write(to: packageURL.appendingPathComponent("filler.bin"))

        XCTAssertEqual(fixture.catalog.scan().packages.first?.status, .excluded(.packageTooLarge))
    }

    func testDepthLimitEnforcedAtEightLevels() throws {
        let fixture = try makeFixture(named: "depth")
        defer { fixture.cleanup() }
        let deepPackageURL = try fixture.writePackage(named: "deep-skill")
        var deepDirectoryURL = deepPackageURL
        for level in 1...8 {
            deepDirectoryURL = deepDirectoryURL.appendingPathComponent("d\(level)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: deepDirectoryURL, withIntermediateDirectories: true)
        try "too deep".write(
            to: deepDirectoryURL.appendingPathComponent("leaf.txt"),
            atomically: true,
            encoding: .utf8
        )
        let okPackageURL = try fixture.writePackage(named: "ok-skill")
        var okDirectoryURL = okPackageURL
        for level in 1...7 {
            okDirectoryURL = okDirectoryURL.appendingPathComponent("d\(level)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: okDirectoryURL, withIntermediateDirectories: true)
        try "at the limit".write(
            to: okDirectoryURL.appendingPathComponent("leaf.txt"),
            atomically: true,
            encoding: .utf8
        )

        let state = fixture.catalog.scan()

        XCTAssertEqual(state.package(named: "deep-skill")?.status, .excluded(.depthExceeded))
        XCTAssertEqual(state.package(named: "ok-skill")?.status, .accepted)
    }

    func testTooManyPackagesExcludesAll() throws {
        let fixture = try makeFixture(named: "too-many")
        defer { fixture.cleanup() }
        for index in 1...33 {
            try fixture.writePackage(named: "skill-\(String(format: "%02d", index))")
        }

        let state = fixture.catalog.scan()

        XCTAssertEqual(state.globalDiagnostics, [.globalLimitExceeded])
        XCTAssertEqual(state.packages.count, 33)
        for package in state.packages {
            XCTAssertEqual(package.status, .excluded(.globalLimitExceeded), "\(package.name)")
        }
        XCTAssertNil(try fixture.catalog.prepareSnapshot())
    }

    func testGlobalByteBudgetExcludesAll() throws {
        let fixture = try makeFixture(named: "global-bytes")
        defer { fixture.cleanup() }
        for index in 1...3 {
            let packageURL = try fixture.writePackage(named: "skill-\(index)")
            try Data(repeating: 0x61, count: 4 * 1024 * 1024)
                .write(to: packageURL.appendingPathComponent("filler.bin"))
        }

        let state = fixture.catalog.scan()

        XCTAssertEqual(state.globalDiagnostics, [.globalLimitExceeded])
        for package in state.packages {
            XCTAssertEqual(package.status, .excluded(.globalLimitExceeded), "\(package.name)")
        }
    }

    func testGlobalFileCountExcludesAll() throws {
        let fixture = try makeFixture(named: "global-files")
        defer { fixture.cleanup() }
        for packageIndex in 1...3 {
            let packageURL = try fixture.writePackage(named: "skill-\(packageIndex)")
            for fileIndex in 1...200 {
                try "f".write(
                    to: packageURL.appendingPathComponent("file-\(fileIndex).txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }

        let state = fixture.catalog.scan()

        XCTAssertEqual(state.globalDiagnostics, [.globalLimitExceeded])
        for package in state.packages {
            XCTAssertEqual(package.status, .excluded(.globalLimitExceeded), "\(package.name)")
        }
    }

    // MARK: - Snapshot preparation

    func testWorkflowExamplesLoadAsUserSkillsWithExecutableHelpers() throws {
        let fixture = try makeFixture(named: "worktree-examples")
        defer { fixture.cleanup() }
        let examplesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("examples/skills", isDirectory: true)
        let names = ["worktree-cleanup", "worktree-create", "worktree-done"]
        for name in names {
            try FileManager.default.copyItem(
                at: examplesURL.appendingPathComponent(name),
                to: fixture.skillsRootURL.appendingPathComponent(name)
            )
        }

        let snapshot = try XCTUnwrap(fixture.catalog.prepareSnapshot())
        XCTAssertEqual(snapshot.acceptedPackageNames, names)
        for name in names {
            XCTAssertEqual(
                try Data(contentsOf: snapshot.skillsRootURL.appendingPathComponent("\(name)/SKILL.md")),
                try Data(contentsOf: examplesURL.appendingPathComponent("\(name)/SKILL.md"))
            )
        }
        let statusURL = snapshot.skillsRootURL
            .appendingPathComponent("worktree-cleanup/scripts/worktree-status.py")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: statusURL.path))
        let helperURL = snapshot.skillsRootURL
            .appendingPathComponent("worktree-create/scripts/create-worktree.sh")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helperURL.path))
        let result = try runProcess(helperURL.path, arguments: ["--help"])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.contains("--repo-root"))
    }

    func testPrepareSnapshotBuildsExpectedLayoutAndReusesImmutably() throws {
        let fixture = try makeFixture(named: "snapshot")
        defer { fixture.cleanup() }
        try fixture.writePackage(named: "alpha-skill")
        try fixture.writePackage(named: "beta-skill")

        let first = try XCTUnwrap(fixture.catalog.prepareSnapshot())

        XCTAssertEqual(first.pluginName, "toastty-user")
        XCTAssertEqual(first.version, "0.1.0-\(first.sourceDigest.prefix(12))")
        XCTAssertEqual(first.acceptedPackageNames, ["alpha-skill", "beta-skill"])
        let expectedRoot = fixture.snapshotsRootURL
            .appendingPathComponent(first.sourceDigest, isDirectory: true)
        XCTAssertEqual(
            first.marketplaceRootURL.path,
            expectedRoot.appendingPathComponent("marketplace").path
        )
        XCTAssertEqual(
            first.pluginRootURL.path,
            first.marketplaceRootURL.appendingPathComponent("plugins/toastty-user").path
        )
        for relativePath in [
            "marketplace/.agents/plugins/marketplace.json",
            "marketplace/plugins/toastty-user/.codex-plugin/plugin.json",
            "marketplace/plugins/toastty-user/.claude-plugin/plugin.json",
            "marketplace/plugins/toastty-user/.cursor-plugin/plugin.json",
            "marketplace/plugins/toastty-user/skills/alpha-skill/SKILL.md",
            "marketplace/plugins/toastty-user/skills/beta-skill/SKILL.md",
            "receipt.json",
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: expectedRoot.appendingPathComponent(relativePath).path
                ),
                relativePath
            )
        }
        let codexManifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: first.pluginRootURL.appendingPathComponent(".codex-plugin/plugin.json"))
        ) as? [String: Any]
        XCTAssertEqual(codexManifest?["name"] as? String, "toastty-user")
        XCTAssertEqual(codexManifest?["version"] as? String, first.version)
        XCTAssertEqual(codexManifest?["skills"] as? String, "./skills/")
        let claudeManifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: first.pluginRootURL.appendingPathComponent(".claude-plugin/plugin.json"))
        ) as? [String: Any]
        XCTAssertEqual(claudeManifest?["version"] as? String, first.version)
        let cursorManifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: first.pluginRootURL.appendingPathComponent(".cursor-plugin/plugin.json"))
        ) as? [String: Any]
        XCTAssertEqual(cursorManifest?["name"] as? String, "toastty-user")
        XCTAssertEqual(cursorManifest?["version"] as? String, first.version)
        XCTAssertEqual(cursorManifest?["skills"] as? String, "./skills/")
        XCTAssertNil(cursorManifest?["hooks"])

        // Rebuilding without source changes reuses the immutable snapshot.
        // The receipt's modification date is intentionally refreshed on reuse
        // (newest-receipt selection), so identity is inode plus content.
        let receiptInode = try fileInode(at: first.receiptURL)
        let receiptData = try Data(contentsOf: first.receiptURL)
        let second = try XCTUnwrap(fixture.catalog.prepareSnapshot())
        XCTAssertEqual(second, first)
        XCTAssertEqual(try fileInode(at: second.receiptURL), receiptInode)
        XCTAssertEqual(try Data(contentsOf: second.receiptURL), receiptData)
    }

    func testContentChangeCreatesNewSnapshotAndRevertReusesOriginal() throws {
        let fixture = try makeFixture(named: "digest-change")
        defer { fixture.cleanup() }
        let packageURL = try fixture.writePackage(named: "alpha-skill")
        let extraURL = packageURL.appendingPathComponent("notes.md")
        try "original".write(to: extraURL, atomically: true, encoding: .utf8)
        let original = try XCTUnwrap(fixture.catalog.prepareSnapshot())

        try "changed".write(to: extraURL, atomically: true, encoding: .utf8)
        let changed = try XCTUnwrap(fixture.catalog.prepareSnapshot())
        XCTAssertNotEqual(changed.sourceDigest, original.sourceDigest)
        XCTAssertNotEqual(changed.pluginRootURL.path, original.pluginRootURL.path)

        try "original".write(to: extraURL, atomically: true, encoding: .utf8)
        let reverted = try XCTUnwrap(fixture.catalog.prepareSnapshot())
        XCTAssertEqual(reverted.sourceDigest, original.sourceDigest)
        XCTAssertEqual(reverted.pluginRootURL.path, original.pluginRootURL.path)
    }

    func testExecutableBitPreservedAndReflectedInDigest() throws {
        let fixture = try makeFixture(named: "executable")
        defer { fixture.cleanup() }
        let packageURL = try fixture.writePackage(named: "alpha-skill")
        let scriptsURL = packageURL.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsURL, withIntermediateDirectories: true)
        let scriptURL = scriptsURL.appendingPathComponent("run.sh")
        try "#!/bin/sh\nexit 0\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let executableSnapshot = try XCTUnwrap(fixture.catalog.prepareSnapshot())
        let copiedScriptPath = executableSnapshot.skillsRootURL
            .appendingPathComponent("alpha-skill/scripts/run.sh").path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: copiedScriptPath))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scriptURL.path)
        let plainSnapshot = try XCTUnwrap(fixture.catalog.prepareSnapshot())
        XCTAssertNotEqual(plainSnapshot.sourceDigest, executableSnapshot.sourceDigest)
        XCTAssertFalse(
            FileManager.default.isExecutableFile(
                atPath: plainSnapshot.skillsRootURL
                    .appendingPathComponent("alpha-skill/scripts/run.sh").path
            )
        )
    }

    func testOrphanedStagingCleanedUpAndFinalLayoutCarriesReceipt() throws {
        let fixture = try makeFixture(named: "staging")
        defer { fixture.cleanup() }
        try fixture.writePackage(named: "alpha-skill")
        // An aged orphan (left by a crashed earlier run) is removed; a fresh
        // staging directory is presumed to belong to a concurrent build in
        // another process and is left alone.
        let agedOrphanURL = fixture.snapshotsRootURL.appendingPathComponent(".staging-orphan", isDirectory: true)
        try FileManager.default.createDirectory(at: agedOrphanURL, withIntermediateDirectories: true)
        try "junk".write(
            to: agedOrphanURL.appendingPathComponent("junk.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -7200)],
            ofItemAtPath: agedOrphanURL.path
        )
        let freshStagingURL = fixture.snapshotsRootURL.appendingPathComponent(".staging-fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: freshStagingURL, withIntermediateDirectories: true)

        let snapshot = try XCTUnwrap(fixture.catalog.prepareSnapshot())

        XCTAssertFalse(FileManager.default.fileExists(atPath: agedOrphanURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshStagingURL.path))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: fixture.snapshotsRootURL.path)
        XCTAssertEqual(siblings.filter { $0.hasPrefix(".staging-") }, [".staging-fresh"])
        XCTAssertEqual(
            siblings.filter { $0.hasPrefix(".") == false }.sorted(),
            [snapshot.sourceDigest]
        )
        // A completed snapshot always carries its receipt as the completion
        // marker; content exists wherever the receipt exists.
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.receiptURL.path))
    }

    func testCorruptExistingSnapshotIsRebuilt() throws {
        let fixture = try makeFixture(named: "corrupt")
        defer { fixture.cleanup() }
        try fixture.writePackage(named: "alpha-skill")
        let first = try XCTUnwrap(fixture.catalog.prepareSnapshot())
        try "tampered".write(
            to: first.skillsRootURL.appendingPathComponent("alpha-skill/SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let rebuilt = try XCTUnwrap(fixture.catalog.prepareSnapshot())

        XCTAssertEqual(rebuilt.sourceDigest, first.sourceDigest)
        let restoredContents = try String(
            contentsOf: rebuilt.skillsRootURL.appendingPathComponent("alpha-skill/SKILL.md"),
            encoding: .utf8
        )
        XCTAssertTrue(restoredContents.contains("name: alpha-skill"))
    }

    func testZeroAcceptedPackagesReturnsNilWithoutCreatingSnapshotDirectory() throws {
        let fixture = try makeFixture(named: "zero")
        defer { fixture.cleanup() }
        try fixture.writePackage(named: "broken-skill", skillFileContents: "no frontmatter\n")

        XCTAssertNil(try fixture.catalog.prepareSnapshot())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.snapshotsRootURL.path))

        // A missing skills directory is an empty catalog, not an error.
        let emptyFixture = try makeFixture(named: "zero-missing")
        defer { emptyFixture.cleanup() }
        XCTAssertEqual(emptyFixture.catalog.scan().packages, [])
        XCTAssertNil(try emptyFixture.catalog.prepareSnapshot())
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyFixture.snapshotsRootURL.path))
    }

    func testAllWritesStayUnderIsolatedRuntimeHome() throws {
        let fixture = try makeFixture(named: "isolation")
        defer { fixture.cleanup() }
        try fixture.writePackage(named: "alpha-skill")

        let snapshot = try XCTUnwrap(fixture.catalog.prepareSnapshot())

        XCTAssertTrue(snapshot.pluginRootURL.path.hasPrefix(fixture.runtimeHomeURL.path + "/"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.realHomeURL.appendingPathComponent(".toastty").path
            ),
            "Isolated runs must never write into the real home's .toastty"
        )
    }

    func testFileSwappedForFifoAfterScanFailsFastWithoutHanging() throws {
        let swappingFileManager = FifoSwappingFileManager()
        let fixture = try makeFixture(named: "fifo-swap", fileManager: swappingFileManager)
        defer { fixture.cleanup() }
        let packageURL = try fixture.writePackage(named: "alpha-skill")
        let trapURL = packageURL.appendingPathComponent("trap.txt")
        try "regular for the scan".write(to: trapURL, atomically: true, encoding: .utf8)
        swappingFileManager.swapTargetPath = trapURL.path

        // Without O_NONBLOCK the FIFO open would block forever waiting for a
        // writer; the snapshot build must fail fast with a typed error.
        let finished = expectation(description: "prepareSnapshot returned")
        let errorBox = ErrorBox()
        DispatchQueue.global().async { [catalog = fixture.catalog] in
            do {
                _ = try catalog.prepareSnapshot()
            } catch {
                errorBox.set(error)
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)

        guard case .sourceUnreadable(let path)? = errorBox.current as? ToasttyUserSkillCatalogError else {
            return XCTFail("Expected sourceUnreadable, got \(String(describing: errorBox.current))")
        }
        XCTAssertTrue(path.hasSuffix("alpha-skill/trap.txt"), path)
    }

    func testExistingSnapshotRejectsHalfDeletedSnapshots() throws {
        for missingRelativePath in [
            "marketplace/plugins/toastty-user/.claude-plugin",
            "marketplace/plugins/toastty-user/.codex-plugin",
            "marketplace/plugins/toastty-user/.cursor-plugin",
            "marketplace/plugins/toastty-user/skills/alpha-skill",
        ] {
            let fixture = try makeFixture(named: "half-deleted")
            defer { fixture.cleanup() }
            try fixture.writePackage(named: "alpha-skill")
            let snapshot = try XCTUnwrap(fixture.catalog.prepareSnapshot())
            let snapshotRoot = fixture.snapshotsRootURL
                .appendingPathComponent(snapshot.sourceDigest, isDirectory: true)
            try FileManager.default.removeItem(
                at: snapshotRoot.appendingPathComponent(missingRelativePath)
            )

            XCTAssertNil(fixture.catalog.existingSnapshot(), missingRelativePath)
        }
    }

    func testExistingSnapshotRejectsTamperedContentOnFirstVerification() throws {
        let fixture = try makeFixture(named: "tampered-existing")
        defer { fixture.cleanup() }
        try fixture.writePackage(named: "alpha-skill")
        let snapshot = try XCTUnwrap(fixture.catalog.prepareSnapshot())
        try "tampered".write(
            to: snapshot.skillsRootURL.appendingPathComponent("alpha-skill/SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertNil(fixture.catalog.existingSnapshot())
    }

    func testExistingSnapshotMemoizesDigestVerification() throws {
        let fixture = try makeFixture(named: "digest-memo")
        defer { fixture.cleanup() }
        try fixture.writePackage(named: "alpha-skill")
        let prepared = try XCTUnwrap(fixture.catalog.prepareSnapshot())

        let first = try XCTUnwrap(fixture.catalog.existingSnapshot())
        XCTAssertEqual(first.sourceDigest, prepared.sourceDigest)
        // Directory enumeration may standardize /var to /private/var; compare
        // symlink-resolved paths.
        XCTAssertEqual(
            first.pluginRootURL.resolvingSymlinksInPath().path,
            prepared.pluginRootURL.resolvingSymlinksInPath().path
        )

        // Content tampering that keeps the structure intact: a repeat call on
        // the same instance trusts the memoized digest verdict (no recompute),
        // while a fresh instance recomputes and rejects — proving both that
        // the digest check exists and that repeat calls skip it.
        try "tampered extra".write(
            to: first.pluginRootURL.appendingPathComponent("extra.txt"),
            atomically: true,
            encoding: .utf8
        )
        let memoized = try XCTUnwrap(fixture.catalog.existingSnapshot())
        XCTAssertEqual(memoized.sourceDigest, first.sourceDigest)

        let freshCatalog = ToasttyUserSkillCatalog(
            runtimePaths: .resolve(
                homeDirectoryPath: fixture.realHomeURL.path,
                environment: ["TOASTTY_RUNTIME_HOME": fixture.runtimeHomeURL.path]
            )
        )
        XCTAssertNil(freshCatalog.existingSnapshot())
    }

    func testConcurrentPrepareSnapshotCallsBothSucceed() throws {
        let fixture = try makeFixture(named: "concurrent")
        defer { fixture.cleanup() }
        try fixture.writePackage(named: "alpha-skill")

        let finished = expectation(description: "both prepareSnapshot calls returned")
        finished.expectedFulfillmentCount = 2
        let results = SnapshotResultsBox()
        for _ in 0..<2 {
            DispatchQueue.global().async { [catalog = fixture.catalog] in
                results.append(Result { try catalog.prepareSnapshot() })
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 10)

        let snapshots = results.current.map { result -> UserSkillPluginSnapshot? in
            switch result {
            case .success(let snapshot): return snapshot
            case .failure(let error):
                XCTFail("Concurrent prepareSnapshot failed: \(error)")
                return nil
            }
        }
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.compactMap { $0?.sourceDigest }.count, 2)
        XCTAssertEqual(snapshots.first??.sourceDigest, snapshots.last??.sourceDigest)
    }

    func testExistingSnapshotTracksMostRecentlyPreparedAfterContentRevert() throws {
        let fixture = try makeFixture(named: "revert-tracking")
        defer { fixture.cleanup() }
        let packageURL = try fixture.writePackage(named: "alpha-skill")
        let extraURL = packageURL.appendingPathComponent("notes.md")
        try "original".write(to: extraURL, atomically: true, encoding: .utf8)
        let original = try XCTUnwrap(fixture.catalog.prepareSnapshot())

        try "changed".write(to: extraURL, atomically: true, encoding: .utf8)
        let changed = try XCTUnwrap(fixture.catalog.prepareSnapshot())
        XCTAssertNotEqual(changed.sourceDigest, original.sourceDigest)

        // Reverting reuses the original snapshot AND makes it the one
        // `existingSnapshot()` selects, so sync/restored launches deliver the
        // same snapshot async launches prepare.
        try "original".write(to: extraURL, atomically: true, encoding: .utf8)
        let reverted = try XCTUnwrap(fixture.catalog.prepareSnapshot())
        XCTAssertEqual(reverted.sourceDigest, original.sourceDigest)
        XCTAssertEqual(fixture.catalog.existingSnapshot()?.sourceDigest, original.sourceDigest)
    }

    func testCRLFAndBOMFrontmatterAccepted() throws {
        let fixture = try makeFixture(named: "crlf-bom")
        defer { fixture.cleanup() }
        try fixture.writePackage(
            named: "alpha-skill",
            skillFileContents: "\u{FEFF}---\r\nname: alpha-skill\r\ndescription: Test skill.\r\n---\r\n\r\nBody.\r\n"
        )

        let state = fixture.catalog.scan()

        XCTAssertEqual(state.packages.count, 1)
        XCTAssertEqual(state.packages.first?.status, .accepted)
    }

    func testRemovingAllSkillSourcesConvergesSnapshotsAndResolution() throws {
        let fixture = try makeFixture(named: "converge-empty")
        defer { fixture.cleanup() }
        try fixture.writePackage(named: "alpha-skill")
        let snapshot = try XCTUnwrap(fixture.catalog.prepareSnapshot())
        // Compare by digest: directory enumeration may standardize /var to
        // /private/var in the resolved snapshot's URLs.
        XCTAssertEqual(
            fixture.catalog.existingSnapshotResolution().snapshot?.sourceDigest,
            snapshot.sourceDigest
        )

        // The user deletes everything under the skills directory.
        try FileManager.default.removeItem(at: fixture.skillsRootURL)
        try FileManager.default.createDirectory(at: fixture.skillsRootURL, withIntermediateDirectories: true)

        XCTAssertNil(try fixture.catalog.prepareSnapshot())
        // Removed skills stop being deliverable everywhere: no snapshot
        // directories remain, and the resolution is the confirmed-empty one.
        XCTAssertNil(fixture.catalog.existingSnapshot())
        XCTAssertEqual(fixture.catalog.existingSnapshotResolution(), .empty)
        let remaining = (try? FileManager.default.contentsOfDirectory(
            atPath: fixture.snapshotsRootURL.path
        )) ?? []
        XCTAssertEqual(remaining.filter { $0.hasPrefix(".") == false }, [])
    }

    func testUnreadableSourceDirectoryThrowsInsteadOfConverging() throws {
        let fixture = try makeFixture(named: "unreadable-source")
        defer { fixture.cleanup() }
        try fixture.writePackage(named: "alpha-skill")
        let snapshot = try XCTUnwrap(fixture.catalog.prepareSnapshot())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: fixture.skillsRootURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fixture.skillsRootURL.path
            )
        }

        // Unconfirmed emptiness must never converge deliveries: the build
        // fails with a typed error and the snapshot store stays intact.
        XCTAssertThrowsError(try fixture.catalog.prepareSnapshot()) { error in
            XCTAssertEqual(
                error as? ToasttyUserSkillCatalogError,
                .sourceUnreadable(fixture.skillsRootURL.path)
            )
        }
        XCTAssertEqual(
            fixture.catalog.existingSnapshotResolution().snapshot?.sourceDigest,
            snapshot.sourceDigest
        )
    }

    func testExistingSnapshotResolutionDistinguishesUnverifiableFromAbsent() throws {
        let fixture = try makeFixture(named: "resolution-tri-state")
        defer { fixture.cleanup() }
        try fixture.writePackage(named: "alpha-skill")
        let snapshot = try XCTUnwrap(fixture.catalog.prepareSnapshot())
        let snapshotRoot = fixture.snapshotsRootURL
            .appendingPathComponent(snapshot.sourceDigest, isDirectory: true)

        // Structurally broken but present: `.unavailable` (never a
        // destructive convergence trigger).
        try FileManager.default.removeItem(
            at: snapshotRoot.appendingPathComponent("marketplace/plugins/toastty-user/.claude-plugin")
        )
        XCTAssertEqual(fixture.catalog.existingSnapshotResolution(), .unavailable)

        // Entirely absent: confirmed `.empty`.
        try FileManager.default.removeItem(at: snapshotRoot)
        XCTAssertEqual(fixture.catalog.existingSnapshotResolution(), .empty)
    }

    func testExistingSnapshotResolutionTreatsUnreadableStoreAsUnavailable() throws {
        let fixture = try makeFixture(named: "unreadable-store")
        defer { fixture.cleanup() }
        try fixture.writePackage(named: "alpha-skill")
        _ = try XCTUnwrap(fixture.catalog.prepareSnapshot())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: fixture.snapshotsRootURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fixture.snapshotsRootURL.path
            )
        }

        // Present but unreadable is `.unavailable`, never the destructive
        // `.empty` (the manager leaves delivered state untouched for
        // `.unavailable`, see testUnavailableResolutionLeavesDeliveredUserStateUntouchedAndDelivers).
        XCTAssertEqual(fixture.catalog.existingSnapshotResolution(), .unavailable)
    }

    func testHiddenEntriesInsidePackagesAreIgnoredEverywhere() throws {
        let cleanFixture = try makeFixture(named: "hidden-clean")
        defer { cleanFixture.cleanup() }
        let cleanPackageURL = try cleanFixture.writePackage(named: "alpha-skill")
        try "visible notes".write(
            to: cleanPackageURL.appendingPathComponent("notes.md"),
            atomically: true,
            encoding: .utf8
        )
        let cleanSnapshot = try XCTUnwrap(cleanFixture.catalog.prepareSnapshot())

        let hiddenFixture = try makeFixture(named: "hidden-noisy")
        defer { hiddenFixture.cleanup() }
        let hiddenPackageURL = try hiddenFixture.writePackage(named: "alpha-skill")
        try "visible notes".write(
            to: hiddenPackageURL.appendingPathComponent("notes.md"),
            atomically: true,
            encoding: .utf8
        )
        try "junk".write(
            to: hiddenPackageURL.appendingPathComponent(".DS_Store"),
            atomically: true,
            encoding: .utf8
        )
        let gitDirectoryURL = hiddenPackageURL.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectoryURL, withIntermediateDirectories: true)
        try "[core]\n".write(
            to: gitDirectoryURL.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
        // A hidden file larger than the package cap must not count toward it.
        try Data(repeating: 0x61, count: 6 * 1024 * 1024)
            .write(to: hiddenPackageURL.appendingPathComponent(".filler.bin"))

        let state = hiddenFixture.catalog.scan()
        XCTAssertEqual(state.packages.first?.status, .accepted)

        let hiddenSnapshot = try XCTUnwrap(hiddenFixture.catalog.prepareSnapshot())
        // Hidden entries affect neither the source digest nor the copy.
        XCTAssertEqual(hiddenSnapshot.sourceDigest, cleanSnapshot.sourceDigest)
        let copiedEntries = try FileManager.default.contentsOfDirectory(
            atPath: hiddenSnapshot.skillsRootURL.appendingPathComponent("alpha-skill").path
        )
        XCTAssertEqual(Set(copiedEntries), ["SKILL.md", "notes.md"])
    }

    // MARK: - Live Codex CLI acceptance

    /// Verifies that the real Codex CLI accepts the generated marketplace
    /// fixture and the `0.1.0-<hex12>` prerelease version form, against
    /// throwaway HOME/CODEX_HOME directories only. Skips with a warning when
    /// no real codex binary is available (Toastty shims are not the CLI).
    func testCodexAcceptsGeneratedSnapshotThroughThrowawayInstall() throws {
        guard let codexURL = Self.resolveRealCodexExecutable() else {
            throw XCTSkip("codex is unavailable; skipped live marketplace acceptance check")
        }
        let fixture = try makeFixture(named: "live-cli")
        defer { fixture.cleanup() }
        try fixture.writePackage(named: "alpha-skill")
        let snapshot = try XCTUnwrap(fixture.catalog.prepareSnapshot())

        let throwawayHomeURL = fixture.rootURL.appendingPathComponent("throwaway-home", isDirectory: true)
        let throwawayCodexHomeURL = fixture.rootURL.appendingPathComponent("throwaway-codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: throwawayHomeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: throwawayCodexHomeURL, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = throwawayHomeURL.path
        environment["CODEX_HOME"] = throwawayCodexHomeURL.path
        // npm-installed codex is a `#!/usr/bin/env node` script; make its
        // sibling `node` resolvable from the test process environment.
        let codexBinDirectory = codexURL.deletingLastPathComponent().path
        environment["PATH"] = [codexBinDirectory, environment["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")

        let marketplaceAdd = try runProcess(
            codexURL.path,
            arguments: ["plugin", "marketplace", "add", snapshot.marketplaceRootURL.path, "--json"],
            environment: environment
        )
        XCTAssertEqual(
            marketplaceAdd.status, 0,
            "codex plugin marketplace add failed: \(marketplaceAdd.stdout) \(marketplaceAdd.stderr)"
        )
        XCTAssertTrue(marketplaceAdd.stdout.contains("\"toastty-user\""), marketplaceAdd.stdout)

        let pluginAdd = try runProcess(
            codexURL.path,
            arguments: ["plugin", "add", "toastty-user@toastty-user", "--json"],
            environment: environment
        )
        XCTAssertEqual(
            pluginAdd.status, 0,
            "codex rejected the generated plugin (version \(snapshot.version)): \(pluginAdd.stdout) \(pluginAdd.stderr)"
        )
        XCTAssertTrue(pluginAdd.stdout.contains(snapshot.version), pluginAdd.stdout)
        let cachedVersionURL = throwawayCodexHomeURL
            .appendingPathComponent("plugins/cache/toastty-user/toastty-user", isDirectory: true)
            .appendingPathComponent(snapshot.version, isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: cachedVersionURL.appendingPathComponent("skills/alpha-skill/SKILL.md").path
            )
        )
    }
}

// MARK: - Fixture

private extension ToasttyUserSkillCatalogTests {
    struct Fixture {
        let rootURL: URL
        let realHomeURL: URL
        let runtimeHomeURL: URL
        let catalog: ToasttyUserSkillCatalog
        let removesRootOnCleanup: Bool

        var skillsRootURL: URL {
            runtimeHomeURL.appendingPathComponent("skills", isDirectory: true)
        }

        var snapshotsRootURL: URL {
            runtimeHomeURL.appendingPathComponent("agent-plugins/user", isDirectory: true)
        }

        @discardableResult
        func writePackage(
            named directoryName: String,
            frontmatterName: String? = nil,
            skillFileContents: String? = nil
        ) throws -> URL {
            let packageURL = skillsRootURL.appendingPathComponent(directoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
            let contents = skillFileContents
                ?? "---\nname: \(frontmatterName ?? directoryName)\ndescription: Test skill.\n---\n\nBody.\n"
            try contents.write(
                to: packageURL.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
            return packageURL
        }

        func cleanup() {
            guard removesRootOnCleanup else { return }
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    func makeFixture(
        named name: String,
        rootURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> Fixture {
        let resolvedRootURL = rootURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-user-skills-\(name)-\(UUID().uuidString)", isDirectory: true)
        let realHomeURL = resolvedRootURL.appendingPathComponent("real-home", isDirectory: true)
        let runtimeHomeURL = resolvedRootURL.appendingPathComponent("runtime-home", isDirectory: true)
        try FileManager.default.createDirectory(at: realHomeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: runtimeHomeURL.appendingPathComponent("skills", isDirectory: true),
            withIntermediateDirectories: true
        )
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: realHomeURL.path,
            environment: [
                "TOASTTY_RUNTIME_HOME": runtimeHomeURL.path,
                // The sanctioned hermetic mechanism: user skills follow the
                // real user home by default, so isolated fixtures redirect
                // the source explicitly.
                "TOASTTY_USER_SKILLS_ROOT": runtimeHomeURL
                    .appendingPathComponent("skills", isDirectory: true).path,
            ]
        )
        return Fixture(
            rootURL: resolvedRootURL,
            realHomeURL: realHomeURL,
            runtimeHomeURL: runtimeHomeURL,
            catalog: ToasttyUserSkillCatalog(runtimePaths: runtimePaths, fileManager: fileManager),
            // Volume-hosted fixtures disappear with the volume.
            removesRootOnCleanup: rootURL == nil
        )
    }

    func fileInode(at url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? "0"
    }

    @discardableResult
    func runProcess(
        _ executablePath: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    /// Resolves a real Codex CLI the way the plugin self-test does: honor
    /// `CODEX_BIN`, then search PATH and common install locations, skipping
    /// Toastty-managed agent shims (which intercept `codex` on dev machines).
    static func resolveRealCodexExecutable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let explicit = environment["CODEX_BIN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           explicit.isEmpty == false {
            candidates.append(URL(fileURLWithPath: explicit))
        }
        var searchDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        searchDirectories.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin"])
        let nodeVersionsURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let nodeVersions = try? fileManager.contentsOfDirectory(atPath: nodeVersionsURL.path) {
            for version in nodeVersions.sorted().reversed() {
                searchDirectories.append(
                    nodeVersionsURL.appendingPathComponent("\(version)/bin", isDirectory: true).path
                )
            }
        }
        candidates.append(contentsOf: searchDirectories.map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("codex")
        })
        for candidate in candidates {
            guard fileManager.isExecutableFile(atPath: candidate.path) else { continue }
            guard candidate.resolvingSymlinksInPath().lastPathComponent != "toastty-agent-shim" else {
                continue
            }
            return candidate
        }
        return nil
    }
}

private extension UserSkillCatalogState {
    func package(named name: String) -> UserSkillPackage? {
        packages.first { $0.name == name }
    }
}

/// Replaces the target regular file with a FIFO the moment the validator's
/// readability probe touches it, reproducing a scan-to-copy swap race.
private final class FifoSwappingFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var targetPath: String?
    private var swapped = false

    var swapTargetPath: String? {
        get { lock.withLock { targetPath } }
        set { lock.withLock { targetPath = newValue } }
    }

    override func isReadableFile(atPath path: String) -> Bool {
        let readable = super.isReadableFile(atPath: path)
        let shouldSwap = lock.withLock { () -> Bool in
            guard swapped == false, let targetPath, targetPath == path else { return false }
            swapped = true
            return true
        }
        if shouldSwap {
            try? removeItem(atPath: path)
            _ = mkfifo(path, 0o644)
        }
        return readable
    }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Error?

    func set(_ error: Error) {
        lock.withLock { value = error }
    }

    var current: Error? {
        lock.withLock { value }
    }
}

private final class SnapshotResultsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<UserSkillPluginSnapshot?, Error>] = []

    func append(_ result: Result<UserSkillPluginSnapshot?, Error>) {
        lock.withLock { results.append(result) }
    }

    var current: [Result<UserSkillPluginSnapshot?, Error>] {
        lock.withLock { results }
    }
}
