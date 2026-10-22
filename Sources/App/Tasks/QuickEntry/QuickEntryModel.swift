import AppKit
import CoreState
import Foundation
import ImageIO
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
/// optional workspace and agent preset. Toastty copies each attached file into a
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
        /// A small preview for an image, made once when it is attached.
        let thumbnail: NSImage?
    }

    struct Option: Identifiable, Equatable {
        let id: String
        let title: String
    }

    @Published var text = ""
    @Published private(set) var attachments: [Attachment] = []
    /// nil means Auto: triage chooses.
    @Published var workspaceID: UUID?
    /// The agent, model and effort; nil means Auto: triage or `[defaults]`
    /// chooses.
    @Published var preset: QuickEntryPreset?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSubmitting = false
    /// Files still being copied in.
    @Published private(set) var pendingAttachmentCount = 0
    /// Bumped to ask the text editor to take focus.
    @Published private(set) var focusRequestID = 0
    /// A drag with files or images is over the panel.
    @Published var isDropTargeted = false
    /// The pill whose picker is open.
    @Published var openPicker: QuickEntryPickerKind?
    /// Where each pill is, in the panel's top-left coordinates, so its
    /// picker opens under it.
    var pillFrames: [QuickEntryPickerKind: CGRect] = [:]

    let workspaceOptions: [Option]
    let agentProfiles: [QuickEntryAgentProfile]
    /// Presets listed first in the Agent picker.
    let frequentPresets: [QuickEntryPreset]

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
        agentProfiles: [QuickEntryAgentProfile],
        frequentPresets: [QuickEntryPreset],
        stagingDirectoryURL: URL,
        create: @escaping @MainActor (TaskCreateRequest) async throws -> TaskRecord,
        onCreated: @escaping @MainActor (TaskRecord) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.workspaceOptions = workspaceOptions
        self.agentProfiles = agentProfiles
        self.frequentPresets = frequentPresets
        self.stagingDirectoryURL = stagingDirectoryURL
        self.create = create
        self.onCreated = onCreated
        self.onCancel = onCancel
        apply(prefill)
    }

    /// True once the panel has closed. Copies still running then throw
    /// their file away, and the last one removes the staging folder.
    private(set) var isClosed = false

    /// False while a task is being created from this draft, so what the
    /// user sees is what gets saved.
    var isEditable: Bool {
        isSubmitting == false && isClosed == false
    }

    var canSubmit: Bool {
        isEditable
            && pendingAttachmentCount == 0
            && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var canAttachMore: Bool {
        attachments.count + pendingAttachmentCount < TaskRecord.maximumAttachmentCount
    }

    var workspaceTitle: String {
        workspaceID.flatMap { id in workspaceOptions.first { $0.id == id.uuidString }?.title } ?? "Auto"
    }

    /// `model · effort`. The model names its provider, so the profile's
    /// name is added only when no model is chosen. A profile that runs
    /// another provider's command, such as a release profile wrapping
    /// Codex, takes no model, so it always shows its name.
    var agentTitle: String {
        let parts = agentTitleParts
        return parts.effort.map { "\(parts.name) · \($0)" } ?? parts.name
    }

    /// The pill cuts a long model short but keeps the effort.
    var agentTitleParts: (name: String, effort: String?) {
        guard let preset else { return ("Auto", nil) }
        let name = agentProfiles.first { $0.id == preset.agent }?.displayName ?? preset.agent
        return (preset.model ?? name, preset.effort)
    }

    func requestFocus() {
        focusRequestID &+= 1
    }

    /// Adds what a later opener asks for while the panel is already open.
    func apply(_ prefill: QuickEntryPrefill) {
        guard isEditable else { return }
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

    /// Ends the draft when the panel closes. The staging folder goes once no
    /// copy is still writing into it; after a create, `task.create` has
    /// already made its own copies.
    func close() {
        isClosed = true
        removeStagingDirectoryIfIdle()
    }

    /// For app termination: removes the staging folder at once.
    func removeStagingDirectoryNow() {
        isClosed = true
        try? FileManager.default.removeItem(at: stagingDirectoryURL)
    }

    func removeAttachment(id: Attachment.ID) {
        guard isEditable, let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let removed = attachments.remove(at: index)
        usedFileNames.remove(removed.url.lastPathComponent)
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
            agent: preset?.agent,
            model: preset?.model,
            effort: preset?.effort
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
            guard let image = NSImage(data: data),
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
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

    /// The pasteboard types a drop onto the panel can use.
    static let droppableTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .png, .tiff, .URL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    /// Attaches files or an image from the pasteboard. Returns false when it
    /// holds neither, or holds text, so a normal paste can run instead.
    @discardableResult
    func pasteAttachments(from pasteboard: NSPasteboard) -> Bool {
        guard isEditable else { return false }
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
        guard isEditable else { return false }
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

    /// A promised file. It holds an attachment slot from the drop until the
    /// sender has written it, so Create Task waits for it.
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
        for receiver in receivers {
            // One slot per promised file. A promise that names no files yet
            // holds one slot, and any extra file it delivers is taken only
            // while there is room.
            var promises: [PromisedAttachment] = []
            for _ in 0..<max(1, receiver.fileNames.count) {
                guard let promise = beginPromisedAttachment() else { break }
                promises.append(promise)
            }
            guard let directoryURL = promises.first?.directoryURL else { return }
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            } catch {
                for _ in promises {
                    finishPromisedAttachment(.failure(error))
                }
                continue
            }
            let tracker = PromiseDeliveryTracker(reservedSlots: promises.count)
            receiver.receivePromisedFiles(
                atDestination: directoryURL,
                options: [:],
                operationQueue: Self.promiseQueue
            ) { @Sendable url, error in
                // Runs on promiseQueue. Without @Sendable, Swift 6 takes this
                // closure as main-actor isolated, from the method it is
                // written in, and traps when AppKit calls it off the main
                // thread.
                Task { @MainActor in
                    let result: Result<URL, any Error> = error.map { .failure($0) } ?? .success(url)
                    if tracker.takeReservedSlot() {
                        self.finishPromisedAttachment(result)
                    } else if case .success(let url) = result {
                        // An extra file beyond the slots held: attach it only
                        // if there is still room.
                        if self.beginAttachment() {
                            self.finishPromisedAttachment(.success(url))
                        } else {
                            try? FileManager.default.removeItem(at: url)
                        }
                    }
                }
            }
        }
    }

    /// Counts the deliveries of one promise against the slots it holds.
    @MainActor
    private final class PromiseDeliveryTracker {
        private var remaining: Int

        init(reservedSlots: Int) {
            remaining = reservedSlots
        }

        func takeReservedSlot() -> Bool {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
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

    /// Holds an attachment slot until ``finishAttachment`` releases it.
    private func beginAttachment() -> Bool {
        guard isEditable else { return false }
        guard canAttachMore else {
            errorMessage = "Attach at most \(TaskRecord.maximumAttachmentCount) files."
            return false
        }
        pendingAttachmentCount += 1
        return true
    }

    private func finishAttachment(_ result: Result<URL, any Error>, displayName: String, reservedName: String?) {
        pendingAttachmentCount -= 1
        guard isClosed == false else {
            // The draft is gone; the folder removal below takes this file.
            removeStagingDirectoryIfIdle()
            return
        }
        switch result {
        case .success(let url):
            let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
            attachments.append(Attachment(
                url: url,
                displayName: displayName,
                isImage: isImage,
                thumbnail: isImage ? Self.thumbnail(of: url) : nil
            ))
        case .failure(let error):
            if let reservedName {
                usedFileNames.remove(reservedName)
            }
            errorMessage = error.localizedDescription
        }
    }

    /// A preview sized for the attachment chip, read without decoding the
    /// whole image, since a screenshot can be large.
    private static func thumbnail(of url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 96,
              ] as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func removeStagingDirectoryIfIdle() {
        guard isClosed, pendingAttachmentCount == 0 else { return }
        try? FileManager.default.removeItem(at: stagingDirectoryURL)
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
