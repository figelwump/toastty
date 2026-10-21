#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import Foundation
import ToasttyAppLogic

/// `TOASTTY_LINUX_SMOKE_SCRIPT` commands for browser annotation mode. They
/// target the active right-panel tab (or the focused panel), which must be a
/// browser. Pointer gestures go through the overlay's gesture handlers
/// (`pointerPressed`/`Dragged`/`Released` with the overlay's live size);
/// the comment is typed into the popover's real `GtkTextView` and saved
/// with its real Add/Save button.
///
///     annotate-mode on|off                # enter / leave annotation mode
///     annotate-click 120 80               # click a point (opens the comment popover)
///     annotate-drag 40 40 300 160         # drag a region
///     annotate-comment Make this bigger   # type into the open comment editor
///     annotate-save                       # Add / Save / Edit button of the open popover
///     annotate-escape                     # Escape (drag → popover → mode)
///     annotate-wait                       # captures/saves/sends settle (10 s)
///     annotate-popover-screenshot out/p.png  # the open popover (not in window screenshots)
///     annotate-send first|<session-id>    # send drafts to an agent session, wait for the result
///     annotate-copy-screenshot out/a.png  # copy the last sent annotated screenshot
///     annotate-expect-pixel 120 80 229 72 77  # RGB at a pixel of that screenshot (±40)
///     annotate-expect-payload Make this bigger  # the last payload contains text
///
/// Summary keys: `annotationMode`, `annotationDrafts`, `annotationComments`
/// (`1:text|2:text`), `annotationPopover` (create/edit/view/none),
/// `annotationPopoverShown`, `annotationModeBar`, `annotationNotice`,
/// `annotationSentTo`, `annotationSentScreenshots`, `annotationCandidates`.
@MainActor
enum BrowserAnnotationAutomation {
    static func install(host: WebPanelHost) {
        AutomationScript.summaryContributors.append { [weak host] app in
            guard let host, let browser = activeBrowser(host: host, app: app), let annotation = browser.annotation else { return [:] }
            var result: [String: String] = [:]
            for (key, value) in browser.automationFacts() where key.hasPrefix("annotation") { result[key] = value }
            result["annotationCandidates"] = annotation.controller.sendCandidates
                .map { $0.blockedReason == nil ? $0.label : "\($0.label) (\($0.blockedReason!))" }
                .joined(separator: "|")
            return result
        }
        let commands: [String: @MainActor (LinuxAppController, String, AutomationScript) -> Void] = [
            "annotate-mode": { app, argument, script in
                guard let annotation = annotation(host: host, app: app, script: script) else { return }
                annotation.controller.setAnnotationModeEnabled(argument != "off")
                waitIdle(annotation)
                script.settleWindows(app)
            },
            "annotate-click": { app, argument, script in
                guard let annotation = annotation(host: host, app: app, script: script) else { return }
                let numbers = argument.split(separator: " ").compactMap { Double($0) }
                guard numbers.count == 2 else { script.reportFailure("annotate-click needs <x> <y>"); return }
                annotation.simulateGesture(from: CGPoint(x: numbers[0], y: numbers[1]), to: CGPoint(x: numbers[0], y: numbers[1]))
                MainLoop.spin(untilMilliseconds: 150)
                script.settleWindows(app)
            },
            "annotate-drag": { app, argument, script in
                guard let annotation = annotation(host: host, app: app, script: script) else { return }
                let numbers = argument.split(separator: " ").compactMap { Double($0) }
                guard numbers.count == 4 else { script.reportFailure("annotate-drag needs <x1> <y1> <x2> <y2>"); return }
                annotation.simulateGesture(from: CGPoint(x: numbers[0], y: numbers[1]), to: CGPoint(x: numbers[2], y: numbers[3]))
                MainLoop.spin(untilMilliseconds: 150)
                script.settleWindows(app)
            },
            "annotate-comment": { app, argument, script in
                guard let annotation = annotation(host: host, app: app, script: script) else { return }
                if annotation.typeComment(argument.replacingOccurrences(of: "\\n", with: "\n")) == false {
                    script.reportFailure("annotate-comment: no comment editor is open")
                }
                MainLoop.spin(untilMilliseconds: 50)
            },
            "annotate-save": { app, _, script in
                guard let annotation = annotation(host: host, app: app, script: script) else { return }
                if annotation.clickPopoverPrimaryButton() == false { script.reportFailure("annotate-save: no enabled popover button") }
                waitIdle(annotation)
                script.settleWindows(app)
            },
            "annotate-escape": { app, _, script in
                guard let annotation = annotation(host: host, app: app, script: script) else { return }
                if annotation.controller.popover != nil {
                    annotation.controller.cancelPopover()
                } else {
                    _ = annotation.controller.escapePressed()
                }
                MainLoop.spin(untilMilliseconds: 50)
                script.settleWindows(app)
            },
            "annotate-popover-screenshot": { app, argument, script in
                guard let annotation = annotation(host: host, app: app, script: script) else { return }
                script.settleWindows(app)
                let url = script.resolvePath(argument)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let error = annotation.writePopoverPNG(to: url.path) {
                    script.reportFailure("annotate-popover-screenshot: \(error)")
                } else {
                    script.logLine("wrote \(url.path)")
                }
            },
            "annotate-wait": { app, _, script in
                guard let annotation = annotation(host: host, app: app, script: script) else { return }
                if waitIdle(annotation) == false { script.reportFailure("annotate-wait: still busy after 10 s") }
                script.settleWindows(app)
            },
            "annotate-send": { app, argument, script in
                guard let annotation = annotation(host: host, app: app, script: script) else { return }
                let candidates = annotation.controller.sendCandidates
                let target = argument == "first" || argument.isEmpty ? candidates.first : candidates.first { $0.sessionID == argument }
                guard let target else {
                    script.reportFailure("annotate-send: no candidate \(argument); candidates=\(candidates.map(\.label))")
                    return
                }
                let previous = annotation.controller.lastSentPayload
                annotation.controller.send(toSessionID: target.sessionID)
                MainLoop.spin(untilMilliseconds: 10_000) { annotation.controller.isSendInFlight == false }
                waitIdle(annotation)
                if annotation.controller.lastSentPayload == nil || annotation.controller.lastSentPayload == previous {
                    script.reportFailure("annotate-send: nothing was sent (notice: \(annotation.lastNoticeMessage ?? "none"))")
                }
                script.settleWindows(app)
            },
            "annotate-copy-screenshot": { app, argument, script in
                guard let annotation = annotation(host: host, app: app, script: script) else { return }
                guard let source = annotation.controller.lastSentScreenshotPaths.first else {
                    script.reportFailure("annotate-copy-screenshot: nothing sent yet"); return
                }
                let destination = script.resolvePath(argument)
                try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: destination)
                do {
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: destination)
                    script.logLine("copied \(source) -> \(destination.path)")
                } catch {
                    script.reportFailure("annotate-copy-screenshot: \(error)")
                }
            },
            "annotate-expect-pixel": { app, argument, script in
                guard let annotation = annotation(host: host, app: app, script: script) else { return }
                let numbers = argument.split(separator: " ").compactMap { Int($0) }
                guard numbers.count == 5 else { script.reportFailure("annotate-expect-pixel needs <x> <y> <r> <g> <b>"); return }
                guard let path = annotation.controller.lastSentScreenshotPaths.first,
                      let png = FileManager.default.contents(atPath: path),
                      let pixel = LinuxAnnotationScreenshotRenderer.pixel(png: png, x: numbers[0], y: numbers[1]) else {
                    script.reportFailure("annotate-expect-pixel: no readable screenshot"); return
                }
                let actual = [Int(pixel.red), Int(pixel.green), Int(pixel.blue)]
                if zip(actual, numbers[2...]).contains(where: { abs($0 - $1) > 40 }) {
                    script.reportFailure("annotate-expect-pixel \(numbers[0]),\(numbers[1]): expected \(Array(numbers[2...])) but was \(actual)")
                } else {
                    script.logLine("pixel \(numbers[0]),\(numbers[1]) = \(actual)")
                }
            },
            "annotate-expect-payload": { app, argument, script in
                guard let annotation = annotation(host: host, app: app, script: script) else { return }
                let payload = annotation.controller.lastSentPayload ?? ""
                if payload.contains(argument) == false {
                    script.reportFailure("annotate-expect-payload: \"\(argument)\" not in payload:\n\(payload)")
                }
            },
        ]
        for (name, handler) in commands { AutomationScript.extensionCommands[name] = handler }
    }

    private static func activeBrowser(host: WebPanelHost, app: LinuxAppController) -> BrowserPanelController? {
        WebPanelAutomation.activeController(host: host, app: app) as? BrowserPanelController
    }

    private static func annotation(host: WebPanelHost, app: LinuxAppController, script: AutomationScript) -> BrowserAnnotationOverlay? {
        guard let browser = activeBrowser(host: host, app: app) else {
            script.reportFailure("annotation: the active web panel is not a browser")
            return nil
        }
        guard let annotation = browser.annotation else {
            script.reportFailure("annotation: not attached (no app-logic layer)")
            return nil
        }
        return annotation
    }

    @discardableResult
    private static func waitIdle(_ annotation: BrowserAnnotationOverlay) -> Bool {
        MainLoop.spin(untilMilliseconds: 10_000) { annotation.controller.isBusy == false }
    }
}
#endif
