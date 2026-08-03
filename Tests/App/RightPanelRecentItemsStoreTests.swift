import CoreState
import Foundation
import XCTest
@testable import ToasttyApp

@MainActor
final class RightPanelRecentItemsStoreTests: XCTestCase {
    func testListDedupesSortsNewestFirstAndCapsItems() {
        let firstID = RecentRightPanelItemID.localDocument(path: "/tmp/first.md")
        let secondID = RecentRightPanelItemID.browser(url: "https://example.com/second")
        let thirdID = RecentRightPanelItemID.scratchpad(
            documentID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )
        var list = RightPanelRecentItemsList(maxItems: 2)

        list.record(
            RecentRightPanelItem(
                id: firstID,
                title: "First",
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            maxItems: 2
        )
        list.record(
            RecentRightPanelItem(
                id: secondID,
                title: "Second",
                updatedAt: Date(timeIntervalSince1970: 200)
            ),
            maxItems: 2
        )
        list.record(
            RecentRightPanelItem(
                id: firstID,
                title: "First Updated",
                updatedAt: Date(timeIntervalSince1970: 300)
            ),
            maxItems: 2
        )
        list.record(
            RecentRightPanelItem(
                id: thirdID,
                title: "Third",
                updatedAt: Date(timeIntervalSince1970: 400)
            ),
            maxItems: 2
        )

        XCTAssertEqual(list.items.map(\.id), [thirdID, firstID])
        XCTAssertEqual(list.items.last?.title, "First Updated")
    }

    func testBrowserPanelReplacementRemovesPreviousURLForSamePanel() {
        let oldID = RecentRightPanelItemID.browser(url: "https://example.com/old")
        let newID = RecentRightPanelItemID.browser(url: "https://example.com/new")
        var list = RightPanelRecentItemsList()

        list.record(
            RecentRightPanelItem(
                id: oldID,
                title: "Old",
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )
        list.record(
            RecentRightPanelItem(
                id: newID,
                title: "New",
                updatedAt: Date(timeIntervalSince1970: 200)
            ),
            replacingID: oldID
        )

        XCTAssertEqual(list.items.map(\.id), [newID])
    }

    func testStorePersistsVersionedCodableIDs() throws {
        let directoryURL = temporaryDirectory()
        let fileURL = directoryURL.appending(path: "recent-right-panel-items.json", directoryHint: .notDirectory)
        let scratchpadID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let store = RightPanelRecentItemsStore(
            fileURL: fileURL,
            persistDebounceInterval: 0
        )
        let items = [
            RecentRightPanelItem(
                id: .localDocument(path: "/tmp/project/README.md"),
                title: "README.md",
                detail: "/tmp/project/README.md",
                updatedAt: Date(timeIntervalSince1970: 300)
            ),
            RecentRightPanelItem(
                id: .scratchpad(documentID: scratchpadID),
                title: "Plan",
                detail: "Scratchpad",
                updatedAt: Date(timeIntervalSince1970: 200)
            ),
            RecentRightPanelItem(
                id: .browser(url: "https://example.com/docs"),
                title: "Docs",
                detail: "example.com",
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
        ]

        for item in items {
            store.record(item)
        }
        store.flushForTesting()

        let reloaded = RightPanelRecentItemsStore(
            fileURL: fileURL,
            persistDebounceInterval: 0
        )
        let persistedJSON = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertEqual(reloaded.items.map(\.id), items.map(\.id))
        XCTAssertTrue(persistedJSON.contains("\"version\" : 1"))
        XCTAssertTrue(persistedJSON.contains("\"type\" : \"localDocument\""))
        XCTAssertTrue(persistedJSON.contains("\"type\" : \"scratchpad\""))
        XCTAssertTrue(persistedJSON.contains("\"type\" : \"browser\""))
    }

    func testCorruptStoreLoadFallsBackToEmptyAndPreservesBackup() throws {
        let directoryURL = temporaryDirectory()
        let fileURL = directoryURL.appending(path: "recent-right-panel-items.json", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(to: fileURL)

        let store = RightPanelRecentItemsStore(fileURL: fileURL)
        let backupURLs = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("recent-right-panel-items.json.corrupt-")
        }

        XCTAssertEqual(store.items, [])
        XCTAssertEqual(backupURLs.count, 1)
        XCTAssertEqual(try String(contentsOf: backupURLs[0], encoding: .utf8), "{not-json")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "toastty-right-panel-recents-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
