import CoreState
import Foundation
import RemoteProtocol
import Testing

@testable import ToasttyApp

@MainActor
struct RemotePreviewProviderTests {
    @Test func inventoryPreservesEmptyWorkspacesAndAllHiddenInactiveTabsInOrder() throws {
        var state = AppState.bootstrap()
        let workspaceID = try #require(state.windows.first?.workspaceIDs.first)
        var workspace = try #require(state.workspacesByID[workspaceID])
        var first = try #require(workspace.orderedTabs.first)
        var second = WorkspaceTabState.bootstrap()
        first.customTitle = "First"
        second.customTitle = "Second"
        let a = panel(title: "A", path: "/tmp/a.md")
        let b = panel(title: "B", path: "/tmp/b.md")
        let c = panel(title: "C", path: "/tmp/c.md")
        first.rightAuxPanel.appendTab(a)
        first.rightAuxPanel.appendTab(b)
        first.rightAuxPanel.isVisible = false
        second.rightAuxPanel.appendTab(c)
        workspace.tabIDs = [second.id, first.id]
        workspace.tabsByID = [first.id: first, second.id: second]
        workspace.selectedTabID = second.id
        state.workspacesByID[workspaceID] = workspace
        let empty = WorkspaceState.bootstrap(title: "Empty")
        state.workspacesByID[empty.id] = empty
        state.windows[0].workspaceIDs.append(empty.id)
        let inventory = RemoteAccessService.workspaceInventory(state: state)
        #expect(inventory.map(\.id) == [workspaceID, empty.id])
        #expect(inventory[0].panels.map(\.panelID) == [c.panelID, a.panelID, b.panelID])
        #expect(inventory[0].panels.map(\.workspaceTabTitle) == ["Second", "First", "First"])
        #expect(inventory[0].panels.map(\.auxiliaryTabID) == [c.id, a.id, b.id])
        #expect(inventory[1].panels.isEmpty)
        workspace.tabsByID[first.id]?.rightAuxPanel.removeTab(id: a.id)
        state.workspacesByID[workspaceID] = workspace
        #expect(
            RemoteAccessService.workspaceInventory(state: state)[0].panels.map(\.panelID) == [
                c.panelID, b.panelID,
            ])
    }

    @Test func savedDocumentsIncludeLineAndScratchpadRevisionMustMatch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "preview-provider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("plan.md")
        try Data("# Saved on disk".utf8).write(to: file)
        let target = RemotePreviewTarget.panel(workspaceID: UUID(), panelID: UUID())
        let operation = RemoteGatewayPreviewOperation(
            deviceID: UUID(), request: .preview(.init(target: target)))
        let context = RemotePreviewContext(
            title: "Plan",
            source: .file(
                reference: file.path + "#L12", recordedCWD: nil, openPaths: [file.path],
                format: .markdown))
        let response = try RemotePreviewProvider.response(operation: operation, context: context)
        guard
            case .document(let document) = try JSONDecoder().decode(
                RemotePreviewResponse.self, from: response.body
            ).content
        else {
            Issue.record("Expected saved document")
            return
        }
        #expect(document.content == "# Saved on disk")
        #expect(document.line == 12)
        let utf16 = "# Unicode café 🌱"
        try #require(utf16.data(using: .utf16)).write(to: file)
        let utf16Response = try RemotePreviewProvider.response(
            operation: operation, context: context)
        guard
            case .document(let unicodeDocument) = try JSONDecoder().decode(
                RemotePreviewResponse.self, from: utf16Response.body
            ).content
        else {
            Issue.record("Expected UTF-16 document")
            return
        }
        #expect(unicodeDocument.content == utf16)
        let store = ScratchpadDocumentStore(directoryURL: directory)
        let documentID = UUID()
        _ = try store.createDocument(
            documentID: documentID, title: "Scratch", content: "<h1>Hello</h1>", sessionLink: nil)
        let stale = RemotePreviewContext(
            title: "Scratch",
            source: .scratchpad(documentID: documentID, revision: 0, storeDirectory: directory))
        #expect(throws: RemotePreviewError.stale) {
            try RemotePreviewProvider.response(operation: operation, context: stale)
        }
    }

    @Test func redirectedHTMLEntryDoesNotGrantOutsideHTMLOrAssets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "preview-html-grant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let entry = directory.appendingPathComponent("entry.html")
        let outsideEntry = outside.appendingPathComponent("private.html")
        try Data("<h1>Original</h1>".utf8).write(to: entry)
        try Data("<h1>Private</h1>".utf8).write(to: outsideEntry)
        try Data("private {}".utf8).write(to: outside.appendingPathComponent("private.css"))
        let target = RemotePreviewTarget.panel(workspaceID: UUID(), panelID: UUID())
        let context = RemotePreviewContext(
            title: "HTML",
            source: .file(
                reference: entry.path, recordedCWD: nil,
                openPaths: [entry.path], format: nil))
        let preview = RemoteGatewayPreviewOperation(
            deviceID: UUID(), request: .preview(.init(target: target)))
        _ = try RemotePreviewProvider.response(operation: preview, context: context)
        try FileManager.default.removeItem(at: entry)
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: outsideEntry)
        #expect(throws: RemotePreviewError.denied) {
            try RemotePreviewProvider.response(operation: preview, context: context)
        }
        let resource = RemoteGatewayPreviewOperation(
            deviceID: UUID(),
            request: .resource(
                .init(
                    target: target,
                    expectedSourcePath: try RemotePreviewFileReader.canonicalPath(
                        outsideEntry.path),
                    relativePath: "private.css")))
        #expect(throws: RemotePreviewError.denied) {
            try RemotePreviewProvider.response(operation: resource, context: context)
        }
    }

    private func panel(title: String, path: String) -> RightAuxPanelTabState {
        let id = UUID()
        return .init(
            id: UUID(), identity: .localDocument(path: path), panelID: id,
            panelState: .web(.init(definition: .localDocument, title: title, filePath: path)))
    }
}
