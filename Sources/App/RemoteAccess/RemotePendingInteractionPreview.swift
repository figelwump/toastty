import Foundation
import RemoteProtocol

/// Produces the intentionally small, read-only hint shown in a session-list
/// row. It never leaves the gateway response path and must not be copied into
/// audit entries, logs, diagnostics, or accessibility metadata on the Mac.
enum RemotePendingInteractionPreviewFormatter {
    static let maximumGraphemeCount = 120

    static func make(
        from interactions: [RemotePendingInteraction],
        maximumGraphemeCount: Int = maximumGraphemeCount
    ) -> RemotePendingInteractionPreview? {
        guard maximumGraphemeCount > 0,
              let interaction = interactions.first(where: { $0.state == .pending }) else {
            return nil
        }

        let normalized = interaction.prompt
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard normalized.isEmpty == false else { return nil }
        guard normalized.count > maximumGraphemeCount else {
            return RemotePendingInteractionPreview(prompt: normalized)
        }
        let prompt: String
        if maximumGraphemeCount == 1 {
            prompt = "…"
        } else {
            prompt = String(normalized.prefix(maximumGraphemeCount - 1)) + "…"
        }
        return RemotePendingInteractionPreview(prompt: prompt)
    }
}
