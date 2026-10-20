import Foundation

/// The first message a task's agent receives.
public enum TaskPrompt {
    /// The first prompt, when there is one, then the task text exactly as
    /// written, then the attached files. Toastty adds the text and files
    /// itself, so nothing that writes the first prompt can drop or reword
    /// them. The text keeps its own spacing and indentation.
    public static func compose(firstPrompt: String?, text: String, attachmentPaths: [String]) -> String {
        var sections: [String] = []
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
}
