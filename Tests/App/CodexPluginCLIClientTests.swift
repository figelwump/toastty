import Foundation
import XCTest
@testable import ToasttyApp

final class CodexPluginCLIClientTests: XCTestCase {
    func testProcessExecutorDrainsLargeOutputWithoutTimingOut() throws {
        let runtime = CodexIntegrationRuntime(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            codexHomeURL: FileManager.default.temporaryDirectory,
            workingDirectoryURL: FileManager.default.temporaryDirectory
        )

        let data = try CodexPluginCLIProcessExecutor().execute(
            runtime: runtime,
            arguments: ["-c", "/usr/bin/head -c 200000 /dev/zero"],
            deadline: Date().addingTimeInterval(2)
        )

        XCTAssertEqual(data.count, 200_000)
    }

    func testProcessExecutorAppliesManagedPathAndCodexHomeWithoutDroppingInheritedValues() throws {
        let runtime = CodexIntegrationRuntime(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            codexHomeURL: URL(fileURLWithPath: "/tmp/managed-codex-home", isDirectory: true),
            processPath: "/custom/node/bin:/usr/bin:/bin",
            workingDirectoryURL: FileManager.default.temporaryDirectory
        )
        let executor = CodexPluginCLIProcessExecutor(baseEnvironment: {
            ["PATH": "/gui-only", "TOASTTY_TEST_MARKER": "preserved"]
        })

        let data = try executor.execute(
            runtime: runtime,
            arguments: ["-c", "printf '%s|%s|%s' \"$PATH\" \"$CODEX_HOME\" \"$TOASTTY_TEST_MARKER\""],
            deadline: Date().addingTimeInterval(2)
        )

        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "/custom/node/bin:/usr/bin:/bin|/tmp/managed-codex-home|preserved"
        )
    }

    func testProcessEnvironmentKeepsInheritedPathWhenManagedPathIsNil() {
        let processEnvironment = CodexProcessEnvironment(
            codexHomeURL: URL(fileURLWithPath: "/tmp/managed-codex-home", isDirectory: true),
            path: nil
        )

        XCTAssertEqual(
            processEnvironment.applying(to: ["PATH": "/inherited/bin", "MARKER": "preserved"]),
            [
                "PATH": "/inherited/bin",
                "CODEX_HOME": "/tmp/managed-codex-home",
                "MARKER": "preserved",
            ]
        )
    }

    func testRuntimeUnavailableRequiresAnExecutableLaunchFailureMessage() {
        XCTAssertTrue(
            CodexPluginCLIError.commandFailed(
                "plugin list --json",
                127,
                "env: node: No such file or directory"
            ).isRuntimeUnavailable
        )
        XCTAssertTrue(
            CodexPluginCLIError.commandFailed(
                "plugin list --json",
                126,
                "bad interpreter: Permission denied"
            ).isRuntimeUnavailable
        )
        XCTAssertFalse(
            CodexPluginCLIError.commandFailed(
                "plugin list --json",
                127,
                "plugin registry command returned no result"
            ).isRuntimeUnavailable
        )
        XCTAssertFalse(
            CodexPluginCLIError.commandFailed(
                "plugin list --json",
                1,
                "env: node: No such file or directory"
            ).isRuntimeUnavailable
        )
    }

    func testRuntimeLocatorUsesPreferredShellPathAndMergesGUIFallback() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runtime-locator-\(UUID().uuidString)", isDirectory: true)
        let binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        let executableURL = binURL.appendingPathComponent("codex", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let runtime = try CodexIntegrationRuntimeLocator.resolve(
            environment: ["PATH": "/usr/bin:/bin", "CODEX_HOME": "/tmp/codex-home"],
            preferredProcessPath: "relative:\(binURL.path):/usr/bin"
        )

        XCTAssertEqual(runtime.executableURL.path, executableURL.path)
        XCTAssertEqual(runtime.processEnvironment.path, "\(binURL.path):/usr/bin:/bin")
        XCTAssertEqual(runtime.codexHomeURL.path, "/tmp/codex-home")
    }

    func testRuntimeLocatorFallsBackToSupportedCdxExecutable() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdx-runtime-locator-\(UUID().uuidString)", isDirectory: true)
        let binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        let executableURL = binURL.appendingPathComponent("cdx", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let runtime = try CodexIntegrationRuntimeLocator.resolve(
            environment: ["PATH": "/usr/bin:/bin"],
            preferredProcessPath: binURL.path
        )

        XCTAssertEqual(runtime.executableURL.path, executableURL.path)
        XCTAssertEqual(runtime.processEnvironment.path, "\(binURL.path):/usr/bin:/bin")
    }

    func testDecodesMarketplaceAndInstalledPluginJSON() throws {
        let executor = RecordingPluginCLIExecutor(responses: [
            ["plugin", "marketplace", "list", "--json"]: #"{"marketplaces":[{"name":"toastty","root":"/tmp/market","marketplaceSource":{"sourceType":"path","source":"/tmp/market"}}]}"#,
            ["plugin", "list", "--json"]: #"{"installed":[{"pluginId":"toastty@toastty","name":"toastty","marketplaceName":"toastty","version":"0.2.0","source":{"path":"/tmp/cache/toastty"},"marketplaceSource":{"sourceType":"path","source":"/tmp/market"}}]}"#,
        ])
        let client = CodexPluginCLIClient(executor: executor)

        XCTAssertEqual(
            try client.listMarketplaces(runtime: Self.runtime(), deadline: Date().addingTimeInterval(1)),
            [CodexPluginMarketplace(name: "toastty", rootPath: "/tmp/market", sourcePath: "/tmp/market")]
        )
        XCTAssertEqual(
            try client.listInstalledPlugins(runtime: Self.runtime(), deadline: Date().addingTimeInterval(1)),
            [
                CodexInstalledPlugin(
                    pluginID: "toastty@toastty",
                    name: "toastty",
                    marketplaceName: "toastty",
                    version: "0.2.0",
                    sourcePath: "/tmp/cache/toastty",
                    marketplaceSourcePath: "/tmp/market"
                ),
            ]
        )
    }

    func testUsesPublicCLICommandsForAddInstallAndRemoval() throws {
        let executor = RecordingPluginCLIExecutor(responses: [
            ["plugin", "marketplace", "add", "/tmp/market", "--json"]: #"{"marketplaceName":"toastty"}"#,
            ["plugin", "add", "toastty@toastty", "--json"]: #"{"pluginId":"toastty@toastty","name":"toastty","marketplaceName":"toastty","version":"0.2.0","installedPath":"/tmp/cache/toastty"}"#,
            ["plugin", "remove", "toastty@toastty", "--json"]: #"{}"#,
            ["plugin", "marketplace", "remove", "toastty", "--json"]: #"{}"#,
        ])
        let client = CodexPluginCLIClient(executor: executor)
        let deadline = Date().addingTimeInterval(1)

        XCTAssertEqual(
            try client.addMarketplace(runtime: Self.runtime(), sourcePath: "/tmp/market", deadline: deadline),
            "toastty"
        )
        XCTAssertEqual(
            try client.installPlugin(runtime: Self.runtime(), selector: "toastty@toastty", deadline: deadline),
            CodexPluginInstallation(
                pluginID: "toastty@toastty",
                name: "toastty",
                marketplaceName: "toastty",
                version: "0.2.0",
                installedPath: "/tmp/cache/toastty"
            )
        )
        try client.removePlugin(runtime: Self.runtime(), selector: "toastty@toastty", deadline: deadline)
        try client.removeMarketplace(runtime: Self.runtime(), name: "toastty", deadline: deadline)

        XCTAssertFalse(executor.arguments.contains { $0.contains("upgrade") })
    }

    func testMalformedJSONFailsClosed() {
        let executor = RecordingPluginCLIExecutor(responses: [
            ["plugin", "list", "--json"]: "not-json",
        ])

        XCTAssertThrowsError(
            try CodexPluginCLIClient(executor: executor).listInstalledPlugins(
                runtime: Self.runtime(),
                deadline: Date().addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(error as? CodexPluginCLIError, .malformedJSON("plugin list --json"))
        }
    }
}

private extension CodexPluginCLIClientTests {
    static func runtime() -> CodexIntegrationRuntime {
        CodexIntegrationRuntime(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            codexHomeURL: URL(fileURLWithPath: "/tmp/codex-home", isDirectory: true),
            workingDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )
    }
}

private final class RecordingPluginCLIExecutor: CodexPluginCLIExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [[String]: String]
    private var recordedArguments: [[String]] = []

    init(responses: [[String]: String]) {
        self.responses = responses
    }

    var arguments: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedArguments
    }

    func execute(
        runtime: CodexIntegrationRuntime,
        arguments: [String],
        deadline: Date
    ) throws -> Data {
        lock.lock()
        recordedArguments.append(arguments)
        lock.unlock()
        guard let response = responses[arguments] else {
            throw CodexPluginCLIError.commandFailed(arguments.joined(separator: " "), 1, "missing fixture")
        }
        return Data(response.utf8)
    }
}
