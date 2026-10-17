import CoreState
import CryptoKit
import Foundation
import RemoteProtocol

/// Turns one Claude PermissionRequest hook payload into what a phone can show
/// and answer, and maps the phone's choice back to Claude's hook decision.
/// Claude's raw permission suggestions stay in this hook process; the host and
/// the phone see only labels and opaque option IDs.
struct ClaudePermissionHook {
    static let maximumPreviewBytes = 16 * 1024
    static let maximumAlwaysOptions = 2
    static let maximumRuleLabelLength = 240
    static let denyMessage = "The user denied this request from Toastty on iPhone."
    /// Built-in tools whose permission prompt a plain hook allow or deny
    /// settles. Claude ignores a hook allow without updated input for tools
    /// that require user interaction (questions, plan approval, and some MCP
    /// tools), so every other tool stays answerable only on the desktop.
    static let supportedToolNames: Set<String> = [
        "Bash", "Edit", "MultiEdit", "Write", "NotebookEdit", "Read", "Glob", "Grep", "WebFetch", "WebSearch",
    ]

    var presentation: ClaudePermissionHookPresentation
    var suggestionsByIndex: [Int: AutomationJSONValue]

    static func supportsTool(_ toolName: String) -> Bool {
        supportedToolNames.contains(toolName)
    }

    /// The same tool call produces the same digest in PreToolUse and in
    /// PermissionRequest, without sending the input to the host.
    static func inputDigest(_ toolInput: [String: AutomationJSONValue]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(toolInput) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    init?(
        toolName: String,
        toolInput: [String: AutomationJSONValue],
        suggestions: AutomationJSONValue?,
        summary: String
    ) {
        guard Self.supportsTool(toolName),
              summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
        var options = [RemotePendingInteraction.Option(id: ClaudePermissionDecision.allowOnce.optionID, label: "Allow once")]
        var suggestionsByIndex: [Int: AutomationJSONValue] = [:]
        if case .array(let entries)? = suggestions {
            for (index, entry) in entries.enumerated() where suggestionsByIndex.count < Self.maximumAlwaysOptions {
                guard let (label, detail) = Self.alwaysAllowLabel(for: entry),
                      options.contains(where: { $0.label == label }) == false else { continue }
                options.append(.init(id: ClaudePermissionDecision.alwaysAllow(suggestionIndex: index).optionID,
                                     label: label, detail: detail))
                suggestionsByIndex[index] = entry
            }
        }
        options.append(.init(id: ClaudePermissionDecision.deny.optionID, label: "Deny",
                             detail: "Stops Claude so you can say what to do instead"))
        let (preview, truncated) = Self.boundedPreview(Self.previewText(toolName: toolName, input: toolInput))
        // Clients without a permission view render only the question, so it
        // carries the full preview: nobody approves a command they cannot read.
        let decision = RemoteInteractionQuestion(
            id: ClaudePermissionDecision.questionID,
            header: toolName,
            question: [summary, preview, truncated ? "(Preview shortened. Check the desktop for the full request.)" : nil]
                .compactMap { $0 }.filter { $0.isEmpty == false }.joined(separator: "\n\n"),
            options: options
        )
        guard ClaudeQuestionValidation.validateQuestions([decision]) else { return nil }
        presentation = ClaudePermissionHookPresentation(
            summary: summary,
            detail: RemotePermissionRequestDetail(
                toolName: toolName,
                description: toolInput.string("description").flatMap { $0.isEmpty ? nil : $0 },
                preview: preview,
                previewTruncated: truncated
            ),
            decision: decision
        )
        self.suggestionsByIndex = suggestionsByIndex
    }

    func providerResponse(answers: [RemoteInteractionAnswer]) -> String? {
        guard let choice = ClaudePermissionDecision.decision(from: answers, for: presentation.decision) else { return nil }
        let decision: [String: AutomationJSONValue]
        switch choice {
        case .allowOnce:
            decision = ["behavior": .string("allow")]
        case .alwaysAllow(let index):
            guard let suggestion = suggestionsByIndex[index] else { return nil }
            decision = ["behavior": .string("allow"), "updatedPermissions": .array([suggestion])]
        case .deny:
            // Match the desktop "No": Claude stops and waits for the user.
            decision = ["behavior": .string("deny"), "message": .string(Self.denyMessage), "interrupt": .bool(true)]
        }
        let response: [String: AutomationJSONValue] = [
            "hookSpecificOutput": .object([
                "hookEventName": .string("PermissionRequest"),
                "decision": .object(decision),
            ]),
        ]
        guard let data = try? JSONEncoder().encode(response) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Suggestions

    /// Labels only the suggestions whose effect a phone can state exactly:
    /// allow rules at any destination, and a session-only switch to
    /// accept-edits mode. Everything else is left to the desktop.
    static func alwaysAllowLabel(for entry: AutomationJSONValue) -> (label: String, detail: String)? {
        guard case .object(let object) = entry, let type = object.string("type"),
              let destination = object.string("destination") else { return nil }
        switch type {
        case "addRules":
            guard object.string("behavior") == "allow",
                  let detail = destinationDetail(destination),
                  case .array(let rawRules)? = object["rules"], rawRules.isEmpty == false else { return nil }
            var rules: [String] = []
            for rawRule in rawRules {
                guard case .object(let rule) = rawRule,
                      let toolName = rule.string("toolName"), toolName.isEmpty == false else { return nil }
                if let content = rule.string("ruleContent"), content.isEmpty == false {
                    rules.append("\(toolName)(\(content))")
                } else if rule["ruleContent"] == nil || rule["ruleContent"] == .null {
                    rules.append(toolName)
                } else {
                    return nil
                }
            }
            let ruleList = rules.joined(separator: ", ")
            // Never shorten a rule: the label must state exactly what is allowed.
            guard ruleList.count <= maximumRuleLabelLength,
                  ruleList.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control }) else { return nil }
            return ("Always allow \(ruleList)", detail)
        case "setMode":
            guard destination == "session" else { return nil }
            guard object.string("mode") == "acceptEdits" else { return nil }
            return ("Allow all edits this session", "Switches Claude to accept-edits mode until the session ends")
        default:
            return nil
        }
    }

    static func destinationDetail(_ destination: String) -> String? {
        switch destination {
        case "session": "Until this Claude session ends"
        case "localSettings": "Saved for this project in .claude/settings.local.json"
        case "projectSettings": "Saved for everyone in this project's .claude/settings.json"
        case "userSettings": "Saved for all your projects in ~/.claude/settings.json"
        default: nil
        }
    }

    // MARK: - Preview

    private enum ShownValue {
        case string, bool, edits
    }

    /// Arguments that each formatted preview shows, with the value type it
    /// prints. Any other argument, or a shown one with another type, can change
    /// what the tool does (Bash's `dangerouslyDisableSandbox`, for example), so
    /// it is listed above the formatted text, where the phone shows it first
    /// and shortening cannot drop it.
    private static let formattedArguments: [String: [String: ShownValue]] = [
        "Bash": ["command": .string, "description": .string],
        "Edit": ["file_path": .string, "old_string": .string, "new_string": .string, "replace_all": .bool],
        "MultiEdit": ["file_path": .string, "edits": .edits],
        "Write": ["file_path": .string, "content": .string],
    ]
    private static let editArguments: [String: ShownValue] = [
        "old_string": .string, "new_string": .string, "replace_all": .bool,
    ]

    static func previewText(toolName: String, input: [String: AutomationJSONValue]) -> String {
        guard let shown = formattedArguments[toolName],
              let formatted = formattedPreview(toolName: toolName, input: input) else {
            // Every argument can change what the tool does, so show them all.
            return jsonPreview(input)
        }
        let others = input.filter { isShown($0.value, as: shown[$0.key]) == false }
        guard others.isEmpty == false else { return formatted }
        return "Other arguments:\n\(jsonPreview(others))\n\n\(formatted)"
    }

    private static func isShown(_ value: AutomationJSONValue, as kind: ShownValue?) -> Bool {
        switch (kind, value) {
        case (.string?, .string), (.bool?, .bool), (.edits?, .array): true
        default: false
        }
    }

    private static func formattedPreview(toolName: String, input: [String: AutomationJSONValue]) -> String? {
        switch toolName {
        case "Bash":
            return input.string("command")
        case "Edit":
            guard let path = input.string("file_path") else { return nil }
            let scope = input.bool("replace_all") == true ? "\n(all occurrences)" : ""
            return "\(path)\n\(editPreview(input))\(scope)"
        case "MultiEdit":
            guard let path = input.string("file_path"), case .array(let edits)? = input["edits"] else { return nil }
            var parts = [path]
            for edit in edits {
                // An edit the formatter cannot show in full falls back to every argument.
                guard case .object(let object) = edit,
                      object.allSatisfy({ isShown($0.value, as: editArguments[$0.key]) }) else { return nil }
                parts.append(editPreview(object) + (object.bool("replace_all") == true ? "\n(all occurrences)" : ""))
            }
            return parts.joined(separator: "\n")
        case "Write":
            guard let path = input.string("file_path"), let content = input.string("content") else { return nil }
            return "\(path)\n\n\(content)"
        default:
            return nil
        }
    }

    private static func editPreview(_ input: [String: AutomationJSONValue]) -> String {
        let removed = (input.string("old_string") ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            .map { "- \($0)" }
        let added = (input.string("new_string") ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            .map { "+ \($0)" }
        return (removed + added).joined(separator: "\n")
    }

    private static func jsonPreview(_ input: [String: AutomationJSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(input), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// Shortens on a character boundary so the preview stays valid text.
    static func boundedPreview(_ text: String) -> (String, Bool) {
        guard text.utf8.count > maximumPreviewBytes else { return (text, false) }
        var result = ""
        var bytes = 0
        for character in text {
            let size = character.utf8.count
            guard bytes + size <= maximumPreviewBytes else { break }
            result.append(character)
            bytes += size
        }
        return (result, true)
    }
}
