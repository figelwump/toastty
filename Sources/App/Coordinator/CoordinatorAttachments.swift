import CoreState
import Foundation

/// Toastty's copies of the files that the user attached to a message for
/// the coordinator, in one folder for each message.
///
/// The folder is in the coordinator's own folder, the agent's working
/// directory, so the agent can read the files with no extra permission.
/// A copy stays after its message was typed: the coordinator reads it then,
/// and passes it on to the task it creates. Toastty removes a copy when the
/// user removes the waiting message, and otherwise after `retention`.
struct CoordinatorAttachments: Sendable {
    static let directoryName = "attachments"
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    /// `<the coordinator's folder>/attachments`.
    let directoryURL: URL

    init(coordinatorDirectoryURL: URL) {
        directoryURL = coordinatorDirectoryURL.appending(path: Self.directoryName, directoryHint: .isDirectory)
    }

    /// Copies `files` into the folder of message `messageID`, and returns
    /// the copies. On a failure nothing of the message stays.
    func stage(_ files: [URL], messageID: UUID) throws -> [URL] {
        guard files.isEmpty == false else { return [] }
        guard files.count <= TaskRecord.maximumAttachmentCount else {
            throw CoordinatorError("Attach at most \(TaskRecord.maximumAttachmentCount) files.")
        }
        let fileManager = FileManager.default
        let folder = folderURL(messageID: messageID.uuidString)
        // Only a folder that this call made is removed on a failure.
        var madeFolder = false
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            ignoreInGit()
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
            madeFolder = true
            var copies: [URL] = []
            var usedNames: Set<String> = []
            for file in files {
                let size = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard size.isRegularFile == true else {
                    throw CoordinatorError("\(file.lastPathComponent) is not a file.")
                }
                guard (size.fileSize ?? 0) <= TaskCoordinator.maximumAttachmentBytes else {
                    throw CoordinatorError(
                        "\(file.lastPathComponent) is larger than \(TaskCoordinator.maximumAttachmentBytes / 1024 / 1024) MB."
                    )
                }
                let copy = folder.appending(
                    path: Self.uniqueName(Self.fileName(file.lastPathComponent), among: &usedNames),
                    directoryHint: .notDirectory
                )
                try fileManager.copyItem(at: file, to: copy)
                copies.append(copy)
            }
            return copies
        } catch {
            if madeFolder { try? fileManager.removeItem(at: folder) }
            if let error = error as? CoordinatorError { throw error }
            throw CoordinatorError("Toastty could not copy the attached files: \(error.localizedDescription)")
        }
    }

    /// Removes the copies of one message: its own folder, and each folder
    /// that its text names. A message that the user took back into the
    /// chat's field and sent again has a new ID, and its files are still
    /// under the ID it had. A message with no copies removes nothing.
    func discard(messageID: String, text: String = "") {
        for id in messageIDs(namedIn: text).union([messageID]) where UUID(uuidString: id) != nil {
            try? FileManager.default.removeItem(at: folderURL(messageID: id))
        }
    }

    /// The messages whose folders `text` names as paths.
    func messageIDs(namedIn text: String) -> Set<String> {
        let prefix = folderPathPrefix
        var ids: Set<String> = []
        var remainder = text[...]
        while let found = remainder.range(of: prefix) {
            let id = String(remainder[found.upperBound...].prefix(36))
            if UUID(uuidString: id) != nil { ids.insert(id) }
            remainder = remainder[found.upperBound...]
        }
        return ids
    }

    /// `<attachments>/`, as a message's paths start.
    private var folderPathPrefix: String {
        let path = directoryURL.path(percentEncoded: false)
        return path.hasSuffix("/") ? path : path + "/"
    }

    /// Removes the folders older than `retention`, except those of the
    /// messages in `waitingMessageIDs`, which were not typed yet.
    func removeExpired(waitingMessageIDs: Set<String>, now: Date = Date()) {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        ) else { return }
        for folder in folders {
            let name = folder.lastPathComponent
            guard UUID(uuidString: name) != nil, waitingMessageIDs.contains(name) == false,
                  let values = try? folder.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > Self.retention else { continue }
            try? fileManager.removeItem(at: folder)
        }
    }

    private func folderURL(messageID: String) -> URL {
        directoryURL.appending(path: messageID, directoryHint: .isDirectory)
    }

    /// The coordinator's folder is a git repository for the policy. A
    /// `.gitignore` inside the attachments keeps them out of it, also in a
    /// repository that the user made.
    private func ignoreInGit() {
        let url = directoryURL.appending(path: ".gitignore", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: url.path) == false else { return }
        try? Data("*\n".utf8).write(to: url)
    }

    /// The name of a copy. The coordinator writes the path into a command
    /// (`task create --file`), so the name holds only letters, digits,
    /// `.`, `_` and `-`: nothing that a shell or a code span reads as more
    /// than a name.
    static func fileName(_ name: String) -> String {
        var cleaned = String(name.unicodeScalars.map { scalar -> Character in
            let isSafe = scalar.properties.isAlphabetic
                || scalar.properties.numericType != nil
                || scalar == "." || scalar == "_" || scalar == "-"
            return isSafe ? Character(scalar) : "-"
        })
        // No hidden file, and no name that is only dots.
        while cleaned.hasPrefix(".") || cleaned.hasPrefix("-") { cleaned.removeFirst() }
        if cleaned.count > 120 {
            let ext = (cleaned as NSString).pathExtension
            cleaned = String(cleaned.prefix(100)) + (ext.isEmpty || ext.count > 16 ? "" : "." + ext)
        }
        return cleaned.isEmpty ? "attachment" : cleaned
    }

    private static func uniqueName(_ name: String, among used: inout Set<String>) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var number = 2
        while used.insert(candidate.lowercased()).inserted == false {
            candidate = ext.isEmpty ? "\(base)-\(number)" : "\(base)-\(number).\(ext)"
            number += 1
        }
        return candidate
    }
}
