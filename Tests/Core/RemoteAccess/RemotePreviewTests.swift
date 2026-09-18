import Foundation
import RemoteProtocol
import Testing

@testable import CoreState

struct RemotePreviewProtocolTests {
    @Test func oldSnapshotDefaultsToNoWorkspacesAndPanelOnlyWorkspaceRoundTrips() throws {
        let old = RemoteSessionListSnapshot(
            projectionRunID: .init(), conversations: [], generatedAt: .now)
        let encoder = JSONEncoder()
        let data = try encoder.encode(old)
        #expect(!String(decoding: data, as: UTF8.self).contains("workspaces"))
        #expect(
            try JSONDecoder().decode(RemoteSessionListSnapshot.self, from: data).workspaces.isEmpty)
        var withWorkspace = old
        withWorkspace.workspaces = [.init(id: UUID(), title: "No conversations", panels: [])]
        #expect(
            try JSONDecoder().decode(
                RemoteSessionListSnapshot.self, from: encoder.encode(withWorkspace))
                == withWorkspace)
    }

    @Test func oldPanelMetadataDecodesWithoutTimestamp() throws {
        let panel = RemoteWorkspacePanel(panelID: UUID(), auxiliaryTabID: UUID(), workspaceTabID: UUID(),
                                         workspaceTabTitle: "Tab", kind: "localDocument", title: "File")
        let data = try ConversationEventCoding.makeEncoder().encode(panel)
        #expect(!String(decoding: data, as: UTF8.self).contains("updatedAt"))
        #expect(!String(decoding: data, as: UTF8.self).contains("associatedConversationID"))
        #expect(try ConversationEventCoding.makeDecoder().decode(RemoteWorkspacePanel.self, from: data).associatedConversationID == nil)
        #expect(try ConversationEventCoding.makeDecoder().decode(RemoteWorkspacePanel.self, from: data).updatedAt == nil)
    }

    @Test func scratchpadConversationAssociationRoundTrips() throws {
        let panel = RemoteWorkspacePanel(
            panelID: UUID(), auxiliaryTabID: UUID(), workspaceTabID: UUID(),
            workspaceTabTitle: "Tab", kind: "scratchpad", title: "Notes",
            associatedConversationID: RemoteConversationID())
        let data = try ConversationEventCoding.makeEncoder().encode(panel)
        #expect(try ConversationEventCoding.makeDecoder().decode(RemoteWorkspacePanel.self, from: data) == panel)
    }

    @Test func previewTargetsAndResourcesRoundTripAndRejectIncompleteEnvelopes() throws {
        for target: RemotePreviewTarget in [
            .panel(workspaceID: UUID(), panelID: UUID()),
            .conversationFile(conversationID: .init(), fileReference: "docs/plan.md#L12"),
        ] {
            let request = RemotePreviewRequest(target: target)
            #expect(
                try JSONDecoder().decode(
                    RemotePreviewRequest.self, from: JSONEncoder().encode(request)) == request)
        }
        let resource = RemoteHTMLResourceResponse(mimeType: "image/png", data: Data([0, 1, 255]))
        #expect(
            try JSONDecoder().decode(
                RemoteHTMLResourceResponse.self, from: JSONEncoder().encode(resource)) == resource)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                RemotePreviewResponse.self, from: Data(#"{"protocolVersion":"1.0"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                RemoteHTMLResourceResponse.self,
                from: Data(#"{"protocolVersion":"1.0","mimeType":"image/png"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                RemoteHTMLResourceResponse.self,
                from: Data(
                    #"{"protocolVersion":"1.0","mimeType":"image/png","data":"AA==","error":"denied"}"#
                        .utf8))
        }
    }
}

struct RemotePreviewFileReaderTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "preview-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return URL(fileURLWithPath: try RemotePreviewFileReader.canonicalPath(root.path))
    }

    @Test func projectRootAndExplicitFilesDoNotGrantOtherFilesOrHome() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let source = project.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let inside = project.appendingPathComponent("README.md").path
        try Data().write(to: URL(fileURLWithPath: inside))
        #expect(
            try RemotePreviewFileReader.resolveFile(
                reference: "../README.md", recordedCWD: source.path, explicitlyOpenPaths: []).path
                == inside)
        let outside = root.appendingPathComponent("outside.md").path
        try Data().write(to: URL(fileURLWithPath: outside))
        try Data().write(to: root.appendingPathComponent("neighbor.md"))
        #expect(
            try RemotePreviewFileReader.resolveFile(
                reference: outside, recordedCWD: source.path, explicitlyOpenPaths: [outside]).path
                == outside)
        #expect(throws: RemotePreviewError.denied) {
            try RemotePreviewFileReader.resolveFile(
                reference: root.appendingPathComponent("neighbor.md").path,
                recordedCWD: source.path, explicitlyOpenPaths: [outside])
        }
        #expect(throws: RemotePreviewError.denied) {
            try RemotePreviewFileReader.resolveFile(
                reference: "README.md", recordedCWD: nil, explicitlyOpenPaths: [])
        }
        #expect(throws: RemotePreviewError.denied) {
            try RemotePreviewFileReader.projectRoot(recordedCWD: NSHomeDirectory())
        }
    }

    @Test func rejectsSymlinkEscapesAndOnlyAllowsSupportingAssets() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let web = root.appendingPathComponent("web")
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.css")
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: web.appendingPathComponent("escape.css"), withDestinationURL: outside)
        let entry = web.appendingPathComponent("index.html").path
        for path in [
            "../outside.css", "escape.css", ".env", "README.md", "state.json", "/etc/passwd",
        ] {
            #expect(throws: RemotePreviewError.denied) {
                try RemotePreviewFileReader.resourcePath(relativePath: path, entryPath: entry)
            }
        }
        try FileManager.default.createDirectory(
            at: web.appendingPathComponent("images"), withIntermediateDirectories: true)
        try Data().write(to: web.appendingPathComponent("images/icon.png"))
        let asset = try RemotePreviewFileReader.resourcePath(
            relativePath: "images/icon.png", entryPath: entry)
        #expect(asset.path == web.appendingPathComponent("images/icon.png").path)
        #expect(asset.mimeType == "image/png")
        #expect(throws: RemotePreviewError.denied) {
            try RemotePreviewFileReader.resolveFile(
                reference: "escape.css", recordedCWD: web.path, explicitlyOpenPaths: [])
        }
    }

    @Test func boundsActualBytesAndRejectsDirectoriesAndChangedSymlink() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("document.txt")
        try Data("hello".utf8).write(to: file)
        let snapshot = try RemotePreviewFileReader.read(path: file.path, maximumBytes: 5)
        #expect(snapshot.data == Data("hello".utf8))
        #expect(snapshot.revision.count == 64)
        #expect(throws: RemotePreviewError.tooLarge) {
            try RemotePreviewFileReader.read(path: file.path, maximumBytes: 4)
        }
        #expect(throws: RemotePreviewError.denied) {
            try RemotePreviewFileReader.read(path: root.path, maximumBytes: 10)
        }
        #expect(throws: RemotePreviewError.missing) {
            try RemotePreviewFileReader.read(
                path: root.appendingPathComponent("missing.txt").path, maximumBytes: 10)
        }
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: RemotePreviewError.stale) {
            try RemotePreviewFileReader.read(path: link.path, maximumBytes: 10)
        }
    }

    @Test func exactFileGrantsRejectLeafAndAncestorSymlinkReplacement() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("allowed.md")
        let outside = root.appendingPathComponent("outside.md")
        try Data("allowed".utf8).write(to: original)
        try Data("private".utf8).write(to: outside)
        #expect(
            try RemotePreviewFileReader.resolveFile(
                reference: original.path, recordedCWD: nil,
                explicitlyOpenPaths: [original.path]).path == original.path)
        try FileManager.default.removeItem(at: original)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
        #expect(throws: RemotePreviewError.denied) {
            try RemotePreviewFileReader.resolveFile(
                reference: original.path, recordedCWD: nil,
                explicitlyOpenPaths: [original.path])
        }
        // Knowing the symlink's destination must not turn it into a new grant.
        #expect(throws: RemotePreviewError.denied) {
            try RemotePreviewFileReader.resolveFile(
                reference: outside.path, recordedCWD: nil,
                explicitlyOpenPaths: [original.path])
        }
        let directory = root.appendingPathComponent("original")
        let replacement = root.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: replacement.appendingPathComponent("doc.md"))
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: replacement)
        let path = directory.appendingPathComponent("doc.md").path
        #expect(throws: RemotePreviewError.denied) {
            try RemotePreviewFileReader.resolveFile(
                reference: path, recordedCWD: nil, explicitlyOpenPaths: [path])
        }
        #expect(throws: RemotePreviewError.denied) {
            try RemotePreviewFileReader.projectRoot(recordedCWD: directory.path)
        }
        #expect(throws: RemotePreviewError.denied) {
            try RemotePreviewFileReader.resolveFile(
                reference: "doc.md", recordedCWD: directory.path, explicitlyOpenPaths: [])
        }
    }

    @Test func authorityPathsAllowSystemAliasesButDoNotCollapseSymlinkParentTraversal() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.md")
        try Data().write(to: file)
        let varAlias = file.path.replacingOccurrences(
            of: "/private/var/", with: "/var/", options: .anchored)
        #expect(
            try RemotePreviewFileReader.resolveFile(
                reference: varAlias, recordedCWD: nil,
                explicitlyOpenPaths: [varAlias]).path == file.path)
        let tmpDirectory = URL(fileURLWithPath: "/tmp/preview-authority-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDirectory) }
        let tmpFile = tmpDirectory.appendingPathComponent("file.md")
        try Data().write(to: tmpFile)
        #expect(
            try RemotePreviewFileReader.resolveFile(
                reference: tmpFile.path, recordedCWD: nil,
                explicitlyOpenPaths: [tmpFile.path]).path
                == RemotePreviewFileReader.canonicalPath(tmpFile.path))
        let nested = root.appendingPathComponent("outside/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("outside/file.md"))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: nested)
        let expression = root.path + "/link/../file.md"
        #expect(throws: RemotePreviewError.denied) {
            try RemotePreviewFileReader.authorityPath(expression)
        }
    }

    @Test func transcriptLinkGrantsOnlyLinkedReferencesAndKeepsReadPinning() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let inside = project.appendingPathComponent("README.md")
        try Data().write(to: inside)
        let sibling = root.appendingPathComponent("sibling-worktree")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let linked = sibling.appendingPathComponent("plan.md")
        try Data("plan".utf8).write(to: linked)

        // A linked sibling-worktree file loads; the same file unlinked does not.
        let resolved = try RemotePreviewFileReader.resolveFile(
            reference: "../sibling-worktree/plan.md", recordedCWD: project.path,
            explicitlyOpenPaths: [], isTranscriptLinked: true)
        #expect(resolved == .init(path: linked.path, grant: .transcriptLink))
        #expect(throws: RemotePreviewError.denied) {
            try RemotePreviewFileReader.resolveFile(
                reference: "../sibling-worktree/plan.md", recordedCWD: project.path,
                explicitlyOpenPaths: [])
        }
        // A file the project root already allows keeps that authority.
        #expect(
            try RemotePreviewFileReader.resolveFile(
                reference: "README.md", recordedCWD: project.path, explicitlyOpenPaths: [],
                isTranscriptLinked: true).grant == .projectRoot)

        // An absolute linked /tmp file loads without a session cwd; a
        // relative reference still has nothing to resolve against.
        let tmpDirectory = URL(fileURLWithPath: "/tmp/preview-linked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDirectory) }
        let scratch = tmpDirectory.appendingPathComponent("out.patch")
        try Data("diff".utf8).write(to: scratch)
        #expect(
            try RemotePreviewFileReader.resolveFile(
                reference: scratch.path, recordedCWD: nil, explicitlyOpenPaths: [],
                isTranscriptLinked: true)
                == .init(
                    path: try RemotePreviewFileReader.canonicalPath(scratch.path),
                    grant: .transcriptLink))
        #expect(throws: RemotePreviewError.denied) {
            try RemotePreviewFileReader.resolveFile(
                reference: "out.patch", recordedCWD: nil, explicitlyOpenPaths: [],
                isTranscriptLinked: true)
        }

        // Swapping the granted file for a symlink after resolution is caught
        // by the read, and re-resolving no longer matches the granted file.
        let secret = root.appendingPathComponent("secret.md")
        try Data("private".utf8).write(to: secret)
        try FileManager.default.removeItem(at: linked)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: secret)
        #expect(throws: RemotePreviewError.stale) {
            try RemotePreviewFileReader.read(path: resolved.path, maximumBytes: 1024)
        }
        #expect(
            try RemotePreviewFileReader.resolveFile(
                reference: "../sibling-worktree/plan.md", recordedCWD: project.path,
                explicitlyOpenPaths: [], isTranscriptLinked: true) != resolved)
    }

    @Test func transcriptLinkedHTMLEntryDoesNotExposeHomeOrRootAsAssetDirectory() throws {
        let home = try RemotePreviewFileReader.canonicalPath(NSHomeDirectory())
        #expect(
            try !RemotePreviewFileReader.allowsSubresources(
                of: .init(path: home + "/report.html", grant: .transcriptLink)))
        #expect(
            try !RemotePreviewFileReader.allowsSubresources(
                of: .init(path: "/report.html", grant: .transcriptLink)))
        #expect(
            try RemotePreviewFileReader.allowsSubresources(
                of: .init(path: home + "/reports/report.html", grant: .transcriptLink)))
        // Existing grants are unchanged.
        #expect(
            try RemotePreviewFileReader.allowsSubresources(
                of: .init(path: home + "/report.html", grant: .openPanel)))
    }

    @Test func linkReferencesMatchWhatTheTranscriptRendererMakesTappable() {
        let markdown = """
            See [the plan](../toastty-foo/docs/plan.md#L12), [scratch](/tmp/out.patch),
            [spaced](docs/a%20b.md), [line](Sources/App/Foo.swift:42), <file:///tmp/a.md>,
            and [the site](https://example.com/a.md). Not a link: `[code](/etc/hosts)`.

            ```
            [fenced](/etc/passwd)
            ```
            """
        #expect(
            RemotePreviewLinkReference.localFileReferences(inMarkdown: markdown) == [
                "../toastty-foo/docs/plan.md#L12", "/tmp/out.patch", "docs/a b.md",
                "Sources/App/Foo.swift:42", "/tmp/a.md",
            ])
        #expect(RemotePreviewLinkReference.localFileReferences(inMarkdown: "/etc/hosts").isEmpty)
    }

    @Test func cancelledReadDoesNotOpenFile() async throws {
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try RemotePreviewFileReader.read(path: "/missing", maximumBytes: 10)
        }
        await #expect(throws: CancellationError.self) { try await work.value }
    }
}

extension RemoteGatewayRequestHandlerTests {
    @Test @MainActor func previewRequiresNativeReadAndRechecksRevocationAfterSuspension()
        async throws
    {
        let (handler, store, _) = Self.makeHandler()
        let native = try Self.nativeCredential(handler: handler, store: store)
        let body = try JSONEncoder().encode(
            RemotePreviewRequest(target: .panel(workspaceID: UUID(), panelID: UUID())))
        let request = Self.request(
            "POST", "/api/preview.get",
            headerFields: [
                ("authorization", "Bearer \(native.credential)"),
                ("tailscale-user-login", "owner@example.com"),
            ], body: body)
        guard case .deferredPreview(let operation) = handler.handle(request, at: Self.now) else {
            Issue.record("Native read should defer content IO")
            return
        }
        let cookie = Self.pairedDeviceCookie(store)
        guard
            case .respond(let denied) = handler.handle(
                Self.request(
                    "POST", "/api/preview.get",
                    origin: Self.origin, cookie: cookie, body: String(decoding: body, as: UTF8.self)
                ), at: Self.now)
        else {
            Issue.record("Browser credential must be rejected")
            return
        }
        #expect(denied.status == 401)
        handler.previewHandler = { operation in
            _ = try? store.revokeDevice(native.device.id, at: Self.now)
            return .json(
                status: 200, reason: "OK",
                body: try! JSONEncoder().encode(
                    RemotePreviewResponse(content: .webURL(URL(string: "https://example.com")!))))
        }
        let response = await handler.resolvePreview(operation)
        #expect(
            try JSONDecoder().decode(RemotePreviewResponse.self, from: response.body).error
                == .denied)
    }
}
