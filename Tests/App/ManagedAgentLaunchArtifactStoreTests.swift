import CoreState
import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyApp

final class ManagedAgentLaunchArtifactStoreTests: XCTestCase {
    func testProcessLifetimeArtifactsUsePrivateDurableDirectory() throws {
        let fixture = try makeFixture()
        defer { try? fixture.fileManager.removeItem(at: fixture.root.deletingLastPathComponent()) }

        let sessionID = UUID().uuidString
        let artifacts = try fixture.store.makeDirectory(
            agent: .claude,
            sessionID: sessionID,
            lifetime: .agentProcess
        )

        XCTAssertEqual(artifacts.storage, .durable)
        XCTAssertEqual(artifacts.lifetime, .agentProcess)
        XCTAssertEqual(
            artifacts.directoryURL.path,
            fixture.root.appendingPathComponent("toastty-claude-launch-\(sessionID)").path
        )
        XCTAssertEqual(try permissions(at: fixture.root), 0o700)
        XCTAssertEqual(try permissions(at: artifacts.directoryURL), 0o700)
        XCTAssertEqual(
            try permissions(at: artifacts.directoryURL.appendingPathComponent(
                ManagedAgentLaunchArtifactStore.metadataFileName
            )),
            0o600
        )
    }

    func testSessionLifetimeArtifactsRemainTemporary() throws {
        let fixture = try makeFixture()
        let sessionID = UUID().uuidString
        let artifacts = try fixture.store.makeDirectory(
            agent: .opencode,
            sessionID: sessionID,
            lifetime: .session
        )
        defer { try? fixture.fileManager.removeItem(at: artifacts.directoryURL) }

        XCTAssertEqual(artifacts.storage, .temporary)
        XCTAssertNil(artifacts.ownerRecordURL)
        XCTAssertFalse(artifacts.directoryURL.path.hasPrefix(fixture.root.path + "/"))
    }

    func testDurableRootFailureFallsBackToTemporaryStorage() throws {
        let fileManager = FileManager.default
        let parent = fileManager.temporaryDirectory.appendingPathComponent(
            "toastty-artifact-store-symlink-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let target = parent.appendingPathComponent("target", isDirectory: true)
        let root = parent.appendingPathComponent("managed-agent-launches", isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: root, withDestinationURL: target)
        defer { try? fileManager.removeItem(at: parent) }

        let store = ManagedAgentLaunchArtifactStore(rootDirectoryURL: root)
        let sessionID = UUID().uuidString
        let artifacts = try store.makeDirectory(
            agent: .grok,
            sessionID: sessionID,
            lifetime: .agentProcess
        )
        defer { try? fileManager.removeItem(at: artifacts.directoryURL) }

        XCTAssertEqual(artifacts.storage, .temporary)
        XCTAssertFalse(artifacts.directoryURL.path.hasPrefix(root.path + "/"))
        let hooks = target.appendingPathComponent("hooks", isDirectory: true)
        try fileManager.createDirectory(at: hooks, withIntermediateDirectories: false)
        let linkURL = hooks.appendingPathComponent("toastty-\(sessionID).json")
        XCTAssertThrowsError(try store.registerGrokHookLink(artifacts: artifacts, linkURL: linkURL))
        XCTAssertFalse(pathExistsIncludingSymlink(linkURL))
    }

    func testSweepDeletesOnlyInactiveArtifactsWithProvenDeadOwner() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let deadPID: Int32 = 41001
        let livePID: Int32 = 41002
        let unknownPID: Int32 = 41003
        let fixture = try makeFixture(
            now: now,
            ownerProcessStateProvider: { processID in
                switch processID {
                case deadPID: return .dead
                case livePID: return .alive
                default: return .unknown
                }
            }
        )
        defer { try? fixture.fileManager.removeItem(at: fixture.root.deletingLastPathComponent()) }

        let dead = try makeOwnedArtifacts(pid: deadPID, fixture: fixture)
        let active = try makeOwnedArtifacts(pid: deadPID, fixture: fixture)
        let live = try makeOwnedArtifacts(pid: livePID, fixture: fixture)
        let unknown = try makeOwnedArtifacts(pid: unknownPID, fixture: fixture)
        let missingOwner = try fixture.store.makeDirectory(
            agent: .codex,
            sessionID: UUID().uuidString,
            lifetime: .agentProcess
        )

        fixture.store.sweep(activeSessionIDs: [active.sessionID])

        XCTAssertFalse(fixture.fileManager.fileExists(atPath: dead.artifacts.directoryURL.path))
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: active.artifacts.directoryURL.path))
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: live.artifacts.directoryURL.path))
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: unknown.artifacts.directoryURL.path))
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: missingOwner.directoryURL.path))
    }

    func testSweepPreservesAnyLivePIDRatherThanGuessingAboutReuse() throws {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let fixture = try makeFixture(
            now: Date(timeIntervalSince1970: 10_000),
            ownerProcessStateProvider: { _ in .alive }
        )
        defer { try? fixture.fileManager.removeItem(at: fixture.root.deletingLastPathComponent()) }

        let owned = try makeOwnedArtifacts(pid: 42001, observedAt: observedAt, fixture: fixture)
        fixture.store.sweep(activeSessionIDs: [])

        XCTAssertTrue(fixture.fileManager.fileExists(atPath: owned.artifacts.directoryURL.path))
    }

    func testSweepPreservesRecentOwnerRecordDuringGracePeriod() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let fixture = try makeFixture(
            now: now,
            ownerProcessStateProvider: { _ in .dead },
            cleanupGraceInterval: 600
        )
        defer { try? fixture.fileManager.removeItem(at: fixture.root.deletingLastPathComponent()) }

        let owned = try makeOwnedArtifacts(
            pid: 43001,
            observedAt: now.addingTimeInterval(-599),
            fixture: fixture
        )
        fixture.store.sweep(activeSessionIDs: [])

        XCTAssertTrue(fixture.fileManager.fileExists(atPath: owned.artifacts.directoryURL.path))
    }

    func testSweepPreservesSymlinkOwnerRecord() throws {
        let fixture = try makeFixture(
            now: Date(timeIntervalSince1970: 10_000),
            ownerProcessStateProvider: { _ in .dead },
            cleanupGraceInterval: 0
        )
        defer { try? fixture.fileManager.removeItem(at: fixture.root.deletingLastPathComponent()) }

        let artifacts = try fixture.store.makeDirectory(
            agent: .codex,
            sessionID: UUID().uuidString,
            lifetime: .agentProcess
        )
        let externalOwnerURL = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("external-owner", isDirectory: false)
        try "44001\n".write(to: externalOwnerURL, atomically: true, encoding: .utf8)
        let ownerURL = try XCTUnwrap(artifacts.ownerRecordURL)
        try fixture.fileManager.createSymbolicLink(at: ownerURL, withDestinationURL: externalOwnerURL)

        fixture.store.sweep(activeSessionIDs: [])

        XCTAssertTrue(fixture.fileManager.fileExists(atPath: artifacts.directoryURL.path))
    }

    func testGrokHookLinksAreIndependentAndAbandonedLaunchOnlyRemovesItsOwnLink() throws {
        let fixture = try makeFixture(directoryPrefix: "grok launch '", createParentDirectory: true)
        defer { try? fixture.fileManager.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let first = try makeGrokArtifactsAndLink(fixture: fixture)
        let second = try makeGrokArtifactsAndLink(fixture: fixture)

        XCTAssertEqual(
            try fixture.fileManager.destinationOfSymbolicLink(atPath: first.linkURL.path),
            first.artifacts.directoryURL.appendingPathComponent("hooks.json").path
        )
        fixture.store.removeAbandoned(first.artifacts)

        XCTAssertFalse(pathExistsIncludingSymlink(first.linkURL))
        XCTAssertFalse(pathExistsIncludingSymlink(first.artifacts.directoryURL))
        XCTAssertTrue(pathExistsIncludingSymlink(second.linkURL))
        XCTAssertTrue(pathExistsIncludingSymlink(second.artifacts.directoryURL))
    }

    func testGrokHookSweepPreservesActiveLiveUnknownAndMalformedOwners() throws {
        let fixture = try makeFixture(
            now: Date(timeIntervalSince1970: 10_000),
            ownerProcessStateProvider: { pid in
                switch pid {
                case 45001: return .dead
                case 45002: return .alive
                default: return .unknown
                }
            }
        )
        defer { try? fixture.fileManager.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let dead = try makeGrokArtifactsAndLink(pid: "45001", fixture: fixture)
        let active = try makeGrokArtifactsAndLink(pid: "45001", fixture: fixture)
        let live = try makeGrokArtifactsAndLink(pid: "45002", fixture: fixture)
        let unknown = try makeGrokArtifactsAndLink(pid: "45003", fixture: fixture)
        let malformed = try makeGrokArtifactsAndLink(pid: "invalid", fixture: fixture)
        let missing = try makeGrokArtifactsAndLink(fixture: fixture)

        fixture.store.sweep(activeSessionIDs: [active.sessionID])

        XCTAssertFalse(pathExistsIncludingSymlink(dead.linkURL))
        XCTAssertFalse(pathExistsIncludingSymlink(dead.artifacts.directoryURL))
        for retained in [active, live, unknown, malformed, missing] {
            XCTAssertTrue(pathExistsIncludingSymlink(retained.linkURL))
            XCTAssertTrue(pathExistsIncludingSymlink(retained.artifacts.directoryURL))
        }
    }

    func testGrokHookCleanupPreservesReplacementLinkAndRegularFile() throws {
        let fixture = try makeFixture(
            now: Date(timeIntervalSince1970: 10_000),
            ownerProcessStateProvider: { _ in .dead }
        )
        defer { try? fixture.fileManager.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let replacedLink = try makeGrokArtifactsAndLink(pid: "45001", fixture: fixture)
        let replacedFile = try makeGrokArtifactsAndLink(fixture: fixture)
        let otherTarget = fixture.root.deletingLastPathComponent().appendingPathComponent("user-hooks.json")
        try "user hooks".write(to: otherTarget, atomically: true, encoding: .utf8)
        try fixture.fileManager.removeItem(at: replacedLink.linkURL)
        try fixture.fileManager.createSymbolicLink(at: replacedLink.linkURL, withDestinationURL: otherTarget)
        try fixture.fileManager.removeItem(at: replacedFile.linkURL)
        try "replacement".write(to: replacedFile.linkURL, atomically: true, encoding: .utf8)

        fixture.store.sweep(activeSessionIDs: [])
        fixture.store.removeAbandoned(replacedFile.artifacts)

        XCTAssertEqual(try fixture.fileManager.destinationOfSymbolicLink(atPath: replacedLink.linkURL.path), otherTarget.path)
        XCTAssertEqual(try String(contentsOf: replacedFile.linkURL, encoding: .utf8), "replacement")
        XCTAssertFalse(pathExistsIncludingSymlink(replacedLink.artifacts.directoryURL))
        XCTAssertFalse(pathExistsIncludingSymlink(replacedFile.artifacts.directoryURL))
    }

    func testGrokCleanupRetainsOwnershipWhenUnlinkFailsAndRetriesLater() throws {
        let fixture = try makeFixture(
            now: Date(timeIntervalSince1970: 10_000),
            ownerProcessStateProvider: { _ in .dead }
        )
        defer { try? fixture.fileManager.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let stopped = try makeGrokArtifactsAndLink(pid: "45001", fixture: fixture)
        let abandoned = try makeGrokArtifactsAndLink(fixture: fixture)
        let hooks = stopped.linkURL.deletingLastPathComponent()
        let originalPermissions = try permissions(at: hooks)
        defer {
            try? fixture.fileManager.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: hooks.path)
        }
        try fixture.fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: hooks.path)

        fixture.store.sweep(activeSessionIDs: [])
        fixture.store.removeAbandoned(abandoned.artifacts)

        for retained in [stopped, abandoned] {
            XCTAssertTrue(pathExistsIncludingSymlink(retained.linkURL))
            XCTAssertTrue(pathExistsIncludingSymlink(retained.artifacts.directoryURL))
            XCTAssertTrue(pathExistsIncludingSymlink(retained.artifacts.directoryURL.appendingPathComponent(
                ManagedAgentLaunchArtifactStore.metadataFileName
            )))
        }

        try fixture.fileManager.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: hooks.path)
        fixture.store.sweep(activeSessionIDs: [])
        fixture.store.removeAbandoned(abandoned.artifacts)

        for removed in [stopped, abandoned] {
            XCTAssertFalse(pathExistsIncludingSymlink(removed.linkURL))
            XCTAssertFalse(pathExistsIncludingSymlink(removed.artifacts.directoryURL))
        }
    }

    func testGrokSweepRemovesDeadOwnerLinkBeforeDirectoryGraceExpires() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let fixture = try makeFixture(now: now, ownerProcessStateProvider: { _ in .dead })
        defer { try? fixture.fileManager.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let owned = try makeGrokArtifactsAndLink(pid: "45001", fixture: fixture)
        let ownerURL = try XCTUnwrap(owned.artifacts.ownerRecordURL)
        try fixture.fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-1)], ofItemAtPath: ownerURL.path)

        fixture.store.sweep(activeSessionIDs: [])

        XCTAssertFalse(pathExistsIncludingSymlink(owned.linkURL))
        XCTAssertTrue(pathExistsIncludingSymlink(owned.artifacts.directoryURL))
        let laterStore = ManagedAgentLaunchArtifactStore(
            rootDirectoryURL: fixture.root,
            nowProvider: { now.addingTimeInterval(600) },
            ownerProcessStateProvider: { _ in .dead }
        )

        laterStore.sweep(activeSessionIDs: [])

        XCTAssertFalse(pathExistsIncludingSymlink(owned.artifacts.directoryURL))
    }

    func testGrokHookRegistrationDoesNotOverwriteExistingFileOrDanglingLink() throws {
        let fixture = try makeFixture()
        defer { try? fixture.fileManager.removeItem(at: fixture.root.deletingLastPathComponent()) }
        for existingIsLink in [false, true] {
            let sessionID = UUID().uuidString
            let artifacts = try fixture.store.makeDirectory(agent: .grok, sessionID: sessionID, lifetime: .agentProcess)
            let hooks = fixture.root.deletingLastPathComponent().appendingPathComponent("hooks", isDirectory: true)
            try fixture.fileManager.createDirectory(at: hooks, withIntermediateDirectories: true)
            let linkURL = hooks.appendingPathComponent("toastty-\(sessionID).json")
            let missingTarget = hooks.appendingPathComponent("missing.json")
            if existingIsLink {
                try fixture.fileManager.createSymbolicLink(at: linkURL, withDestinationURL: missingTarget)
            } else {
                try "existing".write(to: linkURL, atomically: true, encoding: .utf8)
            }

            XCTAssertThrowsError(try fixture.store.registerGrokHookLink(artifacts: artifacts, linkURL: linkURL))
            fixture.store.removeAbandoned(artifacts)

            if existingIsLink {
                XCTAssertEqual(try fixture.fileManager.destinationOfSymbolicLink(atPath: linkURL.path), missingTarget.path)
            } else {
                XCTAssertEqual(try String(contentsOf: linkURL, encoding: .utf8), "existing")
            }
        }
    }

    func testGrokHookRegistrationRejectsTemporaryStorageAndUnsafePaths() throws {
        let fixture = try makeFixture()
        defer { try? fixture.fileManager.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let sessionID = UUID().uuidString
        let temporary = try fixture.store.makeDirectory(agent: .grok, sessionID: sessionID, lifetime: .session)
        defer { try? fixture.fileManager.removeItem(at: temporary.directoryURL) }
        let durable = try fixture.store.makeDirectory(agent: .grok, sessionID: sessionID, lifetime: .agentProcess)
        let hooks = fixture.root.deletingLastPathComponent().appendingPathComponent("hooks", isDirectory: true)
        try fixture.fileManager.createDirectory(at: hooks, withIntermediateDirectories: true)
        let validLinkURL = hooks.appendingPathComponent("toastty-\(sessionID).json")
        XCTAssertThrowsError(try fixture.store.registerGrokHookLink(artifacts: temporary, linkURL: validLinkURL))
        XCTAssertThrowsError(try fixture.store.registerGrokHookLink(artifacts: durable, linkURL: hooks.appendingPathComponent("other.json")))
        let alias = fixture.root.deletingLastPathComponent().appendingPathComponent("alias", isDirectory: true)
        try fixture.fileManager.createDirectory(at: alias, withIntermediateDirectories: false)
        let aliasHooks = alias.appendingPathComponent("hooks", isDirectory: true)
        try fixture.fileManager.createSymbolicLink(at: aliasHooks, withDestinationURL: hooks)
        XCTAssertThrowsError(try fixture.store.registerGrokHookLink(artifacts: durable, linkURL: aliasHooks.appendingPathComponent("toastty-\(sessionID).json")))
        XCTAssertFalse(pathExistsIncludingSymlink(validLinkURL))
    }

    func testFailedGrokHookCreationRollsBackOwnershipWithoutRemovingCompetingLink() throws {
        let fileManager = CompetingHookLinkFileManager()
        let fixture = try makeFixture(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let sessionID = UUID().uuidString
        let artifacts = try fixture.store.makeDirectory(agent: .grok, sessionID: sessionID, lifetime: .agentProcess)
        let hooks = fixture.root.deletingLastPathComponent().appendingPathComponent("hooks", isDirectory: true)
        try fileManager.createDirectory(at: hooks, withIntermediateDirectories: true)
        let linkURL = hooks.appendingPathComponent("toastty-\(sessionID).json")

        XCTAssertThrowsError(try fixture.store.registerGrokHookLink(artifacts: artifacts, linkURL: linkURL))
        fixture.store.removeAbandoned(artifacts)

        XCTAssertTrue(pathExistsIncludingSymlink(linkURL))
        XCTAssertEqual(
            try fileManager.destinationOfSymbolicLink(atPath: linkURL.path),
            artifacts.directoryURL.appendingPathComponent("hooks.json").path
        )
    }

    func testInvalidRecordedGrokLinkPathCannotRemoveAnotherLaunchLink() throws {
        let fixture = try makeFixture()
        defer { try? fixture.fileManager.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let owned = try makeGrokArtifactsAndLink(fixture: fixture)
        let other = try makeGrokArtifactsAndLink(fixture: fixture)
        try fixture.fileManager.removeItem(at: other.linkURL)
        try fixture.fileManager.createSymbolicLink(
            at: other.linkURL,
            withDestinationURL: owned.artifacts.directoryURL.appendingPathComponent("hooks.json")
        )
        let metadataURL = owned.artifacts.directoryURL.appendingPathComponent(ManagedAgentLaunchArtifactStore.metadataFileName)
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        metadata["grokHookLinkPath"] = other.linkURL.path
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)

        fixture.store.removeAbandoned(owned.artifacts)

        XCTAssertTrue(pathExistsIncludingSymlink(other.linkURL))
        XCTAssertTrue(pathExistsIncludingSymlink(other.artifacts.directoryURL))
        XCTAssertFalse(pathExistsIncludingSymlink(owned.artifacts.directoryURL))
    }

    func testOlderMetadataWithoutGrokLinkPathStillCleansUp() throws {
        let fixture = try makeFixture(
            now: Date(timeIntervalSince1970: 10_000),
            ownerProcessStateProvider: { _ in .dead }
        )
        defer { try? fixture.fileManager.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let owned = try makeOwnedArtifacts(pid: 45001, fixture: fixture)
        let metadataURL = owned.artifacts.directoryURL.appendingPathComponent(ManagedAgentLaunchArtifactStore.metadataFileName)
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        metadata.removeValue(forKey: "grokHookLinkPath")
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)

        fixture.store.sweep(activeSessionIDs: [])

        XCTAssertFalse(pathExistsIncludingSymlink(owned.artifacts.directoryURL))
    }
}

private extension ManagedAgentLaunchArtifactStoreTests {
    struct Fixture {
        let root: URL
        let store: ManagedAgentLaunchArtifactStore
        let fileManager: FileManager
    }

    struct OwnedArtifacts {
        let sessionID: String
        let artifacts: ManagedAgentLaunchArtifactDirectory
    }

    struct GrokArtifacts {
        let sessionID: String
        let artifacts: ManagedAgentLaunchArtifactDirectory
        let linkURL: URL
    }

    func makeGrokArtifactsAndLink(pid: String? = nil, fixture: Fixture) throws -> GrokArtifacts {
        let sessionID = UUID().uuidString
        let artifacts = try fixture.store.makeDirectory(agent: .grok, sessionID: sessionID, lifetime: .agentProcess)
        try "{}".write(to: artifacts.directoryURL.appendingPathComponent("hooks.json"), atomically: true, encoding: .utf8)
        let hooks = fixture.root.deletingLastPathComponent().appendingPathComponent("hooks", isDirectory: true)
        try fixture.fileManager.createDirectory(at: hooks, withIntermediateDirectories: true)
        let linkURL = hooks.appendingPathComponent("toastty-\(sessionID).json")
        try fixture.store.registerGrokHookLink(artifacts: artifacts, linkURL: linkURL)
        if let pid {
            let ownerURL = try XCTUnwrap(artifacts.ownerRecordURL)
            try "\(pid)\n".write(to: ownerURL, atomically: true, encoding: .utf8)
            try fixture.fileManager.setAttributes(
                [.posixPermissions: 0o600, .modificationDate: Date(timeIntervalSince1970: 1_000)],
                ofItemAtPath: ownerURL.path
            )
        }
        return GrokArtifacts(sessionID: sessionID, artifacts: artifacts, linkURL: linkURL)
    }

    func pathExistsIncludingSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    func makeFixture(
        now: Date = Date(),
        ownerProcessStateProvider: @escaping @Sendable (Int32) -> ManagedAgentOwnerProcessState = { _ in .unknown },
        cleanupGraceInterval: TimeInterval = 600,
        fileManager: FileManager = .default,
        directoryPrefix: String = "toastty-artifact-store-tests-",
        createParentDirectory: Bool = false
    ) throws -> Fixture {
        let parent = fileManager.temporaryDirectory.appendingPathComponent(
            "\(directoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        ).standardizedFileURL
        if createParentDirectory {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let root = parent.appendingPathComponent("managed-agent-launches")
        return Fixture(
            root: root,
            store: ManagedAgentLaunchArtifactStore(
                rootDirectoryURL: root,
                fileManager: fileManager,
                nowProvider: { now },
                ownerProcessStateProvider: ownerProcessStateProvider,
                cleanupGraceInterval: cleanupGraceInterval
            ),
            fileManager: fileManager
        )
    }

    func makeOwnedArtifacts(
        pid: Int32,
        observedAt: Date = Date(timeIntervalSince1970: 1_000),
        fixture: Fixture
    ) throws -> OwnedArtifacts {
        let sessionID = UUID().uuidString
        let artifacts = try fixture.store.makeDirectory(
            agent: .codex,
            sessionID: sessionID,
            lifetime: .agentProcess
        )
        let ownerURL = try XCTUnwrap(artifacts.ownerRecordURL)
        try "\(pid)\n".write(to: ownerURL, atomically: true, encoding: .utf8)
        try fixture.fileManager.setAttributes(
            [
                .posixPermissions: 0o600,
                .modificationDate: observedAt,
            ],
            ofItemAtPath: ownerURL.path
        )
        return OwnedArtifacts(sessionID: sessionID, artifacts: artifacts)
    }

    func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}

/// Simulates another writer creating the same link after the store's initial
/// existence check but before its exclusive symlink creation.
private final class CompetingHookLinkFileManager: FileManager {
    override func createSymbolicLink(atPath path: String, withDestinationPath destination: String) throws {
        try super.createSymbolicLink(atPath: path, withDestinationPath: destination)
        throw CocoaError(.fileWriteFileExists)
    }
}
