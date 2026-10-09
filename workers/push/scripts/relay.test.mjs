import { generateKeyPairSync } from "node:crypto";
import { EventEmitter } from "node:events";
import { test } from "node:test";
import assert from "node:assert/strict";
import { deployRelay, health, relaySecrets } from "./relay.mjs";

const { privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1", privateKeyEncoding: { type: "pkcs8", format: "pem" }, publicKeyEncoding: { type: "spki", format: "pem" } });
const source = {
  TOASTTY_CLOUDFLARE_API_TOKEN: "test-cloudflare-token", TOASTTY_CLOUDFLARE_ACCOUNT_ID: "test-account",
  TOASTTY_APNS_PRIVATE_KEY: privateKey.replaceAll("\n", "\\n"), TOASTTY_APNS_KEY_ID: "TESTKEY001", TOASTTY_APNS_TEAM_ID: "TESTTEAM01",
  UNRELATED_SECRET: "never-forward"
};

test("deploys only the development relay and transfers the signing key through stdin", async () => {
  const calls = [];
  const result = await deployRelay(source, {
    run: async (args, options) => { calls.push({ args, options }); },
    check: async enabled => assert.equal(enabled, true)
  });
  assert.equal(result.enabled, true);
  assert.equal(result.notificationSent, false);
  assert.equal(calls.length, 4);
  for (const { args, options } of calls) {
    assert.equal(args[args.indexOf("--config") + 1], "wrangler.relay.jsonc");
    assert.equal(options.environment.APNS_PRIVATE_KEY, undefined);
    assert.equal(options.environment.TOASTTY_APNS_PRIVATE_KEY, undefined);
    assert.equal(options.environment.UNRELATED_SECRET, undefined);
    assert.equal(JSON.stringify(args).includes(privateKey), false);
  }
  assert.deepEqual(JSON.parse(calls[2].options.input), relaySecrets(source));
  assert.deepEqual(calls[3].args.slice(-2), ["--var", "PUSH_ENABLED:true"]);
});

test("disables and verifies after an uncertain enable deployment without exposing failure details", async () => {
  const calls = [];
  const checks = [];
  await assert.rejects(deployRelay(source, {
    run: async args => { calls.push(args); if (args.includes("PUSH_ENABLED:true")) throw new Error(privateKey); },
    check: async enabled => { checks.push(enabled); }
  }), error => error.message === "Relay deployment failed at enabled deployment. Disabled state verified. No test notification was requested.");
  assert.deepEqual(calls.at(-1), ["deploy", "--config", "wrangler.relay.jsonc"]);
  assert.deepEqual(checks, [false]);
});

test("disable needs no Apple secret and interrupted enable still attempts cleanup", async () => {
  let calls = 0;
  await deployRelay({ TOASTTY_CLOUDFLARE_API_TOKEN: "test", TOASTTY_CLOUDFLARE_ACCOUNT_ID: "test" }, {
    disable: true, run: async () => { calls++; }, check: async enabled => assert.equal(enabled, false)
  });
  assert.equal(calls, 2);
  const signals = new EventEmitter();
  const cleanup = [];
  let originalSignal;
  await assert.rejects(deployRelay(source, {
    signalSource: signals,
    run: async (args, options) => {
      originalSignal ??= options.signal;
      if (args.includes("PUSH_ENABLED:true")) { signals.emit("SIGINT"); options.signal.throwIfAborted(); }
      if (options.signal !== originalSignal) { assert.equal(options.signal.aborted, false); cleanup.push(args); }
    }, check: async () => {}
  }));
  assert.equal(cleanup.length, 1);
  assert.equal(signals.listenerCount("SIGINT"), 0);
});

test("a failed disabled deployment still attempts cleanup in either mode", async () => {
  for (const disable of [false, true]) {
    let calls = 0;
    await assert.rejects(deployRelay(source, {
      disable, report: () => {},
      run: async () => { if (++calls === 2) throw new Error("failed"); },
      check: async enabled => assert.equal(enabled, false)
    }), /Disabled state verified/);
    assert.equal(calls, 3);
  }
});

test("normalizes accepted private key encodings to PKCS8 before upload", () => {
  const { privateKey: sec1 } = generateKeyPairSync("ec", { namedCurve: "prime256v1", privateKeyEncoding: { type: "sec1", format: "pem" }, publicKeyEncoding: { type: "spki", format: "pem" } });
  assert.match(relaySecrets({ ...source, TOASTTY_APNS_PRIVATE_KEY: sec1 }).APNS_PRIVATE_KEY, /^-----BEGIN PRIVATE KEY-----/);
  assert.equal(relaySecrets({ ...source, TOASTTY_APNS_PRIVATE_KEY: privateKey.replaceAll("\n", "\r\n") }).APNS_PRIVATE_KEY, privateKey);
});

test("a second interrupt stops cleanup and reports uncertain disabled state", async () => {
  const signals = new EventEmitter();
  await assert.rejects(deployRelay(source, {
    signalSource: signals, report: () => {},
    run: async (args, options) => {
      if (args.includes("PUSH_ENABLED:true")) { signals.emit("SIGINT"); options.signal.throwIfAborted(); }
    },
    check: async (_enabled, { signal }) => { signals.emit("SIGINT"); signal.throwIfAborted(); }
  }), /disabling could not be verified/);
  assert.equal(signals.listenerCount("SIGINT"), 0);
  assert.equal(signals.listenerCount("SIGTERM"), 0);
});

test("health validates relay identity and retries only read-only checks", async () => {
  let calls = 0;
  await health(true, { pause: async () => {}, fetchRequest: async () => {
    calls++;
    return Response.json({ service: "toastty-push", version: 1, relayID: "toastty-push-dev-v1", apnsEnvironment: "development", enabled: calls > 1 });
  } });
  assert.equal(calls, 2);
  await assert.rejects(health(true, { pause: async () => {}, fetchRequest: async () => Response.json({ enabled: true }) }));
});
