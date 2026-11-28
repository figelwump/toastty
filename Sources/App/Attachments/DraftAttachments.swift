import Combine
import CoreState
import Foundation

/// The files attached to a message that the user is still writing: the
/// quick entry panel's draft, or the coordinator chat's composer.
///
/// Toastty copies each file into `stagingDirectoryURL` as soon as it is
/// added, because a dragged screenshot or a pasted image may live only in a
/// temporary file. A file that a waiting message already holds can come back
/// as an attachment too (`restore`): it stays where it is, and the draft
/// never removes it.
@MainActor
final class DraftAttachments: ObservableObject {
    struct Attachment: Identifiable, Equatable {
        let id = UUID()
        /// Toastty's copy.
        let url: URL
        let displayName: String
        let isImage: Bool
        /// A small preview for an image, made once when it is attached
        /// (`thumbnail(of:)`, per platform).
        let thumbnail: AttachmentThumbnail?
        /// The draft made this copy in its staging folder, and removes it
        /// with the attachment. A restored file is not the draft's.
        let isDraftCopy: Bool
    }

    @Published private(set) var attachments: [Attachment] = []
    /// Files still being copied in.
    @Published private(set) var pendingCount = 0
    /// A drag with files or images is over the draft's window or panel.
    @Published var isDropTargeted = false

    /// The owner's own lock, such as while its message is being sent.
    var isEditable: @MainActor () -> Bool = { true }
    /// Shows why a file was not attached.
    var onError: @MainActor (String) -> Void = { _ in }
    /// Takes a web link dropped on the draft. Without it a drop of a link
    /// is not used.
    var onLink: (@MainActor (String) -> Void)?

    let stagingDirectoryURL: URL
    /// True once the draft has ended. Copies still running then throw
    /// their file away, and the last one removes the staging folder.
    private(set) var isClosed = false
    private var usedFileNames: Set<String> = []

    init(stagingDirectoryURL: URL) {
        self.stagingDirectoryURL = stagingDirectoryURL
    }

    var canEdit: Bool {
        isClosed == false && isEditable()
    }

    var canAttachMore: Bool {
        attachments.count + pendingCount < TaskRecord.maximumAttachmentCount
    }

    var isEmpty: Bool {
        attachments.isEmpty && pendingCount == 0
    }

    // MARK: - Ending the draft

    /// Ends the draft. The staging folder goes once no copy is still
    /// writing into it.
    func close() {
        isClosed = true
        removeStagingDirectoryIfIdle()
    }

    /// For app termination: removes the staging folder at once.
    func removeStagingDirectoryNow() {
        isClosed = true
        try? FileManager.default.removeItem(at: stagingDirectoryURL)
    }

    /// Empties the draft after its message was sent: the draft's own copies
    /// go, and restored files stay, since the sent message names them.
    func clear() {
        for attachment in attachments where attachment.isDraftCopy {
            try? FileManager.default.removeItem(at: attachment.url)
        }
        attachments.removeAll()
        usedFileNames.removeAll()
    }

    func remove(id: Attachment.ID) {
        guard canEdit, let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let removed = attachments.remove(at: index)
        guard removed.isDraftCopy else { return }
        usedFileNames.remove(removed.url.lastPathComponent)
        try? FileManager.default.removeItem(at: removed.url)
    }

    /// Puts files that a waiting message holds back as attachments, in
    /// front of the others, as an edit puts the message's text in front of
    /// the draft's. They stay where they are.
    func restore(_ urls: [URL]) {
        let restored = urls.map { url in
            let isImage = Self.isImage(url)
            return Attachment(
                url: url,
                displayName: url.lastPathComponent,
                isImage: isImage,
                thumbnail: isImage ? Self.thumbnail(of: url) : nil,
                isDraftCopy: false
            )
        }
        attachments.insert(contentsOf: restored, at: 0)
    }

    // MARK: - Adding files

    /// Copies files into staging. Directories and missing files are
    /// skipped with a message; the receiver checks size and type again.
    func attachFiles(_ urls: [URL]) {
        for url in urls {
            guard beginAttachment() else { return }
            let name = reserveFileName(url.lastPathComponent)
            let destination = stagingDirectoryURL.appending(path: name, directoryHint: .notDirectory)
            let directory = stagingDirectoryURL
            Task { @MainActor in
                let result: Result<URL, any Error> = await Task.detached(priority: .userInitiated) {
                    Result {
                        var isDirectory: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
                              isDirectory.boolValue == false else {
                            throw TaskError("\(url.lastPathComponent) is not a file.")
                        }
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: url, to: destination)
                        return destination
                    }
                }.value
                finishAttachment(result, displayName: url.lastPathComponent, reservedName: name)
            }
        }
    }

    /// Image data from the pasteboard or a drag, saved as a PNG.
    func attachImageData(_ data: Data, named name: String = "Pasted image.png") {
        guard beginAttachment() else { return }
        let fileName = reserveFileName(name)
        let destination = stagingDirectoryURL.appending(path: fileName, directoryHint: .notDirectory)
        let result = Result { () -> URL in
            guard let png = Self.pngData(fromImageData: data) else {
                throw TaskError("Toastty could not read the image.")
            }
            try FileManager.default.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: true)
            try png.write(to: destination)
            return destination
        }
        finishAttachment(result, displayName: fileName, reservedName: fileName)
    }

    func attachText(_ text: String, named name: String) {
        guard beginAttachment() else { return }
        let fileName = reserveFileName(name)
        let destination = stagingDirectoryURL.appending(path: fileName, directoryHint: .notDirectory)
        let result = Result { () -> URL in
            try FileManager.default.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: destination)
            return destination
        }
        finishAttachment(result, displayName: fileName, reservedName: fileName)
    }

    /// A promised file. It holds an attachment slot from the drop until the
    /// sender has written it, so a send waits for it.
    struct PromisedAttachment {
        /// Where the sender writes; a folder of its own inside staging.
        let directoryURL: URL
    }

    func beginPromisedAttachment() -> PromisedAttachment? {
        guard beginAttachment() else { return nil }
        return PromisedAttachment(
            directoryURL: stagingDirectoryURL.appending(path: "promised-\(UUID().uuidString)", directoryHint: .isDirectory)
        )
    }

    func finishPromisedAttachment(_ result: Result<URL, any Error>) {
        let displayName = (try? result.get().lastPathComponent) ?? "file"
        finishAttachment(result, displayName: displayName, reservedName: nil)
    }

    // MARK: - Slots and copies

    /// Holds an attachment slot until ``finishAttachment`` releases it.
    /// Internal for the platform files' paste and drop paths.
    func beginAttachment() -> Bool {
        guard canEdit else { return false }
        guard canAttachMore else {
            onError("Attach at most \(TaskRecord.maximumAttachmentCount) files.")
            return false
        }
        pendingCount += 1
        return true
    }

    func finishAttachment(_ result: Result<URL, any Error>, displayName: String, reservedName: String?) {
        pendingCount -= 1
        guard isClosed == false else {
            // The draft is gone; the folder removal below takes this file.
            removeStagingDirectoryIfIdle()
            return
        }
        switch result {
        case .success(let url):
            let isImage = Self.isImage(url)
            attachments.append(Attachment(
                url: url,
                displayName: displayName,
                isImage: isImage,
                thumbnail: isImage ? Self.thumbnail(of: url) : nil,
                isDraftCopy: true
            ))
        case .failure(let error):
            if let reservedName {
                usedFileNames.remove(reservedName)
            }
            onError(error.localizedDescription)
        }
    }

    private func removeStagingDirectoryIfIdle() {
        guard isClosed, pendingCount == 0 else { return }
        try? FileManager.default.removeItem(at: stagingDirectoryURL)
    }

    /// Staged names must differ, since two files named `Screenshot.png`
    /// from different folders would otherwise overwrite each other.
    func reserveFileName(_ name: String) -> String {
        let cleaned = name.isEmpty ? "attachment" : name
        var candidate = cleaned
        let base = (cleaned as NSString).deletingPathExtension
        let ext = (cleaned as NSString).pathExtension
        var number = 2
        while usedFileNames.contains(candidate) {
            candidate = ext.isEmpty ? "\(base)-\(number)" : "\(base)-\(number).\(ext)"
            number += 1
        }
        usedFileNames.insert(candidate)
        return candidate
    }
}
