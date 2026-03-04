import AppKit
import ImageIO
import SwiftUI

struct RecentScreenshotsPanelView: View {
    @ObservedObject var store: RecentScreenshotsStore

    var body: some View {
        Group {
            switch store.status {
            case .idle, .loading, .ready:
                if store.items.isEmpty {
                    panelMessage(
                        title: "No recent screenshots",
                        body: "Take a system screenshot to populate this panel."
                    )
                } else {
                    screenshotList
                }

            case .missingDirectory(let path):
                panelMessage(
                    title: "Screenshot folder missing",
                    body: path
                )

            case .unreadableDirectory(let path):
                panelMessage(
                    title: "Cannot read screenshot folder",
                    body: path
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ToastyTheme.surfaceBackground)
        .accessibilityIdentifier("screenshots.panel")
    }

    private var screenshotList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                    RecentScreenshotRow(
                        item: item,
                        index: index
                    )
                }
            }
            .padding(10)
        }
    }

    private func panelMessage(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(ToastyTheme.fontMonoHeader)
                .foregroundStyle(ToastyTheme.primaryText)
            Text(body)
                .font(ToastyTheme.fontSubtext)
                .foregroundStyle(ToastyTheme.inactiveText)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }
}

private struct RecentScreenshotRow: View {
    let item: RecentScreenshotItem
    let index: Int

    private static let previewHeight: CGFloat = 220
    private static let thumbnailCache = NSCache<NSString, NSImage>()
    private static let thumbnailScaleFactor: CGFloat = 2

    @State private var previewImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail

            Text(item.capturedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(ToastyTheme.fontBody)
                .foregroundStyle(ToastyTheme.primaryText)

            Text(item.displayName)
                .font(ToastyTheme.fontWorkspaceSubtitle)
                .foregroundStyle(ToastyTheme.inactiveText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(ToastyTheme.elevatedBackground)
        .overlay(
            Rectangle()
                .stroke(ToastyTheme.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(object: item.fileURL as NSURL)
        }
        .accessibilityIdentifier("screenshots.row.\(index)")
        .task(id: item.id) {
            await loadPreviewImageIfNeeded()
        }
    }

    private var thumbnail: some View {
        ZStack {
            Rectangle()
                .fill(ToastyTheme.chromeBackground)

            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ToastyTheme.inactiveText)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: Self.previewHeight,
            maxHeight: Self.previewHeight,
            alignment: .center
        )
        .overlay(
            Rectangle()
                .stroke(ToastyTheme.hairline, lineWidth: 1)
        )
    }

    @MainActor
    private func loadPreviewImageIfNeeded() async {
        guard previewImage == nil else { return }
        let cacheKey = thumbnailCacheKey
        if let cachedThumbnail = Self.thumbnailCache.object(forKey: cacheKey) {
            previewImage = cachedThumbnail
            return
        }

        let fileURL = item.fileURL
        let thumbnailScaleFactor = Self.thumbnailScaleFactor
        let thumbnailMaxPixelSize = Int(Self.previewHeight * thumbnailScaleFactor)
        let thumbnailImage = await Task.detached(priority: .utility) {
            Self.loadThumbnailImage(
                fileURL: fileURL,
                maxPixelSize: thumbnailMaxPixelSize,
                scaleFactor: thumbnailScaleFactor
            )
        }.value
        guard Task.isCancelled == false else { return }
        if let thumbnailImage {
            Self.thumbnailCache.setObject(thumbnailImage, forKey: cacheKey)
        }
        previewImage = thumbnailImage
    }

    private var thumbnailCacheKey: NSString {
        NSString(string: "\(item.id)#\(item.contentModifiedAt.timeIntervalSinceReferenceDate)")
    }

    nonisolated private static func loadThumbnailImage(
        fileURL: URL,
        maxPixelSize: Int,
        scaleFactor: CGFloat
    ) -> NSImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions as CFDictionary) else {
            return NSImage(contentsOf: fileURL)
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        guard let cgThumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            return NSImage(contentsOf: fileURL)
        }

        let normalizedScaleFactor = max(1, scaleFactor)
        let pointSize = NSSize(
            width: CGFloat(cgThumbnail.width) / normalizedScaleFactor,
            height: CGFloat(cgThumbnail.height) / normalizedScaleFactor
        )
        return NSImage(
            cgImage: cgThumbnail,
            size: pointSize
        )
    }
}
