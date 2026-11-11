@testable import ToasttyApp
import AppKit
import CoreState
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// The files of a draft message, as the coordinator chat's composer keeps
/// them: which files the draft may remove, the format of a photo, and how
/// Edit takes a waiting message's files back.
@MainActor
struct DraftAttachmentsTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("toastty-draft-attachments-\(UUID().uuidString)", isDirectory: true)

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ name: String, _ contents: String = "data") throws -> URL {
        let url = root.appendingPathComponent("sources/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while condition() == false, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Which files the draft removes

    @Test func theDraftRemovesOnlyItsOwnCopies() async throws {
        defer { cleanUp() }
        let draft = DraftAttachments(stagingDirectoryURL: root.appendingPathComponent("staging"))
        // A copy that a waiting message made, in the coordinator's folder.
        let coordinator = CoordinatorAttachments(coordinatorDirectoryURL: root.appendingPathComponent("coordinator"))
        let waiting = try coordinator.stage([try file("shot.png"), try file("log.txt")], messageID: UUID())
        draft.restore(waiting)
        draft.attachFiles([try file("notes.txt")])
        await waitUntil { draft.attachments.count == 3 }
        #expect(draft.attachments.map(\.displayName) == ["shot.png", "log.txt", "notes.txt"])
        #expect(draft.attachments.map(\.isDraftCopy) == [false, false, true])
        let ownCopy = try #require(draft.attachments.last?.url)
        #expect(ownCopy.path.hasPrefix(draft.stagingDirectoryURL.path))

        // Removing a restored file leaves the file: the folder of its
        // message keeps it until that folder goes.
        draft.remove(id: draft.attachments[1].id)
        #expect(FileManager.default.fileExists(atPath: waiting[1].path))
        #expect(draft.attachments.map(\.displayName) == ["shot.png", "notes.txt"])

        // After a send, the draft's own copy goes and the restored one stays:
        // the sent message names it.
        draft.clear()
        #expect(draft.attachments.isEmpty)
        #expect(FileManager.default.fileExists(atPath: ownCopy.path) == false)
        #expect(FileManager.default.fileExists(atPath: waiting[0].path))

        // A new copy may use the name of a removed one again.
        draft.attachFiles([try file("notes.txt")])
        await waitUntil { draft.attachments.count == 1 }
        #expect(draft.attachments.first?.url.lastPathComponent == "notes.txt")
    }

    @Test func aRestoredImageHasAPreview() throws {
        defer { cleanUp() }
        let png = root.appendingPathComponent("sources/shot.png")
        try FileManager.default.createDirectory(at: png.deletingLastPathComponent(), withIntermediateDirectories: true)
        try QuickEntryTests.pngData().write(to: png)
        let draft = DraftAttachments(stagingDirectoryURL: root.appendingPathComponent("staging"))
        draft.restore([png])
        #expect(draft.attachments.first?.isImage == true)
        #expect(draft.attachments.first?.thumbnail != nil)
    }

    // MARK: - Drops

    /// Every form in which a drag can hold a file becomes an attachment, on
    /// the composer's field and on the area of the chat behind it. Nothing
    /// types a path into the field: Claude Code turns a bare image path into
    /// an image and drops the Return that follows.
    @Test func everyDragThatHoldsAFileAttachesItAndTypesNoPath() async throws {
        defer { cleanUp() }
        let image = root.appendingPathComponent("sources/Screen Shot.png")
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try QuickEntryTests.pngData().write(to: image)
        let legacyFileNames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        let flavors: [(String, (NSPasteboard) throws -> Void)] = [
            ("a file from Finder", { $0.writeObjects([image as NSURL]) }),
            ("file names", { pasteboard in
                pasteboard.declareTypes([legacyFileNames], owner: nil)
                pasteboard.setPropertyList([image.path], forType: legacyFileNames)
            }),
            ("a file: link", { pasteboard in
                pasteboard.declareTypes([.URL], owner: nil)
                pasteboard.setString(image.absoluteString, forType: .URL)
            }),
            ("image data", { $0.setData(try QuickEntryTests.pngData(), forType: .png) }),
        ]
        for (name, fill) in flavors {
            for target in ["field", "chat"] {
                let pasteboard = QuickEntryTests.pasteboard()
                try fill(pasteboard)
                let draft = DraftAttachments(stagingDirectoryURL: root.appendingPathComponent("staging-\(UUID().uuidString)"))
                let dropTarget = AttachmentDropTarget(attachments: draft)
                let drag = FakeDrag(pasteboard)
                #expect(AttachmentDropTarget.carriesAttachments(pasteboard), "\(name)")
                if target == "field" {
                    let field = CoordinatorComposerTextView()
                    field.string = "Look at this"
                    field.dropTarget = dropTarget
                    #expect(field.draggingEntered(drag) == .copy, "\(name)")
                    #expect(draft.isDropTargeted, "\(name)")
                    #expect(field.prepareForDragOperation(drag), "\(name)")
                    #expect(field.performDragOperation(drag), "\(name)")
                    #expect(field.string == "Look at this", "\(name): no path in the text")
                } else {
                    let area = AttachmentDropView()
                    area.dropTarget = dropTarget
                    #expect(area.draggingEntered(drag) == .copy, "\(name)")
                    #expect(area.performDragOperation(drag), "\(name)")
                }
                #expect(draft.isDropTargeted == false, "\(name)")
                await waitUntil { draft.attachments.count == 1 }
                #expect(draft.attachments.count == 1, "\(name) on the \(target)")
            }
        }

        // Text and web links are not files. The field takes them as text,
        // and the chat around it refuses them.
        let notFiles: [(NSPasteboard) -> Void] = [
            { _ = $0.setString(image.path, forType: .string) },
            { pasteboard in
                pasteboard.declareTypes([.URL], owner: nil)
                _ = pasteboard.setString("https://example.com/shot.png", forType: .URL)
            },
        ]
        for fill in notFiles {
            let pasteboard = QuickEntryTests.pasteboard()
            fill(pasteboard)
            #expect(AttachmentDropTarget.carriesAttachments(pasteboard) == false)
            let draft = DraftAttachments(stagingDirectoryURL: root.appendingPathComponent("staging-\(UUID().uuidString)"))
            let area = AttachmentDropView()
            area.dropTarget = AttachmentDropTarget(attachments: draft)
            #expect(area.draggingEntered(FakeDrag(pasteboard)) == [])
            #expect(area.performDragOperation(FakeDrag(pasteboard)) == false)
            #expect(draft.isEmpty)
        }
    }

    // MARK: - Paste

    /// A plain-text field enables Paste only for text it can read. A copied
    /// image or file alone must still enable Paste, in the Edit menu and for
    /// Command-V, and attach; text pastes as text.
    @Test func pasteIsOnForACopiedImageOrFileAndAttachesIt() async throws {
        defer { cleanUp() }
        let draft = DraftAttachments(stagingDirectoryURL: root.appendingPathComponent("staging"))
        let field = CoordinatorComposerTextView()
        field.onPasteAttachments = { draft.pasteAttachments(from: $0) }
        field.canPasteAttachments = { draft.canPasteAttachments(from: $0) }
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")

        let image = QuickEntryTests.pasteboard()
        image.setData(try QuickEntryTests.pngData(), forType: .png)
        field.pasteboard = image
        #expect(field.validateMenuItem(paste))
        field.paste(nil)
        #expect(draft.attachments.map(\.displayName) == ["Pasted image.png"])
        #expect(field.string.isEmpty)

        let copiedFile = QuickEntryTests.pasteboard()
        copiedFile.writeObjects([try file("notes.txt") as NSURL])
        copiedFile.setString("notes.txt", forType: .string)
        #expect(draft.canPasteAttachments(from: copiedFile), "Finder also copies the name as text")

        // An image copied from a browser comes with text: that pastes as
        // text, so the attachments do not decide Paste.
        let withText = QuickEntryTests.pasteboard()
        withText.setString("alt text", forType: .string)
        withText.setData(try QuickEntryTests.pngData(), forType: .png)
        #expect(draft.canPasteAttachments(from: withText) == false)
        let link = QuickEntryTests.pasteboard()
        link.declareTypes([.URL, .string], owner: nil)
        link.setString("file:///tmp/shot.png", forType: .string)
        link.setString("file:///tmp/shot.png", forType: .URL)
        #expect(draft.canPasteAttachments(from: link) == false, "A copied file: link pastes as text")

        // A draft that is being sent takes nothing.
        draft.isEditable = { false }
        #expect(draft.canPasteAttachments(from: image) == false)
    }

    // MARK: - Photos

    @Test func aPhotoInAFormatClaudeCannotReadBecomesAJPEG() throws {
        #expect(DraftAttachments.PhotoFormat(contentTypes: [.png]) == .original(fileExtension: "png"))
        #expect(DraftAttachments.PhotoFormat(contentTypes: [.jpeg, .heic]) == .original(fileExtension: "jpg"))
        #expect(DraftAttachments.PhotoFormat(contentTypes: [.gif]) == .original(fileExtension: "gif"))
        #expect(DraftAttachments.PhotoFormat(contentTypes: [.webP]) == .original(fileExtension: "webp"))
        #expect(DraftAttachments.PhotoFormat(contentTypes: [.heic, .jpeg]) == .jpeg)
        #expect(DraftAttachments.PhotoFormat(contentTypes: [.tiff]) == .jpeg)
        #expect(DraftAttachments.PhotoFormat(contentTypes: []) == .jpeg)

        // A readable format is saved as it came.
        let png = try QuickEntryTests.pngData()
        #expect(try DraftAttachments.photoFileData(png, format: .original(fileExtension: "png")) == png)

        // Any other image is a JPEG of at most 2048 pixels on its long side.
        // HEIC is tried where this Mac can write it; TIFF stands in for it.
        let large = try Self.image(width: 3000, height: 1500)
        var sources = [try Self.encoded(large, as: .tiff)]
        if let heic = try? Self.encoded(large, as: .heic) { sources.append(heic) }
        for source in sources {
            let jpeg = try DraftAttachments.photoFileData(source, format: .jpeg)
            let decoded = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
            #expect(CGImageSourceGetType(decoded) as String? == UTType.jpeg.identifier)
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any])
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == 2048)
            #expect(properties[kCGImagePropertyPixelHeight] as? Int == 1024)
        }
        #expect(throws: (any Error).self) { try DraftAttachments.photoFileData(Data("not an image".utf8), format: .jpeg) }
    }

    private static func image(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private struct EncoderUnavailable: Error {}

    private static func encoded(_ image: CGImage, as type: UTType) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw EncoderUnavailable()
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw EncoderUnavailable() }
        return data as Data
    }

    // MARK: - Edit

    @Test func editTakesAWaitingMessagesFilesBackWhenEachIsStillACopy() throws {
        defer { cleanUp() }
        let coordinator = CoordinatorAttachments(coordinatorDirectoryURL: root.appendingPathComponent("coordinator"))
        let copies = try coordinator.stage([try file("shot.png"), try file("log.txt")], messageID: UUID())
        let paths = copies.map { $0.path(percentEncoded: false) }

        // From the chat: the text and the files.
        let chat = RemoteMessageAttachmentStore.Staged.deliveryText(text: "Look at these", paths: paths)
        let parts = try #require(CoordinatorChatModel.editParts(of: chat, attachments: coordinator, room: 10))
        #expect(parts.text == "Look at these")
        #expect(parts.files.map { $0.path(percentEncoded: false) } == paths)

        // From quick entry: the text keeps Toastty's first line.
        let quickEntry = CoordinatorMessageHeader.quickEntryMessage(.init(), text: "Look", attachmentPaths: paths)
        #expect(CoordinatorChatModel.editParts(of: quickEntry, attachments: coordinator, room: 10)?.text
            == "[Toastty] Quick entry from the user\nLook")

        // The text keeps its paths when a file cannot come back: there is
        // no room for all of them, one is not a copy in the coordinator's
        // folder, or one is gone.
        #expect(CoordinatorChatModel.editParts(of: chat, attachments: coordinator, room: 1) == nil)
        let elsewhere = RemoteMessageAttachmentStore.Staged.deliveryText(
            text: "Look", paths: [paths[0], try file("outside.txt").path(percentEncoded: false)]
        )
        #expect(CoordinatorChatModel.editParts(of: elsewhere, attachments: coordinator, room: 10) == nil)
        let dotted = RemoteMessageAttachmentStore.Staged.deliveryText(
            text: "Look", paths: [copies[0].deletingLastPathComponent().path + "/../../../sources/outside.txt"]
        )
        #expect(CoordinatorChatModel.editParts(of: dotted, attachments: coordinator, room: 10) == nil)
        try FileManager.default.removeItem(at: copies[1])
        #expect(CoordinatorChatModel.editParts(of: chat, attachments: coordinator, room: 10) == nil)
        // A message without files has nothing to take back.
        #expect(CoordinatorChatModel.editParts(of: "Just text", attachments: coordinator, room: 10) == nil)
    }
}

/// A drag over a view, as AppKit hands it to the view's drop methods.
@MainActor
private final class FakeDrag: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard) {
        draggingPasteboard = pasteboard
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation {
        get { .default }
        set {}
    }
    var animatesToDestination: Bool {
        get { false }
        set {}
    }
    var numberOfValidItemsForDrop: Int {
        get { 1 }
        set {}
    }
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
