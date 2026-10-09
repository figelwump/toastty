import { env, exports } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import sessionFixture from "../../../../Tests/RemoteProtocol/Fixtures/v1/push-session.json";
import { policy } from "../../src/relay-protocol";
import verificationFixture from "../../../../Tests/RemoteProtocol/Fixtures/v1/push-verification.json";

// Failure modes: proof before begin response; lost HTTP responses; expired or
// replayed proof; reversed enrollment order; cross-role credentials; revocation
// during APNs I/O; repeated sends; malformed/big requests; and cache eviction.
const configuration = env as RelayEnv;
const outbound = vi.fn<typeof fetch>();
const token = "ab".repeat(32);
const pairingID = sessionFixture.toastty.pairingID;
const encode = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
function attempt(deviceToken = token) {
  return {
    registrationID: crypto.randomUUID(), deviceToken, pairingID,
    managementToken: encode(crypto.getRandomValues(new Uint8Array(32))),
    sendToken: encode(crypto.getRandomValues(new Uint8Array(32)))
  };
}
type Attempt = ReturnType<typeof attempt>;
interface VerificationPayload { toastty: { nonce: string; registrationID: string; pairingID: string } }
function call(path: string, method: string, body?: unknown, credential?: string) {
  return exports.default.fetch(`https://relay.test${path}`, {
    method,
    headers: { "content-type": "application/json", "CF-Connecting-IP": "192.0.2.10", ...(credential ? { authorization: `Bearer ${credential}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body)
  });
}
function registrationPath(value: Attempt) { return `/v1/registrations/${value.registrationID}`; }
function pushPayload(index = outbound.mock.calls.length - 1): VerificationPayload {
  return JSON.parse(String(outbound.mock.calls[index][1]?.body)) as VerificationPayload;
}
async function enroll(value = attempt()) {
  const response = await call("/v1/registrations", "POST", value);
  expect(response.status).toBe(201);
  const nonce = pushPayload().toastty.nonce;
  const completed = await call(`${registrationPath(value)}/complete`, "POST", { nonce }, value.managementToken);
  expect(completed.status).toBe(200);
  return { value, nonce };
}
function send(value: Attempt, overrides: Record<string, unknown> = {}) {
  return call(`${registrationPath(value)}/notifications`, "POST", {
    eventID: sessionFixture.toastty.eventID,
    conversationID: sessionFixture.toastty.conversationID,
    sessionTitle: sessionFixture.aps.alert.title,
    status: "ready", ...overrides
  }, value.sendToken);
}

let publicKey: CryptoKey;
beforeEach(async () => {
  // Clear only the application's tables. The current workerd version crashes
  // in its runtime-wide reset helper, which also touches the test runner.
  await runInDurableObject(configuration.PUSH_STATE.getByName("relay-v1"), (_instance, state) => {
    for (const table of ["registrations", "limits", "events", "provider_token"]) {
      state.storage.sql.exec(`DELETE FROM ${table}`);
    }
  });
  const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  if (!("privateKey" in keys)) throw new Error("Expected an asymmetric test key pair");
  publicKey = keys.publicKey;
  const exported = await crypto.subtle.exportKey("pkcs8", keys.privateKey);
  if (!(exported instanceof ArrayBuffer)) throw new Error("Expected binary PKCS8 test key");
  const pkcs8 = new Uint8Array(exported);
  configuration.APNS_PRIVATE_KEY = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8))}\n-----END PRIVATE KEY-----`;
  configuration.PUSH_ENABLED = "true";
  outbound.mockReset().mockResolvedValue(new Response(null, { status: 200 }));
  vi.stubGlobal("fetch", outbound);
});
afterEach(() => { vi.unstubAllGlobals(); });

describe("account-free registration and session alerts", () => {
  it("proves receipt before enabling a grant and matches the shared payloads", async () => {
    const value = attempt();
    const response = await call("/v1/registrations", "POST", value);
    expect(response.status).toBe(201);
    const receipt = await response.json<{ registrationID: string; state: string; expiresAt: number }>();
    const verification = JSON.parse(String(outbound.mock.calls[0][1]?.body));
    expect(verification).toEqual({ ...verificationFixture, toastty: {
      ...verificationFixture.toastty, registrationID: value.registrationID, nonce: verification.toastty.nonce
    } });
    expect(receipt).toEqual({ registrationID: value.registrationID, state: "pending", expiresAt: expect.any(Number) });
    expect(receipt.expiresAt).toBeGreaterThan(Date.now() / 1000);
    expect(JSON.stringify(receipt)).not.toContain(verification.toastty.nonce);
    expect((await send(value)).status).toBe(409);
    expect((await call(`${registrationPath(value)}/complete`, "POST", { nonce: value.sendToken }, value.managementToken)).status).toBe(403);
    expect((await call(`${registrationPath(value)}/complete`, "POST", { nonce: verification.toastty.nonce }, value.sendToken)).status).toBe(401);
    expect((await call(`${registrationPath(value)}/complete`, "POST", { nonce: verification.toastty.nonce }, value.managementToken)).status).toBe(200);
    expect((await send(value)).status).toBe(202);
    expect(JSON.parse(String(outbound.mock.calls[1][1]?.body))).toEqual({ ...sessionFixture, toastty: {
      ...sessionFixture.toastty, registrationID: value.registrationID
    } });
    const headers = new Headers(outbound.mock.calls[1][1]?.headers);
    expect(headers.get("apns-topic")).toBe("com.giantthings.toastty.mobile.dev");
    expect(headers.get("apns-push-type")).toBe("alert");
    expect(outbound.mock.calls[1][1]?.redirect).toBe("manual");
  });

  it("allows completion while the verification request is still awaiting APNs", async () => {
    const value = attempt();
    let release!: () => void;
    let received!: (nonce: string) => void;
    const receipt = new Promise<string>(resolve => { received = resolve; });
    outbound.mockImplementationOnce(async (_url, init) => {
      received((JSON.parse(String(init?.body)) as VerificationPayload).toastty.nonce);
      await new Promise<void>(resolve => { release = resolve; });
      return new Response(null, { status: 200 });
    });
    const beginning = call("/v1/registrations", "POST", value);
    const nonce = await receipt;
    const complete = await call(`${registrationPath(value)}/complete`, "POST", { nonce }, value.managementToken);
    expect(complete.status).toBe(200);
    release();
    await beginning;
    expect((await call(registrationPath(value), "GET", undefined, value.managementToken)).status).toBe(200);
    expect((await send(value)).status).toBe(202);
  });

  it("retries begin and complete without another verification notification", async () => {
    const value = attempt();
    await call("/v1/registrations", "POST", value);
    const nonce = pushPayload().toastty.nonce;
    const retry = await call("/v1/registrations", "POST", value);
    expect(retry.status).toBe(202);
    expect(outbound).toHaveBeenCalledTimes(1);
    for (let i = 0; i < 2; i++) {
      expect((await call(`${registrationPath(value)}/complete`, "POST", { nonce }, value.managementToken)).status).toBe(200);
    }
    expect((await call("/v1/registrations", "POST", { ...value, deviceToken: "cd".repeat(32) })).status).toBe(409);
    expect(outbound).toHaveBeenCalledTimes(1);
  });

  it("does not let an older proof replace a newer active registration", async () => {
    const first = attempt();
    await call("/v1/registrations", "POST", first);
    const oldNonce = pushPayload().toastty.nonce;
    const { value: second } = await enroll();
    expect((await call(`${registrationPath(first)}/complete`, "POST", { nonce: oldNonce }, first.managementToken)).status).toBe(409);
    expect((await send(second)).status).toBe(202);
  });

  it("keeps the previous active grant until a replacement proves receipt", async () => {
    const { value: first } = await enroll();
    const second = attempt();
    await call("/v1/registrations", "POST", second);
    const nonce = pushPayload().toastty.nonce;
    expect((await send(first)).status).toBe(202);
    await call(`${registrationPath(second)}/complete`, "POST", { nonce }, second.managementToken);
    expect((await send(first, { eventID: crypto.randomUUID() })).status).toBe(410);
    expect((await send(second)).status).toBe(202);
  });

  it("does not expose management status or accept sends with the wrong role", async () => {
    const { value } = await enroll();
    expect((await call(registrationPath(value), "GET", undefined, value.sendToken)).status).toBe(401);
    expect((await call(`${registrationPath(value)}/notifications`, "POST", {}, value.managementToken)).status).toBe(401);
    expect((await call(registrationPath(value), "DELETE", undefined, attempt().sendToken)).status).toBe(401);
    expect((await call(registrationPath(value), "DELETE", undefined, value.sendToken)).status).toBe(204);
    expect((await send(value)).status).toBe(410);
    expect((await call(registrationPath(value), "DELETE", undefined, value.managementToken)).status).toBe(204);
  });

  it("does not repeat an event after an ambiguous APNs outcome", async () => {
    const { value } = await enroll();
    outbound.mockRejectedValueOnce(new Error("network failed after send"));
    expect((await send(value)).status).toBe(502);
    const duplicate = await send(value);
    expect(duplicate.status).toBe(409);
    expect(outbound).toHaveBeenCalledTimes(2);
  });

  it("deduplicates successful sends and disables an unregistered destination", async () => {
    const { value } = await enroll();
    expect((await send(value)).status).toBe(202);
    expect((await send(value)).status).toBe(202);
    expect(outbound).toHaveBeenCalledTimes(2);
    outbound.mockResolvedValueOnce(new Response('{"reason":"Unregistered"}', { status: 410 }));
    expect((await send(value, { eventID: crypto.randomUUID() })).status).toBe(410);
    expect((await call(registrationPath(value), "GET", undefined, value.managementToken)).status).toBe(410);
  });

  it("rejects oversized, malformed and caller-selected notification content", async () => {
    expect((await call("/v1/registrations", "POST", { ...attempt(), unexpected: true })).status).toBe(400);
    expect((await call("/v1/registrations", "POST", { ...attempt(), deviceToken: "not-a-token" })).status).toBe(400);
    expect((await call("/v1/registrations", "POST", { data: "x".repeat(4097) })).status).toBe(413);
    const { value } = await enroll();
    expect((await send(value, { sessionTitle: "😀".repeat(129) })).status).toBe(400);
    expect((await send(value, { sessionTitle: "bad\u0000title" })).status).toBe(400);
    expect((await send(value, { body: "caller content" })).status).toBe(400);
    expect(outbound).toHaveBeenCalledTimes(1);
  });

  it("limits verification sends without disclosing an existing nonce", async () => {
    for (let i = 0; i < 3; i++) expect((await call("/v1/registrations", "POST", attempt())).status).toBe(201);
    const limited = await call("/v1/registrations", "POST", attempt());
    expect(limited.status).toBe(429);
    expect(Number(limited.headers.get("retry-after"))).toBeGreaterThan(0);
    expect(outbound).toHaveBeenCalledTimes(3);
  });

  it("persists its provider JWT for reuse and signs valid ES256", async () => {
    const first = await enroll();
    const original = new Headers(outbound.mock.calls[0][1]?.headers).get("authorization")!.slice(7);
    const [header, payload, signature] = original.split(".");
    expect(JSON.parse(atob(header.replaceAll("-", "+").replaceAll("_", "/")))).toEqual({ alg: "ES256", kid: "TESTKEY001" });
    expect(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey,
      Uint8Array.from(atob(signature.replaceAll("-", "+").replaceAll("_", "/")), c => c.charCodeAt(0)),
      new TextEncoder().encode(`${header}.${payload}`))).toBe(true);
    const persisted = await runInDurableObject(configuration.PUSH_STATE.getByName("relay-v1"), (_instance, state) =>
      state.storage.sql.exec<{ token: string }>("SELECT token FROM provider_token WHERE id = 1").one().token);
    expect(persisted).toBe(original);
    await send(first.value);
    expect(new Headers(outbound.mock.calls[1][1]?.headers).get("authorization")).toBe(`bearer ${original}`);
  });

  it("expires pending proof without relying on alarm timing", async () => {
    const value = attempt();
    await call("/v1/registrations", "POST", value);
    const nonce = pushPayload().toastty.nonce;
    const stub = configuration.PUSH_STATE.getByName("relay-v1");
    await runInDurableObject(stub, (_instance, state) => {
      state.storage.sql.exec("UPDATE registrations SET expires_at = 1 WHERE id = ?", value.registrationID);
    });
    expect((await call(`${registrationPath(value)}/complete`, "POST", { nonce }, value.managementToken)).status).toBe(410);
  });

  it("does not resend begin while its first verification request is in flight", async () => {
    const value = attempt();
    let release!: () => void;
    let received!: () => void;
    const started = new Promise<void>(resolve => { received = resolve; });
    outbound.mockImplementationOnce(async () => {
      received();
      await new Promise<void>(resolve => { release = resolve; });
      return new Response(null, { status: 200 });
    });
    const first = call("/v1/registrations", "POST", value);
    await started;
    expect((await call("/v1/registrations", "POST", value)).status).toBe(202);
    expect(outbound).toHaveBeenCalledTimes(1);
    release();
    expect((await first).status).toBe(201);
  });

  it("keeps revocation final when a verification response arrives later", async () => {
    const value = attempt();
    let release!: () => void;
    let received!: (nonce: string) => void;
    const started = new Promise<string>(resolve => { received = resolve; });
    outbound.mockImplementationOnce(async (_url, init) => {
      received((JSON.parse(String(init?.body)) as VerificationPayload).toastty.nonce);
      await new Promise<void>(resolve => { release = resolve; });
      return new Response(null, { status: 200 });
    });
    const beginning = call("/v1/registrations", "POST", value);
    const nonce = await started;
    expect((await call(registrationPath(value), "DELETE", undefined, value.managementToken)).status).toBe(204);
    expect((await call(`${registrationPath(value)}/complete`, "POST", { nonce }, value.managementToken)).status).toBe(410);
    release();
    expect((await beginning).status).toBe(410);
    expect((await send(value)).status).toBe(410);
  });

  it("keeps revocation final when an already accepted send finishes later", async () => {
    const { value } = await enroll();
    let release!: () => void;
    let received!: () => void;
    const started = new Promise<void>(resolve => { received = resolve; });
    outbound.mockImplementationOnce(async () => {
      received();
      await new Promise<void>(resolve => { release = resolve; });
      return new Response(null, { status: 200 });
    });
    const sending = send(value);
    await started;
    await call(registrationPath(value), "DELETE", undefined, value.managementToken);
    release();
    expect((await sending).status).toBe(202);
    expect((await send(value, { eventID: crypto.randomUUID() })).status).toBe(410);
  });

  it("does not reactivate an older proof after the newer grant has been revoked", async () => {
    const older = attempt();
    await call("/v1/registrations", "POST", older);
    const nonce = pushPayload().toastty.nonce;
    const { value: newer } = await enroll();
    await call(registrationPath(newer), "DELETE", undefined, newer.managementToken);
    expect((await call(`${registrationPath(older)}/complete`, "POST", { nonce }, older.managementToken)).status).toBe(409);
  });

  it("can finish proof after an ambiguous begin response without another push", async () => {
    const value = attempt();
    outbound.mockRejectedValueOnce(new Error("connection lost after write"));
    expect((await call("/v1/registrations", "POST", value)).status).toBe(503);
    const nonce = pushPayload().toastty.nonce;
    expect((await call("/v1/registrations", "POST", value)).status).toBe(202);
    expect((await call(`${registrationPath(value)}/complete`, "POST", { nonce }, value.managementToken)).status).toBe(200);
    expect(outbound).toHaveBeenCalledTimes(1);
  });

  it("preserves emoji joiners and keeps status messages fixed", async () => {
    const { value } = await enroll();
    const title = "Review 👩🏽‍💻 changes";
    expect((await send(value, { sessionTitle: title, status: "needs_approval" })).status).toBe(202);
    const payload = JSON.parse(String(outbound.mock.calls[1][1]?.body));
    expect(payload.aps.alert).toEqual({ title, body: "Needs approval" });
    expect((await send(value, { eventID: crypto.randomUUID(), sessionTitle: "line\u2028break" })).status).toBe(400);
  });

  it("stores only credential and nonce hashes, with a short fixed verification alert", async () => {
    const value = attempt();
    const result = await call("/v1/registrations", "POST", value);
    const body = await result.json<{ expiresAt: number }>();
    const nonce = pushPayload().toastty.nonce;
    const stored = await runInDurableObject(configuration.PUSH_STATE.getByName("relay-v1"), (_instance, state) =>
      JSON.stringify(state.storage.sql.exec("SELECT * FROM registrations").toArray()));
    for (const secret of [value.managementToken, value.sendToken, nonce]) expect(stored).not.toContain(secret);
    const headers = new Headers(outbound.mock.calls[0][1]?.headers);
    expect(headers.get("apns-expiration")).toBe(String(body.expiresAt));
    expect(headers.get("apns-collapse-id")).toBe("toastty-verification");
    expect(headers.get("apns-topic")).toBe("com.giantthings.toastty.mobile.dev");
  });

  it("refreshes a definitely rejected provider token once, but not other failures", async () => {
    const { value } = await enroll();
    await runInDurableObject(configuration.PUSH_STATE.getByName("relay-v1"), (_instance, state) => {
      state.storage.sql.exec("UPDATE provider_token SET created_at = ?", Math.floor(Date.now() / 1000) - 1201);
    });
    outbound.mockResolvedValueOnce(new Response('{"reason":"ExpiredProviderToken"}', { status: 403 }));
    expect((await send(value)).status).toBe(202);
    expect(outbound).toHaveBeenCalledTimes(3);
    expect(new Headers(outbound.mock.calls[2][1]?.headers).get("authorization"))
      .not.toBe(new Headers(outbound.mock.calls[1][1]?.headers).get("authorization"));
    outbound.mockResolvedValueOnce(new Response('{"reason":"InternalServerError"}', { status: 500 }));
    expect((await send(value, { eventID: crypto.randomUUID() })).status).toBe(502);
    expect(outbound).toHaveBeenCalledTimes(4);
    outbound.mockResolvedValueOnce(new Response('{"reason":"ExpiredProviderToken"}', { status: 403 }));
    expect((await send(value, { eventID: crypto.randomUUID() })).status).toBe(503);
    expect(outbound).toHaveBeenCalledTimes(5);
  });

  it("normalizes Swift uppercase IDs and replaces the previous Mac pairing", async () => {
    expect(policy.eventSeconds).toBeGreaterThanOrEqual(policy.challengeSeconds);
    const { value: first } = await enroll();
    const next = { ...attempt(), pairingID: crypto.randomUUID().toUpperCase() };
    next.registrationID = next.registrationID.toUpperCase();
    await call("/v1/registrations", "POST", next);
    const nonce = pushPayload().toastty.nonce;
    expect((await call(`${registrationPath(next)}/complete`, "POST", { nonce }, next.managementToken)).status).toBe(200);
    expect((await send(first)).status).toBe(410);
    expect((await send(next)).status).toBe(202);
    const status = await call(registrationPath(next), "GET", undefined, next.managementToken);
    expect(await status.json()).toMatchObject({ state: "active", pairingID: next.pairingID.toLowerCase() });
  });

  it("rejects expired active grants before pruning and never retries uncertain server responses", async () => {
    const { value } = await enroll();
    for (const response of [new Response("upstream", { status: 502 }), new Response(null, { status: 302 })]) {
      const eventID = crypto.randomUUID();
      outbound.mockResolvedValueOnce(response);
      expect((await send(value, { eventID })).status).toBe(502);
      expect((await send(value, { eventID })).status).toBe(409);
    }
    expect(outbound).toHaveBeenCalledTimes(3);
    expect((await send(value, { sessionTitle: "\ud800" })).status).toBe(400);
    await runInDurableObject(configuration.PUSH_STATE.getByName("relay-v1"), (_instance, state) => {
      state.storage.sql.exec("UPDATE registrations SET expires_at = 1");
    });
    expect((await send(value, { eventID: crypto.randomUUID() })).status).toBe(410);
  });

  it("classifies invalid APNs destinations and stays closed while disabled", async () => {
    outbound.mockResolvedValueOnce(new Response('{"reason":"BadDeviceToken"}', { status: 400 }));
    const invalid = await call("/v1/registrations", "POST", attempt());
    expect(invalid.status).toBe(422);
    expect(await invalid.json()).toEqual({ error: "invalid_device_token" });
    configuration.PUSH_ENABLED = "false";
    expect((await call("/v1/registrations", "POST", attempt())).status).toBe(503);
    expect(outbound).toHaveBeenCalledTimes(1);
  });

  it("rolls back a rate-limited event and sends the maximum multibyte title safely", async () => {
    const { value } = await enroll();
    await runInDurableObject(configuration.PUSH_STATE.getByName("relay-v1"), (_instance, state) => {
      state.storage.sql.exec("INSERT INTO limits (key, count, expires_at) VALUES ('send-global', ?, ?)",
        policy.sendsGlobalPerMinute, Math.floor(Date.now() / 1000) + 60);
    });
    expect((await send(value)).status).toBe(429);
    await runInDurableObject(configuration.PUSH_STATE.getByName("relay-v1"), (_instance, state) => {
      expect(state.storage.sql.exec("SELECT * FROM events").toArray()).toHaveLength(0);
      expect(state.storage.sql.exec("SELECT * FROM limits WHERE key LIKE 'send:%'").toArray()).toHaveLength(0);
      state.storage.sql.exec("DELETE FROM limits WHERE key = 'send-global'");
    });
    expect((await send(value, { sessionTitle: "😀".repeat(128) })).status).toBe(202);
    expect(new TextEncoder().encode(String(outbound.mock.calls.at(-1)?.[1]?.body)).byteLength).toBeLessThan(4096);
    expect(outbound).toHaveBeenCalledTimes(2);
  });
});
