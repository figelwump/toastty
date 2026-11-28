import Foundation

/// The Linux parts of `DraftAttachments` (macOS: `DraftAttachments+Mac.swift`).
///
/// No preview is made here: the GTK attachment chip scales the image file
/// itself (`gdk_pixbuf_new_from_file_at_scale`). Paste and drop read the GTK
/// clipboard and drop values in the frontend, which then calls
/// `attachFiles`, `attachImageData` or `attachText`.
typealias AttachmentThumbnail = Never

extension DraftAttachments {
    static let imageFileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg", "avif",
    ]

    /// Whether a file is an image, by its extension.
    static func isImage(_ url: URL) -> Bool {
        imageFileExtensions.contains(url.pathExtension.lowercased())
    }

    static func thumbnail(of url: URL) -> AttachmentThumbnail? { nil }

    /// The frontend hands PNG bytes (`gdk_texture_save_to_png_bytes`); any
    /// other data is refused.
    static func pngData(fromImageData data: Data) -> Data? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        return data.starts(with: signature) ? data : nil
    }
}
