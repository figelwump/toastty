import Foundation
import RemoteProtocol
import Testing

struct RemoteProtocolBoundaryTests {
    @Test func sharedModuleImportsFoundationOnly() throws {
        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RemoteProtocol", isDirectory: true)

        let sourceFiles = try FileManager.default.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        #expect(sourceFiles.isEmpty == false)
        for sourceFile in sourceFiles {
            let source = try String(contentsOf: sourceFile, encoding: .utf8)
            let importedModules = source.split(separator: "\n").compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("import ") {
                    return String(trimmed.dropFirst("import ".count))
                }
                if trimmed.hasPrefix("@_exported import ") {
                    return String(trimmed.dropFirst("@_exported import ".count))
                }
                return nil
            }
            #expect(
                importedModules == ["Foundation"],
                "\(sourceFile.lastPathComponent) must remain Foundation-only"
            )
        }
    }

    @Test func deviceSummaryScopesHaveStableWireOrder() {
        let summary = RemoteGatewayDeviceSummary(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            name: "Phone",
            scopes: [.send, .approve, .read]
        )

        #expect(summary.scopes == [.approve, .read, .send])
    }

    @Test func pendingInteractionPreviewPreservesComplexEmojiGraphemes() throws {
        let prompt = "Review 👩🏽‍💻 and family 👨‍👩‍👧‍👦 plus text ✈️"
        let preview = RemotePendingInteractionPreview(prompt: prompt)
        #expect(preview.prompt == prompt)

        let data = try ConversationEventCoding.makeEncoder().encode(preview)
        let decoded = try ConversationEventCoding.makeDecoder().decode(
            RemotePendingInteractionPreview.self,
            from: data
        )
        #expect(decoded == preview)

        let grapheme = "👩🏽‍💻"
        let bounded = RemotePendingInteractionPreview(
            prompt: String(repeating: grapheme, count: RemotePendingInteractionPreview.maximumPromptLength + 1)
        )
        #expect(bounded.prompt.count == RemotePendingInteractionPreview.maximumPromptLength)
        #expect(bounded.prompt == String(repeating: grapheme, count: RemotePendingInteractionPreview.maximumPromptLength))
    }

    @Test func pendingInteractionPreviewStripsAndRejectsActualControls() throws {
        let sanitized = RemotePendingInteractionPreview(
            prompt: "before\u{0000}middle\u{001F}after\u{007F}end\u{0085}"
        )
        #expect(sanitized.prompt == "beforemiddleafterend")

        for control in ["\u{0000}", "\u{001F}", "\u{007F}", "\u{0085}"] {
            let data = try JSONSerialization.data(withJSONObject: ["prompt": "before\(control)after"])
            #expect(throws: DecodingError.self) {
                try ConversationEventCoding.makeDecoder().decode(
                    RemotePendingInteractionPreview.self,
                    from: data
                )
            }
        }
    }

    @Test func pendingInteractionPreviewRejectsSpoofingFormatScalarsWithoutBreakingEmoji() throws {
        let family = "👨‍👩‍👧‍👦"
        let profession = "👩🏽‍💻"
        let sanitized = RemotePendingInteractionPreview(
            prompt: "safe\u{200B}text\u{202E}end \(family) \(profession)"
        )
        #expect(sanitized.prompt == "safetextend \(family) \(profession)")

        for spoofingScalar in ["\u{200B}", "\u{202E}"] {
            let data = try JSONSerialization.data(
                withJSONObject: ["prompt": "safe\(spoofingScalar)text \(family) \(profession)"]
            )
            #expect(throws: DecodingError.self) {
                try ConversationEventCoding.makeDecoder().decode(
                    RemotePendingInteractionPreview.self,
                    from: data
                )
            }
        }

        let validData = try ConversationEventCoding.makeEncoder().encode(
            RemotePendingInteractionPreview(prompt: "\(family) \(profession)")
        )
        let decoded = try ConversationEventCoding.makeDecoder().decode(
            RemotePendingInteractionPreview.self,
            from: validData
        )
        #expect(decoded.prompt == "\(family) \(profession)")
    }
}
