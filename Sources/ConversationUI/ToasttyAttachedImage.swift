import Foundation

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

/// The message whose files a bubble shows: a device asks the host for an
/// image by it.
struct ToasttyAttachedMessage: Hashable {
    let conversationID: UUID
    let eventID: String
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
