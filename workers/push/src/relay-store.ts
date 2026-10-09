import { policy, RelayError } from "./relay-protocol";

export type RegistrationRow = {
  ordinal: number; id: string; token: string; token_hash: string; pairing_id: string;
  management_hash: string; send_hash: string; nonce_hash: string | null;
  status: "pending" | "active" | "revoked"; activated: number; expires_at: number; last_used: number;
};
type LimitRow = { count: number; expires_at: number };
export type EventRow = { outcome: "pending" | "accepted" | "unknown" | "rejected"; expires_at: number };

/** All read/decide/write operations below are synchronous SQLite transactions.
 * No transaction is held across APNs or another network operation. */
export class RelayStore {
  readonly sql: SqlStorage;
  constructor(private readonly storage: DurableObjectStorage) {
    this.sql = storage.sql;
    storage.transactionSync(() => {
      this.sql.exec("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)");
      if (this.sql.exec("SELECT version FROM schema_version").toArray().length === 0) this.sql.exec("INSERT INTO schema_version VALUES (1)");
      if (this.sql.exec<{ version: number }>("SELECT version FROM schema_version").one().version !== 1) throw new Error("unsupported_schema");
      this.sql.exec(`CREATE TABLE IF NOT EXISTS registrations (
        ordinal INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, token TEXT NOT NULL,
        token_hash TEXT NOT NULL, pairing_id TEXT NOT NULL, management_hash TEXT NOT NULL,
        send_hash TEXT NOT NULL, nonce_hash TEXT, status TEXT NOT NULL,
        activated INTEGER NOT NULL DEFAULT 0, expires_at INTEGER NOT NULL, last_used INTEGER NOT NULL
      )`);
      this.sql.exec("CREATE INDEX IF NOT EXISTS registrations_token ON registrations(token_hash, ordinal)");
      this.sql.exec("CREATE INDEX IF NOT EXISTS registrations_expiry ON registrations(expires_at)");
      this.sql.exec("CREATE TABLE IF NOT EXISTS limits (key TEXT PRIMARY KEY, count INTEGER NOT NULL, expires_at INTEGER NOT NULL)");
      this.sql.exec(`CREATE TABLE IF NOT EXISTS events (
        registration_id TEXT NOT NULL, event_id TEXT NOT NULL, outcome TEXT NOT NULL,
        expires_at INTEGER NOT NULL, PRIMARY KEY (registration_id, event_id)
      )`);
      this.sql.exec(`CREATE TABLE IF NOT EXISTS provider_token (
        id INTEGER PRIMARY KEY, token TEXT NOT NULL, created_at INTEGER NOT NULL,
        key_id TEXT NOT NULL, team_id TEXT NOT NULL
      )`);
    });
  }

  transaction<T>(body: () => T): T { return this.storage.transactionSync(body); }
  registration(id: string): RegistrationRow | undefined {
    return this.sql.exec<RegistrationRow>("SELECT * FROM registrations WHERE id = ?", id).toArray()[0];
  }

  insert(value: Omit<RegistrationRow, "ordinal" | "activated">): void {
    this.sql.exec(`INSERT INTO registrations
      (id, token, token_hash, pairing_id, management_hash, send_hash, nonce_hash, status, expires_at, last_used)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, value.id, value.token, value.token_hash, value.pairing_id,
      value.management_hash, value.send_hash, value.nonce_hash, value.status, value.expires_at, value.last_used);
  }

  consumeLimit(key: string, maximum: number, seconds: number, now: number): void {
    const row = this.sql.exec<LimitRow>("SELECT count, expires_at FROM limits WHERE key = ?", key).toArray()[0];
    if (row && row.expires_at > now) {
      if (row.count >= maximum) throw new RelayError(429, "rate_limited", row.expires_at - now);
      this.sql.exec("UPDATE limits SET count = count + 1 WHERE key = ?", key);
    } else {
      this.sql.exec("INSERT OR REPLACE INTO limits (key, count, expires_at) VALUES (?, 1, ?)", key, now + seconds);
    }
  }

  activate(row: RegistrationRow, now: number): void {
    const current = this.registration(row.id);
    if (!current || current.status === "revoked" || current.expires_at <= now) throw new RelayError(410, "registration_inactive");
    if (current.status === "active") return;
    // The insertion order is monotonic even when requests share a timestamp.
    // A late proof cannot displace a newer completed enrollment for this phone.
    const newer = this.sql.exec("SELECT id FROM registrations WHERE token_hash = ? AND ordinal > ? AND activated = 1 LIMIT 1",
      row.token_hash, row.ordinal).toArray().length > 0;
    if (newer) throw new RelayError(409, "registration_superseded");
    this.sql.exec(`UPDATE registrations SET status = 'revoked', nonce_hash = NULL, token = '', expires_at = ?
      WHERE token_hash = ? AND id <> ? AND status = 'active'`, now + policy.eventSeconds, row.token_hash, row.id);
    this.sql.exec("UPDATE registrations SET status = 'active', activated = 1, nonce_hash = NULL, expires_at = ?, last_used = ? WHERE id = ? AND status = 'pending'",
      now + policy.activeSeconds, now, row.id);
  }

  revoke(id: string, now: number): void {
    this.sql.exec("UPDATE registrations SET status = 'revoked', nonce_hash = NULL, token = '', expires_at = ? WHERE id = ? AND status <> 'revoked'",
      now + policy.eventSeconds, id);
  }

  touch(id: string, now: number): void {
    this.sql.exec("UPDATE registrations SET expires_at = ?, last_used = ? WHERE id = ? AND status = 'active' AND expires_at > ?",
      now + policy.activeSeconds, now, id, now);
  }

  event(registrationID: string, eventID: string): EventRow | undefined {
    return this.sql.exec<EventRow>("SELECT outcome, expires_at FROM events WHERE registration_id = ? AND event_id = ?",
      registrationID, eventID).toArray()[0];
  }

  reserveEvent(registrationID: string, eventID: string, now: number): void {
    this.sql.exec("INSERT OR REPLACE INTO events (registration_id, event_id, outcome, expires_at) VALUES (?, ?, 'pending', ?)",
      registrationID, eventID, now + policy.eventSeconds);
  }

  finishEvent(registrationID: string, eventID: string, outcome: EventRow["outcome"]): void {
    this.sql.exec("UPDATE events SET outcome = ? WHERE registration_id = ? AND event_id = ? AND outcome = 'pending'",
      outcome, registrationID, eventID);
  }

  prune(now: number): boolean {
    return this.transaction(() => {
      this.sql.exec("DELETE FROM registrations WHERE expires_at <= ?", now);
      this.sql.exec("DELETE FROM limits WHERE expires_at <= ?", now);
      this.sql.exec("DELETE FROM events WHERE expires_at <= ?", now);
      return this.sql.exec("SELECT id FROM registrations LIMIT 1").toArray().length > 0 ||
        this.sql.exec("SELECT key FROM limits LIMIT 1").toArray().length > 0 ||
        this.sql.exec("SELECT event_id FROM events LIMIT 1").toArray().length > 0;
    });
  }
}
