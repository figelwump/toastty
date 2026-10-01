import Foundation

/// A set of example user skill packages that `toastty setup install-workflow`
/// copies into the user skills directory. The packages ship in the app bundle
/// from the repository's `examples/skills` directory; they are installable, not
/// delivered automatically like the shipped Toastty skills.
public struct ToasttyWorkflowDescriptor: Equatable, Sendable {
    public let name: String
    public let summary: String
    public let packageNames: [String]
    /// What the workflow needs beyond Toastty, shown with install results.
    public let requirements: String

    public init(name: String, summary: String, packageNames: [String], requirements: String) {
        self.name = name
        self.summary = summary
        self.packageNames = packageNames
        self.requirements = requirements
    }
}

public enum ToasttyWorkflowCatalog {
    /// Location of the bundled example packages, relative to the app's
    /// Resources directory. `Project.swift` copies `examples/skills` here.
    public static let bundledPackagesSubpath = "WorkflowExamples/skills"

    public static let workflows = [
        ToasttyWorkflowDescriptor(
            name: "worktree-handoff",
            summary: "Hand a task to its own Git worktree and subspace, then accept and clean up its PR.",
            packageNames: ["worktree-create", "worktree-done", "worktree-cleanup"],
            requirements: "Needs a Git repository; the PR steps use GitHub through an authenticated gh CLI, and worktree-done relies on the repository's auto-merge setting."
        ),
    ]

    public static func workflow(named name: String) -> ToasttyWorkflowDescriptor? {
        workflows.first { $0.name == name }
    }
}
