import Foundation

/// Synthetic Codex rollout fixtures.
///
/// Record shapes mirror real rollout files audited on 2026-08-07 (envelope
/// `{timestamp, type, payload}`; `session_meta` / `turn_context` /
/// `response_item` / `event_msg` / `compacted` kinds; resume appending a second
/// `session_meta` with the same session ID; subagent files carrying
/// `agent_role`). All content is synthetic.
enum CodexRolloutFixtures {
    static let sessionID = "01900000-aaaa-7000-8000-000000000001"

    /// Two-turn session: user prompt, commentary, one exec tool call, final
    /// answer, completion; then a second turn with a multiline user message.
    static let basicSession = lines([
        #"{"timestamp":"2026-08-07T10:00:00.100Z","type":"session_meta","payload":{"session_id":"\#(sessionID)","id":"\#(sessionID)","timestamp":"2026-08-07T10:00:00.000Z","cwd":"/tmp/demo","originator":"codex_cli","cli_version":"0.144.2","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex."},"history_mode":"legacy","context_window":{"window_id":"01900000-aaaa-7000-8000-00000000000f"},"git":{"commit_hash":"abc123","branch":"main"}}}"#,
        #"{"timestamp":"2026-08-07T10:00:05.000Z","type":"event_msg","payload":{"type":"user_message","message":"Add a retry to the sync job","images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}}"#,
        #"{"timestamp":"2026-08-07T10:00:05.100Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-001","started_at":1786000805,"model_context_window":258400,"collaboration_mode_kind":"default"}}"#,
        #"{"timestamp":"2026-08-07T10:00:05.200Z","type":"turn_context","payload":{"turn_id":"turn-001","cwd":"/tmp/demo","approval_policy":"never","model":"gpt-5.5","effort":"high","summary":"auto"}}"#,
        #"{"timestamp":"2026-08-07T10:00:08.000Z","type":"response_item","payload":{"type":"message","role":"assistant","id":"msg_0001","phase":"commentary","content":[{"type":"output_text","text":"Looking at the sync job first."}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-001"}}}"#,
        #"{"timestamp":"2026-08-07T10:00:09.000Z","type":"response_item","payload":{"type":"reasoning","id":"rs_0001","encrypted_content":"gAAAAABq0000","summary":[]}}"#,
        #"{"timestamp":"2026-08-07T10:00:10.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"grep -n retry sync.py\",\"workdir\":\"/tmp/demo\"}","call_id":"call_0001","id":"fc_0001","internal_chat_message_metadata_passthrough":{"turn_id":"turn-001"}}}"#,
        #"{"timestamp":"2026-08-07T10:00:11.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_0001","id":"fco_0001","output":"Chunk ID: aa11\nWall time: 0.1 seconds\nProcess exited with code 0\nno matches"}}"#,
        #"{"timestamp":"2026-08-07T10:00:12.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_tokens":1200}}}"#,
        #"{"timestamp":"2026-08-07T10:00:13.000Z","type":"event_msg","payload":{"type":"agent_reasoning","text":"Considering edit strategy."}}"#,
        #"{"timestamp":"2026-08-07T10:00:20.000Z","type":"response_item","payload":{"type":"message","role":"assistant","id":"msg_0002","phase":"final","content":[{"type":"output_text","text":"Added a retry with backoff to sync.py."}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-001"}}}"#,
        #"{"timestamp":"2026-08-07T10:00:21.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-001","last_agent_message":"Added a retry with backoff to sync.py.","started_at":1786000805,"completed_at":1786000821,"duration_ms":16000}}"#,
        #"{"timestamp":"2026-08-07T10:01:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"Also log each retry.\nUse the existing logger.\nThanks!","images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}}"#,
        #"{"timestamp":"2026-08-07T10:01:00.100Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-002","started_at":1786000860,"model_context_window":258400,"collaboration_mode_kind":"default"}}"#,
        #"{"timestamp":"2026-08-07T10:01:05.000Z","type":"response_item","payload":{"type":"message","role":"assistant","id":"msg_0003","phase":"final","content":[{"type":"output_text","text":"Retries now log through the sync logger."}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-002"}}}"#,
        #"{"timestamp":"2026-08-07T10:01:06.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-002","last_agent_message":"Retries now log through the sync logger.","started_at":1786000860,"completed_at":1786000866,"duration_ms":6000}}"#,
    ])

    /// Continuation appended after `basicSession` when the session is resumed:
    /// a second `session_meta` with the same session ID, then a third turn
    /// where the user repeats an earlier answer ("yes") twice across turns.
    static let resumeContinuation = lines([
        #"{"timestamp":"2026-08-07T12:00:00.000Z","type":"session_meta","payload":{"session_id":"\#(sessionID)","id":"\#(sessionID)","timestamp":"2026-08-07T10:00:00.000Z","cwd":"/tmp/demo","originator":"codex_cli","cli_version":"0.144.2","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex."},"history_mode":"legacy","context_window":{"window_id":"01900000-aaaa-7000-8000-0000000000f2"},"git":{"commit_hash":"abc124","branch":"main"}}}"#,
        #"{"timestamp":"2026-08-07T12:00:10.000Z","type":"event_msg","payload":{"type":"user_message","message":"yes","images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}}"#,
        #"{"timestamp":"2026-08-07T12:00:10.100Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-003","started_at":1786007810,"model_context_window":258400,"collaboration_mode_kind":"default"}}"#,
        #"{"timestamp":"2026-08-07T12:00:15.000Z","type":"response_item","payload":{"type":"message","role":"assistant","id":"msg_0004","phase":"final","content":[{"type":"output_text","text":"Done. Anything else?"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-003"}}}"#,
        #"{"timestamp":"2026-08-07T12:00:16.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-003","last_agent_message":"Done. Anything else?","started_at":1786007810,"completed_at":1786007816,"duration_ms":6000}}"#,
        #"{"timestamp":"2026-08-07T12:01:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"yes","images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}}"#,
        #"{"timestamp":"2026-08-07T12:01:00.100Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-004","started_at":1786007860,"model_context_window":258400,"collaboration_mode_kind":"default"}}"#,
        #"{"timestamp":"2026-08-07T12:01:05.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-004","last_agent_message":"Wrapped up.","started_at":1786007860,"completed_at":1786007865,"duration_ms":5000}}"#,
    ])

    /// Approval + question flow: an exec approval that resolves through its
    /// tool output, then a question that is superseded by the next turn.
    static let approvalSession = lines([
        #"{"timestamp":"2026-08-07T11:00:00.000Z","type":"session_meta","payload":{"session_id":"01900000-aaaa-7000-8000-000000000002","id":"01900000-aaaa-7000-8000-000000000002","timestamp":"2026-08-07T11:00:00.000Z","cwd":"/tmp/demo","originator":"codex_cli","cli_version":"0.144.2","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex."},"history_mode":"legacy"}}"#,
        #"{"timestamp":"2026-08-07T11:00:05.000Z","type":"event_msg","payload":{"type":"user_message","message":"Clean the build directory","images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}}"#,
        #"{"timestamp":"2026-08-07T11:00:05.100Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-101","started_at":1786004405,"model_context_window":258400,"collaboration_mode_kind":"default"}}"#,
        #"{"timestamp":"2026-08-07T11:00:06.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"rm -rf build\",\"workdir\":\"/tmp/demo\"}","call_id":"call_0101","id":"fc_0101","internal_chat_message_metadata_passthrough":{"turn_id":"turn-101"}}}"#,
        #"{"timestamp":"2026-08-07T11:00:06.500Z","type":"event_msg","payload":{"type":"exec_approval_request","call_id":"call_0101","approval_id":"appr_0101","command":"rm -rf build","cwd":"/tmp/demo"}}"#,
        #"{"timestamp":"2026-08-07T11:00:20.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_0101","id":"fco_0101","output":"Chunk ID: bb22\nProcess exited with code 0\n"}}"#,
        #"{"timestamp":"2026-08-07T11:00:25.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-101","last_agent_message":"Build directory removed.","started_at":1786004405,"completed_at":1786004425,"duration_ms":20000}}"#,
        #"{"timestamp":"2026-08-07T11:01:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"Now redo the setup","images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}}"#,
        #"{"timestamp":"2026-08-07T11:01:00.100Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-102","started_at":1786004460,"model_context_window":258400,"collaboration_mode_kind":"default"}}"#,
        #"{"timestamp":"2026-08-07T11:01:02.000Z","type":"event_msg","payload":{"type":"request_user_input","call_id":"call_0102","question":"Use the fast setup or the full setup?"}}"#,
        #"{"timestamp":"2026-08-07T11:02:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"fast","images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}}"#,
        #"{"timestamp":"2026-08-07T11:02:00.100Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-103","started_at":1786004520,"model_context_window":258400,"collaboration_mode_kind":"default"}}"#,
        #"{"timestamp":"2026-08-07T11:02:10.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-103","last_agent_message":"Fast setup complete.","started_at":1786004520,"completed_at":1786004530,"duration_ms":10000}}"#,
    ])

    /// Subagent activity plus an interrupted turn.
    static let subagentAndInterruptSession = lines([
        #"{"timestamp":"2026-08-07T13:00:00.000Z","type":"session_meta","payload":{"session_id":"01900000-aaaa-7000-8000-000000000003","id":"01900000-aaaa-7000-8000-000000000003","timestamp":"2026-08-07T13:00:00.000Z","cwd":"/tmp/demo","originator":"codex_cli","cli_version":"0.144.2","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex."},"history_mode":"legacy"}}"#,
        #"{"timestamp":"2026-08-07T13:00:05.000Z","type":"event_msg","payload":{"type":"user_message","message":"Audit the workers in parallel","images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}}"#,
        #"{"timestamp":"2026-08-07T13:00:05.100Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-201","started_at":1786011605,"model_context_window":258400,"collaboration_mode_kind":"default"}}"#,
        #"{"timestamp":"2026-08-07T13:00:10.000Z","type":"event_msg","payload":{"type":"sub_agent_activity","event_id":"call_sub01","occurred_at_ms":1786011610000,"agent_thread_id":"01900000-bbbb-7000-8000-000000000001","agent_path":"/root/audit_worker_queue","kind":"started"}}"#,
        #"{"timestamp":"2026-08-07T13:03:00.000Z","type":"event_msg","payload":{"type":"sub_agent_activity","event_id":"call_sub01","occurred_at_ms":1786011780000,"agent_thread_id":"01900000-bbbb-7000-8000-000000000001","agent_path":"/root/audit_worker_queue","kind":"finished"}}"#,
        #"{"timestamp":"2026-08-07T13:04:00.000Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-201","reason":"interrupted","started_at":1786011605,"completed_at":1786011840,"duration_ms":235000}}"#,
    ])

    /// Compaction: `context_compacted` plus a top-level `compacted` record
    /// whose `replacement_history` replays the first user message.
    static let compactionSession = lines([
        #"{"timestamp":"2026-08-07T14:00:00.000Z","type":"session_meta","payload":{"session_id":"01900000-aaaa-7000-8000-000000000004","id":"01900000-aaaa-7000-8000-000000000004","timestamp":"2026-08-07T14:00:00.000Z","cwd":"/tmp/demo","originator":"codex_cli","cli_version":"0.144.2","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex."},"history_mode":"legacy"}}"#,
        #"{"timestamp":"2026-08-07T14:00:05.000Z","type":"event_msg","payload":{"type":"user_message","message":"Summarize the repo layout","images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}}"#,
        #"{"timestamp":"2026-08-07T14:00:05.100Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-301","started_at":1786015205,"model_context_window":258400,"collaboration_mode_kind":"default"}}"#,
        #"{"timestamp":"2026-08-07T14:00:10.000Z","type":"response_item","payload":{"type":"message","role":"assistant","id":"msg_0301","phase":"final","content":[{"type":"output_text","text":"Two targets: app and core."}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-301"}}}"#,
        #"{"timestamp":"2026-08-07T14:00:11.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-301","last_agent_message":"Two targets: app and core.","started_at":1786015205,"completed_at":1786015211,"duration_ms":6000}}"#,
        #"{"timestamp":"2026-08-07T14:30:00.000Z","type":"event_msg","payload":{"type":"context_compacted"}}"#,
        #"{"timestamp":"2026-08-07T14:30:00.100Z","type":"compacted","payload":{"message":"","replacement_history":[{"type":"message","id":"msg_u0301","role":"user","content":[{"type":"input_text","text":"Summarize the repo layout"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-301"}},{"type":"compaction","id":"cmp_0301","encrypted_content":"gAAAAABq1111"}],"window_number":2,"first_window_id":"01900000-cccc-7000-8000-000000000001","previous_window_id":"01900000-cccc-7000-8000-000000000002","window_id":"01900000-cccc-7000-8000-000000000003"}}"#,
        #"{"timestamp":"2026-08-07T14:31:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"Now list the tests","images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}}"#,
        #"{"timestamp":"2026-08-07T14:31:00.100Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-302","started_at":1786017060,"model_context_window":258400,"collaboration_mode_kind":"default"}}"#,
        #"{"timestamp":"2026-08-07T14:31:05.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-302","last_agent_message":"Tests live under Tests/.","started_at":1786017060,"completed_at":1786017065,"duration_ms":5000}}"#,
    ])

    /// Malformed and unknown records around one valid turn.
    static var malformedSession: String {
        lines([
            #"{"timestamp":"2026-08-07T15:00:00.000Z","type":"session_meta","payload":{"session_id":"01900000-aaaa-7000-8000-000000000005","id":"01900000-aaaa-7000-8000-000000000005","timestamp":"2026-08-07T15:00:00.000Z","cwd":"/tmp/demo","originator":"codex_cli","cli_version":"0.144.2","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex."},"history_mode":"legacy"}}"#,
            #"{"timestamp":"2026-08-07T15:00:01.000Z","type":"world_state","payload":{"full":true,"state":{}}}"#,
            #"this line is not json at all"#,
            #"{"timestamp":"2026-08-07T15:00:02.000Z","type":"mystery_record","payload":{"whatever":true}}"#,
            #"{"timestamp":"2026-08-07T15:00:03.000Z","type":"event_msg","payload":{"type":"brand_new_event_kind","detail":"ignore me"}}"#,
            #"{"no_timestamp":true,"type":"event_msg","payload":{"type":"user_message","message":"lost"}}"#,
            // Oversized line: a session_meta whose payload carries ~120KB of tool schema.
            #"{"timestamp":"2026-08-07T15:00:04.000Z","type":"session_meta","payload":{"session_id":"01900000-aaaa-7000-8000-000000000005","id":"01900000-aaaa-7000-8000-000000000005","agent_role":null,"dynamic_tools":"\#(String(repeating: "x", count: 120_000))"}}"#,
            #"{"timestamp":"2026-08-07T15:00:05.000Z","type":"event_msg","payload":{"type":"user_message","message":"Still works?","images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}}"#,
            #"{"timestamp":"2026-08-07T15:00:05.100Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-401","started_at":1786018805,"model_context_window":258400,"collaboration_mode_kind":"default"}}"#,
            #"{"timestamp":"2026-08-07T15:00:10.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-401","last_agent_message":"Yes.","started_at":1786018805,"completed_at":1786018810,"duration_ms":5000}}"#,
        ])
    }

    /// A subagent's own rollout file; its session identity must not be
    /// ingested as root conversation identity.
    static let subagentRolloutFile = lines([
        #"{"timestamp":"2026-08-07T16:00:00.000Z","type":"session_meta","payload":{"session_id":"01900000-dddd-7000-8000-000000000001","id":"01900000-dddd-7000-8000-000000000001","timestamp":"2026-08-07T16:00:00.000Z","cwd":"/tmp/demo","originator":"codex_cli","cli_version":"0.144.2","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex."},"history_mode":"legacy","agent_role":"worker","agent_path":"/root/audit_worker_queue","agent_nickname":"Pascal","parent_thread_id":"01900000-aaaa-7000-8000-000000000003"}}"#,
        #"{"timestamp":"2026-08-07T16:00:05.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-501","started_at":1786022405,"model_context_window":258400,"collaboration_mode_kind":"default"}}"#,
    ])

    private static func lines(_ records: [String]) -> String {
        records.joined(separator: "\n") + "\n"
    }
}
