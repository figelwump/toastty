import AppKit
import CoreState
import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The macOS parts of `DraftAttachments`: Photos, the pasteboard, promised
/// files, ImageIO previews and the open panel. The Linux build has its own
/// (linux/Sources/ToasttyAppLogic/Attachments).
typealias AttachmentThumbnail = NSImage

extension DraftAttachments {
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


    /// Whether a file is an image, by its extension.
    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    /// A preview sized for the attachment chip, read without decoding the
    /// whole image, since a screenshot can be large.
    static func thumbnail(of url: URL) -> AttachmentThumbnail? {
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

    /// Image data from the pasteboard or a drag, as PNG bytes.
    static func pngData(fromImageData data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
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
    /// Called after a drop that the draft took.
    var onDrop: (() -> Void)?

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
        guard attachments?.handleDrop(from: pasteboard) == true else { return false }
        onDrop?()
        return true
    }
}
