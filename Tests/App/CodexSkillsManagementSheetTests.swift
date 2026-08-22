import CoreState
import Foundation
import XCTest
@testable import ToasttyApp

final class CodexSkillsManagementSheetTests: XCTestCase {
    func testManagementRowsExposeTheExactFiveQualifiedSkillsAndSummaries() {
        XCTAssertEqual(
            ToasttyAgentPluginBundle.skills.map { "toastty:\($0.name)" },
            [
                "toastty:toastty-capabilities",
                "toastty:toastty-open-markdown",
                "toastty:toastty-scratchpad",
                "toastty:toastty-send-diagnostics",
                "toastty:worktree-create",
            ]
        )
        XCTAssertTrue(ToasttyAgentPluginBundle.skills.allSatisfy { $0.summary.isEmpty == false })
    }

    func testProvisionedNoticeIsClaimedOncePerAgentByItsTargetWindow() throws {
        let suiteName = "toastty-codex-skills-notice-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let targetWindowID = UUID()

        let codexNotice = ManagedAgentSkillsProvisionedNotice(
            windowID: targetWindowID,
            agent: .codex,
            shippedSkillCount: 5,
            deliveredUserSkillCount: 2
        )
        let claudeNotice = ManagedAgentSkillsProvisionedNotice(
            windowID: targetWindowID,
            agent: .claude,
            shippedSkillCount: 5,
            deliveredUserSkillCount: 0
        )

        XCTAssertNil(
            ManagedAgentSkillsProvisionedNoticeStore.claim(
                for: UUID(),
                notificationObject: codexNotice,
                userDefaults: defaults
            )
        )
        XCTAssertEqual(
            ManagedAgentSkillsProvisionedNoticeStore.claim(
                for: targetWindowID,
                notificationObject: codexNotice,
                userDefaults: defaults
            ),
            codexNotice
        )
        XCTAssertNil(
            ManagedAgentSkillsProvisionedNoticeStore.claim(
                for: targetWindowID,
                notificationObject: codexNotice,
                userDefaults: defaults
            )
        )
        XCTAssertEqual(
            ManagedAgentSkillsProvisionedNoticeStore.claim(
                for: targetWindowID,
                notificationObject: claudeNotice,
                userDefaults: defaults
            ),
            claudeNotice
        )
    }

    // MARK: - Provisioned banner wording

    func testProvisionedBannerTitleIdentifiesTheManagedAgent() {
        XCTAssertEqual(
            ManagedAgentSkillsProvisionedBanner.title(for: .codex),
            "Toastty skills are now available in Codex"
        )
        XCTAssertEqual(
            ManagedAgentSkillsProvisionedBanner.title(for: .claude),
            "Toastty skills are now available in Claude Code"
        )
        XCTAssertEqual(
            ManagedAgentSkillsProvisionedBanner.title(for: .pi),
            "Toastty skills are now available in Pi"
        )
        XCTAssertEqual(
            ManagedAgentSkillsProvisionedBanner.title(for: .opencode),
            "Toastty skills are now available in OpenCode"
        )
        XCTAssertEqual(
            ManagedAgentSkillsProvisionedBanner.title(for: .mimocode),
            "Toastty skills are now available in MiMo Code"
        )
    }

    func testProvisionedBannerMessageForShippedOnlyLaunch() {
        XCTAssertEqual(
            ManagedAgentSkillsProvisionedBanner.message(
                for: ManagedAgentSkillsProvisionedNotice(
                    windowID: UUID(),
                    agent: .codex,
                    shippedSkillCount: 5,
                    deliveredUserSkillCount: 0
                )
            ),
            "Toastty enabled 5 skills for managed Codex sessions. Global and project skill folders were not changed."
        )
    }

    func testProvisionedBannerMessageIncludesDeliveredUserSkillCount() {
        XCTAssertEqual(
            ManagedAgentSkillsProvisionedBanner.message(
                for: ManagedAgentSkillsProvisionedNotice(
                    windowID: UUID(),
                    agent: .codex,
                    shippedSkillCount: 5,
                    deliveredUserSkillCount: 2
                )
            ),
            "Toastty enabled 7 skills for managed Codex sessions (including 2 user skills). Global and project skill folders were not changed."
        )
        XCTAssertEqual(
            ManagedAgentSkillsProvisionedBanner.message(
                for: ManagedAgentSkillsProvisionedNotice(
                    windowID: UUID(),
                    agent: .claude,
                    shippedSkillCount: 5,
                    deliveredUserSkillCount: 1
                )
            ),
            "Toastty enabled 6 skills for managed Claude Code sessions (including 1 user skill). Global and project skill folders were not changed."
        )
    }

    @MainActor
    func testDeliveredUserSkillCountRequiresCodexDeliveredOutcome() {
        let snapshot = makeSnapshot(packageNames: ["alpha-skill", "beta-skill"])

        XCTAssertEqual(
            ManagedAgentLaunchPlanner.deliveredUserSkillCount(
                agent: .codex,
                codexUserSkills: .delivered(version: "0.1.0-abc", contentDigest: "d"),
                userSkillSnapshot: snapshot
            ),
            2
        )
        XCTAssertEqual(
            ManagedAgentLaunchPlanner.deliveredUserSkillCount(
                agent: .codex,
                codexUserSkills: .notDelivered,
                userSkillSnapshot: snapshot
            ),
            0
        )
        XCTAssertEqual(
            ManagedAgentLaunchPlanner.deliveredUserSkillCount(
                agent: .claude,
                codexUserSkills: nil,
                userSkillSnapshot: snapshot
            ),
            2
        )
        XCTAssertEqual(
            ManagedAgentLaunchPlanner.deliveredUserSkillCount(
                agent: .claude,
                codexUserSkills: nil,
                userSkillSnapshot: nil
            ),
            0
        )
    }

    // MARK: - Launch-provided delivery row (Claude Code, Pi, OpenCode, MiMo Code)

    func testLaunchDeliveryStatusTitleForEachState() {
        XCTAssertEqual(
            ToasttySkillsManagementSheet.launchDeliveryStatusTitle(
                for: .providedAtLaunch(makeLaunchConfiguration(version: "0.1.0-abc"))
            ),
            "Provided at launch"
        )
        XCTAssertEqual(
            ToasttySkillsManagementSheet.launchDeliveryStatusTitle(
                for: .stagesOnNextLaunch(version: "0.2.0-def")
            ),
            "Stages on next launch"
        )
        XCTAssertEqual(
            ToasttySkillsManagementSheet.launchDeliveryStatusTitle(
                for: .unavailable(detail: "Toastty could not verify the staged skills plugin.")
            ),
            "Needs attention"
        )
        XCTAssertEqual(
            ToasttySkillsManagementSheet.launchDeliveryStatusTitle(for: nil),
            "Checking"
        )
    }

    func testDeliveredSkillsVersionPrefersStagedSkillsVersion() {
        let codexStatus = makeCodexStatus(bundledVersion: "0.3.0")

        XCTAssertEqual(
            ToasttySkillsManagementSheet.deliveredSkillsVersion(
                claudeStatus: .providedAtLaunch(makeLaunchConfiguration(version: "0.1.0-abc")),
                codexStatus: codexStatus
            ),
            "0.1.0-abc"
        )
        XCTAssertEqual(
            ToasttySkillsManagementSheet.deliveredSkillsVersion(
                claudeStatus: .stagesOnNextLaunch(version: "0.2.0-def"),
                codexStatus: codexStatus
            ),
            "0.2.0-def"
        )
    }

    func testDeliveredSkillsVersionFallsBackToCodexBundledVersion() {
        XCTAssertEqual(
            ToasttySkillsManagementSheet.deliveredSkillsVersion(
                claudeStatus: .unavailable(detail: "broken"),
                codexStatus: makeCodexStatus(bundledVersion: "0.3.0")
            ),
            "0.3.0"
        )
        XCTAssertEqual(
            ToasttySkillsManagementSheet.deliveredSkillsVersion(
                claudeStatus: nil,
                codexStatus: makeCodexStatus(bundledVersion: "0.3.0")
            ),
            "0.3.0"
        )
        XCTAssertNil(
            ToasttySkillsManagementSheet.deliveredSkillsVersion(
                claudeStatus: nil,
                codexStatus: nil
            )
        )
    }

    // MARK: - Duplicate-skills guidance copy

    func testDuplicateSkillsGuidanceStaysConciseAndNamesDeliveredHosts() {
        let guidance = ToasttySkillsManagementSheet.duplicateSkillsGuidanceText

        // Only the hosts Toastty actually delivers skills to are named, and
        // the note stays short enough to read at a glance in the sheet.
        XCTAssertTrue(guidance.contains("~/.codex/skills"))
        XCTAssertTrue(guidance.contains("~/.claude/skills"))
        XCTAssertTrue(guidance.contains("~/.agents/skills"))
        XCTAssertTrue(guidance.contains("never changes global skill folders"))
        XCTAssertFalse(guidance.contains(".pi/skills"))
        XCTAssertFalse(guidance.contains(".opencode/skills"))
        XCTAssertLessThan(guidance.count, 220)
    }

    // MARK: - User skills section model

    @MainActor
    func testUserSkillsModelReflectsAcceptedAndExcludedPackages() async {
        let state = makeCatalogState(packages: [
            makePackage(name: "alpha-skill", status: .accepted),
            makePackage(name: "beta-skill", status: .excluded(.missingSkillFile)),
            makePackage(name: "gamma-skill", status: .accepted),
        ])
        let model = makeModel(scan: { state })

        model.refresh()
        await model.waitForPendingWork()

        XCTAssertEqual(model.catalogState, state)
        XCTAssertEqual(model.sectionTitle, "User Skills — 2 included")
        XCTAssertEqual(
            UserSkillsManagementModel.statusDescription(for: state.packages[0]),
            "Included"
        )
        XCTAssertEqual(
            UserSkillsManagementModel.statusDescription(for: state.packages[1]),
            UserSkillDiagnostic.missingSkillFile.displayMessage
        )
        XCTAssertNil(model.snapshotDigest)
        XCTAssertFalse(model.isWorking)
    }

    @MainActor
    func testUserSkillsModelEmptyCatalogState() async {
        let emptyState = makeCatalogState(packages: [])
        let model = makeModel(scan: { emptyState })

        model.refresh()
        await model.waitForPendingWork()

        XCTAssertEqual(model.sectionTitle, "User Skills")
        XCTAssertEqual(model.acceptedCount, 0)
        XCTAssertNil(model.snapshotDigest)
    }

    @MainActor
    func testUserSkillsModelSnapshotDigestFromVerifiedSnapshot() async {
        let snapshot = makeSnapshot(
            packageNames: ["alpha-skill"],
            pluginContentDigest: "abcdef1234567890"
        )
        let acceptedState = makeCatalogState(packages: [
            makePackage(name: "alpha-skill", status: .accepted),
        ])
        let model = makeModel(
            scan: { acceptedState },
            existingSnapshot: { snapshot }
        )

        model.refresh()
        await model.waitForPendingWork()

        XCTAssertEqual(model.snapshotDigest, "abcdef1234567890")
    }

    @MainActor
    func testUserSkillsModelRescanShowsNoUserSkillsAfterSourcesRemoved() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-sheet-user-converge-\(UUID().uuidString)", isDirectory: true)
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
        _ = try XCTUnwrap(catalog.prepareSnapshot())
        let model = UserSkillsManagementModel(catalog: catalog, revealFolder: { _ in })

        model.refresh()
        await model.waitForPendingWork()
        XCTAssertNotNil(model.snapshotDigest)

        // The user deletes every skill and hits Rescan: the sheet converges
        // to the no-user-skills state instead of advertising the removed set.
        try FileManager.default.removeItem(at: packageURL)
        model.rescan()
        await model.waitForPendingWork()

        XCTAssertNil(model.snapshotDigest)
        XCTAssertEqual(model.acceptedCount, 0)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testRescanInvokesRefreshExactlyOnceAndRescans() async {
        let counter = InvocationCounter()
        let acceptedState = makeCatalogState(packages: [
            makePackage(name: "alpha-skill", status: .accepted),
        ])
        let model = makeModel(
            scan: {
                counter.increment(\.scans)
                return acceptedState
            },
            refresh: {
                counter.increment(\.refreshes)
                return nil
            }
        )

        model.refresh()
        await model.waitForPendingWork()
        let scansBeforeRescan = counter.counts.scans
        XCTAssertEqual(counter.counts.refreshes, 0)

        model.rescan()
        await model.waitForPendingWork()

        XCTAssertEqual(counter.counts.refreshes, 1)
        XCTAssertGreaterThan(counter.counts.scans, scansBeforeRescan)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isWorking)
    }

    @MainActor
    func testRescanSkipsRefreshWhenNothingAcceptedAndNoSnapshotExists() async {
        let counter = InvocationCounter()
        let excludedState = makeCatalogState(packages: [
            makePackage(name: "beta-skill", status: .excluded(.invalidFrontmatter)),
        ])
        let model = makeModel(
            scan: { excludedState },
            refresh: {
                counter.increment(\.refreshes)
                return nil
            }
        )

        model.rescan()
        await model.waitForPendingWork()

        XCTAssertEqual(counter.counts.refreshes, 0)
    }

    @MainActor
    func testRescanRefreshesWhenSnapshotExistsEvenWithoutAcceptedPackages() async {
        let counter = InvocationCounter()
        let snapshot = makeSnapshot(packageNames: ["alpha-skill"])
        let emptyState = makeCatalogState(packages: [])
        let model = makeModel(
            scan: { emptyState },
            existingSnapshot: { snapshot },
            refresh: {
                counter.increment(\.refreshes)
                return nil
            }
        )

        model.rescan()
        await model.waitForPendingWork()

        XCTAssertEqual(counter.counts.refreshes, 1)
    }

    @MainActor
    func testRescanSurfacesRefreshFailureAsErrorMessage() async {
        let acceptedState = makeCatalogState(packages: [
            makePackage(name: "alpha-skill", status: .accepted),
        ])
        let model = makeModel(
            scan: { acceptedState },
            refresh: {
                throw ToasttyUserSkillCatalogError.snapshotWriteFailed("/tmp/user-skills")
            }
        )

        model.rescan()
        await model.waitForPendingWork()

        XCTAssertEqual(
            model.errorMessage,
            ToasttyUserSkillCatalogError.snapshotWriteFailed("/tmp/user-skills").localizedDescription
        )
    }

    @MainActor
    func testCreateSkillsFolderAffordanceOnlyOfferedWhenDirectoryMissing() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-user-skills-sheet-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        var revealedURLs: [URL] = []
        let model = makeModel(
            userSkillsDirectoryURL: directoryURL,
            revealFolder: { revealedURLs.append($0) }
        )

        model.refresh()
        await model.waitForPendingWork()
        XCTAssertTrue(model.showsCreateFolderAffordance)

        model.createUserSkillsFolder()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory)
        )
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertFalse(model.showsCreateFolderAffordance)
        XCTAssertEqual(revealedURLs.map(\.path), [directoryURL.path])

        model.refresh()
        await model.waitForPendingWork()
        XCTAssertFalse(model.showsCreateFolderAffordance)
    }

    // MARK: - Fixtures

    @MainActor
    private func makeModel(
        userSkillsDirectoryURL: URL = URL(
            fileURLWithPath: "/nonexistent/toastty-user-skills-fixture",
            isDirectory: true
        ),
        scan: @escaping @Sendable () -> UserSkillCatalogState = {
            UserSkillCatalogState(packages: [], globalDiagnostics: [], sourceFingerprint: "fp")
        },
        existingSnapshot: @escaping @Sendable () -> UserSkillPluginSnapshot? = { nil },
        refresh: @escaping @Sendable () throws -> UserSkillPluginSnapshot? = { nil },
        revealFolder: (@MainActor (URL) -> Void)? = { _ in }
    ) -> UserSkillsManagementModel {
        UserSkillsManagementModel(
            userSkillsDirectoryURL: userSkillsDirectoryURL,
            scanProvider: scan,
            existingSnapshotProvider: existingSnapshot,
            refreshProvider: refresh,
            revealFolder: revealFolder
        )
    }

    private func makeLaunchConfiguration(version: String) -> ClaudeSkillsLaunchConfiguration {
        ClaudeSkillsLaunchConfiguration(
            pluginRootPath: "/tmp/plugin",
            skillsRootPath: "/tmp/plugin/skills",
            version: version,
            contentDigest: "digest"
        )
    }

    private func makeCodexStatus(bundledVersion: String?) -> CodexSkillsStatus {
        CodexSkillsStatus(
            availability: .ready,
            detail: "Ready.",
            bundledVersion: bundledVersion,
            installedVersion: bundledVersion,
            bundledDigest: "digest",
            installedDigest: "digest",
            cachePath: "/tmp/plugin-cache",
            profileConfigPath: "/tmp/profile.toml",
            updatePending: false,
            repairPending: false,
            hasActiveManagedSession: false
        )
    }

    private func makeCatalogState(packages: [UserSkillPackage]) -> UserSkillCatalogState {
        UserSkillCatalogState(
            packages: packages,
            globalDiagnostics: [],
            sourceFingerprint: "fp"
        )
    }

    private func makePackage(
        name: String,
        status: UserSkillPackage.Status
    ) -> UserSkillPackage {
        UserSkillPackage(
            name: name,
            sourceURL: URL(fileURLWithPath: "/tmp/user-skills/\(name)", isDirectory: true),
            status: status
        )
    }

    private func makeSnapshot(
        packageNames: [String],
        pluginContentDigest: String = "abcdef1234567890"
    ) -> UserSkillPluginSnapshot {
        let rootURL = URL(fileURLWithPath: "/tmp/toastty-user-snapshot", isDirectory: true)
        return UserSkillPluginSnapshot(
            pluginName: UserSkillPluginSnapshot.pluginName,
            version: "0.1.0-abcdef123456",
            sourceDigest: "abcdef123456",
            pluginContentDigest: pluginContentDigest,
            pluginRootURL: rootURL,
            marketplaceRootURL: rootURL,
            skillsRootURL: rootURL.appendingPathComponent("skills", isDirectory: true),
            receiptURL: rootURL.appendingPathComponent("receipt.json"),
            acceptedPackageNames: packageNames
        )
    }
}

/// Thread-safe invocation counter for providers that run off the main actor.
private final class InvocationCounter: @unchecked Sendable {
    struct Counts {
        var scans = 0
        var refreshes = 0
    }

    private let lock = NSLock()
    private var storage = Counts()

    var counts: Counts {
        lock.withLock { storage }
    }

    func increment(_ keyPath: WritableKeyPath<Counts, Int>) {
        lock.withLock {
            storage[keyPath: keyPath] += 1
        }
    }
}
