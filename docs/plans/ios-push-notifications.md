# iPhone session notifications

Status: implementation in progress. Development delivery through Cloudflare and APNs has been verified. Production deployment and activation are separate actions.

## User flow

After pairing, or after an update, Toastty introduces notifications once at the first connection to a Mac that supports them. Continue opens the iOS permission prompt. Not now and Don't Allow are remembered.

After Allow, the user returns to Home. Registration runs without a blocking screen. An interrupted attempt resumes when the app returns to the foreground. A failure while the app is open shows a small error with Retry. Settings shows whether alerts are on, off, being enabled, or waiting to turn off. There is no quick-check screen or success modal.

Session alerts contain the session title and one fixed status: Ready or Needs approval. The introduction discloses that the title passes through Toastty's notification service and Apple. Hiding session titles is deferred. No preference, API field, or dormant implementation for it is included.

The service verifies that the registering app receives notifications before authorizing session alerts. The app handles this automatically while open. A verification alert already in flight can appear if the app moves to the background. Its fixed copy remains valid after interruption. This feature does not depend on silent push or guaranteed background execution.

## Components

- The iPhone owns permission, notification intent, enrollment, and the management credential. A separate Keychain record keeps incomplete work and pending revocations across app restarts and unpairing. Pairing credentials retain their existing schema.
- The Mac stores a send credential for each enrolled native device. It uses the accepted session-event callback, independent of desktop focus and optional shell hooks. It sends only for an active native device with read permission, while remote access is enabled.
- A separate Worker and one SQLite Durable Object hold registrations, credential hashes, rate limits, short-lived event deduplication records, and the cached APNs provider token. The existing operator probe remains separate. Production uses separate resources and configuration.

The Mac and iPhone use configured HTTPS relay origins. Native registration never accepts an arbitrary relay URL. Private active and cleanup records retain the trusted origin used at registration so a later configuration change does not redirect credentials.

## Contract v1

All IDs are UUID strings. Tokens and nonces are random 32-byte base64url strings without padding. Wire timestamps are Unix seconds. JSON bodies are bounded at 4 KiB. Unknown fields are rejected. Redirects are not followed. Secrets, APNs tokens, nonces, and session titles are excluded from logs and diagnostics.

A deployment pins `relayID`, `apnsEnvironment` (`development` or `production`), and APNs topic. Development is `toastty-push-dev-v1`, `development`, and `com.giantthings.toastty.mobile.dev`. Both clients must agree with the host configuration before enrollment starts. Unconfigured app builds do not expose the feature.

### Relay

- `POST /v1/registrations`: `{registrationID, deviceToken, pairingID, managementToken, sendToken}`. Persist the attempt before sending its verification push. Return `{registrationID, state: "pending", expiresAt}`. An identical authenticated retry does not resend. The HTTP response never includes the nonce. The phone persists keys before this call and can process proof before the begin response arrives.
- Verification APNs payload: `toastty: {version: 1, kind: "verification", registrationID, pairingID, nonce}` plus fixed neutral alert copy. One challenge per registration removes the need for another challenge ID. Expiration matches the five-minute challenge window; verification uses a fixed collapse ID. Store only the nonce hash on the relay.
- `POST /v1/registrations/<id>/complete`, Bearer management token, body `{nonce}`. Activate only with the correct unexpired proof. Return `{registrationID, pairingID, state: "active"}`. Repeating completion with the management token after activation is idempotent. A completion can precede APNs' HTTP response; later writes cannot revert activation.
- `GET /v1/registrations/<id>`, Bearer management token: active status and pairing identity. This is phone reconciliation, not a Mac authorization call.
- `DELETE /v1/registrations/<id>`, Bearer management or send token: revoke this registration only. The caller treats missing/expired registration as cleanup complete; invalid credentials cannot mutate an existing record.
- `POST /v1/registrations/<id>/notifications`, Bearer send token: `{eventID, conversationID, sessionTitle, status}` where status is `ready` or `needs_approval`. The relay supplies stored pairing and registration identity, fixed body, topic, and destination. No caller-controlled destination or URL.

Completion replaces older active registrations for the same APNs token. The phone supports one paired Mac and one current attempt. The relay also prevents an older pending attempt from replacing a newer completed one. Beginning an attempt does not disturb active registration. A changed APNs token requires a new proof.

Native capabilities are distinct: management can complete, inspect, and revoke; send can send and revoke itself. Short-lived deduplication is keyed by registration and event ID and reserved before APNs I/O. Neither Mac nor relay automatically retries an ambiguous notification send. APNs 410 disables a registration. Inactive registration retention is bounded; phone reconciliation can recover expiration.

Shared alert payload: `toastty: {version: 1, kind: "session", registrationID, pairingID, conversationID, eventID}`. The title is at most 512 UTF-8 bytes; Mac truncates on a grapheme boundary and removes control characters, relay validates. Delivered alerts route by the current pairing ID, so an older alert from the same pairing remains usable after token renewal or Off/On. Alerts from a different pairing are ignored.

### Mac native API

- Capability: `push_notifications`.
- `GET /v1/native-device/push-configuration`: `RemoteGatewayPushConfigurationResponse {protocolVersion, relayID, apnsEnvironment, registrationID}`. Both relay fields are absent when not configured. No credential or relay URL is returned.
- `POST /v1/native-device/push`: `RemoteGatewayPushRegistrationRequest {protocolVersion, registration: RemoteGatewayPushRegistration?}`. Registration is `{registrationID, sendToken, relayID}`. Null clears it. Response: `RemoteGatewayPushRegistrationResponse {protocolVersion, registrationID}`.

Both routes require existing native bearer and Tailscale identity checks. Registration additionally requires read scope and matching configured relay ID. It derives device identity from authentication. The authenticated phone has already verified relay enrollment; the Mac persists the grant synchronously rather than making another network verification request. Repeated identical handoff is harmless. A missing/dead send grant clears the matching saved enrollment; temporary service errors drop only that event.

Mac replacement, clear, and device revocation atomically move old credentials into a private cleanup list before clearing active state. Startup and later operations retry bounded cleanup. Phone Off and unpair retain management cleanup independently of the deleted native credential. State cannot claim confirmed Off until the relay has accepted revocation. Alerts already sent can still arrive.

## Build and validation

The normal app delegate handles APNs callbacks and taps. The old probe delegate remains isolated. Development push entitlements apply only to the fixed physical-device Debug identity. Production release support is explicitly configured and cannot reuse the sandbox relay. Arbitrary worktree identities and prod-test do not acquire an invalid push entitlement.

Worker API tests use a disposable local Workers runtime, mocked APNs, and generated signing keys. Cover proof races, replay, expiration, lost responses, token replacement order, limits, revocation, duplicate events, and fixed payloads. Mac tests cover native auth, persistence, cleanup, event eligibility, and relay errors. iOS tests cover permission, automatic enrollment, interrupted work, Keychain lock, stale pairing, cleanup, and tap routing. Shared JSON fixtures check the cross-language contract.

Use the repository's remote macOS and iOS test wrappers; both regenerate and build their graphs. Then run independent UI QA and a bounded development-device session covering automatic enrollment, real session alerts, locked-phone delivery, tap routing, and Off. Production activation and merging remain separate approvals.
