import AppKit
import CoreState
import XCTest
@testable import ToasttyApp

/// Renders the quick entry panel as a user sees it, and keeps the images on
/// the test result for visual review against "Task Inbox Mockups" panel 1.
@MainActor
final class QuickEntryPanelSnapshotTests: XCTestCase {
    private static let designText = "Sidebar unread pill doesn't clear when I read the session from the phone, see screenshot. Probably the read-receipt path skips the desktop store"

    private var stagingRoot: URL!
    private var store: AppStore!
    private var controller: QuickEntryController!

    override func setUp() async throws {
        store = AppStore(persistTerminalFontPreference: false)
        let workspace = try XCTUnwrap(store.selectedWorkspace)
        _ = store.send(.renameWorkspace(workspaceID: workspace.id, title: "toastty"))
        stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-quick-entry-snapshot-\(UUID().uuidString)", isDirectory: true)
        controller = QuickEntryController(
            store: store,
            agentCatalogProvider: TestAgentCatalogProvider(),
            create: { _ in throw TaskError("not used") },
            configLoader: { TasksConfig() },
            stagingRootURL: stagingRoot,
            registersGlobalHotKey: false
        )
    }

    override func tearDown() async throws {
        controller.dismiss()
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    func testEmptyPanelIsCompactWithCreateTaskQuiet() throws {
        controller.present(prefill: .empty)
        let model = try XCTUnwrap(controller.model)
        XCTAssertFalse(model.canSubmit)
        let empty = try render("quick-entry-empty")

        model.text = Self.designText
        let typed = try render("quick-entry-typed")
        XCTAssertEqual(typed.size.height, empty.size.height, "Two lines fit the text area's minimum height")
    }

    func testDesignStateWithScreenshotAttached() throws {
        controller.present(prefill: .empty)
        let model = try XCTUnwrap(controller.model)
        model.text = Self.designText
        model.attachImageData(try Self.screenshotData(), named: "Screenshot 4.11.52 PM.png")
        XCTAssertEqual(model.attachments.first?.displayName, "Screenshot 4.11.52 PM.png")
        XCTAssertNotNil(model.attachments.first?.thumbnail)
        XCTAssertTrue(model.canSubmit)
        try render("quick-entry-design-state")
    }

    func testPinnedWorkspaceWithSelectionAndScreenshot() throws {
        let workspace = try XCTUnwrap(store.selectedWorkspace)
        controller.present(prefill: QuickEntryPrefill(workspaceID: workspace.id, selectionText: "error: socket closed (POSIX 53)"))
        let model = try XCTUnwrap(controller.model)
        model.text = Self.designText
        model.attachImageData(try Self.screenshotData(), named: "Screenshot 4.11.52 PM.png")
        XCTAssertEqual(model.attachments.map(\.displayName), ["selection.txt", "Screenshot 4.11.52 PM.png"])
        XCTAssertEqual(model.workspaceTitle, "toastty")
        XCTAssertEqual(model.agentTitle, "Auto")
        try render("quick-entry-pinned-workspace")
    }

    func testDropHighlightAndError() throws {
        controller.present(prefill: .empty)
        let model = try XCTUnwrap(controller.model)
        model.isDropTargeted = true
        try render("quick-entry-drop-highlight")
        model.isDropTargeted = false

        model.attachFiles([URL(fileURLWithPath: "/nonexistent/Report.pdf")])
        let deadline = Date().addingTimeInterval(5)
        while model.pendingAttachmentCount > 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNotNil(model.errorMessage)
        try render("quick-entry-error")
    }

    func testLongTextGrowsThePanelUpToItsLimit() throws {
        controller.present(prefill: .empty)
        let model = try XCTUnwrap(controller.model)
        let short = try render("quick-entry-before-long-text")
        model.text = Array(repeating: Self.designText, count: 8).joined(separator: "\n\n")
        let long = try render("quick-entry-long-text")
        XCTAssertGreaterThan(long.size.height, short.size.height)
        XCTAssertLessThanOrEqual(
            long.size.height - short.size.height,
            QuickEntryTextEditor.maximumHeight - QuickEntryTextEditor.minimumHeight + 1
        )
    }

    /// Lets SwiftUI lay out and the panel fit its content, then renders the
    /// panel and keeps the image on the test result. The window shadow is
    /// drawn by the window server and is not in the image.
    @discardableResult
    private func render(_ name: String) throws -> NSBitmapImageRep {
        let panel = try XCTUnwrap(controller.panel)
        let contentView = try XCTUnwrap(panel.contentView)
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        contentView.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds))
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        XCTAssertEqual(bitmap.size.width, QuickEntryPanel.width)
        XCTAssertEqual(bitmap.size.height, panel.frame.height, "The panel fits its content")

        let attachment = XCTAttachment(
            data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
            uniformTypeIdentifier: "public.png"
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return bitmap
    }

    private static func screenshotData() throws -> Data {
        let image = NSImage(size: NSSize(width: 340, height: 260), flipped: false) { rect in
            NSColor(calibratedRed: 0.23, green: 0.27, blue: 0.32, alpha: 1).setFill()
            rect.fill()
            NSColor(calibratedRed: 0.42, green: 0.48, blue: 0.53, alpha: 1).setFill()
            NSRect(x: 40, y: 190, width: 220, height: 24).fill()
            NSColor(calibratedRed: 0.91, green: 0.58, blue: 0.05, alpha: 0.6).setFill()
            NSRect(x: 40, y: 130, width: 160, height: 24).fill()
            return true
        }
        return try XCTUnwrap(image.tiffRepresentation)
    }
}
