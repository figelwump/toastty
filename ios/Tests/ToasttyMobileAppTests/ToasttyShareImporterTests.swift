import Foundation
import ImageIO
import RemoteProtocol
import UniformTypeIdentifiers
import XCTest
@testable import ToasttyMobileApp

@MainActor
final class ToasttyShareImporterTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    override func setUp() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSafariLinkBecomesTheTitleAndURLInTheMessage() async throws {
        let item = NSExtensionItem()
        item.attributedContentText = NSAttributedString(string: "Toastty docs")
        item.attachments = [NSItemProvider(object: try XCTUnwrap(URL(string: "https://example.com/docs")) as NSURL)]
        let selection = NSExtensionItem()
        selection.attachments = [NSItemProvider(object: "  Selected words \n" as NSString)]

        let draft = await ToasttyShareImporter.makeDraft(from: [item, selection])

        XCTAssertEqual(draft.text, "Toastty docs\nhttps://example.com/docs\n\nSelected words")
        XCTAssertEqual(draft.attachments, [])
        XCTAssertEqual(draft.skippedItemCount, 0)
        XCTAssertNil(draft.skippedItemsNotice)
    }

    func testPhotosBecomeJPEGAttachmentsAndOnlyFourAreKept() async throws {
        let png = try pngData()
        let item = NSExtensionItem()
        item.attachments = (1...5).map { index in
            let provider = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
            provider.suggestedName = "IMG_000\(index).PNG"
            return provider
        }

        let draft = await ToasttyShareImporter.makeDraft(from: [item])

        XCTAssertEqual(draft.attachments.map(\.filename), ["IMG_0001.jpg", "IMG_0002.jpg", "IMG_0003.jpg", "IMG_0004.jpg"])
        XCTAssertTrue(draft.attachments.allSatisfy { $0.data.starts(with: [0xFF, 0xD8, 0xFF]) })
        XCTAssertEqual(draft.skippedItemCount, 1)
        XCTAssertEqual(draft.text, "")
        XCTAssertNotNil(draft.skippedItemsNotice)
        XCTAssertNil(RemoteAttachmentPolicy.validationError(for: draft.attachments))
    }

    func testFilesAttachWithTheirNamesAndUnsupportedItemsAreCounted() async throws {
        let pdf = directory.appendingPathComponent("spec.pdf")
        try Data("%PDF-1.7\n%%EOF\n".utf8).write(to: pdf)
        let notes = directory.appendingPathComponent("notes.md")
        try Data("# Notes\n".utf8).write(to: notes)
        let markdown = try XCTUnwrap(UTType(filenameExtension: "md"))
        let named = NSItemProvider(item: Data("# Agenda\n".utf8) as NSData, typeIdentifier: markdown.identifier)
        named.suggestedName = "meeting agenda"
        let item = NSExtensionItem()
        item.attachments = [
            try XCTUnwrap(NSItemProvider(contentsOf: pdf)),
            try XCTUnwrap(NSItemProvider(contentsOf: notes)),
            named,
            NSItemProvider(item: Data([0, 1, 2]) as NSData, typeIdentifier: UTType.mpeg4Movie.identifier),
        ]

        let draft = await ToasttyShareImporter.makeDraft(from: [item])

        // iOS names an unnamed provider's copy itself; it keeps the PDF type.
        XCTAssertEqual(draft.attachments.map { ($0.filename as NSString).pathExtension }, ["pdf", "md", "md"])
        XCTAssertEqual(draft.attachments.dropFirst().map(\.filename), ["notes.md", "meeting agenda.md"])
        XCTAssertEqual(draft.attachments.last?.data, Data("# Agenda\n".utf8))
        XCTAssertEqual(draft.skippedItemCount, 1)
        XCTAssertFalse(draft.isEmpty)
    }

    func testALinkWinsOverNamedTextAndUnnamedDataGetsAFileName() async throws {
        let link = NSItemProvider(object: try XCTUnwrap(URL(string: "https://example.com/post")) as NSURL)
        link.registerObject("Post title" as NSString, visibility: .all)
        link.suggestedName = "Post title"
        let pdf = NSItemProvider(item: Data("%PDF-1.7\n%%EOF\n".utf8) as NSData, typeIdentifier: UTType.pdf.identifier)
        let item = NSExtensionItem()
        item.attachments = [link, pdf]

        let draft = await ToasttyShareImporter.makeDraft(from: [item])

        XCTAssertEqual(draft.text, "https://example.com/post")
        XCTAssertEqual(draft.attachments.map { ($0.filename as NSString).pathExtension }, ["pdf"])
        XCTAssertTrue(draft.attachments.first?.data.starts(with: Data("%PDF-".utf8)) == true)
        XCTAssertEqual(draft.skippedItemCount, 0)
    }

    func testNothingUsableLeavesAnEmptyDraft() async {
        let item = NSExtensionItem()
        item.attachments = [NSItemProvider(item: Data([0, 1, 2]) as NSData, typeIdentifier: UTType.mpeg4Movie.identifier)]

        let draft = await ToasttyShareImporter.makeDraft(from: [item])

        XCTAssertTrue(draft.isEmpty)
        XCTAssertEqual(draft.skippedItemCount, 1)
    }

    private func pngData() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.9, green: 0.6, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

final class ToasttySharedDraftStoreTests: XCTestCase {
    private var store: ToasttySharedDraftStore!

    override func setUp() {
        store = ToasttySharedDraftStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: store.directory)
    }

    func testADraftCanBeTakenOnlyOnce() throws {
        let draft = makeDraft()
        try store.save(draft)

        XCTAssertNil(store.waitingDraftID(), "Only a marked draft waits for the app")
        XCTAssertEqual(store.take(id: draft.id), draft)
        XCTAssertNil(store.take(id: draft.id))
        XCTAssertNil(store.take(id: UUID()))
    }

    func testTheNewestDraftThatCouldNotOpenTheAppWaitsUntilTaken() throws {
        let older = makeDraft()
        let newer = makeDraft()
        try store.save(older)
        try store.markWaiting(id: older.id)
        try setModified(Date().addingTimeInterval(-60), id: older.id, pathExtension: "waiting")
        try store.save(newer)
        try store.markWaiting(id: newer.id)

        XCTAssertEqual(store.waitingDraftID(), newer.id)
        XCTAssertEqual(store.take(id: newer.id), newer)
        XCTAssertEqual(store.waitingDraftID(), older.id)
    }

    func testExpiredDraftsAreNeitherOpenedNorKept() throws {
        let expired = makeDraft(createdAt: Date().addingTimeInterval(-ToasttySharedDraftStore.lifetime - 1))
        try store.save(expired)
        try store.markWaiting(id: expired.id)
        try setModified(expired.createdAt, id: expired.id, pathExtension: "draft")
        try setModified(expired.createdAt, id: expired.id, pathExtension: "waiting")
        let fresh = makeDraft()
        try store.save(fresh)

        XCTAssertNil(store.waitingDraftID())
        store.removeExpired()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        XCTAssertEqual(remaining, ["\(fresh.id.uuidString).draft"])
        XCTAssertNil(store.take(id: expired.id))
    }

    func testADraftFromAnotherFormatIsIgnored() throws {
        var draft = makeDraft()
        draft.version = ToasttySharedDraft.currentVersion + 1
        try store.save(draft)

        XCTAssertNil(store.take(id: draft.id))
    }

    private func makeDraft(createdAt: Date = Date()) -> ToasttySharedDraft {
        ToasttySharedDraft(
            id: UUID(),
            createdAt: createdAt,
            text: "Look at this",
            attachments: [RemoteMessageAttachment(filename: "note.txt", data: Data("note".utf8))],
            skippedItemCount: 0
        )
    }

    private func setModified(_ date: Date, id: UUID, pathExtension: String) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: store.directory.appendingPathComponent("\(id.uuidString).\(pathExtension)").path
        )
    }
}
