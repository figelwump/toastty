import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// One image attached to a user's message, as a chat names it: its path on
/// the host, and the message and place in the message's list of files
/// that a device asks the host for.
public struct ToasttyAttachedImage: Hashable, Identifiable, Sendable {
    /// The file's path on the host, as Toastty wrote it in the message.
    public let url: URL
    /// The message's conversation and event. `nil` for a message that is
    /// still sending, which has no event yet.
    public let conversationID: UUID?
    public let eventID: String?
    /// The file's place in the message's list of files, from 0.
    public let index: Int

    public var id: Self { self }
    public var name: String { url.lastPathComponent }

    public init(url: URL, conversationID: UUID?, eventID: String?, index: Int) {
        self.url = url
        self.conversationID = conversationID
        self.eventID = eventID
        self.index = index
    }
}

/// Where a chat's bubbles get the images attached to messages. The Mac's
/// chat reads the files on the Mac (`localFiles`); a device's chat asks
/// the Mac for them (`remote`).
public struct ToasttyAttachmentImageSource: Sendable {
    public enum Size: String, Hashable, Sendable {
        /// For the image's box in the bubble.
        case thumbnail
        /// For the full-screen view.
        case full
    }

    /// The images come over the network: a box says that it loads, and
    /// loads only while it is on screen.
    public let isRemote: Bool
    fileprivate let cacheKey: @Sendable (ToasttyAttachedImage, Size, Int) -> String?
    fileprivate let load: @Sendable (ToasttyAttachedImage, Size, Int) async -> ToasttyAttachmentImage?

    /// The files on this device, read with ImageIO.
    public static let localFiles = ToasttyAttachmentImageSource(
        isRemote: false,
        cacheKey: { image, _, pixelSize in "\(pixelSize):\(image.url.path)" },
        load: { image, _, pixelSize in
            guard let source = CGImageSourceCreateWithURL(image.url as CFURL, nil) else { return nil }
            return ToasttyAttachmentImage.decode(source, maximumPixelSize: pixelSize)
        }
    )

    /// Images that `fetch` gets from the host, as JPEG or PNG data, by the
    /// message and the place of the file in it. `fetch` returns `nil` when
    /// the host does not have the image or cannot be reached; the box then
    /// shows the file's name, and asks again when it shows again.
    public static func remote(
        fetch: @escaping @Sendable (_ image: ToasttyAttachedImage, _ size: Size) async -> Data?
    ) -> ToasttyAttachmentImageSource {
        ToasttyAttachmentImageSource(
            isRemote: true,
            cacheKey: { image, size, _ in
                guard let conversationID = image.conversationID, let eventID = image.eventID else { return nil }
                return "remote:\(conversationID.uuidString):\(eventID):\(image.index):\(size.rawValue)"
            },
            load: { image, size, pixelSize in
                // A few at a time, so a long chat does not fill the host's
                // read slots.
                guard let data = await ToasttyAttachmentFetchGate.shared.run({ await fetch(image, size) }),
                      let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                return ToasttyAttachmentImage.decode(source, maximumPixelSize: pixelSize)
            }
        )
    }
}

/// An image read or fetched for a chat, decoded off the main thread.
public struct ToasttyAttachmentImage: @unchecked Sendable {
    public let image: CGImage
    public var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    static func decode(_ source: CGImageSource, maximumPixelSize: Int) -> ToasttyAttachmentImage? {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { return nil }
        return ToasttyAttachmentImage(image: image)
    }
}

/// The images a chat loaded, kept while the transcript scrolls its rows
/// out and back in, and the loads under way, so that two boxes, or a box
/// and the full-screen view, never load the same image twice at once. A
/// load stops when no view waits for it any more, such as a box that
/// scrolled away before its image came.
@MainActor
public enum ToasttyAttachmentImageStore {
    private final class Box: NSObject {
        let image: ToasttyAttachmentImage
        init(_ image: ToasttyAttachmentImage) { self.image = image }
    }

    /// One load under way, and the views that wait for it.
    @MainActor
    private final class Load {
        let id = UUID()
        var task: Task<ToasttyAttachmentImage?, Never>?
        var waiters: Set<UUID> = []
    }

    private static let thumbnails: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 64
        return cache
    }()

    private static var loads: [String: Load] = [:]

    /// The image, from the cache or loaded now; `nil` when it cannot be
    /// read now, or when the calling view went away. A thumbnail stays in
    /// the cache; a full-size image does not, as it can take tens of
    /// megabytes.
    public static func image(
        for image: ToasttyAttachedImage,
        size: ToasttyAttachmentImageSource.Size,
        maximumPixelSize: Int,
        source: ToasttyAttachmentImageSource
    ) async -> ToasttyAttachmentImage? {
        guard let key = source.cacheKey(image, size, maximumPixelSize) else { return nil }
        if let cached = thumbnails.object(forKey: key as NSString) { return cached.image }
        let load = loads[key] ?? startLoad(key: key, image: image, size: size, maximumPixelSize: maximumPixelSize, source: source)
        let waiter = UUID()
        load.waiters.insert(waiter)
        guard let task = load.task else { return nil }
        let loaded = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor in leave(key, load, waiter) }
        }
        leave(key, load, waiter)
        return loaded
    }

    /// The thumbnail that a box has loaded, if it is still cached. The
    /// full-screen view shows it while the full image loads.
    public static func cachedThumbnail(
        for image: ToasttyAttachedImage,
        maximumPixelSize: Int,
        source: ToasttyAttachmentImageSource
    ) -> ToasttyAttachmentImage? {
        guard let key = source.cacheKey(image, .thumbnail, maximumPixelSize) else { return nil }
        return thumbnails.object(forKey: key as NSString)?.image
    }

    private static func startLoad(
        key: String,
        image: ToasttyAttachedImage,
        size: ToasttyAttachmentImageSource.Size,
        maximumPixelSize: Int,
        source: ToasttyAttachmentImageSource
    ) -> Load {
        let load = Load()
        let id = load.id
        load.task = Task { @MainActor () -> ToasttyAttachmentImage? in
            let work = Task.detached(priority: .utility) { await source.load(image, size, maximumPixelSize) }
            let loaded = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            if loads[key]?.id == id { loads[key] = nil }
            if let loaded, size == .thumbnail, Task.isCancelled == false {
                thumbnails.setObject(Box(loaded), forKey: key as NSString)
            }
            return loaded
        }
        loads[key] = load
        return load
    }

    /// A view stopped waiting. When it was the last one, the load stops.
    private static func leave(_ key: String, _ load: Load, _ waiter: UUID) {
        guard load.waiters.remove(waiter) != nil, load.waiters.isEmpty, loads[key]?.id == load.id else { return }
        loads[key] = nil
        load.task?.cancel()
    }
}

/// Lets a few fetches run at a time; the others wait their turn. A fetch
/// whose caller is cancelled while it waits leaves the line and never runs.
actor ToasttyAttachmentFetchGate {
    static let shared = ToasttyAttachmentFetchGate(limit: 3)

    private let limit: Int
    private var running = 0
    private var waiting: [(id: UUID, turn: CheckedContinuation<Bool, Never>)] = []

    init(limit: Int) { self.limit = limit }

    func run<Value: Sendable>(_ work: @Sendable () async -> Value?) async -> Value? {
        if running < limit {
            running += 1
        } else {
            let id = UUID()
            let admitted = await withTaskCancellationHandler {
                await withCheckedContinuation { (turn: CheckedContinuation<Bool, Never>) in
                    waiting.append((id, turn))
                }
            } onCancel: {
                Task { await self.leaveLine(id) }
            }
            guard admitted else { return nil }
        }
        defer { passTurn() }
        guard Task.isCancelled == false else { return nil }
        return await work()
    }

    private func leaveLine(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).turn.resume(returning: false)
    }

    /// The slot passes to the next in line, or frees.
    private func passTurn() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().turn.resume(returning: true) }
    }
}

private struct ToasttyAttachmentImageSourceKey: EnvironmentKey {
    static let defaultValue = ToasttyAttachmentImageSource.localFiles
}

private struct ToasttyOpenAttachedImageKey: EnvironmentKey {
    static var defaultValue: (@MainActor (ToasttyAttachedImage) -> Void)? { nil }
}

public extension EnvironmentValues {
    /// Where the chat's bubbles get attached images. The files on this
    /// device by default.
    var toasttyAttachmentImageSource: ToasttyAttachmentImageSource {
        get { self[ToasttyAttachmentImageSourceKey.self] }
        set { self[ToasttyAttachmentImageSourceKey.self] = newValue }
    }

    /// Opens an attached image full size. With it, a loaded thumbnail is
    /// a button; without it, as on the Mac, a thumbnail does nothing.
    var toasttyOpenAttachedImage: (@MainActor (ToasttyAttachedImage) -> Void)? {
        get { self[ToasttyOpenAttachedImageKey.self] }
        set { self[ToasttyOpenAttachedImageKey.self] = newValue }
    }
}

/// The message whose files a bubble shows: a device asks the host for an
/// image by it.
struct ToasttyAttachedMessage: Hashable {
    let conversationID: UUID
    let eventID: String
}

/// The files sent with a user's message, in its bubble: an image as a
/// thumbnail, or as its name when it cannot be read now, and any other
/// file as its icon and name. The host gives their paths; the environment's
/// `toasttyAttachmentImageSource` reads the images.
struct ToasttyMessageAttachments: View {
    let urls: [URL]
    /// The message, for a source that asks the host. `nil` while the
    /// message sends.
    var message: ToasttyAttachedMessage?

    var body: some View {
        ToasttyFlowLayout(spacing: 6) {
            ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                ToasttyMessageAttachment(image: ToasttyAttachedImage(
                    url: url, conversationID: message?.conversationID, eventID: message?.eventID, index: index
                ))
            }
        }
    }
}

private struct ToasttyMessageAttachment: View {
    static var thumbnailSize: CGSize { ToasttyAttachmentThumbnailMetrics.size }

    let image: ToasttyAttachedImage
    @Environment(\.displayScale) private var displayScale
    @Environment(\.toasttyAttachmentImageSource) private var source
    @Environment(\.toasttyOpenAttachedImage) private var openImage
    @State private var thumbnail: ToasttyAttachmentImage?
    @State private var isUnreadable = false
    /// Whether the box is in the transcript's visible area, for a source
    /// that loads only then.
    @State private var isOnScreen = false

    private var name: String { image.name }
    private var isImage: Bool { UTType(filenameExtension: image.url.pathExtension)?.conforms(to: .image) == true }
    private var loadsNow: Bool { source.isRemote == false || isOnScreen }

    var body: some View {
        if isImage {
            thumbnailButton
                .modifier(ToasttyOnScreenTracking(isEnabled: source.isRemote, isOnScreen: $isOnScreen))
                .task(id: LoadRequest(image: image, loadsNow: loadsNow)) { await load() }
        } else {
            fileChip
        }
    }

    private struct LoadRequest: Equatable {
        let image: ToasttyAttachedImage
        let loadsNow: Bool
    }

    @ViewBuilder
    private var thumbnailButton: some View {
        if let openImage, thumbnail != nil {
            Button { openImage(image) } label: { thumbnailView }
                .buttonStyle(.plain)
                .modifier(accessibility)
                .accessibilityHint("Shows the image full size")
        } else {
            thumbnailView
                .accessibilityElement()
                .modifier(accessibility)
        }
    }

    private var accessibility: ToasttyAttachmentAccessibility {
        ToasttyAttachmentAccessibility(name: name, value: accessibilityState, index: image.index)
    }

    private var thumbnailView: some View {
        ZStack {
            Color.black.opacity(0.25)
            if let thumbnail {
                Image(decorative: thumbnail.image, scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if isUnreadable {
                // The image is gone, or is not one that this device reads,
                // or the host cannot be reached now.
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .foregroundStyle(ConversationDesignTokens.mutedText)
                    Text(name)
                        .conversationFont(.caption)
                        .foregroundStyle(ConversationDesignTokens.userBubbleText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                }
                .padding(8)
            } else if source.isRemote {
                // The box has its final size already; only its content
                // changes when the image comes.
                Text("Loading…")
                    .conversationFont(.caption)
                    .foregroundStyle(ConversationDesignTokens.mutedText)
            }
        }
        .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(ConversationDesignTokens.userBubbleBorder)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(name)
    }

    private var accessibilityState: String {
        if thumbnail != nil { return "" }
        if isUnreadable { return "Not available" }
        return source.isRemote ? "Loading" : ""
    }

    private var fileChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc")
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
        guard thumbnail == nil, loadsNow else { return }
        let pixelSize = ToasttyAttachmentThumbnailMetrics.pixelSize(displayScale: displayScale)
        let loaded = await ToasttyAttachmentImageStore.image(
            for: image, size: .thumbnail, maximumPixelSize: pixelSize, source: source)
        guard Task.isCancelled == false else { return }
        if let loaded {
            thumbnail = loaded
            isUnreadable = false
        } else {
            isUnreadable = true
        }
    }
}

public enum ToasttyAttachmentThumbnailMetrics {
    /// Every image takes this box, before and after it loads and also when
    /// it cannot be read, so a row of the transcript keeps its size. The
    /// image fits inside it.
    public static let size = CGSize(width: 200, height: 120)

    /// The pixel size of the image that a box asks for: the full-screen
    /// view finds the box's thumbnail by it.
    public static func pixelSize(displayScale: CGFloat) -> Int {
        Int(max(size.width, size.height) * displayScale)
    }
}

private struct ToasttyAttachmentAccessibility: ViewModifier {
    let name: String
    let value: String
    let index: Int

    func body(content: Content) -> some View {
        content
            .accessibilityLabel("Image \(name)")
            .accessibilityValue(value)
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("toastty-attachment-image-\(index)")
    }
}

/// Tracks whether a view is in its scroll view's visible area. Before
/// macOS 15 the view counts as always on screen.
private struct ToasttyOnScreenTracking: ViewModifier {
    let isEnabled: Bool
    @Binding var isOnScreen: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            if #available(macOS 15.0, iOS 18.0, *) {
                content.onScrollVisibilityChange(threshold: 0.01) { isOnScreen = $0 }
            } else {
                content.onAppear { isOnScreen = true }
            }
        } else {
            content
        }
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
