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
const approvalPolicy = args.get("approval-policy") ?? "never";
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

function isResponseMessage(message) {
  return Object.prototype.hasOwnProperty.call(message, "result") ||
    Object.prototype.hasOwnProperty.call(message, "error");
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
      type: isResponseMessage(message) ? "response" : "notification",
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

    if (
      Object.prototype.hasOwnProperty.call(message, "id") &&
      !isResponseMessage(message) &&
      typeof message.method === "string"
    ) {
      await finish("setup_error", {
        failureReason: buildFailureReason(
          "user_input_required",
          `Server requested interactive input via ${message.method}`,
        ),
      });
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
