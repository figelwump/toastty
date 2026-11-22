import AppKit
import SwiftUI

/// One attached file in a draft: the image's preview, or a file icon and
/// the file's name, and a button that removes it. Quick entry and the
/// coordinator chat's composer show the same chip, in the colors of the
/// quick entry design.
struct AttachmentChip: View {
    let attachment: DraftAttachments.Attachment
    let accessibilityIdentifier: String
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
            .frame(width: attachment.thumbnail == nil ? 48 : 96, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help(attachment.displayName)

            // A preview identifies an image by itself; the name shows only
            // beside a file icon, and on hover.
            if attachment.thumbnail == nil {
                Text(attachment.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(QuickEntryView.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 120, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }

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
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
