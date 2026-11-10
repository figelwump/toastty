import Foundation

/// UniformTypeIdentifiers subset: the types shared code names, with their
/// preferred filename extensions.
public struct UTType: Hashable, Sendable {
    public let identifier: String
    public let preferredFilenameExtension: String?

    public init(_ identifier: String, preferredFilenameExtension: String? = nil) {
        self.identifier = identifier
        self.preferredFilenameExtension = preferredFilenameExtension
    }

    public init?(filenameExtension: String) {
        self.init("dyn.\(filenameExtension.lowercased())", preferredFilenameExtension: filenameExtension.lowercased())
    }

    public static let data = UTType("public.data")
    public static let text = UTType("public.text", preferredFilenameExtension: "txt")
    public static let plainText = UTType("public.plain-text", preferredFilenameExtension: "txt")
    public static let utf8PlainText = UTType("public.utf8-plain-text", preferredFilenameExtension: "txt")
    public static let json = UTType("public.json", preferredFilenameExtension: "json")
    public static let png = UTType("public.png", preferredFilenameExtension: "png")
    public static let jpeg = UTType("public.jpeg", preferredFilenameExtension: "jpeg")
    public static let html = UTType("public.html", preferredFilenameExtension: "html")
    public static let fileURL = UTType("public.file-url")
    public static let url = UTType("public.url")
    public static let folder = UTType("public.folder")
    public static let directory = UTType("public.directory")
}

extension URL {
    /// Darwin appends the type's preferred extension unless the component
    /// already has one; Linux treats any existing extension as conforming.
    public func appendingPathComponent(_ partialName: String, conformingTo contentType: UTType) -> URL {
        let url = appendingPathComponent(partialName)
        guard url.pathExtension.isEmpty, let ext = contentType.preferredFilenameExtension else { return url }
        return url.appendingPathExtension(ext)
    }
}
