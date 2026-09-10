import RemoteProtocol
import SwiftUI

struct ToasttySessionExecutionProfilePresentation: Equatable {
    let text: String
    let accessibilityLabel: String

    init?(profile: RemoteSessionExecutionProfile?, isLastReported: Bool) {
        guard let profile, !profile.isEmpty else { return nil }
        let values = [
            profile.modelIdentifier,
            profile.reasoningEffort.map { "\($0) reasoning" },
        ].compactMap { $0 }
        let labels = [
            profile.modelIdentifier.map { "Model: \($0)" },
            profile.reasoningEffort.map { "Reasoning: \($0)" },
        ].compactMap { $0 }
        text = (isLastReported ? "Last reported · " : "") + values.joined(separator: " · ")
        accessibilityLabel = (isLastReported ? "Last reported. " : "") + labels.joined(separator: ". ")
    }
}

struct ToasttySessionExecutionProfileView: View {
    let presentation: ToasttySessionExecutionProfilePresentation

    var body: some View {
        Text(presentation.text)
            .font(.caption)
            .foregroundStyle(ToasttyDesignTokens.secondaryText)
            // This inset shares the screen with the keyboard and composer
            // notices. VoiceOver still receives the complete reported values.
            .lineLimit(2)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityIdentifier("toastty-mobile-session-execution-profile")
    }
}
