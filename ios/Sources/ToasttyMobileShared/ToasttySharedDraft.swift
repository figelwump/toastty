import Foundation
import RemoteProtocol

/// Content another app shared to Toastty, waiting for the app to open it in
/// the new-session sheet. The share extension writes it; the app takes it
/// once.
struct ToasttySharedDraft: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = Self.currentVersion
    let id: UUID
    let createdAt: Date
    var text: String
    var attachments: [RemoteMessageAttachment]
    /// Shared items the draft could not take, for the sheet to mention.
    var skippedItemCount: Int

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    var skippedItemsNotice: String? {
        guard skippedItemCount > 0 else { return nil }
        let items = skippedItemCount == 1 ? "1 shared item" : "\(skippedItemCount) shared items"
        return "Toastty left out \(items). A session can start with up to 4 images, PDFs, or text files, 8 MB in total."
    }
}

/// Shared drafts in the App Group container, one file each. A marker file
/// says the app should find the draft itself if its link does not open it,
/// so the app can find it without reading every draft.
struct ToasttySharedDraftStore: Equatable, Sendable {
    /// How long a draft waits for the app. Older drafts are deleted unopened.
    static let lifetime: TimeInterval = 30 * 60

    private static let draftExtension = "draft"
    private static let waitingExtension = "waiting"

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// `nil` when this build has no App Group, or the system does not grant it.
    init?(appGroupID: String?) {
        guard let appGroupID, appGroupID.isEmpty == false,
              let container = FileManager.default.containerURL(
                  forSecurityApplicationGroupIdentifier: appGroupID
              ) else { return nil }
        directory = container.appending(path: "SharedDrafts", directoryHint: .isDirectory)
    }

    func save(_ draft: ToasttySharedDraft) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(draft).write(
            to: fileURL(draft.id, Self.draftExtension),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    /// Records that the app should open the draft the next time it can, in
    /// case its link does not reach the app or the app cannot show it then.
    func markWaiting(id: UUID) throws {
        try Data().write(to: fileURL(id, Self.waitingExtension), options: .atomic)
    }

    /// The newest draft the app has not taken.
    func waitingDraftID(now: Date = Date()) -> UUID? {
        files()
            .filter { $0.url.pathExtension == Self.waitingExtension && isFresh($0.modified, now: now) }
            .max { $0.modified < $1.modified }
            .flatMap { UUID(uuidString: $0.url.deletingPathExtension().lastPathComponent) }
    }

    /// Reads the draft and deletes it, so its link and the waiting path
    /// can never both open it.
    func take(id: UUID, now: Date = Date()) -> ToasttySharedDraft? {
        let url = fileURL(id, Self.draftExtension)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: fileURL(id, Self.waitingExtension))
        }
        guard let data = try? Data(contentsOf: url),
              let draft = try? PropertyListDecoder().decode(ToasttySharedDraft.self, from: data),
              draft.version == ToasttySharedDraft.currentVersion,
              draft.id == id,
              isFresh(draft.createdAt, now: now) else { return nil }
        return draft
    }

    /// Deletes drafts and markers older than `lifetime`.
    func removeExpired(now: Date = Date()) {
        for file in files() where isFresh(file.modified, now: now) == false {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    private func fileURL(_ id: UUID, _ pathExtension: String) -> URL {
        directory.appending(path: "\(id.uuidString).\(pathExtension)", directoryHint: .notDirectory)
    }

    private func isFresh(_ date: Date, now: Date) -> Bool {
        now.timeIntervalSince(date) < Self.lifetime
    }

    private func files() -> [(url: URL, modified: Date)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        return urls.compactMap { url in
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { return nil }
            return (url, modified)
        }
    }
}
