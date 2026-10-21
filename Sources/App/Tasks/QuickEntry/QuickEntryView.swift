import AppKit
import SwiftUI

/// The quick entry panel's content, drawn to "Task Inbox Mockups" panel 1:
/// a small label, the task text, a row of attachments, and a footer with
/// the Workspace and Agent choices and Create Task. The panel's height
/// follows the text.
struct QuickEntryView: View {
    @ObservedObject var model: QuickEntryModel
    let dropTarget: QuickEntryDropTarget
    let attachFiles: () -> Void
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
    static let autoText = Color(hex: 0xE8B46A)
    static let autoBackground = Color(hex: 0x241C11)
    static let autoBorder = Color(hex: 0x4A3A22)
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
                    .foregroundStyle(Self.autoText)
                    .accessibilityIdentifier("quick-entry.drop-hint")
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
            .frame(height: 38)
            // Keeps Attach in view once the files fill the row.
            .onChange(of: model.attachments.count + model.pendingAttachmentCount) {
                scroller.scrollTo(Self.attachChipID, anchor: .trailing)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Auto") { model.workspaceID = nil }
                if model.workspaceOptions.isEmpty == false {
                    Divider()
                }
                ForEach(model.workspaceOptions) { option in
                    Button(option.title) { model.workspaceID = UUID(uuidString: option.id) }
                }
            } label: {
                PillLabel(title: "Workspace", value: model.workspaceTitle, isAuto: model.workspaceID == nil)
            }
            // The button style with a plain button keeps the custom pill
            // label; the borderless style replaces it with the title.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.isEditable == false)
            .help("The workspace the task starts in. Auto lets triage choose.")
            .accessibilityValue(model.workspaceTitle)
            .accessibilityIdentifier("quick-entry.workspace")

            Menu {
                Button("Auto") { model.agentID = nil }
                if model.agentOptions.isEmpty == false {
                    Divider()
                }
                ForEach(model.agentOptions) { option in
                    Button(option.title) { model.agentID = option.id }
                }
            } label: {
                PillLabel(title: "Agent", value: model.agentTitle, isAuto: model.agentID == nil)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.isEditable == false)
            .help("The agent that works on the task. Auto lets triage choose.")
            .accessibilityValue(model.agentTitle)
            .accessibilityIdentifier("quick-entry.agent")

            Spacer(minLength: 8)

            Button(action: model.cancel) {
                KeyCap(text: "esc")
            }
            .buttonStyle(.plain)
            .help("Close without creating a task")
            .accessibilityLabel("Cancel")

            Button(action: model.submit) {
                CreateButtonLabel(isSubmitting: model.isSubmitting)
            }
            .buttonStyle(CreateButtonStyle())
            .disabled(model.canSubmit == false)
            .accessibilityIdentifier("quick-entry.create")
        }
    }
}

/// A key shown as a small outlined key cap, such as "esc" or "⌘V".
private struct KeyCap: View {
    let text: String
    var color: Color = QuickEntryView.mutedText
    var border: Color = QuickEntryView.chipBorder

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(border, lineWidth: 1))
    }
}

private struct PillLabel: View {
    let title: String
    let value: String
    let isAuto: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .foregroundStyle(QuickEntryView.mutedText)
            Text(value)
                .foregroundStyle(isAuto ? QuickEntryView.autoText : ToastyTheme.primaryText)
                .lineLimit(1)
                .frame(maxWidth: 160, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(isAuto ? QuickEntryView.autoBackground : QuickEntryView.pillBackground))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(isAuto ? QuickEntryView.autoBorder : QuickEntryView.pillBorder, lineWidth: 1)
        )
        .contentShape(Capsule())
        // One element named for the pill; the menu adds the value.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
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
                        .font(.system(size: 12))
                        .foregroundStyle(QuickEntryView.mutedText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white.opacity(0.05))
                }
            }
            .frame(width: 34, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            Text(attachment.displayName)
                .font(.system(size: 12))
                .foregroundStyle(QuickEntryView.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 200, alignment: .leading)
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
        .padding(EdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 9))
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
