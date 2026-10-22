import AppKit
import Combine
import CoreState
import ImageIO
import SwiftUI

/// One Inbox task with the actions that move it on: the popover from its
/// sidebar row, and the Tasks view's detail pane. When the task has no
/// workspace, it holds the workspace field; when triage is on and suggested
/// a project, that suggestion is chosen first. Drawn to the "Workspace
/// Picker Design" Scratchpad, in the quick entry panel's colors.
struct TaskInboxCard: View {
    enum Layout {
        /// The sidebar popover: a status label and the title, a fixed width,
        /// and a footer with the actions.
        case popover
        /// Below the Tasks view's own title: the actions in a row.
        case pane
    }

    let taskID: UUID
    @ObservedObject var records: TaskRecordStore
    let coordinator: TaskCoordinator
    var layout: Layout = .popover
    let dismiss: () -> Void

    @State private var errorMessage: String?
    @State private var choices: TaskWorkspaceChoices?
    @State private var selection: Selection = .suggested
    /// Read when the card opens: Retry Triage is offered only while
    /// `[triage] command` is set.
    @State private var isTriageEnabled = false

    /// What the user chose. The suggestion is kept as such, not as the choice
    /// it was when the card opened, since the project may open or close while
    /// the card is shown.
    private enum Selection: Equatable {
        case suggested
        case choice(TaskWorkspaceChoice)
    }

    /// The choice Start uses now; `nil` when the chosen workspace is gone.
    private var chosen: TaskWorkspaceChoice? {
        guard let choices else { return nil }
        switch selection {
        case .suggested:
            return choices.suggested?.choice
        case .choice(let choice):
            return Self.isAvailable(choice, in: choices) ? choice : nil
        }
    }

    private var chosenBinding: Binding<TaskWorkspaceChoice?> {
        Binding(
            get: { chosen },
            set: { choice in
                if let choice, choice == choices?.suggested?.choice {
                    selection = .suggested
                } else if let choice {
                    selection = .choice(choice)
                }
            }
        )
    }

    static func isAvailable(_ choice: TaskWorkspaceChoice, in choices: TaskWorkspaceChoices) -> Bool {
        if choices.suggested?.choice == choice { return true }
        switch choice {
        case .open(let id): return choices.open.contains { $0.id == id }
        case .recent(let id): return choices.recent.contains { $0.id == id }
        case .directory: return false
        }
    }

    static let popoverWidth: CGFloat = 344
    // Colors from the design that the theme has no token for.
    static let background = Color(hex: 0x1C1C1C)
    static let secondaryText = Color(hex: 0xB7AEA5)
    static let mutedText = Color(hex: 0x7E766C)
    static let faintText = Color(hex: 0x5A5A5A)
    static let fieldBackground = Color(hex: 0x202020)
    static let fieldBorder = Color(hex: 0x343434)
    static let suggestedText = Color(hex: 0xE8B46A)
    static let suggestedBackground = Color(hex: 0x241C11)
    static let suggestedBorder = Color(hex: 0x4A3A22)
    static let noteRule = Color(hex: 0x3A3226)
    static let deleteText = Color(hex: 0xC97C7C)

    var body: some View {
        Group {
            if let record = records.record(id: taskID), SidebarInboxRowPresentation.isInInbox(record) {
                switch layout {
                case .popover: popover(record)
                case .pane: pane(record)
                }
            } else {
                // The task started or was deleted while this was open.
                Text("This task left the Inbox.")
                    .font(.system(size: 12))
                    .foregroundStyle(Self.mutedText)
                    .padding(16)
            }
        }
        .frame(width: layout == .popover ? Self.popoverWidth : nil, alignment: .leading)
        .onAppear(perform: loadChoices)
        .onChange(of: records.record(id: taskID)?.setup) { _, _ in
            // Retry Triage may bring a new suggestion.
            selection = .suggested
            loadChoices()
        }
        // Workspaces that open or close while the card is shown change the
        // choices, and the IDs Start would use.
        .onReceive(coordinator.store.$state.map { Set($0.workspacesByID.keys) }.removeDuplicates().dropFirst()) { _ in
            loadChoices()
        }
    }

    // MARK: - Layouts

    private func popover(_ record: TaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                statusLabel(record)
                Text(record.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ToastyTheme.primaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                taskBody(record)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))

            if isPickingWorkspace(record) {
                divider
                workspaceField(record)
                    .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }
            if let errorMessage {
                errorText(errorMessage)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            divider
            HStack(spacing: 8) {
                deleteButton(record)
                secondaryActions(record)
                Spacer(minLength: 8)
                primaryAction(record)
            }
            .padding(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 12))
        }
    }

    private func pane(_ record: TaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            taskBody(record)
            if isPickingWorkspace(record) {
                workspaceField(record)
                    .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    .frame(maxWidth: 520, alignment: .leading)
                    .background(Color(hex: 0x141414), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ToastyTheme.subtleBorder, lineWidth: 1))
            }
            if let errorMessage {
                errorText(errorMessage)
            }
            HStack(spacing: 8) {
                primaryAction(record)
                secondaryActions(record)
                deleteButton(record)
            }
        }
    }

    // MARK: - Parts

    /// The text as written, the attached files, and why the task is waiting.
    @ViewBuilder
    private func taskBody(_ record: TaskRecord) -> some View {
        let text = record.text.isEmpty ? (record.pinned.prompt ?? "") : record.text
        if text.isEmpty == false, text != record.title || layout == .popover {
            ScrollView {
                Text(text)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(Self.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: layout == .popover ? 120 : 240)
            .fixedSize(horizontal: false, vertical: true)
        }
        if record.attachments.isEmpty == false {
            TaskAttachmentChips(attachments: record.attachments)
        }
        ForEach(Array(notes(record).enumerated()), id: \.offset) { _, note in
            Text(note.text)
                .font(.system(size: 11.5))
                .lineSpacing(1.5)
                .foregroundStyle(note.isProblem ? Self.secondaryText : Self.mutedText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(note.isProblem ? ToastyTheme.sessionErrorText.opacity(0.55) : Self.noteRule)
                        .frame(width: 2)
                }
        }
    }

    private struct Note {
        var text: String
        var isProblem: Bool
    }

    /// Why the task waits, and what triage could not do when it ran, as
    /// quiet notes.
    private func notes(_ record: TaskRecord) -> [Note] {
        var notes: [Note] = []
        if case .needsWorkspace(let reason) = record.setup {
            notes.append(Note(text: reason, isProblem: false))
        }
        if let failure = SidebarInboxRowPresentation.failureReason(record) {
            notes.append(Note(text: failure, isProblem: true))
        }
        if let triageNote = record.triageNote, notes.contains(where: { $0.text.contains(triageNote) }) == false {
            notes.append(Note(text: triageNote, isProblem: false))
        }
        return notes
    }

    private func statusLabel(_ record: TaskRecord) -> some View {
        let status = Self.status(record)
        let color = status.needsUser ? ToastyTheme.sessionNeedsApprovalText : Self.mutedText
        return HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5)
                .strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                .frame(width: 8, height: 8)
            Text(status.label.uppercased())
                .font(.system(size: 10.5, weight: .medium))
                .tracking(0.7)
                .foregroundStyle(color)
            Spacer(minLength: 8)
            Text(record.createdAt.formatted(.relative(presentation: .named)))
                .font(.system(size: 11))
                .foregroundStyle(Self.faintText)
        }
        .accessibilityElement(children: .combine)
    }

    static func status(_ record: TaskRecord) -> (label: String, needsUser: Bool) {
        switch record.setup {
        case .routing: return ("Setting up", false)
        case .needsWorkspace: return ("Needs a workspace", true)
        case .settingUp: return ("Setting up", false)
        case .setupFailed: return ("Setup failed", true)
        case .started:
            if case .failed? = record.startWork?.state { return ("Worktree move failed", true) }
            return ("Moving to a worktree", false)
        }
    }

    private var divider: some View {
        Rectangle().fill(ToastyTheme.subtleBorder).frame(height: 1)
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11.5))
            .foregroundStyle(ToastyTheme.sessionErrorText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("task.inbox.error")
    }

    // MARK: - Workspace field

    private func isPickingWorkspace(_ record: TaskRecord) -> Bool {
        if case .needsWorkspace = record.setup { return true }
        return false
    }

    private func workspaceField(_ record: TaskRecord) -> some View {
        let choices = choices ?? TaskWorkspaceChoices(open: [], recent: [])
        let isSuggested = chosen != nil && chosen == choices.suggested?.choice
        return VStack(alignment: .leading, spacing: 6) {
            Text("WORKSPACE")
                .font(.system(size: 10.5, weight: .medium))
                .tracking(0.7)
                .foregroundStyle(Self.faintText)
            Menu {
                Picker("Workspace", selection: chosenBinding) {
                    if let suggested = choices.suggested {
                        Section("Suggested") {
                            menuItem(
                                suggested.title,
                                detail: Self.abbreviated(suggested.rootDirectory) + (suggested.isOpen ? "" : " · not open"),
                                choice: suggested.choice
                            )
                        }
                    }
                    Section("Open") {
                        ForEach(choices.open.filter { .open($0.id) != choices.suggested?.choice }) { workspace in
                            menuItem(workspace.title, detail: workspace.rootDirectory.map(Self.abbreviated), choice: .open(workspace.id))
                        }
                    }
                    let recent = choices.recent.filter { .recent($0.id) != choices.suggested?.choice }
                    if recent.isEmpty == false {
                        Section("Recently closed") {
                            ForEach(recent) { item in
                                menuItem(
                                    item.title,
                                    detail: "\(Self.abbreviated(item.rootDirectory)) · \(item.closedAt.formatted(.relative(presentation: .named)))",
                                    choice: .recent(item.id)
                                )
                            }
                        }
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                fieldLabel(choices: choices, isSuggested: isSuggested)
            }
            // The button style with a plain button keeps the custom label;
            // the borderless style replaces it with the title.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Workspace")
            .accessibilityValue(chosen.flatMap(choices.title(of:)) ?? "None chosen")
            .accessibilityIdentifier("task.inbox.workspacePicker")

            if let hint = Self.hint(for: chosen, choices: choices) {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Self.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func menuItem(_ title: String, detail: String?, choice: TaskWorkspaceChoice) -> some View {
        // On macOS 14 a second Text becomes the menu item's subtitle.
        VStack(alignment: .leading) {
            Text(title)
            if let detail {
                Text(detail)
            }
        }
        .tag(Optional(choice))
    }

    private func fieldLabel(choices: TaskWorkspaceChoices, isSuggested: Bool) -> some View {
        let title = chosen.flatMap(choices.title(of:))
        let path = chosen.flatMap { Self.rootDirectory(of: $0, in: choices) }.map(Self.abbreviated)
        return HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title ?? "Choose a workspace")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(title == nil ? Self.mutedText : ToastyTheme.primaryText)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let path {
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Self.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if isSuggested {
                Text("Suggested")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Self.suggestedText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(Self.suggestedBorder, lineWidth: 1))
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Self.mutedText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isSuggested ? Self.suggestedBackground : Self.fieldBackground,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSuggested ? Self.suggestedBorder : Self.fieldBorder, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    static func rootDirectory(of choice: TaskWorkspaceChoice, in choices: TaskWorkspaceChoices) -> String? {
        if let suggested = choices.suggested, suggested.choice == choice { return suggested.rootDirectory }
        switch choice {
        case .open(let id): return choices.open.first { $0.id == id }?.rootDirectory
        case .recent(let id): return choices.recent.first { $0.id == id }?.rootDirectory
        case .directory(let path): return path
        }
    }

    /// What choosing a workspace that is not open will do.
    static func hint(for choice: TaskWorkspaceChoice?, choices: TaskWorkspaceChoices) -> String? {
        switch choice {
        case .recent?, .directory?:
            "Not open. Toastty opens it with one terminal in this folder."
        case .open?, nil:
            nil
        }
    }

    /// A path with the home folder as `~`.
    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Actions

    /// The action that moves the task on, in amber, or an outline that says
    /// what is missing.
    @ViewBuilder
    private func primaryAction(_ record: TaskRecord) -> some View {
        if SidebarInboxRowPresentation.canRetry(record) {
            Button(record.setup.isStarted ? "Retry Move" : "Retry Setup") {
                perform { try coordinator.retry(taskID: record.id) }
            }
            .buttonStyle(TaskInboxButtonStyle(kind: .primary))
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("task.inbox.retry")
        } else if isPickingWorkspace(record) {
            let choices = choices ?? TaskWorkspaceChoices(open: [], recent: [])
            Button(Self.startTitle(for: chosen, choices: choices)) {
                guard let chosen else { return }
                perform { try coordinator.setWorkspace(taskID: record.id, choice: chosen) }
            }
            .buttonStyle(TaskInboxButtonStyle(kind: chosen == nil ? .disabledPrimary : .primary))
            .disabled(chosen == nil)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("task.inbox.start")
        }
    }

    static func startTitle(for choice: TaskWorkspaceChoice?, choices: TaskWorkspaceChoices) -> String {
        guard let choice, let title = choices.title(of: choice) else { return "Start" }
        switch choice {
        case .open: return "Start in \(title)"
        case .recent, .directory: return "Open \(title) & Start"
        }
    }

    @ViewBuilder
    private func secondaryActions(_ record: TaskRecord) -> some View {
        if isPickingWorkspace(record), isTriageEnabled {
            Button("Retry Triage") {
                perform { try coordinator.retry(taskID: record.id) }
            }
            .buttonStyle(TaskInboxButtonStyle(kind: .secondary))
            .accessibilityIdentifier("task.inbox.retryTriage")
        }
    }

    private func deleteButton(_ record: TaskRecord) -> some View {
        Button("Delete", role: .destructive) {
            perform { try coordinator.delete(taskID: record.id) }
        }
        .buttonStyle(TaskInboxButtonStyle(kind: layout == .popover ? .destructiveLink : .secondary))
        .accessibilityIdentifier("task.inbox.delete")
    }

    private func loadChoices() {
        guard let record = records.record(id: taskID), isPickingWorkspace(record) else { return }
        choices = coordinator.workspaceChoices(taskID: taskID)
        isTriageEnabled = coordinator.isTriageConfigured
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            errorMessage = nil
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension View {
    /// The card's own dark color behind a popover, the arrow included,
    /// instead of the system's grey material.
    func inboxPopoverChrome() -> some View {
        presentationBackground(TaskInboxCard.background)
            .environment(\.colorScheme, .dark)
    }
}

/// The Inbox card's buttons: amber for the action that moves the task on,
/// an outline for the others, and a quiet red link for Delete.
struct TaskInboxButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        /// The main action while something is missing, such as a workspace.
        case disabledPrimary
        case secondary
        case destructiveLink
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        configuration.label
            .font(.system(size: 12, weight: kind == .primary || kind == .disabledPrimary ? .semibold : .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, kind == .destructiveLink ? 2 : 12)
            .padding(.vertical, 5)
            .background(kind == .primary ? ToastyTheme.accent : Color.clear, in: shape)
            .overlay {
                if kind == .secondary || kind == .disabledPrimary {
                    shape.strokeBorder(Color(hex: 0x383838), lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(shape)
    }

    private var foreground: Color {
        switch kind {
        case .primary: Color(hex: 0x1A1206)
        case .disabledPrimary: Color(hex: 0x6C665F)
        case .secondary: TaskInboxCard.secondaryText
        case .destructiveLink: TaskInboxCard.deleteText
        }
    }
}

/// Attached files as chips, with a thumbnail for an image.
struct TaskAttachmentChips: View {
    let attachments: [TaskAttachment]

    var body: some View {
        FlowRow(spacing: 6) {
            ForEach(attachments, id: \.path) { attachment in
                HStack(spacing: 7) {
                    if let thumbnail = Self.thumbnail(path: attachment.path) {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 26, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    } else {
                        Image(systemName: "doc")
                            .font(.system(size: 11))
                            .foregroundStyle(TaskInboxCard.mutedText)
                            .frame(width: 20, height: 20)
                    }
                    Text(attachment.displayName)
                        .font(.system(size: 11.5))
                        .foregroundStyle(TaskInboxCard.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(EdgeInsets(top: 3, leading: 3, bottom: 3, trailing: 8))
                .background(Color(hex: 0x222222), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(hex: 0x333333), lineWidth: 1))
                .help(attachment.displayName)
            }
        }
    }

    private static let thumbnails = NSCache<NSString, NSImage>()

    /// A small preview read without decoding the whole image; `nil` for a
    /// file that is not an image or is gone.
    static func thumbnail(path: String) -> NSImage? {
        if let cached = thumbnails.object(forKey: path as NSString) { return cached }
        guard let source = CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 80,
              ] as CFDictionary) else {
            return nil
        }
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        thumbnails.setObject(thumbnail, forKey: path as NSString)
        return thumbnail
    }
}

/// Lays chips out left to right, wrapping to a new line when full.
private struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, min(x - spacing, width))
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxX, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
