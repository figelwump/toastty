import AppKit
import SwiftUI

/// The quick entry panel's content, drawn to "Task Inbox Mockups" panel 1:
/// a small label, the task text, a row of attachments, and a footer with
/// the Workspace and Agent choices and Create Task. The footer's pills
/// follow "Task Keyboard Flow" revision 3, section 1, except that a small
/// icon takes the place of each pill's name, so the values have room. The
/// panel's height follows the text.
///
/// With a coordinator the same panel sends to it ("Coordinator design"
/// revision 15, section 4): the label says so, a pill shows "Auto" until
/// the user sets it, Send is the main button, and Create Task stays as a
/// second, quiet button.
struct QuickEntryView: View {
    @ObservedObject var model: QuickEntryModel
    let dropTarget: AttachmentDropTarget
    let attachFiles: () -> Void
    /// A click on a pill: opens its picker, or closes it.
    let togglePicker: (QuickEntryPickerKind) -> Void
    /// Called with the content's height whenever it changes, so the window
    /// can fit it.
    let onHeightChange: (CGFloat) -> Void

    // Colors from the design that the theme has no token for.
    static let panelBackground = ToastyTheme.elevatedBackground.opacity(0.97)
    static let panelBorder = Color(hex: 0x3A3A3A)
    static let mutedText = Color(hex: 0x7E766C)
    static let secondaryText = Color(hex: 0xB7AEA5)
    static let chipBackground = Color(hex: 0x222222)
    static let chipBorder = Color(hex: 0x333333)
    static let pillBackground = Color(hex: 0x202020)
    static let pillBorder = Color(hex: 0x343434)
    static let accentText = Color(hex: 0xE8B46A)
    static let missingBackground = Color(hex: 0x241C11)
    static let missingBorder = Color(hex: 0x4A3A22)
    static let errorText = Color(hex: 0xE55C5C)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: QuickEntryPanel.cornerRadius, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                header
                QuickEntryTextEditor(
                    text: $model.text,
                    placeholder: "What needs doing?",
                    isEditable: model.isEditable,
                    focusRequestID: model.focusRequestID,
                    onSubmit: model.submit,
                    onCreateTask: model.createTask,
                    onCancel: model.cancel,
                    onPasteAttachments: model.pasteAttachments(from:),
                    dropTarget: dropTarget
                )
            }
            .padding(EdgeInsets(top: 16, leading: 18, bottom: 10, trailing: 18))

            attachmentsRow
                .padding(.horizontal, 18)
                .padding(.bottom, 12)

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Self.errorText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("quick-entry.error")
            }

            Rectangle()
                .fill(ToastyTheme.subtleBorder)
                .frame(height: 1)

            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: QuickEntryPanel.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(shape.fill(Self.panelBackground))
        // The design's inset hairline, inside the border.
        .overlay(shape.inset(by: 1).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        .overlay(
            shape.strokeBorder(
                model.isDropTargeted ? ToastyTheme.accent : Self.panelBorder,
                lineWidth: model.isDropTargeted ? 1.5 : 1
            )
        )
        .clipShape(shape)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            onHeightChange(height)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ToastyTheme.accent)
                .frame(width: 6, height: 6)
            Text(model.sendsToCoordinator ? "To coordinator" : "New task")
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .medium))
                .tracking(0.44)
                .foregroundStyle(Self.mutedText)
                .accessibilityIdentifier("quick-entry.title")
            Spacer(minLength: 8)
            if model.isDropTargeted {
                Text("Drop to attach")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Self.accentText)
                    .accessibilityIdentifier("quick-entry.drop-hint")
            } else if let coordinator = model.coordinator {
                // The pills are optional here. The line says instead when
                // the message will wait.
                if let hint = coordinator.hint {
                    Text(hint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Self.accentText)
                        .lineLimit(1)
                        .accessibilityIdentifier("quick-entry.coordinator-hint")
                }
            } else if let hint = model.missingChoiceHint {
                Text(hint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Self.accentText)
                    .accessibilityIdentifier("quick-entry.missing-choice")
            }
        }
        .frame(height: 14)
    }

    private static let attachChipID = "attach"

    private var attachmentsRow: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.attachments) { attachment in
                        AttachmentChip(attachment: attachment, accessibilityIdentifier: "quick-entry.attachment") {
                            model.removeAttachment(id: attachment.id)
                        }
                        .disabled(model.isEditable == false)
                    }
                    if model.pendingAttachmentCount > 0 {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 4)
                    }
                    Button(action: attachFiles) {
                        HStack(spacing: 6) {
                            Text("＋ Attach")
                            KeyCap(text: "⌘V")
                        }
                    }
                    .buttonStyle(AddChipStyle())
                    .disabled(model.canAttachMore == false || model.isEditable == false)
                    .help("Attach files. You can also paste an image with ⌘V or drop files on the panel.")
                    .accessibilityIdentifier("quick-entry.attach")
                    .id(Self.attachChipID)
                }
                .padding(.vertical, 1)
            }
            .frame(height: 74)
            // Keeps Attach in view once the files fill the row.
            .onChange(of: model.attachments.count + model.pendingAttachmentCount) {
                scroller.scrollTo(Self.attachChipID, anchor: .trailing)
            }
        }
    }

    /// One row: a long workspace or model name is cut short, and the
    /// buttons keep their size.
    private var footer: some View {
        HStack(spacing: 8) {
            let sendsToCoordinator = model.sendsToCoordinator
            pill(
                .workspace,
                title: "Workspace",
                icon: "square.grid.2x2",
                value: model.workspacePillTitle,
                isMissing: sendsToCoordinator == false && model.workspaceID == nil,
                isUnset: sendsToCoordinator && model.choseWorkspace == false,
                help: sendsToCoordinator
                    ? "The project. Auto leaves the choice to the coordinator."
                    : "The workspace the task starts in."
            )
            .accessibilityIdentifier("quick-entry.workspace")

            pill(
                .agent,
                title: "Agent",
                icon: "sparkle",
                value: model.agentPillParts.name,
                suffix: model.agentPillParts.effort.map { " · \($0)" },
                accessibilityValue: model.agentPillTitle,
                isMissing: sendsToCoordinator == false && model.preset == nil,
                isUnset: sendsToCoordinator && model.chosePreset == false,
                help: sendsToCoordinator
                    ? "The agent, model and effort. Auto leaves the choice to the coordinator."
                    : "The agent, model and effort for the task."
            )
            .accessibilityIdentifier("quick-entry.agent")

            Spacer(minLength: 8)

            Button(action: model.cancel) {
                KeyCap(text: "esc")
            }
            .buttonStyle(.plain)
            .help(sendsToCoordinator ? "Close without sending" : "Close without creating a task")
            .accessibilityLabel("Cancel")
            .fixedSize()
            .layoutPriority(1)

            if sendsToCoordinator {
                // Short, so that a usual project and model name fit next
                // to two buttons. The tooltip says the rest.
                Button(action: model.createTask) {
                    SubmitButtonLabel(title: "Create", shortcut: "⌥⌘↩", isSubmitting: false, isProminent: false)
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityLabel("Create Task")
                .disabled(model.canCreateTask == false)
                .help(model.missingChoiceHint.map { "\($0) to create the task directly." }
                    ?? "Create the task now in \(model.workspaceTitle) with \(model.agentTitle), without the coordinator")
                .accessibilityIdentifier("quick-entry.create")
                .fixedSize()
                .layoutPriority(1)

                Button(action: model.submit) {
                    SubmitButtonLabel(title: "Send", shortcut: "⌘↩", isSubmitting: model.isSubmitting, isProminent: true)
                }
                .buttonStyle(CreateButtonStyle())
                .disabled(model.canSubmit == false)
                .help("Send to the coordinator")
                .accessibilityIdentifier("quick-entry.send")
                .fixedSize()
                .layoutPriority(1)
            } else {
                Button(action: model.submit) {
                    SubmitButtonLabel(title: "Create Task", shortcut: "⌘↩", isSubmitting: model.isSubmitting, isProminent: true)
                }
                .buttonStyle(CreateButtonStyle())
                .disabled(model.canSubmit == false)
                .help(model.missingChoiceHint ?? "Create the task")
                .accessibilityIdentifier("quick-entry.create")
                .fixedSize()
                .layoutPriority(1)
            }
        }
    }

    private func pill(
        _ kind: QuickEntryPickerKind,
        title: String,
        icon: String,
        value: String,
        suffix: String? = nil,
        accessibilityValue: String? = nil,
        isMissing: Bool,
        isUnset: Bool = false,
        help: String
    ) -> some View {
        let shortcut = kind == .workspace ? "⌘1" : "⌘2"
        return Button {
            togglePicker(kind)
        } label: {
            PillLabel(
                icon: icon,
                value: value,
                suffix: suffix,
                shortcut: shortcut,
                isMissing: isMissing,
                isUnset: isUnset,
                isOpen: model.openPicker == kind
            )
        }
        .buttonStyle(.plain)
        .disabled(model.isEditable == false)
        .help("\(help) \(shortcut)")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            model.pillFrames[kind] = frame
        }
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue ?? value)
    }
}

/// A key shown as a small outlined key cap, such as "esc" or "⌘V".
struct KeyCap: View {
    let text: String
    var size: CGFloat = 11
    var color: Color = QuickEntryView.mutedText
    var border: Color = QuickEntryView.chipBorder

    var body: some View {
        Text(text)
            .font(.system(size: size, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, size < 11 ? 4 : 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(border, lineWidth: 1))
    }
}

/// A footer choice: its icon, its value, and the shortcut that opens its
/// picker. Only the value shrinks, ending in "…"; a suffix such as
/// " · high" stays whole. The tooltip and VoiceOver give the pill's name.
private struct PillLabel: View {
    let icon: String
    let value: String
    let suffix: String?
    let shortcut: String
    let isMissing: Bool
    /// "Auto": the coordinator chooses. Quieter than a value.
    var isUnset = false
    let isOpen: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(QuickEntryView.mutedText)
                .fixedSize()
            HStack(spacing: 0) {
                Text(value)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let suffix {
                    Text(suffix)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(
                isMissing ? QuickEntryView.accentText : (isUnset ? QuickEntryView.secondaryText : ToastyTheme.primaryText)
            )
            KeyCap(text: shortcut, size: 10)
                .fixedSize()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(shape.fill(isMissing ? QuickEntryView.missingBackground : QuickEntryView.pillBackground))
        .overlay(
            shape.strokeBorder(
                isOpen ? QuickEntryView.accentText : (isMissing ? QuickEntryView.missingBorder : QuickEntryView.pillBorder),
                lineWidth: 1
            )
        )
        // The design's glow around an open pill.
        .overlay(shape.inset(by: -2).strokeBorder(QuickEntryView.accentText.opacity(isOpen ? 0.18 : 0), lineWidth: 2))
        .contentShape(shape)
        // One element named for the pill; the button adds the value.
        .accessibilityElement(children: .ignore)
    }
}

/// The dashed "＋ Attach ⌘V" chip at the end of the attachments row.
private struct AddChipStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(QuickEntryView.mutedText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.06 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(QuickEntryView.chipBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A footer button's title and key: "Create Task ⌘↩", "Send ⌘↩".
private struct SubmitButtonLabel: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let shortcut: String
    let isSubmitting: Bool
    /// On the amber button the key cap is dark.
    let isProminent: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isSubmitting {
                ProgressView().controlSize(.mini)
            }
            Text(title)
            KeyCap(
                text: shortcut,
                color: isEnabled && isProminent ? Color(hex: 0x3A2806) : QuickEntryView.mutedText,
                border: isEnabled && isProminent ? Color(hex: 0x9A6208) : QuickEntryView.chipBorder
            )
        }
    }
}

/// The second action next to the amber button: an outline, never filled.
private struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(isEnabled ? QuickEntryView.secondaryText : QuickEntryView.mutedText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(shape.fill(Color.white.opacity(configuration.isPressed ? 0.08 : 0.03)))
            .overlay(shape.strokeBorder(QuickEntryView.chipBorder, lineWidth: 1))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.6)
    }
}

/// Amber when the task can be created; a quiet outline until there is text.
private struct CreateButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(isEnabled ? ToastyTheme.accentDark : QuickEntryView.mutedText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                shape.fill(isEnabled ? ToastyTheme.accent.opacity(configuration.isPressed ? 0.85 : 1) : Color.white.opacity(0.04))
            )
            .overlay(shape.strokeBorder(isEnabled ? Color.clear : QuickEntryView.chipBorder, lineWidth: 1))
            .contentShape(shape)
    }
}
