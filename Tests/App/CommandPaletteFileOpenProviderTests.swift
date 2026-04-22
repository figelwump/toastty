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

    func testProviderIndexesSupportedFilesInsideHiddenDirectoriesAndSkipsHiddenFiles() async throws {
        let fixture = try TemporaryProviderFileScope(
            files: [
                ".agents/skills/worktree-create/SKILL.md": "# Worktree Create\n",
                ".claude/CLAUDE.md": "# Claude\n",
                ".gitignore": "Derived*\n",
                ".markdownlint.json": "{\n  \"default\": true\n}\n",
                ".git/ignored.md": "# ignored\n",
                "Derived-tests/cache.json": "{\n  \"ignored\": true\n}\n",
                "DerivedData/build-log.md": "# ignored\n",
                "DerivedState/model.md": "# keep\n",
                ".yarn/cache/dep.md": "# ignored\n",
                ".yarn/unplugged/dep.md": "# ignored\n",
            ]
        )
        let provider = CommandPaletteFileOpenProvider()
        let scope = PaletteFileSearchScope(
            rootPath: fixture.rootURL.path,
            kind: .workingDirectory
        )

        let results = await provider.indexedFiles(in: scope)
        let relativePaths = Set(results.map(\.relativePath))

        XCTAssertTrue(relativePaths.contains(".agents/skills/worktree-create/SKILL.md"))
        XCTAssertTrue(relativePaths.contains(".claude/CLAUDE.md"))
        XCTAssertTrue(relativePaths.contains(".gitignore"))
        XCTAssertTrue(relativePaths.contains("DerivedState/model.md"))
        XCTAssertFalse(relativePaths.contains(".markdownlint.json"))
        XCTAssertFalse(relativePaths.contains(".git/ignored.md"))
        XCTAssertFalse(relativePaths.contains("Derived-tests/cache.json"))
        XCTAssertFalse(relativePaths.contains("DerivedData/build-log.md"))
        XCTAssertFalse(relativePaths.contains(".yarn/cache/dep.md"))
        XCTAssertFalse(relativePaths.contains(".yarn/unplugged/dep.md"))
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
        XCTAssertEqual(
            CommandPaletteFileOpenRouting.destination(
                forNormalizedFilePath: "/tmp/.gitignore"
            ),
            .localDocument(filePath: "/tmp/.gitignore")
        )
        XCTAssertNil(
            CommandPaletteFileOpenRouting.destination(
                forNormalizedFilePath: "/tmp/notes.txt"
            )
        )
    }

    func testProviderReusesFreshCachedResultsWithoutRescanning() async {
        let scope = PaletteFileSearchScope(rootPath: "/tmp/toastty-cache", kind: .workingDirectory)
        let readme = makeFileResult(
            filePath: "/tmp/toastty-cache/README.md",
            relativePath: "README.md"
        )
        let scanSpy = ProviderScanSpy(responses: [[readme]])
        let provider = CommandPaletteFileOpenProvider(
            staleAfter: 60,
            scanScope: { rootPath in
                await scanSpy.scan(rootPath: rootPath)
            }
        )

        let initialSnapshot = await provider.prepareIndex(in: scope)
        XCTAssertTrue(initialSnapshot.isIndexing)

        let firstResults = await provider.indexedFiles(in: scope)
        let secondSnapshot = await provider.prepareIndex(in: scope)
        let secondResults = await provider.indexedFiles(in: scope)
        let totalInvocationCount = await scanSpy.invocationCount()

        XCTAssertEqual(firstResults, [readme])
        XCTAssertEqual(secondSnapshot, .ready(results: [readme]))
        XCTAssertEqual(secondResults, [readme])
        XCTAssertEqual(totalInvocationCount, 1)
    }

    func testProviderMaintainsSeparateCachesPerScope() async {
        let firstScope = PaletteFileSearchScope(rootPath: "/tmp/toastty-first", kind: .workingDirectory)
        let secondScope = PaletteFileSearchScope(rootPath: "/tmp/toastty-second", kind: .workingDirectory)
        let firstReadme = makeFileResult(
            filePath: "/tmp/toastty-first/README.md",
            relativePath: "README.md"
        )
        let secondReadme = makeFileResult(
            filePath: "/tmp/toastty-second/README.md",
            relativePath: "README.md"
        )
        let scanSpy = ProviderScanSpy(
            responsesByRootPath: [
                firstScope.rootPath: [[firstReadme]],
                secondScope.rootPath: [[secondReadme]],
            ]
        )
        let provider = CommandPaletteFileOpenProvider(
            staleAfter: 60,
            scanScope: { rootPath in
                await scanSpy.scan(rootPath: rootPath)
            }
        )

        _ = await provider.prepareIndex(in: firstScope)
        _ = await provider.prepareIndex(in: secondScope)
        let firstResults = await provider.indexedFiles(in: firstScope)
        let secondResults = await provider.indexedFiles(in: secondScope)
        let firstScopeInvocationCount = await scanSpy.invocationCount(for: firstScope.rootPath)
        let secondScopeInvocationCount = await scanSpy.invocationCount(for: secondScope.rootPath)

        XCTAssertEqual(firstResults, [firstReadme])
        XCTAssertEqual(secondResults, [secondReadme])
        XCTAssertEqual(firstScopeInvocationCount, 1)
        XCTAssertEqual(secondScopeInvocationCount, 1)
    }

    func testProviderReturnsCachedResultsWhileRefreshingStaleIndex() async {
        let scope = PaletteFileSearchScope(rootPath: "/tmp/toastty-stale", kind: .workingDirectory)
        let oldReadme = makeFileResult(
            filePath: "/tmp/toastty-stale/README.md",
            relativePath: "README.md"
        )
        let refreshedReadme = makeFileResult(
            filePath: "/tmp/toastty-stale/docs/README.md",
            relativePath: "docs/README.md"
        )
        let scanSpy = ProviderScanSpy(responses: [[oldReadme], [refreshedReadme]])
        let provider = CommandPaletteFileOpenProvider(
            staleAfter: 0,
            scanScope: { rootPath in
                await scanSpy.scan(rootPath: rootPath)
            }
        )

        _ = await provider.prepareIndex(in: scope)
        let firstResults = await provider.indexedFiles(in: scope)
        let staleSnapshot = await provider.prepareIndex(in: scope)
        let refreshedResults = await provider.indexedFiles(in: scope)
        let totalInvocationCount = await scanSpy.invocationCount()

        XCTAssertEqual(firstResults, [oldReadme])
        XCTAssertEqual(staleSnapshot, .indexing(results: [oldReadme]))
        XCTAssertEqual(refreshedResults, [refreshedReadme])
        XCTAssertEqual(totalInvocationCount, 2)
    }
}

private actor ProviderScanSpy {
    private var defaultResponses: [[PaletteFileResult]]
    private var responsesByRootPath: [String: [[PaletteFileResult]]]
    private var invocationCounts: [String: Int] = [:]

    init(
        responses: [[PaletteFileResult]] = [],
        responsesByRootPath: [String: [[PaletteFileResult]]] = [:]
    ) {
        self.defaultResponses = responses
        self.responsesByRootPath = responsesByRootPath
    }

    func scan(rootPath: String) async -> [PaletteFileResult] {
        invocationCounts[rootPath, default: 0] += 1

        if var responses = responsesByRootPath[rootPath], responses.isEmpty == false {
            let result = responses.removeFirst()
            responsesByRootPath[rootPath] = responses
            return result
        }

        if defaultResponses.isEmpty == false {
            return defaultResponses.removeFirst()
        }

        return []
    }

    func invocationCount() -> Int {
        invocationCounts.values.reduce(0, +)
    }

    func invocationCount(for rootPath: String) -> Int {
        invocationCounts[rootPath, default: 0]
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

private func makeFileResult(filePath: String, relativePath: String) -> PaletteFileResult {
    PaletteFileResult(
        filePath: filePath,
        fileName: URL(fileURLWithPath: filePath).lastPathComponent,
        relativePath: relativePath,
        destination: .localDocument(filePath: filePath)
    )
}
