#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CGtkShim
@testable import ConversationUI
import CoreState
import Foundation
import RemoteProtocol
@testable import ToasttyAppLogic

extension CoordinatorMentionCandidate {
    /// The tasks on the board that can be mentioned (macOS
    /// `CoordinatorMentionCandidate.candidates(from:)`): a task space
    /// without a task record cannot, since the coordinator reads tasks by
    /// their ID.
    @MainActor
    static func linuxCandidates(from items: [TaskBoardItem]) -> [CoordinatorMentionCandidate] {
        items.compactMap { item in
            guard case .task(let taskID) = item.id else { return nil }
            let group: Group = switch item.stage {
            case .needsYou: .needsYou
            case .starting, .running: .working
            case .idle: .idle
            case .toShip: .toShip
            case .done: .done
            case .archived: .archived
            }
            return CoordinatorMentionCandidate(
                taskID: taskID,
                title: item.title,
                projectTitle: item.projectTitle,
                pullRequestNumber: item.pullRequest?.number,
                group: group,
                markColor: TaskChipColors.color(for: item),
                doneAt: item.record?.doneAt ?? item.activityAt
            )
        }
    }
}

/// The colors of task chips and mentions (macOS
/// `CoordinatorTaskChips.markColor`), from the task's stage.
@MainActor
enum TaskChipColors {
    static func color(for item: TaskBoardItem) -> ConversationChipColor {
        let hex: UInt32 = switch item.stage {
        case .starting: 0x8F877D
        case .needsYou(let attention):
            switch attention {
            case .review, .readyForReview: 0x6E9FE6
            case .agentError: 0xE55C5C
            case .agentFinished: 0x5BA08A
            default: 0xE8A635
            }
        case .running, .idle: item.agent == .working ? 0xF5A623 : 0x8A8279
        case .toShip: 0xB98CE0
        case .done: 0x7CC47F
        case .archived: 0x8A8279
        }
        return ConversationChipColor(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Every task's chip, keyed by task ID, for the transcript's links.
    static func chips(_ items: [TaskBoardItem]) -> [UUID: ConversationLinkChip] {
        var chips: [UUID: ConversationLinkChip] = [:]
        for item in items {
            guard case .task(let taskID) = item.id else { continue }
            chips[taskID] = ConversationLinkChip(
                markColor: color(for: item),
                title: ConversationLinkChip.taskTitle(item.title),
                detail: item.pullRequest.map { "#\($0.number)" },
                showsActivity: CoordinatorChatPresentation.chipShowsActivity(for: item)
            )
        }
        return chips
    }
}

/// The list of tasks to mention, above the composer's field, while the
/// caret follows an `@` and its search (macOS `CoordinatorMentionPicker`).
/// The trigger and the search are the shared rules
/// (`CoordinatorMentionTrigger`, `CoordinatorMentionSearch`); Up and Down
/// choose, Return or Tab puts the task in, Escape closes the list.
@MainActor
final class CoordinatorMentionPopover {
    private let popover: WidgetPtr
    private var popoverRef: GObjectRef?
    private let list: WidgetPtr
    private let candidates: () -> [CoordinatorMentionCandidate]
    private var results: [CoordinatorMentionCandidate] = []
    private var selectedIndex = 0
    private var dismissedAnchor: Int?
    /// The `@` and its search, in character offsets of the field's text.
    private(set) var queryRange: Range<Int>?
    var onChoose: ((CoordinatorMentionCandidate) -> Void)?

    init(anchor: WidgetPtr, candidates: @escaping () -> [CoordinatorMentionCandidate]) {
        self.candidates = candidates
        popover = gtk_popover_new()!
        Gtk.addClasses(popover, ["mention-popover"])
        gtk_popover_set_autohide(cast(popover), 0)
        gtk_popover_set_has_arrow(cast(popover), 0)
        gtk_popover_set_position(cast(popover), GTK_POS_TOP)
        list = Gtk.vbox(spacing: 2, classes: ["mention-list"])
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(cast(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_max_content_height(cast(scroller), 280)
        gtk_scrolled_window_set_propagate_natural_height(cast(scroller), 1)
        gtk_widget_set_size_request(scroller, 340, -1)
        gtk_scrolled_window_set_child(cast(scroller), list)
        gtk_popover_set_child(cast(popover), scroller)
        Gtk.setName(popover, "coordinator.chat.mentions")
        popoverRef = GObjectRef(sinking: popover)
        gtk_widget_set_parent(popover, anchor)
    }

    func teardown() {
        Gtk.unparentIfAttached(popover)
    }

    var isOpen: Bool { queryRange != nil }

    /// Follows the text and the caret (`cursorOffset` in characters).
    func textChanged(text: String, cursorOffset: Int) {
        let scalars = Array(text.unicodeScalars)
        let caret = min(cursorOffset, scalars.count)
        let utf16Caret = String(String.UnicodeScalarView(scalars.prefix(caret))).utf16.count
        guard let match = CoordinatorMentionTrigger.match(in: text as NSString, caret: utf16Caret) else {
            dismissedAnchor = nil
            close()
            return
        }
        if match.anchor == dismissedAnchor {
            close()
            return
        }
        let sections = CoordinatorMentionSearch.sections(query: match.query, candidates: candidates(), now: Date())
        if CoordinatorMentionSearch.endsTheSearch(query: match.query, sections: sections) {
            close()
            return
        }
        // The anchor in characters (GTK's offsets) from UTF-16 (the rules').
        let anchorScalars = String(decoding: Array(text.utf16.prefix(match.anchor)), as: UTF16.self).unicodeScalars.count
        let newRange = anchorScalars..<caret
        if queryRange != newRange { selectedIndex = 0 }
        queryRange = newRange
        rebuild(sections)
        gtk_popover_popup(cast(popover))
    }

    /// A key while the list shows. Returns true when the list took it.
    func handleKey(_ keyval: Int32) -> Bool {
        switch keyval {
        case GDK_KEY_Escape:
            dismissedAnchor = queryRange.map { $0.lowerBound }
            close()
            return true
        case GDK_KEY_Up where results.isEmpty == false:
            selectedIndex = (selectedIndex - 1 + results.count) % results.count
            highlight()
            return true
        case GDK_KEY_Down where results.isEmpty == false:
            selectedIndex = (selectedIndex + 1) % results.count
            highlight()
            return true
        case GDK_KEY_Return, GDK_KEY_KP_Enter, GDK_KEY_Tab where results.isEmpty == false:
            onChoose?(results[min(selectedIndex, results.count - 1)])
            return true
        default:
            return false
        }
    }

    func close() {
        queryRange = nil
        results = []
        if gtk_widget_get_visible(popover).bool { gtk_popover_popdown(cast(popover)) }
    }

    private var rows: [WidgetPtr] = []

    private func rebuild(_ sections: [CoordinatorMentionSearch.Section]) {
        Gtk.removeAllChildren(list)
        rows = []
        results = sections.flatMap(\.candidates)
        if results.isEmpty {
            Gtk.append(list, Gtk.label("No task matches", classes: ["dim-label", "mention-empty"]))
        }
        for section in sections {
            Gtk.append(list, Gtk.label(section.group.title.uppercased(), classes: ["mention-section"]))
            for candidate in section.candidates {
                let index = rows.count
                let row = gtk_button_new()!
                Gtk.addClasses(row, ["flat", "mention-row"])
                let content = Gtk.hbox(spacing: 6)
                let dot = Gtk.label("●", ellipsize: false)
                let color = MarkdownWidgets.hex(candidate.markColor)
                gtk_label_set_markup(cast(dot), "<span foreground=\"\(color)\">●</span>")
                Gtk.append(content, dot)
                let title = Gtk.label(CoordinatorMentionCandidate.label(title: candidate.title))
                gtk_widget_set_hexpand(title, 1)
                Gtk.append(content, title)
                let detail = [candidate.projectTitle, candidate.pullRequestNumber.map { "#\($0)" }].compactMap { $0 }.joined(separator: " · ")
                if detail.isEmpty == false {
                    Gtk.append(content, Gtk.label(detail, classes: ["dim-label", "mention-detail"], ellipsize: false))
                }
                gtk_button_set_child(cast(row), content)
                Signal.connect(row, "clicked") { [weak self] in
                    guard let self, self.results.indices.contains(index) else { return }
                    self.onChoose?(self.results[index])
                }
                rows.append(row)
                Gtk.append(list, row)
            }
        }
        highlight()
    }

    private func highlight() {
        for (index, row) in rows.enumerated() {
            Gtk.setClass(row, "selected", index == selectedIndex)
        }
    }

    var automationResults: [String] { results.map(\.title) }
}
#endif
