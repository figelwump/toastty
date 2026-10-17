import Foundation
import RemoteProtocol
import UniformTypeIdentifiers

/// Reads what another app put in the share sheet into a draft for a new
/// session: images, PDFs, and text files become attachments, and links and
/// plain text become the message.
@MainActor
enum ToasttyShareImporter {
    private enum Content: Sendable {
        case attachment(RemoteMessageAttachment)
        case text(String)
        case unusable
    }

    static func makeDraft(
        from items: [NSExtensionItem],
        id: UUID = UUID(),
        now: Date = Date()
    ) async -> ToasttySharedDraft {
        var paragraphs: [String] = []
        var attachments: [RemoteMessageAttachment] = []
        var skippedItemCount = 0
        for item in items {
            var lines: [String] = []
            for provider in item.attachments ?? [] {
                switch await content(of: provider) {
                case .attachment(let attachment):
                    // Keep what the Mac accepts in one message and leave out
                    // the rest, rather than a draft that cannot start.
                    if RemoteAttachmentPolicy.validationError(for: attachments + [attachment]) == nil {
                        attachments.append(attachment)
                    } else {
                        skippedItemCount += 1
                    }
                case .text(let text):
                    if lines.contains(text) == false { lines.append(text) }
                case .unusable:
                    skippedItemCount += 1
                }
            }
            // Safari and other apps describe a shared link with its title.
            if let caption = (item.attributedContentText ?? item.attributedTitle)?.string
                .trimmingCharacters(in: .whitespacesAndNewlines),
               caption.isEmpty == false, lines.contains(caption) == false {
                lines.insert(caption, at: 0)
            }
            if lines.isEmpty == false { paragraphs.append(lines.joined(separator: "\n")) }
        }
        return ToasttySharedDraft(
            id: id,
            createdAt: now,
            text: paragraphs.joined(separator: "\n\n"),
            attachments: attachments,
            skippedItemCount: skippedItemCount
        )
    }

    /// Tries each representation in turn and falls through when one does
    /// not load.
    private static func content(of provider: NSItemProvider) async -> Content {
        let types = provider.registeredContentTypes
        if let image = types.first(where: { $0.conforms(to: .image) }),
           let attachment = await photo(from: provider, type: image) {
            return .attachment(attachment)
        }
        if let pdf = types.first(where: { $0.conforms(to: .pdf) }),
           let attachment = await file(from: provider, type: pdf) {
            return .attachment(attachment)
        }
        // A link comes before text: some apps add the page title as named text.
        if types.contains(where: { $0.conforms(to: .url) }),
           let url = await loadObject(URL.self, from: provider) {
            if url.isFileURL == false { return .text(url.absoluteString) }
            if let attachment = try? ToasttyAttachmentLoader.file(at: url) { return .attachment(attachment) }
        }
        // Named text is a file, such as one from Files. Text without a name,
        // such as a selection, goes in the message.
        if provider.suggestedName != nil,
           let text = types.first(where: {
               $0.conforms(to: .text) && RemoteAttachmentPolicy.supportedFilename(filename(for: provider, type: $0))
           }),
           let attachment = await file(from: provider, type: text) {
            return .attachment(attachment)
        }
        if types.contains(where: { $0.conforms(to: .plainText) }),
           let text = await loadObject(String.self, from: provider)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           text.isEmpty == false {
            return .text(text)
        }
        return .unusable
    }

    private static func photo(from provider: NSItemProvider, type: UTType) async -> RemoteMessageAttachment? {
        let filename = provider.suggestedName.map { ($0 as NSString).deletingPathExtension + ".jpg" }
        var attachment = await loadFile(from: provider, type: type) { url in
            try ToasttyAttachmentLoader.photo(at: url)
        }
        // Some apps share an image only as data, such as an edited screenshot.
        if attachment == nil {
            attachment = await loadData(from: provider, type: type) { try ToasttyAttachmentLoader.photo(data: $0) }
        }
        if let filename, RemoteAttachmentPolicy.supportedFilename(filename) { attachment?.filename = filename }
        return attachment
    }

    private static func file(from provider: NSItemProvider, type: UTType) async -> RemoteMessageAttachment? {
        let derivedFilename = filename(for: provider, type: type)
        let hasSuggestedName = provider.suggestedName != nil
        return await loadFile(from: provider, type: type) { url in
            // Without a suggested name, keep the copy's own name when it
            // names this type, rather than a temporary name like copy.tmp.
            let namesType = UTType(filenameExtension: url.pathExtension)?.conforms(to: type) == true
            let filename = hasSuggestedName || namesType == false ? derivedFilename : url.lastPathComponent
            return try ToasttyAttachmentLoader.file(at: url, filename: filename)
        }
    }

    private static func filename(for provider: NSItemProvider, type: UTType) -> String {
        let name = provider.suggestedName ?? "Shared"
        guard (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension else { return name }
        return "\(name).\(ext)"
    }

    // The provider deletes a file representation when its handler returns,
    // so each conversion runs inside the handler, off the main actor.

    private static func loadFile(
        from provider: NSItemProvider,
        type: UTType,
        convert: @escaping @Sendable (URL) throws -> RemoteMessageAttachment
    ) async -> RemoteMessageAttachment? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                continuation.resume(returning: url.flatMap { try? convert($0) })
            }
        }
    }

    private static func loadData(
        from provider: NSItemProvider,
        type: UTType,
        convert: @escaping @Sendable (Data) throws -> RemoteMessageAttachment
    ) async -> RemoteMessageAttachment? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data.flatMap { try? convert($0) })
            }
        }
    }

    private static func loadObject<Object: _ObjectiveCBridgeable & Sendable>(
        _ type: Object.Type,
        from provider: NSItemProvider
    ) async -> Object? where Object._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { object, _ in
                continuation.resume(returning: object)
            }
        }
    }
}
