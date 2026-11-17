#if DEBUG
import Foundation
import RemoteProtocol
import UIKit

/// A draft as the share extension would save it, for UI tests that cannot
/// drive another app's share sheet.
enum ToasttySharedDraftFixture {
    enum Handoff: String {
        /// Only the draft's link opens it.
        case link
        /// The app opens it on its own, as when the link did not open it.
        case waiting
    }

    static let draftID = UUID(uuidString: "5A4E0D2A-0000-4000-8000-000000000001")!

    /// Starts every fixture launch without drafts, then saves the fixture
    /// draft when a test asks for one.
    static func seed(_ store: ToasttySharedDraftStore, handoff: Handoff?) {
        try? FileManager.default.removeItem(at: store.directory)
        guard let handoff else { return }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        let draft = ToasttySharedDraft(
            id: draftID,
            createdAt: Date(),
            text: "Toastty fixture page\nhttps://example.com/toastty",
            attachments: [RemoteMessageAttachment(filename: "Shared screenshot.png", data: image)],
            skippedItemCount: 1
        )
        try? store.save(draft)
        if handoff == .waiting { try? store.markWaiting(id: draftID) }
    }
}
#endif
