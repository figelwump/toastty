import CoreState
import Testing

struct SocketEventNormalizerTests {
    @Test
    func normalizeFilesKeepsAbsolutePathsAndStandardizes() throws {
        let files = ["/tmp/../tmp/readme.md", "/usr/bin/env"]

        let normalized = try SocketEventNormalizer.normalizeFiles(files, cwd: nil)

        #expect(normalized == ["/tmp/readme.md", "/usr/bin/env"])
    }

    @Test
    func normalizeFilesResolvesRelativePathsAgainstCWD() throws {
        let files = ["docs/implementation-plan.md", "./Project.swift"]
        let normalized = try SocketEventNormalizer.normalizeFiles(
            files,
            cwd: "/Users/vishal/GiantThings/repos/toastty"
        )

        #expect(
            normalized == [
                "/Users/vishal/GiantThings/repos/toastty/docs/implementation-plan.md",
                "/Users/vishal/GiantThings/repos/toastty/Project.swift",
            ]
        )
    }

    @Test
    func normalizeFilesFailsWhenRelativePathsHaveNoCWD() {
        #expect(throws: SocketEventNormalizationError.missingCWDForRelativePath("docs/plan.md")) {
            _ = try SocketEventNormalizer.normalizeFiles(["docs/plan.md"], cwd: nil)
        }
    }
}
