import CGtk
import CoreState
import Foundation

/// `TOASTTY_LINUX_SMOKE_SCRIPT` commands for web panels:
///
///     browser-open file:///tmp/page.html     # new right-panel browser tab
///     doc-open /path/README.md               # local-document panel
///     scratchpad-open /path/content.html Title  # store a Scratchpad document + open it
///     web-wait ready                         # active right-panel tab loaded / bridge ready (15 s)
///     web-wait text Hello world              # page text contains (docs: rendered text; Scratchpad: srcdoc)
///     web-eval <js>                          # logs the JSON result
///     web-expect <js> => <json>              # fails unless the result matches
///     web-command local-document.edit        # panel command on the active tab
///     web-snapshot artifacts/x.png           # WebKit snapshot of the active tab
///     doc-search Markdown                    # local-document find query
///     file-write /tmp/x.md # Title\nBody     # write a file (`\n` escapes)
///
/// Annotation mode commands (`annotate-*`) are in `BrowserAnnotationAutomation`.
///
/// Summary keys (`expect`): `webPanels`, `webKind`, `webURI`, `webTitle`,
/// `webBridgeReady`, `webLoading`, `webEditing`, `webDirty`, `webSearchMatches`.
@MainActor
enum WebPanelAutomation {
    static func install(host: WebPanelHost) {
        AutomationScript.summaryContributors.append { [weak host] app in
            guard let host else { return [:] }
            return summary(host: host, app: app)
        }
        let commands: [String: @MainActor (LinuxAppController, String, AutomationScript) -> Void] = [
            "browser-open": { app, argument, script in
                guard let workspaceID = workspaceID(app) else { script.reportFailure("browser-open: no workspace"); return }
                host.openURLInRightPanelBrowser(argument, workspaceID: workspaceID)
                script.settleWindows(app)
            },
            "doc-open": { app, argument, script in
                guard let windowID = app.selectedWindowController()?.windowID else { script.reportFailure("doc-open: no window"); return }
                let path = script.resolvePath(argument).path
                if host.openLocalDocument(path: path, windowID: windowID) == false { script.reportFailure("doc-open \(path) failed") }
                script.settleWindows(app)
            },
            "scratchpad-open": { app, argument, script in
                let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
                guard let first = parts.first, let workspaceID = workspaceID(app) else { script.reportFailure("scratchpad-open: bad argument"); return }
                do {
                    let html = try String(contentsOf: script.resolvePath(first), encoding: .utf8)
                    let documentID = try writeScratchpadDocument(html: html, title: parts.count > 1 ? parts[1] : nil)
                    app.store.send(.createWebPanel(
                        workspaceID: workspaceID,
                        panel: WebPanelState(definition: .scratchpad, title: parts.count > 1 ? parts[1] : nil,
                                             scratchpad: ScratchpadState(documentID: documentID, revision: 1)),
                        placement: .rightPanel
                    ))
                    script.settleWindows(app)
                } catch {
                    script.reportFailure("scratchpad-open: \(error)")
                }
            },
            "web-wait": { app, argument, script in
                let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
                let deadline = Date().addingTimeInterval(20)
                var satisfied = false
                while Date() < deadline {
                    if let controller = activeController(host: host, app: app), condition(parts, controller: controller) {
                        satisfied = true
                        break
                    }
                    MainLoop.spin(untilMilliseconds: 100)
                }
                if satisfied == false {
                    let facts = activeController(host: host, app: app)?.automationFacts() ?? [:]
                    script.reportFailure("web-wait \(argument) timed out; facts=\(facts) diagnostics=\(activeController(host: host, app: app)?.diagnostics.suffix(5) ?? [])")
                }
                script.settleWindows(app)
            },
            "web-eval": { app, argument, script in
                guard let controller = activeController(host: host, app: app) else { script.reportFailure("web-eval: no web panel"); return }
                script.logLine("web-eval => \(evaluateSync(controller, argument))")
            },
            "web-expect": { app, argument, script in
                guard let controller = activeController(host: host, app: app) else { script.reportFailure("web-expect: no web panel"); return }
                // The last " => " separates the script from the expected JSON.
                guard let separator = argument.range(of: " => ", options: .backwards) else {
                    script.reportFailure("web-expect needs '<js> => <json>'"); return
                }
                let js = String(argument[..<separator.lowerBound])
                let expected = String(argument[separator.upperBound...])
                let result = evaluateSync(controller, js)
                if result != expected { script.reportFailure("web-expect \(js): expected \(expected) but was \(result)") }
            },
            "web-command": { app, argument, script in
                guard let controller = activeController(host: host, app: app) else { script.reportFailure("web-command: no web panel"); return }
                if controller.perform(commandID: argument) == false { script.reportFailure("web-command \(argument) not handled") }
                MainLoop.spin(untilMilliseconds: 50)
            },
            "doc-search": { app, argument, script in
                guard let document = activeController(host: host, app: app) as? LocalDocumentPanelController else {
                    script.reportFailure("doc-search: active tab is not a local document"); return
                }
                document.setSearchQuery(argument)
                MainLoop.spin(untilMilliseconds: 300)
            },
            "file-write": { _, argument, script in
                // file-write <path> <text with \n escapes>
                let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { script.reportFailure("file-write needs <path> <text>"); return }
                let text = parts[1].replacingOccurrences(of: "\\n", with: "\n")
                do { try text.write(to: script.resolvePath(parts[0]), atomically: true, encoding: .utf8) } catch {
                    script.reportFailure("file-write: \(error)")
                }
            },
            "web-snapshot": { app, argument, script in
                guard let controller = activeController(host: host, app: app) else { script.reportFailure("web-snapshot: no web panel"); return }
                var png: Data?
                var done = false
                controller.snapshotPNG { data in png = data; done = true }
                MainLoop.spin(untilMilliseconds: 5000) { done }
                let url = script.resolvePath(argument)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard let png, (try? png.write(to: url)) != nil else { script.reportFailure("web-snapshot \(argument) failed"); return }
                script.logLine("wrote \(url.path)")
            },
        ]
        for (name, handler) in commands { AutomationScript.extensionCommands[name] = handler }
        #if TOASTTY_LINUX_APP_LOGIC
        BrowserAnnotationAutomation.install(host: host)
        #endif
    }

    private static func workspaceID(_ app: LinuxAppController) -> UUID? {
        guard let window = app.selectedWindowController() else { return nil }
        return app.store.state.workspaceSelection(in: window.windowID)?.workspaceID
    }

    static func activeController(host: WebPanelHost, app: LinuxAppController) -> WebPanelController? {
        guard let window = app.selectedWindowController(),
              let selection = app.store.state.workspaceSelection(in: window.windowID) else { return nil }
        if let panelID = selection.workspace.rightAuxPanel.activePanelID, let controller = host.controller(for: panelID) {
            return controller
        }
        if let focused = selection.workspace.focusedPanelID { return host.controller(for: focused) }
        return nil
    }

    private static func condition(_ parts: [String], controller: WebPanelController) -> Bool {
        switch parts.first {
        case "ready":
            switch controller {
            case let browser as BrowserPanelController: return browser.isLoading == false && browser.currentURI != nil
            case let document as LocalDocumentPanelController:
                return document.isBridgeReady && document.lastRenderedRevision == document.session?.contentRevision
            case let scratchpad as ScratchpadPanelController:
                return scratchpad.isBridgeReady && scratchpad.renderedRevision == scratchpad.currentBootstrap?.revision
            default: return true
            }
        case "text":
            let needle = parts.count > 1 ? parts[1] : ""
            let quoted = (try? JSONSerialization.data(withJSONObject: [needle])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
            let js = """
            (() => {
              const needle = \(quoted);
              if ((document.body?.innerText ?? "").includes(needle)) return true;
              return Array.from(document.querySelectorAll("iframe")).some((f) => (f.srcdoc ?? "").includes(needle));
            })()
            """
            return evaluateSync(controller, js) == "true"
        default:
            return false
        }
    }

    static func evaluateSync(_ controller: WebPanelController, _ script: String) -> String {
        var output = "<timeout>"
        var done = false
        controller.evaluate(script) { result in
            switch result {
            case .success(let json): output = json ?? "null"
            case .failure(let error): output = "error: \(error)"
            }
            done = true
        }
        MainLoop.spin(untilMilliseconds: 5000) { done }
        return output
    }

    /// Writes a document in `ScratchpadDocumentStore`'s on-disk format
    /// (JSONEncoder defaults) to the runtime's Scratchpad directory.
    static func writeScratchpadDocument(html: String, title: String?) throws -> UUID {
        struct Document: Encodable {
            let documentID: UUID
            let revision: Int
            let title: String?
            let contentType = "html"
            let content: String
            let createdAt: Date
            let updatedAt: Date
        }
        let id = UUID()
        let directory = ToasttyRuntimePaths.resolve(environment: ProcessInfo.processInfo.environment).scratchpadDocumentsDirectoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let data = try JSONEncoder().encode(Document(documentID: id, revision: 1, title: title, content: html, createdAt: now, updatedAt: now))
        try data.write(to: directory.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
        return id
    }

    static func summary(host: WebPanelHost, app: LinuxAppController) -> [String: String] {
        var result = ["webPanels": "\(host.controllers.count)"]
        guard let controller = activeController(host: host, app: app) else { return result }
        let facts = controller.automationFacts()
        result["webKind"] = facts["kind"] ?? ""
        result["webURI"] = controller.currentURI ?? ""
        result["webTitle"] = facts["title"] ?? facts["displayName"] ?? ""
        result["webLoading"] = "\(controller.isLoading)"
        result["webBridgeReady"] = facts["bridgeReady"] ?? ""
        result["webEditing"] = facts["isEditing"] ?? ""
        result["webDirty"] = facts["isDirty"] ?? ""
        result["webSearchMatches"] = facts["searchMatches"] ?? ""
        result["webZoom"] = facts["zoom"] ?? ""
        return result
    }
}
