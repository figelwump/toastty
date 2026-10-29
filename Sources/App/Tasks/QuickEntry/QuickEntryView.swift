import AppKit
import SwiftUI

/// The quick entry panel's content, drawn to "Task Inbox Mockups" panel 1:
/// a small label, the task text, a row of attachments, and a footer with
/// the Workspace and Agent choices and Create Task. The footer's pills
/// follow "Task Keyboard Flow" revision 3, section 1. The panel's height
/// follows the text.
struct QuickEntryView: View {
    @ObservedObject var model: QuickEntryModel
    let dropTarget: QuickEntryDropTarget
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
            Text("New task")
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .medium))
                .tracking(0.44)
                .foregroundStyle(Self.mutedText)
            Spacer(minLength: 8)
            if model.isDropTargeted {
                Text("Drop to attach")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Self.accentText)
                    .accessibilityIdentifier("quick-entry.drop-hint")
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
                        AttachmentChip(attachment: attachment) {
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
            .frame(height: 54)
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
            pill(
                .workspace,
                title: "Workspace",
                value: model.workspaceTitle,
                isMissing: model.workspaceID == nil,
                help: "The workspace the task starts in."
            )
            .accessibilityIdentifier("quick-entry.workspace")

            pill(
                .agent,
                title: "Agent",
                value: model.agentTitleParts.name,
                suffix: model.agentTitleParts.effort.map { " · \($0)" },
                accessibilityValue: model.agentTitle,
                isMissing: model.preset == nil,
                help: "The agent, model and effort for the task."
            )
            .accessibilityIdentifier("quick-entry.agent")

            Spacer(minLength: 8)

            Button(action: model.cancel) {
                KeyCap(text: "esc")
            }
            .buttonStyle(.plain)
            .help("Close without creating a task")
            .accessibilityLabel("Cancel")
            .fixedSize()
            .layoutPriority(1)

            Button(action: model.submit) {
                CreateButtonLabel(isSubmitting: model.isSubmitting)
            }
            .buttonStyle(CreateButtonStyle())
            .disabled(model.canSubmit == false)
            .help(model.missingChoiceHint ?? "Create the task")
            .accessibilityIdentifier("quick-entry.create")
            .fixedSize()
            .layoutPriority(1)
        }
    }

    private func pill(
        _ kind: QuickEntryPickerKind,
        title: String,
        value: String,
        suffix: String? = nil,
        accessibilityValue: String? = nil,
        isMissing: Bool,
        help: String
    ) -> some View {
        let shortcut = kind == .workspace ? "⌘1" : "⌘2"
        return Button {
            togglePicker(kind)
        } label: {
            PillLabel(
                title: title,
                value: value,
                suffix: suffix,
                shortcut: shortcut,
                isMissing: isMissing,
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
private struct KeyCap: View {
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

/// A footer choice: its name, its value, and the shortcut that opens its
/// picker. Only the value shrinks, ending in "…"; a suffix such as
/// " · high" stays whole.
private struct PillLabel: View {
    let title: String
    let value: String
    let suffix: String?
    let shortcut: String
    let isMissing: Bool
    let isOpen: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        HStack(spacing: 6) {
            Text(title)
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
            .foregroundStyle(isMissing ? QuickEntryView.accentText : ToastyTheme.primaryText)
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

private struct AttachmentChip: View {
    let attachment: QuickEntryModel.Attachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let thumbnail = attachment.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: attachment.isImage ? "photo" : "doc")
                        .font(.system(size: 16))
                        .foregroundStyle(QuickEntryView.mutedText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white.opacity(0.05))
                }
            }
            // The preview leads the chip; the name stays quiet beside it.
            .frame(width: 64, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Text(attachment.displayName)
                .font(.system(size: 11))
                .foregroundStyle(QuickEntryView.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 120, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)

            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ToastyTheme.subtleText)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove \(attachment.displayName)")
            .accessibilityLabel("Remove \(attachment.displayName)")
        }
        .padding(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 9))
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(QuickEntryView.chipBackground))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(QuickEntryView.chipBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachment.displayName)
        .accessibilityIdentifier("quick-entry.attachment")
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

private struct CreateButtonLabel: View {
    @Environment(\.isEnabled) private var isEnabled
    let isSubmitting: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isSubmitting {
                ProgressView().controlSize(.mini)
            }
            Text("Create Task")
            KeyCap(
                text: "⌘↩",
                color: isEnabled ? Color(hex: 0x3A2806) : QuickEntryView.mutedText,
                border: isEnabled ? Color(hex: 0x9A6208) : QuickEntryView.chipBorder
            )
        }
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
