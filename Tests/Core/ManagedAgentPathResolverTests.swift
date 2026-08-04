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
    func executablePathValidationRejectsSymlinkToExcludedExecutable() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-agent-path-resolver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let shimExecutableURL = rootURL.appendingPathComponent("toastty-agent-shim", isDirectory: false)
        let piLinkURL = rootURL.appendingPathComponent("pi", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: shimExecutableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: shimExecutableURL.path
        )
        try FileManager.default.createSymbolicLink(at: piLinkURL, withDestinationURL: shimExecutableURL)

        let isAllowed = ManagedAgentPathResolver.isExecutablePathAllowed(
            piLinkURL.path,
            excludedExecutablePaths: [shimExecutableURL.path],
            canonicalPathProvider: { path in
                URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            }
        )

        #expect(isAllowed == false)
    }
}
