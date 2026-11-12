import AppKit
import ConversationUI
import CoreState
import SwiftUI
import XCTest
@testable import ToasttyApp

/// Renders the coordinator chat's composer as a user sees it: the row of
/// attached files with image previews, at the widths a chat panel has.
/// The images are kept on the test result. With
/// `TOASTTY_COMPOSER_SNAPSHOT_DIR` set (as `TEST_RUNNER_TOASTTY_COMPOSER_SNAPSHOT_DIR`
/// for `xcodebuild test`), they are also written there as PNG files.
@MainActor
final class CoordinatorComposerSnapshotTests: XCTestCase {
    private var root: URL!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-composer-snapshot-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        try? FileManager.default.removeItem(at: root)
    }

    func testTrayShowsPreviewsFileNamesAndACopyInProgressAtEachWidth() throws {
        let draft = DraftAttachments(stagingDirectoryURL: root.appendingPathComponent("staging"))
        draft.attachImageData(try Self.screenshotData(width: 340, height: 260), named: "Screenshot 4.11.52 PM.png")
        draft.attachImageData(try Self.screenshotData(width: 200, height: 300), named: "Photo.png")
        draft.attachText("error: socket closed (POSIX 53)", named: "terminal-log.txt")
        // A promised file that has not arrived yet shows the spinner.
        let promise = try XCTUnwrap(draft.beginPromisedAttachment())
        defer { draft.finishPromisedAttachment(.failure(CocoaError(.fileNoSuchFile))) }
        XCTAssertEqual(draft.attachments.map(\.displayName), ["Screenshot 4.11.52 PM.png", "Photo.png", "terminal-log.txt"])
        XCTAssertEqual(draft.attachments.map { $0.thumbnail != nil }, [true, true, false])
        XCTAssertEqual(draft.pendingCount, 1)
        _ = promise

        let empty = DraftAttachments(stagingDirectoryURL: root.appendingPathComponent("empty"))
        let emptyHeight = try render("composer-empty-520", draft: empty, text: "", width: 520).size.height
        for width in [360, 520, 760] {
            let image = try render(
                "composer-tray-\(width)",
                draft: draft,
                text: "Why does the sidebar look like this? The log is attached.",
                width: CGFloat(width)
            )
            XCTAssertEqual(image.size.width, CGFloat(width))
            XCTAssertGreaterThanOrEqual(
                image.size.height, emptyHeight + CoordinatorComposerView.trayHeight,
                "The tray sits above the text field at width \(width)"
            )
        }
    }

    func testAFileDraggedOverTheChatHighlightsTheComposer() throws {
        let draft = DraftAttachments(stagingDirectoryURL: root.appendingPathComponent("staging"))
        draft.attachImageData(try Self.screenshotData(width: 340, height: 260), named: "Screenshot.png")
        draft.isDropTargeted = true
        try render("composer-drop-highlight-520", draft: draft, text: "", width: 520)
    }

    /// A reply shows above the files: whose message and when, its start on
    /// two lines, and ✕. It adds its height to the composer at each width.
    func testAReplyShowsAboveTheFilesAtEachWidth() throws {
        let draft = DraftAttachments(stagingDirectoryURL: root.appendingPathComponent("staging"))
        draft.attachImageData(try Self.screenshotData(width: 340, height: 260), named: "Screenshot.png")
        let empty = DraftAttachments(stagingDirectoryURL: root.appendingPathComponent("empty"))
        let reply = CoordinatorReplyTarget(
            text: "I made two tasks. [Fix the unread dot](toastty://task/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F) waits "
                + "for your answer: should the dot clear on hover, or only on click?\n\nThe second task starts when "
                + "the first one merges.",
            time: "14:05"
        )
        let withoutReply = try render("composer-tray-only-520", draft: draft, text: "Only on click.", width: 520).size.height
        let withReply = try render("composer-reply-tray-520", draft: draft, text: "Only on click.", width: 520, reply: reply)
            .size.height
        XCTAssertGreaterThan(withReply, withoutReply + 20, "The reply sits above the tray")
        for width in [360, 760] {
            try render("composer-reply-\(width)", draft: empty, text: "Only on click.", width: CGFloat(width), reply: reply)
        }
    }

    /// The ＋ button, the send button and the field's last line share one
    /// center line at the smallest, the default and the largest text size,
    /// with one line and with several.
    func testButtonsLineUpWithTheLastLineAtEachTextSize() throws {
        let empty = DraftAttachments(stagingDirectoryURL: root.appendingPathComponent("empty"))
        for scale in [CoordinatorChatModel.minimumTextScale, 1, CoordinatorChatModel.maximumTextScale] {
            let fontSize = CoordinatorComposerTextEditor.defaultFontSize * scale
            for (name, text) in [("line", "Only on click."), ("lines", "One\nTwo\nOnly on click.")] {
                let image = try render("composer-align-\(name)-\(scale)", draft: empty, text: text, width: 520, fontSize: fontSize)
                let centers = try Self.rowCenters(in: image, width: 520)
                XCTAssertEqual(centers.plus, centers.text, accuracy: 1, "＋ and text, \(name) at \(scale)×")
                XCTAssertEqual(centers.send, centers.text, accuracy: 1, "Send and text, \(name) at \(scale)×")
            }
        }
    }

    /// The vertical centers, in points, of the ＋ glyph, the first letter of
    /// the field's last line, and the send button, found by their pixels.
    /// The composer sits 16 points inside the image; see `render`.
    private static func rowCenters(in image: NSBitmapImageRep, width: CGFloat) throws -> (plus: CGFloat, text: CGFloat, send: CGFloat) {
        let scale = CGFloat(image.pixelsWide) / width
        func px(_ points: CGFloat) -> Int { Int((points * scale).rounded()) }
        let background = try XCTUnwrap(image.colorAt(x: px(width / 2), y: px(18))?.usingColorSpace(.sRGB))
        func isInk(_ x: Int, _ y: Int) -> Bool {
            guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            let difference = abs(color.redComponent - background.redComponent)
                + abs(color.greenComponent - background.greenComponent)
                + abs(color.blueComponent - background.blueComponent)
            return difference > 0.6
        }
        func inkRows(_ columns: Range<Int>, within rows: Range<Int>? = nil) -> [Int] {
            (rows ?? 0..<image.pixelsHigh).filter { y in columns.contains { isInk($0, y) } }
        }
        func center(_ rows: [Int]) throws -> CGFloat {
            let first = try XCTUnwrap(rows.first), last = try XCTUnwrap(rows.last)
            return CGFloat(first + last + 1) / 2 / scale
        }
        // ＋: 16 outside, 6 inside, then a 24-point button.
        let plus = try center(inkRows(px(22)..<px(46)))
        // Send: the last 24-point button before the composer's trailing edge.
        let send = try center(inkRows(px(width - 46)..<px(width - 22)))
        // The text starts 6 points after ＋. Its last line is the last run of
        // rows with ink, and its first letter is the first run of columns.
        let textColumns = px(52)..<px(width - 60)
        var lines: [[Int]] = []
        for y in inkRows(textColumns) {
            if let previous = lines.last?.last, y - previous <= 2 {
                lines[lines.count - 1].append(y)
            } else {
                lines.append([y])
            }
        }
        let lastLine = try XCTUnwrap(lines.last)
        let lineRows = lastLine.first!..<(lastLine.last! + 1)
        let firstInk = try XCTUnwrap(textColumns.first { x in lineRows.contains { isInk(x, $0) } })
        let afterGlyph = (firstInk..<textColumns.upperBound).first { x in lineRows.contains { isInk(x, $0) } == false } ?? textColumns.upperBound
        let text = try center(inkRows(firstInk..<afterGlyph, within: lineRows))
        return (plus, text, send)
    }

    /// Hosts the composer in a window, lets SwiftUI lay it out, and keeps
    /// the image. The window is on screen, far outside every display, so
    /// SwiftUI lays out and draws as it does in the app.
    @discardableResult
    private func render(
        _ name: String,
        draft: DraftAttachments,
        text: String,
        width: CGFloat,
        reply: CoordinatorReplyTarget? = nil,
        fontSize: CGFloat = CoordinatorComposerTextEditor.defaultFontSize
    ) throws -> NSBitmapImageRep {
        let composer = CoordinatorComposerView(
            text: .constant(text),
            attachments: draft,
            reply: reply,
            placeholder: "Message the coordinator…  ⌥Space from anywhere",
            canStop: false,
            focusRequestID: 0,
            fontSize: fontSize,
            onSend: {},
            onStop: {},
            dropTarget: AttachmentDropTarget(attachments: draft)
        )
        .frame(width: width - 32)
        .padding(16)
        .background(ConversationDesignTokens.background)
        .fixedSize(horizontal: false, vertical: true)

        let host = NSHostingView(rootView: composer)
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        windows.append(window)
        let size = host.fittingSize
        window.setContentSize(NSSize(width: width, height: size.height))
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["TOASTTY_COMPOSER_SNAPSHOT_DIR"], directory.isEmpty == false {
            let folder = URL(filePath: directory, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent("\(name).png"))
        }
        return bitmap
    }

    private static func screenshotData(width: CGFloat, height: CGFloat) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor(calibratedRed: 0.23, green: 0.27, blue: 0.32, alpha: 1).setFill()
            rect.fill()
            NSColor(calibratedRed: 0.42, green: 0.48, blue: 0.53, alpha: 1).setFill()
            NSRect(x: 20, y: rect.height - 50, width: rect.width * 0.6, height: 18).fill()
            NSColor(calibratedRed: 0.91, green: 0.58, blue: 0.05, alpha: 0.6).setFill()
            NSRect(x: 20, y: rect.height - 90, width: rect.width * 0.45, height: 18).fill()
            return true
        }
        return try XCTUnwrap(image.tiffRepresentation)
    }
}
