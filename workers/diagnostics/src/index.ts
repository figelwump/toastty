import { buildDiagnosticsSummary, validateDiagnosticsBundle, type DiagnosticsSummary } from "./schema";
import { scanForSecrets } from "./secretScan";

type DiagnosticsEnv = Env & {
  TOASTTY_DIAGNOSTICS_UPLOAD_KEY?: string;
  TOASTTY_DIAGNOSTICS_ADMIN_KEY?: string;
  TOASTTY_DIAGNOSTICS_ADMIN_BASE_URL?: string;
  TOASTTY_DIAGNOSTICS_NOTIFY_WEBHOOK_URL?: string;
};

type ReportEnvelope = {
  reportID: string;
  receivedAtMs: number;
  expiresAtMs: number;
  requestMetadata: {
    contentLength?: string;
    userAgent?: string;
    colo?: string;
  };
  summary: DiagnosticsSummary;
  bundle: unknown;
};

type DiagnosticsNotificationSummary = Omit<DiagnosticsSummary, "notePreview" | "secretScanFindings"> & {
  secretScanFindingCount: number;
};

type DiagnosticsNotificationPayload = {
  type: "toastty.diagnostics.submitted";
  reportID: string;
  adminURL?: string;
  skillPrompt: string;
  summary: DiagnosticsNotificationSummary;
};

export default {
  async fetch(request: Request, env: DiagnosticsEnv, ctx: ExecutionContext): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (request.method === "GET" && url.pathname === "/health") {
        return jsonResponse({ ok: true });
      }
      if (request.method === "POST" && url.pathname === "/v1/diagnostics") {
        return await handleSubmit(request, env, ctx);
      }
      if (request.method === "GET" && url.pathname.startsWith("/v1/diagnostics/")) {
        return await handleAdminGet(request, env, url.pathname.slice("/v1/diagnostics/".length));
      }
      if (url.pathname === "/v1/diagnostics" || url.pathname.startsWith("/v1/diagnostics/")) {
        return errorResponse(405, "method_not_allowed", "method is not allowed");
      }
      return errorResponse(404, "not_found", "not found");
    } catch (error) {
      if (error instanceof HTTPError) {
        return errorResponse(error.status, error.code, error.message);
      }
      console.error(JSON.stringify({ event: "diagnostics.unhandled_error", message: safeErrorMessage(error) }));
      return errorResponse(500, "internal_error", "internal error");
    }
  }
};

async function handleSubmit(request: Request, env: DiagnosticsEnv, ctx: ExecutionContext): Promise<Response> {
  await requireSecretHeader(
    request,
    env.TOASTTY_DIAGNOSTICS_UPLOAD_KEY,
    "x-toastty-diagnostics-key",
    "upload_key_missing"
  );
  requireJSONContentType(request);

  const maxBodyBytes = numberSetting(env.MAX_BODY_BYTES, 15_000_000);
  const minimumRedactionRulesVersion = numberSetting(env.MIN_REDACTION_RULES_VERSION, 1);
  const retentionDays = numberSetting(env.RETENTION_DAYS, 30);
  const rawBody = await readRequestText(request, maxBodyBytes);
  const secretScanFindings = scanForSecrets(rawBody);
  const secretScanOverride = request.headers.get("x-toastty-secret-scan-override") === "1";
  if (secretScanFindings.length > 0 && !secretScanOverride) {
    return errorResponse(422, "secret_scan_failed", "diagnostics bundle appears to contain unredacted secrets");
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(rawBody);
  } catch {
    return errorResponse(400, "json_invalid", "body must be valid JSON");
  }

  const validation = validateDiagnosticsBundle(parsed, minimumRedactionRulesVersion);
  if (!validation.ok) {
    return errorResponse(validation.status, validation.code, validation.message);
  }

  const reportID = makeReportID(new Date());
  const receivedAtMs = Date.now();
  const expiresAtMs = receivedAtMs + retentionDays * 24 * 60 * 60 * 1000;
  const summary = buildDiagnosticsSummary(validation.bundle, secretScanFindings, secretScanOverride);
  const envelope: ReportEnvelope = {
    reportID,
    receivedAtMs,
    expiresAtMs,
    requestMetadata: {
      contentLength: request.headers.get("content-length") ?? undefined,
      userAgent: request.headers.get("user-agent") ?? undefined,
      colo: typeof request.cf?.colo === "string" ? request.cf.colo : undefined
    },
    summary,
    bundle: parsed
  };

  const key = objectKeyForReportID(reportID);
  await env.DIAGNOSTICS_BUCKET.put(key, JSON.stringify(envelope), {
    httpMetadata: { contentType: "application/json; charset=utf-8" },
    customMetadata: {
      reportID,
      receivedAtMs: String(receivedAtMs),
      expiresAtMs: String(expiresAtMs)
    }
  });

  if (env.TOASTTY_DIAGNOSTICS_NOTIFY_WEBHOOK_URL) {
    ctx.waitUntil(sendNotification(
      env.TOASTTY_DIAGNOSTICS_NOTIFY_WEBHOOK_URL,
      diagnosticsNotificationPayload(
        reportID,
        adminURLForBaseURL(env.TOASTTY_DIAGNOSTICS_ADMIN_BASE_URL, reportID),
        summary
      )
    ));
  }

  return jsonResponse({ reportID, receivedAtMs, expiresAtMs }, 201);
}

async function handleAdminGet(request: Request, env: DiagnosticsEnv, rawReportID: string): Promise<Response> {
  await requireSecretHeader(request, env.TOASTTY_DIAGNOSTICS_ADMIN_KEY, "x-toastty-admin-key", "admin_key_missing");
  const reportID = decodeURIComponent(rawReportID);
  if (!/^TT-[0-9]{8}-[A-Z2-9]{16}$/.test(reportID)) {
    return errorResponse(404, "report_not_found", "report not found");
  }

  const object = await env.DIAGNOSTICS_BUCKET.get(objectKeyForReportID(reportID));
  if (!object) {
    return errorResponse(404, "report_not_found", "report not found");
  }

  return new Response(object.body, {
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store"
    }
  });
}

function requireJSONContentType(request: Request): void {
  const contentType = request.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    throw new HTTPError(415, "unsupported_media_type", "content-type must be application/json");
  }
}

async function readRequestText(request: Request, maxBodyBytes: number): Promise<string> {
  const contentLength = request.headers.get("content-length");
  if (contentLength) {
    const parsed = Number(contentLength);
    if (Number.isFinite(parsed) && parsed > maxBodyBytes) {
      throw new HTTPError(413, "payload_too_large", "diagnostics payload is too large");
    }
  }
  if (!request.body) {
    return "";
  }

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const result = await reader.read();
    if (result.done) {
      break;
    }
    total += result.value.byteLength;
    if (total > maxBodyBytes) {
      throw new HTTPError(413, "payload_too_large", "diagnostics payload is too large");
    }
    chunks.push(result.value);
  }

  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }

  try {
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes);
  } catch {
    throw new HTTPError(400, "utf8_invalid", "body must be valid UTF-8");
  }
}

async function requireSecretHeader(
  request: Request,
  expectedSecret: string | undefined,
  headerName: string,
  missingCode: string
): Promise<void> {
  if (!expectedSecret) {
    throw new HTTPError(503, missingCode, "diagnostics service is not configured");
  }
  const actualSecret = request.headers.get(headerName) ?? "";
  if (!(await timingSafeEqual(actualSecret, expectedSecret))) {
    throw new HTTPError(401, "unauthorized", "unauthorized");
  }
}

async function timingSafeEqual(actual: string, expected: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const actualBytes = encoder.encode(actual);
  const expectedBytes = encoder.encode(expected);
  const length = Math.max(actualBytes.length, expectedBytes.length, 1);
  const actualPadded = new Uint8Array(length);
  const expectedPadded = new Uint8Array(length);
  actualPadded.set(actualBytes);
  expectedPadded.set(expectedBytes);

  type TimingSafeSubtle = SubtleCrypto & {
    timingSafeEqual?: (left: Uint8Array, right: Uint8Array) => boolean | Promise<boolean>;
  };
  const subtle = crypto.subtle as TimingSafeSubtle;
  if (subtle.timingSafeEqual) {
    return (await subtle.timingSafeEqual(actualPadded, expectedPadded))
      && actualBytes.length === expectedBytes.length;
  }

  let diff = actualBytes.length ^ expectedBytes.length;
  for (let index = 0; index < length; index += 1) {
    diff |= actualPadded[index] ^ expectedPadded[index];
  }
  return diff === 0;
}

function makeReportID(date: Date): string {
  const stamp = date.toISOString().slice(0, 10).replaceAll("-", "");
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  let suffix = "";
  for (const byte of bytes) {
    suffix += alphabet[byte & 31];
  }
  return `TT-${stamp}-${suffix}`;
}

function objectKeyForReportID(reportID: string): string {
  const date = reportID.slice(3, 11);
  return `reports/${date.slice(0, 4)}/${date.slice(4, 6)}/${date.slice(6, 8)}/${reportID}.json`;
}

async function sendNotification(webhookURL: string, payload: DiagnosticsNotificationPayload): Promise<void> {
  try {
    const response = await fetch(webhookURL, {
      method: "POST",
      headers: { "content-type": "application/json; charset=utf-8" },
      body: JSON.stringify(payload)
    });
    if (!response.ok) {
      console.warn(JSON.stringify({
        event: "diagnostics.notification_failed",
        reportID: payload.reportID,
        status: response.status
      }));
    }
  } catch (error) {
    console.warn(JSON.stringify({
      event: "diagnostics.notification_failed",
      reportID: payload.reportID,
      message: safeErrorMessage(error)
    }));
  }
}

export function diagnosticsNotificationPayload(
  reportID: string,
  adminURL: string | undefined,
  summary: DiagnosticsSummary
): DiagnosticsNotificationPayload {
  const payload: DiagnosticsNotificationPayload = {
    type: "toastty.diagnostics.submitted",
    reportID,
    skillPrompt: `Use $toastty-diagnostics to fetch and summarize ${reportID}.`,
    summary: notificationSummary(summary)
  };
  if (adminURL) {
    payload.adminURL = adminURL;
  }
  return payload;
}

export function notificationSummary(summary: DiagnosticsSummary): DiagnosticsNotificationSummary {
  const { notePreview: _, secretScanFindings, ...safeSummary } = summary;
  return {
    ...safeSummary,
    secretScanFindingCount: secretScanFindings.length
  };
}

export function adminURLForBaseURL(baseURL: string | undefined, reportID: string): string | undefined {
  if (!baseURL) {
    return undefined;
  }
  let url: URL;
  try {
    url = new URL(baseURL);
  } catch {
    return undefined;
  }
  const basePath = url.pathname.replace(/\/+$/, "");
  if (basePath.endsWith("/v1/diagnostics")) {
    url.pathname = `${basePath}/${encodeURIComponent(reportID)}`;
  } else {
    url.pathname = `${basePath}/v1/diagnostics/${encodeURIComponent(reportID)}`;
  }
  url.search = "";
  url.hash = "";
  return url.toString();
}

function numberSetting(value: string | undefined, fallback: number): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function jsonResponse(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store"
    }
  });
}

function errorResponse(status: number, code: string, message: string): Response {
  return jsonResponse({ error: { code, message } }, status);
}

function safeErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

class HTTPError extends Error {
  status: number;
  code: string;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}
