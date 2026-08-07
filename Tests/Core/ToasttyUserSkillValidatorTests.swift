import CoreState
import Foundation
import Testing

struct ToasttyUserSkillValidatorTests {
    @Test
    func scanAcceptsValidPackageAndRejectsMissingSkillFile() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-core-skills-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let validURL = rootURL.appendingPathComponent("valid-skill", isDirectory: true)
        let invalidURL = rootURL.appendingPathComponent("missing-skill-file", isDirectory: true)
        try FileManager.default.createDirectory(at: validURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: invalidURL, withIntermediateDirectories: true)
        try """
        ---
        name: valid-skill
        description: A valid shared validator fixture.
        ---

        # Valid
        """.write(
            to: validURL.appendingPathComponent("SKILL.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let state = ToasttyUserSkillValidator()
            .scan(userSkillsDirectoryURL: rootURL)
            .state

        #expect(state.packages.map(\.name) == ["missing-skill-file", "valid-skill"])
        #expect(state.packages[0].status == .excluded(.missingSkillFile))
        #expect(state.packages[1].status == .accepted)
    }

    @Test
    func scanOfMissingRootIsEmptyAndReadOnly() {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-core-skills-missing-\(UUID().uuidString)", isDirectory: true)

        let state = ToasttyUserSkillValidator()
            .scan(userSkillsDirectoryURL: rootURL)
            .state

        #expect(state.packages.isEmpty)
        #expect(state.globalDiagnostics.isEmpty)
        #expect(FileManager.default.fileExists(atPath: rootURL.path) == false)
    }
}
