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
