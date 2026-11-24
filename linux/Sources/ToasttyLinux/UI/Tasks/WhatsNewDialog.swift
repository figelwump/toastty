#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CGtkShim
import CoreState
import Foundation
@testable import ToasttyAppLogic

/// The What's new question at the first launch (macOS `WhatsNewSheet`):
/// tasks, quick entry with "Use Alt+Shift+T in every app", the
/// coordinator, notes for a user who updates, and Not Now / Start
/// Coordinator. The shared `CoordinatorStartOffer` decides when it shows
/// and keeps the answer; the quick entry key waits for it
/// (`QuickEntryShortcutAnswer`).
@MainActor
enum WhatsNewDialog {
    static func presenter(app: LinuxAppController, ui: TasksUI) -> CoordinatorStartOffer.Presenter {
        { [weak app, weak ui] windowID, answer in
            guard let app, let ui, let window = app.windows[windowID]?.window,
                  adw_application_window_get_visible_dialog(cast(window)) == nil else { return nil }
            let facts = Self.facts(ui: ui)
            let dialog = widget(adw_dialog_new()!)
            adw_dialog_set_title(cast(dialog), WhatsNewWords.title)
            adw_dialog_set_content_width(cast(dialog), 520)
            Gtk.setName(dialog, "coordinator.start-offer")
            var answered = false
            var allowsDefault = facts.allowsDefaultShortcut
            @MainActor func finish(_ choice: CoordinatorStartOffer.Answer?) {
                guard answered == false else { return }
                answered = true
                if case .askForDefault = facts.shortcut, choice != nil {
                    QuickEntryShortcutAnswer.save(allowsDefault, in: ui.startOfferDefaults)
                }
                adw_dialog_close(cast(dialog))
                answer(choice)
            }

            let content = Gtk.vbox(spacing: 14, classes: ["whats-new"])
            Gtk.margins(content, top: 8, bottom: 20, start: 24, end: 24)
            Gtk.append(content, Gtk.image(LinuxAppController.applicationID, pixelSize: 48))
            Gtk.append(content, Self.text(WhatsNewWords.title, ["title-2"]))
            Gtk.append(content, Self.text(WhatsNewWords.subtitle, ["dim-label"]))

            Gtk.append(content, Self.section(WhatsNewWords.tasksTitle, WhatsNewWords.tasks))
            let quickEntry = Self.section(WhatsNewWords.quickEntryTitle, WhatsNewWords.quickEntry)
            switch facts.shortcut {
            case .askForDefault(let label):
                let box = gtk_check_button_new_with_label(WhatsNewWords.useEverywhere(label))!
                gtk_check_button_set_active(cast(box), allowsDefault.gboolean)
                Gtk.setName(box, "whats-new.shortcut")
                Signal.connect(box, "toggled") { allowsDefault = gtk_check_button_get_active(cast(box)).bool }
                Gtk.append(quickEntry, box)
                Gtk.append(quickEntry, Self.text(WhatsNewWords.useEverywhereNote, ["dim-label", "caption"]))
            case .written(let label):
                Gtk.append(quickEntry, Self.text(label == nil ? WhatsNewWords.shortcutOffNote : WhatsNewWords.writtenShortcutNote, ["dim-label", "caption"]))
            }
            let changeKey = Gtk.button(WhatsNewWords.changeKey, classes: ["flat", "whats-new-link"])
            gtk_widget_set_halign(changeKey, GTK_ALIGN_START)
            Gtk.setName(changeKey, "whats-new.change-key")
            Signal.connect(changeKey, "clicked") { [weak app] in
                _ = app?.selectedWindowController()?.perform("app.config.manage")
            }
            Gtk.append(quickEntry, changeKey)
            Gtk.append(content, quickEntry)

            let coordinator = Self.section(WhatsNewWords.coordinatorTitle, WhatsNewWords.coordinator)
            Gtk.append(coordinator, Self.text(WhatsNewWords.startLater, ["dim-label", "caption"]))
            Gtk.append(content, coordinator)

            let notes = Gtk.vbox(spacing: 6)
            Gtk.append(notes, Self.text(WhatsNewWords.sidebar, ["dim-label", "caption"]))
            if facts.hasTaskSpacesFromBefore {
                Gtk.append(notes, Self.text(WhatsNewWords.taskSpacesFromBefore, ["dim-label", "caption"]))
            }
            if facts.hasPhoneWithTaskActions {
                Gtk.append(notes, Self.text(WhatsNewWords.phone, ["dim-label", "caption"]))
            }
            Gtk.append(content, notes)

            let buttons = Gtk.hbox(spacing: 8)
            let read = Gtk.button(WhatsNewWords.readAboutTasks + " ↗", classes: ["flat"])
            Signal.connect(read, "clicked") { _ = DesktopLauncher.open(WhatsNewWords.tasksDocumentURL, parent: window) }
            Gtk.append(buttons, read)
            let spacer = Gtk.hbox()
            gtk_widget_set_hexpand(spacer, 1)
            Gtk.append(buttons, spacer)
            let notNow = Gtk.button(WhatsNewWords.notNow)
            Gtk.setName(notNow, "whats-new.not-now")
            Signal.connect(notNow, "clicked") { finish(.notNow) }
            Gtk.append(buttons, notNow)
            let start = Gtk.button(WhatsNewWords.start, classes: ["suggested-action"])
            Gtk.setName(start, "whats-new.start")
            Signal.connect(start, "clicked") { finish(.start) }
            Gtk.append(buttons, start)
            Gtk.append(content, buttons)

            let toolbar = adw_toolbar_view_new()!
            adw_toolbar_view_add_top_bar(cast(toolbar), adw_header_bar_new())
            let scroller = gtk_scrolled_window_new()!
            gtk_scrolled_window_set_policy(cast(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
            gtk_scrolled_window_set_propagate_natural_height(cast(scroller), 1)
            gtk_scrolled_window_set_child(cast(scroller), content)
            adw_toolbar_view_set_content(cast(toolbar), scroller)
            adw_dialog_set_child(cast(dialog), toolbar)
            adw_dialog_set_default_widget(cast(dialog), start)
            // Escape is Not Now, without an answer about the key.
            Signal.connect(dialog, "closed") {
                guard answered == false else { return }
                answered = true
                answer(nil)
            }
            adw_dialog_present(cast(dialog), window)
            return {
                guard answered == false else { return }
                answered = true
                adw_dialog_close(cast(dialog))
            }
        }
    }

    static func facts(ui: TasksUI) -> WhatsNewFacts {
        let quickEntry = (try? TasksConfigFile.load())?.quickEntry ?? TasksConfig.QuickEntry()
        return WhatsNewFacts(
            shortcut: quickEntry.isShortcutSet
                ? .written(label: quickEntry.shortcut?.symbolLabel)
                : .askForDefault(label: QuickEntryShortcut.default.symbolLabel),
            allowsDefaultShortcut: QuickEntryShortcutAnswer.saved(in: ui.startOfferDefaults) ?? true,
            hasTaskSpacesFromBefore: ui.board.items().contains { $0.record == nil },
            hasPhoneWithTaskActions: ui.logic.remoteAccessService?.devices.contains(where: \.canActOnTasks) ?? false
        )
    }

    private static func section(_ title: String, _ body: String) -> WidgetPtr {
        let box = Gtk.vbox(spacing: 4, classes: ["whats-new-section"])
        Gtk.append(box, text(title, ["heading"]))
        Gtk.append(box, text(body, []))
        return box
    }

    private static func text(_ string: String, _ classes: [String]) -> WidgetPtr {
        let label = Gtk.label(string, classes: classes, ellipsize: false)
        gtk_label_set_wrap(cast(label), 1)
        return label
    }
}

extension TasksUI {
    /// The What's new question and the quick entry key's wait for it, as
    /// macOS connects them in `ToasttyApp.init`.
    func installStartOffer(app: LinuxAppController) {
        guard let controller = tasks.coordinatorController else { return }
        // An automation run asks nothing, as on macOS. A test of the
        // question sets TOASTTY_LINUX_TEST_START_OFFER=1 for throwaway
        // preferences.
        let defaults = tasks.userDefaults
            ?? (ProcessInfo.processInfo.environment["TOASTTY_LINUX_TEST_START_OFFER"] == "1"
                ? UserDefaults(suiteName: "toastty.test-start-offer.\(ProcessInfo.processInfo.processIdentifier)") : nil)
        startOfferDefaults = defaults
        let offer = CoordinatorStartOffer(
            controller: controller,
            store: store,
            defaults: defaults,
            coordinatorDirectoryURL: logic.runtimePaths.coordinatorDirectoryURL,
            present: WhatsNewDialog.presenter(app: app, ui: self)
        )
        controller.startOffer = offer
        QuickEntryShortcutAnswer.connect(tasks.quickEntry, to: offer, defaults: defaults) { [weak app, weak self] in
            guard let app, let self, let window = app.selectedWindowController() else { return }
            self.tasks.quickEntry.presentLaunchMessageIfNeeded(windowID: window.windowID) { _, message in
                window.toast(message)
                return true
            }
        }
    }

    /// A window got the keyboard: ask the question there if it waits.
    func offerStartIfNeeded(windowID: UUID) {
        guard let offer = tasks.coordinatorController?.startOffer else { return }
        ToasttyLog.debug("Checked the What's new question", category: .tasks, metadata: [
            "should_offer": String(offer.shouldOffer), "is_showing": String(offer.isShowing),
        ])
        offer.offerIfNeeded(windowID: windowID)
    }
}
#endif
