import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyCLIKit

struct ClaudePermissionHookTests {
    @Test
    func permissionRequestCarriesFullPreviewAndCorrelatesWithPreToolUse() throws {
        let command = "sed -n 200,215p docs/agents/automation.md && rm -rf build/very/long/path/that/the/summary/cuts/off/at/one/hundred/characters"
        let input: [String: AutomationJSONValue] = ["command": .string(command), "description": .string("Print lines")]
        let request = try #require(ClaudeQuestionHookParser.parse(payload(name: "PermissionRequest", input: input)))
        let preTool = try #require(ClaudeQuestionHookParser.parse(payload(
            name: "PreToolUse", input: input, extra: ["tool_use_id": .string("call-1")]
        )))

        #expect(preTool.event.providerCallID == "call-1")
        #expect(preTool.event.permission == nil)
        #expect(request.event.providerCallID == nil)
        #expect(request.event.toolInputDigest == preTool.event.toolInputDigest)
        #expect(request.event.toolName == "Bash")

        let presentation = try #require(request.event.permission)
        #expect(presentation.detail.preview == command)
        #expect(presentation.detail.description == "Print lines")
        #expect(!presentation.detail.previewTruncated)
        // Older phones render only the question text, so it holds the whole command.
        #expect(presentation.decision.question.contains(command))
        #expect(presentation.decision.options.map(\.id) == ["allow", "deny"])
    }

    @Test
    func onlyAllowListedMainAgentToolsParticipate() {
        let input: [String: AutomationJSONValue] = ["plan": .string("Do it")]
        for tool in ["ExitPlanMode", "mcp__server__tool", "Task"] {
            #expect(ClaudeQuestionHookParser.parse(payload(name: "PermissionRequest", tool: tool, input: input)) == nil)
            #expect(ClaudeQuestionHookParser.parse(payload(
                name: "PreToolUse", tool: tool, input: input, extra: ["tool_use_id": .string("call")]
            )) == nil)
        }
        #expect(ClaudeQuestionHookParser.parse(payload(
            name: "PermissionRequest", input: ["command": .string("ls")], extra: ["agent_id": .string("sub")]
        )) == nil)
        // Completion of an ordinary tool reaches the host through the transcript.
        #expect(ClaudeQuestionHookParser.parse(payload(
            name: "PostToolUse", input: ["command": .string("ls")], extra: ["tool_use_id": .string("call")]
        )) == nil)
    }

    @Test
    func suggestionsBecomeExactAlwaysAllowOptionsAndUnsupportedOnesAreSkipped() throws {
        let suggestions: AutomationJSONValue = .array([
            .object(["type": .string("addDirectories"), "directories": .array([.string("/tmp")]),
                     "destination": .string("session")]),
            .object(["type": .string("addRules"), "behavior": .string("allow"), "destination": .string("localSettings"),
                     "rules": .array([.object(["toolName": .string("Bash"), "ruleContent": .string("sed -n:*")])])]),
            .object(["type": .string("setMode"), "mode": .string("bypassPermissions"), "destination": .string("session")]),
            // Same label as the first rule: skipped so the question stays valid.
            .object(["type": .string("addRules"), "behavior": .string("allow"), "destination": .string("userSettings"),
                     "rules": .array([.object(["toolName": .string("Bash"), "ruleContent": .string("sed -n:*")])])]),
            .object(["type": .string("setMode"), "mode": .string("acceptEdits"), "destination": .string("session")]),
            .object(["type": .string("addRules"), "behavior": .string("allow"), "destination": .string("session"),
                     "rules": .array([.object(["toolName": .string("Read")])])]),
        ])
        let parsed = try #require(ClaudeQuestionHookParser.parse(payload(
            name: "PermissionRequest", input: ["command": .string("sed -n 1p a")],
            extra: ["permission_suggestions": suggestions]
        )))
        let options = try #require(parsed.event.permission?.decision.options)
        #expect(options.map(\.id) == ["allow", "always:1", "always:4", "deny"])
        #expect(options[1].label == "Always allow Bash(sed -n:*)")
        #expect(options[1].detail == "Saved for this project in .claude/settings.local.json")
        #expect(options[2].label == "Allow all edits this session")
    }

    @Test
    func decisionsMapToClaudeHookOutput() throws {
        let suggestion: AutomationJSONValue = .object([
            "type": .string("addRules"), "behavior": .string("allow"), "destination": .string("localSettings"),
            "rules": .array([.object(["toolName": .string("Bash"), "ruleContent": .string("ls:*")])]),
        ])
        let parsed = try #require(ClaudeQuestionHookParser.parse(payload(
            name: "PermissionRequest", input: ["command": .string("ls")],
            extra: ["permission_suggestions": .array([suggestion])]
        )))
        func decision(_ optionID: String, text: String? = nil) throws -> [String: AutomationJSONValue]? {
            guard let json = parsed.providerResponse(answers: [
                .init(questionID: "decision", selectedOptionIDs: [optionID], text: text),
            ]) else { return nil }
            let output = try JSONDecoder().decode([String: AutomationJSONValue].self, from: Data(json.utf8))
            #expect(output.object("hookSpecificOutput")?.string("hookEventName") == "PermissionRequest")
            return output.object("hookSpecificOutput")?.object("decision")
        }

        #expect(try decision("allow") == ["behavior": .string("allow")])
        #expect(try decision("always:0") == ["behavior": .string("allow"), "updatedPermissions": .array([suggestion])])
        let deny = try #require(try decision("deny"))
        #expect(deny.string("behavior") == "deny")
        #expect(deny.bool("interrupt") == true)
        #expect(deny.string("message")?.isEmpty == false)
        #expect(try decision("always:7") == nil)
        #expect(try decision("allow", text: "custom") == nil)
    }

    @Test
    func editAndLongPreviewsStayReadableAndBounded() throws {
        let edit = try #require(ClaudeQuestionHookParser.parse(payload(name: "PermissionRequest", tool: "Edit", input: [
            "file_path": .string("/repo/a.swift"), "old_string": .string("let a = 1"), "new_string": .string("let a = 2\nlet b = 3"),
        ])))
        #expect(edit.event.permission?.detail.preview == "/repo/a.swift\n- let a = 1\n+ let a = 2\n+ let b = 3")

        let multi = try #require(ClaudeQuestionHookParser.parse(payload(name: "PermissionRequest", tool: "MultiEdit", input: [
            "file_path": .string("/repo/a.swift"),
            "edits": .array([.object(["old_string": .string("a"), "new_string": .string("b"), "replace_all": .bool(true)])]),
        ])))
        #expect(multi.event.permission?.detail.preview == "/repo/a.swift\n- a\n+ b\n(all occurrences)")
        // Other tools show every argument, since any of them can change the effect.
        let notebook = try #require(ClaudeQuestionHookParser.parse(payload(name: "PermissionRequest", tool: "NotebookEdit", input: [
            "notebook_path": .string("/repo/n.ipynb"), "cell_id": .string("c2"), "edit_mode": .string("delete"),
            "new_source": .string(""),
        ])))
        let notebookPreview = try #require(notebook.event.permission?.detail.preview)
        #expect(notebookPreview.contains("\"cell_id\" : \"c2\""))
        #expect(notebookPreview.contains("\"edit_mode\" : \"delete\""))

        let long = String(repeating: "é", count: ClaudePermissionHook.maximumPreviewBytes)
        let write = try #require(ClaudeQuestionHookParser.parse(payload(name: "PermissionRequest", tool: "Write", input: [
            "file_path": .string("/repo/big.txt"), "content": .string(long),
        ])))
        let detail = try #require(write.event.permission?.detail)
        #expect(detail.previewTruncated)
        #expect(detail.preview.utf8.count <= ClaudePermissionHook.maximumPreviewBytes)
        #expect(detail.preview.hasPrefix("/repo/big.txt\n\n"))
    }

    @Test
    func argumentsOutsideTheFormattedPreviewAreShownFirst() throws {
        // A long command must not push the sandbox override out of the bounded preview.
        let command = "ls " + String(repeating: "a", count: ClaudePermissionHook.maximumPreviewBytes)
        let bash = try #require(ClaudeQuestionHookParser.parse(payload(name: "PermissionRequest", input: [
            "command": .string(command), "description": .string("List"), "dangerouslyDisableSandbox": .bool(true),
        ])))
        let presentation = try #require(bash.event.permission)
        #expect(presentation.detail.previewTruncated)
        #expect(presentation.detail.preview.hasPrefix("Other arguments:\n{\n  \"dangerouslyDisableSandbox\" : true\n}\n\nls "))
        #expect(presentation.decision.question.contains("\"dangerouslyDisableSandbox\" : true"))

        let write = try #require(ClaudeQuestionHookParser.parse(payload(name: "PermissionRequest", tool: "Write", input: [
            "file_path": .string("/repo/a.txt"), "content": .string("hi"), "mode": .string("append"),
        ])))
        #expect(write.event.permission?.detail.preview == "Other arguments:\n{\n  \"mode\" : \"append\"\n}\n\n/repo/a.txt\n\nhi")

        // An edit with an argument the formatter does not show falls back to every argument.
        let multi = try #require(ClaudeQuestionHookParser.parse(payload(name: "PermissionRequest", tool: "MultiEdit", input: [
            "file_path": .string("/repo/a.swift"),
            "edits": .array([.object(["old_string": .string("a"), "new_string": .string("b"), "target": .string("/etc/x")])]),
        ])))
        let multiPreview = try #require(multi.event.permission?.detail.preview)
        #expect(multiPreview.contains("\"target\" : \"/etc/x\""))
        #expect(multiPreview.contains("\"edits\""))

        // A shown argument with a value the formatter does not print is listed too.
        let edit = try #require(ClaudeQuestionHookParser.parse(payload(name: "PermissionRequest", tool: "Edit", input: [
            "file_path": .string("/repo/a.swift"), "old_string": .object(["text": .string("a")]),
            "new_string": .string("b"), "replace_all": .string("true"),
        ])))
        #expect(edit.event.permission?.detail.preview
            == "Other arguments:\n{\n  \"old_string\" : {\n    \"text\" : \"a\"\n  },\n  \"replace_all\" : \"true\"\n}\n\n/repo/a.swift\n- \n+ b")
        let multiType = try #require(ClaudeQuestionHookParser.parse(payload(name: "PermissionRequest", tool: "MultiEdit", input: [
            "file_path": .string("/repo/a.swift"),
            "edits": .array([.object(["old_string": .string("a"), "new_string": .string("b"), "replace_all": .string("true")])]),
        ])))
        #expect(multiType.event.permission?.detail.preview.contains("\"replace_all\" : \"true\"") == true)
    }

    @Test
    func runnerSendsPhoneDecisionAndSuppressesGenericTelemetry() throws {
        var sent: [ClaudeQuestionHookRequest] = []
        var replies: [ClaudeQuestionHookReply] = [
            .init(status: .pending, responseID: "response-1"),
            .init(status: .answer, responseID: "response-1", answers: [.init(questionID: "decision", selectedOptionIDs: ["deny"])]),
        ]
        let runner = ClaudeQuestionHookRunner(send: { request in
            sent.append(request)
            return replies.count > 1 ? replies.removeFirst() : replies[0]
        }, makeResponseID: { "response-1" }, uptime: { 0 }, sleep: { _ in })
        let result = runner.run(payload: payload(name: "PermissionRequest", input: ["command": .string("rm x")]),
                                sessionID: "managed", panelID: UUID())
        #expect(result.suppressTelemetry)
        #expect(result.providerResponse?.contains("\"deny\"") == true)
        #expect(sent.first?.phase == .begin)
        #expect(sent.first?.event?.permission != nil)

        // An unavailable host leaves the request to the generic read-only path.
        let fallback = ClaudeQuestionHookRunner(send: { _ in .init(status: .unavailable) })
            .run(payload: payload(name: "PermissionRequest", input: ["command": .string("rm x")]),
                 sessionID: "managed", panelID: UUID())
        #expect(!fallback.suppressTelemetry)
        #expect(fallback.providerResponse == nil)
    }

    private func payload(
        name: String,
        tool: String = "Bash",
        input: [String: AutomationJSONValue],
        extra: [String: AutomationJSONValue] = [:]
    ) -> Data {
        var object: [String: AutomationJSONValue] = [
            "hook_event_name": .string(name), "session_id": .string("native-session"),
            "prompt_id": .string("prompt-1"), "transcript_path": .string("/tmp/transcript.jsonl"),
            "tool_name": .string(tool), "tool_input": .object(input),
        ]
        object.merge(extra) { _, new in new }
        return try! JSONEncoder().encode(object)
    }
}
