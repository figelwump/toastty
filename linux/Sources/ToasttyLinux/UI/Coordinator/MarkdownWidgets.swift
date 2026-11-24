#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CGtkShim
@testable import ConversationUI
import Foundation

/// An agent's markdown as GTK widgets (macOS `ToasttyMarkdownText`): one
/// selectable label per paragraph, heading, list item or quote, a framed
/// monospace label per code block and a grid per table. Inline styles and
/// links become Pango markup; `toastty://task/<id>` links become task chips
/// through the host's link presenter.
@MainActor
enum MarkdownWidgets {
    /// Draws a link the presenter answers for (a task chip, plain text), or
    /// nil to draw it as a link.
    typealias LinkPresenter = (URL) -> ConversationLinkPresentation?

    static func make(
        blocks: [ToasttyMarkdownBlock],
        linkPresenter: LinkPresenter?,
        onLink: @escaping (URL) -> Void
    ) -> WidgetPtr {
        let column = Gtk.vbox(spacing: 6, classes: ["markdown"])
        for block in blocks {
            Gtk.append(column, widget(for: block, linkPresenter: linkPresenter, onLink: onLink))
        }
        return column
    }

    static func widget(
        for block: ToasttyMarkdownBlock,
        linkPresenter: LinkPresenter?,
        onLink: @escaping (URL) -> Void
    ) -> WidgetPtr {
        switch block.style {
        case .paragraph:
            return label(markup(block.content, linkPresenter: linkPresenter), classes: ["md-paragraph"], onLink: onLink)
        case .heading(let level):
            return label(markup(block.content, linkPresenter: linkPresenter), classes: ["md-heading", "md-h\(min(level, 4))"], onLink: onLink)
        case .list(let marker, let depth):
            let line = Gtk.hbox(spacing: 6, classes: ["md-list-item"])
            gtk_widget_set_margin_start(line, Int32(max(0, depth - 1) * 16))
            let bullet = Gtk.label(marker.label, classes: ["md-list-marker"], xalign: 1, ellipsize: false)
            gtk_widget_set_valign(bullet, GTK_ALIGN_START)
            gtk_widget_set_size_request(bullet, 16, -1)
            Gtk.append(line, bullet)
            let text = label(markup(block.content, linkPresenter: linkPresenter), classes: ["md-paragraph"], onLink: onLink)
            gtk_widget_set_hexpand(text, 1)
            Gtk.append(line, text)
            return line
        case .blockQuote:
            return label(markup(block.content, linkPresenter: linkPresenter), classes: ["md-quote"], onLink: onLink)
        case .code(let language):
            let frame = Gtk.vbox(spacing: 2, classes: ["md-code"])
            if let language, language.isEmpty == false {
                Gtk.append(frame, Gtk.label(language, classes: ["md-code-language"]))
            }
            let text = String(block.content.characters).trimmingCharacters(in: .newlines)
            let code = Gtk.label(text, classes: ["md-code-text"], ellipsize: false)
            gtk_label_set_selectable(cast(code), 1)
            gtk_label_set_wrap(cast(code), 1)
            gtk_label_set_wrap_mode(cast(code), PANGO_WRAP_WORD_CHAR)
            Gtk.append(frame, code)
            return frame
        case .table(let table):
            return tableWidget(table, linkPresenter: linkPresenter, onLink: onLink)
        }
    }

    private static func tableWidget(
        _ table: ToasttyMarkdownTable,
        linkPresenter: LinkPresenter?,
        onLink: @escaping (URL) -> Void
    ) -> WidgetPtr {
        let grid = gtk_grid_new()!
        Gtk.addClasses(grid, ["md-table"])
        gtk_grid_set_column_spacing(cast(grid), 14)
        gtk_grid_set_row_spacing(cast(grid), 4)
        for row in table.rows {
            for (column, cell) in row.cells.enumerated() {
                let alignment: Float = switch table.columns.indices.contains(column) ? table.columns[column] : .leading {
                case .leading: 0
                case .center: 0.5
                case .trailing: 1
                }
                let widget = label(
                    markup(cell, linkPresenter: linkPresenter),
                    classes: row.isHeader ? ["md-table-header"] : ["md-table-cell"],
                    onLink: onLink,
                    xalign: alignment
                )
                gtk_grid_attach(cast(grid), widget, Int32(column), Int32(row.id), 1, 1)
            }
        }
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(cast(scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER)
        gtk_scrolled_window_set_propagate_natural_height(cast(scroller), 1)
        gtk_scrolled_window_set_child(cast(scroller), grid)
        // A table is as tall as its rows, never taller.
        gtk_widget_set_vexpand(scroller, 0)
        gtk_widget_set_valign(scroller, GTK_ALIGN_START)
        return scroller
    }

    static func label(
        _ markup: String,
        classes: [String],
        onLink: @escaping (URL) -> Void,
        xalign: Float = 0
    ) -> WidgetPtr {
        let label = gtk_label_new(nil)!
        gtk_label_set_markup(cast(label), markup)
        gtk_label_set_xalign(cast(label), xalign)
        gtk_label_set_wrap(cast(label), 1)
        gtk_label_set_wrap_mode(cast(label), PANGO_WRAP_WORD_CHAR)
        gtk_label_set_selectable(cast(label), 1)
        Gtk.addClasses(label, classes)
        // Links never open by themselves: the host decides (task chips,
        // the Toastty browser, the system browser).
        Signal.connectPointerBool(label, "activate-link") { uri in
            guard let uri, let url = URL(string: String(cString: uri.assumingMemoryBound(to: CChar.self))) else { return true }
            onLink(url)
            return true
        }
        return label
    }

    /// Pango markup for an attributed string from the markdown parser:
    /// strong, emphasis, code, strikethrough and links. A task link the
    /// presenter answers for draws as a chip: a colored dot, the title and
    /// the pull request number.
    static func markup(_ content: AttributedString, linkPresenter: LinkPresenter?) -> String {
        var result = ""
        var drawnChips: Set<URL> = []
        for run in content.runs {
            let text = String(content[run.range].characters)
            var piece = escape(text)
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { piece = "<tt>\(piece)</tt>" }
                if intent.contains(.stronglyEmphasized) { piece = "<b>\(piece)</b>" }
                if intent.contains(.emphasized) { piece = "<i>\(piece)</i>" }
                if intent.contains(.strikethrough) { piece = "<s>\(piece)</s>" }
            }
            if let url = run.link {
                switch linkPresenter?(url) {
                case .plainText?:
                    break
                case .chip(let chip)?:
                    // A link with inline styles spans several runs; the chip
                    // draws once.
                    guard drawnChips.insert(url).inserted else { continue }
                    piece = "<a href=\"\(escape(url.absoluteString))\">\(chipMarkup(chip))</a>"
                case nil:
                    piece = "<a href=\"\(escape(url.absoluteString))\">\(piece)</a>"
                }
            }
            result += piece
        }
        return result
    }

    static func chipMarkup(_ chip: ConversationLinkChip) -> String {
        let color = hex(chip.markColor)
        let dot = chip.showsActivity ? "◌" : "●"
        var text = "<span foreground=\"\(color)\">\(dot)</span>\u{2009}<span weight=\"600\">\(escape(chip.title))</span>"
        if let detail = chip.detail {
            text += "\u{2009}<span alpha=\"60%\">\(escape(detail))</span>"
        }
        return "<span underline=\"none\" background=\"\(color)22\">\u{2009}\(text)\u{2009}</span>"
    }

    static func hex(_ color: ConversationChipColor) -> String {
        func byte(_ value: Double) -> String {
            String(format: "%02X", Int((min(max(value, 0), 1) * 255).rounded()))
        }
        return "#\(byte(color.red))\(byte(color.green))\(byte(color.blue))"
    }

    static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
#endif
