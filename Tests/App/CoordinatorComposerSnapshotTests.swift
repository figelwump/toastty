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

    /// Hosts the composer in a window, lets SwiftUI lay it out, and keeps
    /// the image. The window is on screen, far outside every display, so
    /// SwiftUI lays out and draws as it does in the app.
    @discardableResult
    private func render(_ name: String, draft: DraftAttachments, text: String, width: CGFloat) throws -> NSBitmapImageRep {
        let composer = CoordinatorComposerView(
            text: .constant(text),
            attachments: draft,
            placeholder: "Message the coordinator…  ⌥Space from anywhere",
            canStop: false,
            focusRequestID: 0,
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
