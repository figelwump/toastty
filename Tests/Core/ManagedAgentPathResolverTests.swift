import CoreState
import Foundation
import Testing

struct ManagedAgentPathResolverTests {
    @Test
    func mergedPathAppendsBaseEntriesWithoutDuplicatingCurrentEntries() {
        let mergedPath = ManagedAgentPathResolver.mergedPath(
            currentPath: "/tmp/shim:/usr/bin:/bin",
            basePath: "/usr/bin:/Users/test/.bun/bin:/bin:/Users/test/.local/bin"
        )

        #expect(mergedPath == "/tmp/shim:/usr/bin:/bin:/Users/test/.bun/bin:/Users/test/.local/bin")
    }

    @Test
    func resolvedExecutablePathFallsBackToAgentBasePath() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-agent-path-resolver-\(UUID().uuidString)", isDirectory: true)
        let shimDirectoryURL = rootURL.appendingPathComponent("shim", isDirectory: true)
        let toolsDirectoryURL = rootURL.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: shimDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: toolsDirectoryURL, withIntermediateDirectories: true)

        let executableURL = toolsDirectoryURL.appendingPathComponent("codex", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let resolvedPath = ManagedAgentPathResolver.resolvedExecutablePath(
            commandName: "codex",
            currentPath: shimDirectoryURL.path,
            basePath: toolsDirectoryURL.path,
            excludedDirectoryPaths: [shimDirectoryURL.path]
        )

        #expect(resolvedPath == executableURL.path)
    }

    @Test
    func sanitizedMergedPathDropsRelativeEmptyDuplicateAndExcludedEntries() {
        let path = ManagedAgentPathResolver.sanitizedMergedPath(
            preferredPath: "/tmp/toastty-shims:relative:/Users/test/.nvm/bin:/usr/bin::/usr/bin",
            fallbackPath: "/bin:/Users/test/.nvm/bin:.",
            excludedDirectoryPaths: ["/tmp/toastty-shims"]
        )

        #expect(path == "/Users/test/.nvm/bin:/usr/bin:/bin")
    }

    @Test
    func sanitizedMergedPathReturnsNilRatherThanReplacingAnInheritedPathWithEmptyText() {
        let path = ManagedAgentPathResolver.sanitizedMergedPath(
            preferredPath: "relative:.",
            fallbackPath: nil
        )

        #expect(path == nil)
    }

    @Test
    func sanitizedMergedPathExcludesSymlinkAliasesAndCanonicalDuplicates() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-agent-path-\(UUID().uuidString)", isDirectory: true)
        let shimURL = rootURL.appendingPathComponent("actual-shims", isDirectory: true)
        let shimAliasURL = rootURL.appendingPathComponent("shim-alias", isDirectory: true)
        let binURL = rootURL.appendingPathComponent("actual-bin", isDirectory: true)
        let binAliasURL = rootURL.appendingPathComponent("bin-alias", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try FileManager.default.createDirectory(at: shimURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: shimAliasURL, withDestinationURL: shimURL)
        try FileManager.default.createSymbolicLink(at: binAliasURL, withDestinationURL: binURL)

        let path = ManagedAgentPathResolver.sanitizedMergedPath(
            preferredPath: "\(shimAliasURL.path):\(binAliasURL.path)",
            fallbackPath: "\(shimURL.path):\(binURL.path):/usr/bin",
            excludedDirectoryPaths: [shimURL.path]
        )

        #expect(path == "\(binAliasURL.path):/usr/bin")
    }
}
