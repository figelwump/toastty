#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HELPER="$ROOT_DIR/scripts/remote/live-gateway-test-environment.sh"
WRAPPER="$ROOT_DIR/scripts/remote/test.sh"
BROKER="$ROOT_DIR/scripts/remote/live-gateway-test-broker.mjs"
TEST_ROOT="$(mktemp -d /tmp/toastty-live-gateway-env.XXXXXX)"
VALID_URL="https://toastty-probe.example-tailnet.ts.net"
VALID_CREDENTIAL="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

cleanup() {
  if [[ -n "${BROKER_PID:-}" ]]; then
    kill -TERM "$BROKER_PID" >/dev/null 2>&1 || true
    wait "$BROKER_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

# shellcheck source=../remote/live-gateway-test-environment.sh
source "$HELPER"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

expect_invalid_url() {
  local value="$1"
  if toastty_live_gateway_url_is_valid "$value"; then
    fail "accepted a non-canonical live gateway URL"
  fi
}

expect_invalid_credential() {
  local value="$1"
  if toastty_live_gateway_credential_is_valid "$value"; then
    fail "accepted invalid live gateway credential material"
  fi
}

toastty_live_gateway_url_is_valid "$VALID_URL" || fail "rejected a canonical live gateway URL"
toastty_live_gateway_credential_is_valid "$VALID_CREDENTIAL" \
  || fail "rejected valid live gateway credential material"

expect_invalid_url "http://toastty-probe.example-tailnet.ts.net"
expect_invalid_url "https://toastty-probe.example-tailnet.ts.net/"
expect_invalid_url "https://Toastty-probe.example-tailnet.ts.net"
expect_invalid_url "https://toastty-probe.example-tailnet.ts.net.evil.example"
expect_invalid_url "https://toastty-probe..example-tailnet.ts.net"
expect_invalid_url "https://-toastty-probe.example-tailnet.ts.net"
expect_invalid_url "https://toastty-probe.example-tailnet.ts.net?secret=1"

expect_invalid_credential "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
expect_invalid_credential "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA!"
expect_invalid_credential "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

safe_result="$({
  printf 'set +x\nset -euo pipefail\n'
  printf 'unset TOASTTY_MOBILE_LIVE_GATEWAY_URL TOASTTY_MOBILE_LIVE_GATEWAY_CREDENTIAL TOASTTY_MOBILE_LIVE_ALLOW_DESTRUCTIVE_REVOCATION TOASTTY_MOBILE_LIVE_FORWARDING_PROBE TEST_RUNNER_TOASTTY_MOBILE_LIVE_GATEWAY_URL TEST_RUNNER_TOASTTY_MOBILE_LIVE_GATEWAY_CREDENTIAL TEST_RUNNER_TOASTTY_MOBILE_LIVE_ALLOW_DESTRUCTIVE_REVOCATION TEST_RUNNER_TOASTTY_MOBILE_LIVE_FORWARDING_PROBE\n'
  toastty_emit_live_gateway_remote_setup "$VALID_URL" "$VALID_CREDENTIAL" 0
  cat <<'EOF'
[[ "$live_gateway_url" == https://*.ts.net ]]
[[ ${#live_gateway_credential} -eq 43 ]]
[[ "$live_gateway_allow_destructive" == "false" ]]
[[ "$TEST_RUNNER_TOASTTY_MOBILE_LIVE_FORWARDING_PROBE" == "1" ]]
[[ -z "${TOASTTY_MOBILE_LIVE_GATEWAY_CREDENTIAL:-}" ]]
[[ -z "${TEST_RUNNER_TOASTTY_MOBILE_LIVE_GATEWAY_CREDENTIAL:-}" ]]
printf 'live-forwarding=valid destructive=false credential-bytes=%s\n' "${#live_gateway_credential}"
EOF
} | /bin/bash --noprofile --norc -s --)"

[[ "$safe_result" == "live-forwarding=valid destructive=false credential-bytes=43" ]] \
  || fail "safe live environment did not round-trip"
[[ "$safe_result" != *"$VALID_URL"* && "$safe_result" != *"$VALID_CREDENTIAL"* ]] \
  || fail "safe live environment exposed its inputs"

destructive_result="$({
  printf 'set +x\nset -euo pipefail\n'
  toastty_emit_live_gateway_remote_setup "$VALID_URL" "$VALID_CREDENTIAL" 1
  cat <<'EOF'
printf 'destructive=%s\n' "$live_gateway_allow_destructive"
EOF
} | /bin/bash --noprofile --norc -s --)"
[[ "$destructive_result" == "destructive=true" ]] \
  || fail "explicit destructive opt-in was not preserved"

# Prove the required xtrace guard keeps even the dummy sentinels out of trace
# output before the helper reads or serializes them.
HELPER="$HELPER" \
TOASTTY_TEST_LIVE_URL="$VALID_URL" \
TOASTTY_TEST_LIVE_CREDENTIAL="$VALID_CREDENTIAL" \
  /bin/bash --noprofile --norc -x -s -- \
  >"$TEST_ROOT/xtrace-stdout.log" 2>"$TEST_ROOT/xtrace-stderr.log" <<'EOF'
set +x
source "$HELPER"
toastty_emit_live_gateway_remote_setup \
  "$TOASTTY_TEST_LIVE_URL" \
  "$TOASTTY_TEST_LIVE_CREDENTIAL" \
  0 >/dev/null
EOF

if rg -Fq "$VALID_URL" "$TEST_ROOT/xtrace-stdout.log" "$TEST_ROOT/xtrace-stderr.log" \
  || rg -Fq "$VALID_CREDENTIAL" "$TEST_ROOT/xtrace-stdout.log" "$TEST_ROOT/xtrace-stderr.log"; then
  fail "xtrace exposed live gateway inputs"
fi

BROKER_STATE="$TEST_ROOT/broker-state.json"
printf '%s\n%s\nfalse\n' "$VALID_URL" "$VALID_CREDENTIAL" \
  | node "$BROKER" --state-file "$BROKER_STATE" \
    >"$TEST_ROOT/broker-stdout.log" 2>"$TEST_ROOT/broker-stderr.log" &
BROKER_PID=$!
for _ in $(seq 1 100); do
  if [[ -s "$BROKER_STATE" ]]; then
    break
  fi
  if ! kill -0 "$BROKER_PID" >/dev/null 2>&1; then
    wait "$BROKER_PID" >/dev/null 2>&1 || true
    fail "live gateway broker exited before readiness"
  fi
  sleep 0.02
done
[[ -s "$BROKER_STATE" ]] || fail "live gateway broker did not become ready"
if rg -Fq "$VALID_URL" "$BROKER_STATE" || rg -Fq "$VALID_CREDENTIAL" "$BROKER_STATE"; then
  fail "live gateway broker state persisted gateway inputs"
fi

BROKER_METADATA="$(node -e '
  const fs = require("node:fs");
  const state = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  process.stdout.write(`${state.port} ${state.token}`);
' "$BROKER_STATE")"
read -r BROKER_PORT BROKER_TOKEN <<<"$BROKER_METADATA"

denied_result="$(
  BROKER_PORT="$BROKER_PORT" \
  BROKER_TOKEN="wrong-${BROKER_TOKEN}" \
    node -e '
      const response = await fetch(`http://127.0.0.1:${process.env.BROKER_PORT}/v1/config`, {
        headers: { Authorization: `Bearer ${process.env.BROKER_TOKEN}` },
      });
      process.stdout.write(`denied=${response.status}`);
    '
)"
[[ "$denied_result" == "denied=404" ]] || fail "live gateway broker accepted a wrong token"

broker_result="$(
  BROKER_PORT="$BROKER_PORT" \
  BROKER_TOKEN="$BROKER_TOKEN" \
  EXPECTED_URL="$VALID_URL" \
  EXPECTED_CREDENTIAL="$VALID_CREDENTIAL" \
    node -e '
      const response = await fetch(`http://127.0.0.1:${process.env.BROKER_PORT}/v1/config`, {
        cache: "no-store",
        headers: { Authorization: `Bearer ${process.env.BROKER_TOKEN}` },
      });
      const value = await response.json();
      if (!response.ok
          || value.gatewayURL !== process.env.EXPECTED_URL
          || value.credential !== process.env.EXPECTED_CREDENTIAL
          || value.allowDestructiveRevocation !== false) {
        process.exit(1);
      }
      process.stdout.write("broker=valid");
    '
)"
[[ "$broker_result" == "broker=valid" ]] || fail "live gateway broker did not return its inputs"
[[ "$broker_result" != *"$VALID_URL"* && "$broker_result" != *"$VALID_CREDENTIAL"* ]] \
  || fail "live gateway broker exposed its inputs"

# Denied requests do not consume the eight-response budget. The first success
# above plus seven more must pass; the ninth authenticated response is denied.
budget_result="$(
  BROKER_PORT="$BROKER_PORT" \
  BROKER_TOKEN="$BROKER_TOKEN" \
    node -e '
      const statuses = [];
      for (let attempt = 0; attempt < 8; attempt += 1) {
        const response = await fetch(`http://127.0.0.1:${process.env.BROKER_PORT}/v1/config`, {
          headers: { Authorization: `Bearer ${process.env.BROKER_TOKEN}` },
        });
        statuses.push(response.status);
        await response.arrayBuffer();
      }
      process.stdout.write(statuses.join(","));
    '
)"
[[ "$budget_result" == "200,200,200,200,200,200,200,404" ]] \
  || fail "live gateway broker request budget was not enforced"

kill -TERM "$BROKER_PID"
wait "$BROKER_PID"
BROKER_PID=""
[[ ! -e "$BROKER_STATE" ]] || fail "live gateway broker left its state file behind"
[[ ! -s "$TEST_ROOT/broker-stdout.log" ]] || fail "live gateway broker wrote unexpected stdout"
if rg -Fq "$VALID_URL" "$TEST_ROOT/broker-stderr.log" \
  || rg -Fq "$VALID_CREDENTIAL" "$TEST_ROOT/broker-stderr.log"; then
  fail "live gateway broker logged its inputs"
fi
closed_result="$(
  BROKER_PORT="$BROKER_PORT" \
    node -e '
      try {
        await fetch(`http://127.0.0.1:${process.env.BROKER_PORT}/v1/config`, {
          signal: AbortSignal.timeout(500),
        });
        process.stdout.write("closed=false");
      } catch {
        process.stdout.write("closed=true");
      }
    '
)"
[[ "$closed_result" == "closed=true" ]] || fail "live gateway broker still accepted connections"

if TOASTTY_MOBILE_LIVE_GATEWAY_URL= \
   TOASTTY_MOBILE_LIVE_GATEWAY_CREDENTIAL= \
   /bin/bash "$WRAPPER" --live-gateway \
     >"$TEST_ROOT/missing-stdout.log" 2>"$TEST_ROOT/missing-stderr.log"; then
  fail "wrapper accepted missing live gateway inputs"
fi
if ! rg -Fxq 'error: --live-gateway requires canonical URL and credential inputs' \
  "$TEST_ROOT/missing-stderr.log"; then
  fail "wrapper did not fail missing inputs categorically"
fi

if /bin/bash "$WRAPPER" --allow-destructive-live-revocation \
  >"$TEST_ROOT/destructive-stdout.log" 2>"$TEST_ROOT/destructive-stderr.log"; then
  fail "wrapper accepted destructive mode without --live-gateway"
fi
if ! rg -Fxq 'error: --allow-destructive-live-revocation requires --live-gateway' \
  "$TEST_ROOT/destructive-stderr.log"; then
  fail "wrapper did not reject an unscoped destructive opt-in"
fi

printf 'ok: remote live gateway environment self-test passed\n'
