import CoreGraphics
import Foundation
import ImageIO
import RemoteProtocol
import UniformTypeIdentifiers

/// Serves a device the images attached to the user messages of the
/// coordinator's chat. This is a boundary of what a device can read on
/// this Mac:
///
/// - The device names a message and a place in its list of files. The path
///   comes from this Mac's own copy of that user message, read with the
///   parser that the Mac's chat uses, so only a file that a user message of
///   the chat lists can be read.
/// - The file must be one that Toastty stored as an attachment: inside one
///   of `allowedFolders` (the coordinator's attachments folder, where the
///   Mac copies the files the user attaches, and the gateway's store of
///   files that devices send). A path that a sender typed into a message
///   cannot reach any other file.
/// - The file must have an image's extension, as the Mac's chat requires
///   to draw a thumbnail, and be a regular file at that path: a symbolic
///   link anywhere in the path is refused, so the path cannot lead to
///   another file.
/// - ImageIO must decode it as an image. The device gets a new JPEG or PNG
///   made from the decoded pixels, never the file's own bytes.
public enum RemoteCoordinatorAttachmentImageReader {
    /// The path of the file at `index` in the list of files of the user
    /// message `eventID`, from `events`, which must be the coordinator's
    /// conversation as this Mac has it.
    public static func attachmentPath(
        in events: [ConversationEvent],
        eventID: String,
        index: Int
    ) throws -> String {
        guard let event = events.last(where: { $0.eventID == eventID }) else {
            // The Mac no longer has the message, or never had it.
            throw RemotePreviewError.missing
        }
        guard case .userMessage(let payload) = event.payload else { throw RemotePreviewError.denied }
        // A message that a device sent with files keeps their paths apart
        // from its text; any other names them in its text.
        let paths = payload.attachmentPaths ?? CoordinatorMessageHeader.displayParts(of: payload.text).attachmentPaths
        guard paths.indices.contains(index) else { throw RemotePreviewError.denied }
        return paths[index]
    }

    /// The image at `recordedPath`, scaled down to `size`, as a new JPEG,
    /// or a PNG when it has transparency. Runs off the main thread: it
    /// reads the file and decodes it.
    public static func image(
        atRecordedPath recordedPath: String,
        size: RemoteCoordinatorAttachmentImageRequest.Size,
        allowedFolders: [URL]
    ) throws -> RemoteCoordinatorAttachmentImageResponse {
        let fileExtension = URL(fileURLWithPath: recordedPath).pathExtension
        guard UTType(filenameExtension: fileExtension)?.conforms(to: .image) == true else {
            throw RemotePreviewError.unsupported
        }
        // The path as written, with no symbolic link in it: the Mac's
        // system aliases (/tmp, /var, /etc) only.
        let path = try RemotePreviewFileReader.authorityPath(recordedPath)
        let insideAllowedFolder = allowedFolders.contains { folder in
            guard let root = try? RemotePreviewFileReader.canonicalPath(folder.path(percentEncoded: false)) else { return false }
            return RemotePreviewFileReader.isWithin(path, root: root)
        }
        guard insideAllowedFolder else { throw RemotePreviewError.denied }
        let snapshot = try RemotePreviewFileReader.read(
            path: path, maximumBytes: RemoteCoordinatorAttachmentImagePolicy.maximumSourceBytes)
        try Task.checkCancellation()
        return try encodedImage(from: snapshot.data, maximumPixelSize: size.maximumPixelSize)
    }

    static func encodedImage(
        from data: Data,
        maximumPixelSize: Int,
        maximumSourcePixels: Int = RemoteCoordinatorAttachmentImagePolicy.maximumSourcePixels
    ) throws -> RemoteCoordinatorAttachmentImageResponse {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              UTType(type)?.conforms(to: .image) == true,
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { throw RemotePreviewError.unsupported }
        // A small file can still decode to more pixels than the Mac should
        // hold in memory.
        guard width.multipliedReportingOverflow(by: height).overflow == false,
              width * height <= maximumSourcePixels
        else { throw RemotePreviewError.tooLarge }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maximumPixelSize, max(width, height)),
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { throw RemotePreviewError.unsupported }
        try Task.checkCancellation()

        let hasAlpha = switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
        let outputType = hasAlpha ? UTType.png : UTType.jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, outputType.identifier as CFString, 1, nil) else {
            throw RemotePreviewError.unsupported
        }
        // No metadata goes along: only the pixels.
        let options: [CFString: Any] = hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.82]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RemotePreviewError.unsupported }
        return RemoteCoordinatorAttachmentImageResponse(
            mimeType: outputType.preferredMIMEType ?? (hasAlpha ? "image/png" : "image/jpeg"),
            data: output as Data,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }
}
