import { DurableObject } from "cloudflare:workers";
import { RelayAPNsClient } from "./relay-apns";
import {
  base64url, bearerHash, capability, digest, enrollment, failure, json, policy,
  readObject, RelayError, sameHash, sessionAlert, uuid
} from "./relay-protocol";
import { RelayStore, type RegistrationRow } from "./relay-store";

function configured(env: RelayEnv): boolean {
  return env.PUSH_ENABLED === "true" && !!env.APNS_PRIVATE_KEY &&
    /^[A-Za-z0-9_-]{1,100}$/.test(env.PUSH_RELAY_ID) &&
    ((env.APNS_ENVIRONMENT === "development" && env.APNS_TOPIC === "com.giantthings.toastty.mobile.dev") ||
     (env.APNS_ENVIRONMENT === "production" && env.APNS_TOPIC === "com.giantthings.toastty.mobile"));
}

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health" && request.method === "GET" && !url.search) {
      return json({ service: "toastty-push", version: 1, relayID: env.PUSH_RELAY_ID,
        apnsEnvironment: env.APNS_ENVIRONMENT, enabled: configured(env) });
    }
    if (!configured(env)) return failure(new RelayError(503, "push_unavailable"));
    if (url.search || !/^\/v1\/registrations(?:\/[a-f0-9-]+(?:\/(?:complete|notifications))?)?$/i.test(url.pathname)) {
      return failure(new RelayError(404, "not_found"));
    }
    // Cloudflare supplies this header at ingress. A caller cannot choose the
    // rate-limit key by sending the internal forwarding header itself.
    const headers = new Headers(request.headers);
    headers.set("x-toastty-client-ip", request.headers.get("CF-Connecting-IP")?.slice(0, 64) || "unknown");
    const forwarded = new Request(request, { headers });
    try { return await env.PUSH_STATE.getByName("relay-v1").fetch(forwarded); }
    catch { return failure(new RelayError(503, "service_unavailable", 5)); }
  }
} satisfies ExportedHandler<RelayEnv>;

export class PushRelayState extends DurableObject<RelayEnv> {
  private readonly ready: Promise<{ store: RelayStore; apns: RelayAPNsClient }>;

  constructor(ctx: DurableObjectState, env: RelayEnv) {
    super(ctx, env);
    this.ready = ctx.blockConcurrencyWhile(async () => {
      const store = new RelayStore(ctx.storage);
      return { store, apns: new RelayAPNsClient(env, store.sql) };
    });
  }

  async fetch(request: Request): Promise<Response> {
    try {
      const { store, apns } = await this.ready;
      const url = new URL(request.url);
      const parts = url.pathname.split("/").filter(Boolean);
      if (parts.length === 2 && request.method === "POST") return await this.begin(request, store, apns);
      if (parts.length === 2) throw new RelayError(405, "method_not_allowed");
      const id = uuid(parts[2]);
      const authorization = await bearerHash(request);
      if (parts.length === 3 && request.method === "DELETE") {
        const row = store.registration(id);
        if (row && !sameHash(row.management_hash, authorization) && !sameHash(row.send_hash, authorization)) {
          throw new RelayError(401, "unauthorized");
        }
        if (row) store.revoke(id, now());
        return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
      }
      const role = parts[3] === "notifications" ? "send" : "management";
      const row = this.authorized(store, id, authorization, role);
      if (parts.length === 3 && request.method === "GET") {
        if (row.status === "active") store.touch(id, now());
        return json({ ...status(row), pairingID: row.pairing_id });
      }
      if (parts[3] === "complete" && request.method === "POST") return await this.complete(request, store, row);
      if (parts[3] === "notifications" && request.method === "POST") return await this.send(request, store, apns, row);
      throw new RelayError(405, "method_not_allowed");
    } catch (error) { return failure(error); }
  }

  private authorized(store: RelayStore, id: string, authorization: string, role: "send" | "management"): RegistrationRow {
    const row = store.registration(id);
    if (!row) throw new RelayError(404, "registration_not_found");
    if (!sameHash(role === "send" ? row.send_hash : row.management_hash, authorization)) throw new RelayError(401, "unauthorized");
    if (row.status === "revoked" || row.expires_at <= now()) throw new RelayError(410, "registration_inactive");
    return row;
  }

  private async begin(request: Request, store: RelayStore, apns: RelayAPNsClient): Promise<Response> {
    const value = await enrollment(request);
    const nonce = base64url(crypto.getRandomValues(new Uint8Array(32)));
    const [managementHash, sendHash, nonceHash, tokenHash, ipHash] = await Promise.all([
      digest(value.managementToken), digest(value.sendToken), digest(nonce), digest(value.deviceToken),
      digest(request.headers.get("x-toastty-client-ip") || "unknown")
    ]);
    if (sameHash(managementHash, sendHash)) throw new RelayError(400, "distinct_capabilities_required");
    const timestamp = now();
    const existing = store.transaction(() => {
      const row = store.registration(value.registrationID);
      if (row) {
        if (!sameHash(row.management_hash, managementHash) || !sameHash(row.send_hash, sendHash) ||
            row.token_hash !== tokenHash || row.pairing_id !== value.pairingID) throw new RelayError(409, "registration_conflict");
        if (row.status === "revoked" || row.expires_at <= timestamp) throw new RelayError(410, "registration_inactive");
        return row;
      }
      store.consumeLimit(`verify-token:${tokenHash}`, policy.verificationPerToken, 3600, timestamp);
      store.consumeLimit(`verify-ip:${ipHash}`, policy.verificationPerIP, 3600, timestamp);
      store.consumeLimit("verify-global", policy.verificationGlobal, 3600, timestamp);
      store.insert({ id: value.registrationID, token: value.deviceToken, token_hash: tokenHash, pairing_id: value.pairingID,
        management_hash: managementHash, send_hash: sendHash, nonce_hash: nonceHash, status: "pending",
        expires_at: timestamp + policy.challengeSeconds, last_used: timestamp });
      return undefined;
    });
    if (existing) return json(status(existing), existing.status === "active" ? 200 : 202);
    await this.schedulePruning();
    const result = await apns.send(value.deviceToken, {
      aps: { alert: { title: "Toastty notification test", body: "Checking delivery to this iPhone." } },
      toastty: { version: 1, kind: "verification", registrationID: value.registrationID, pairingID: value.pairingID, nonce }
    }, timestamp + policy.challengeSeconds, "toastty-verification");
    // Completion or revocation may have arrived while APNs was in flight.
    // Never write a post-send state over either decision.
    const current = store.registration(value.registrationID);
    if (!current || current.status === "revoked") throw new RelayError(410, "registration_inactive");
    if (current.status === "active") return json(status(current));
    if (result === "inactive" || result === "invalid_device_token") {
      store.revoke(value.registrationID, now());
      throw new RelayError(422, "invalid_device_token");
    }
    if (result !== "accepted") throw new RelayError(503, "verification_unavailable");
    return json(status(current), 201);
  }

  private async complete(request: Request, store: RelayStore, original: RegistrationRow): Promise<Response> {
    const body = await readObject(request, ["nonce"]);
    const nonceHash = await digest(capability(body.nonce));
    return store.transaction(() => {
      const row = store.registration(original.id);
      if (!row || row.status === "revoked" || row.expires_at <= now()) throw new RelayError(410, "registration_inactive");
      if (!sameHash(row.management_hash, original.management_hash)) throw new RelayError(401, "unauthorized");
      if (row.status === "active") return json(status(row));
      if (!row.nonce_hash || !sameHash(row.nonce_hash, nonceHash)) throw new RelayError(403, "invalid_proof");
      store.activate(row, now());
      return json({ registrationID: row.id, pairingID: row.pairing_id, state: "active" });
    });
  }

  private async send(request: Request, store: RelayStore, apns: RelayAPNsClient, original: RegistrationRow): Promise<Response> {
    const alert = await sessionAlert(request);
    const timestamp = now();
    const prepared = store.transaction(() => {
      const row = store.registration(original.id);
      if (!row || row.status === "revoked" || row.expires_at <= timestamp) throw new RelayError(410, "registration_inactive");
      if (!sameHash(row.send_hash, original.send_hash)) throw new RelayError(401, "unauthorized");
      if (row.status !== "active") throw new RelayError(409, "registration_pending");
      const prior = store.event(row.id, alert.eventID);
      if (prior && prior.expires_at > timestamp) {
        if (prior.outcome === "accepted") return { row, duplicate: true };
        throw new RelayError(409, "delivery_already_attempted");
      }
      store.consumeLimit(`send:${row.id}`, policy.sendsPerMinute, 60, timestamp);
      store.consumeLimit("send-global", policy.sendsGlobalPerMinute, 60, timestamp);
      store.reserveEvent(row.id, alert.eventID, timestamp);
      store.touch(row.id, timestamp);
      return { row, duplicate: false };
    });
    if (prepared.duplicate) return json({ result: "duplicate" }, 202);
    const row = prepared.row;
    const result = await apns.send(row.token, {
      aps: { alert: { title: alert.sessionTitle, body: alert.status === "ready" ? "Ready" : "Needs approval" }, sound: "default" },
      toastty: { version: 1, kind: "session", registrationID: row.id, pairingID: row.pairing_id,
        conversationID: alert.conversationID, eventID: alert.eventID }
    }, timestamp + 300, alert.eventID);
    store.transaction(() => {
      store.finishEvent(row.id, alert.eventID, result === "accepted" ? "accepted" : result === "unknown" ? "unknown" : "rejected");
      if (result === "inactive" || result === "invalid_device_token") store.revoke(row.id, now());
    });
    if (result === "inactive" || result === "invalid_device_token") {
      throw new RelayError(410, "registration_inactive");
    }
    if (result === "unknown") throw new RelayError(502, "delivery_unknown");
    if (result !== "accepted") throw new RelayError(503, "delivery_unavailable");
    return json({ result: "accepted" }, 202);
  }

  private async schedulePruning(): Promise<void> {
    if (await this.ctx.storage.getAlarm() === null) await this.ctx.storage.setAlarm(Date.now() + 3600_000);
  }

  async alarm(): Promise<void> {
    const { store } = await this.ready;
    if (store.prune(now())) await this.ctx.storage.setAlarm(Date.now() + 3600_000);
  }
}

function now(): number { return Math.floor(Date.now() / 1000); }
function status(row: RegistrationRow): object {
  return row.status === "active"
    ? { registrationID: row.id, pairingID: row.pairing_id, state: "active" }
    : { registrationID: row.id, state: "pending", expiresAt: row.expires_at };
}
