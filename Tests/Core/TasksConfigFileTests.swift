import CoreState
import Foundation
import Testing

struct TasksConfigFileTests {
    @Test
    func templateParsesAsEmptyConfig() throws {
        #expect(try TasksConfigFile.parse(contents: TasksConfigFile.templateContents()) == .empty)
    }

    @Test
    func parsesEverySectionWithDefaultsAndMultilineGuidance() throws {
        let config = try TasksConfigFile.parse(contents: """
        [triage]
        profile = "claude"   # the triage CLI
        model = "claude-haiku-5-5"
        effort = "low"
        guidance = \"\"\"
        toastty is the app. # this is text, not a comment
          website is the site.
        \"\"\"

        [create]
        script = "~/bin/task-create.sh"
        timeout-seconds = 1_200

        [start]
        skill = "task-start"
        """)

        #expect(config.triage == TasksConfig.Triage(
            profileID: "claude",
            model: "claude-haiku-5-5",
            effort: "low",
            timeoutSeconds: 60,
            guidance: "toastty is the app. # this is text, not a comment\n  website is the site."
        ))
        #expect(config.create == TasksConfig.Create(script: "~/bin/task-create.sh", timeoutSeconds: 1200))
        #expect(config.start == TasksConfig.Start(skill: "task-start"))
    }

    @Test
    func parsesSingleLineTripleQuotedGuidance() throws {
        let config = try TasksConfigFile.parse(contents: """
        [triage]
        profile = "codex"
        guidance = \"\"\"Prefer codex.\"\"\"
        """)
        #expect(config.triage?.guidance == "Prefer codex.")
        #expect(config.create == nil)
        #expect(config.start == nil)
    }

    @Test(arguments: [
        ("[triage]\nmodel = \"x\"", 1, "[triage] is missing profile"),
        ("[create]\ntimeout-seconds = 10", 1, "[create] is missing script"),
        ("[start]\n", 1, "[start] is missing skill"),
        ("profile = \"claude\"", 1, "expected a [triage], [create] or [start] table before keys"),
        ("[hooks]", 1, "unknown table [hooks]; expected [triage], [create] or [start]"),
        ("[start]\nskill = \"a\"\n[start]", 3, "duplicate table [start]"),
        ("[start]\nskill = \"a\"\nskill = \"b\"", 3, "[start] has duplicate skill"),
        ("[start]\nskill = \"a\"\nhook = \"b\"", 3, "[start] contains unknown key 'hook'"),
        ("[start]\nskill = \"../x\"", 2, "[start] skill must be 1-64 ASCII letters, digits, '.', '_' or '-', and not start with '.'"),
        ("[start]\nskill = \"\"", 2, "[start] skill is empty"),
        ("[triage]\nprofile = \"Claude Code\"", 2, "[triage] profile 'Claude Code' is not a profile ID"),
        ("[triage]\nprofile = \"claude\"\nmodel = \"--yolo\"", 3, "[triage] model must be one word with no spaces that doesn't start with a dash"),
        ("[triage]\nprofile = \"claude\"\ntimeout-seconds = 2", 3, "[triage] timeout-seconds must be a whole number from 5 to 600"),
        ("[triage]\nprofile = \"claude\"\ntimeout-seconds = \"60\"", 3, "[triage] timeout-seconds must be a whole number from 5 to 600"),
        ("[create]\nscript = 12", 2, "[create] script must be a quoted string"),
        ("[create]\nscript = path", 2, "[create] script must be a quoted string or a whole number"),
        ("[triage]\nprofile = \"claude\"\nguidance = \"\"\"\nno end", 3, "unterminated multiline string"),
        ("[triage", 1, "invalid table header"),
    ])
    func reportsErrorsWithLineNumbers(contents: String, line: Int, message: String) {
        #expect(throws: TasksConfigParseError(line: line, message: message)) {
            try TasksConfigFile.parse(contents: contents)
        }
    }

    @Test
    func loadReadsOverridePathAndTreatsMissingFileAsEmpty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "tasks-config-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "tasks.toml")
        let environment = [TasksConfigFile.environmentOverrideKey: url.path]

        #expect(try TasksConfigFile.load(environment: environment) == .empty)

        try "[start]\nskill = \"task-start\"\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(try TasksConfigFile.load(environment: environment).start?.skill == "task-start")

        // An override path is never filled with the template.
        try FileManager.default.removeItem(at: url)
        try TasksConfigFile.ensureTemplateExists(environment: environment)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test
    func fileFollowsTheUserHomeInRuntimeIsolatedRuns() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "tasks-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let environment = ["TOASTTY_RUNTIME_HOME": root.appending(path: "runtime").path]

        try TasksConfigFile.ensureTemplateExists(homeDirectoryPath: home.path, environment: environment)
        let url = TasksConfigFile.fileURL(homeDirectoryPath: home.path, environment: environment)
        #expect(url.path == home.appending(path: ".toastty/tasks.toml").path)
        #expect(try String(contentsOf: url, encoding: .utf8) == TasksConfigFile.templateContents())

        try "[start]\nskill = \"mine\"\n".write(to: url, atomically: true, encoding: .utf8)
        try TasksConfigFile.ensureTemplateExists(homeDirectoryPath: home.path, environment: environment)
        #expect(try TasksConfigFile.load(homeDirectoryPath: home.path, environment: environment).start?.skill == "mine")
    }
}
