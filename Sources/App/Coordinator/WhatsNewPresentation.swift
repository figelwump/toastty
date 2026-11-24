import CoreState
import Foundation

/// What the What's new sheet shows for this user: the quick entry key, and
/// the lines that name what changed for a user who updates.
struct WhatsNewFacts: Equatable {
    enum Shortcut: Equatable {
        /// `tasks.toml` does not set a key: the sheet asks before Toastty
        /// takes this one, the default.
        case askForDefault(label: String)
        /// `tasks.toml` sets the key, or turns it off with nil. The sheet
        /// shows it and asks nothing.
        case written(label: String?)
    }

    var shortcut: Shortcut
    /// The box's first state: the saved answer, if the sheet shows again.
    var allowsDefaultShortcut = true
    /// Task spaces that have no task record, such as those from an earlier
    /// version, which the board now lists as tasks.
    var hasTaskSpacesFromBefore = false
    /// A paired phone that may merge, archive and delete tasks.
    var hasPhoneWithTaskActions = false
    /// Old example skills in the user's skills folder that are still
    /// delivered next to the built-in task skills.
    var oldExampleSkills: [UserSkillPackage] = []
}

/// The What's new sheet's words, which macOS (`WhatsNewSheet`) and the GTK
/// dialog show.
enum WhatsNewWords {
    static let title = "New in Toastty: tasks"
    static let subtitle = "Hand work to agents, and follow all of it in one place."
    static let tasksTitle = "Tasks"
    static let tasks = "Describe a change. Toastty starts an agent on it in its own git worktree, shows its pull request, and merges it when you press Merge."
    static let quickEntryTitle = "Quick entry"
    static let quickEntry = "Add a task from any app."
    static func useEverywhere(_ label: String) -> String { "Use \(label) in every app" }
    static let useEverywhereNote = "Other apps, and Toastty's own terminals, then do not get this key."
    static let writtenShortcutNote = "Your tasks.toml sets this key."
    #if os(Linux)
    static let shortcutOffNote = "Your tasks.toml turns the key off. Use New Task… in the menu."
    #else
    static let shortcutOffNote = "Your tasks.toml turns the key off. Use New Task… in the File menu."
    #endif
    static let changeKey = "Change the key…"
    static let coordinatorTitle = "The coordinator"
    static let coordinator = "One agent that follows your tasks: it tells you what needs you, unblocks stuck tasks and turns your requests into tasks. The first time, it asks you a few questions about how you work. It can also run by itself each day. It keeps your rules in policy.md and changes them when you ask it to work differently. In friction.md it notes what slows your tasks, and it suggests fixes."
    #if os(Linux)
    static let startLater = "Not now? Start it later with Open Coordinator in the menu or the command palette."
    #else
    static let startLater = "Not now? Start it later with Open Coordinator in the Agent menu."
    #endif
    static let sidebar = "The sidebar now groups your sessions and tasks under Needs you, Ready to review, Running and Idle."
    static let taskSpacesFromBefore = "Your task spaces from before now show as tasks."
    static let phone = "Your paired phone can now merge, archive and delete tasks."
    static let phoneLink = "Change in Remote Access…"
    static func oldSkills(_ names: [String]) -> String {
        "Old example skills in ~/.toastty/skills (\(names.joined(separator: ", "))) compete with the new task skills. Delete them to use the built-in ones."
    }
    #if os(Linux)
    static let oldSkillsLink = "Show in Files"
    #else
    static let oldSkillsLink = "Show in Finder"
    #endif
    static let readAboutTasks = "Read about tasks"
    static let notNow = "Not Now"
    static let start = "Start Coordinator"

    static let tasksDocumentURL = URL(string: "https://github.com/figelwump/toastty/blob/main/docs/tasks.md")!
}
