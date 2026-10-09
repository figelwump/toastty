export const policy = {
  bodyBytes: 4096,
  titleBytes: 512,
  challengeSeconds: 300,
  activeSeconds: 90 * 24 * 3600,
  eventSeconds: 3600,
  verificationPerToken: 3,
  verificationPerIP: 30,
  verificationGlobal: 300,
  sendsPerMinute: 60,
  sendsGlobalPerMinute: 1000
} as const;

export class RelayError extends Error {
  constructor(readonly status: number, readonly code: string, readonly retryAfter?: number) { super(code); }
}

export function json(value: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return Response.json(value, { status, headers: { "cache-control": "no-store", ...headers } });
}

export function failure(error: unknown): Response {
  const known = error instanceof RelayError ? error : new RelayError(503, "service_unavailable");
  return json({ error: known.code }, known.status,
    known.retryAfter === undefined ? {} : { "retry-after": String(known.retryAfter) });
}

export async function readObject(request: Request, keys: readonly string[]): Promise<Record<string, unknown>> {
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
  const object = parsed as Record<string, unknown>;
  if (Object.keys(object).length !== keys.length || keys.some(key => !Object.hasOwn(object, key))) {
    throw new RelayError(400, "invalid_request");
  }
  return object;
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

export interface SessionAlert { eventID: string; conversationID: string; sessionTitle: string; status: "ready" | "needs_approval" }
export async function sessionAlert(request: Request): Promise<SessionAlert> {
  const value = await readObject(request, ["eventID", "conversationID", "sessionTitle", "status"]);
  if (typeof value.sessionTitle !== "string" || value.sessionTitle.length === 0 ||
      new TextEncoder().encode(value.sessionTitle).byteLength > policy.titleBytes ||
      /[\p{Cc}\p{Cs}\p{Zl}\p{Zp}]/u.test(value.sessionTitle) || (value.status !== "ready" && value.status !== "needs_approval")) {
    throw new RelayError(400, "invalid_request");
  }
  return { eventID: uuid(value.eventID), conversationID: uuid(value.conversationID), sessionTitle: value.sessionTitle, status: value.status };
}
