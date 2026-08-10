import XCTest
@testable import ToasttyApp

final class GrokManagedHookCleanupTests: XCTestCase {
    func testHookFileURLUsesSessionScopedToasttyName() {
        let grokHome = URL(fileURLWithPath: "/tmp/grok-home", isDirectory: true)
        let url = GrokManagedHookCleanup.hookFileURL(grokHome: grokHome, sessionID: "abc-123")
        XCTAssertEqual(url.path, "/tmp/grok-home/hooks/toastty-abc-123.json")
    }

    func testRemoveHookFileDeletesExistingFile() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-grok-hook-remove-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let hookURL = rootURL.appendingPathComponent("toastty-session.json", isDirectory: false)
        try Data("{}".utf8).write(to: hookURL)
        XCTAssertTrue(fileManager.fileExists(atPath: hookURL.path))

        GrokManagedHookCleanup.removeHookFile(at: hookURL, fileManager: fileManager)
        XCTAssertFalse(fileManager.fileExists(atPath: hookURL.path))
    }

    func testRemoveOrphanHookFilesKeepsActiveAndNonMatchingNames() throws {
        let fileManager = FileManager.default
        let hooksDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-grok-hooks-sweep-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: hooksDirectory) }

        let activeURL = hooksDirectory.appendingPathComponent("toastty-aaa.json", isDirectory: false)
        let orphanURL = hooksDirectory.appendingPathComponent("toastty-bbb.json", isDirectory: false)
        let foreignURL = hooksDirectory.appendingPathComponent("other-hooks.json", isDirectory: false)
        let wrongSuffixURL = hooksDirectory.appendingPathComponent("toastty-ccc.txt", isDirectory: false)
        try Data("active".utf8).write(to: activeURL)
        try Data("orphan".utf8).write(to: orphanURL)
        try Data("foreign".utf8).write(to: foreignURL)
        try Data("wrong-suffix".utf8).write(to: wrongSuffixURL)

        GrokManagedHookCleanup.removeOrphanHookFiles(
            in: hooksDirectory,
            activeSessionIDs: ["aaa"],
            fileManager: fileManager
        )

        XCTAssertTrue(fileManager.fileExists(atPath: activeURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: orphanURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: foreignURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: wrongSuffixURL.path))
    }

    func testRemoveOrphanHookFilesNoopsWhenDirectoryMissing() {
        let fileManager = FileManager.default
        let missing = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-grok-hooks-missing-\(UUID().uuidString)", isDirectory: true)

        GrokManagedHookCleanup.removeOrphanHookFiles(
            in: missing,
            activeSessionIDs: [],
            fileManager: fileManager
        )
        XCTAssertFalse(fileManager.fileExists(atPath: missing.path))
    }

    func testRemoveOrphanHookFilesAtColdStartHonorsGROK_HOME() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-grok-cold-start-\(UUID().uuidString)", isDirectory: true)
        let hooksDirectory = rootURL.appendingPathComponent("hooks", isDirectory: true)
        try fileManager.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        // Dead-owner file should be swept; foreign non-toastty files stay.
        let deadOwnerObject: [String: Any] = [
            "hooks": [:],
            GrokManagedHookCleanup.ownerMetadataKey: GrokManagedHookCleanup.ownerMetadata(
                ownerPID: 1,
                managedSessionID: "dead-session",
                createdAt: Date(timeIntervalSince1970: 1)
            ),
        ]
        let leftoverURL = hooksDirectory.appendingPathComponent("toastty-leftover.json", isDirectory: false)
        let foreignURL = hooksDirectory.appendingPathComponent("user-hook.json", isDirectory: false)
        try JSONSerialization.data(withJSONObject: deadOwnerObject).write(to: leftoverURL)
        try Data("user".utf8).write(to: foreignURL)

        GrokManagedHookCleanup.removeOrphanHookFilesAtColdStart(
            environment: ["GROK_HOME": rootURL.path],
            fileManager: fileManager,
            isProcessAlive: { _ in false }
        )

        XCTAssertFalse(fileManager.fileExists(atPath: leftoverURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: foreignURL.path))
    }

    func testColdStartKeepsHooksOwnedByLiveProcess() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-grok-cold-live-\(UUID().uuidString)", isDirectory: true)
        let hooksDirectory = rootURL.appendingPathComponent("hooks", isDirectory: true)
        try fileManager.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let livePID: Int32 = 42_424
        let liveObject: [String: Any] = [
            "hooks": [:],
            GrokManagedHookCleanup.ownerMetadataKey: GrokManagedHookCleanup.ownerMetadata(
                ownerPID: livePID,
                managedSessionID: "live-session"
            ),
        ]
        let deadObject: [String: Any] = [
            "hooks": [:],
            GrokManagedHookCleanup.ownerMetadataKey: GrokManagedHookCleanup.ownerMetadata(
                ownerPID: 1,
                managedSessionID: "dead-session"
            ),
        ]
        let liveURL = hooksDirectory.appendingPathComponent("toastty-live.json", isDirectory: false)
        let deadURL = hooksDirectory.appendingPathComponent("toastty-dead.json", isDirectory: false)
        try JSONSerialization.data(withJSONObject: liveObject).write(to: liveURL)
        try JSONSerialization.data(withJSONObject: deadObject).write(to: deadURL)

        GrokManagedHookCleanup.removeOrphanHookFilesAtColdStart(
            environment: ["GROK_HOME": rootURL.path],
            fileManager: fileManager,
            isProcessAlive: { pid in pid == livePID }
        )

        XCTAssertTrue(fileManager.fileExists(atPath: liveURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: deadURL.path))
    }

    func testColdStartDoesNotDeleteFreshUnownedHooks() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-grok-cold-unowned-\(UUID().uuidString)", isDirectory: true)
        let hooksDirectory = rootURL.appendingPathComponent("hooks", isDirectory: true)
        try fileManager.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let freshURL = hooksDirectory.appendingPathComponent("toastty-fresh.json", isDirectory: false)
        try Data("{}".utf8).write(to: freshURL)

        GrokManagedHookCleanup.removeOrphanHookFilesAtColdStart(
            environment: ["GROK_HOME": rootURL.path],
            fileManager: fileManager,
            now: Date(),
            isProcessAlive: { _ in false }
        )

        XCTAssertTrue(
            fileManager.fileExists(atPath: freshURL.path),
            "Unowned legacy hooks must not be deleted immediately (concurrent instance race)"
        )
    }

    func testResolveGrokHomeURLPrefersEnvironmentOverDefault() {
        let fileManager = FileManager.default
        let resolved = GrokManagedHookCleanup.resolveGrokHomeURL(
            environment: ["GROK_HOME": "/custom/grok"],
            fileManager: fileManager
        )
        XCTAssertEqual(resolved.path, "/custom/grok")

        let defaultHome = GrokManagedHookCleanup.resolveGrokHomeURL(
            environment: [:],
            fileManager: fileManager
        )
        XCTAssertEqual(
            defaultHome.path,
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".grok").path
        )
    }
}
