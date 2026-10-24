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
        start_skill = "task-start"
        merge_skill = "toastty-task-merge"
        release_skill = "toastty-release"

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
        start_skill = "website-start"
        merge_skill = "website-merge"
        release_skill = "website-release"
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
            mergePrompt: "Use toastty-task-merge.",
            startSkill: "task-start",
            mergeSkill: "toastty-task-merge",
            releaseSkill: "toastty-release"
        ))
        #expect(config.quickEntry.shortcut == .default)
        #expect(config.workspaces == [
            TasksConfig.Workspace(
                path: "~/GiantThings/repos/toastty",
                guidelines: "iOS tasks: read ios/AGENTS.md first.",
                createHook: "scripts/dev/bootstrap-worktree.sh",
                branchPrefix: "fix",
                releaseTags: "v*",
                releasePrompt: "Use toastty-release, then toastty-publish."
            ),
            TasksConfig.Workspace(
                path: "/srv/website",
                merge: .direct,
                startSkill: "website-start",
                mergeSkill: "website-merge",
                releaseSkill: "website-release"
            ),
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
    func quickEntryShortcutDefaultsAndCanBeTurnedOff() throws {
        #expect(try parse("").quickEntry.shortcut == .default)
        #expect(try parse("[quick_entry]\nshortcut = \"None\"").quickEntry.shortcut == nil)
        #expect(try parse("[quick_entry]\nshortcut = \"ctrl+opt+space\"").quickEntry.shortcut
            == QuickEntryShortcut(modifiers: [.control, .option], key: .space))
    }

    @Test
    func coordinatorDefaultsToClaudeAndCanBeTurnedOff() throws {
        #expect(try parse("").coordinator == TasksConfig.Coordinator(agent: "claude"))
        #expect(try parse("[coordinator]").coordinator == TasksConfig.Coordinator(agent: "claude"))
        #expect(try parse("[coordinator]\nagent = \"None\"").coordinator.agent == nil)
        #expect(try parse("""
        [coordinator]
        agent = "codex"
        model = "gpt-6.1-sol"
        effort = "high"
        """).coordinator == TasksConfig.Coordinator(agent: "codex", model: "gpt-6.1-sol", effort: "high"))
        // A model alone keeps the default agent.
        #expect(try parse("[coordinator]\nmodel = \"claude-opus-5-5\"").coordinator
            == TasksConfig.Coordinator(agent: "claude", model: "claude-opus-5-5"))
    }

    @Test
    func triageTimeoutDefaults() throws {
        #expect(try parse("[triage]\ncommand = \"x\"").triage?.timeoutSeconds == TasksConfig.Triage.defaultTimeoutSeconds)
    }

    @Test(arguments: [
        ("[create]\nscript = \"x\"", 1, "create_hook"),
        ("[start]\nskill = \"task-start\"", 1, "start_skill"),
        ("[defaults]\nskill = \"task-start\"", 2, "start_skill"),
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
        ("[defaults]\nstart_skill = \"task start\"", 2, "[defaults] start_skill must be a skill name with no spaces"),
        ("[defaults]\nmerge_skill = \"  \"", 2, "merge_skill is empty"),
        ("[defaults]\nrelease_skill = 3", 2, "release_skill must be a quoted string"),
        ("[workspace.\"/r\"]\nrelease_skill = \"a\\tb\"", 2, "release_skill must be a skill name with no spaces"),
        ("[workspace.\"/r\"]\nstart_skill = \"\"\"\none\ntwo\n\"\"\"", 2, "start_skill must be one line"),
        ("[coordinator]\nprompt = \"x\"", 2, "[coordinator] contains unknown key 'prompt'"),
        ("[coordinator]\nagent = \"my agent\"", 2, "one word"),
        ("[coordinator]\nagent = \"none\"\neffort = \"high\"", 3, "takes no model or effort"),
        ("[quick_entry]\nshortcut = \"shift+t\"", 2, "[quick_entry] the shortcut \"shift+t\" needs Command"),
        ("[quick_entry]\nshortcut = \"opt+shift+tt\"", 2, "unknown key \"tt\""),
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

    @Test
    func aProjectsSkillOverridesTheDefault() throws {
        let config = try parse("""
        [defaults]
        start_skill = "task-start"

        [workspace."~/repos/toastty"]
        start_skill = "toastty-start"
        release_skill = "toastty-release"

        [workspace."~/repos/notes"]
        release_prompt = "Tag it."

        [workspace."~/repos/site"]
        branch_prefix = "fix"
        """)
        let toastty = "/Users/tester/repos/toastty"
        #expect(config.startSkill(forProjectRoot: toastty, homeDirectoryPath: home) == "toastty-start")
        #expect(config.startSkill(forProjectRoot: "/Users/tester/repos/site", homeDirectoryPath: home) == "task-start")
        #expect(config.startSkill(forProjectRoot: "/Users/tester/repos/other", homeDirectoryPath: home) == "task-start")
        #expect(config.releaseSkill(forProjectRoot: toastty, homeDirectoryPath: home) == "toastty-release")

        // A release skill or a release prompt makes a project releasable.
        #expect(config.canRelease(projectRoot: toastty, homeDirectoryPath: home))
        #expect(config.canRelease(projectRoot: "/Users/tester/repos/notes", homeDirectoryPath: home))
        #expect(config.canRelease(projectRoot: "/Users/tester/repos/site", homeDirectoryPath: home) == false)
        // A release skill in [defaults] applies to every project.
        var everywhere = config
        everywhere.defaults.releaseSkill = "release"
        #expect(everywhere.canRelease(projectRoot: "/Users/tester/repos/site", homeDirectoryPath: home))
        #expect(everywhere.releaseSkill(forProjectRoot: toastty, homeDirectoryPath: home) == "toastty-release")
    }
}
