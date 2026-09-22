import Foundation

/// Bytes uploaded privately to the paired Mac for the current conversation.
public struct RemoteMessageAttachment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var filename: String
    public var data: Data

    public init(id: UUID = UUID(), filename: String, data: Data) {
        self.id = id
        self.filename = filename
        self.data = data
    }
}

public enum RemoteAttachmentPolicy {
    public static let maximumCount = 4
    public static let maximumFileBytes = 4 * 1024 * 1024
    public static let maximumTotalBytes = 8 * 1024 * 1024
    public static let maximumEncodedBodyBytes = 12 * 1024 * 1024
    public static let sendPath = "/api/conversation.message.send-with-attachments"
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "toml", "xml",
        "swift", "py", "js", "jsx", "ts", "tsx", "html", "css", "c", "h", "cpp",
        "hpp", "rs", "go", "java", "kt", "rb", "sh", "sql", "log", "ini", "diff", "patch"
    ]

    public static func supportedFilename(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return textExtensions.contains(ext) || ["jpg", "jpeg", "png", "gif", "webp", "pdf"].contains(ext)
    }

    /// Display names are never paths or terminal controls. The Mac generates
    /// independent random disk names even when this name is safe.
    public static func displayFilename(_ filename: String) -> String {
        let basename = (filename as NSString).lastPathComponent
        let clean = basename.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.illegalCharacters.contains(scalar)
                && ![0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069].contains(scalar.value)
        }
        let result = String(String.UnicodeScalarView(clean)).prefix(120)
        return result.isEmpty ? "Attachment" : String(result)
    }

    public static func validationError(for attachments: [RemoteMessageAttachment], validateContents: Bool = true) -> String? {
        guard attachments.count <= maximumCount else { return "Attach up to 4 files." }
        guard Set(attachments.map(\.id)).count == attachments.count else { return "Duplicate attachments are not supported." }
        var total = 0
        for attachment in attachments {
            guard attachment.filename.utf8.count <= 512, supportedFilename(attachment.filename) else {
                return "Choose an image, PDF, or supported text file."
            }
            guard !attachment.data.isEmpty, attachment.data.count <= maximumFileBytes else {
                return "Each attachment must be nonempty and at most 4 MiB."
            }
            total += attachment.data.count
            guard total <= maximumTotalBytes else { return "Attachments must total at most 8 MiB." }
            if !validateContents { continue }
            let bytes = attachment.data
            let ext = (attachment.filename as NSString).pathExtension.lowercased()
            let valid: Bool
            switch ext {
            case "jpg", "jpeg": valid = bytes.starts(with: [0xFF, 0xD8, 0xFF])
            case "png": valid = bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
            case "gif": valid = bytes.starts(with: Data("GIF87a".utf8)) || bytes.starts(with: Data("GIF89a".utf8))
            case "webp": valid = bytes.count >= 12 && bytes.starts(with: Data("RIFF".utf8)) && bytes.dropFirst(8).starts(with: Data("WEBP".utf8))
            case "pdf": valid = bytes.starts(with: Data("%PDF-".utf8))
            default: valid = !bytes.contains(0) && String(data: bytes, encoding: .utf8) != nil
            }
            guard valid else { return "An attachment does not match its file type." }
        }
        return nil
    }
}
