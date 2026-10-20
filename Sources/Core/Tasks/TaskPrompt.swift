import Foundation

/// The first message a task's agent receives.
public enum TaskPrompt {
    /// The first prompt, when there is one, then the task text exactly as
    /// written, then the attached files. Toastty adds the text and files
    /// itself, so nothing that writes the first prompt can drop or reword
    /// them. The text keeps its own spacing and indentation.
    public static func compose(
        firstPrompt: String?,
        text: String,
        attachmentPaths: [String],
        worktree: TaskOperation.Worktree? = nil,
        base: TaskOperation.Base? = nil
    ) -> String {
        var sections: [String] = []
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
    /// forked, also gets the task.
    public static func movedToWorktree(
        record: TaskRecord,
        worktree: TaskOperation.Worktree,
        base: TaskOperation.Base?,
        forked: Bool
    ) -> String {
        var sections = [worktreeLine(worktree, base: base)]
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

    private static func worktreeLine(_ worktree: TaskOperation.Worktree, base: TaskOperation.Base?) -> String {
        var line = "You are in the git worktree \(worktree.path), on branch \(worktree.branch)"
        if let base {
            line += ", which starts at \(base.ref) (\(base.sha.prefix(12)))"
        }
        return line + "."
    }
}
