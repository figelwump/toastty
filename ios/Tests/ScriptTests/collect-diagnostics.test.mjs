import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync,
  rmSync, statSync, writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("../../scripts/collect-diagnostics.mjs", import.meta.url));
const bundleID = "com.giantthings.toastty.mobile.dev";

function report(overrides = {}) {
  return {
    schemaVersion: 1,
    app: { bundleID, version: "0.1.0", build: "123" },
    runID: "12345678-1234-4234-8234-123456789abc",
    runStartedAt: "2026-01-01T12:00:00Z",
    capturedAt: "2026-01-01T12:01:00.123Z",
    events: [{ sequence: 1, recordedAt: "2026-01-01T12:00:30Z", event: "request_succeeded" }],
    ...overrides,
  };
}

// This projection matches ToasttyPushSetupSnapshot and the app's JSON encoder.
function pushSnapshot() {
  return {
    stage: "idle", foreground: true, connected: false, desired: true,
    reconciling: false, activeRegistrationEnabled: false, permission: "allowed",
    tokenPresent: true, configurationMatches: true,
    cooldownUntil: "2026-01-01T12:02:00.123Z",
    savedCooldownUntil: "2026-01-01T12:03:00.123Z",
    retryScheduledAt: "2026-01-01T12:02:01Z",
    cleanupCount: 0, lastAction: "reconcile", lastReturnReason: "relayCooldown",
    lastReturnAt: "2026-01-01T12:00:30Z", resultSequence: 2,
  };
}

function fixture(t, payload = report()) {
  const root = mkdtempSync(path.join(os.tmpdir(), "toastty-collect-test-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const bin = path.join(root, "bin");
  mkdirSync(bin);
  const payloadPath = path.join(root, "fixture.json");
  writeFileSync(payloadPath, typeof payload === "string" ? payload : JSON.stringify(payload));
  const log = path.join(root, "commands.jsonl");
  writeFileSync(path.join(bin, "xcrun"), `#!${process.execPath}
const fs = require("node:fs");
const args = process.argv.slice(2);
fs.appendFileSync(process.env.STUB_LOG, JSON.stringify(args) + "\\n");
process.stdout.write("sensitive-device-output");
process.stderr.write("sensitive-device-error");
if (process.env.STUB_COPY_MODE === "fail") process.exit(7);
if (process.env.STUB_COPY_MODE === "signal") process.kill(process.pid, "SIGTERM");
if (process.env.STUB_COPY_MODE !== "missing") {
  fs.copyFileSync(process.env.STUB_PAYLOAD, args[args.indexOf("--destination") + 1]);
}
`, { mode: 0o755 });
  const output = path.join(root, "saved", "capture.json");
  return {
    root, log, output, payloadPath,
    run(extra = [], env = {}, args = ["--device", "EXPLICIT-IPHONE", "--bundle-id", bundleID, "--output", output]) {
      return spawnSync(process.execPath, [script, ...args, ...extra], {
        encoding: "utf8",
        env: {
          ...process.env,
          PATH: `${bin}:/usr/bin:/bin`,
          STUB_PAYLOAD: payloadPath,
          STUB_LOG: log,
          ...env,
        },
      });
    },
  };
}

function assertFailure(result, pattern) {
  assert.equal(result.status, 1, result.stdout);
  assert.match(result.stderr, pattern);
  assert.match(result.stderr, /No new report was saved/);
  assert.doesNotMatch(result.stdout + result.stderr, /sensitive-(?:device|report)/);
}

test("copy uses only the selected app's saved file and saves an old snapshot with private permissions", (t) => {
  const f = fixture(t, report({
    lastFlushReason: "background",
    push: pushSnapshot(),
    events: [{
      sequence: 1, recordedAt: "2026-01-01T12:00:30Z", event: "push_rate_limited",
      pushDetails: {
        registrationNumber: 1, statusCode: 429, code: "verification_token_limit",
        rateLimitSource: "relay", providerRefreshAttempted: false, retryAfterSeconds: 60,
      },
      pushSnapshot: pushSnapshot(),
    }],
  }));
  const result = f.run(["--expected-build", "123"]);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(readFileSync(f.output)), JSON.parse(readFileSync(f.payloadPath)));
  assert.equal(statSync(f.output).mode & 0o777, 0o600);
  assert.deepEqual(readdirSync(path.dirname(f.output)), ["capture.json"]);
  assert.match(result.stdout, /Snapshot time: 2026-01-01T12:01:00.123Z; age: \d+\.\d seconds/);
  assert.match(result.stdout, /saved capture, not live proof/);
  assert.match(result.stdout, /suspended app can have an old snapshot/);
  assert.match(result.stdout, /Push snapshot \(frozen observation at capture, not current live state\)/);
  assert.match(result.stdout, /stage: idle/);
  assert.match(result.stdout, /permission: allowed/);
  assert.match(result.stdout, /reconciling: false/);
  assert.match(result.stdout, /active registration enabled: false/);
  assert.match(result.stdout, /last action: reconcile/);
  assert.match(result.stdout, /last return reason: relayCooldown/);
  assert.match(result.stdout, /last return time: 2026-01-01T12:00:30.000Z/);
  assert.match(result.stdout, /cooldown until: 2026-01-01T12:02:00.123Z; remaining at capture: 60.0 seconds/);
  assert.match(result.stdout, /saved cooldown until: 2026-01-01T12:03:00.123Z; remaining at capture: 120.0 seconds/);
  assert.match(result.stdout, /retry scheduled at: 2026-01-01T12:02:01.000Z/);
  assert.doesNotMatch(result.stdout + result.stderr, /sensitive-device/);
  const commands = readFileSync(f.log, "utf8").trim().split("\n").map(JSON.parse);
  assert.equal(commands.length, 1);
  const args = commands[0];
  assert.deepEqual(args.slice(0, 13), [
    "devicectl", "device", "copy", "from", "--device", "EXPLICIT-IPHONE",
    "--domain-type", "appDataContainer", "--domain-identifier", bundleID,
    "--source", "Library/Application Support/ToasttyDiagnostics/current.json", "--destination",
  ]);
  assert.notEqual(args[13], f.output);
  assert.equal(existsSync(path.dirname(args[13])), false, "temporary copy is removed");
  assert.deepEqual(args.slice(14), ["--timeout", "30"]);
});

test("dry run validates arguments but does not contact a device or create output", (t) => {
  const f = fixture(t);
  const result = f.run(["--dry-run"]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Read-only command: xcrun/);
  assert.match(result.stdout, /Dry run: no device command ran/);
  assert.equal(existsSync(f.log), false);
  assert.equal(existsSync(path.dirname(f.output)), false);
});

test("--previous selects only the retained prior run and permits additive fields", (t) => {
  const f = fixture(t, report({ futureField: { value: "ignored" } }));
  const result = f.run(["--previous"]);
  assert.equal(result.status, 0, result.stderr);
  const args = JSON.parse(readFileSync(f.log, "utf8").trim());
  assert.equal(args[args.indexOf("--source") + 1], "Library/Application Support/ToasttyDiagnostics/previous.json");
  assert.deepEqual(JSON.parse(readFileSync(f.output)).futureField, { value: "ignored" });
});

test("summary omits arbitrary snapshot strings while saved JSON preserves additive data", (t) => {
  const f = fixture(t, report({
    push: {
      stage: "sensitive-report-content\n",
      lastAction: "x".repeat(65), lastReturnReason: "sensitive-report-content: secret",
      lastReturnAt: "sensitive-report-time", cooldownUntil: "sensitive-report-deadline",
      savedCooldownUntil: "2025-12-31T12:00:00Z", retryScheduledAt: {},
      reconciling: "sensitive-report-boolean", permission: ["sensitive-report-permission"],
      extra: "sensitive-report-extra",
    },
  }));
  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.doesNotMatch(result.stdout + result.stderr, /sensitive-report|x{65}/);
  assert.match(result.stdout, /remaining at capture: 0.0 seconds/);
  assert.equal(JSON.parse(readFileSync(f.output)).push.extra, "sensitive-report-extra");
});

test("saved JSON resolves duplicate keys to the same identity that validation used", (t) => {
  const raw = JSON.stringify(report()).replace(
    `"bundleID":"${bundleID}"`, `"bundleID":"com.other.app","bundleID":"${bundleID}"`,
  );
  const f = fixture(t, raw);
  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  const saved = readFileSync(f.output, "utf8");
  assert.equal((saved.match(/"bundleID"/g) ?? []).length, 1);
  assert.equal(JSON.parse(saved).app.bundleID, bundleID);
  assert.doesNotMatch(saved, /com.other.app/);
});

test("required, repeated, and unreasonable arguments fail before tool access", async (t) => {
  for (const extra of [
    ["--device", "PHONE"], ["--unknown"], ["--max-age-seconds", "Infinity"],
    ["--max-age-seconds", "-1"], ["--max-age-seconds", "31536001"],
    ["--max-age-seconds", "NaN"], ["--max-age-seconds", ""],
    ["--device", "--destination"],
  ]) {
    await t.test(JSON.stringify(extra), (t) => {
      const f = fixture(t);
      assertFailure(f.run(extra), /argument|seconds|requires/);
      assert.equal(existsSync(f.log), false);
    });
  }
  for (const omitted of ["--device", "--bundle-id", "--output"]) {
    await t.test(`missing ${omitted}`, (t) => {
      const f = fixture(t);
      const args = ["--device", "PHONE", "--bundle-id", bundleID, "--output", f.output];
      const index = args.indexOf(omitted);
      args.splice(index, 2);
      assertFailure(f.run([], {}, args), new RegExp(`${omitted} is required`));
      assert.equal(existsSync(f.log), false);
    });
  }
});

test("copy failures and missing files never reuse an earlier output", async (t) => {
  for (const mode of ["fail", "missing", "signal"]) {
    await t.test(mode, (t) => {
      const f = fixture(t);
      mkdirSync(path.dirname(f.output));
      writeFileSync(f.output, "prior capture");
      const result = f.run([], { STUB_COPY_MODE: mode });
      assertFailure(result, /copy failed|did not produce/);
      if (mode === "fail") assert.match(result.stderr, /exited with status 7/);
      if (mode === "signal") assert.match(result.stderr, /signal SIGTERM/);
      assert.equal(readFileSync(f.output, "utf8"), "prior capture");
    });
  }
});

test("malformed, oversized, and incompatible captures fail without replacing output", async (t) => {
  const cases = [
    ["invalid JSON", '{"private":"sensitive-report-content",', /not valid JSON/],
    ["too large", " ".repeat(256 * 1024 + 1), /256 KiB/],
    ["schema version", report({ schemaVersion: 2 }), /schema/],
    ["missing app", report({ app: undefined }), /schema/],
    ["wrong bundle", report({ app: { bundleID: "com.other.app", version: "1", build: "123" } }), /bundle ID/],
    ["wrong build", report({ app: { bundleID, version: "1", build: "124" } }), /build/],
    ["invalid run ID", report({ runID: "not-a-uuid" }), /schema/],
    ["invalid timestamp", report({ capturedAt: "yesterday" }), /timestamps/],
    ["invalid calendar day", report({ capturedAt: "2026-02-30T00:00:00Z" }), /timestamps/],
    ["backward timestamp", report({ runStartedAt: "2026-01-02T00:00:00Z" }), /timestamps/],
    ["future timestamp", () => report({ capturedAt: new Date(Date.now() + 61_000).toISOString() }), /future/],
    ["too many events", report({ events: Array.from({ length: 129 }, () => ({})) }), /schema/],
    ["invalid event", report({ events: [null] }), /schema/],
    ["missing event fields", report({ events: [{}] }), /schema/],
    ["invalid event timestamp", report({ events: [{ sequence: 1, event: "connected", recordedAt: "invalid" }] }), /schema/],
    ["invalid event sequence", report({ events: [{ sequence: -1, event: "connected", recordedAt: "2026-01-01T12:00:30Z" }] }), /schema/],
    ["invalid push", report({ push: [] }), /schema/],
  ];
  for (const [name, payload, pattern] of cases) {
    await t.test(name, (t) => {
      const f = fixture(t, typeof payload === "function" ? payload() : payload);
      mkdirSync(path.dirname(f.output));
      writeFileSync(f.output, "prior capture");
      assertFailure(f.run(["--expected-build", "123"]), pattern);
      assert.equal(readFileSync(f.output, "utf8"), "prior capture");
      assert.deepEqual(readdirSync(path.dirname(f.output)), ["capture.json"]);
    });
  }
});

test("optional maximum age rejects old captures and accepts a current capture", (t) => {
  const stale = fixture(t);
  assertFailure(stale.run(["--max-age-seconds", "60"]), /older than/);
  assert.equal(existsSync(stale.output), false);
  const fresh = fixture(t, report({ capturedAt: new Date().toISOString() }));
  const result = fresh.run(["--max-age-seconds", "60"]);
  assert.equal(result.status, 0, result.stderr);
  assert.ok(existsSync(fresh.output));
  const ahead = fixture(t, report({ capturedAt: new Date(Date.now() + 60_000).toISOString() }));
  const aheadResult = ahead.run(["--max-age-seconds", "0"]);
  assert.equal(aheadResult.status, 0, aheadResult.stderr);
  assert.match(aheadResult.stdout, /age: 0.0 seconds/);
  assert.match(aheadResult.stdout, /Device clock is ahead by/);
  assert.match(aheadResult.stdout, /displayed age is clamped to zero/);
});
