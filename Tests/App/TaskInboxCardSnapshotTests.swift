import AppKit
import CoreState
import SwiftUI
import XCTest
@testable import ToasttyApp

/// Renders the Inbox card of a task that waits for a workspace, with triage
/// off and on, and keeps the images on the test result for visual review.
@MainActor
final class TaskInboxCardSnapshotTests: XCTestCase {
    func testCardWithTriageOffOffersNoRetryTriage() throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        fixture.config = TasksConfig(defaults: .init(agent: "claude"))
        XCTAssertFalse(fixture.coordinator.isTriageConfigured)
        let record = try waitingTask(in: fixture, reason: TaskCoordinator.noWorkspaceReason)

        let image = try render(record, in: fixture, name: "task-inbox-card-triage-off")
        let withTriage = try {
            fixture.config = TasksConfig(triage: .init(command: "triage"), defaults: .init(agent: "claude"))
            XCTAssertTrue(fixture.coordinator.isTriageConfigured)
            return try render(record, in: fixture, name: "task-inbox-card-triage-on")
        }()
        // The same card; triage only adds its button to the footer row.
        XCTAssertEqual(image.size.height, withTriage.size.height)
    }

    private func waitingTask(in fixture: TaskCoordinatorTests.Fixture, reason: String) throws -> TaskRecord {
        let record = TaskRecord(
            createdAt: Date(),
            text: "Sidebar drops the Inbox group after a restart even though one task is still in it",
            title: "Sidebar drops the Inbox group after a restart",
            slug: "sidebar-inbox-restart",
            source: .quickEntry,
            setup: .needsWorkspace(reason: reason)
        )
        try fixture.coordinator.records.insert(record)
        return record
    }

    /// Hosts the card in a window so `onAppear` loads its choices, then
    /// renders it on the card's own background.
    @discardableResult
    private func render(_ record: TaskRecord, in fixture: TaskCoordinatorTests.Fixture, name: String) throws -> NSBitmapImageRep {
        let card = TaskInboxCard(taskID: record.id, records: fixture.coordinator.records, coordinator: fixture.coordinator) {}
            .background(TaskInboxCard.background)
            .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: card)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer { window.close() }
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        window.setContentSize(hostingView.fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let attachment = XCTAttachment(
            data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
            uniformTypeIdentifier: "public.png"
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return bitmap
    }
}
