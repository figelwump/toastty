#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CGtkShim
@testable import ConversationUI
import Foundation
import RemoteProtocol
@testable import ToasttyAppLogic

/// A live structured question owns its answer controls for the life of the
/// card. Edits can change the submit button's sensitivity or show an Other
/// field without replacing the widget that currently has keyboard focus.
@MainActor
final class InteractionCard {
    let root: WidgetPtr
    let id: RemotePendingInteraction.ID
    private let status: WidgetPtr
    private let submitButton: WidgetPtr
    private let edit: (ToasttyInteractionAnswerEdit) -> Void
    private var isSyncing = false

    private struct QuestionControls {
        let question: RemoteInteractionQuestion
        let options: [WidgetPtr]
        let other: WidgetPtr
        let entry: WidgetPtr
    }
    private var controls: [QuestionControls] = []

    init(
        presentation: ToasttyInteractionPresentation,
        answer: ToasttyInteractionAnswerState,
        edit: @escaping (ToasttyInteractionAnswerEdit) -> Void,
        submit: @escaping () -> Void,
        showTerminal: @escaping () -> Void
    ) {
        id = presentation.interaction.id
        self.edit = edit
        root = Self.shell(presentation.interaction)
        status = Gtk.label("", classes: ["interaction-status"], ellipsize: false)
        gtk_label_set_wrap(cast(status), 1)
        gtk_widget_set_hexpand(status, 1)
        submitButton = Gtk.button("Submit answer", classes: ["suggested-action"])
        Gtk.setName(submitButton, "coordinator.chat.interaction.submit")
        Signal.connect(submitButton, "clicked") { submit() }

        for question in answer.questions {
            addQuestion(question)
        }
        let footer = Gtk.hbox(spacing: 8)
        Gtk.append(footer, status)
        Gtk.append(footer, Self.terminalButton(showTerminal))
        Gtk.append(footer, submitButton)
        Gtk.append(root, footer)
        update(answer)
    }

    func update(_ answer: ToasttyInteractionAnswerState) {
        isSyncing = true
        defer { isSyncing = false }
        let isEditable: Bool = switch answer.status {
        case .editing, .failed: true
        default: false
        }
        for control in controls {
            let draft = answer.drafts[control.question.id] ?? ToasttyInteractionQuestionDraft()
            for (option, button) in zip(control.question.options, control.options) {
                let active = draft.selectedOptionIDs.contains(option.id)
                if gtk_check_button_get_active(cast(button)).bool != active {
                    gtk_check_button_set_active(cast(button), active.gboolean)
                }
                gtk_widget_set_sensitive(button, isEditable.gboolean)
            }
            if gtk_check_button_get_active(cast(control.other)).bool != draft.usesCustomText {
                gtk_check_button_set_active(cast(control.other), draft.usesCustomText.gboolean)
            }
            gtk_widget_set_sensitive(control.other, isEditable.gboolean)
            let currentText = gtk_editable_get_text(cast(control.entry)).map { String(cString: $0) }
            if currentText != draft.customText {
                gtk_editable_set_text(cast(control.entry), draft.customText)
            }
            Gtk.setVisible(control.entry, draft.usesCustomText)
            gtk_widget_set_sensitive(control.entry, isEditable.gboolean)
        }
        let message = Self.statusText(answer.status) ?? ""
        if gtk_label_get_text(cast(status)).map({ String(cString: $0) }) != message {
            Gtk.setLabel(status, message)
        }
        Gtk.setVisible(submitButton, isEditable)
        gtk_widget_set_sensitive(submitButton, answer.canSubmit.gboolean)
    }

    private func addQuestion(_ question: RemoteInteractionQuestion) {
        let column = Gtk.vbox(spacing: 4, classes: ["interaction-question"])
        if question.header.isEmpty == false {
            Gtk.append(column, Gtk.label(question.header, classes: ["interaction-question-header"]))
        }
        let text = Gtk.label(question.question, classes: ["interaction-question-text"], ellipsize: false)
        gtk_label_set_wrap(cast(text), 1)
        Gtk.append(column, text)
        var group: WidgetPtr?
        var buttons: [WidgetPtr] = []
        for option in question.options {
            let button = gtk_check_button_new_with_label(option.label)!
            if question.multiSelect == false {
                if let group { gtk_check_button_set_group(cast(button), cast(group)) } else { group = button }
            }
            if let detail = option.detail { gtk_widget_set_tooltip_text(button, detail) }
            Gtk.setName(button, "coordinator.chat.interaction.option.\(option.id)")
            Signal.connect(button, "toggled") { [weak self] in
                guard let self, self.isSyncing == false else { return }
                if question.multiSelect {
                    self.edit(.toggleOption(questionID: question.id, optionID: option.id))
                } else if gtk_check_button_get_active(cast(button)).bool {
                    self.edit(.selectOnly(questionID: question.id, optionID: option.id))
                }
            }
            buttons.append(button)
            Gtk.append(column, button)
        }
        let other = gtk_check_button_new_with_label("Other")!
        if question.multiSelect == false, let group { gtk_check_button_set_group(cast(other), cast(group)) }
        Signal.connect(other, "toggled") { [weak self] in
            guard let self, self.isSyncing == false else { return }
            // Choosing another radio button clears Other through selectOnly.
            if question.multiSelect || gtk_check_button_get_active(cast(other)).bool {
                self.edit(.toggleCustomText(questionID: question.id))
            }
        }
        Gtk.append(column, other)

        let entry = gtk_entry_new()!
        Gtk.setName(entry, "coordinator.chat.interaction.custom.\(question.id)")
        Signal.connect(entry, "changed") { [weak self] in
            guard let self, self.isSyncing == false else { return }
            let value = gtk_editable_get_text(cast(entry)).map { String(cString: $0) } ?? ""
            self.edit(.setCustomText(questionID: question.id, text: value))
        }
        Gtk.append(column, entry)
        controls.append(QuestionControls(question: question, options: buttons, other: other, entry: entry))
        Gtk.append(root, column)
    }

    static func readOnly(
        presentation: ToasttyInteractionPresentation,
        message: String,
        showTerminal: @escaping () -> Void
    ) -> WidgetPtr {
        let interaction = presentation.interaction
        let card = shell(interaction)
        if interaction.options.isEmpty == false {
            let options = Gtk.vbox(spacing: 2)
            for option in interaction.options {
                Gtk.append(options, Gtk.label("• \(option.label)", classes: ["interaction-option-readonly"]))
            }
            Gtk.append(card, options)
        }
        let footer = Gtk.hbox(spacing: 8)
        let label = Gtk.label(message, classes: ["dim-label"])
        gtk_widget_set_hexpand(label, 1)
        Gtk.append(footer, label)
        Gtk.append(footer, terminalButton(showTerminal))
        Gtk.append(card, footer)
        return card
    }

    private static func shell(_ interaction: RemotePendingInteraction) -> WidgetPtr {
        let card = Gtk.vbox(spacing: 10, classes: ["interaction-card"])
        Gtk.setName(card, "coordinator.chat.interaction")
        let kindTitle: String = switch interaction.kind {
        case .permission: "Permission"
        case .question, .structuredChoice: "Question"
        case .freeForm: "Waiting for your answer"
        }
        Gtk.append(card, Gtk.label(kindTitle.uppercased(), classes: ["interaction-kind"]))
        if interaction.prompt.isEmpty == false {
            let prompt = Gtk.label(interaction.prompt, classes: ["interaction-prompt"], ellipsize: false)
            gtk_label_set_wrap(cast(prompt), 1)
            gtk_label_set_selectable(cast(prompt), 1)
            Gtk.append(card, prompt)
        }
        return card
    }

    private static func terminalButton(_ showTerminal: @escaping () -> Void) -> WidgetPtr {
        let button = Gtk.button("Show Terminal", classes: ["flat"])
        Gtk.setName(button, "coordinator.chat.interaction.show-terminal")
        Signal.connect(button, "clicked") { showTerminal() }
        return button
    }

    private static func statusText(_ status: ToasttyInteractionAnswerStatus) -> String? {
        switch status {
        case .editing: nil
        case .submitting: "Sending your answer…"
        case .awaitingClaude: "Waiting for Claude to confirm the answer…"
        case .failed(let message): message
        case .unavailable(let message): message
        case .resolved(let answers): "Answered: " + answers.map { answer in
            ([answer.text].compactMap { $0 } + answer.selectedOptionIDs).joined(separator: ", ")
        }.joined(separator: "; ")
        }
    }
}
#endif
