import Foundation

/// Synthetic Claude Code transcript fixtures.
///
/// Record shapes mirror real `~/.claude/projects/<slug>/<sessionId>.jsonl`
/// files audited on 2026-08-07: `user`/`assistant` records with a nested
/// `message` (string or block-array content), `tool_use`/`tool_result`
/// correlation by `tool_use_id`, `isMeta`/`isSidechain` flags, `stop_reason`,
/// and interleaved non-transcript record types. All content is synthetic.
enum ClaudeTranscriptFixtures {
    static let sessionID = "cf000000-0000-4000-8000-000000000001"

    /// Two turns: a string-content prompt, a tool call and its result, a final
    /// answer; then a second prompt with array-content text and a final answer.
    static let basicSession = lines([
        #"{"type":"user","sessionId":"\#(sessionID)","uuid":"u-0001","parentUuid":null,"isSidechain":false,"timestamp":"2026-08-07T09:00:00.000Z","promptId":"prompt-1","message":{"role":"user","content":"Add a retry to the sync job"}}"#,
        #"{"type":"assistant","sessionId":"\#(sessionID)","uuid":"a-0001","parentUuid":"u-0001","isSidechain":false,"timestamp":"2026-08-07T09:00:03.000Z","message":{"role":"assistant","model":"claude-opus-5","stop_reason":"tool_use","content":[{"type":"thinking","thinking":"internal"},{"type":"text","text":"Looking at the sync job first."},{"type":"tool_use","id":"toolu_0001","name":"Bash","input":{"command":"grep -n retry sync.py","description":"search"}}]}}"#,
        #"{"type":"user","sessionId":"\#(sessionID)","uuid":"u-0002","parentUuid":"a-0001","isSidechain":false,"timestamp":"2026-08-07T09:00:04.000Z","promptId":"prompt-1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_0001","is_error":false,"content":"no matches"}]}}"#,
        #"{"type":"assistant","sessionId":"\#(sessionID)","uuid":"a-0002","parentUuid":"u-0002","isSidechain":false,"timestamp":"2026-08-07T09:00:08.000Z","message":{"role":"assistant","model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"Added a retry with backoff to sync.py."}]}}"#,
        #"{"type":"system","subtype":"turn_duration","timestamp":"2026-08-07T09:00:08.500Z","durationMs":8500}"#,
        #"{"type":"user","sessionId":"\#(sessionID)","uuid":"u-0003","parentUuid":"a-0002","isSidechain":false,"timestamp":"2026-08-07T09:01:00.000Z","promptId":"prompt-2","message":{"role":"user","content":[{"type":"text","text":"Also log each retry."}]}}"#,
        #"{"type":"assistant","sessionId":"\#(sessionID)","uuid":"a-0003","parentUuid":"u-0003","isSidechain":false,"timestamp":"2026-08-07T09:01:05.000Z","message":{"role":"assistant","model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"Retries now log through the sync logger."}]}}"#,
    ])

    /// A failing tool call: `is_error: true` must surface as a failed outcome.
    static let toolFailureSession = lines([
        #"{"type":"user","sessionId":"cf000000-0000-4000-8000-000000000002","uuid":"u-1001","parentUuid":null,"isSidechain":false,"timestamp":"2026-08-07T10:00:00.000Z","promptId":"prompt-10","message":{"role":"user","content":"Run the build"}}"#,
        #"{"type":"assistant","sessionId":"cf000000-0000-4000-8000-000000000002","uuid":"a-1001","parentUuid":"u-1001","isSidechain":false,"timestamp":"2026-08-07T10:00:02.000Z","message":{"role":"assistant","model":"claude-opus-5","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_1001","name":"Bash","input":{"command":"make build"}}]}}"#,
        #"{"type":"user","sessionId":"cf000000-0000-4000-8000-000000000002","uuid":"u-1002","parentUuid":"a-1001","isSidechain":false,"timestamp":"2026-08-07T10:00:20.000Z","promptId":"prompt-10","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1001","is_error":true,"content":[{"type":"text","text":"error: build failed"}]}]}}"#,
        #"{"type":"assistant","sessionId":"cf000000-0000-4000-8000-000000000002","uuid":"a-1002","parentUuid":"u-1002","isSidechain":false,"timestamp":"2026-08-07T10:00:25.000Z","message":{"role":"assistant","model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"The build failed; fixing."}]}}"#,
    ])

    /// Meta records, subagent sidechain records, and unknown record types
    /// around one valid turn — all must be skipped without corrupting order.
    static var noiseSession: String {
        lines([
            #"{"type":"user","sessionId":"cf000000-0000-4000-8000-000000000003","uuid":"u-2000","parentUuid":null,"isSidechain":false,"isMeta":true,"timestamp":"2026-08-07T11:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>injected context</system-reminder>"}]}}"#,
            #"{"type":"bridge-session","sessionId":"cf000000-0000-4000-8000-000000000003","bridgeSessionId":"cse_x","lastSequenceNum":0}"#,
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-07T11:00:01.000Z","sessionId":"cf000000-0000-4000-8000-000000000003","content":"queued"}"#,
            #"not valid json at all"#,
            #"{"type":"assistant","sessionId":"cf000000-0000-4000-8000-000000000003","uuid":"a-side","parentUuid":"u-2000","isSidechain":true,"timestamp":"2026-08-07T11:00:02.000Z","message":{"role":"assistant","model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"subagent-only reply"}]}}"#,
            #"{"type":"brand-new-record-kind","timestamp":"2026-08-07T11:00:03.000Z","payload":{"whatever":true}}"#,
            #"{"type":"user","sessionId":"cf000000-0000-4000-8000-000000000003","uuid":"u-2001","parentUuid":null,"isSidechain":false,"timestamp":"2026-08-07T11:00:05.000Z","promptId":"prompt-20","message":{"role":"user","content":"Real question"}}"#,
            #"{"type":"assistant","sessionId":"cf000000-0000-4000-8000-000000000003","uuid":"a-2001","parentUuid":"u-2001","isSidechain":false,"timestamp":"2026-08-07T11:00:08.000Z","message":{"role":"assistant","model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"Real answer."}]}}"#,
        ])
    }

    /// The same session resumed: a later append with the same sessionId and a
    /// repeated identical short prompt across turns.
    static let resumeContinuation = lines([
        #"{"type":"user","sessionId":"\#(sessionID)","uuid":"u-0100","parentUuid":"a-0003","isSidechain":false,"timestamp":"2026-08-07T12:00:00.000Z","promptId":"prompt-3","message":{"role":"user","content":"yes"}}"#,
        #"{"type":"assistant","sessionId":"\#(sessionID)","uuid":"a-0100","parentUuid":"u-0100","isSidechain":false,"timestamp":"2026-08-07T12:00:04.000Z","message":{"role":"assistant","model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"Done. Anything else?"}]}}"#,
        #"{"type":"user","sessionId":"\#(sessionID)","uuid":"u-0101","parentUuid":"a-0100","isSidechain":false,"timestamp":"2026-08-07T12:01:00.000Z","promptId":"prompt-4","message":{"role":"user","content":"yes"}}"#,
        #"{"type":"assistant","sessionId":"\#(sessionID)","uuid":"a-0101","parentUuid":"u-0101","isSidechain":false,"timestamp":"2026-08-07T12:01:05.000Z","message":{"role":"assistant","model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"Wrapped up."}]}}"#,
    ])

    private static func lines(_ records: [String]) -> String {
        records.joined(separator: "\n") + "\n"
    }
}
