@testable import ToasttyApp
import Foundation
import XCTest

final class AgentHookTemplateFileTests: XCTestCase {
    func testEnsureTemplateExistsWritesExecutableStubScript() throws {
        let homeDirectoryURL = try makeTemporaryHookTestHomeDirectory()

        try AgentHookTemplateFile.ensureTemplateExists(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )

        let templateURL = AgentHookTemplateFile.fileURL(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )
        XCTAssertEqual(
            templateURL.path,
            homeDirectoryURL
                .appendingPathComponent(".toastty/hooks/agent-hook")
                .path
        )

        let contents = try String(contentsOf: templateURL, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("#!/bin/bash\n"))
        for event in [
            "session-start",
            "turn-complete",
            "needs-approval",
            "session-error",
            "session-stop",
        ] {
            XCTAssertTrue(contents.contains("\(event))"), "missing case for \(event)")
        }
        for variable in [
            "TOASTTY_HOOK_SCHEMA_VERSION",
            "TOASTTY_HOOK_EVENT",
            "TOASTTY_AGENT",
            "TOASTTY_SESSION_ID",
            "TOASTTY_WORKSPACE_ID",
            "TOASTTY_PANEL_ID",
            "TOASTTY_SESSION_CWD",
            "TOASTTY_CLI_PATH",
            "TOASTTY_SOCKET_PATH",
            "TOASTTY_LAUNCH_REASON",
        ] {
            XCTAssertTrue(contents.contains(variable), "missing env var \(variable)")
        }
        XCTAssertTrue(contents.contains("agent-hook = \"~/.toastty/hooks/agent-hook\""))
        XCTAssertTrue(contents.contains("docs/agent-hooks.md"))

        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: templateURL.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(permissions.int16Value & 0o111, 0o111, "template must be executable")
    }

    func testEnsureTemplateExistsDoesNotOverwriteExistingScript() throws {
        let homeDirectoryURL = try makeTemporaryHookTestHomeDirectory()
        let templateURL = AgentHookTemplateFile.fileURL(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )
        try FileManager.default.createDirectory(
            at: templateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let userScript = "#!/bin/sh\necho custom\n"
        try userScript.write(to: templateURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: templateURL.path
        )

        try AgentHookTemplateFile.ensureTemplateExists(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )

        let contents = try String(contentsOf: templateURL, encoding: .utf8)
        XCTAssertEqual(contents, userScript)
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: templateURL.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(permissions.int16Value, 0o600, "existing permissions must be untouched")
    }

    func testFileURLUsesRuntimeHomeWhenSet() {
        let templateURL = AgentHookTemplateFile.fileURL(
            homeDirectoryPath: "/tmp/ignored-home",
            environment: ["TOASTTY_RUNTIME_HOME": "/tmp/toastty-runtime-home-tests/hook-runtime"]
        )

        XCTAssertEqual(
            templateURL.path,
            "/tmp/toastty-runtime-home-tests/hook-runtime/hooks/agent-hook"
        )
    }

    func testTemplateContentsPassesBashSyntaxCheck() throws {
        let homeDirectoryURL = try makeTemporaryHookTestHomeDirectory()
        let scriptURL = homeDirectoryURL.appendingPathComponent("agent-hook-syntax-check")
        try AgentHookTemplateFile.templateContents().write(
            to: scriptURL,
            atomically: true,
            encoding: .utf8
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", scriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, "template must be valid bash")
    }
}

private func makeTemporaryHookTestHomeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-hook-template-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
