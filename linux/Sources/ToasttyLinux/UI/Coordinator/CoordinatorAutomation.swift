#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CGtkShim
import CoreState
import Foundation
@testable import ToasttyAppLogic

extension LinuxAppController {
    /// Script commands for the coordinator UI (Broadway tests):
    ///
    ///     coordinator type Hello_there     # type into the visible chat's field (`_` = space)
    ///     coordinator send                 # Return in that field
    ///     coordinator queue                # Ctrl+Return in that field
    ///     coordinator focus-dock           # give the dock's field the keyboard
    ///     expect coordinatorDock=shown coordinatorCover=chat coordinatorIntro=true
    func installCoordinatorAutomation(ui: TasksUI) {
        AutomationScript.extensionCommands["coordinator"] = { [weak ui] app, argument, script in
            guard let ui, let window = app.selectedWindowController(),
                  let feature = ui.feature(windowID: window.windowID) else {
                script.reportFailure("coordinator: no window")
                return
            }
            let coordinatorUI = feature.coordinatorUI
            let chat = coordinatorUI.visibleChat
            let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
            switch parts.first ?? "" {
            case "type":
                guard let chat else { script.reportFailure("coordinator type: no chat on screen"); return }
                let text = (parts.count > 1 ? parts[1] : "").replacingOccurrences(of: "_", with: " ")
                chat.composer.automationType(text)
            case "send", "queue":
                guard let chat, let model = ui.tasks.coordinatorController?.chat else {
                    script.reportFailure("coordinator send: no chat on screen")
                    return
                }
                guard model.canSend else { script.reportFailure("coordinator send: nothing to send"); return }
                model.send(queueing: parts[0] == "queue")
                _ = chat
            case "focus-dock":
                _ = ui.tasks.coordinatorController?.focusDockComposer(in: window.windowID)
            default:
                script.reportFailure("coordinator: unknown \(argument)")
            }
        }
        AutomationScript.summaryContributors.append { [weak ui] app in
            guard let ui, let window = app.selectedWindowController(),
                  let feature = ui.feature(windowID: window.windowID) else { return [:] }
            return feature.coordinatorUI.automationSummary
        }
    }
}

extension CoordinatorWindowUI {
    /// The chat on screen: the dock's, else the full view's.
    var visibleChat: CoordinatorChatView? {
        if gtk_widget_get_mapped(dockChat.root).bool { return dockChat }
        if gtk_widget_get_mapped(panelChat.root).bool { return panelChat }
        return nil
    }

    var automationSummary: [String: String] {
        let model = automationController?.chat
        var summary: [String: String] = [
            "coordinatorDock": gtk_widget_get_mapped(dockChat.root).bool ? "shown" : "hidden",
            "coordinatorCover": gtk_widget_get_mapped(panelChat.root).bool ? "chat" : (automationController?.location == nil ? "none" : "terminal"),
            "coordinatorIntro": String(model?.showsIntroduction ?? false),
            "coordinatorNotice": model?.notice.map(CoordinatorChatPresentation.text(for:)).map { String($0.prefix(40)) } ?? "",
            "coordinatorQueued": String(model?.presentation.sendItems.count ?? 0),
            "coordinatorTranscript": String((visibleChat?.automationTranscriptKeys.count) ?? 0),
            "coordinatorComposer": visibleChat?.automationComposerText ?? "",
            "coordinatorComposerEmpty": String((visibleChat?.automationComposerText ?? "").isEmpty),
            "coordinatorRunning": String(automationController?.location != nil),
        ]
        summary["coordinatorDockShortcut"] = dockShortcutTitle
        return summary
    }
}

extension CoordinatorComposer {
    /// Types into the field as the keyboard would.
    func automationType(_ text: String) {
        gtk_widget_grab_focus(textView)
        var end = GtkTextIter()
        let buffer = OpaquePointer(gtk_text_view_get_buffer(cast(textView))!)
        gtk_text_buffer_get_end_iter(cast(buffer), &end)
        gtk_text_buffer_insert(cast(buffer), &end, text, -1)
    }
}
#endif
