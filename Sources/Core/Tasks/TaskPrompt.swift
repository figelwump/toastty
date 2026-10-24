import Foundation

/// The messages Toastty sends a task's agent.
public enum TaskPrompt {
    /// The line that starts a message for a task event that names a skill.
    public static func skillLine(_ skill: String) -> String {
        "Use the \(skill) skill."
    }

    /// The skill line, when there is a skill, then the worktree, the first
    /// prompt, the task text exactly as written, and the attached files.
    /// Toastty adds the text and files itself, so nothing that writes the
    /// first prompt can drop or reword them. The text keeps its own spacing
    /// and indentation.
    public static func compose(
        skill: String? = nil,
        firstPrompt: String?,
        text: String,
        attachmentPaths: [String],
        worktree: TaskOperation.Worktree? = nil,
        base: TaskOperation.Base? = nil
    ) -> String {
        var sections: [String] = []
        if let skill {
            sections.append(skillLine(skill))
        }
        if let worktree {
            sections.append(worktreeLine(worktree, base: base))
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
        return sections.joined(separator: "\n\n")
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
        forked: Bool
    ) -> String {
        let skill = forked ? nil : record.resolved?.skill ?? record.pinned.skill
        var sections = skill.map { [skillLine($0)] } ?? []
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
            sections.append(compose(
                firstPrompt: record.resolved?.prompt ?? record.pinned.prompt,
                text: record.text,
                attachmentPaths: record.attachments.map(\.path)
            ))
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
        base: TaskOperation.Base?
    ) -> String {
        let skill = record.resolved?.skill ?? record.pinned.skill
        var sections = skill.map { [skillLine($0)] } ?? []
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
                + forkReportLine(record, sourceWorkspaceID: sourceWorkspaceID)
        )
        sections.append(compose(
            firstPrompt: record.resolved?.prompt ?? record.pinned.prompt,
            text: record.text,
            attachmentPaths: record.attachments.map(\.path)
        ))
        return sections.joined(separator: "\n\n")
    }

    private static func forkReportLine(_ record: TaskRecord, sourceWorkspaceID: UUID?) -> String {
        if let parentTaskID = record.parentTaskID {
            return "Report progress, questions and results to the task that created this one with "
                + "`toastty task send \(parentTaskID.uuidString) \"<message>\"`."
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
    /// without a skill is sent as written.
    public static func merge(skill: String?, prompt: String?, pullRequestURL: String) -> String {
        let skill = skill ?? (prompt == nil ? defaultMergeSkill : nil)
        let sections = [skill.map(skillLine), prompt] + ["The user accepted \(pullRequestURL) for merging."]
        return sections.compactMap { $0 }.joined(separator: "\n\n")
    }

    public static let defaultMergeSkill = "toastty-task-merge"
    /// The skill a task's agent follows to publish its review packet when
    /// no `verify_skill` names another.
    public static let defaultVerifySkill = "toastty-task-verify"

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
