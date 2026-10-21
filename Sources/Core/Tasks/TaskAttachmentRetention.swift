import Foundation

/// How long Toastty keeps its copies of a task's attached files. They stay
/// while the task can still use them, and are removed once the task has
/// been Done or Archived, with its task space closed, for
/// `keepAfterFinish`. The record, with the files' names, stays.
///
/// The week counts from when the sweep first sees the task finished, not
/// from a date on the record: a merge can turn into Done long after it
/// happened (for example when `release_tags` is removed), and a task can
/// leave Done again. Leaving resets the count.
public enum TaskAttachmentRetention {
    public static let keepAfterFinish: TimeInterval = 7 * 24 * 60 * 60

    /// What the sweep does with one task's files.
    public enum Step: Equatable, Sendable {
        case none
        /// Save `now` as the start of the week.
        case startClock
        /// The task is no longer finished; forget the start.
        case resetClock
        case remove
    }

    /// Whether the task is Done or Archived by its record: archived, marked
    /// done, shipped, or merged in a project without `release_tags`. Not
    /// while setup or a move into a worktree runs, as after a retry, and
    /// not while a stopped cleanup puts it in Needs you.
    public static func isFinished(_ record: TaskRecord, releaseTagsConfigured: Bool) -> Bool {
        guard record.cleanup?.problem == nil else { return false }
        switch record.setup {
        case .routing, .settingUp: return false
        case .needsWorkspace, .setupFailed, .started: break
        }
        if case .running? = record.startWork?.state { return false }
        if record.archivedAt != nil || record.doneAt != nil || record.shippedAt != nil {
            return true
        }
        return record.mergedAt != nil && releaseTagsConfigured == false
    }

    /// `hasFiles` is whether the task's attachments folder exists; a record
    /// rebuilt from its task space can have a folder but no file list.
    /// An open task space keeps the files, because its agent may still
    /// read them.
    public static func step(
        _ record: TaskRecord,
        hasFiles: Bool,
        releaseTagsConfigured: Bool,
        taskSpaceOpen: Bool,
        now: Date
    ) -> Step {
        guard hasFiles, record.attachmentsRemovedAt == nil else { return .none }
        guard taskSpaceOpen == false, isFinished(record, releaseTagsConfigured: releaseTagsConfigured) else {
            return record.attachmentsFinishedSeenAt == nil ? .none : .resetClock
        }
        guard let seenAt = record.attachmentsFinishedSeenAt else { return .startClock }
        return now.timeIntervalSince(seenAt) >= keepAfterFinish ? .remove : .none
    }
}
