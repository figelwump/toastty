# Tailscale Serve Identity Header Probe

Status: accepted evidence for the native-device authentication design.

## Result

On 2026-08-11, a live probe ran on `toastty-mini` with Tailscale 1.102.2.
A temporary tailnet-only Serve mapping forwarded HTTPS port 10000 to a
loopback header-capture server. The existing HTTPS port 443 mapping remained
untouched, and the temporary mapping was removed after the probe.

The baseline request arrived with Tailscale's identity headers, including
`Tailscale-User-Login`, `Tailscale-User-Name`, and
`Tailscale-User-Profile-Pic`, plus `Tailscale-Headers-Info` and the expected
forwarded-host/protocol fields. A second request deliberately supplied fake
login and name headers. Serve removed those values and forwarded the same real
tailnet identity as the baseline request; the backend received no duplicate or
spoofed identity value.

The raw capture is intentionally untracked because it contains personal
identity metadata. Local evidence is retained under
`artifacts/remote-gui/mobile-tailscale-identity-header-probe/`; its
`result.json` records a remote pass with no fallback, and
`remote/artifacts/tailscale-serve-after-probe.txt` shows that only the original
port 443 mapping remained afterward.

## Security consequence

Native pairing may bind a device record to the exact
`Tailscale-User-Login` value supplied by Serve and compare it on later native
requests and WebSocket upgrades. A missing or changed value fails native
authentication. The app-specific per-device Bearer credential remains the
actual authority for scope, revocation, and audit; the Tailscale identity bind
is defense in depth.

This probe does not expand the trust boundary. A local process can connect to
Toastty's loopback listener and forge HTTP headers, so local processes remain
trusted by the host threat model. The result also covers this client and
Tailscale version, not every future Serve version or multi-user ACL policy;
the route-level authorization matrix and live integration tests must still
cover missing and mismatched identities.
