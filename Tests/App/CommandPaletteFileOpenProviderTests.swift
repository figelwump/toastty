import Foundation
import XCTest
@testable import ToasttyApp

final class CommandPaletteFileOpenProviderTests: XCTestCase {
    func testProviderIndexesSupportedFilesAndSkipsHeavyDirectories() async throws {
        let fixture = try TemporaryProviderFileScope(
            files: [
                "README.md": "# Toastty\n",
                "package.json": "{\n  \"name\": \"toastty\"\n}\n",
                "docs/index.html": "<html></html>\n",
                ".git/ignored.md": "# ignored\n",
                "node_modules/dep.md": "# ignored\n",
                "build/output.html": "<html></html>\n",
                ".build/debug.json": "{}\n",
                "Derived/cache.yaml": "name: ignored\n",
                "notes.txt": "unsupported\n",
            ]
        )
        let provider = CommandPaletteFileOpenProvider()
        let scope = PaletteFileSearchScope(
            rootPath: fixture.rootURL.path,
            kind: .workingDirectory
        )

        let results = await provider.indexedFiles(in: scope)

        XCTAssertEqual(
            Set(results.map(\.title)),
            ["README.md", "package.json", "index.html"]
        )
        XCTAssertTrue(
            results.contains {
                $0.destination == .localDocument(filePath: fixture.path("package.json"))
            }
        )
        XCTAssertTrue(
            results.contains {
                $0.destination == .browser(
                    fileURLString: fixture.url("docs/index.html").absoluteString
                )
            }
        )
    }

    func testRoutingSupportsNewLocalDocumentFormatsAndHTMLOnly() {
        XCTAssertEqual(
            CommandPaletteFileOpenRouting.destination(
                forNormalizedFilePath: "/tmp/package.json"
            ),
            .localDocument(filePath: "/tmp/package.json")
        )
        XCTAssertEqual(
            CommandPaletteFileOpenRouting.destination(
                forNormalizedFilePath: "/tmp/index.html"
            ),
            .browser(fileURLString: URL(fileURLWithPath: "/tmp/index.html").absoluteString)
        )
        XCTAssertNil(
            CommandPaletteFileOpenRouting.destination(
                forNormalizedFilePath: "/tmp/notes.txt"
            )
        )
    }
}

private struct TemporaryProviderFileScope {
    let rootURL: URL

    init(files: [String: String]) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        for (relativePath, contents) in files {
            let fileURL = rootURL.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    func path(_ relativePath: String) -> String {
        url(relativePath).path
    }

    func url(_ relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath)
    }
}
