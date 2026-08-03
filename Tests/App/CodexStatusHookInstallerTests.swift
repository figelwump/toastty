@testable import ToasttyApp
import XCTest

final class CodexStatusHookInstallerTests: XCTestCase {
    private let eventNames = [
        "SessionStart",
        "UserPromptSubmit",
        "PermissionRequest",
        "PreToolUse",
        "SubagentStart",
        "SubagentStop",
        "Stop",
    ]

    func testInstallCreatesHooksFileAndForwarder() throws {
        let homeURL = try makeTemporaryHome()
        let installer = CodexStatusHookInstaller(homeDirectoryPath: homeURL.path)

        let result = try installer.install()

        XCTAssertTrue(result.hooksFileChanged)
        XCTAssertTrue(result.forwarderScriptChanged)
        XCTAssertEqual(result.status.state, .installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.status.forwarderScriptURL.path))

        let object = try hooksJSONObject(homeURL: homeURL)
        for eventName in eventNames {
            let entries = try toasttyHookEntries(for: eventName, in: object, homeURL: homeURL)
            XCTAssertEqual(entries.count, 1, eventName)
        }
        XCTAssertNil((object["hooks"] as? [String: Any])?["PostToolUse"])

        let forwarder = try String(contentsOf: result.status.forwarderScriptURL, encoding: .utf8)
        XCTAssertTrue(forwarder.contains("session ingest-agent-event --source codex-hooks"))
        XCTAssertTrue(forwarder.contains("exit 0"))
    }

    func testInstallPreservesExistingHooks() throws {
        let homeURL = try makeTemporaryHome()
        let hooksFileURL = homeURL.appendingPathComponent(".codex/hooks.json", isDirectory: false)
        try writeHooksObject(
            [
                "hooks": [
                    "UserPromptSubmit": [
                        [
                            "hooks": [
                                [
                                    "type": "command",
                                    "command": "/usr/bin/true",
                                    "statusMessage": "Existing Hook",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
            to: hooksFileURL
        )

        _ = try CodexStatusHookInstaller(homeDirectoryPath: homeURL.path).install()

        let object = try hooksJSONObject(homeURL: homeURL)
        let userPromptHooks = try hookEntries(for: "UserPromptSubmit", in: object)
        XCTAssertTrue(userPromptHooks.contains { ($0["command"] as? String) == "/usr/bin/true" })
        XCTAssertEqual(try toasttyHookEntries(for: "UserPromptSubmit", in: object, homeURL: homeURL).count, 1)
    }

    func testInstallReplacesStaleToasttyHooks() throws {
        let homeURL = try makeTemporaryHome()
        let hooksFileURL = homeURL.appendingPathComponent(".codex/hooks.json", isDirectory: false)
        let staleCommand = "/bin/sh '\(homeURL.path)/.toastty/codex-hooks/forwarder.sh'"
        try writeHooksObject(
            [
                "hooks": [
                    "Stop": [
                        [
                            "hooks": [
                                [
                                    "type": "command",
                                    "command": staleCommand,
                                    "timeout": 1,
                                    "statusMessage": "Toastty Agent Status",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
            to: hooksFileURL
        )

        _ = try CodexStatusHookInstaller(homeDirectoryPath: homeURL.path).install()

        let object = try hooksJSONObject(homeURL: homeURL)
        let stopHooks = try hookEntries(for: "Stop", in: object)
        XCTAssertFalse(
            stopHooks.contains {
                ($0["command"] as? String) == staleCommand &&
                    (($0["timeout"] as? NSNumber)?.intValue == 1 || ($0["timeout"] as? Int) == 1)
            }
        )
        XCTAssertEqual(try toasttyHookEntries(for: "Stop", in: object, homeURL: homeURL).count, 1)
    }

    func testInstallRemovesLegacyToasttyPostToolUseHook() throws {
        let homeURL = try makeTemporaryHome()
        let hooksFileURL = homeURL.appendingPathComponent(".codex/hooks.json", isDirectory: false)
        let legacyCommand = "/bin/sh '\(homeURL.path)/.toastty/codex-hooks/forwarder.sh'"
        try writeHooksObject(
            [
                "hooks": [
                    "PostToolUse": [
                        [
                            "matcher": "*",
                            "hooks": [
                                [
                                    "type": "command",
                                    "command": legacyCommand,
                                    "timeout": 5,
                                    "statusMessage": "Toastty Agent Status",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
            to: hooksFileURL
        )
        let installer = CodexStatusHookInstaller(homeDirectoryPath: homeURL.path)

        XCTAssertEqual(try installer.installationStatus().state, .needsUpdate)

        _ = try installer.install()

        let object = try hooksJSONObject(homeURL: homeURL)
        XCTAssertNil((object["hooks"] as? [String: Any])?["PostToolUse"])
        for eventName in eventNames {
            let entries = try toasttyHookEntries(for: eventName, in: object, homeURL: homeURL)
            XCTAssertEqual(entries.count, 1, eventName)
        }
    }

    func testCurrentHooksWithLegacyToasttyHookNeedAutomaticMaintenanceWithoutLaunchWarning() throws {
        let homeURL = try makeTemporaryHome()
        let installer = CodexStatusHookInstaller(homeDirectoryPath: homeURL.path)
        _ = try installer.install()
        try appendLegacyToasttyHook(homeURL: homeURL)

        let status = try installer.installationStatus()

        XCTAssertEqual(status.state, .needsUpdate)
        XCTAssertEqual(status.setupRequirement, .automaticMaintenance)
        XCTAssertTrue(status.needsAutomaticMaintenance)
        XCTAssertFalse(status.requiresLaunchPreflightWarning)
    }

    func testCurrentHooksWithExtraStaleCurrentHookNeedAutomaticMaintenanceWithoutLaunchWarning() throws {
        let homeURL = try makeTemporaryHome()
        let installer = CodexStatusHookInstaller(homeDirectoryPath: homeURL.path)
        _ = try installer.install()
        try appendStaleCurrentToasttyHook(homeURL: homeURL)

        let status = try installer.installationStatus()

        XCTAssertEqual(status.state, .needsUpdate)
        XCTAssertEqual(status.setupRequirement, .automaticMaintenance)
        XCTAssertTrue(status.needsAutomaticMaintenance)
        XCTAssertFalse(status.requiresLaunchPreflightWarning)
    }

    func testHooksMissingSubagentLifecycleEventsReceiveAutomaticMaintenance() throws {
        let homeURL = try makeTemporaryHome()
        let installer = CodexStatusHookInstaller(homeDirectoryPath: homeURL.path)
        _ = try installer.install()

        let hooksFileURL = homeURL.appendingPathComponent(".codex/hooks.json", isDirectory: false)
        var object = try hooksJSONObject(homeURL: homeURL)
        var hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        hooks.removeValue(forKey: "SubagentStart")
        hooks.removeValue(forKey: "SubagentStop")
        object["hooks"] = hooks
        try writeHooksObject(object, to: hooksFileURL)

        let status = try installer.installationStatus()
        XCTAssertEqual(status.state, .needsUpdate)
        XCTAssertEqual(status.setupRequirement, .automaticMaintenance)

        let result = try XCTUnwrap(installer.performAutomaticMaintenanceIfNeeded())
        XCTAssertEqual(result.status.state, .installed)
        let updatedObject = try hooksJSONObject(homeURL: homeURL)
        XCTAssertEqual(try toasttyHookEntries(for: "SubagentStart", in: updatedObject, homeURL: homeURL).count, 1)
        XCTAssertEqual(try toasttyHookEntries(for: "SubagentStop", in: updatedObject, homeURL: homeURL).count, 1)
    }

    func testAutomaticMaintenanceRemovesLegacyToasttyHookAndPreservesExistingHooks() throws {
        let homeURL = try makeTemporaryHome()
        let installer = CodexStatusHookInstaller(homeDirectoryPath: homeURL.path)
        _ = try installer.install()
        try appendLegacyToasttyHook(homeURL: homeURL)
        try appendExternalStopHook(homeURL: homeURL)

        let result = try XCTUnwrap(installer.performAutomaticMaintenanceIfNeeded())

        XCTAssertTrue(result.hooksFileChanged)
        XCTAssertEqual(result.status.state, .installed)

        let object = try hooksJSONObject(homeURL: homeURL)
        XCTAssertNil((object["hooks"] as? [String: Any])?["PostToolUse"])
        let stopHooks = try hookEntries(for: "Stop", in: object)
        XCTAssertTrue(stopHooks.contains { ($0["command"] as? String) == "/usr/bin/true" })
        XCTAssertEqual(try toasttyHookEntries(for: "Stop", in: object, homeURL: homeURL).count, 1)
    }

    func testAutomaticMaintenancePreservesExternalHookWithToasttyStatusMessage() throws {
        let homeURL = try makeTemporaryHome()
        let installer = CodexStatusHookInstaller(homeDirectoryPath: homeURL.path)
        _ = try installer.install()
        try appendLegacyToasttyHook(homeURL: homeURL)
        try appendExternalStopHook(homeURL: homeURL, statusMessage: "Toastty Agent Status")

        let result = try XCTUnwrap(installer.performAutomaticMaintenanceIfNeeded())

        XCTAssertTrue(result.hooksFileChanged)
        XCTAssertEqual(result.status.state, .installed)

        let object = try hooksJSONObject(homeURL: homeURL)
        let stopHooks = try hookEntries(for: "Stop", in: object)
        XCTAssertTrue(
            stopHooks.contains {
                ($0["command"] as? String) == "/usr/bin/true" &&
                    ($0["statusMessage"] as? String) == "Toastty Agent Status"
            }
        )
        XCTAssertEqual(try toasttyHookEntries(for: "Stop", in: object, homeURL: homeURL).count, 1)
    }

    func testAutomaticMaintenanceRecreatesMissingForwarderForOwnedHooks() throws {
        let homeURL = try makeTemporaryHome()
        let installer = CodexStatusHookInstaller(homeDirectoryPath: homeURL.path)
        let installResult = try installer.install()
        try FileManager.default.removeItem(at: installResult.status.forwarderScriptURL)

        let status = try installer.installationStatus()

        XCTAssertEqual(status.state, .needsUpdate)
        XCTAssertEqual(status.setupRequirement, .automaticMaintenance)
        XCTAssertFalse(status.requiresLaunchPreflightWarning)

        let maintenanceResult = try XCTUnwrap(installer.performAutomaticMaintenanceIfNeeded())
        XCTAssertFalse(maintenanceResult.hooksFileChanged)
        XCTAssertTrue(maintenanceResult.forwarderScriptChanged)
        XCTAssertEqual(maintenanceResult.status.state, .installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: maintenanceResult.status.forwarderScriptURL.path))
    }

    func testAutomaticMaintenanceDoesNotInstallWhenNoToasttyHooksExist() throws {
        let homeURL = try makeTemporaryHome()
        let hooksFileURL = homeURL.appendingPathComponent(".codex/hooks.json", isDirectory: false)
        try writeHooksObject(
            [
                "hooks": [
                    "Stop": [
                        [
                            "hooks": [
                                [
                                    "type": "command",
                                    "command": "/usr/bin/true",
                                    "statusMessage": "Toastty Agent Status",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
            to: hooksFileURL
        )
        let installer = CodexStatusHookInstaller(homeDirectoryPath: homeURL.path)

        let status = try installer.installationStatus()
        let result = try installer.performAutomaticMaintenanceIfNeeded()

        XCTAssertEqual(status.state, .notInstalled)
        XCTAssertEqual(status.setupRequirement, .userSetup)
        XCTAssertTrue(status.requiresLaunchPreflightWarning)
        XCTAssertNil(result)

        let object = try hooksJSONObject(homeURL: homeURL)
        let stopHooks = try hookEntries(for: "Stop", in: object)
        XCTAssertEqual(stopHooks.count, 1)
        XCTAssertEqual(stopHooks.first?["command"] as? String, "/usr/bin/true")
    }

    func testUninstallRemovesOnlyToasttyHooks() throws {
        let homeURL = try makeTemporaryHome()
        let installer = CodexStatusHookInstaller(homeDirectoryPath: homeURL.path)
        _ = try installer.install()

        let hooksFileURL = homeURL.appendingPathComponent(".codex/hooks.json", isDirectory: false)
        var object = try hooksJSONObject(homeURL: homeURL)
        var hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        var stopGroups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        stopGroups.append(
            [
                "hooks": [
                    [
                        "type": "command",
                        "command": "/usr/bin/true",
                        "statusMessage": "Existing Hook",
                    ],
                ],
            ]
        )
        hooks["Stop"] = stopGroups
        object["hooks"] = hooks
        try writeHooksObject(object, to: hooksFileURL)

        let status = try installer.uninstall()

        XCTAssertEqual(status.state, .notInstalled)
        let updatedObject = try hooksJSONObject(homeURL: homeURL)
        let stopHooks = try hookEntries(for: "Stop", in: updatedObject)
        XCTAssertTrue(stopHooks.contains { ($0["command"] as? String) == "/usr/bin/true" })
        XCTAssertTrue(try toasttyHookEntries(for: "Stop", in: updatedObject, homeURL: homeURL).isEmpty)
    }

    func testInstallationStatusRequiresCurrentForwarderScript() throws {
        let homeURL = try makeTemporaryHome()
        let installer = CodexStatusHookInstaller(homeDirectoryPath: homeURL.path)
        let result = try installer.install()
        try FileManager.default.removeItem(at: result.status.forwarderScriptURL)

        let status = try installer.installationStatus()

        XCTAssertEqual(status.state, .needsUpdate)
    }

    func testMalformedHooksFileFailsWithoutOverwriting() throws {
        let homeURL = try makeTemporaryHome()
        let hooksFileURL = homeURL.appendingPathComponent(".codex/hooks.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: hooksFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: hooksFileURL)

        XCTAssertThrowsError(try CodexStatusHookInstaller(homeDirectoryPath: homeURL.path).install()) { error in
            XCTAssertEqual(error as? CodexStatusHookInstallerError, .unableToReadHooksFile(hooksFileURL.path))
        }
        XCTAssertEqual(try String(contentsOf: hooksFileURL, encoding: .utf8), "not json")
    }

    private func makeTemporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-codex-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func hooksJSONObject(homeURL: URL) throws -> [String: Any] {
        let url = homeURL.appendingPathComponent(".codex/hooks.json", isDirectory: false)
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func writeHooksObject(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func hookEntries(
        for eventName: String,
        in object: [String: Any]
    ) throws -> [[String: Any]] {
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks[eventName] as? [[String: Any]])
        return groups.flatMap { group in
            group["hooks"] as? [[String: Any]] ?? []
        }
    }

    private func toasttyHookEntries(
        for eventName: String,
        in object: [String: Any],
        homeURL: URL
    ) throws -> [[String: Any]] {
        let expectedCommand = "/bin/sh '\(homeURL.path)/.toastty/codex-hooks/forwarder.sh'"
        return try hookEntries(for: eventName, in: object).filter { hook in
            (hook["command"] as? String) == expectedCommand &&
                (hook["statusMessage"] as? String) == "Toastty Agent Status"
        }
    }

    private func appendLegacyToasttyHook(homeURL: URL) throws {
        let hooksFileURL = homeURL.appendingPathComponent(".codex/hooks.json", isDirectory: false)
        var object = try hooksJSONObject(homeURL: homeURL)
        var hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let legacyCommand = "/bin/sh '\(homeURL.path)/.toastty/codex-hooks/forwarder.sh'"
        hooks["PostToolUse"] = [
            [
                "matcher": "*",
                "hooks": [
                    [
                        "type": "command",
                        "command": legacyCommand,
                        "timeout": 5,
                        "statusMessage": "Toastty Agent Status",
                    ],
                ],
            ],
        ]
        object["hooks"] = hooks
        try writeHooksObject(object, to: hooksFileURL)
    }

    private func appendStaleCurrentToasttyHook(homeURL: URL) throws {
        let hooksFileURL = homeURL.appendingPathComponent(".codex/hooks.json", isDirectory: false)
        var object = try hooksJSONObject(homeURL: homeURL)
        var hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        var stopGroups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let staleCommand = "/bin/sh '\(homeURL.path)/.toastty/codex-hooks/forwarder.sh'"
        stopGroups.append(
            [
                "hooks": [
                    [
                        "type": "command",
                        "command": staleCommand,
                        "timeout": 1,
                        "statusMessage": "Toastty Agent Status",
                    ],
                ],
            ]
        )
        hooks["Stop"] = stopGroups
        object["hooks"] = hooks
        try writeHooksObject(object, to: hooksFileURL)
    }

    private func appendExternalStopHook(
        homeURL: URL,
        statusMessage: String = "Existing Hook"
    ) throws {
        let hooksFileURL = homeURL.appendingPathComponent(".codex/hooks.json", isDirectory: false)
        var object = try hooksJSONObject(homeURL: homeURL)
        var hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        var stopGroups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        stopGroups.append(
            [
                "hooks": [
                    [
                        "type": "command",
                        "command": "/usr/bin/true",
                        "statusMessage": statusMessage,
                    ],
                ],
            ]
        )
        hooks["Stop"] = stopGroups
        object["hooks"] = hooks
        try writeHooksObject(object, to: hooksFileURL)
    }
}
