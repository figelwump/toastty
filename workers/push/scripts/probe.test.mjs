import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { spawn } from "node:child_process";
import { test } from "node:test";
import assert from "node:assert/strict";
import { probe, runWrangler, withProbeCredential, wranglerEnvironment } from "./probe.mjs";

test("passes secret values only through stdin and does not forward CLI output", async () => {
  const input = JSON.stringify({ PUSH_PROBE_AUTH: "dummy-secret-for-test" });
  let received = "";
  await runWrangler(["secret", "bulk"], {
    input, environment: {},
    spawnProcess(command, args, options) {
      assert.equal(JSON.stringify([command, args, options]).includes("dummy-secret-for-test"), false);
      const child = new EventEmitter();
      child.stdin = new PassThrough();
      child.stdout = new PassThrough();
      child.stderr = new PassThrough();
      child.stdin.on("data", (chunk) => { received += chunk; });
      child.stdin.on("finish", () => {
        child.stdout.end(input);
        child.stderr.end(input);
        child.emit("close", 0);
      });
      return child;
    }
  });
  assert.equal(received, input);
});

test("forwards only Cloudflare credentials and basic process settings", () => {
  const result = wranglerEnvironment({
    PATH: "/bin", TOASTTY_CLOUDFLARE_API_TOKEN: "dummy-api-token",
    TOASTTY_CLOUDFLARE_ACCOUNT_ID: "dummy-account", UNRELATED_SECRET: "must-not-forward"
  });
  assert.equal(result.CLOUDFLARE_API_TOKEN, "dummy-api-token");
  assert.equal(result.CLOUDFLARE_ACCOUNT_ID, "dummy-account");
  assert.equal(result.UNRELATED_SECRET, undefined);
});

test("waits for secret propagation without retrying APNs transport failures", async () => {
  let calls = 0;
  const result = await probe("dummy", { fetchRequest: async () => {
    calls++;
    if (calls === 1) return Response.json({ error: "probe_disabled" }, { status: 503 });
    return Response.json({ transportReachable: true, notificationDelivered: false,
      apnsStatus: 403, apnsReason: "MissingProviderToken", apnsID: "b0cbab37-56ba-42ac-a5a9-b871a1d26454" });
  }, pause: async () => {} });
  assert.equal(calls, 2);
  assert.equal(result.transportReachable, true);
  calls = 0;
  await assert.rejects(probe("dummy", { fetchRequest: async () => {
    calls++;
    return Response.json({ error: "apns_transport_failed" }, { status: 502 });
  } }), /apns_transport_failed/);
  assert.equal(calls, 1);
});

test("disables the credential after a failed probe", async () => {
  const updates = [];
  await assert.rejects(withProbeCredential({}, async () => { throw new Error("probe failed"); },
    { run: async (args, { input }) => { updates.push(JSON.parse(input)); } }), /probe failed/);
  assert.equal(updates.length, 2);
  assert.notEqual(updates[0].PUSH_PROBE_AUTH, updates[1].PUSH_PROBE_AUTH);
  assert.equal(updates[1].PUSH_PROBE_EXPIRES_AT, "0");
  assert.equal(updates[1].APNS_PROVIDER_TOKEN, "");
  assert.equal(updates[1].APNS_DEVICE_TOKEN, "");
});

test("never repeats a real send after an ambiguous response or APNs rejection", async () => {
  for (const response of [new Response("upstream error", { status: 502 }),
    Response.json({ apnsAccepted: false, apnsReason: "TooManyProviderTokenUpdates" }, { status: 502 })]) {
    let calls = 0;
    await assert.rejects(probe("dummy", { fetchRequest: async () => { calls++; return response; }, isSend: true }));
    assert.equal(calls, 1);
  }
});

test("reports cleanup failure and expiry without hiding the probe failure", async () => {
  const previousExitCode = process.exitCode;
  let calls = 0;
  await assert.rejects(withProbeCredential({}, async () => { throw new Error("probe failed"); },
    { run: async () => { if (++calls === 2) throw new Error("private CLI output"); } }),
    (error) => {
      assert.match(error.message, /probe failed\nProbe cleanup failed.*expires at/);
      assert.match(error.message, /Rerun without --send/);
      assert.equal(error.message.includes("private CLI output"), false);
      return true;
    });
  assert.equal(process.exitCode, previousExitCode);
});

test("clears every uploaded key after an interruption and removes signal handlers", async () => {
  const source = new EventEmitter();
  const updates = [];
  await assert.rejects(withProbeCredential({}, async (auth, signal) => {
    source.emit("SIGINT");
    signal.throwIfAborted();
  }, { signalSource: source, appleSecrets: { APNS_PROVIDER_TOKEN: "dummy", EXTRA_TEST_KEY: "dummy" },
    run: async (args, { input }) => { updates.push(JSON.parse(input)); } }));
  assert.equal(updates[1].PUSH_PROBE_EXPIRES_AT, "0");
  assert.equal(updates[1].APNS_PROVIDER_TOKEN, "");
  assert.equal(updates[1].EXTRA_TEST_KEY, "");
  assert.equal(source.listenerCount("SIGINT"), 0);
  assert.equal(source.listenerCount("SIGTERM"), 0);
});

test("describes a network error after send as unverified without echoing upstream details", async () => {
  await assert.rejects(probe("dummy", { isSend: true,
    fetchRequest: async () => { throw new Error("private-network-detail"); } }),
    /^Error: Send interrupted\. Delivery is unverified; no retry was attempted\. Check the phone before another send\.$/);
});

test("terminates a stalled Wrangler child after its deadline", async () => {
  await assert.rejects(runWrangler(["secret", "bulk"], {
    environment: {}, timeoutMs: 30,
    spawnProcess(command, args, options) { return spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], options); }
  }), /interrupted/);
});
