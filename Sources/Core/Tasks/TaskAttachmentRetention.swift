import Foundation

/// How long Toastty keeps its copies of a task's attached files. They stay
/// while the task can still use them, and are removed once the task has
/// been Done or Archived for `keepAfterFinish`. The record, with the files'
/// names, stays.
public enum TaskAttachmentRetention {
    public static let keepAfterFinish: TimeInterval = 7 * 24 * 60 * 60

    /// When the task reached Done or Archived, from its record: archived,
    /// marked done, shipped, or merged in a project without `release_tags`.
    /// `nil` while the task is in any other stage, including To ship and a
    /// stopped cleanup. A done mark that new work cleared is gone from the
    /// record, so the task counts from its next finish.
    public static func finishedAt(_ record: TaskRecord, releaseTagsConfigured: Bool) -> Date? {
        guard record.cleanup?.problem == nil else { return nil }
        if let archivedAt = record.archivedAt {
            return archivedAt
        }
        if let done = [record.doneAt, record.shippedAt].compactMap({ $0 }).min() {
            return done
        }
        if let mergedAt = record.mergedAt, releaseTagsConfigured == false {
            return mergedAt
        }
        return nil
    }

    /// Whether the task's attached files should go now. A task space that
    /// is still open keeps them, whatever the record says, because its
    /// agent may still read them.
    public static func shouldRemove(
        _ record: TaskRecord,
        releaseTagsConfigured: Bool,
        taskSpaceOpen: Bool,
        now: Date
    ) -> Bool {
        guard record.attachments.isEmpty == false,
              record.attachmentsRemovedAt == nil,
              taskSpaceOpen == false,
              let finishedAt = finishedAt(record, releaseTagsConfigured: releaseTagsConfigured) else {
            return false
        }
        return now.timeIntervalSince(finishedAt) >= keepAfterFinish
    }
}
