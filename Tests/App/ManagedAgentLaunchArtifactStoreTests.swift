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
        let artifacts = try store.makeDirectory(
            agent: .claude,
            sessionID: UUID().uuidString,
            lifetime: .agentProcess
        )
        defer { try? fileManager.removeItem(at: artifacts.directoryURL) }

        XCTAssertEqual(artifacts.storage, .temporary)
        XCTAssertFalse(artifacts.directoryURL.path.hasPrefix(root.path + "/"))
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

    func makeFixture(
        now: Date = Date(),
        ownerProcessStateProvider: @escaping @Sendable (Int32) -> ManagedAgentOwnerProcessState = { _ in .unknown },
        cleanupGraceInterval: TimeInterval = 600
    ) throws -> Fixture {
        let fileManager = FileManager.default
        let parent = fileManager.temporaryDirectory.appendingPathComponent(
            "toastty-artifact-store-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let root = parent.appendingPathComponent("managed-agent-launches", isDirectory: true)
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
