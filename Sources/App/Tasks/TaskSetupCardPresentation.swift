import CoreState
import Foundation

/// What the setup card shows for a task that has not started: its notes,
/// its workspace choices and its buttons' titles. `TaskSetupCard` (macOS)
/// and the GTK setup card draw them.
enum TaskSetupCardPresentation {
    struct Note: Equatable {
        var text: String
        var isProblem: Bool
    }

    /// Why the task waits, and what triage could not do when it ran, as
    /// quiet notes.
    static func notes(_ record: TaskRecord) -> [Note] {
        var notes: [Note] = []
        if case .needsWorkspace(let reason) = record.setup {
            notes.append(Note(text: reason, isProblem: false))
        }
        if let failure = TaskSetupPresentation.failureReason(record) {
            notes.append(Note(text: failure, isProblem: true))
        }
        if let triageNote = record.triageNote, notes.contains(where: { $0.text.contains(triageNote) }) == false {
            notes.append(Note(text: triageNote, isProblem: false))
        }
        return notes
    }

    /// The task waits for the user to pick its workspace.
    static func isPickingWorkspace(_ record: TaskRecord) -> Bool {
        if case .needsWorkspace = record.setup { return true }
        return false
    }

    static func isAvailable(_ choice: TaskWorkspaceChoice, in choices: TaskWorkspaceChoices) -> Bool {
        if choices.suggested?.choice == choice { return true }
        switch choice {
        case .open(let id): return choices.open.contains { $0.id == id }
        case .recent(let id): return choices.recent.contains { $0.id == id }
        case .directory: return false
        }
    }

    static func rootDirectory(of choice: TaskWorkspaceChoice, in choices: TaskWorkspaceChoices) -> String? {
        if let suggested = choices.suggested, suggested.choice == choice { return suggested.rootDirectory }
        switch choice {
        case .open(let id): return choices.open.first { $0.id == id }?.rootDirectory
        case .recent(let id): return choices.recent.first { $0.id == id }?.rootDirectory
        case .directory(let path): return path
        }
    }

    /// What choosing a workspace that is not open will do.
    static func hint(for choice: TaskWorkspaceChoice?, choices: TaskWorkspaceChoices) -> String? {
        switch choice {
        case .recent?, .directory?:
            "Not open. Toastty opens it with one terminal in this folder."
        case .open?, nil:
            nil
        }
    }

    /// A path with the home folder as `~`.
    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    static func startTitle(for choice: TaskWorkspaceChoice?, choices: TaskWorkspaceChoices) -> String {
        guard let choice, let title = choices.title(of: choice) else { return "Start" }
        switch choice {
        case .open: return "Start in \(title)"
        case .recent, .directory: return "Open \(title) & Start"
        }
    }
}
