import AppKit
import CoreState
import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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
        /// A small preview for an image, made once when it is attached.
        let thumbnail: NSImage?
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

    /// Photos chosen in the Photos picker. Each holds a slot while Photos
    /// hands it over, which can take a moment for a photo in iCloud.
    func attachPhotos(_ items: [PhotosPickerItem]) {
        for item in items {
            guard beginAttachment() else { return }
            let format = PhotoFormat(contentTypes: item.supportedContentTypes)
            let name = reserveFileName("Photo.\(format.fileExtension)")
            let destination = stagingDirectoryURL.appending(path: name, directoryHint: .notDirectory)
            let directory = stagingDirectoryURL
            Task { @MainActor in
                let result: Result<URL, any Error>
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw TaskError("Photos did not hand over the photo.")
                    }
                    result = await Task.detached(priority: .userInitiated) {
                        Result {
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            try Self.photoFileData(data, format: format).write(to: destination)
                            return destination
                        }
                    }.value
                } catch {
                    result = .failure(error)
                }
                finishAttachment(result, displayName: name, reservedName: name)
            }
        }
    }

    /// How a photo is saved. Claude reads PNG, JPEG, GIF and WebP; a photo
    /// in any other format, such as HEIC, becomes a JPEG, as Toastty Mobile
    /// does.
    enum PhotoFormat: Equatable, Sendable {
        case original(fileExtension: String)
        case jpeg

        static let readableTypes: [(UTType, String)] = [(.png, "png"), (.jpeg, "jpg"), (.gif, "gif"), (.webP, "webp")]

        /// From the formats Photos offers, best first.
        init(contentTypes: [UTType]) {
            guard let first = contentTypes.first,
                  let readable = Self.readableTypes.first(where: { first.conforms(to: $0.0) }) else {
                self = .jpeg
                return
            }
            self = .original(fileExtension: readable.1)
        }

        var fileExtension: String {
            switch self {
            case .original(let fileExtension): fileExtension
            case .jpeg: "jpg"
            }
        }
    }

    /// The bytes to save for a photo: as they are, or as a JPEG of at most
    /// 2048 pixels on its long side.
    nonisolated static func photoFileData(_ data: Data, format: PhotoFormat) throws -> Data {
        guard format == .jpeg else { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2048,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else {
            throw TaskError("Toastty could not read the photo.")
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw TaskError("Toastty could not convert the photo.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw TaskError("Toastty could not convert the photo.")
        }
        return encoded as Data
    }

    // MARK: - The pasteboard

    /// The pasteboard types a drop onto a draft can use.
    static let droppableTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .png, .tiff, .URL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    /// The types that become attachments: files, promised files and images.
    /// A `file:` link is a file too; see `fileURLs(on:)`.
    static let attachmentTypes = droppableTypes.filter { $0 != .URL }

    /// The files on the pasteboard: file URLs, which a drag of file names
    /// also gives, and with `includingLinks` also `file:` links. Text is
    /// never read as a file.
    static func fileURLs(on pasteboard: NSPasteboard, includingLinks: Bool = true) -> [URL] {
        guard includingLinks else {
            return pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }
        return (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).filter(\.isFileURL)
    }

    /// Attaches files or an image from the pasteboard. Returns false when it
    /// holds neither, or holds text, so a normal paste can run instead.
    @discardableResult
    func pasteAttachments(from pasteboard: NSPasteboard) -> Bool {
        guard canEdit else { return false }
        // A copied link pastes as text, also a `file:` link.
        if attachFileURLs(from: pasteboard, includingLinks: false) {
            return true
        }
        // Copying an image from a browser also puts its URL or alt text on
        // the pasteboard; a pasteboard with text pastes the text.
        guard pasteboard.string(forType: .string) == nil else { return false }
        return attachImage(from: pasteboard)
    }

    /// Whether `pasteAttachments(from:)` would take the pasteboard. Menu
    /// validation asks this often, so it reads no file and no image.
    func canPasteAttachments(from pasteboard: NSPasteboard) -> Bool {
        guard canEdit else { return false }
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return true
        }
        return pasteboard.availableType(from: [.string]) == nil && pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    /// Handles a drop: files, promised files and images are attached, and a
    /// web link goes to `onLink`. Returns false when nothing was used.
    func handleDrop(from pasteboard: NSPasteboard) -> Bool {
        guard canEdit else { return false }
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
        if let onLink, let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], urls.isEmpty == false {
            for url in urls {
                onLink(url.absoluteString)
            }
            return true
        }
        return false
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

    private func attachFileURLs(from pasteboard: NSPasteboard, includingLinks: Bool = true) -> Bool {
        let fileURLs = Self.fileURLs(on: pasteboard, includingLinks: includingLinks)
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

    // MARK: - Slots and copies

    /// Holds an attachment slot until ``finishAttachment`` releases it.
    private func beginAttachment() -> Bool {
        guard canEdit else { return false }
        guard canAttachMore else {
            onError("Attach at most \(TaskRecord.maximumAttachmentCount) files.")
            return false
        }
        pendingCount += 1
        return true
    }

    private func finishAttachment(_ result: Result<URL, any Error>, displayName: String, reservedName: String?) {
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

    private static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    /// A preview sized for the attachment chip, read without decoding the
    /// whole image, since a screenshot can be large.
    private static func thumbnail(of url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 256,
              ] as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func removeStagingDirectoryIfIdle() {
        guard isClosed, pendingCount == 0 else { return }
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

    // MARK: - Choosing files

    /// The open panel for **Files…** and **＋ Attach**: several files, no
    /// folders.
    static func makeOpenPanel() -> NSOpenPanel {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.prompt = "Attach"
        return openPanel
    }
}

/// Takes drops for a draft's attachments, from the text field and from the
/// panel or window area around it.
@MainActor
final class AttachmentDropTarget {
    weak var attachments: DraftAttachments?

    init(attachments: DraftAttachments?) {
        self.attachments = attachments
    }

    /// Files, promised files and images become attachments. A drag that
    /// holds a file in any form counts, also a `file:` link: a text view
    /// would type it.
    static func carriesAttachments(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: DraftAttachments.attachmentTypes) != nil
            || DraftAttachments.fileURLs(on: pasteboard).isEmpty == false
    }

    static func carriesLink(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.URL]) != nil
    }

    func dropEntered(_ pasteboard: NSPasteboard, acceptsLinks: Bool = false) -> Bool {
        guard Self.carriesAttachments(pasteboard) || (acceptsLinks && Self.carriesLink(pasteboard)) else {
            return false
        }
        attachments?.isDropTargeted = true
        return true
    }

    func dropExited() {
        attachments?.isDropTargeted = false
    }

    func performDrop(_ pasteboard: NSPasteboard) -> Bool {
        attachments?.isDropTargeted = false
        return attachments?.handleDrop(from: pasteboard) ?? false
    }
}
