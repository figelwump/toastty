import AppKit
@testable import ToasttyApp
import XCTest

#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

@MainActor
final class TerminalHostViewInteractionTests: TerminalHostViewTestCase {
    func testDragOperationAcceptsNonImageLocalFileURL() throws {
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let fileURL = URL(fileURLWithPath: "/tmp/toastty drop note.md").standardizedFileURL
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))

        let targetPanelID = UUID()
        var resolvedFileURLs: [URL] = []
        var performedDrop: PreparedFileDrop?
        hostView.resolveFileDrop = { urls in
            resolvedFileURLs = urls
            return PreparedFileDrop(targetPanelID: targetPanelID, fileURLs: urls)
        }
        hostView.performFileDrop = { drop in
            performedDrop = drop
            return true
        }

        let draggingInfo = TestDraggingInfo(pasteboard: pasteboard)
        XCTAssertEqual(hostView.draggingEntered(draggingInfo), .copy)
        XCTAssertTrue(hostView.prepareForDragOperation(draggingInfo))
        XCTAssertTrue(hostView.performDragOperation(draggingInfo))

        XCTAssertEqual(resolvedFileURLs.map(\.path), [fileURL.path])
        XCTAssertEqual(performedDrop?.targetPanelID, targetPanelID)
        XCTAssertEqual(performedDrop?.fileURLs.map(\.path), [fileURL.path])
    }

    func testMakeContextMenuIncludesSearchWithGoogleForSearchableSelection() {
        let hostView = TerminalHostView()

        let menu = hostView.makeContextMenu(
            copyEnabled: true,
            pasteEnabled: true,
            selectionText: "git status"
        )

        XCTAssertEqual(menu.items.map(\.title), ["Copy", "Paste", "Search with Google"])
        XCTAssertTrue(menu.items[2].target === hostView)
        XCTAssertEqual(menu.items[2].action, #selector(TerminalHostView.searchWithGoogle(_:)))
    }

    func testMakeContextMenuOmitsSearchWithGoogleForWhitespaceOnlySelection() {
        let hostView = TerminalHostView()

        let menu = hostView.makeContextMenu(
            copyEnabled: true,
            pasteEnabled: true,
            selectionText: " \n\t "
        )

        XCTAssertEqual(menu.items.map(\.title), ["Copy", "Paste"])
    }

    func testOpenGoogleSearchNormalizesSelectionWhitespace() {
        let hostView = TerminalHostView()
        var openedURL: URL?

        hostView.openSearchSelectionURL = { url in
            openedURL = url
            return true
        }

        let opened = hostView.openGoogleSearch(for: "  brew   upgrade\npeekaboo  ")

        XCTAssertTrue(opened)
        XCTAssertEqual(
            openedURL?.absoluteString,
            "https://www.google.com/search?q=brew%20upgrade%20peekaboo"
        )
    }

    func testOpenGoogleSearchSkipsWhitespaceOnlySelection() {
        let hostView = TerminalHostView()
        var openCallCount = 0

        hostView.openSearchSelectionURL = { _ in
            openCallCount += 1
            return true
        }

        let opened = hostView.openGoogleSearch(for: " \n ")

        XCTAssertFalse(opened)
        XCTAssertEqual(openCallCount, 0)
    }

    func testGoogleSearchURLReturnsNilForWhitespaceOnlySelection() {
        XCTAssertNil(TerminalHostView.googleSearchURL(for: "\n\t "))
    }
}
#endif
