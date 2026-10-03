#!/usr/bin/env node
// Local stdio MCP adapter for one Toastty instance. All app access goes through
// its same-user Unix socket; stdout is reserved for MCP JSON-RPC messages.
import { createInterface } from 'node:readline';
import { createConnection } from 'node:net';
import { randomUUID } from 'node:crypto';

const socketPath = process.env.TOASTTY_SOCKET_PATH;
const starts = new Map();

function socketRequest(command, payload = {}) {
  if (!socketPath) throw new Error('TOASTTY_SOCKET_PATH is required');
  return new Promise((resolve, reject) => {
    const client = createConnection(socketPath);
    const chunks = [];
    let byteCount = 0;
    let done = false;
    const finish = (error, value) => {
      if (done) return;
      done = true;
      client.destroy();
      error ? reject(error) : resolve(value);
    };
    client.setTimeout(15000, () => finish(new Error('Toastty response timed out; delivery may be uncertain')));
    client.on('error', error => finish(error));
    client.on('connect', () => client.write(JSON.stringify({
      protocolVersion: '1.0', kind: 'request', requestID: randomUUID(), command, payload,
    }) + '\n'));
    client.on('data', chunk => {
      chunks.push(chunk);
      byteCount += chunk.length;
      if (byteCount > 2_000_000) return finish(new Error('Toastty response exceeded 2 MB'));
      if (chunk.indexOf(0x0a) < 0) return;
      try {
        const reply = Buffer.concat(chunks, byteCount);
        const end = reply.indexOf(0x0a);
        const envelope = JSON.parse(reply.subarray(0, end).toString('utf8'));
        if (!envelope.ok) return finish(new Error(`${envelope.error?.code ?? 'ERROR'}: ${envelope.error?.message ?? 'Toastty refused request'}`));
        finish(null, envelope.result ?? {});
      } catch (error) { finish(error); }
    });
    client.on('end', () => finish(new Error('Toastty closed without a complete response')));
  });
}

const tools = [
  { name: 'toastty_list_sessions', description: 'List Toastty workspaces and managed conversation status.', inputSchema: { type: 'object', properties: {}, additionalProperties: false } },
  { name: 'toastty_read_progress', description: 'Read up to 40 normalized events from one conversation. Use the returned continuation cursor for the next page.', inputSchema: { type: 'object', properties: { conversationID: { type: 'string' }, cursor: { type: 'object' }, limit: { type: 'integer', minimum: 1, maximum: 40 } }, required: ['conversationID'], additionalProperties: false } },
  { name: 'toastty_send_message', description: 'Send text only to an exactly open managed prompt. The result is delivery status, not proof the agent acted.', inputSchema: { type: 'object', properties: { conversationID: { type: 'string' }, clientRequestID: { type: 'string' }, expectedInputEpoch: { type: 'object' }, text: { type: 'string' } }, required: ['conversationID', 'clientRequestID', 'expectedInputEpoch', 'text'], additionalProperties: false } },
  { name: 'toastty_start_session', description: 'Create a background terminal tab in an existing workspace and launch a managed agent there.', inputSchema: { type: 'object', properties: { clientRequestID: { type: 'string' }, workspaceID: { type: 'string' }, profileID: { type: 'string' }, text: { type: 'string' }, model: { type: 'string' }, reasoningEffort: { type: 'string' } }, required: ['clientRequestID', 'workspaceID', 'profileID', 'text'], additionalProperties: false } },
  { name: 'toastty_request_skill', description: 'Ask the owning agent to use an available skill; this sends an instruction, not a structured skill execution.', inputSchema: { type: 'object', properties: { conversationID: { type: 'string' }, clientRequestID: { type: 'string' }, expectedInputEpoch: { type: 'object' }, skillName: { type: 'string' }, task: { type: 'string' } }, required: ['conversationID', 'clientRequestID', 'expectedInputEpoch', 'skillName', 'task'], additionalProperties: false } },
  { name: 'toastty_request_merge', description: 'Ask the owning agent to prepare a merge handoff for user review. This never invokes GitHub merge.', inputSchema: { type: 'object', properties: { conversationID: { type: 'string' }, clientRequestID: { type: 'string' }, expectedInputEpoch: { type: 'object' }, pullRequestURL: { type: 'string' } }, required: ['conversationID', 'clientRequestID', 'expectedInputEpoch', 'pullRequestURL'], additionalProperties: false } },
];

function requiredText(value, name, maximum = 32000) {
  if (typeof value !== 'string' || !value.trim() || value.length > maximum) throw new Error(`${name} must be nonempty and at most ${maximum} characters`);
  return value;
}
function safePrompt(value, name) {
  const text = requiredText(value, name);
  // The first prompt is ultimately placed in a terminal command line. Reject
  // control sequences, line breaks, and bidirectional formatting characters.
  if (/[\u0000-\u001f\u007f-\u009f\u2028\u2029\u202a-\u202e\u2066-\u2069]/u.test(text)) {
    throw new Error(`${name} contains terminal or display control characters`);
  }
  return text;
}
function uuid(value, name) {
  if (typeof value !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) throw new Error(`${name} must be a UUID`);
  return value;
}
function action(id, args) { return socketRequest('app_control.run_action', { id, args }); }

async function send(args, text) {
  const request = {
    conversationID: uuid(args.conversationID, 'conversationID'),
    clientRequestID: requiredText(args.clientRequestID, 'clientRequestID', 64),
    expectedInputEpoch: args.expectedInputEpoch,
    text: safePrompt(text, 'text'),
  };
  if (!request.expectedInputEpoch || typeof request.expectedInputEpoch !== 'object') throw new Error('expectedInputEpoch is required');
  return socketRequest('mcp.message_send', { requestJSON: JSON.stringify(request) });
}

async function call(name, args = {}) {
  switch (name) {
    case 'toastty_list_sessions': return socketRequest('mcp.session_list');
    case 'toastty_read_progress': {
      const payload = { conversationID: uuid(args.conversationID, 'conversationID'), limit: args.limit ?? 40 };
      if (!Number.isInteger(payload.limit) || payload.limit < 1 || payload.limit > 40) throw new Error('limit must be between 1 and 40');
      if (args.cursor !== undefined) payload.cursorJSON = JSON.stringify(args.cursor);
      return socketRequest('mcp.conversation_events', payload);
    }
    case 'toastty_send_message': return send(args, args.text);
    case 'toastty_request_skill': {
      const skill = requiredText(args.skillName, 'skillName', 80);
      if (!/^[a-z][a-z0-9_-]*$/.test(skill)) throw new Error('skillName has invalid characters');
      return send(args, `Please use $${skill} for this task: ${safePrompt(args.task, 'task')}`);
    }
    case 'toastty_request_merge': {
      const url = new URL(requiredText(args.pullRequestURL, 'pullRequestURL', 500));
      if (url.protocol !== 'https:' || url.hostname !== 'github.com' || !/^\/[^/]+\/[^/]+\/pull\/\d+\/?$/.test(url.pathname)) throw new Error('pullRequestURL must be a GitHub PR URL');
      return send(args, `Please prepare a merge handoff for ${url.href}. Check the exact PR and reviewed head, then ask the user to accept it. Do not merge or enable auto-merge based on this message alone.`);
    }
    case 'toastty_start_session': {
      const key = requiredText(args.clientRequestID, 'clientRequestID', 64);
      const workspaceID = uuid(args.workspaceID, 'workspaceID');
      const profileID = requiredText(args.profileID, 'profileID', 80);
      const text = safePrompt(args.text, 'text');
      const model = args.model === undefined ? undefined : requiredText(args.model, 'model', 200);
      const reasoningEffort = args.reasoningEffort === undefined ? undefined : requiredText(args.reasoningEffort, 'reasoningEffort', 40);
      const fingerprint = JSON.stringify([workspaceID.toLowerCase(), profileID, text, model, reasoningEffort]);
      const previous = starts.get(key);
      if (previous) {
        if (previous.fingerprint !== fingerprint) throw new Error('clientRequestID was already used with different start arguments');
        return previous.operation;
      }
      const operation = (async () => {
        let workspace;
        for (let attempt = 0; attempt < 40; attempt++) {
          const list = await socketRequest('app_control.run_query', { id: 'workspace.list', args: {} });
          workspace = list.workspaces?.find(item => item.workspaceID?.toLowerCase() === workspaceID.toLowerCase());
          if (!workspace || workspace.terminalCwds?.[0]) break;
          await new Promise(resolve => setTimeout(resolve, 250));
        }
        if (!workspace) throw new Error('workspace is unavailable');
        const cwd = workspace.terminalCwds?.[0];
        if (!cwd) throw new Error('workspace has no known terminal directory');
        const created = await action('workspace.tab.create', { workspaceID, activate: false });
        if (!created.panelID) throw new Error('terminal creation returned no panelID; inspect workspace before retrying');
        const launchArgs = { workspaceID, panelID: created.panelID, profileID, cwd, initialPrompt: text };
        if (model !== undefined) launchArgs.model = model;
        if (reasoningEffort !== undefined) launchArgs.reasoningEffort = reasoningEffort;
        try {
          const launched = await action('agent.launch', launchArgs);
          return { status: 'delivered_to_terminal', clientRequestID: key, tabID: created.tabID, panelID: created.panelID, sessionID: launched.sessionID, workspaceID };
        } catch (error) {
          return { status: 'uncertain', clientRequestID: key, tabID: created.tabID, panelID: created.panelID, workspaceID, detail: String(error.message) };
        }
      })();
      starts.set(key, { fingerprint, operation });
      return operation;
    }
    default: throw new Error(`Unknown tool: ${name}`);
  }
}

function write(message) { process.stdout.write(JSON.stringify(message) + '\n'); }
const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
for await (const line of lines) {
  let message;
  try { message = JSON.parse(line); } catch { continue; }
  if (message === null || typeof message !== 'object' || Array.isArray(message)) {
    write({ jsonrpc: '2.0', id: null, error: { code: -32600, message: 'Invalid Request' } });
    continue;
  }
  if (message.id === undefined) continue;
  const reply = { jsonrpc: '2.0', id: message.id };
  try {
    switch (message.method) {
      case 'initialize': reply.result = { protocolVersion: '2025-03-26', capabilities: { tools: {} }, serverInfo: { name: 'toastty-local', version: '0.1.0' } }; break;
      case 'ping': reply.result = {}; break;
      case 'tools/list': reply.result = { tools }; break;
      case 'tools/call': {
        const result = await call(message.params?.name, message.params?.arguments ?? {});
        reply.result = { content: [{ type: 'text', text: JSON.stringify(result) }], structuredContent: result };
        break;
      }
      default: throw new Error(`Unknown method: ${message.method}`);
    }
  } catch (error) {
    if (message.method === 'tools/call') reply.result = { isError: true, content: [{ type: 'text', text: String(error.message) }] };
    else reply.error = { code: -32601, message: String(error.message) };
  }
  write(reply);
}
