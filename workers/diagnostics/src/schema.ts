import type { SecretScanFinding } from "./secretScan";

export type DiagnosticsBundle = {
  schemaVersion: number;
  generatedAtMs: number;
  note?: string;
  app?: Record<string, unknown>;
  logs?: Record<string, unknown>;
  shell?: Record<string, unknown>;
  socket?: Record<string, unknown>;
  system?: Record<string, unknown>;
  redaction?: {
    rulesVersion: number;
    redactedKeyCount: number;
  };
};

export type DiagnosticsSummary = {
  appVersion?: string;
  build?: string;
  runtimeLabel?: string;
  socketState?: string;
  currentLogSizeBytes?: number;
  currentLogTruncated?: boolean;
  previousLogSizeBytes?: number;
  previousLogTruncated?: boolean;
  redactionRulesVersion: number;
  redactedKeyCount: number;
  notePreview?: string;
  systemArch?: string;
  hardwareModel?: string;
  secretScanOverride: boolean;
  secretScanFindings: SecretScanFinding[];
};

export type ValidationResult =
  | { ok: true; bundle: DiagnosticsBundle }
  | { ok: false; status: number; code: string; message: string };

export function validateDiagnosticsBundle(value: unknown, minimumRedactionRulesVersion: number): ValidationResult {
  const object = asRecord(value);
  if (!object) {
    return invalid("schema_invalid", "body must be a JSON object");
  }

  const schemaVersion = numberValue(object.schemaVersion);
  if (schemaVersion !== 1) {
    return invalid("schema_unsupported", `schemaVersion ${String(object.schemaVersion)} is not supported`);
  }

  const generatedAtMs = numberValue(object.generatedAtMs);
  if (generatedAtMs === undefined) {
    return invalid("schema_invalid", "generatedAtMs must be a number");
  }

  const redaction = asRecord(object.redaction);
  if (!redaction) {
    return invalid("redaction_missing", "redaction metadata is required");
  }

  const rulesVersion = numberValue(redaction.rulesVersion);
  const redactedKeyCount = numberValue(redaction.redactedKeyCount);
  if (rulesVersion === undefined || redactedKeyCount === undefined) {
    return invalid("redaction_invalid", "redaction.rulesVersion and redaction.redactedKeyCount must be numbers");
  }
  if (rulesVersion < minimumRedactionRulesVersion) {
    return {
      ok: false,
      status: 400,
      code: "redaction_stale",
      message: `redaction rules v${rulesVersion} are too old; v${minimumRedactionRulesVersion} or newer is required`
    };
  }

  return {
    ok: true,
    bundle: {
      schemaVersion,
      generatedAtMs,
      note: stringValue(object.note),
      app: asRecord(object.app) ?? undefined,
      logs: asRecord(object.logs) ?? undefined,
      shell: asRecord(object.shell) ?? undefined,
      socket: asRecord(object.socket) ?? undefined,
      system: asRecord(object.system) ?? undefined,
      redaction: {
        rulesVersion,
        redactedKeyCount
      }
    }
  };
}

export function buildDiagnosticsSummary(
  bundle: DiagnosticsBundle,
  secretScanFindings: SecretScanFinding[],
  secretScanOverride: boolean
): DiagnosticsSummary {
  const app = bundle.app;
  const logs = bundle.logs;
  const system = bundle.system;
  const socket = bundle.socket;
  const redaction = bundle.redaction;

  return {
    appVersion: stringProperty(app, "shortVersion"),
    build: stringProperty(app, "build"),
    runtimeLabel: stringProperty(app, "runtimeLabel"),
    socketState: stringProperty(socket, "state"),
    currentLogSizeBytes: logNumber(logs, "current", "sizeBytes"),
    currentLogTruncated: logBool(logs, "current", "truncated"),
    previousLogSizeBytes: logNumber(logs, "previous", "sizeBytes"),
    previousLogTruncated: logBool(logs, "previous", "truncated"),
    redactionRulesVersion: redaction?.rulesVersion ?? 0,
    redactedKeyCount: redaction?.redactedKeyCount ?? 0,
    notePreview: preview(bundle.note),
    systemArch: stringProperty(system, "arch"),
    hardwareModel: stringProperty(system, "hardwareModel"),
    secretScanOverride,
    secretScanFindings
  };
}

function invalid(code: string, message: string): ValidationResult {
  return { ok: false, status: 400, code, message };
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return undefined;
  }
  return value as Record<string, unknown>;
}

function numberValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function stringProperty(object: Record<string, unknown> | undefined, key: string): string | undefined {
  return object ? stringValue(object[key]) : undefined;
}

function logNumber(logs: Record<string, unknown> | undefined, logKey: string, property: string): number | undefined {
  const log = logs ? asRecord(logs[logKey]) : undefined;
  return log ? numberValue(log[property]) : undefined;
}

function logBool(logs: Record<string, unknown> | undefined, logKey: string, property: string): boolean | undefined {
  const log = logs ? asRecord(logs[logKey]) : undefined;
  const value = log?.[property];
  return typeof value === "boolean" ? value : undefined;
}

function preview(value: string | undefined): string | undefined {
  if (!value) {
    return undefined;
  }
  const collapsed = value.replace(/\s+/g, " ").trim();
  if (!collapsed) {
    return undefined;
  }
  return collapsed.length > 160 ? `${collapsed.slice(0, 157)}...` : collapsed;
}
