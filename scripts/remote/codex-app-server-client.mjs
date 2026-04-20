#!/usr/bin/env node

import { appendFile, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

const EXIT_PASS = 0;
const EXIT_AGENT_ERROR = 2;
const EXIT_TIMEOUT = 3;
const EXIT_SETUP_ERROR = 4;
const REQUEST_TIMEOUT_MS = 20_000;

function parseArgs(argv) {
  const args = new Map();

  for (let index = 2; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith("--")) {
      throw new Error(`Unexpected argument: ${argument}`);
    }

    const key = argument.slice(2);
    const value = argv[index + 1];
    if (value === undefined || value.startsWith("--")) {
      throw new Error(`Missing value for --${key}`);
    }

    args.set(key, value);
    index += 1;
  }

  return args;
}

function isoNow() {
  return new Date().toISOString();
}

function durationSeconds(startedAt, endedAt) {
  return Math.max(
    0,
    Math.round((Date.parse(endedAt) - Date.parse(startedAt)) / 1000),
  );
}

function normalizeTokenUsage(value) {
  return {
    input: Number(value?.inputTokens ?? 0),
    cachedInput: Number(value?.cachedInputTokens ?? 0),
    output: Number(value?.outputTokens ?? 0),
    reasoningOutput: Number(value?.reasoningOutputTokens ?? 0),
    total: Number(value?.totalTokens ?? 0),
  };
}

function buildFailureReason(kind, message) {
  return { kind, message };
}

function defaultApprovalPolicy() {
  return {
    granular: {
      sandbox_approval: false,
      rules: false,
      skill_approval: false,
      request_permissions: false,
      mcp_elicitations: true,
    },
  };
}

function parseApprovalPolicy(rawValue) {
  if (!rawValue) {
    return defaultApprovalPolicy();
  }

  const trimmed = rawValue.trim();
  if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
    try {
      return JSON.parse(trimmed);
    } catch (error) {
      throw new Error(`Invalid --approval-policy JSON: ${String(error)}`);
    }
  }

  return trimmed;
}

function extractToolText(item) {
  const parts = [];

  for (const contentItem of item?.result?.content ?? []) {
    if (typeof contentItem?.text === "string" && contentItem.text.length > 0) {
      parts.push(contentItem.text);
    }
  }

  if (typeof item?.error === "string" && item.error.length > 0) {
    parts.push(item.error);
  }

  return parts.join("\n").trim();
}

function classifyComputerUseFailure(message, toolName) {
  const normalized = message.toLowerCase();

  if (normalized.includes("approval denied")) {
    return {
      priority: 100,
      status: "setup_error",
      failureReason: buildFailureReason("approval_denied", message),
    };
  }

  if (
    normalized.includes("procnotfound") ||
    normalized.includes("no eligible process")
  ) {
    return {
      priority: 80,
      status: "setup_error",
      failureReason: buildFailureReason("app_not_found", message),
    };
  }

  if (
    normalized.includes("sender process is not authenticated") ||
    normalized.includes("apple event error -10000") ||
    normalized.includes("not authorized to send apple events")
  ) {
    return {
      priority: 90,
      status: "setup_error",
      failureReason: buildFailureReason(
        "apple_event_not_authenticated",
        message,
      ),
    };
  }

  return {
    priority: 10,
    status: "agent_error",
    failureReason: buildFailureReason(
      "computer_use_tool_failed",
      message || `Computer Use tool ${toolName} failed`,
    ),
  };
}

function summarizeAppList(result) {
  const data = Array.isArray(result?.data) ? result.data : [];

  return {
    appListCount: data.length,
  };
}

const args = parseArgs(process.argv);
const wsUrl = args.get("ws-url");
const cwd = args.get("cwd");
const promptPath = args.get("prompt-file");
const transcriptPath = args.get("transcript-path");
const summaryPath = args.get("summary-path");
const timeoutSeconds = Number(args.get("timeout-seconds") ?? "300");
const approvalPolicy = parseApprovalPolicy(args.get("approval-policy"));
const sandbox = args.get("sandbox") ?? "read-only";

if (!wsUrl || !cwd || !promptPath || !transcriptPath || !summaryPath) {
  throw new Error(
    "--ws-url, --cwd, --prompt-file, --transcript-path, and --summary-path are required",
  );
}

await mkdir(path.dirname(transcriptPath), { recursive: true });
await mkdir(path.dirname(summaryPath), { recursive: true });

const prompt = await readFile(promptPath, "utf8");
const expectsComputerUse = prompt.includes("@Computer Use");
const pending = new Map();
let nextRequestId = 1;
let initialized = false;
let activeThreadId = null;
let activeTurnId = null;
let appListCount = 0;
let computerUseReady = null;
let finalText = "";
let tokensUsed = normalizeTokenUsage(null);
let finished = false;
let closeExpected = false;
let completionTimer = null;
let computerUseToolCallsStarted = 0;
let computerUseToolCallsSucceeded = 0;
let latestComputerUseFailure = null;
let hasTokenUsageUpdate = false;
let turnCompletedObserved = false;
let pendingCompletion = null;
let mcpElicitationsAccepted = 0;
let mcpElicitationsDeclined = 0;
const startedAt = isoNow();

const socket = new WebSocket(wsUrl);

async function writeTranscript(entry) {
  await appendFile(transcriptPath, `${JSON.stringify(entry)}\n`, "utf8");
}

async function writeSummary(summary) {
  await writeFile(summaryPath, `${JSON.stringify(summary, null, 2)}\n`, "utf8");
}

async function finishPendingCompletion() {
  if (!pendingCompletion) {
    return;
  }

  const completion = pendingCompletion;
  pendingCompletion = null;
  await finish(completion.status, completion.options);
}

function settlePending(message) {
  for (const pendingRequest of pending.values()) {
    clearTimeout(pendingRequest.timer);
    pendingRequest.reject(new Error(message));
  }
  pending.clear();
}

async function finish(status, options = {}) {
  if (finished) {
    return;
  }
  finished = true;
  clearTimeout(timeoutTimer);
  if (completionTimer) {
    clearTimeout(completionTimer);
  }

  const endedAt = isoNow();
  const summary = {
    schemaVersion: 1,
    status,
    startedAt,
    endedAt,
    durationSeconds: durationSeconds(startedAt, endedAt),
    threadId: activeThreadId,
    turnId: activeTurnId,
    cwd,
    wsUrl,
    approvalPolicy,
    sandbox,
    appListCount,
    computerUseReady,
    mcpElicitationsAccepted,
    mcpElicitationsDeclined,
    computerUseToolCallsStarted,
    computerUseToolCallsSucceeded,
    tokensUsed,
    finalText: finalText.trim(),
    turnStatus: options.turnStatus ?? null,
    failureReason:
      options.failureReason ??
      (status === "pass" ? null : latestComputerUseFailure?.failureReason ?? null),
  };

  await writeTranscript({
    ts: endedAt,
    direction: "client",
    type: "session_finished",
    summary,
  });
  await writeSummary(summary);

  closeExpected = true;
  settlePending("Session finished");
  try {
    socket.close();
  } catch {
    // Ignore close failures during teardown.
  }

  let exitCode = EXIT_SETUP_ERROR;
  if (status === "pass") {
    exitCode = EXIT_PASS;
  } else if (status === "agent_error") {
    exitCode = EXIT_AGENT_ERROR;
  } else if (status === "timeout") {
    exitCode = EXIT_TIMEOUT;
  }

  process.exit(exitCode);
}

function sendRequest(method, params) {
  const id = nextRequestId;
  nextRequestId += 1;

  const payload = {
    jsonrpc: "2.0",
    id,
    method,
    params,
  };

  socket.send(JSON.stringify(payload));
  void writeTranscript({
    ts: isoNow(),
    direction: "client",
    type: "request",
    id,
    method,
    params,
  });

  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`${method} timed out after ${REQUEST_TIMEOUT_MS}ms`));
    }, REQUEST_TIMEOUT_MS);

    pending.set(id, { method, resolve, reject, timer });
  });
}

function sendNotification(method, params = undefined) {
  const payload = {
    jsonrpc: "2.0",
    method,
  };

  if (params !== undefined) {
    payload.params = params;
  }

  socket.send(JSON.stringify(payload));
  void writeTranscript({
    ts: isoNow(),
    direction: "client",
    type: "notification",
    method,
    params,
  });
}

function sendServerResult(id, result) {
  const payload = {
    jsonrpc: "2.0",
    id,
    result,
  };

  socket.send(JSON.stringify(payload));
  void writeTranscript({
    ts: isoNow(),
    direction: "client",
    type: "response",
    id,
    result,
  });
}

function isResponseMessage(message) {
  return Object.prototype.hasOwnProperty.call(message, "result") ||
    Object.prototype.hasOwnProperty.call(message, "error");
}

function isServerRequestMessage(message) {
  return (
    Object.prototype.hasOwnProperty.call(message, "id") &&
    !isResponseMessage(message) &&
    typeof message.method === "string"
  );
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function preferredPersistChoice(meta) {
  const persist = meta?.persist;

  if (persist === "always" || persist === "session") {
    return persist;
  }

  if (Array.isArray(persist)) {
    if (persist.includes("session")) {
      return "session";
    }
    if (persist.includes("always")) {
      return "always";
    }
  }

  return null;
}

function enumOptions(schema) {
  if (!isRecord(schema)) {
    return [];
  }

  if (Array.isArray(schema.enum)) {
    return schema.enum.filter((value) => typeof value === "string");
  }

  if (Array.isArray(schema.oneOf)) {
    return schema.oneOf
      .map((entry) => entry?.const)
      .filter((value) => typeof value === "string");
  }

  if (isRecord(schema.items) && Array.isArray(schema.items.enum)) {
    return schema.items.enum.filter((value) => typeof value === "string");
  }

  if (isRecord(schema.items) && Array.isArray(schema.items.oneOf)) {
    return schema.items.oneOf
      .map((entry) => entry?.const)
      .filter((value) => typeof value === "string");
  }

  return [];
}

function chooseEnumOption(fieldName, schema, meta) {
  const options = enumOptions(schema);
  if (options.length === 0) {
    return null;
  }

  const persistChoice = preferredPersistChoice(meta);
  if (
    persistChoice &&
    /(persist|scope|remember|save)/i.test(fieldName) &&
    options.includes(persistChoice)
  ) {
    return persistChoice;
  }

  const preferredValues = [
    "session",
    "always",
    "accept",
    "approve",
    "allow",
    "yes",
    "true",
    "continue",
    "ok",
  ];

  for (const preferredValue of preferredValues) {
    if (options.includes(preferredValue)) {
      return preferredValue;
    }
  }

  return options[0];
}

function chooseBooleanValue(fieldName, schema) {
  if (typeof schema.default === "boolean") {
    return schema.default;
  }

  if (/(deny|decline|reject|block|cancel|abort)/i.test(fieldName)) {
    return false;
  }

  return true;
}

function chooseStringValue(fieldName, schema, meta) {
  if (typeof schema.default === "string") {
    return schema.default;
  }

  const enumChoice = chooseEnumOption(fieldName, schema, meta);
  if (enumChoice !== null) {
    return enumChoice;
  }

  if (/(persist|scope|remember|save)/i.test(fieldName)) {
    return preferredPersistChoice(meta) ?? "session";
  }

  if (/(decision|action|approval|allow|accept|confirm)/i.test(fieldName)) {
    return "accept";
  }

  const minLength = Number(schema.minLength ?? 0);
  if (minLength > 0) {
    return "approved";
  }

  return "";
}

function chooseNumberValue(schema) {
  if (typeof schema.default === "number") {
    return schema.default;
  }

  if (typeof schema.minimum === "number") {
    return schema.minimum;
  }

  return 0;
}

function chooseArrayValue(fieldName, schema, meta) {
  if (Array.isArray(schema.default)) {
    return schema.default;
  }

  const enumChoice = chooseEnumOption(fieldName, schema, meta);
  if (enumChoice !== null) {
    return [enumChoice];
  }

  return [];
}

function buildMcpElicitationContent(request) {
  if (request.mode !== "form") {
    return null;
  }

  const schema = request.requestedSchema;
  if (!isRecord(schema) || !isRecord(schema.properties)) {
    return {};
  }

  const meta = isRecord(request._meta) ? request._meta : {};
  const content = {};
  const required = new Set(
    Array.isArray(schema.required)
      ? schema.required.filter((value) => typeof value === "string")
      : [],
  );

  for (const [fieldName, fieldSchema] of Object.entries(schema.properties)) {
    if (!isRecord(fieldSchema)) {
      continue;
    }

    let value;
    switch (fieldSchema.type) {
      case "string":
        value = chooseStringValue(fieldName, fieldSchema, meta);
        break;
      case "boolean":
        value = chooseBooleanValue(fieldName, fieldSchema);
        break;
      case "number":
      case "integer":
        value = chooseNumberValue(fieldSchema);
        break;
      case "array":
        value = chooseArrayValue(fieldName, fieldSchema, meta);
        break;
      default:
        value = undefined;
    }

    if (value !== undefined && (required.has(fieldName) || value !== "")) {
      content[fieldName] = value;
    }
  }

  return content;
}

function shouldAutoAcceptMcpElicitation(params) {
  if (params?.serverName !== "computer-use" || params?.mode !== "form") {
    return false;
  }

  // Keep unattended approvals narrow: only accept the known app-access prompt
  // shape, or an explicit MCP tool-call approval marker from the server.
  const properties = isRecord(params?.requestedSchema?.properties)
    ? params.requestedSchema.properties
    : {};
  if (
    Object.keys(properties).length === 0 &&
    typeof params?.message === "string" &&
    /^Allow Codex to use /i.test(params.message)
  ) {
    return true;
  }

  const meta = isRecord(params?._meta) ? params._meta : {};
  return meta.codex_approval_kind === "mcp_tool_call";
}

async function handleServerRequest(message) {
  const { id, method, params = {} } = message;

  if (method === "mcpServer/elicitation/request") {
    if (shouldAutoAcceptMcpElicitation(params)) {
      const content = buildMcpElicitationContent(params);

      mcpElicitationsAccepted += 1;
      sendServerResult(id, {
        action: "accept",
        content,
        _meta: null,
      });
      return;
    }

    mcpElicitationsDeclined += 1;
    sendServerResult(id, {
      action: "decline",
      content: null,
      _meta: null,
    });
    return;
  }

  await finish("setup_error", {
    failureReason: buildFailureReason(
      "user_input_required",
      `Server requested interactive input via ${method}`,
    ),
  });
}

socket.onopen = () => {
  void writeTranscript({
    ts: isoNow(),
    direction: "client",
    type: "socket_open",
    wsUrl,
  });

  (async () => {
    try {
      await sendRequest("initialize", {
        clientInfo: {
          name: "toastty-computer-use-e2e",
          title: "Toastty Computer Use E2E",
          version: "0.1.0",
        },
        capabilities: {
          experimentalApi: true,
        },
      });
      initialized = true;
      // app-server expects an explicit follow-up notification after initialize.
      sendNotification("initialized");

      const threadResponse = await sendRequest("thread/start", {
        cwd,
        approvalPolicy,
        sandbox,
        ephemeral: true,
        experimentalRawEvents: false,
        persistExtendedHistory: true,
      });
      activeThreadId = threadResponse?.thread?.id ?? null;

      const appListResponse = await sendRequest("app/list", {
        threadId: activeThreadId,
        forceRefetch: false,
      });
      const appSummary = summarizeAppList(appListResponse);
      appListCount = appSummary.appListCount;

      const turnResponse = await sendRequest("turn/start", {
        threadId: activeThreadId,
        input: [
          {
            type: "text",
            text: prompt,
            text_elements: [],
          },
        ],
      });
      activeTurnId = turnResponse?.turn?.id ?? null;
    } catch (error) {
      await finish("setup_error", {
        failureReason: buildFailureReason("protocol_error", String(error)),
      });
    }
  })();
};

socket.onmessage = (event) => {
  void (async () => {
    let message;
    try {
      message = JSON.parse(event.data.toString());
    } catch (error) {
      await finish("setup_error", {
        failureReason: buildFailureReason(
          "invalid_json",
          `Failed to parse server message: ${String(error)}`,
        ),
      });
      return;
    }

    await writeTranscript({
      ts: isoNow(),
      direction: "server",
      type: isResponseMessage(message)
        ? "response"
        : isServerRequestMessage(message)
        ? "server_request"
        : "notification",
      payload: message,
    });

    if (Object.prototype.hasOwnProperty.call(message, "id") && pending.has(message.id)) {
      const pendingRequest = pending.get(message.id);
      pending.delete(message.id);
      clearTimeout(pendingRequest.timer);

      if (message.error) {
        pendingRequest.reject(
          new Error(`${pendingRequest.method}: ${JSON.stringify(message.error)}`),
        );
      } else {
        pendingRequest.resolve(message.result);
      }
      return;
    }

    if (isServerRequestMessage(message)) {
      await handleServerRequest(message);
      return;
    }

    const method = message.method;
    const params = message.params ?? {};

    if (method === "item/agentMessage/delta" && params.threadId === activeThreadId) {
      if (params.turnId !== activeTurnId) {
        return;
      }
      finalText += params.delta ?? "";
      return;
    }

    if (method === "thread/tokenUsage/updated" && params.threadId === activeThreadId) {
      hasTokenUsageUpdate = true;
      tokensUsed = normalizeTokenUsage(params.tokenUsage?.total ?? params.tokenUsage);
      if (turnCompletedObserved) {
        await finishPendingCompletion();
      }
      return;
    }

    if (method === "mcpServer/startupStatus/updated" && params.name === "computer-use") {
      if (params.status === "ready") {
        computerUseReady = true;
      } else if (computerUseReady === null) {
        computerUseReady = false;
      }
      return;
    }

    if (
      method === "item/started" &&
      params.threadId === activeThreadId &&
      params.item?.type === "mcpToolCall" &&
      params.item?.server === "computer-use"
    ) {
      computerUseToolCallsStarted += 1;
      return;
    }

    if (
      method === "item/completed" &&
      params.threadId === activeThreadId &&
      params.item?.type === "mcpToolCall" &&
      params.item?.server === "computer-use"
    ) {
      if (params.item?.status === "completed") {
        computerUseToolCallsSucceeded += 1;
      } else if (params.item?.status === "failed") {
        const message =
          extractToolText(params.item) ||
          `Computer Use tool ${params.item?.tool ?? "unknown"} failed`;
        const classifiedFailure = classifyComputerUseFailure(
          message,
          params.item?.tool ?? "unknown",
        );
        if (
          !latestComputerUseFailure ||
          classifiedFailure.priority >= latestComputerUseFailure.priority
        ) {
          latestComputerUseFailure = classifiedFailure;
        }
      }
      return;
    }

    if (method === "error" && params.threadId === activeThreadId) {
      await finish("agent_error", {
        failureReason: buildFailureReason(
          "server_error",
          JSON.stringify(params),
        ),
      });
      return;
    }

    if (method === "turn/completed" && params.threadId === activeThreadId) {
      const turn = params.turn ?? {};
      const turnStatus = turn.status ?? null;
      turnCompletedObserved = true;
      clearTimeout(timeoutTimer);

      if (computerUseToolCallsSucceeded === 0 && latestComputerUseFailure) {
        pendingCompletion = {
          status: latestComputerUseFailure.status,
          options: {
            turnStatus,
            failureReason: latestComputerUseFailure.failureReason,
          },
        };
      } else if (expectsComputerUse && computerUseToolCallsStarted === 0) {
        pendingCompletion = {
          status: "agent_error",
          options: {
            turnStatus,
            failureReason: buildFailureReason(
              "computer_use_not_invoked",
              "Turn completed without invoking any Computer Use tool calls",
            ),
          },
        };
      } else if (turnStatus === "completed") {
        pendingCompletion = {
          status: "pass",
          options: { turnStatus },
        };
      } else {
        const errorMessage =
          turn?.error?.message ??
          turn?.error?.additionalDetails ??
          "Turn did not complete successfully";
        pendingCompletion = {
          status: "agent_error",
          options: {
            turnStatus,
            failureReason: buildFailureReason("turn_failed", errorMessage),
          },
        };
      }

      completionTimer = setTimeout(async () => {
        await finishPendingCompletion();
      }, 200);
      if (hasTokenUsageUpdate) {
        await finishPendingCompletion();
      }
      return;
    }
  })();
};

socket.onerror = (event) => {
  void writeTranscript({
    ts: isoNow(),
    direction: "client",
    type: "socket_error",
    message: event?.message ?? null,
  });
  if (turnCompletedObserved) {
    return;
  }
  void finish("setup_error", {
    failureReason: buildFailureReason("websocket_error", "WebSocket reported an error"),
  });
};

socket.onclose = () => {
  if (finished || closeExpected || turnCompletedObserved) {
    return;
  }

  void finish(initialized ? "agent_error" : "setup_error", {
    failureReason: buildFailureReason(
      initialized ? "unexpected_close" : "connection_failed",
      initialized
        ? "WebSocket closed before the turn completed"
        : "WebSocket closed before initialization completed",
    ),
  });
};

const timeoutTimer = setTimeout(() => {
  if (completionTimer) {
    clearTimeout(completionTimer);
  }
  void finish("timeout", {
    failureReason: buildFailureReason(
      "timeout",
      `Turn exceeded timeout of ${timeoutSeconds} seconds`,
    ),
  });
}, timeoutSeconds * 1000);
