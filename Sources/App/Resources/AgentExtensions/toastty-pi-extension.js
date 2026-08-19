const fs = require("node:fs");
const { spawn } = require("node:child_process");

const MAX_FIELD_LENGTH = 500;
const MAX_PATHS = 50;
const MAX_QUEUED_EVENTS = 100;

function cleanString(value, limit = MAX_FIELD_LENGTH) {
  if (typeof value !== "string") return undefined;
  const collapsed = value.split(/\s+/).filter(Boolean).join(" ");
  if (!collapsed) return undefined;
  return collapsed.length > limit ? `${collapsed.slice(0, Math.max(0, limit - 3))}...` : collapsed;
}

function cleanPath(value, limit = 1000) {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  if (!trimmed) return undefined;
  return trimmed.length > limit ? trimmed.slice(0, limit) : trimmed;
}

function lastPathComponent(path) {
  const cleaned = cleanString(path, 160);
  if (!cleaned) return undefined;
  const parts = cleaned.split(/[\\/]/).filter(Boolean);
  return parts.length > 0 ? parts[parts.length - 1] : cleaned;
}

function compactPath(path) {
  return lastPathComponent(path) || cleanString(path, 120);
}

function commandPreview(command) {
  return cleanString(command, 120);
}

function bashDetail(command) {
  const preview = commandPreview(command);
  if (!preview) return "Running a shell command";
  const lower = preview.toLowerCase();
  if (
    /\bxcodebuild\b.*\btest\b/.test(lower) ||
    /\b(swift test|tuist test|npm test|npm run test|pnpm test|yarn test|bun test|pytest|pytest3|go test|cargo test|ctest)\b/.test(lower)
  ) {
    return "Running tests";
  }
  if (/\b(xcodebuild|swift build|tuist build|npm run build|pnpm build|yarn build|bun run build|make|ninja|cmake)\b/.test(lower)) {
    return "Building project";
  }
  if (/\b(git status|git diff|git log|git show|git rev-parse|git branch)\b/.test(lower)) {
    return "Checking git state";
  }
  if (/\b(rg|grep|ag|ack)\b/.test(lower)) {
    return "Searching the workspace";
  }
  if (/\b(ls|find|fd|tree)\b/.test(lower)) {
    return "Listing files";
  }
  return "Running a shell command";
}

function toolDetail(toolName, input) {
  const name = cleanString(toolName, 80);
  switch (name) {
    case "bash":
      return bashDetail(input && input.command);
    case "read": {
      const target = compactPath(input && input.path);
      return target ? `Reading ${target}` : "Reading files";
    }
    case "edit": {
      const target = compactPath(input && input.path);
      return target ? `Editing ${target}` : "Editing files";
    }
    case "write": {
      const target = compactPath(input && input.path);
      return target ? `Writing ${target}` : "Writing a file";
    }
    case "grep": {
      const pattern = cleanString(input && input.pattern, 80);
      return pattern ? `Searching for ${pattern}` : "Searching the workspace";
    }
    case "find": {
      const pattern = cleanString(input && input.pattern, 80);
      return pattern ? `Finding ${pattern}` : "Finding files";
    }
    case "ls": {
      const target = compactPath(input && input.path);
      return target ? `Listing ${target}` : "Listing files";
    }
    default:
      return name ? `Using ${displayToolName(name)}` : "Pi is using a tool";
  }
}

function displayToolName(raw) {
  return raw
    .replace(/[_-]+/g, " ")
    .split(/\s+/)
    .filter(Boolean)
    .map((word) => `${word.charAt(0).toUpperCase()}${word.slice(1)}`)
    .join(" ");
}

function collectPaths(value, output = []) {
  if (output.length >= MAX_PATHS || value == null) return output;
  if (typeof value === "string") {
    if (value.includes("/") || value.startsWith(".")) output.push(value);
    return output;
  }
  if (Array.isArray(value)) {
    for (const entry of value) collectPaths(entry, output);
    return output;
  }
  if (typeof value === "object") {
    for (const [key, entry] of Object.entries(value)) {
      const lowerKey = key.toLowerCase();
      if (
        typeof entry === "string" &&
        (lowerKey === "path" ||
          lowerKey === "file" ||
          lowerKey === "filepath" ||
          lowerKey === "file_path" ||
          lowerKey.endsWith("path"))
      ) {
        output.push(entry);
      } else {
        collectPaths(entry, output);
      }
    }
  }
  return output;
}

function uniqueStrings(values) {
  const seen = new Set();
  const result = [];
  for (const value of values) {
    const cleaned = cleanString(value);
    if (!cleaned || seen.has(cleaned)) continue;
    seen.add(cleaned);
    result.push(cleaned);
    if (result.length >= MAX_PATHS) break;
  }
  return result;
}

function collectAssistantText(value, output = [], depth = 0) {
  if (depth > 8 || value == null) return output;
  if (typeof value === "string") {
    output.push(value);
    return output;
  }
  if (Array.isArray(value)) {
    for (const entry of value) collectAssistantText(entry, output, depth + 1);
    return output;
  }
  if (typeof value !== "object") return output;

  if (value.type === "text") {
    collectAssistantText(value.text, output, depth + 1);
    return output;
  }
  if (value.type === undefined && typeof value.text === "string") {
    collectAssistantText(value.text, output, depth + 1);
    return output;
  }
  if (value.type === undefined && value.content !== undefined) {
    collectAssistantText(value.content, output, depth + 1);
  }
  return output;
}

function assistantSummaryFromMessage(message) {
  if (!message || message.role !== "assistant") return undefined;
  const chunks = collectAssistantText(message.content !== undefined ? message.content : message);
  return cleanString(chunks.join(" "), 160);
}

function latestAssistantSummary(messages) {
  if (!Array.isArray(messages)) return undefined;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const summary = assistantSummaryFromMessage(messages[index]);
    if (summary) return summary;
  }
  return undefined;
}

module.exports = function toasttyPiExtension(pi) {
  const sessionID = process.env.TOASTTY_SESSION_ID;
  const cliPath = process.env.TOASTTY_CLI_PATH;
  const telemetryLogPath = process.env.TOASTTY_PI_TELEMETRY_LOG_PATH;
  if (!sessionID || !cliPath || !telemetryLogPath) return;

  const pendingIngestLines = [];
  let activeIngest = false;
  let currentPrompt;
  let lastAssistantSummary;
  const subagentTools = new Map();

  function cliEnvironment() {
    const env = {
      TOASTTY_SESSION_ID: sessionID,
    };
    for (const key of ["HOME", "PATH", "TOASTTY_PANEL_ID", "TOASTTY_SOCKET_PATH"]) {
      if (process.env[key]) env[key] = process.env[key];
    }
    return env;
  }

  function pumpIngestQueue() {
    if (activeIngest || pendingIngestLines.length === 0) return;
    activeIngest = true;
    const line = pendingIngestLines.shift();

    const child = spawn(cliPath, ["session", "ingest-agent-event", "--source", "pi-extension"], {
      stdio: ["pipe", "ignore", "ignore"],
      env: cliEnvironment(),
      detached: false,
    });

    let finished = false;
    function finish() {
      if (finished) return;
      finished = true;
      activeIngest = false;
      pumpIngestQueue();
    }

    child.on("error", finish);
    child.on("close", finish);
    child.stdin.on("error", () => {});
    child.stdin.end(line);
  }

  function enqueueIngest(line) {
    if (pendingIngestLines.length >= MAX_QUEUED_EVENTS) pendingIngestLines.shift();
    pendingIngestLines.push(line);
    pumpIngestQueue();
  }

  function emit(event, payload = {}) {
    const record = {
      source: "pi-extension",
      version: 1,
      toasttySessionID: sessionID,
      event,
      timestamp: new Date().toISOString(),
      ...payload,
    };
    const line = `${JSON.stringify(record)}\n`;
    try {
      fs.appendFileSync(telemetryLogPath, line);
    } catch (_) {}
    enqueueIngest(line);
  }

  function emitNativeSession(event, context) {
    const sessionManager = context && context.sessionManager;
    if (!sessionManager) return;

    const nativeSessionID = cleanString(
      typeof sessionManager.getSessionId === "function" ? sessionManager.getSessionId() : undefined,
      160
    );
    const sessionFilePath = cleanPath(
      typeof sessionManager.getSessionFile === "function" ? sessionManager.getSessionFile() : undefined
    );
    const cwd = cleanPath(
      typeof sessionManager.getCwd === "function" ? sessionManager.getCwd() : undefined
    );

    if (!nativeSessionID || !sessionFilePath || !cwd) return;
    emit("native_session", {
      nativeSessionID,
      sessionFilePath,
      cwd,
      reason: cleanString(event && event.reason, 80),
    });
  }

  function subagentToolCallID(event) {
    return cleanString(event && (event.toolCallId || event.toolCallID), 120);
  }

  function subagentToolName(event) {
    return cleanString(event && event.toolName, 120);
  }

  function subagentInput(event) {
    return (event && (event.input || event.args)) || {};
  }

  function emitSubagentActivity(phase, activity) {
    emit(`background_activity_${phase}`, {
      activityID: activity.id,
      displayName: cleanString(activity.displayName, 120) || "Sub-agent",
      modelIdentifier: cleanString(activity.modelIdentifier, 200),
    });
  }

  function startSubagentTool(event) {
    if (subagentToolName(event) !== "subagent") return;
    const toolCallID = subagentToolCallID(event);
    if (!toolCallID || subagentTools.has(toolCallID)) return;
    const input = subagentInput(event);
    let mode;
    let requests = [];
    if (Array.isArray(input.chain) && input.chain.length > 0) {
      mode = "chain";
      requests = [input.chain[0]];
    } else if (Array.isArray(input.tasks) && input.tasks.length > 0) {
      mode = "parallel";
      requests = input.tasks;
    } else if (input.agent && input.task) {
      mode = "single";
      requests = [{ agent: input.agent, task: input.task }];
    } else {
      return;
    }
    const activities = requests.slice(0, 8).map((request, index) => ({
      id: `pi-subagent:${toolCallID}:${index}`,
      displayName: cleanString(request && request.agent, 120) || "Sub-agent",
      modelIdentifier: undefined,
      finished: false,
    }));
    subagentTools.set(toolCallID, { mode, activities });
    for (const activity of activities) emitSubagentActivity("start", activity);
  }

  function updateSubagentTool(event) {
    if (subagentToolName(event) !== "subagent") return;
    const toolCallID = subagentToolCallID(event);
    const tracked = subagentTools.get(toolCallID);
    if (!tracked) return;
    const partialResult = (event && event.partialResult) || {};
    const details = partialResult.details || {};
    const results = Array.isArray(details.results) ? details.results : [];

    if (tracked.mode === "chain") {
      const result = results[results.length - 1];
      const activity = tracked.activities[0];
      if (!result || !activity || activity.finished) return;
      const displayName = cleanString(result.agent, 120) || activity.displayName;
      const modelIdentifier = cleanString(result.model, 200) || activity.modelIdentifier;
      if (displayName === activity.displayName && modelIdentifier === activity.modelIdentifier) return;
      activity.displayName = displayName;
      activity.modelIdentifier = modelIdentifier;
      emitSubagentActivity("start", activity);
      return;
    }

    for (let index = 0; index < tracked.activities.length; index += 1) {
      const activity = tracked.activities[index];
      const result = results[index];
      if (!result || activity.finished) continue;
      const modelIdentifier = cleanString(result.model, 200) || activity.modelIdentifier;
      if (modelIdentifier !== activity.modelIdentifier) {
        activity.modelIdentifier = modelIdentifier;
        emitSubagentActivity("start", activity);
      }
      if (tracked.mode === "parallel" && Number.isFinite(result.exitCode) && result.exitCode !== -1) {
        activity.finished = true;
        emitSubagentActivity("finish", activity);
      }
    }
  }

  function finishSubagentTool(event) {
    if (subagentToolName(event) !== "subagent") return;
    const toolCallID = subagentToolCallID(event);
    const tracked = subagentTools.get(toolCallID);
    if (!tracked) return;
    subagentTools.delete(toolCallID);
    for (const activity of tracked.activities) {
      if (activity.finished) continue;
      activity.finished = true;
      emitSubagentActivity("finish", activity);
    }
  }

  function finishAllSubagents() {
    for (const [toolCallID, tracked] of subagentTools) {
      subagentTools.delete(toolCallID);
      for (const activity of tracked.activities) {
        if (activity.finished) continue;
        activity.finished = true;
        emitSubagentActivity("finish", activity);
      }
    }
  }

  pi.on("session_start", (event, context) => {
    emitNativeSession(event, context);
    emit("session_start", { reason: cleanString(event && event.reason) });
  });

  pi.on("before_agent_start", (event) => {
    currentPrompt = cleanString(event && event.prompt, 160);
    lastAssistantSummary = undefined;
    emit("before_agent_start", { prompt: currentPrompt });
  });

  pi.on("agent_start", () => {
    if (currentPrompt) return;
    emit("agent_start");
  });

  pi.on("message_end", (event) => {
    const summary = assistantSummaryFromMessage(event && event.message);
    if (summary) lastAssistantSummary = summary;
  });

  pi.on("tool_call", (event) => {
    const input = event && event.input;
    startSubagentTool(event);
    emit("tool_call", {
      toolCallID: cleanString(event && event.toolCallId, 120),
      toolName: cleanString(event && event.toolName, 120),
      detail: toolDetail(event && event.toolName, input),
      files: uniqueStrings(collectPaths(input)),
    });
  });

  pi.on("tool_result", (event) => {
    finishSubagentTool(event);
    emit("tool_result", {
      toolCallID: cleanString(event && event.toolCallId, 120),
      toolName: cleanString(event && event.toolName, 120),
      isError: Boolean(event && event.isError),
      files: uniqueStrings([
        ...collectPaths(event && event.input),
        ...collectPaths(event && event.details),
      ]),
    });
  });

  pi.on("tool_execution_start", (event) => {
    startSubagentTool(event);
  });

  pi.on("tool_execution_update", (event) => {
    updateSubagentTool(event);
  });

  pi.on("tool_execution_end", (event) => {
    updateSubagentTool({ ...event, partialResult: event && event.result });
    finishSubagentTool(event);
  });

  pi.on("agent_end", (event) => {
    finishAllSubagents();
    const summary = latestAssistantSummary(event && event.messages) || lastAssistantSummary;
    emit("agent_end", { summary });
    currentPrompt = undefined;
    lastAssistantSummary = undefined;
  });

  pi.on("session_shutdown", (event) => {
    finishAllSubagents();
    currentPrompt = undefined;
    lastAssistantSummary = undefined;
    emit("session_shutdown", { reason: cleanString(event && event.reason) });
  });
};
