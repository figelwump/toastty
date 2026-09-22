import CoreTransferable
import Foundation
import ImageIO
import RemoteProtocol
import UniformTypeIdentifiers

struct ToasttyAttachmentPhoto: Transferable, Sendable {
    let attachment: RemoteMessageAttachment

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            let attachment = try await Task.detached(priority: .userInitiated) {
                try ToasttyAttachmentLoader.photo(at: file.file)
            }.value
            return Self(attachment: attachment)
        }
    }
}

enum ToasttyAttachmentLoader {
    enum ImportError: LocalizedError {
        case unsupported, tooLarge, unreadable, invalidImage

        var errorDescription: String? {
            switch self {
            case .unsupported: "Choose an image, PDF, text, or source file."
            case .tooLarge: "This file is too large. Choose a file under 4 MB, or a smaller photo."
            case .unreadable: "This file could not be read. Download it to your iPhone and try again."
            case .invalidImage: "This photo could not be prepared. Choose another photo."
            }
        }
    }

    static func file(at url: URL) throws -> RemoteMessageAttachment {
        if ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif"].contains(url.pathExtension.lowercased()) {
            return try photo(at: url)
        }
        guard RemoteAttachmentPolicy.supportedFilename(url.lastPathComponent) else {
            throw ImportError.unsupported
        }
        let data = try readRegularFile(at: url, maximumBytes: RemoteAttachmentPolicy.maximumFileBytes)
        return RemoteMessageAttachment(filename: url.lastPathComponent, data: data)
    }

    static func photo(at url: URL) throws -> RemoteMessageAttachment {
        // Bound the source as well as the encoded output. ImageIO downsamples
        // before decoding so a full-resolution photo does not enter draft memory.
        let data = try readRegularFile(at: url, maximumBytes: 32 * 1024 * 1024)
        return try photo(data: data)
    }

    static func photo(data: Data) throws -> RemoteMessageAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ImportError.invalidImage }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImportError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImportError.invalidImage }
        guard encoded.length <= RemoteAttachmentPolicy.maximumFileBytes else { throw ImportError.tooLarge }
        return RemoteMessageAttachment(filename: "Photo-\(UUID().uuidString.prefix(8)).jpg", data: encoded as Data)
    }

    private static func readRegularFile(at url: URL, maximumBytes: Int) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw ImportError.unreadable
        }
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
            result = Result { try boundedRead(at: coordinatedURL, maximumBytes: maximumBytes) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ImportError.unreadable }
        return try result.get()
    }

    private static func boundedRead(at url: URL, maximumBytes: Int) throws -> Data {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
              properties.isPackage != true else { throw ImportError.unreadable }
        guard let size = properties.fileSize, size <= maximumBytes else { throw ImportError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Read no more than the limit even if a provider reports stale metadata.
        var data = Data()
        while data.count <= maximumBytes {
            let chunk = try handle.read(upToCount: min(64 * 1024, maximumBytes + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw ImportError.tooLarge }
        guard data.isEmpty == false else { throw ImportError.unreadable }
        return data
    }
}
