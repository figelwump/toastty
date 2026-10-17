import CoreTransferable
import Foundation
import RemoteProtocol

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
