import AppKit
import CoreState
import XCTest
@testable import ToasttyApp

/// Renders the quick entry panel as a user sees it, and keeps the image on
/// the test result for visual review against the design.
@MainActor
final class QuickEntryPanelSnapshotTests: XCTestCase {
    func testFilledPanelRendersTextAttachmentsAndPills() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let workspace = try XCTUnwrap(store.selectedWorkspace)
        _ = store.send(.renameWorkspace(workspaceID: workspace.id, title: "toastty"))
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-quick-entry-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let controller = QuickEntryController(
            store: store,
            agentCatalogProvider: TestAgentCatalogProvider(),
            create: { _ in throw TaskError("not used") },
            configLoader: { TasksConfig() },
            stagingRootURL: stagingRoot,
            registersGlobalHotKey: false
        )

        controller.present(prefill: QuickEntryPrefill(workspaceID: workspace.id, selectionText: "error: socket closed (POSIX 53)"))
        defer { controller.dismiss() }
        let model = try XCTUnwrap(controller.model)
        model.text = "Sidebar unread pill doesn't clear when I read the session from the phone, see screenshot. Probably the read-receipt path skips the desktop store"
        let screenshot = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        model.attachImageData(try XCTUnwrap(screenshot.tiffRepresentation), named: "Screenshot 4.11.52 PM.png")
        XCTAssertEqual(model.attachments.map(\.displayName), ["selection.txt", "Screenshot 4.11.52 PM.png"])
        XCTAssertEqual(model.workspaceTitle, "toastty")
        XCTAssertEqual(model.agentTitle, "Auto")
        XCTAssertTrue(model.canSubmit)

        let contentView = try XCTUnwrap(controller.panel?.contentView)
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        contentView.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds))
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        XCTAssertEqual(bitmap.size, QuickEntryPanel.defaultSize)

        let attachment = XCTAttachment(
            data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
            uniformTypeIdentifier: "public.png"
        )
        attachment.name = "quick-entry-panel"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
