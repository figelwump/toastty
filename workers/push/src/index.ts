const sandboxURL = "https://api.sandbox.push.apple.com/3/device/";
const transportReasons = new Set(["MissingProviderToken", "BadDeviceToken", "BadTopic", "TopicDisallowed"]);
const expectedReasons = new Set([...transportReasons, "DeviceTokenNotForTopic", "Unregistered",
  "ExpiredProviderToken", "InvalidProviderToken", "TooManyProviderTokenUpdates", "TooManyRequests",
  "Forbidden", "MissingTopic", "PayloadTooLarge", "BadPriority", "BadExpirationDate",
  "InternalServerError", "ServiceUnavailable", "Shutdown"]);
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function json(body: unknown, status = 200): Response {
  return Response.json(body, { status, headers: { "cache-control": "no-store" } });
}

async function authorized(request: Request, secret: string): Promise<boolean> {
  const supplied = request.headers.get("authorization") ?? "";
  if (supplied.length > 256) return false;
  const encoder = new TextEncoder();
  const [actual, expected] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(supplied)),
    crypto.subtle.digest("SHA-256", encoder.encode(`Bearer ${secret}`))
  ]);
  return crypto.subtle.timingSafeEqual(actual, expected);
}

async function readReason(response: Response): Promise<string | undefined> {
  if (!response.body) return undefined;
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 2048) return undefined;
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    const body: unknown = JSON.parse(new TextDecoder().decode(bytes));
    if (typeof body !== "object" || body === null || !("reason" in body)) return undefined;
    return typeof body.reason === "string" && expectedReasons.has(body.reason) ? body.reason : undefined;
  } catch {
    return undefined;
  } finally {
    await reader.cancel().catch(() => {});
  }
}

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health" && request.method === "GET") {
      return json({ service: "toastty-push-probe", version: 1 });
    }
    const isSend = url.pathname === "/v1/test-notification";
    if (url.pathname !== "/v1/transport-probe" && !isSend) return json({ error: "not_found" }, 404);
    if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
    const expiresAt = Number(env.PUSH_PROBE_EXPIRES_AT);
    if (!env.PUSH_PROBE_AUTH || !Number.isFinite(expiresAt) || expiresAt <= Date.now()) {
      return json({ error: "probe_disabled" }, 503);
    }
    if (!await authorized(request, env.PUSH_PROBE_AUTH)) return json({ error: "unauthorized" }, 401);
    if (url.search || (request.body !== null && request.headers.get("content-length") !== "0")) {
      return json({ error: "empty_request_required" }, 400);
    }
    if (isSend && (!env.APNS_PROVIDER_TOKEN || !/^[\w-]+\.[\w-]+\.[\w-]+$/.test(env.APNS_PROVIDER_TOKEN) ||
        !env.APNS_DEVICE_TOKEN || !/^(?:[a-f0-9]{2}){16,256}$/i.test(env.APNS_DEVICE_TOKEN))) {
      return json({ error: "sender_not_configured" }, 503);
    }

    try {
      const headers = new Headers({
        "content-type": "application/json",
        "apns-topic": "com.giantthings.toastty.mobile.dev",
        "apns-push-type": "alert",
        "apns-expiration": isSend ? String(Math.floor(Date.now() / 1000) + 300) : "0"
      });
      if (isSend) {
        headers.set("authorization", `bearer ${env.APNS_PROVIDER_TOKEN}`);
        headers.set("apns-priority", "10");
        headers.set("apns-collapse-id", "toastty-development-push-test");
      }
      const token = isSend ? env.APNS_DEVICE_TOKEN : "0".repeat(64);
      const response = await fetch(`${sandboxURL}${token}`, {
        method: "POST",
        // Deployed Workers support manual/follow; never follow a redirect with a provider token.
        redirect: "manual",
        headers,
        body: JSON.stringify({ aps: isSend ? {
          alert: { title: "Toastty push test", body: "The sandbox sender reached this iPhone." }, sound: "default"
        } : { alert: "Toastty transport probe" } }),
        signal: AbortSignal.timeout(10_000)
      });
      const apnsID = response.headers.get("apns-id") ?? "";
      if (isSend && response.status === 200) {
        await response.body?.cancel().catch(() => {});
        return json({ apnsAccepted: true, deliveryVerified: false, apnsStatus: 200,
          apnsID: uuidPattern.test(apnsID) ? apnsID : null });
      }
      const reason = await readReason(response);
      if (isSend && [400, 403, 410, 413, 429, 500, 503].includes(response.status) && reason && uuidPattern.test(apnsID)) {
        return json({ apnsAccepted: false, deliveryVerified: false, apnsStatus: response.status, apnsReason: reason, apnsID }, 502);
      }
      if (isSend || ![400, 403].includes(response.status) || !reason || !transportReasons.has(reason) || !uuidPattern.test(apnsID)) {
        return json({ ...(isSend ? { apnsAccepted: null, deliveryVerified: false } : {}),
          error: "unrecognized_apns_response" }, 502);
      }
      return json({ transportReachable: true, notificationDelivered: false,
        apnsStatus: response.status, apnsReason: reason, apnsID });
    } catch (error) {
      return json({ ...(isSend ? { apnsAccepted: null, deliveryVerified: false } : {}),
        error: error instanceof DOMException && error.name === "TimeoutError"
        ? "apns_timeout" : "apns_transport_failed" }, 502);
    }
  }
} satisfies ExportedHandler<Partial<Env>>;
