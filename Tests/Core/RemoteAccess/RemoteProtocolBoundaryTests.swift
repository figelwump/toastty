import Foundation
import RemoteProtocol
import Testing

struct RemoteProtocolBoundaryTests {
    @Test func conversationPlacementTabFieldsAreAdditive() throws {
        let legacy = Data(#"{"workspaceTitle":"Workspace"}"#.utf8)
        let decoder = JSONDecoder()
        let old = try decoder.decode(RemoteConversationPlacement.self, from: legacy)
        #expect(old.workspaceTabID == nil)
        #expect(old.workspaceTabTitle == nil)
        let tabID = UUID()
        let placement = RemoteConversationPlacement(
            workspaceTitle: "Workspace", workspaceTabID: tabID,
            workspaceTabTitle: "Navigation 👩🏽‍💻"
        )
        let encoded = try JSONEncoder().encode(placement)
        #expect(try decoder.decode(RemoteConversationPlacement.self, from: encoded) == placement)
        struct LegacyPlacement: Decodable { let workspaceTitle: String? }
        #expect(try decoder.decode(LegacyPlacement.self, from: encoded).workspaceTitle == "Workspace")
        let oldObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        #expect(oldObject["workspaceTabID"] == nil)
        #expect(oldObject["workspaceTabTitle"] == nil)
    }

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

    @Test func statusDetailIsOptionalSafeAndGraphemeBounded() throws {
        let family = "👨‍👩‍👧‍👦"
        let longDetail = String(
            repeating: family,
            count: RemoteConversationSummary.maximumStatusDetailLength + 1
        )
        var summary = Self.makeSummary(statusDetail: "  safe\u{0000}text\u{202E} \(longDetail)  ")

        let expected = String(
            "safetext \(longDetail)".prefix(RemoteConversationSummary.maximumStatusDetailLength)
        )
        #expect(summary.statusDetail == expected)
        #expect(summary.statusDetail?.count == RemoteConversationSummary.maximumStatusDetailLength)
        #expect(RemoteConversationSummary.normalizedStatusDetail(summary.statusDetail) == expected)

        summary.statusDetail = " \n\t "
        #expect(summary.statusDetail == nil)
        let encoded = try ConversationEventCoding.makeEncoder().encode(summary)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["statusDetail"] == nil)
    }

    @Test func statusDetailDecoderFiltersUnsafeWireText() throws {
        let encoder = ConversationEventCoding.makeEncoder()
        let decoder = ConversationEventCoding.makeDecoder()
        let baseline = Self.makeSummary(statusDetail: "placeholder")
        var object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(baseline)) as? [String: Any]
        )
        object["statusDetail"] = "  before\u{0000}middle\u{202E}after  "

        let decoded = try decoder.decode(
            RemoteConversationSummary.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.statusDetail == "beforemiddleafter")
    }

    private static func makeSummary(statusDetail: String?) -> RemoteConversationSummary {
        RemoteConversationSummary(
            conversationID: RemoteConversationID(),
            provider: .codex,
            title: "Boundary",
            state: .working,
            statusDetail: statusDetail,
            inputAvailability: .unavailable(reason: .working),
            latestSequence: 0,
            updatedAt: Date(timeIntervalSince1970: 1_786_000_000)
        )
    }
}

struct RemoteExecutionProfileCodingTests {
    @Test func summaryProfileIsOptionalAndSupportsPartialReports() throws {
        var summary = RemoteConversationSummary(
            conversationID: RemoteConversationID(), provider: .codex, title: "Session",
            state: .starting, inputAvailability: .unavailable(reason: .starting),
            latestSequence: 0, updatedAt: Date(timeIntervalSince1970: 100)
        )
        let encoder = ConversationEventCoding.makeEncoder()
        let decoder = ConversationEventCoding.makeDecoder()
        let oldData = try encoder.encode(summary)
        let oldObject = try #require(JSONSerialization.jsonObject(with: oldData) as? [String: Any])
        #expect(oldObject["executionProfile"] == nil)
        #expect(try decoder.decode(RemoteConversationSummary.self, from: oldData).executionProfile == nil)
        for profile in [
            RemoteSessionExecutionProfile(modelIdentifier: "gpt-6", reasoningEffort: "high"),
            RemoteSessionExecutionProfile(modelIdentifier: "provider/custom-model"),
            RemoteSessionExecutionProfile(reasoningEffort: "adaptive"),
        ] {
            summary.executionProfile = profile
            let data = try encoder.encode(summary)
            #expect(try decoder.decode(RemoteConversationSummary.self, from: data) == summary)
        }
        summary.executionProfile = RemoteSessionExecutionProfile()
        #expect(summary.executionProfile == nil)
        let emptyObject = try #require(JSONSerialization.jsonObject(with: encoder.encode(summary)) as? [String: Any])
        #expect(emptyObject["executionProfile"] == nil)
    }

    @Test func profileNormalizationRejectsUnusableFieldsWithoutLosingValidFields() throws {
        let decoder = ConversationEventCoding.makeDecoder()
        for value in ["bad\u{0000}model", "bad\u{0085}model", "bad\u{202E}model", String(repeating: "m", count: 201)] {
            let data = try JSONSerialization.data(withJSONObject: ["modelIdentifier": value, "reasoningEffort": "high"])
            let profile = try decoder.decode(RemoteSessionExecutionProfile.self, from: data)
            #expect(profile.modelIdentifier == nil)
            #expect(profile.reasoningEffort == "high")
        }
        #expect(RemoteSessionExecutionProfile(modelIdentifier: "  gpt-6  ", reasoningEffort: " high ") ==
            RemoteSessionExecutionProfile(modelIdentifier: "gpt-6", reasoningEffort: "high"))
        #expect(RemoteSessionExecutionProfile(modelIdentifier: " ", reasoningEffort: "\n").isEmpty)
        #expect(RemoteSessionExecutionProfile(reasoningEffort: String(repeating: "e", count: 81)).isEmpty)
        #expect(RemoteSessionExecutionProfile(modelIdentifier: String(repeating: "m", count: 200)).modelIdentifier?.count == 200)
        #expect(RemoteSessionExecutionProfile(reasoningEffort: String(repeating: "e", count: 80)).reasoningEffort?.count == 80)
        for identifier in ["provider/Model-vNext_1.2:custom", "模型-🧑‍💻"] {
            #expect(RemoteSessionExecutionProfile(modelIdentifier: identifier).modelIdentifier == identifier)
        }
    }
}
