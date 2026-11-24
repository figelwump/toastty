#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CGtkShim
@testable import ConversationUI
import Foundation
import RemoteProtocol
@testable import ToasttyAppLogic

/// A question or a permission request from the agent (macOS
/// `ToasttyInteractionCard`). A supported Claude question shows its choices
/// and Submit answer; anything else says where to answer and offers Show
/// Terminal.
@MainActor
enum InteractionCard {
    static func make(
        presentation: ToasttyInteractionPresentation,
        answer: ToasttyInteractionAnswerState?,
        readOnlyMessage: String,
        edit: @escaping (ToasttyInteractionAnswerEdit) -> Void,
        submit: @escaping () -> Void,
        showTerminal: @escaping () -> Void
    ) -> WidgetPtr {
        let interaction = presentation.interaction
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

        guard let answer else {
            // The chat cannot answer this one: the terminal can.
            if interaction.options.isEmpty == false {
                let options = Gtk.vbox(spacing: 2)
                for option in interaction.options {
                    Gtk.append(options, Gtk.label("• \(option.label)", classes: ["interaction-option-readonly"]))
                }
                Gtk.append(card, options)
            }
            let footer = Gtk.hbox(spacing: 8)
            let message = Gtk.label(readOnlyMessage, classes: ["dim-label"])
            gtk_widget_set_hexpand(message, 1)
            Gtk.append(footer, message)
            let terminal = Gtk.button("Show Terminal", classes: ["interaction-terminal"])
            Gtk.setName(terminal, "coordinator.chat.interaction.show-terminal")
            Signal.connect(terminal, "clicked") { showTerminal() }
            Gtk.append(footer, terminal)
            Gtk.append(card, footer)
            return card
        }

        let isEditable = answer.status == .editing || {
            if case .failed = answer.status { return true }
            return false
        }()
        for question in answer.questions {
            Gtk.append(card, questionWidget(question, draft: answer.drafts[question.id] ?? ToasttyInteractionQuestionDraft(),
                                            isEditable: isEditable, edit: edit))
        }
        let footer = Gtk.hbox(spacing: 8)
        let status = Gtk.label(statusText(answer.status) ?? "", classes: ["interaction-status"], ellipsize: false)
        gtk_label_set_wrap(cast(status), 1)
        gtk_widget_set_hexpand(status, 1)
        Gtk.append(footer, status)
        let terminal = Gtk.button("Show Terminal", classes: ["flat"])
        Gtk.setName(terminal, "coordinator.chat.interaction.show-terminal")
        Signal.connect(terminal, "clicked") { showTerminal() }
        Gtk.append(footer, terminal)
        if isEditable {
            let submitButton = Gtk.button("Submit answer", classes: ["suggested-action"])
            Gtk.setName(submitButton, "coordinator.chat.interaction.submit")
            gtk_widget_set_sensitive(submitButton, (answer.canonicalAnswers != nil && answer.connectionIsLive).gboolean)
            Signal.connect(submitButton, "clicked") { submit() }
            Gtk.append(footer, submitButton)
        }
        Gtk.append(card, footer)
        return card
    }

    private static func questionWidget(
        _ question: RemoteInteractionQuestion,
        draft: ToasttyInteractionQuestionDraft,
        isEditable: Bool,
        edit: @escaping (ToasttyInteractionAnswerEdit) -> Void
    ) -> WidgetPtr {
        let column = Gtk.vbox(spacing: 4, classes: ["interaction-question"])
        if question.header.isEmpty == false {
            Gtk.append(column, Gtk.label(question.header, classes: ["interaction-question-header"]))
        }
        let text = Gtk.label(question.question, classes: ["interaction-question-text"], ellipsize: false)
        gtk_label_set_wrap(cast(text), 1)
        Gtk.append(column, text)
        var group: WidgetPtr?
        for option in question.options {
            let button = gtk_check_button_new_with_label(option.label)!
            if question.multiSelect == false {
                if let group { gtk_check_button_set_group(cast(button), cast(group)) } else { group = button }
            }
            gtk_check_button_set_active(cast(button), draft.selectedOptionIDs.contains(option.id).gboolean)
            gtk_widget_set_sensitive(button, isEditable.gboolean)
            if let detail = option.detail { gtk_widget_set_tooltip_text(button, detail) }
            Gtk.setName(button, "coordinator.chat.interaction.option.\(option.id)")
            Signal.connect(button, "toggled") {
                let active = gtk_check_button_get_active(cast(button)).bool
                if question.multiSelect {
                    guard active != draft.selectedOptionIDs.contains(option.id) else { return }
                    edit(.toggleOption(questionID: question.id, optionID: option.id))
                } else if active {
                    edit(.selectOnly(questionID: question.id, optionID: option.id))
                }
            }
            Gtk.append(column, button)
        }
        // "Other": the user's own words.
        let other = gtk_check_button_new_with_label("Other")!
        if question.multiSelect == false, let group { gtk_check_button_set_group(cast(other), cast(group)) }
        gtk_check_button_set_active(cast(other), draft.usesCustomText.gboolean)
        gtk_widget_set_sensitive(other, isEditable.gboolean)
        Signal.connect(other, "toggled") {
            let active = gtk_check_button_get_active(cast(other)).bool
            guard active != draft.usesCustomText else { return }
            edit(.toggleCustomText(questionID: question.id))
        }
        Gtk.append(column, other)
        if draft.usesCustomText {
            let entry = gtk_entry_new()!
            gtk_editable_set_text(cast(entry), draft.customText)
            gtk_widget_set_sensitive(entry, isEditable.gboolean)
            Gtk.setName(entry, "coordinator.chat.interaction.custom.\(question.id)")
            Signal.connect(entry, "changed") {
                let value = gtk_editable_get_text(cast(entry)).map { String(cString: $0) } ?? ""
                edit(.setCustomText(questionID: question.id, text: value))
            }
            Gtk.append(column, entry)
        }
        return column
    }

    static func statusText(_ status: ToasttyInteractionAnswerStatus) -> String? {
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
