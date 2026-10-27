import Foundation
import XCTest
@testable import ToasttyApp

final class CodexModelCatalogTests: XCTestCase {
    // Failure modes: hidden or malformed identifiers offered to the user,
    // duplicate choices, an unsupported CLI, invalid JSON, and a stalled CLI.
    func testListsVisibleModelsInProviderOrderWithoutDuplicates() throws {
        let models = try CodexModelCatalog.models(in: Data(#"""
        {"models":[
          {"slug":"catalog-second","visibility":"list","unused":{"newField":true}},
          {"slug":"hidden-model","visibility":"hide"},
          {"slug":"catalog-first","visibility":"list"},
          {"slug":"catalog-second","visibility":"list"},
          {"slug":"unknown-visibility","visibility":"future"},
          {"slug":"missing-visibility"},
          {"slug":42,"visibility":"list"},
          null,
          {"slug":"two words","visibility":"list"},
          {"slug":"","visibility":"list"},
          {"slug":"--flag","visibility":"list"}
        ]}
        """#.utf8))

        XCTAssertEqual(models, ["catalog-second", "catalog-first"])
    }

    func testRejectsMalformedCatalogInsteadOfTreatingItAsAnEmptySuccess() {
        for json in ["not json", "{}", #"{"models":{}}"#] {
            XCTAssertThrowsError(try CodexModelCatalog.models(in: Data(json.utf8)))
        }
    }

    func testReadsTheCatalogThroughTheCLIWithItsCodexHome() throws {
        let fixture = try CodexModelCatalogFixture()
        defer { fixture.remove() }
        // Real catalogs include large instruction strings that the picker
        // does not decode. This must drain the pipe before waiting for exit.
        let json = "{\"models\":[{\"slug\":\"org/catalog-model.1\",\"visibility\":\"list\",\"instructions\":\""
            + String(repeating: "x", count: 1_100_000) + "\"}]}"
        try fixture.writeCatalog(json)

        let models = try CodexModelCatalog().load(runtime: fixture.runtime, deadline: Date().addingTimeInterval(2))

        XCTAssertEqual(models, ["org/catalog-model.1"])
    }

    func testUnsupportedCommandAndTimeoutReturnErrors() throws {
        let fixture = try CodexModelCatalogFixture()
        defer { fixture.remove() }
        try "#!/bin/sh\nexit 2\n".write(to: fixture.runtime.executableURL, atomically: false, encoding: .utf8)
        XCTAssertThrowsError(try CodexModelCatalog().load(runtime: fixture.runtime, deadline: Date().addingTimeInterval(2)))

        // exec leaves one process, so timeout cleanup has no fixture child.
        try "#!/bin/sh\nexec /bin/sleep 10\n".write(to: fixture.runtime.executableURL, atomically: false, encoding: .utf8)
        XCTAssertThrowsError(try CodexModelCatalog().load(runtime: fixture.runtime, deadline: Date().addingTimeInterval(0.05))) {
            XCTAssertEqual($0 as? CodexPluginCLIError, .timedOut)
        }
    }
}

/// A disposable CLI, not a model-list mock: the actual process runner must
/// pass the command and environment before it can read the catalog.
struct CodexModelCatalogFixture: Sendable {
    let root: URL
    let runtime: CodexIntegrationRuntime

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("codex")
        try """
        #!/bin/sh
        test "$#" -eq 2 && test "$1" = debug && test "$2" = models || exit 64
        /bin/cat "$CODEX_HOME/catalog.json"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        runtime = CodexIntegrationRuntime(executableURL: executable, codexHomeURL: root, workingDirectoryURL: root)
    }

    func writeCatalog(_ json: String) throws {
        try json.write(to: root.appendingPathComponent("catalog.json"), atomically: true, encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
