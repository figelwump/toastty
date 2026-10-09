import { env, exports } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const url = `https://api.sandbox.push.apple.com/3/device/${"0".repeat(64)}`;
const outbound = vi.fn<typeof fetch>();
const apnsID = "b0cbab37-56ba-42ac-a5a9-b871a1d26454";
const auth = "test-only-probe-authorization";
function request(init: RequestInit = {}) {
  return exports.default.fetch("https://probe.test/v1/transport-probe", {
    method: "POST", headers: { authorization: `Bearer ${auth}` }, ...init
  });
}
function appleResponse(status: number, body: string, headers = { "apns-id": apnsID }) {
  outbound.mockImplementationOnce(async (input, init) => {
    expect(input).toBe(url);
    expect(init?.method).toBe("POST");
    expect(init?.redirect).toBe("manual");
    expect(init?.body).toBe('{"aps":{"alert":"Toastty transport probe"}}');
    expect(new Headers(init?.headers).has("authorization")).toBe(false);
    expect(new Headers(init?.headers).get("apns-topic")).toBe("com.giantthings.toastty.mobile.dev");
    return new Response(body, { status, headers });
  });
}

describe("APNs transport probe", () => {
  beforeEach(() => {
    env.PUSH_PROBE_AUTH = auth;
    env.PUSH_PROBE_EXPIRES_AT = String(Date.now() + 60_000);
    env.APNS_PROVIDER_TOKEN = "";
    env.APNS_DEVICE_TOKEN = "";
    outbound.mockReset().mockRejectedValue(new Error("Unexpected outbound request"));
    vi.stubGlobal("fetch", outbound);
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("fails closed without configuration, with expired credentials, or with invalid authorization", async () => {
    for (const headers of [new Headers(), new Headers({ authorization: "Bearer wrong" })]) {
      expect((await request({ headers })).status).toBe(401);
    }
    env.PUSH_PROBE_AUTH = "";
    expect((await request()).status).toBe(503);
    env.PUSH_PROBE_AUTH = auth;
    env.PUSH_PROBE_EXPIRES_AT = "0";
    expect((await request()).status).toBe(503);
    expect(outbound).not.toHaveBeenCalled();
  });

  it("rejects caller content and query parameters without contacting Apple", async () => {
    expect((await request({ body: "custom message" })).status).toBe(400);
    expect((await exports.default.fetch("https://probe.test/v1/transport-probe?token=123", {
      method: "POST", headers: { authorization: `Bearer ${auth}` }
    })).status).toBe(400);
    expect((await request({ method: "GET" })).status).toBe(405);
    expect((await exports.default.fetch("https://probe.test/other")).status).toBe(404);
    expect(outbound).not.toHaveBeenCalled();
  });

  it.each(["MissingProviderToken", "BadDeviceToken", "BadTopic"])(
    "reports %s as connectivity only", async (reason) => {
      appleResponse(403, JSON.stringify({ reason }));
      const response = await request();
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({
        transportReachable: true, notificationDelivered: false,
        apnsStatus: 403, apnsReason: reason, apnsID
      });
    }
  );

  it("accepts the zero content length sent by Node fetch", async () => {
    appleResponse(403, '{"reason":"MissingProviderToken"}');
    const response = await request({ headers: { authorization: `Bearer ${auth}`, "content-length": "0" } });
    expect(response.status).toBe(200);
    expect(outbound).toHaveBeenCalledOnce();
  });

  it.each([
    ["not json", { "apns-id": apnsID }],
    ['{"reason":"unexpected sensitive text"}', { "apns-id": apnsID }],
    ['{"reason":"MissingProviderToken"}', { "apns-id": "not-an-id" }],
    ["x".repeat(2049), { "apns-id": apnsID }]
  ])("does not return untrusted upstream content", async (body, headers) => {
    appleResponse(403, body, headers);
    const response = await request();
    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: "unrecognized_apns_response" });
  });

  it("reports an outbound failure without leaking error details", async () => {
    outbound.mockRejectedValueOnce(new Error("private upstream detail"));
    const response = await request();
    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: "apns_transport_failed" });
  });

  function send() {
    return exports.default.fetch("https://probe.test/v1/test-notification", {
      method: "POST", headers: { authorization: `Bearer ${auth}` }
    });
  }

  it("requires all sender settings before contacting Apple", async () => {
    expect((await send()).status).toBe(503);
    env.APNS_PROVIDER_TOKEN = "test.header.signature";
    expect((await send()).status).toBe(503);
    env.APNS_DEVICE_TOKEN = "invalid-token";
    expect((await send()).status).toBe(503);
    expect(outbound).not.toHaveBeenCalled();
  });

  it("sends the fixed alert to the configured sandbox device and reports acceptance only", async () => {
    env.APNS_PROVIDER_TOKEN = "test.header.signature";
    env.APNS_DEVICE_TOKEN = "ab".repeat(32);
    outbound.mockImplementationOnce(async (input, init) => {
      expect(input).toBe(`https://api.sandbox.push.apple.com/3/device/${env.APNS_DEVICE_TOKEN}`);
      const headers = new Headers(init?.headers);
      expect(headers.get("authorization")).toBe(`bearer ${env.APNS_PROVIDER_TOKEN}`);
      expect(headers.get("apns-topic")).toBe("com.giantthings.toastty.mobile.dev");
      expect(headers.get("apns-push-type")).toBe("alert");
      expect(headers.get("apns-priority")).toBe("10");
      expect(headers.get("apns-collapse-id")).toBe("toastty-development-push-test");
      expect(Number(headers.get("apns-expiration"))).toBeGreaterThan(Date.now() / 1000 + 290);
      expect(init?.redirect).toBe("manual");
      expect(JSON.parse(String(init?.body))).toEqual({ aps: {
        alert: { title: "Toastty push test", body: "The sandbox sender reached this iPhone." }, sound: "default"
      } });
      return new Response(null, { status: 200, headers: { "apns-id": apnsID } });
    });
    const response = await send();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ apnsAccepted: true, deliveryVerified: false, apnsStatus: 200, apnsID });
    expect(outbound).toHaveBeenCalledOnce();
  });

  it.each([[410, "Unregistered"], [429, "TooManyProviderTokenUpdates"], [403, "InvalidProviderToken"]])(
    "reports APNs rejection %s without retries", async (status, reason) => {
      env.APNS_PROVIDER_TOKEN = "test.header.signature";
      env.APNS_DEVICE_TOKEN = "ab".repeat(32);
      outbound.mockImplementationOnce(async () => Response.json({ reason }, { status, headers: { "apns-id": apnsID } }));
      const response = await send();
      expect(response.status).toBe(502);
      expect(await response.json()).toEqual({ apnsAccepted: false, deliveryVerified: false,
        apnsStatus: status, apnsReason: reason, apnsID });
      expect(outbound).toHaveBeenCalledOnce();
    }
  );

  it("does not follow a redirect or return its contents after a signed send", async () => {
    env.APNS_PROVIDER_TOKEN = "test.header.signature";
    env.APNS_DEVICE_TOKEN = "ab".repeat(32);
    outbound.mockImplementationOnce(async () => new Response("sensitive upstream text", { status: 307,
      headers: { location: "https://unexpected.test" } }));
    const response = await send();
    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ apnsAccepted: null, deliveryVerified: false, error: "unrecognized_apns_response" });
    expect(outbound).toHaveBeenCalledOnce();
  });

  it("reports acceptance even if Apple omits its request ID", async () => {
    env.APNS_PROVIDER_TOKEN = "test.header.signature";
    env.APNS_DEVICE_TOKEN = "ab".repeat(32);
    outbound.mockImplementationOnce(async () => new Response(null, { status: 200 }));
    expect(await (await send()).json()).toEqual({ apnsAccepted: true, deliveryVerified: false, apnsStatus: 200, apnsID: null });
  });

  it("reports a timeout after starting a send as an unknown outcome", async () => {
    env.APNS_PROVIDER_TOKEN = "test.header.signature";
    env.APNS_DEVICE_TOKEN = "ab".repeat(32);
    outbound.mockRejectedValueOnce(new DOMException("deadline", "TimeoutError"));
    expect(await (await send()).json()).toEqual({ apnsAccepted: null, deliveryVerified: false, error: "apns_timeout" });
    expect(outbound).toHaveBeenCalledOnce();
  });
});
