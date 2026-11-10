import CGtk
import CoreState
import Foundation
import Testing
@testable import ToasttyLinuxUI

@Suite("Local document bridge")
struct LocalDocumentBridgeTests {
    @Test func decodesEveryEventTheBundlePosts() {
        #expect(LocalDocumentBridgeEvent(json: #"{"type":"bridgeReady"}"#) == .bridgeReady)
        #expect(LocalDocumentBridgeEvent(json: #"{"type":"enterEdit"}"#) == .enterEdit)
        #expect(LocalDocumentBridgeEvent(json: #"{"type":"copyFullPath"}"#) == .copyFullPath)
        #expect(LocalDocumentBridgeEvent(json: #"{"type":"openInDefaultApp"}"#) == .openInDefaultApp)
        #expect(LocalDocumentBridgeEvent(json: #"{"type":"searchControllerReady"}"#) == .searchControllerReady)
        #expect(LocalDocumentBridgeEvent(json: #"{"type":"draftDidChange","content":"x","baseContentRevision":3}"#)
            == .draftDidChange(content: "x", baseContentRevision: 3))
        // JSC serializes integral numbers either way.
        #expect(LocalDocumentBridgeEvent(json: #"{"type":"save","baseContentRevision":4.0}"#) == .save(baseContentRevision: 4))
        #expect(LocalDocumentBridgeEvent(json: #"{"type":"cancelEdit","baseContentRevision":2}"#) == .cancelEdit(baseContentRevision: 2))
        #expect(LocalDocumentBridgeEvent(json: #"{"type":"overwriteAfterConflict","baseContentRevision":5}"#) == .overwriteAfterConflict(baseContentRevision: 5))
        #expect(LocalDocumentBridgeEvent(json: #"{"type":"renderReady","displayName":"a.md","contentRevision":1,"isEditing":false}"#)
            == .renderReady(displayName: "a.md", contentRevision: 1, isEditing: false))
        #expect(LocalDocumentBridgeEvent(json: #"{"type":"consoleMessage","level":"warn","message":"m"}"#) == .consoleMessage(level: "warn", message: "m"))
        #expect(LocalDocumentBridgeEvent(json: #"{"type":"javascriptError","message":"e","source":null,"line":3,"column":null,"stack":null}"#)
            == .javascriptError(message: "e", source: nil, line: 3, column: nil, stack: nil))
    }

    @Test func rejectsMalformedMessages() {
        #expect(LocalDocumentBridgeEvent(json: "not json") == nil)
        #expect(LocalDocumentBridgeEvent(json: #"{"type":"save"}"#) == nil)
        #expect(LocalDocumentBridgeEvent(json: #"{"type":"draftDidChange","baseContentRevision":1}"#) == nil)
        #expect(LocalDocumentBridgeEvent(json: #"{"type":"consoleMessage","level":"debug"}"#) == nil)
        #expect(LocalDocumentBridgeEvent(json: #"{"type":"somethingElse"}"#) == nil)
    }

    @Test func bootstrapMatchesContractVersion7Fields() throws {
        let snapshot = LocalDocumentSnapshot(
            filePath: "/repo/config.yaml", displayName: "config.yaml", format: .yaml, content: "a: 1\n",
            diskRevision: LocalDocumentDiskRevision(fileNumber: 1, modificationDate: nil, size: 5)
        )
        let session = LocalDocumentEditingSession(document: snapshot)
        let bootstrap = LocalDocumentPanelBootstrap(session: session, theme: .dark, textScale: 1.2)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bootstrap)) as? [String: Any]
        let keys = Set(object?.keys.map { $0 } ?? [])
        let expected: Set<String> = [
            "contractVersion", "filePath", "displayName", "format", "syntaxLanguage", "formatLabel", "shouldHighlight",
            "highlightState", "content", "contentRevision", "isEditing", "isDirty", "hasExternalConflict", "isSaving",
            "theme", "textScale", "editorEngine",
        ]
        #expect(keys.subtracting(["saveErrorMessage"]) == expected)
        #expect(object?["contractVersion"] as? Int == 7)
        #expect(object?["format"] as? String == "yaml")
        #expect(object?["syntaxLanguage"] as? String == "yaml")
        #expect(object?["highlightState"] as? String == "enabled")
        #expect(object?["theme"] as? String == "dark")
        #expect(object?["editorEngine"] as? String == "codemirror")
        #expect(bootstrap.deliveryJavaScript()?.contains("bridge.receiveBootstrap({") == true)
    }

    @Test func highlightStateFollowsMacOSRules() {
        let markdown = LocalDocumentClassifier.classification(format: .markdown, filePath: "/a/README.md")
        #expect(LocalDocumentPanelBootstrap.highlightState(classification: markdown, content: "x", hasDiskRevision: false) == .unavailable)
        #expect(LocalDocumentPanelBootstrap.highlightState(classification: markdown, content: "x", hasDiskRevision: true) == .enabled)
        let big = String(repeating: "x", count: LocalDocumentPanelBootstrap.syntaxHighlightThresholdBytes + 1)
        #expect(LocalDocumentPanelBootstrap.highlightState(classification: markdown, content: big, hasDiskRevision: true) == .disabledForLargeFile)
    }

    @Test func searchScriptsCarryCommands() {
        #expect(LocalDocumentBridgeScript.search(.setQuery("a\"b")).contains(#"{"query":"a\"b","type":"setQuery"}"#))
        #expect(LocalDocumentBridgeScript.search(.findNext("q")).contains(#""type":"next""#))
        #expect(LocalDocumentBridgeScript.search(.findPrevious("q")).contains(#""type":"previous""#))
        #expect(LocalDocumentBridgeScript.search(.clear).contains(#"{"type":"clear"}"#))
        let result = try? JSONDecoder().decode(LocalDocumentSearchResult.self, from: Data(#"{"query":"q","matchCount":2,"activeMatchIndex":null,"matchFound":true}"#.utf8))
        #expect(result?.matchCount == 2 && result?.activeMatchIndex == nil)
    }
}

@Suite("Local document editing session")
struct LocalDocumentEditingSessionTests {
    func snapshot(_ content: String, path: String? = "/tmp/doc.md") -> LocalDocumentSnapshot {
        LocalDocumentSnapshot(filePath: path, displayName: "doc.md", format: .markdown, content: content,
                              diskRevision: LocalDocumentDiskRevision(fileNumber: 1, modificationDate: nil, size: UInt64(content.utf8.count)))
    }

    @Test func editSaveRoundTrip() throws {
        var session = LocalDocumentEditingSession(document: snapshot("one"))
        #expect(session.canEnterEdit && session.canSave == false)
        let r1 = session.beginEditing()
        #expect(r1)
        let r2 = session.updateDraft("two", baseContentRevision: session.contentRevision)
        #expect(r2)
        #expect(session.isDirty && session.needsCloseConfirmation)
        let pending3 = session.beginSave(baseContentRevision: session.contentRevision, allowConflictOverwrite: false)
        let request = try #require(pending3)
        #expect(request.content == "two" && session.isSaving)
        let r4 = session.settleSave(with: snapshot("two"), expectedContent: "two", baseContentRevision: request.baseContentRevision)
        #expect(r4)
        #expect(session.isEditing == false && session.isDirty == false && session.contentRevision == 2)
    }

    @Test func staleRevisionsAreRejected() {
        var session = LocalDocumentEditingSession(document: snapshot("one"))
        session.beginEditing()
        let r5 = session.updateDraft("x", baseContentRevision: 99)
        #expect(r5 == false)
        #expect(session.cancelEditing(baseContentRevision: 99) == false)
        let r6 = session.beginSave(baseContentRevision: 99, allowConflictOverwrite: false)
        #expect(r6 == nil)
    }

    @Test func externalChangeWhileDirtyIsAConflict() {
        var session = LocalDocumentEditingSession(document: snapshot("one"))
        session.beginEditing()
        session.updateDraft("mine", baseContentRevision: session.contentRevision)
        let r7 = session.applyReload(snapshot("theirs"))
        #expect(r7)
        #expect(session.hasExternalConflict && session.draftContent == "mine" && session.loadedContent == "theirs")
        #expect(session.canSave == false)
        let r8 = session.beginSave(baseContentRevision: session.contentRevision, allowConflictOverwrite: false)
        #expect(r8 == nil)
        let r9 = session.beginSave(baseContentRevision: session.contentRevision, allowConflictOverwrite: true)
        #expect(r9 != nil)
    }

    @Test func cleanReloadTakesNewBaseline() {
        var session = LocalDocumentEditingSession(document: snapshot("one"))
        let r10 = session.applyReload(snapshot("two"))
        #expect(r10)
        #expect(session.visibleContent == "two" && session.contentRevision == 2 && session.hasExternalConflict == false)
        session.beginEditing()
        session.isSaving = true
        let r11 = session.applyReload(snapshot("three"))
        #expect(r11 == false)
    }

    @Test func noOpSaveLeavesEditMode() {
        var session = LocalDocumentEditingSession(document: snapshot("one"))
        session.beginEditing()
        let r12 = session.finishNoOpSave(baseContentRevision: session.contentRevision)
        #expect(r12)
        #expect(session.isEditing == false)
    }

    @Test func loadingMissingFileExplainsWhy() {
        let missing = LocalDocumentSnapshot.load(filePath: "/nonexistent/\(UUID().uuidString).md", displayName: "x.md", format: .markdown)
        #expect(missing.diskRevision == nil)
        #expect(missing.content.hasPrefix("Toastty could not load this document."))
        #expect(LocalDocumentEditingSession(document: missing).canEnterEdit)
    }
}

@Suite("Scratchpad bridge")
struct ScratchpadBridgeTests {
    @Test func bootstrapFromStoredDocument() throws {
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = #"{"documentID":"\#(id.uuidString)","revision":3,"title":"Plan","contentType":"html","content":"<p>hi</p>","createdAt":1,"updatedAt":2,"sessionLink":null}"#
        try json.write(to: directory.appendingPathComponent("\(id.uuidString).json"), atomically: true, encoding: .utf8)
        let record = try #require(try ScratchpadDocumentRecord.loadFromDisk(documentID: id, directory: directory))
        #expect(record.revision == 3 && record.title == "Plan" && record.hasSessionLink == false)

        let state = WebPanelState(definition: .scratchpad, scratchpad: ScratchpadState(documentID: id, revision: 3))
        let bootstrap = ScratchpadPanelBootstrap.make(webState: state, theme: .light) { try ScratchpadDocumentRecord.loadFromDisk(documentID: $0, directory: directory) }
        #expect(bootstrap.contentHTML == "<p>hi</p>" && bootstrap.displayName == "Plan" && bootstrap.missingDocument == false)
        #expect(bootstrap.deliveryJavaScript()?.contains("window.ToasttyScratchpadPanel") == true)

        let missing = ScratchpadPanelBootstrap.make(webState: WebPanelState(definition: .scratchpad, scratchpad: ScratchpadState(documentID: UUID(), revision: 1)), theme: .dark) { _ in nil }
        #expect(missing.missingDocument && missing.contentHTML == nil)
        #expect(try ScratchpadDocumentRecord.loadFromDisk(documentID: UUID(), directory: directory) == nil)
    }

    @Test func externalLinksMustBeWebURLs() {
        #expect(ScratchpadBridgeScript.externalLinkURL(fromMessage: "https://example.com/a") == URL(string: "https://example.com/a"))
        #expect(ScratchpadBridgeScript.externalLinkURL(fromMessage: "javascript:alert(1)") == nil)
        #expect(ScratchpadBridgeScript.externalLinkURL(fromMessage: "file:///etc/passwd") == nil)
        #expect(ScratchpadBridgeScript.externalLinkURL(fromMessage: "https://") == nil)
        #expect(ScratchpadBridgeScript.externalLinkURL(fromMessage: nil) == nil)
    }
}

@Suite("Desktop integration")
struct DesktopIntegrationTests {
    @Test func notificationTargetsRoundTrip() {
        let encoded = DesktopNotifications.encodeTarget(identifier: "n-1", userInfo: ["workspaceID": "W", "panelID": "P"])
        let decoded = DesktopNotifications.decodeTarget(encoded)
        #expect(decoded?.identifier == "n-1" && decoded?.userInfo == ["workspaceID": "W", "panelID": "P"])
        #expect(DesktopNotifications.decodeTarget("{}") == nil)
    }

    @MainActor @Test func notificationRouteFocusesPanel() throws {
        var state = AppState.bootstrap()
        let window = try #require(state.windows.first)
        let workspaceID = try #require(window.workspaceIDs.first)
        let panelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)
        let actions = NotificationRoute.actions(userInfo: ["workspaceID": workspaceID.uuidString, "panelID": panelID.uuidString], state: state)
        #expect(actions.count == 4)
        #expect(NotificationRoute.actions(userInfo: ["workspaceID": UUID().uuidString], state: state).isEmpty)
    }

    @MainActor @Test func launcherEntryPayloadShape() {
        let payload = LauncherBadge.updateParameters(count: 3)
        let text = String(cString: g_variant_print(payload, 1))
        #expect(text.contains("application://com.GiantThings.toastty.desktop"))
        #expect(text.contains("'count': <int64 3>"))
        #expect(text.contains("'count-visible': <true>"))
        g_variant_unref(g_variant_ref_sink(payload))
    }
}

@Suite("WebKit renderer selection")
struct WebKitRendererSelectionTests {
    @Test func forcesDMABufUnlessTheUserChose() {
        #expect(WebKitRendererSelection.shouldForceDMABufRenderer(environment: [:]))
        #expect(WebKitRendererSelection.shouldForceDMABufRenderer(environment: ["WEBKIT_FORCE_DMABUF_RENDERER": "0"]) == false)
        #expect(WebKitRendererSelection.shouldForceDMABufRenderer(environment: ["WEBKIT_DISABLE_DMABUF_RENDERER": "1"]) == false)
    }

    @Test func setsTheVariableOnlyAroundContextCreation() {
        let seen = WebKitRendererSelection.withDMABufRenderer(environment: [:]) {
            ProcessInfo.processInfo.environment[WebKitRendererSelection.forceVariable]
        }
        #expect(seen == "1")
        #expect(ProcessInfo.processInfo.environment[WebKitRendererSelection.forceVariable] == nil)
    }
}
