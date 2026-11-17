import CoreState
import Foundation

/// The example skills that Toastty shipped before its built-in task skills,
/// up to v0.9.2. A copy in the user's skills folder is still delivered next
/// to the built-in skills, and an agent can pick it in their place.
enum OldExampleSkills {
    /// Each old example, by its exact folder name, and what replaced it.
    static let replacements: [String: String] = [
        "worktree-create": "toastty-task-start",
        "worktree-done": "toastty-task-merge",
        "worktree-cleanup": "the task's cleanup after merge",
    ]

    /// The included packages that are old examples. Only an included one is
    /// delivered, so only it competes.
    static func included(in state: UserSkillCatalogState?) -> [UserSkillPackage] {
        state?.acceptedPackages.filter { replacements[$0.name] != nil } ?? []
    }
}
