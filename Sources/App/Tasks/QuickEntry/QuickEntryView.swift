import AppKit
import SwiftUI

struct QuickEntryView: View {
    @ObservedObject var model: QuickEntryModel
    let dropTarget: QuickEntryDropTarget
    let attachFiles: () -> Void

    private static let panelBackground = Color(red: 0.10, green: 0.10, blue: 0.11).opacity(0.97)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: QuickEntryPanel.cornerRadius, style: .continuous)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("New task")
                    .font(ToastyTheme.fontTitle)
                    .foregroundStyle(ToastyTheme.primaryText)
                Spacer()
                Text("Drop screenshots or files here")
                    .font(ToastyTheme.fontSubtext)
                    .foregroundStyle(ToastyTheme.inactiveText.opacity(0.6))
            }

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
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.attachments.isEmpty == false || model.pendingAttachmentCount > 0 {
                attachmentsRow
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(ToastyTheme.fontSubtext)
                    .foregroundStyle(Color(hex: 0xE55C5C))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("quick-entry.error")
            }

            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: QuickEntryPanel.defaultSize.width, height: QuickEntryPanel.defaultSize.height)
        .background(shape.fill(Self.panelBackground))
        .overlay(
            shape.stroke(
                model.isDropTargeted ? ToastyTheme.accent.opacity(0.8) : Color.white.opacity(0.1),
                lineWidth: model.isDropTargeted ? 2 : 1
            )
        )
        .clipShape(shape)
        .compositingGroup()
        .shadow(color: Color.black.opacity(0.5), radius: 28, y: 12)
    }

    private var attachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.attachments) { attachment in
                    AttachmentChip(attachment: attachment) {
                        model.removeAttachment(id: attachment.id)
                    }
                    .disabled(model.isEditable == false)
                }
                if model.pendingAttachmentCount > 0 {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 6)
                }
            }
        }
        .frame(height: 30)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: attachFiles) {
                HStack(spacing: 5) {
                    Label("Attach", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                    Text("⌘V").opacity(0.55)
                }
            }
            .buttonStyle(FooterButtonStyle())
            .disabled(model.canAttachMore == false || model.isEditable == false)
            .help("Attach files. You can also paste an image with ⌘V or drop files on the panel.")

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
            // The button style with a plain button keeps the custom pill
            // label; the borderless style replaces it with the title.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.isEditable == false)
            .accessibilityValue(model.agentTitle)
            .accessibilityIdentifier("quick-entry.agent")

            Spacer(minLength: 8)

            Text("esc")
                .font(ToastyTheme.fontSubtext)
                .foregroundStyle(ToastyTheme.inactiveText.opacity(0.55))

            Button(action: model.submit) {
                HStack(spacing: 6) {
                    if model.isSubmitting {
                        ProgressView().controlSize(.mini)
                    }
                    Text("Create Task")
                    Text("⌘↩").opacity(0.7)
                }
            }
            .buttonStyle(CreateButtonStyle())
            .disabled(model.canSubmit == false)
            .accessibilityIdentifier("quick-entry.create")
        }
    }
}

private struct PillLabel: View {
    let title: String
    let value: String
    let isAuto: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(ToastyTheme.inactiveText.opacity(0.75))
            Text(value)
                .foregroundStyle(isAuto ? ToastyTheme.accent : ToastyTheme.primaryText)
                .lineLimit(1)
                .frame(maxWidth: 140, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(ToastyTheme.inactiveText.opacity(0.6))
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(isAuto ? ToastyTheme.accent.opacity(0.10) : Color.white.opacity(0.06))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(isAuto ? ToastyTheme.accent.opacity(0.35) : Color.white.opacity(0.12), lineWidth: 1)
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
        HStack(spacing: 6) {
            if attachment.isImage, let image = NSImage(contentsOf: attachment.url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(ToastyTheme.inactiveText)
            }
            Text(attachment.displayName)
                .font(.system(size: 11.5))
                .foregroundStyle(ToastyTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(ToastyTheme.inactiveText)
            }
            .buttonStyle(.plain)
            .help("Remove \(attachment.displayName)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}

private struct FooterButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(ToastyTheme.inactiveText.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.06))
            )
            .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

private struct CreateButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ToastyTheme.accentDark.opacity(isEnabled ? 1 : 0.6))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(ToastyTheme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35))
            )
    }
}
