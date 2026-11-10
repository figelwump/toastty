import Foundation

public struct ToasttyShippedSkillDescriptor: Equatable, Sendable {
    public let name: String
    public let summary: String

    public init(name: String, summary: String) {
        self.name = name
        self.summary = summary
    }
}

public enum ToasttyShippedSkillCatalog {
    public static let skills = [
        ToasttyShippedSkillDescriptor(
            name: "toastty-capabilities",
            summary: "Control Toastty workspaces, panels, terminals, and managed agents."
        ),
        ToasttyShippedSkillDescriptor(
            name: "toastty-coordinator",
            summary: "The coordinator's job: follow your tasks, unblock them, check their proof, and start releases."
        ),
        ToasttyShippedSkillDescriptor(
            name: "toastty-open-markdown",
            summary: "Open plans and Markdown files for review inside Toastty."
        ),
        ToasttyShippedSkillDescriptor(
            name: "toastty-read-terminal",
            summary: "Read output from another terminal in the same workspace."
        ),
        ToasttyShippedSkillDescriptor(
            name: "toastty-scratchpad",
            summary: "Create and update visual diagrams, mockups, and summaries."
        ),
        ToasttyShippedSkillDescriptor(
            name: "toastty-send-diagnostics",
            summary: "Collect, review, and send redacted Toastty diagnostics."
        ),
        ToasttyShippedSkillDescriptor(
            name: "toastty-task-merge",
            summary: "Check a task's pull request, then merge it with toastty task merge, or report what blocks it."
        ),
        ToasttyShippedSkillDescriptor(
            name: "toastty-task-start",
            summary: "Take a task from request to review: clarify, work in its own worktree, verify, and hand off."
        ),
    ]
}
