import ConversationUI
import UIKit
import XCTest

/// How the coordinator chat's bubbles load the images that the Mac serves:
/// one fetch for an image that two views ask for at once, a cached
/// thumbnail for a box that shows again, and a new fetch after a failure.
@MainActor
final class ToasttyAttachmentImageLoadingTests: XCTestCase {
    func testTwoViewsAskingAtOnceFetchTheImageOnceAndAShownAgainBoxUsesTheCache() async throws {
        let fetches = FetchLog()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 60, height: 40), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        }.pngData())
        let source = ToasttyAttachmentImageSource.remote { image, size in
            await fetches.record("\(image.index):\(size.rawValue)")
            // Long enough for the second view to ask while this runs.
            try? await Task.sleep(for: .milliseconds(200))
            return image.index == 1 ? nil : png
        }
        let image = Self.image(index: 0)

        async let first = ToasttyAttachmentImageStore.image(for: image, size: .thumbnail, maximumPixelSize: 600, source: source)
        async let second = ToasttyAttachmentImageStore.image(for: image, size: .thumbnail, maximumPixelSize: 600, source: source)
        let (one, two) = await (first, second)
        XCTAssertEqual(one?.pixelSize, CGSize(width: 60, height: 40))
        XCTAssertEqual(two?.pixelSize, CGSize(width: 60, height: 40))
        var log = await fetches.entries
        XCTAssertEqual(log, ["0:thumbnail"])

        // The box scrolls back: the cache has it.
        XCTAssertNotNil(ToasttyAttachmentImageStore.cachedThumbnail(for: image, maximumPixelSize: 600, source: source))
        _ = await ToasttyAttachmentImageStore.image(for: image, size: .thumbnail, maximumPixelSize: 600, source: source)
        log = await fetches.entries
        XCTAssertEqual(log, ["0:thumbnail"])

        // The full size is its own fetch, and is not kept.
        _ = await ToasttyAttachmentImageStore.image(for: image, size: .full, maximumPixelSize: 4_096, source: source)
        _ = await ToasttyAttachmentImageStore.image(for: image, size: .full, maximumPixelSize: 4_096, source: source)
        log = await fetches.entries
        XCTAssertEqual(log, ["0:thumbnail", "0:full", "0:full"])

        // An image the Mac does not send: nothing is cached, so the box
        // asks again when it shows again.
        let missing = Self.image(index: 1)
        let absent = await ToasttyAttachmentImageStore.image(for: missing, size: .thumbnail, maximumPixelSize: 600, source: source)
        XCTAssertNil(absent)
        _ = await ToasttyAttachmentImageStore.image(for: missing, size: .thumbnail, maximumPixelSize: 600, source: source)
        log = await fetches.entries
        XCTAssertEqual(log, ["0:thumbnail", "0:full", "0:full", "1:thumbnail", "1:thumbnail"])

        // A message that is still sending has no event: no fetch.
        let sending = ToasttyAttachedImage(url: URL(fileURLWithPath: "/tmp/a.png"), conversationID: nil, eventID: nil, index: 0)
        let none = await ToasttyAttachmentImageStore.image(for: sending, size: .thumbnail, maximumPixelSize: 600, source: source)
        XCTAssertNil(none)
        log = await fetches.entries
        XCTAssertEqual(log.count, 5)
    }

    private static let conversationID = UUID()

    private static func image(index: Int) -> ToasttyAttachedImage {
        ToasttyAttachedImage(
            url: URL(fileURLWithPath: "/Users/me/Desktop/shot-\(index).png"),
            conversationID: conversationID,
            eventID: "claude:\(UUID().uuidString)-\(index)",
            index: index
        )
    }
}

private actor FetchLog {
    private(set) var entries: [String] = []
    func record(_ entry: String) { entries.append(entry) }
}
