import { base64url, RelayError } from "./relay-protocol";

type ProviderTokenRow = { token: string; created_at: number; key_id: string; team_id: string };
export type APNsResult = "accepted" | "inactive" | "invalid_device_token" | "unavailable" | "unknown";

/** A deployment has one state object, so provider-token renewal stays shared
 * across requests and object eviction instead of signing on each delivery. */
export class RelayAPNsClient {
  private signing?: Promise<string>;
  constructor(private readonly env: RelayEnv, private readonly sql: SqlStorage) {}

  async send(deviceToken: string, payload: unknown, expiresAt: number, collapseID: string): Promise<APNsResult> {
    try {
    const providerToken = await this.providerToken();
    const first = await this.request(deviceToken, payload, expiresAt, collapseID, providerToken);
    // A definite rejection did not deliver an alert. Refresh this rejected
    // provider token once; transport failures and ambiguous results never retry.
    if (first === "expired_provider_token") {
      const renewed = await this.providerToken(providerToken);
      const second = await this.request(deviceToken, payload, expiresAt, collapseID, renewed);
      return second === "expired_provider_token" ? "unavailable" : second;
    }
    return first;
    } catch { return "unavailable"; }
  }

  private async request(
    deviceToken: string, payload: unknown, expiresAt: number, collapseID: string, providerToken: string
  ): Promise<APNsResult | "expired_provider_token"> {
    const host = this.env.APNS_ENVIRONMENT === "development" ? "api.sandbox.push.apple.com"
      : this.env.APNS_ENVIRONMENT === "production" ? "api.push.apple.com" : undefined;
    if (!host) return "unavailable";
    try {
      const response = await fetch(`https://${host}/3/device/${deviceToken}`, {
        method: "POST", redirect: "manual", signal: AbortSignal.timeout(10_000),
        headers: {
          "content-type": "application/json", authorization: `bearer ${providerToken}`,
          "apns-topic": this.env.APNS_TOPIC, "apns-push-type": "alert", "apns-priority": "10",
          "apns-expiration": String(expiresAt), "apns-collapse-id": collapseID
        },
        body: JSON.stringify(payload)
      });
      if (response.status === 200) { await response.body?.cancel().catch(() => {}); return "accepted"; }
      const reason = await boundedReason(response);
      if (response.status === 410) return "inactive";
      if (response.status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic")) return "invalid_device_token";
      if (response.status === 403 && reason === "ExpiredProviderToken") return "expired_provider_token";
      return response.status >= 400 && response.status < 500 && reason ? "unavailable" : "unknown";
    } catch { return "unknown"; }
  }

  private async providerToken(rejectedToken?: string): Promise<string> {
    const now = Math.floor(Date.now() / 1000);
    const cached = this.sql.exec<ProviderTokenRow>("SELECT token, created_at, key_id, team_id FROM provider_token WHERE id = 1").toArray()[0];
    // Repeated early expiry errors indicate clock/configuration trouble. Avoid
    // rotating tokens on every request and tripping Apple's update limit.
    if (cached && cached.token === rejectedToken && now - cached.created_at < 20 * 60) throw new RelayError(503, "service_unavailable");
    if (cached && cached.created_at <= now && now - cached.created_at < 40 * 60 &&
        cached.key_id === this.env.APNS_KEY_ID && cached.team_id === this.env.APNS_TEAM_ID && cached.token !== rejectedToken) {
      return cached.token;
    }
    if (this.signing) return this.signing;
    this.signing = this.createProviderToken(now);
    try { return await this.signing; } finally { this.signing = undefined; }
  }

  private async createProviderToken(now: number): Promise<string> {
    try {
      const pem = this.env.APNS_PRIVATE_KEY.replaceAll("\\n", "\n").trim();
      const match = /^-----BEGIN PRIVATE KEY-----\s+([A-Za-z0-9+/=\s]+)\s+-----END PRIVATE KEY-----$/.exec(pem);
      if (!match || !/^[A-Z0-9]{10}$/.test(this.env.APNS_KEY_ID) || !/^[A-Z0-9]{10}$/.test(this.env.APNS_TEAM_ID)) {
        throw new Error("invalid_configuration");
      }
      const pkcs8 = Uint8Array.from(atob(match[1].replaceAll(/\s/g, "")), char => char.charCodeAt(0));
      const key = await crypto.subtle.importKey("pkcs8", pkcs8, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
      const encode = (value: unknown) => base64url(new TextEncoder().encode(JSON.stringify(value)));
      const unsigned = `${encode({ alg: "ES256", kid: this.env.APNS_KEY_ID })}.${encode({ iss: this.env.APNS_TEAM_ID, iat: now })}`;
      const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(unsigned));
      const token = `${unsigned}.${base64url(new Uint8Array(signature))}`;
      this.sql.exec("INSERT OR REPLACE INTO provider_token (id, token, created_at, key_id, team_id) VALUES (1, ?, ?, ?, ?)",
        token, now, this.env.APNS_KEY_ID, this.env.APNS_TEAM_ID);
      return token;
    } catch { throw new RelayError(503, "service_unavailable"); }
  }
}

async function boundedReason(response: Response): Promise<string | undefined> {
  if (!response.body) return undefined;
  const reader = response.body.getReader();
  let text = "";
  let bytes = 0;
  const decoder = new TextDecoder();
  try {
    while (true) {
      const part = await reader.read();
      if (part.done) break;
      bytes += part.value.byteLength;
      if (bytes > 2048) return undefined;
      text += decoder.decode(part.value, { stream: true });
    }
    text += decoder.decode();
    const value: unknown = JSON.parse(text);
    if (value && typeof value === "object" && "reason" in value && typeof value.reason === "string") return value.reason;
    return undefined;
  } catch { return undefined; }
  finally { await reader.cancel().catch(() => {}); }
}
