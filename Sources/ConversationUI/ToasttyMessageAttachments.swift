import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The files sent with a user's message, in its bubble: an image as a
/// thumbnail, any other file, or an image that cannot be read now, as its
/// icon and name. The files are on this device; the host gives their paths.
struct ToasttyMessageAttachments: View {
    let urls: [URL]

    var body: some View {
        ToasttyFlowLayout(spacing: 6) {
            ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
                ToasttyMessageAttachment(url: url)
            }
        }
    }
}

private struct ToasttyMessageAttachment: View {
    /// The thumbnail's height. Its width follows the image, within limits,
    /// so that the row's height does not change when the image loads.
    static let thumbnailHeight: CGFloat = 120
    static let thumbnailWidthRange: ClosedRange<CGFloat> = 72...240

    let url: URL
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: ToasttyAttachmentThumbnail?
    @State private var isUnreadable = false

    private var name: String { url.lastPathComponent }
    private var isImage: Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true }

    var body: some View {
        if isImage, isUnreadable == false {
            thumbnailView
                .task(id: url) { await load() }
        } else {
            fileChip
        }
    }

    private var thumbnailView: some View {
        let width = thumbnail.map {
            min(max($0.aspectRatio * Self.thumbnailHeight, Self.thumbnailWidthRange.lowerBound),
                Self.thumbnailWidthRange.upperBound)
        } ?? Self.thumbnailHeight
        return ZStack {
            Color.black.opacity(0.25)
            if let thumbnail {
                Image(decorative: thumbnail.image, scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: width, height: Self.thumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(ConversationDesignTokens.userBubbleBorder)
        }
        .help(name)
        .accessibilityElement()
        .accessibilityLabel("Image \(name)")
        .accessibilityAddTraits(.isImage)
    }

    private var fileChip: some View {
        HStack(spacing: 6) {
            Image(systemName: isImage ? "photo" : "doc")
                .foregroundStyle(ConversationDesignTokens.mutedText)
                .accessibilityHidden(true)
            Text(name)
                .conversationFont(.caption)
                .foregroundStyle(ConversationDesignTokens.userBubbleText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 260)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.2)))
        .help(name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("File \(name)")
    }

    private func load() async {
        let pixelSize = Int(Self.thumbnailWidthRange.upperBound * displayScale)
        let loaded = await ToasttyAttachmentThumbnail.load(url: url, maximumPixelSize: pixelSize)
        guard Task.isCancelled == false else { return }
        if let loaded {
            thumbnail = loaded
        } else {
            isUnreadable = true
        }
    }
}

/// A small copy of an attached image, made off the main thread and kept
/// while the transcript scrolls its rows out and back in.
struct ToasttyAttachmentThumbnail: @unchecked Sendable {
    let image: CGImage
    var aspectRatio: CGFloat { CGFloat(image.width) / CGFloat(max(image.height, 1)) }

    private final class Box: NSObject {
        let thumbnail: ToasttyAttachmentThumbnail
        init(_ thumbnail: ToasttyAttachmentThumbnail) { self.thumbnail = thumbnail }
    }

    private nonisolated(unsafe) static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 64
        return cache
    }()

    /// `nil` when the file is gone or is not an image that ImageIO reads.
    static func load(url: URL, maximumPixelSize: Int) async -> ToasttyAttachmentThumbnail? {
        let key = "\(maximumPixelSize):\(url.path)" as NSString
        if let cached = cache.object(forKey: key) { return cached.thumbnail }
        let task = Task.detached(priority: .utility) { () -> ToasttyAttachmentThumbnail? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                      kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary) else { return nil }
            return ToasttyAttachmentThumbnail(image: image)
        }
        guard let thumbnail = await task.value else { return nil }
        cache.setObject(Box(thumbnail), forKey: key)
        return thumbnail
    }
}

/// Views in rows that wrap, from the leading edge.
private struct ToasttyFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, maxWidth)
            let widthWithItem = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if row.indices.isEmpty == false, widthWithItem > maxWidth {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            row.sizes.append(size)
        }
        if row.indices.isEmpty == false { rows.append(row) }
        return rows
    }
}
