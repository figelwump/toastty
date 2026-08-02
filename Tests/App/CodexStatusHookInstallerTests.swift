@testable import ToasttyApp
import XCTest

final class CodexStatusHookInstallerTests: XCTestCase {
    func testExplicitMigrationRemovesOwnedCurrentAndLegacyHooksWithoutAddingGlobals() throws {
        let homeURL = try makeTemporaryHome()
        let hooksURL = homeURL.appendingPathComponent(".codex/hooks.json")
        let ownedCommand = "/bin/sh '\(homeURL.path)/.toastty/codex-hooks/forwarder.sh'"
        try writeHooks(
            [
                "hooks": [
                    "SessionStart": [group(command: ownedCommand)],
                    "PostToolUse": [group(command: ownedCommand, matcher: "*")],
                ],
                "foreignTopLevel": ["preserve": true],
            ],
            to: hooksURL
        )

        let installer = CodexStatusHookInstaller(homeDirectoryPath: homeURL.path)
        let result = try installer.prepareSessionIntegrationMigration()

        XCTAssertTrue(result.hooksFileChanged)
        XCTAssertTrue(result.forwarderScriptChanged)
        XCTAssertFalse(try installer.legacyGlobalHooksPresent())
        XCTAssertEqual(result.status.state, .installed)
        let object = try readHooks(at: hooksURL)
        XCTAssertEqual((object["foreignTopLevel"] as? [String: Bool])?["preserve"], true)
        XCTAssertTrue((object["hooks"] as? [String: Any])?.isEmpty == true)
    }

    func testMigrationPreservesForeignHooksAndMixedGroupFields() throws {
        let homeURL = try makeTemporaryHome()
        let hooksURL = homeURL.appendingPathComponent(".codex/hooks.json")
        let ownedCommand = "/bin/sh '\(homeURL.path)/.toastty/codex-hooks/forwarder.sh'"
        let foreignHook: [String: Any] = [
            "type": "command",
            "command": "/usr/local/bin/user hook",
            "timeout": 17,
            "statusMessage": "Toastty Agent Status",
            "foreign": ["nested": "value"],
        ]
        try writeHooks(
            [
                "hooks": [
                    "Stop": [
                        [
                            "matcher": "user matcher",
                            "foreignGroupField": "untouched",
                            "hooks": [
                                foreignHook,
                                ["type": "command", "command": ownedCommand],
                            ],
                        ],
                    ],
                    "Notification": [group(command: "/usr/bin/notify")],
                ],
            ],
            to: hooksURL
        )

        _ = try CodexStatusHookInstaller(homeDirectoryPath: homeURL.path)
            .prepareSessionIntegrationMigration()

        let object = try readHooks(at: hooksURL)
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let stopGroups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let stopGroup = try XCTUnwrap(stopGroups.first)
        XCTAssertEqual(stopGroup["matcher"] as? String, "user matcher")
        XCTAssertEqual(stopGroup["foreignGroupField"] as? String, "untouched")
        let entries = try XCTUnwrap(stopGroup["hooks"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0] as NSDictionary, foreignHook as NSDictionary)
        XCTAssertNotNil(hooks["Notification"])
    }

    func testMigrationDoesNotRewriteForeignOnlyHooksFile() throws {
        let homeURL = try makeTemporaryHome()
        let hooksURL = homeURL.appendingPathComponent(".codex/hooks.json")
        let original = Data(#"{ "foreign" : 1, "hooks" : { "Stop" : [ { "hooks" : [ { "command" : "/usr/bin/true" } ] } ] } }"#.utf8)
        try FileManager.default.createDirectory(at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: hooksURL)

        let result = try CodexStatusHookInstaller(homeDirectoryPath: homeURL.path)
            .prepareSessionIntegrationMigration()

        XCTAssertFalse(result.hooksFileChanged)
        XCTAssertEqual(try Data(contentsOf: hooksURL), original)
    }

    func testMigrationIsIdempotentAndPreservesCommandsThatOnlyReferenceForwarder() throws {
        let homeURL = try makeTemporaryHome()
        let hooksURL = homeURL.appendingPathComponent(".codex/hooks.json")
        let ownedCommand = "/bin/sh '\(homeURL.path)/.toastty/codex-hooks/forwarder.sh'"
        let foreignCommand = "/bin/sh -c 'echo before; \(homeURL.path)/.toastty/codex-hooks/forwarder.sh --user-owned'"
        try writeHooks(
            [
                "hooks": [
                    "Stop": [
                        [
                            "hooks": [
                                ["type": "command", "command": ownedCommand],
                                ["type": "command", "command": foreignCommand],
                            ],
                        ],
                    ],
                ],
            ],
            to: hooksURL
        )
        let installer = CodexStatusHookInstaller(homeDirectoryPath: homeURL.path)

        let first = try installer.prepareSessionIntegrationMigration()
        let second = try installer.prepareSessionIntegrationMigration()

        XCTAssertTrue(first.hooksFileChanged)
        XCTAssertFalse(second.hooksFileChanged)
        let hooks = try XCTUnwrap(try readHooks(at: hooksURL)["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let entries = try XCTUnwrap(groups.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?["command"] as? String, foreignCommand)
    }

    func testAutomaticMaintenanceRefreshesForwarderWithoutRemovingWorkingGlobalHooks() throws {
        let homeURL = try makeTemporaryHome()
        let hooksURL = homeURL.appendingPathComponent(".codex/hooks.json")
        let ownedCommand = "/bin/sh '\(homeURL.path)/.toastty/codex-hooks/forwarder.sh'"
        try writeHooks(["hooks": ["Stop": [group(command: ownedCommand)]]], to: hooksURL)
        let installer = CodexStatusHookInstaller(homeDirectoryPath: homeURL.path)

        let result = try XCTUnwrap(installer.performAutomaticMaintenanceIfNeeded())

        XCTAssertTrue(result.forwarderScriptChanged)
        XCTAssertFalse(result.hooksFileChanged)
        XCTAssertTrue(try installer.legacyGlobalHooksPresent())
        XCTAssertEqual(result.status.setupRequirement, .userSetup)
    }

    func testForwarderIsStableAndUsesOnlyRuntimeEnvironmentForSessionContext() throws {
        let homeURL = try makeTemporaryHome()
        let installer = CodexStatusHookInstaller(homeDirectoryPath: homeURL.path)

        let first = try installer.maintainForwarder()
        let second = try installer.maintainForwarder()

        XCTAssertTrue(first.forwarderScriptChanged)
        XCTAssertFalse(second.forwarderScriptChanged)
        let script = try String(contentsOf: first.status.forwarderScriptURL, encoding: .utf8)
        XCTAssertTrue(script.contains("$TOASTTY_SESSION_ID"))
        XCTAssertTrue(script.contains("$TOASTTY_PANEL_ID"))
        XCTAssertTrue(script.contains("$TOASTTY_SOCKET_PATH"))
        XCTAssertTrue(script.contains("$TOASTTY_CLI_PATH"))
        XCTAssertTrue(script.contains("--source codex-hooks"))
        XCTAssertTrue(script.contains("exit 0"))
        XCTAssertEqual(installer.sessionLaunchForwarderCommand(), "/bin/sh '\(first.status.forwarderScriptURL.path)'")
    }

    func testMalformedHooksFileFailsClosedWithoutOverwriting() throws {
        let homeURL = try makeTemporaryHome()
        let hooksURL = homeURL.appendingPathComponent(".codex/hooks.json")
        try FileManager.default.createDirectory(at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: hooksURL)

        XCTAssertThrowsError(
            try CodexStatusHookInstaller(homeDirectoryPath: homeURL.path)
                .prepareSessionIntegrationMigration()
        ) { error in
            XCTAssertEqual(error as? CodexStatusHookInstallerError, .unableToReadHooksFile(hooksURL.path))
        }
        XCTAssertEqual(try String(contentsOf: hooksURL, encoding: .utf8), "not json")
    }

    private func makeTemporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-codex-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func group(command: String, matcher: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["hooks": [["type": "command", "command": command]]]
        value["matcher"] = matcher
        return value
    }

    private func writeHooks(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func readHooks(at url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }
}
