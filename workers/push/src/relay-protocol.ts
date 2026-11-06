export const policy = {
  bodyBytes: 4096,
  titleBytes: 512,
  /** A task alert's question. It is the only free text besides the title. */
  detailBytes: 512,
  challengeSeconds: 300,
  activeSeconds: 90 * 24 * 3600,
  eventSeconds: 3600,
  verificationPerToken: 3,
  verificationPerIP: 30,
  verificationGlobal: 300,
  sendsPerMinute: 60,
  sendsGlobalPerMinute: 1000
} as const;

export type VerificationOutcome = "apple_accepted" | "apple_bad_device_token" | "apple_token_topic_mismatch"
  | "apple_unregistered" | "apple_provider_expired" | "apple_provider_rejected" | "apple_rate_limited"
  | "apple_provider_updates_limited" | "apple_server_error"
  | "apple_rejected" | "apple_response_unknown" | "apple_transport_unknown" | "provider_unavailable";
export type RelayDiagnostic = VerificationOutcome | "verification_result_unknown" | "existing_active"
  | "verification_token_limit" | "verification_ip_limit" | "verification_global_limit";

export function diagnosticHeaders(diagnostic?: RelayDiagnostic | null, providerRefreshAttempted = false): Record<string, string> {
  return { ...(diagnostic ? { "x-toastty-push-diagnostic": diagnostic } : {}),
    ...(providerRefreshAttempted ? { "x-toastty-push-provider-refresh": "attempted" } : {}) };
}

export class RelayError extends Error {
  constructor(readonly status: number, readonly code: string, readonly retryAfter?: number,
    readonly diagnostic?: RelayDiagnostic, readonly providerRefreshAttempted = false) { super(code); }
}

export function json(value: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return Response.json(value, { status, headers: { "cache-control": "no-store", ...headers } });
}

export function failure(error: unknown): Response {
  const known = error instanceof RelayError ? error : new RelayError(503, "service_unavailable");
  return json({ error: known.code }, known.status, {
    ...diagnosticHeaders(known.diagnostic, known.providerRefreshAttempted),
    ...(known.retryAfter === undefined ? {} : { "retry-after": String(known.retryAfter) })
  });
}

export async function readObject(request: Request, keys: readonly string[]): Promise<Record<string, unknown>> {
  return exactKeys(await readJSONObject(request), keys);
}

function exactKeys(object: Record<string, unknown>, keys: readonly string[]): Record<string, unknown> {
  if (Object.keys(object).length !== keys.length || keys.some(key => !Object.hasOwn(object, key))) {
    throw new RelayError(400, "invalid_request");
  }
  return object;
}

async function readJSONObject(request: Request): Promise<Record<string, unknown>> {
  if (!request.headers.get("content-type")?.toLowerCase().startsWith("application/json")) {
    throw new RelayError(415, "json_required");
  }
  const declared = request.headers.get("content-length");
  if (declared !== null && Number(declared) > policy.bodyBytes) throw new RelayError(413, "request_too_large");
  if (!request.body) throw new RelayError(400, "invalid_request");
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const part = await reader.read();
      if (part.done) break;
      length += part.value.byteLength;
      if (length > policy.bodyBytes) throw new RelayError(413, "request_too_large");
      chunks.push(part.value);
    }
  } finally { await reader.cancel().catch(() => {}); }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  let parsed: unknown;
  try { parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes)); }
  catch { throw new RelayError(400, "invalid_request"); }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new RelayError(400, "invalid_request");
  return parsed as Record<string, unknown>;
}

export function uuid(value: unknown): string {
  if (typeof value !== "string" || !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(value)) {
    throw new RelayError(400, "invalid_request");
  }
  return value.toLowerCase();
}

export function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

export function capability(value: unknown): string {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$/.test(value)) {
    throw new RelayError(400, "invalid_request");
  }
  return value;
}

export async function digest(value: string): Promise<string> {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  return Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
}

export function sameHash(first: string, second: string): boolean {
  const encoder = new TextEncoder();
  return first.length === second.length && crypto.subtle.timingSafeEqual(encoder.encode(first), encoder.encode(second));
}

export async function bearerHash(request: Request): Promise<string> {
  const authorization = request.headers.get("authorization") ?? "";
  try {
    if (!authorization.startsWith("Bearer ")) throw new Error();
    return await digest(capability(authorization.slice(7)));
  } catch { throw new RelayError(401, "unauthorized"); }
}

export interface Enrollment {
  registrationID: string;
  deviceToken: string;
  pairingID: string;
  managementToken: string;
  sendToken: string;
}

export async function enrollment(request: Request): Promise<Enrollment> {
  const value = await readObject(request, ["registrationID", "deviceToken", "pairingID", "managementToken", "sendToken"]);
  if (typeof value.deviceToken !== "string" || !/^(?:[a-f0-9]{2}){32,256}$/i.test(value.deviceToken)) {
    throw new RelayError(400, "invalid_request");
  }
  return {
    registrationID: uuid(value.registrationID), deviceToken: value.deviceToken.toLowerCase(),
    pairingID: uuid(value.pairingID), managementToken: capability(value.managementToken), sendToken: capability(value.sendToken)
  };
}

export interface SessionAlert {
  kind: "session"; eventID: string; conversationID: string; sessionTitle: string; status: "ready" | "needs_approval";
}

/** Why a task needs the user. The relay, not the Mac, words each alert, so
 * a send credential can choose only a task title, a question and a number. */
export type TaskAlertReason = "question" | "review" | "merge_stopped" | "setup_failed" | "move_failed" | "cleanup_stopped";
const taskAlertReasons: readonly TaskAlertReason[] = ["question", "review", "merge_stopped", "setup_failed", "move_failed", "cleanup_stopped"];

export interface TaskAlert {
  kind: "task"; eventID: string; taskID: string; conversationID: string | null; reason: TaskAlertReason;
  taskTitle: string; detail: string | null; pullRequestNumber: number | null;
}

/** A session alert has no `kind` field, as sent by Macs before task alerts.
 * A relay without task alerts rejects the task fields, and the Mac then
 * sends the session alert it would have sent before. */
export async function notificationAlert(request: Request): Promise<SessionAlert | TaskAlert> {
  const value = await readJSONObject(request);
  return Object.hasOwn(value, "kind") ? taskAlert(value) : sessionAlert(value);
}

function sessionAlert(object: Record<string, unknown>): SessionAlert {
  const value = exactKeys(object, ["eventID", "conversationID", "sessionTitle", "status"]);
  if (!displayText(value.sessionTitle, policy.titleBytes) || (value.status !== "ready" && value.status !== "needs_approval")) {
    throw new RelayError(400, "invalid_request");
  }
  return { kind: "session", eventID: uuid(value.eventID), conversationID: uuid(value.conversationID),
    sessionTitle: value.sessionTitle, status: value.status };
}

function taskAlert(object: Record<string, unknown>): TaskAlert {
  const value = exactKeys(object, ["kind", "eventID", "taskID", "conversationID", "reason", "taskTitle", "detail", "pullRequestNumber"]);
  const reason = taskAlertReasons.find(known => known === value.reason);
  const number = value.pullRequestNumber;
  if (value.kind !== "task" || !reason || !displayText(value.taskTitle, policy.titleBytes) ||
      // Only a question carries text besides the title, and only a pull
      // request reason carries a number.
      (value.detail !== null && (reason !== "question" || !displayText(value.detail, policy.detailBytes))) ||
      (number !== null && (!(reason === "review" || reason === "merge_stopped") ||
        typeof number !== "number" || !Number.isSafeInteger(number) || number < 1 || number > 2_147_483_647))) {
    throw new RelayError(400, "invalid_request");
  }
  return {
    kind: "task", eventID: uuid(value.eventID), taskID: uuid(value.taskID),
    conversationID: value.conversationID === null ? null : uuid(value.conversationID), reason,
    taskTitle: value.taskTitle as string, detail: value.detail as string | null, pullRequestNumber: number as number | null
  };
}

/** One line of alert text: no control, separator or surrogate characters. */
function displayText(value: unknown, maxBytes: number): value is string {
  return typeof value === "string" && value.length > 0 && new TextEncoder().encode(value).byteLength <= maxBytes &&
    !/[\p{Cc}\p{Cs}\p{Zl}\p{Zp}]/u.test(value);
}

/** The fixed wording for each alert. */
export function alertText(alert: SessionAlert | TaskAlert): { title: string; body: string } {
  if (alert.kind === "session") return { title: alert.sessionTitle, body: alert.status === "ready" ? "Ready" : "Needs approval" };
  const pullRequest = alert.pullRequestNumber === null ? undefined : `PR #${alert.pullRequestNumber}`;
  switch (alert.reason) {
    case "question": return { title: `${alert.taskTitle} asks`, body: alert.detail ?? "Waiting for your reply" };
    case "review": return { title: pullRequest ? `${pullRequest} is ready for review` : "Ready for review", body: alert.taskTitle };
    case "merge_stopped": return { title: "Merge stopped", body: pullRequest ? `${alert.taskTitle} · ${pullRequest}` : alert.taskTitle };
    case "setup_failed": return { title: "Setup failed", body: alert.taskTitle };
    case "move_failed": return { title: "Move to worktree failed", body: alert.taskTitle };
    case "cleanup_stopped": return { title: "Cleanup stopped", body: alert.taskTitle };
  }
}
