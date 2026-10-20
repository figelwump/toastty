import CoreState
import Foundation
import Testing

struct TasksConfigFileTests {
    private let home = "/Users/tester"

    private func parse(_ contents: String) throws -> TasksConfig {
        try TasksConfigFile.parse(contents: contents, homeDirectoryPath: home)
    }

    private func parseError(_ contents: String) -> TasksConfigParseError? {
        do {
            _ = try parse(contents)
            return nil
        } catch let error as TasksConfigParseError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    @Test
    func parsesEveryTable() throws {
        let config = try parse(#"""
        # comment
        [triage]
        command = "claude -p --model claude-sonnet-5-5 --effort medium"
        guidelines = """
        Bugs with a repro: codex. # not a comment
        Design questions: claude.
        """
        timeout_seconds = 90

        [defaults]
        agent = "claude"
        model = "claude-opus-5-5"
        effort = "high"
        merge = "agent"
        merge_prompt = "Use toastty-task-merge."

        [quick_entry]
        shortcut = "opt+shift+t"

        [workspace."~/GiantThings/repos/toastty"]
        guidelines = "iOS tasks: read ios/AGENTS.md first."
        create_hook = "scripts/dev/bootstrap-worktree.sh"
        branch_prefix = "fix"
        release_tags = "v*"  # trailing comment
        release_prompt = "Use toastty-release, then toastty-publish."

        [workspace."/srv/website"]
        merge = "direct"
        """#)

        #expect(config.triage == TasksConfig.Triage(
            command: "claude -p --model claude-sonnet-5-5 --effort medium",
            guidelines: "Bugs with a repro: codex. # not a comment\nDesign questions: claude.",
            timeoutSeconds: 90
        ))
        #expect(config.defaults == TasksConfig.Defaults(
            agent: "claude",
            model: "claude-opus-5-5",
            effort: "high",
            merge: .agent,
            mergePrompt: "Use toastty-task-merge."
        ))
        #expect(config.quickEntry.shortcut == "opt+shift+t")
        #expect(config.workspaces == [
            TasksConfig.Workspace(
                path: "~/GiantThings/repos/toastty",
                guidelines: "iOS tasks: read ios/AGENTS.md first.",
                createHook: "scripts/dev/bootstrap-worktree.sh",
                branchPrefix: "fix",
                releaseTags: "v*",
                releasePrompt: "Use toastty-release, then toastty-publish."
            ),
            TasksConfig.Workspace(path: "/srv/website", merge: .direct),
        ])
    }

    @Test
    func emptyFileAndMissingFileAreEmpty() throws {
        #expect(try parse("") == .empty)
        #expect(try parse("# only comments\n\n") == .empty)
        let missingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-tasks-config-\(UUID().uuidString)").path
        #expect(try TasksConfigFile.load(homeDirectoryPath: missingHome) == .empty)
    }

    @Test
    func triageTimeoutDefaults() throws {
        #expect(try parse("[triage]\ncommand = \"x\"").triage?.timeoutSeconds == TasksConfig.Triage.defaultTimeoutSeconds)
    }

    @Test(arguments: [
        ("[create]\nscript = \"x\"", 1, "create_hook"),
        ("[start]\nskill = \"task-start\"", 1, "guidelines"),
        ("[triage]\nprofile = \"claude\"", 2, "command"),
        ("[triage]\nguidance = \"x\"", 2, "renamed to guidelines"),
        ("[triage]\ntimeout-seconds = 60", 2, "timeout_seconds"),
    ])
    func earlierDraftKeysNameTheirReplacement(contents: String, line: Int, mention: String) {
        let error = parseError(contents)
        #expect(error?.line == line)
        #expect(error?.message.contains(mention) == true)
    }

    @Test(arguments: [
        ("[tasks]", 1, "unknown table [tasks]"),
        ("[[defaults]]", 1, "invalid table header"),
        ("agent = \"claude\"", 1, "before keys"),
        ("[defaults]\nagent claude", 2, "expected key = value"),
        ("[defaults]\nagent = claude", 2, "quoted string or a whole number"),
        ("[defaults]\nagent = \"\"", 2, "is empty"),
        ("[defaults]\ncolor = \"red\"", 2, "unknown key 'color'"),
        ("[defaults]\nagent = \"a\"\nagent = \"b\"", 3, "duplicate agent"),
        ("[defaults]\n[defaults]", 2, "duplicate table"),
        ("[defaults]\nmodel = \"gpt 6\"", 2, "one word"),
        ("[defaults]\neffort = \"-x\"", 2, "one word"),
        ("[defaults]\nmerge = \"auto\"", 2, "\"agent\" or \"direct\""),
        ("[defaults]\nagent = 3", 2, "must be a quoted string"),
        ("[triage]\ntimeout_seconds = 4", 2, "from 5 to 600"),
        ("[triage]\nguidelines = \"a\"\nguidelines_file = \"b\"", 3, "keep one"),
        ("[triage]\nguidelines = \"\"\"\nnever closed", 2, "unterminated"),
        ("[triage]\ncommand = \"\"\"a\"\"\" extra", 2, "after closing"),
        ("[workspace.toastty]", 1, "in quotes"),
        ("[workspace.\"repos/toastty\"]", 1, "absolute"),
        ("[workspace.\"/r\"]\nbranch_prefix = \"Fix\"", 2, "branch_prefix"),
        ("[workspace.\"/r\"]\nrelease_tag = \"v*\"", 2, "unknown key 'release_tag'"),
    ])
    func reportsErrorsWithLines(contents: String, line: Int, mention: String) {
        let error = parseError(contents)
        #expect(error?.line == line, "\(contents)")
        #expect(error?.message.contains(mention) == true, "\(error?.message ?? "no error")")
    }

    @Test
    func rejectsTwoTablesForTheSameDirectory() {
        let error = parseError("""
        [workspace."~/repos/toastty"]
        [workspace."/Users/tester/repos/toastty/"]
        """)
        #expect(error?.line == 2)
        #expect(error?.message.contains("line 1") == true)
    }

    @Test
    func findsWorkspaceByProjectRoot() throws {
        let config = try parse("""
        [workspace."~/repos/toastty"]
        release_tags = "v*"
        """)
        #expect(config.workspace(forProjectRoot: "/Users/tester/repos/toastty", homeDirectoryPath: home)?.releaseTags == "v*")
        #expect(config.workspace(forProjectRoot: "/Users/tester/repos/toastty/", homeDirectoryPath: home) != nil)
        #expect(config.workspace(forProjectRoot: "/Users/tester/repos/other", homeDirectoryPath: home) == nil)
    }
}
