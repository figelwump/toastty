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

module.exports = function toasttyPiExtension(pi) {
  const sessionID = process.env.TOASTTY_SESSION_ID;
  const cliPath = process.env.TOASTTY_CLI_PATH;
  const telemetryLogPath = process.env.TOASTTY_PI_TELEMETRY_LOG_PATH;
  if (!sessionID || !cliPath || !telemetryLogPath) return;

  const pendingIngestLines = [];
  let activeIngest = false;

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

  pi.on("session_start", (event) => {
    emit("session_start", { reason: cleanString(event && event.reason) });
  });

  pi.on("agent_start", () => {
    emit("agent_start");
  });

  pi.on("tool_execution_start", (event) => {
    emit("tool_execution_start", {
      toolCallID: cleanString(event && event.toolCallId, 120),
      toolName: cleanString(event && event.toolName, 120),
      files: uniqueStrings(collectPaths(event && event.args)),
    });
  });

  pi.on("tool_execution_update", (event) => {
    emit("tool_execution_update", {
      toolCallID: cleanString(event && event.toolCallId, 120),
      toolName: cleanString(event && event.toolName, 120),
    });
  });

  pi.on("tool_execution_end", (event) => {
    emit("tool_execution_end", {
      toolCallID: cleanString(event && event.toolCallId, 120),
      toolName: cleanString(event && event.toolName, 120),
      isError: Boolean(event && event.isError),
      files: uniqueStrings([
        ...collectPaths(event && event.args),
        ...collectPaths(event && event.result),
      ]),
    });
  });

  pi.on("agent_end", () => {
    emit("agent_end");
  });

  pi.on("session_shutdown", (event) => {
    emit("session_shutdown", { reason: cleanString(event && event.reason) });
  });
};
