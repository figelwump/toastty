import CoreState
import Foundation

/// The files Toastty keeps in the coordinator's folder.
///
/// - `AGENTS.md` and `CLAUDE.md` are Toastty's. They carry the coordinator's
///   instructions, which are the text of the shipped `toastty-coordinator`
///   skill. An agent reads its folder's instruction file at every start and
///   at every resume, so the coordinator has the instructions of the running
///   Toastty with no step of its own, also in a conversation that began under
///   an older Toastty. Toastty writes both files again whenever they differ.
/// - `policy.md` and `ledger.md` are the user's and the coordinator's.
///   Toastty creates each one when it is missing and never writes it again.
/// - The folder is a git repository, so the coordinator can commit each
///   change of the policy and undo it with a revert.
struct CoordinatorFolder: Sendable {
    static let instructionsFileName = "AGENTS.md"
    static let claudeInstructionsFileName = "CLAUDE.md"
    static let policyFileName = "policy.md"
    static let ledgerFileName = "ledger.md"

    static let instructionsHeader = """
    <!-- Toastty writes this file and replaces it when Toastty changes. Do not edit it. Your own rules go in policy.md. -->

    """

    /// Claude Code reads `CLAUDE.md`, not `AGENTS.md`; the import keeps one
    /// copy of the text.
    static let claudeInstructions = """
    <!-- Toastty writes this file and replaces it. Your own rules go in policy.md. -->
    @AGENTS.md

    """

    /// The section headings only: the coordinator fills them by asking.
    static let policyTemplate = """
    # Coordinator policy

    ## Projects

    ## Agents

    ## Talking

    ## Reviewing

    ## Unblocking

    ## Releases

    ## Notes (kept by the coordinator)

    """

    static let ledgerTemplate = """
    # Coordinator ledger

    """

    /// Kept out of the repository: Toastty's own files, the ledger, which
    /// changes on most wakes, and an agent's local settings. A commit then
    /// holds a change of the policy and nothing else.
    static let repositoryExcludes = ["AGENTS.md", "CLAUDE.md", "ledger.md", ".claude/"]

    /// The environment of the coordinator's agent. Without its own `.git`,
    /// the folder would use the first repository git finds in a folder
    /// above it, such as a home folder kept in git for dotfiles, and a
    /// change of the policy would be committed there. With the folder's
    /// parent as a ceiling, git stops at the folder and fails instead. The
    /// ceiling changes nothing for a path outside that parent, such as a
    /// project's repository.
    static func gitEnvironment(for directoryURL: URL) -> [String: String] {
        ["GIT_CEILING_DIRECTORIES": directoryURL.standardizedFileURL.deletingLastPathComponent().path]
    }

    let directoryURL: URL
    /// The coordinator's instructions, or `nil` when Toastty cannot read
    /// them.
    var instructions: @Sendable () -> String? = { CoordinatorFolder.shippedInstructions() }
    var runner: any TaskCommandRunning = TaskLiveCommandRunner()
    /// The environment for git: the login shell's PATH, without Toastty's
    /// session variables.
    var environment: @Sendable () -> [String: String] = {
        TaskCommandEnvironment.make(path: TaskWorktreeCreator.LoginPath.value())
    }

    /// The text of the shipped `toastty-coordinator` skill, without its
    /// front matter.
    static func shippedInstructions(pluginURL: URL? = ToasttyAgentPluginBundle.bundledPluginURL()) -> String? {
        guard let skillURL = pluginURL?.appending(path: "skills/toastty-coordinator/SKILL.md", directoryHint: .notDirectory),
              let text = try? String(contentsOf: skillURL, encoding: .utf8) else {
            return nil
        }
        return instructionsBody(ofSkill: text)
    }

    /// A skill file starts with front matter between two `---` lines, which
    /// only a skill loader reads.
    static func instructionsBody(ofSkill text: String) -> String? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines = lines.dropFirst()
        guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body + "\n"
    }

    // MARK: - Files

    /// Creates the folder, writes Toastty's instruction files when they
    /// differ, and creates the policy and the ledger when they are missing.
    /// Returns the folder's path.
    @discardableResult
    func prepareFiles() throws -> String {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw CoordinatorError("Toastty could not create the coordinator's folder \(directoryURL.path): \(error.localizedDescription)")
        }
        guard let instructions = instructions() else {
            throw CoordinatorError("Toastty could not read the coordinator's instructions from the app. Install Toastty again.")
        }
        do {
            try write(Self.instructionsHeader + "\n" + instructions, to: Self.instructionsFileName)
            try write(Self.claudeInstructions, to: Self.claudeInstructionsFileName)
            try createIfMissing(Self.policyTemplate, at: Self.policyFileName)
            try createIfMissing(Self.ledgerTemplate, at: Self.ledgerFileName)
        } catch {
            throw CoordinatorError("Toastty could not write the coordinator's files in \(directoryURL.path): \(error.localizedDescription)")
        }
        return directoryURL.path
    }

    /// Replaces a file of Toastty's own when its text differs.
    private func write(_ text: String, to name: String) throws {
        let url = directoryURL.appending(path: name, directoryHint: .notDirectory)
        if let current = try? String(contentsOf: url, encoding: .utf8), current == text { return }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Creates a file of the user's. Anything already at that path stays as
    /// it is, also an empty file: the user or the coordinator put it there.
    private func createIfMissing(_ text: String, at name: String) throws {
        let url = directoryURL.appending(path: name, directoryHint: .notDirectory)
        // `attributesOfItem` also finds a link whose target is gone.
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else { return }
        // `withoutOverwriting` keeps a file that appeared since the check.
        do {
            try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            return
        }
    }

    // MARK: - Repository

    /// Makes the folder a git repository with the policy as its first
    /// commit. A folder that already has one is left as it is. A failure
    /// stops no start: the coordinator then tells the user that a change of
    /// the policy cannot be undone.
    func prepareRepository() async {
        let directory = directoryURL.path
        guard FileManager.default.fileExists(atPath: directoryURL.appending(path: ".git").path) == false else { return }
        // The identity and the signing setting are the repository's own, so
        // a commit never fails for a missing identity and never waits for a
        // signing key.
        let steps: [[String]] = [
            ["init", "-q"],
            ["config", "user.name", "Toastty Coordinator"],
            ["config", "user.email", "coordinator@toastty.invalid"],
            ["config", "commit.gpgsign", "false"],
            ["add", "--", Self.policyFileName],
            ["commit", "-q", "-m", "Start the coordinator's policy", "--", Self.policyFileName],
        ]
        for (index, arguments) in steps.enumerated() {
            if let failure = await git(arguments, in: directory) {
                ToasttyLog.warning("Could not prepare the coordinator's repository", category: .tasks, metadata: [
                    "step": arguments.first ?? "",
                    "reason": failure,
                ])
                return
            }
            if index == 0 {
                writeExcludes()
            }
        }
        ToasttyLog.info("Made the coordinator's folder a git repository", category: .tasks, metadata: ["directory": directory])
    }

    private func writeExcludes() {
        let url = directoryURL.appending(path: ".git/info/exclude", directoryHint: .notDirectory)
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let text = current + (current.isEmpty || current.hasSuffix("\n") ? "" : "\n")
            + Self.repositoryExcludes.joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            ToasttyLog.warning("Could not write the coordinator repository's excludes", category: .tasks, metadata: [
                "reason": error.localizedDescription,
            ])
        }
    }

    /// Runs one git command in the folder. Returns why it failed, or `nil`.
    private func git(_ arguments: [String], in directory: String) async -> String? {
        let result = await runner.run(TaskCommand(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", directory] + arguments,
            directory: directory,
            environment: environment(),
            timeout: 30
        ))
        switch result.termination {
        case .exited(0):
            return nil
        case .exited(let status):
            let last = result.stderrText.split(whereSeparator: \.isNewline).last.map(String.init)
            return last?.trimmingCharacters(in: .whitespaces) ?? "exit status \(status)"
        case .signaled(let signal):
            return "git stopped on signal \(signal)"
        case .timedOut:
            return "git did not finish within 30 seconds"
        case .cancelled:
            return "cancelled"
        case .launchFailed(let reason):
            return reason
        }
    }
}
