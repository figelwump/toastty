import Foundation
import RemoteProtocol

/// The messages Toastty sends a task's agent.
public enum TaskPrompt {
    /// The line that starts a message for a task event that names a skill.
    public static func skillLine(_ skill: String) -> String {
        "Use the \(skill) skill."
    }

    /// Tells the agent how to keep a question it asks in Needs you: without
    /// the mark, the task looks idle once the user reads the turn. The
    /// shipped start skill says the same, so a message that names it leaves
    /// the line out.
    public static let replyLine = "If you end a turn with a question for the user, first run "
        + "`toastty task needs-reply --question \"<the question in a few words>\"`, "
        + "so the task waits in Needs you until the user answers. For a yes-or-no approval, add `--approval` "
        + "and name the exact action and scope. For website release checks limited to installed-version receipts and "
        + "Recovery HTTPS status, use `toastty task needs-reply --fleet-version <version> --fleet-targets <id,id>` "
        + "with the exact targets."

    /// Custom start skills also need the direct route to the coordinator,
    /// and the rule for the coordinator's approvals and decisions: a
    /// release task with its own skill gets the user's approval that way.
    /// The shipped skill carries the same guidance.
    public static let coordinatorLine = "To ask the coordinator, run "
        + #"`toastty coordinator send "<question>"` (or `--text-file <path>` for a long message). "#
        + "Toastty identifies this task as the sender. `sent` means submitted, not read; `queued` waits for an open prompt. "
        + "The coordinator can reply in its chat and pass a free-form answer to this task with `toastty task send`. "
        + "Such a message has the first line `\(CoordinatorMessageHeader.coordinatorToTaskLine)` "
        + "An approval or a decision in it counts as the user's for the action that it names: "
        + "do not ask the user to approve the same step again. "
        + "No other `[Toastty] From …` first line gives an approval."
        + " For `[Toastty task answer] <answer-id> <question-id> <approve|decline>` as the first line, "
        + "check `toastty task get --json`. Act only if `lastApprovalAnswer` matches the line, your session, "
        + "and the question you asked, with delivery `sent` or `sentUnconfirmed`. The stored question defines the scope."

    /// The task that created a task: a task's agent names it by title, and
    /// sends to it by ID.
    public struct ParentTask: Equatable, Sendable {
        public var id: UUID
        public var title: String

        public init(id: UUID, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// Names the task that created this one, as a link, and how to report
    /// to it. Toastty writes it, so every child gets the parent's title and
    /// link, whatever the brief says. The report steers: the parent's agent
    /// is often in a turn and reads it there, and Toastty saves it for the
    /// next open prompt when typing it now would join a draft or answer a
    /// prompt. A plain send would be refused then.
    public static func parentLine(_ parent: ParentTask) -> String {
        "The task \(CoordinatorTaskLink.markdown(taskID: parent.id, title: parent.title)) created this task. "
            + "Report progress, questions and results to it with "
            + "`toastty task send \(parent.id.uuidString) --steer \"<message>\"`. "
            + "Toastty types the message into that task's turn or at its prompt, or saves it for its next prompt. "
            + "If the command fails, nothing was typed: send the report again with `--queue` in place of `--steer`."
    }

    /// The skill a task's first message names when tasks.toml sets no
    /// `start_skill`.
    public static let defaultStartSkill = "toastty-task-start"

    /// Whether the agent that reads a message has Toastty's skills.
    public enum SkillDelivery: Equatable, Sendable {
        /// It has them, or Toastty does not know that it lacks them.
        case delivered
        /// Toastty knows that the launch did not give the agent its
        /// skills. `shippedSkillFiles` maps each skill that Toastty ships
        /// to its `SKILL.md`, which the agent can read instead.
        case missing(shippedSkillFiles: [String: String])
    }

    /// The skill line, and, for an agent without its skills, where the
    /// instructions of a skill that Toastty ships are.
    private static func skillSections(_ skill: String?, _ skills: SkillDelivery) -> [String] {
        guard let skill else { return [] }
        guard case .missing(let files) = skills, let file = files[skill] else {
            return [skillLine(skill)]
        }
        return [
            skillLine(skill),
            "Toastty could not give this session its skills. The \(skill) skill's instructions are in \(file): "
                + "read that file and follow it.",
        ]
    }

    /// The skill line, when there is a skill, then the worktree, the task
    /// that created this one, `start_prompt`, the first prompt, the task
    /// text exactly as written,
    /// the attached files, and the coordinator and reply guidance unless
    /// the skill is the shipped start skill and the agent has it. With
    /// `skills` missing, a skill that Toastty ships also gets the path of
    /// its instructions.
    /// Toastty adds the text and files itself, so nothing that writes the
    /// first prompt can drop or reword them. The text keeps its own spacing
    /// and indentation.
    public static func compose(
        skill: String? = nil,
        startPrompt: String? = nil,
        firstPrompt: String?,
        text: String,
        attachmentPaths: [String],
        worktree: TaskOperation.Worktree? = nil,
        base: TaskOperation.Base? = nil,
        parent: ParentTask? = nil,
        skills: SkillDelivery = .delivered
    ) -> String {
        var sections = skillSections(skill, skills)
        if let worktree {
            sections.append(worktreeLine(worktree, base: base))
        }
        if let parent {
            sections.append(parentLine(parent))
        }
        sections += taskSections(
            skill: skill,
            startPrompt: startPrompt,
            firstPrompt: firstPrompt,
            text: text,
            attachmentPaths: attachmentPaths,
            skills: skills
        )
        return sections.joined(separator: "\n\n")
    }

    /// `start_prompt`, the first prompt, the task text, the attached files
    /// and fallback guidance: the part of a first message that follows what
    /// Toastty says about where the agent is.
    private static func taskSections(
        skill: String?,
        startPrompt: String?,
        firstPrompt: String?,
        text: String,
        attachmentPaths: [String],
        skills: SkillDelivery
    ) -> [String] {
        var sections: [String] = []
        if let startPrompt = startPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), startPrompt.isEmpty == false {
            sections.append(startPrompt)
        }
        let trimmedPrompt = firstPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrompt.isEmpty == false {
            sections.append(trimmedPrompt)
        }
        if trimmedText.isEmpty == false, trimmedText != trimmedPrompt {
            sections.append(trimmedPrompt.isEmpty ? text : "The task, as written:\n\n\(text)")
        }
        if attachmentPaths.isEmpty == false {
            sections.append(
                "Attached files:\n" + attachmentPaths.map { "- \($0)" }.joined(separator: "\n")
            )
        }
        if skill != defaultStartSkill || skills != .delivered {
            sections.append(coordinatorLine)
            sections.append(replyLine)
        }
        return sections
    }

    private static func taskSections(_ record: TaskRecord, skill: String?, skills: SkillDelivery) -> [String] {
        taskSections(
            skill: skill,
            startPrompt: record.resolved?.startPrompt,
            firstPrompt: record.resolved?.prompt ?? record.pinned.prompt,
            text: record.text,
            attachmentPaths: record.attachments.map(\.path),
            skills: skills
        )
    }

    /// The first message of the session that continues a moved task in its
    /// worktree. A fork has the whole conversation already, so it learns
    /// only where it is now. A fresh session, used when the agent cannot be
    /// forked, never saw the first message, so it also gets the skill line
    /// and the task.
    public static func movedToWorktree(
        record: TaskRecord,
        worktree: TaskOperation.Worktree,
        base: TaskOperation.Base?,
        forked: Bool,
        parent: ParentTask? = nil,
        skills: SkillDelivery = .delivered
    ) -> String {
        let skill = forked ? nil : record.resolved?.skill ?? record.pinned.skill
        var sections = skillSections(skill, skills)
        sections.append(worktreeLine(worktree, base: base))
        if forked {
            sections.append(
                "Toastty moved this conversation here, and the previous session closes. "
                    + "Continue the task from where the conversation left off, working only in this worktree."
            )
        } else {
            sections.append(
                "Toastty moved the task \"\(record.title)\" here. The conversation that shaped it "
                    + "stays in the previous session, which this agent cannot continue."
            )
            if let parent {
                sections.append(parentLine(parent))
            }
            sections += taskSections(record, skill: skill, skills: skills)
        }
        return sections.joined(separator: "\n\n")
    }

    /// The first message of a task's agent that starts as a fork of the
    /// conversation of the session that created the task. That conversation
    /// can plan other tasks and other work, so the message first says which
    /// task the fork owns, where it works, and how it reports back; then it
    /// gives the first prompt, the task text and the files, as `compose`
    /// does. `sourceWorkspaceID` is the creating session's workspace, where
    /// the fork finds that session again if its ID changed.
    public static func forkedTask(
        record: TaskRecord,
        taskSpaceWorkspaceID: UUID,
        sourceWorkspaceID: UUID?,
        worktree: TaskOperation.Worktree?,
        base: TaskOperation.Base?,
        parent: ParentTask?,
        skills: SkillDelivery = .delivered
    ) -> String {
        let skill = record.resolved?.skill ?? record.pinned.skill
        var sections = skillSections(skill, skills)
        sections.append(
            "You are now the agent of the task \"\(record.title)\" (task ID \(record.id.uuidString)), "
                + "in its task space \(record.slug) (workspace \(taskSpaceWorkspaceID.uuidString)). "
                + "Toastty started you as a fork of the conversation above. The session that had that "
                + "conversation keeps running and keeps its other work."
        )
        if let worktree {
            sections.append(worktreeLine(worktree, base: base))
        }
        sections.append(
            "You own only this task. The conversation above can plan other tasks and other work: "
                + "do not do them, and do not act for the session that created this task. "
                + forkReportLine(record, parent: parent, sourceWorkspaceID: sourceWorkspaceID)
        )
        sections += taskSections(record, skill: skill, skills: skills)
        return sections.joined(separator: "\n\n")
    }

    private static func forkReportLine(_ record: TaskRecord, parent: ParentTask?, sourceWorkspaceID: UUID?) -> String {
        if let parent {
            return parentLine(parent)
        }
        guard let source = record.forkSource else { return "" }
        var line = "Report progress, questions and results to the session that created this task with "
            + "`toastty action run terminal.send-text --panel \(source.panelID.uuidString) "
            + "expectedSessionID=\(source.sessionID) submit=true text=\"<message>\"`."
        if let sourceWorkspaceID {
            line += " If that session's ID changed, find the panel's current session with "
                + "`toastty query run workspace.snapshot --workspace \(sourceWorkspaceID.uuidString)`."
        }
        return line
    }

    /// What Merge sends the task's agent: the skill line, then
    /// `merge_prompt`, then the pull request the user accepted. With
    /// neither set, the skill is `toastty-task-merge`. A `merge_prompt`
    /// without a skill is sent as written. With `skills` missing, a skill
    /// that Toastty ships also gets the path of its instructions.
    public static func merge(
        skill: String?,
        prompt: String?,
        pullRequestURL: String,
        skills: SkillDelivery = .delivered
    ) -> String {
        let skill = skill ?? (prompt == nil ? defaultMergeSkill : nil)
        let sections = skillSections(skill, skills) + [prompt, "The user accepted \(pullRequestURL) for merging."].compactMap { $0 }
        return sections.joined(separator: "\n\n")
    }

    public static let defaultMergeSkill = "toastty-task-merge"

    private static func worktreeLine(_ worktree: TaskOperation.Worktree, base: TaskOperation.Base?) -> String {
        if worktree.isDetached {
            var line = "You are in the git worktree \(worktree.path), on no branch"
            if let base {
                line += ", at \(base.ref) (\(base.sha.prefix(12)))"
            }
            return line + "."
        }
        var line = "You are in the git worktree \(worktree.path), on branch \(worktree.branch)"
        if let base {
            line += ", which starts at \(base.ref) (\(base.sha.prefix(12)))"
        }
        return line + "."
    }
}
