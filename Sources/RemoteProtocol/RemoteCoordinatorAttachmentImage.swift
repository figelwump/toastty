import Foundation

/// A device's request for one image attached to one user message in the
/// coordinator's chat.
///
/// The device names the image by the message and its place in the
/// message's list of files, never by a path: the Mac finds the path itself,
/// in its own copy of that message, with the parser that the Mac's chat
/// uses (`CoordinatorMessageHeader.displayParts(of:)`). So a device can
/// read only an image that a user message of the coordinator's chat names.
public struct RemoteCoordinatorAttachmentImageRequest: Codable, Equatable, Sendable {
    /// How large an image the device asks for. The Mac scales the image
    /// down to fit `maximumPixelSize` on its long side, never up.
    public enum Size: String, Codable, Sendable {
        /// For the image's box in the message's bubble.
        case thumbnail
        /// For the full-screen view.
        case full

        public var maximumPixelSize: Int {
            switch self {
            case .thumbnail: RemoteCoordinatorAttachmentImagePolicy.thumbnailMaximumPixelSize
            case .full: RemoteCoordinatorAttachmentImagePolicy.fullMaximumPixelSize
            }
        }
    }

    public var protocolVersion: String
    /// The coordinator's conversation. The Mac refuses any other.
    public var conversationID: RemoteConversationID
    /// The user message that lists the file.
    public var eventID: String
    /// The file's place in the message's list of files, from 0. The list
    /// holds every attached file, images and others, in the order that
    /// `CoordinatorMessageHeader.displayParts(of:)` gives.
    public var attachmentIndex: Int
    public var size: Size

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        conversationID: RemoteConversationID,
        eventID: String,
        attachmentIndex: Int,
        size: Size
    ) {
        self.protocolVersion = protocolVersion
        self.conversationID = conversationID
        self.eventID = eventID
        self.attachmentIndex = attachmentIndex
        self.size = size
    }

    public var isValid: Bool {
        eventID.isEmpty == false
            && eventID.utf8.count <= RemoteCoordinatorAttachmentImagePolicy.maximumEventIDBytes
            && attachmentIndex >= 0
    }
}

/// The Mac's answer: the image, made again by the Mac as a JPEG or a PNG
/// (never the file's own bytes), or why the Mac refused it.
public struct RemoteCoordinatorAttachmentImageResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String = RemoteGatewayProtocol.version
    /// `image/jpeg` or `image/png`.
    public var mimeType: String?
    /// Codable `Data` is base64 in the JSON.
    public var data: Data?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var error: RemotePreviewError?

    public init(mimeType: String, data: Data, pixelWidth: Int, pixelHeight: Int) {
        self.mimeType = mimeType
        self.data = data
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.error = nil
    }

    public init(error: RemotePreviewError) {
        self.error = error
    }

    private enum CodingKeys: String, CodingKey { case protocolVersion, mimeType, data, pixelWidth, pixelHeight, error }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        data = try container.decodeIfPresent(Data.self, forKey: .data)
        pixelWidth = try container.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decodeIfPresent(Int.self, forKey: .pixelHeight)
        // An error the client does not know reads as `unsupported`.
        error = try container.decodeIfPresent(String.self, forKey: .error)
            .map { RemotePreviewError(rawValue: $0) ?? .unsupported }
        let hasImage = mimeType != nil && data != nil && pixelWidth != nil && pixelHeight != nil
        let hasNoImage = mimeType == nil && data == nil && pixelWidth == nil && pixelHeight == nil
        guard (error == nil && hasImage) || (error != nil && hasNoImage) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected an image or an error"))
        }
    }
}

/// Wire contract for reading an image attached to a message in the
/// coordinator's chat.
public enum RemoteCoordinatorAttachmentImagePolicy {
    public static let path = "/api/coordinator.attachment_image.get"
    /// The long side of a thumbnail. The bubble's box is 200 × 120 points,
    /// and an iPhone draws 3 pixels to a point.
    public static let thumbnailMaximumPixelSize = 600
    /// The long side of the full-screen image.
    public static let fullMaximumPixelSize = 4096
    /// The largest file the Mac reads.
    public static let maximumSourceBytes = 64 * 1024 * 1024
    /// The largest image, in pixels, that the Mac decodes.
    public static let maximumSourcePixels = 100_000_000
    public static let maximumRequestBodyBytes = 4 * 1024
    public static let maximumEventIDBytes = 1024
}
