import AppKit
import CoreState
import Foundation
import UniformTypeIdentifiers

/// What an opener fills in before the quick entry panel shows.
struct QuickEntryPrefill: Equatable {
    /// Pins the workspace; nil leaves it on Auto.
    var workspaceID: UUID?
    /// Text selected in a terminal. It is attached as a text file, so the
    /// task text stays what the user types.
    var selectionText: String?

    static let empty = QuickEntryPrefill()
}

/// The quick entry panel's state: the text, the attached files, and the
/// optional workspace and agent. Toastty copies each attached file into a
/// staging directory as soon as it is added, because a dragged screenshot
/// or a pasted image may live only in a temporary file.
@MainActor
final class QuickEntryModel: ObservableObject {
    struct Attachment: Identifiable, Equatable {
        let id = UUID()
        /// Toastty's staged copy.
        let url: URL
        let displayName: String
        let isImage: Bool
    }

    struct Option: Identifiable, Equatable {
        let id: String
        let title: String
    }

    @Published var text = ""
    @Published private(set) var attachments: [Attachment] = []
    /// nil means Auto: triage chooses.
    @Published var workspaceID: UUID?
    /// nil means Auto: triage or `[defaults]` chooses.
    @Published var agentID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSubmitting = false
    /// Files still being copied in.
    @Published private(set) var pendingAttachmentCount = 0
    /// Bumped to ask the text editor to take focus.
    @Published private(set) var focusRequestID = 0
    /// A drag with files or images is over the panel.
    @Published var isDropTargeted = false

    let workspaceOptions: [Option]
    let agentOptions: [Option]

    private let stagingDirectoryURL: URL
    private let create: @MainActor (TaskCreateRequest) async throws -> TaskRecord
    private let onCreated: @MainActor (TaskRecord) -> Void
    private let onCancel: @MainActor () -> Void
    /// One per panel, so a double submit or a retry after a lost answer
    /// returns the first task.
    private let clientRequestID = "quick-entry-\(UUID().uuidString)"
    private var usedFileNames: Set<String> = []

    init(
        prefill: QuickEntryPrefill,
        workspaceOptions: [Option],
        agentOptions: [Option],
        stagingDirectoryURL: URL,
        create: @escaping @MainActor (TaskCreateRequest) async throws -> TaskRecord,
        onCreated: @escaping @MainActor (TaskRecord) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.workspaceOptions = workspaceOptions
        self.agentOptions = agentOptions
        self.stagingDirectoryURL = stagingDirectoryURL
        self.create = create
        self.onCreated = onCreated
        self.onCancel = onCancel
        apply(prefill)
    }

    var canSubmit: Bool {
        isSubmitting == false
            && pendingAttachmentCount == 0
            && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var canAttachMore: Bool {
        attachments.count + pendingAttachmentCount < TaskRecord.maximumAttachmentCount
    }

    var workspaceTitle: String {
        workspaceID.flatMap { id in workspaceOptions.first { $0.id == id.uuidString }?.title } ?? "Auto"
    }

    var agentTitle: String {
        agentID.flatMap { id in agentOptions.first { $0.id == id }?.title } ?? "Auto"
    }

    func requestFocus() {
        focusRequestID &+= 1
    }

    /// Adds what a later opener asks for while the panel is already open.
    func apply(_ prefill: QuickEntryPrefill) {
        if let workspaceID = prefill.workspaceID {
            self.workspaceID = workspaceID
        }
        if let selectionText = prefill.selectionText,
           selectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            attachText(selectionText, named: "selection.txt")
        }
    }

    func cancel() {
        guard isSubmitting == false else { return }
        onCancel()
    }

    func removeAttachment(id: Attachment.ID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let removed = attachments.remove(at: index)
        try? FileManager.default.removeItem(at: removed.url)
    }

    // MARK: - Submit

    func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        let request = TaskCreateRequest(
            text: text,
            files: attachments.map { $0.url.path(percentEncoded: false) },
            clientRequestID: clientRequestID,
            workspaceID: workspaceID,
            agent: agentID
        )
        Task { @MainActor in
            do {
                let record = try await create(request)
                isSubmitting = false
                onCreated(record)
            } catch {
                isSubmitting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Attachments

    /// Copies files into staging. Directories and missing files are
    /// skipped with a message; `task.create` checks size and type again.
    func attachFiles(_ urls: [URL]) {
        for url in urls {
            guard reserveAttachmentSlot() else { return }
            let name = reserveFileName(url.lastPathComponent)
            let destination = stagingDirectoryURL.appending(path: name, directoryHint: .notDirectory)
            let directory = stagingDirectoryURL
            Task { @MainActor in
                let result: Result<Void, any Error> = await Task.detached(priority: .userInitiated) {
                    Result {
                        var isDirectory: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
                              isDirectory.boolValue == false else {
                            throw TaskError("\(url.lastPathComponent) is not a file.")
                        }
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: url, to: destination)
                    }
                }.value
                finishAttachment(result, url: destination, displayName: url.lastPathComponent)
            }
        }
    }

    /// Image data from the pasteboard or a drag, saved as a PNG.
    func attachImageData(_ data: Data, named name: String = "Pasted image.png") {
        guard reserveAttachmentSlot() else { return }
        let fileName = reserveFileName(name)
        let destination = stagingDirectoryURL.appending(path: fileName, directoryHint: .notDirectory)
        let result = Result {
            guard let image = NSImage(data: data),
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                throw TaskError("Toastty could not read the image.")
            }
            try FileManager.default.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: true)
            try png.write(to: destination)
        }
        finishAttachment(result, url: destination, displayName: fileName)
    }

    func attachText(_ text: String, named name: String) {
        guard reserveAttachmentSlot() else { return }
        let fileName = reserveFileName(name)
        let destination = stagingDirectoryURL.appending(path: fileName, directoryHint: .notDirectory)
        let result = Result {
            try FileManager.default.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: destination)
        }
        finishAttachment(result, url: destination, displayName: fileName)
    }

    /// The pasteboard types a drop onto the panel can use.
    static let droppableTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .png, .tiff, .URL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    /// Attaches files or an image from the pasteboard. Returns false when it
    /// holds neither, or holds text, so a normal paste can run instead.
    @discardableResult
    func pasteAttachments(from pasteboard: NSPasteboard) -> Bool {
        if attachFileURLs(from: pasteboard) {
            return true
        }
        // Copying an image from a browser also puts its URL or alt text on
        // the pasteboard; a pasteboard with text pastes the text.
        guard pasteboard.string(forType: .string) == nil else { return false }
        return attachImage(from: pasteboard)
    }

    /// Handles a drop: files, promised files and images are attached, and a
    /// web link is added to the text. Returns false when nothing was used.
    func handleDrop(from pasteboard: NSPasteboard) -> Bool {
        if attachFileURLs(from: pasteboard) {
            return true
        }
        // A screenshot thumbnail, or an image dragged from some apps,
        // promises a file that the sender writes when asked.
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           receivers.isEmpty == false {
            receivePromisedFiles(receivers)
            return true
        }
        if attachImage(from: pasteboard) {
            return true
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], urls.isEmpty == false {
            for url in urls {
                appendLine(url.absoluteString)
            }
            return true
        }
        return false
    }

    private func attachFileURLs(from pasteboard: NSPasteboard) -> Bool {
        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard fileURLs.isEmpty == false else { return false }
        attachFiles(fileURLs)
        return true
    }

    private func attachImage(from pasteboard: NSPasteboard) -> Bool {
        guard let type = pasteboard.availableType(from: [.png, .tiff]),
              let data = pasteboard.data(forType: type) else {
            return false
        }
        attachImageData(data)
        return true
    }

    private func receivePromisedFiles(_ receivers: [NSFilePromiseReceiver]) {
        // The sender writes into a folder of its own inside staging; the
        // file is then copied up like any other attachment.
        let promisesDirectory = stagingDirectoryURL.appending(path: "promised-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: promisesDirectory, withIntermediateDirectories: true)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        for receiver in receivers {
            receiver.receivePromisedFiles(
                atDestination: promisesDirectory,
                options: [:],
                operationQueue: Self.promiseQueue
            ) { [weak self] url, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.errorMessage = error.localizedDescription
                    } else {
                        self.attachFiles([url])
                    }
                }
            }
        }
    }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private func appendLine(_ line: String) {
        if text.isEmpty || text.hasSuffix("\n") {
            text += line
        } else {
            text += "\n" + line
        }
    }

    private func reserveAttachmentSlot() -> Bool {
        guard canAttachMore else {
            errorMessage = "Attach at most \(TaskRecord.maximumAttachmentCount) files."
            return false
        }
        pendingAttachmentCount += 1
        return true
    }

    private func finishAttachment(_ result: Result<Void, any Error>, url: URL, displayName: String) {
        pendingAttachmentCount -= 1
        switch result {
        case .success:
            let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
            attachments.append(Attachment(url: url, displayName: displayName, isImage: isImage))
        case .failure(let error):
            usedFileNames.remove(url.lastPathComponent)
            errorMessage = error.localizedDescription
        }
    }

    /// Staged names must differ, since two files named `Screenshot.png`
    /// from different folders would otherwise overwrite each other.
    private func reserveFileName(_ name: String) -> String {
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
