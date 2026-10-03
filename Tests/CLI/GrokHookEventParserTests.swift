import CoreState
import Foundation
import Testing
@testable import ToasttyCLIKit

struct GrokHookEventParserTests {
    private let nativeID = "3E24B488-217E-4C54-9C26-194329C6999F"
    private let promptID = "9CD97A60-2A9B-4685-A98F-0DDDF32B5EF0"

    @Test
    func ignoresSubagentsAndUnknownEventsBeforeRequiredFieldValidation() throws {
        for object: [String: Any] in [
            [:],
            ["hookEventName": "future_event"],
            ["hookEventName": "subagent_start"],
            ["hookEventName": "subagent_stop"],
            ["hookEventName": "stop", "subagentType": "explore"],
            ["hookEventName": "stop", "subagentType": String(repeating: "x", count: 200)],
        ] {
            #expect(try parse(object).isEmpty)
        }
        #expect(try GrokHookEventParser.parse(sessionID: "managed", panelID: nil, payload: Data()).isEmpty)
    }

    @Test
    func rejectsMalformedJSONAndOversizedPayload() throws {
        for payload in [Data("{".utf8), Data("[]".utf8), Data("null".utf8)] {
            #expect(throws: GrokHookEventParserError.malformedPayload) {
                _ = try GrokHookEventParser.parse(sessionID: "managed", panelID: nil, payload: payload)
            }
        }
        #expect(throws: GrokHookEventParserError.payloadTooLarge) {
            _ = try GrokHookEventParser.parse(
                sessionID: "managed", panelID: nil,
                payload: Data(repeating: 32, count: GrokHookEventParser.maximumPayloadByteCount + 1)
            )
        }
    }

    @Test
    func recognizedEventsRequireNativeUUIDAndRFC3339Timestamp() throws {
        for changes: [String: Any] in [
            ["sessionId": NSNull()], ["sessionId": "not-a-uuid"], ["sessionId": 12],
            ["timestamp": NSNull()], ["timestamp": "yesterday"], ["timestamp": 123],
            ["timestamp": "2026-10-02"], ["promptId": "not-a-uuid"], ["promptId": 12],
            ["timestamp": "2026-10-02T12:20:00Z trailing text"],
            ["timestamp": "2026-10-02T12:20:00"],
            ["timestamp": "2026-10-02T12:20:00+99:99"],
            ["subagentType": 12], ["notificationType": 12], ["cwd": 12], ["transcriptPath": 12],
        ] {
            var object = validPayload(kind: "stop")
            object.merge(changes, uniquingKeysWith: { _, new in new })
            #expect(throws: GrokHookEventParserError.malformedPayload) {
                _ = try parse(object)
            }
        }
        for key in ["sessionId", "timestamp"] {
            var object = validPayload(kind: "stop")
            object.removeValue(forKey: key)
            #expect(throws: GrokHookEventParserError.malformedPayload) {
                _ = try parse(object)
            }
        }
    }

    @Test
    func boundsForwardedStringsAndRejectsControlCharacters() throws {
        for (key, value) in [
            ("notificationType", String(repeating: "n", count: 129)),
            ("notificationType", "approval\nrequired"),
            ("cwd", String(repeating: "x", count: 4097)),
            ("transcriptPath", "/tmp/session\u{0}.json"),
        ] {
            var object = validPayload(kind: "notification")
            object[key] = value
            #expect(throws: GrokHookEventParserError.malformedPayload) {
                _ = try parse(object)
            }
        }
    }

    @Test
    func nativeToolEventsWithoutPromptIDPreserveMetadataThroughIngestorAndEnvelope() throws {
        let panelID = UUID()
        for kind: GrokHookEvent.Kind in [.preToolUse, .postToolUse, .postToolUseFailure, .permissionRequest] {
            var object = validPayload(kind: kind.rawValue)
            object["toolName"] = " shell "
            object["toolUseId"] = " tool-123 "
            object["prompt"] = "private prompt"
            object["toolInput"] = ["command": "private shell command", "path": "/private/input.txt"]
            object["command"] = "private command"
            object["toolOutput"] = "private output"
            object["output"] = "private result"
            object["filePath"] = "/private/output.txt"
            let commands = try AgentEventIngestor.commands(
                for: .grokHooks, sessionID: "managed", panelID: panelID,
                payload: JSONSerialization.data(withJSONObject: object)
            )
            #expect(commands.count == 1)
            let command = try #require(commands.first)
            guard case .sessionGrokHookEvent(let sessionID, let observedPanelID, let event) = command else {
                Issue.record("expected normalized Grok tool event")
                continue
            }
            #expect(sessionID == "managed")
            #expect(observedPanelID == panelID)
            #expect(event.kind == kind)
            #expect(event.promptID == nil)
            #expect(event.toolName == "shell")
            #expect(event.toolUseID == "tool-123")

            let envelope = command.makeEventEnvelope()
            #expect(envelope.eventType == "session.grok_hook_event")
            #expect(envelope.payload.string("toolName") == "shell")
            #expect(envelope.payload.string("toolUseID") == "tool-123")
            #expect(envelope.payload["promptID"] == nil)
            #expect(envelope.payload["toolUseId"] == nil)
            #expect(Set(envelope.payload.keys) == Set([
                "kind", "nativeSessionID", "timestamp", "isSubagent", "toolName", "toolUseID",
            ]))
        }
    }

    @Test
    func toolMetadataUsesStrictOptionalStringsAndUTF8Bounds() throws {
        for key in ["toolName", "toolUseId"] {
            for value: Any in [12, true, ["command": "private"], String(repeating: "x", count: 257),
                               String(repeating: "é", count: 129), "tool\nname", "tool\u{0}id"] {
                var object = validPayload(kind: "pre_tool_use")
                object[key] = value
                #expect(throws: GrokHookEventParserError.malformedPayload) {
                    _ = try parse(object)
                }
            }
            for value: Any in [NSNull(), "", "   ", String(repeating: "x", count: 256),
                               String(repeating: "é", count: 128)] {
                var object = validPayload(kind: "pre_tool_use")
                object[key] = value
                let command = try #require(parse(object).first)
                guard case .sessionGrokHookEvent(_, _, let event) = command else {
                    Issue.record("expected Grok tool event")
                    continue
                }
                let expected = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = expected?.isEmpty == false ? expected : nil
                let observed = key == "toolName" ? event.toolName : event.toolUseID
                #expect(observed == normalized)
                let envelopeKey = key == "toolName" ? "toolName" : "toolUseID"
                #expect(command.makeEventEnvelope().payload.string(envelopeKey) == normalized)
            }
        }
        guard case .sessionGrokHookEvent(_, _, let event) = try #require(parse(validPayload(kind: "pre_tool_use")).first) else {
            Issue.record("expected Grok tool event")
            return
        }
        #expect(event.toolName == nil)
        #expect(event.toolUseID == nil)
    }

    @Test
    func largePromptPreservesMetadataAndExactUnicodePaths() throws {
        var object = validPayload(kind: "user_prompt_submit")
        object["promptId"] = promptID
        object["prompt"] = String(repeating: "private prompt ", count: 20_000)
        object["cwd"] = "/tmp/👩‍💻 repo "
        object["transcriptPath"] = "/tmp/👩‍💻 session.json "
        guard case .sessionGrokHookEvent(_, _, let event) = try #require(parse(object).first) else {
            Issue.record("expected normalized Grok event")
            return
        }
        #expect(event.kind == .userPromptSubmit)
        #expect(event.cwd == "/tmp/👩‍💻 repo ")
        #expect(event.sessionFilePath == "/tmp/👩‍💻 session.json ")
    }

    @Test
    func actualCamelCasePayloadsPreserveOnlyTypedCorrelationMetadata() throws {
        let panelID = UUID()
        for kind in GrokHookEvent.Kind.allCases {
            var object = validPayload(kind: kind.rawValue)
            object["promptId"] = promptID.lowercased()
            object["subagentType"] = ""
            object["transcriptPath"] = "/tmp/repo/session.json"
            object["cwd"] = "/tmp/repo"
            object["prompt"] = "private user prompt"
            object["toolInput"] = ["command": "private shell command"]
            object["error"] = "private failure text"
            let commands = try AgentEventIngestor.commands(
                for: .grokHooks, sessionID: "managed", panelID: panelID,
                payload: JSONSerialization.data(withJSONObject: object)
            )
            #expect(commands.count == 1)
            guard case .sessionGrokHookEvent(let sessionID, let observedPanelID, let event) = try #require(commands.first) else {
                Issue.record("expected normalized Grok hook observation")
                continue
            }
            #expect(sessionID == "managed")
            #expect(observedPanelID == panelID)
            #expect(event.kind == kind)
            #expect(event.nativeSessionID == nativeID.lowercased())
            #expect(event.promptID == promptID.lowercased())
            #expect(event.timestamp.timeIntervalSince1970 == 1_790_943_600.125)
            #expect(!event.isSubagent)
            #expect(event.sessionFilePath == "/tmp/repo/session.json")
            #expect(event.cwd == "/tmp/repo")

            let envelope = try #require(commands.first?.makeEventEnvelope())
            #expect(envelope.eventType == "session.grok_hook_event")
            #expect(envelope.payload.string("kind") == kind.rawValue)
            #expect(envelope.payload.string("nativeSessionID") == nativeID.lowercased())
            #expect(envelope.payload.string("promptID") == promptID.lowercased())
            #expect(envelope.payload["timestamp"] == .double(1_790_943_600.125))
            #expect(envelope.payload["isSubagent"] == .bool(false))
            #expect(envelope.payload["prompt"] == nil)
            #expect(envelope.payload["toolInput"] == nil)
            #expect(envelope.payload["error"] == nil)
            #expect(envelope.payload["summary"] == nil)
        }
    }

    @Test
    func notificationCanOmitPromptIDAndTimestampCanOmitFractionalSeconds() throws {
        var object = validPayload(kind: "notification")
        object["timestamp"] = "2026-10-02T12:20:00Z"
        object["notificationType"] = "idle_prompt"
        guard case .sessionGrokHookEvent(_, _, let event) = try #require(parse(object).first) else {
            Issue.record("expected Grok notification")
            return
        }
        #expect(event.promptID == nil)
        #expect(event.notificationType == "idle_prompt")
        #expect(event.timestamp.timeIntervalSince1970 == 1_790_943_600)
    }

    @Test
    func timestampsRetainMicrosecondOrderingThroughEnvelope() throws {
        var object = validPayload(kind: "stop")
        object["timestamp"] = "2026-10-02T12:20:00.123456Z"
        let command = try #require(parse(object).first)
        guard case .sessionGrokHookEvent(_, _, let event) = command else {
            Issue.record("expected Grok event")
            return
        }
        #expect(abs(event.timestamp.timeIntervalSince1970 - 1_790_943_600.123456) < 0.000001)
        #expect(command.makeEventEnvelope().payload["timestamp"] == .double(event.timestamp.timeIntervalSince1970))
    }

    @Test
    func cliAcceptsGrokHookSourceWithManagedEnvironmentIdentity() throws {
        let panelID = UUID()
        let invocation = try ToasttyCLI.parse(
            arguments: ["session", "ingest-agent-event", "--source", "grok-hooks"],
            environment: ["TOASTTY_SESSION_ID": "managed", "TOASTTY_PANEL_ID": panelID.uuidString]
        )
        #expect(invocation.command == .sessionIngestAgentEvent(sessionID: "managed", panelID: panelID, source: .grokHooks))
    }

    private func validPayload(kind: String) -> [String: Any] {
        ["hookEventName": kind, "sessionId": nativeID, "timestamp": "2026-10-02T12:20:00.125Z"]
    }

    private func parse(_ object: [String: Any]) throws -> [CLICommand] {
        try GrokHookEventParser.parse(
            sessionID: "managed", panelID: nil,
            payload: JSONSerialization.data(withJSONObject: object)
        )
    }
}
