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
            name: "toastty-open-markdown",
            summary: "Open plans and Markdown files for review inside Toastty."
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
            name: "worktree-create",
            summary: "Move work into an isolated Git worktree and Toastty workspace."
        ),
        ToasttyShippedSkillDescriptor(
            name: "worktree-done",
            summary: "Land verified work and clean up its task workspace with user approval."
        ),
    ]
}
