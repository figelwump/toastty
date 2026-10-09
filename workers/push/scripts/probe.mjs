import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { fileURLToPath, pathToFileURL } from "node:url";
import { setTimeout as delay } from "node:timers/promises";
import { signingConfiguration } from "./sign.mjs";

const workerRoot = fileURLToPath(new URL("../", import.meta.url));
const wranglerPath = fileURLToPath(new URL("../node_modules/wrangler/bin/wrangler.js", import.meta.url));
const baseURL = "https://toastty-push-probe-dev.giantthings.workers.dev";

// Forward only the credentials this tool needs. Other vault entries must not reach Wrangler.
export function wranglerEnvironment(source) {
  const result = { WRANGLER_SEND_METRICS: "false", WRANGLER_LOG_SANITIZE: "true" };
  for (const name of ["PATH", "HOME", "TMPDIR", "SYSTEMROOT"]) {
    if (source[name]) result[name] = source[name];
  }
  result.CLOUDFLARE_API_TOKEN = source.TOASTTY_CLOUDFLARE_API_TOKEN;
  result.CLOUDFLARE_ACCOUNT_ID = source.TOASTTY_CLOUDFLARE_ACCOUNT_ID;
  return result;
}

export async function runWrangler(args, { input, environment, signal, spawnProcess = spawn, timeoutMs = 120_000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawnProcess(process.execPath, [wranglerPath, ...args], {
      cwd: workerRoot, env: environment, stdio: ["pipe", "pipe", "pipe"],
      signal: AbortSignal.any([AbortSignal.timeout(timeoutMs), ...(signal ? [signal] : [])])
    });
    // Do not forward CLI output: an upstream failure can include submitted values.
    child.stdout.resume();
    child.stderr.resume();
    child.stdin.on("error", () => {});
    child.on("error", () => reject(new Error("Wrangler could not start or was interrupted (120-second limit).")));
    child.on("close", (code) => code === 0 ? resolve() : reject(new Error(`Wrangler ${args[0]} failed (exit ${code}).`)));
    child.stdin.end(input);
  });
}

export async function probe(auth, { fetchRequest = fetch, pause = delay, isSend = false, signal } = {}) {
  const errors = new Set(["probe_disabled", "unauthorized", "empty_request_required",
    "sender_not_configured", "apns_timeout", "apns_transport_failed", "unrecognized_apns_response"]);
  const reasons = new Set(["MissingProviderToken", "BadDeviceToken", "BadTopic", "TopicDisallowed",
    "DeviceTokenNotForTopic", "Unregistered", "ExpiredProviderToken", "InvalidProviderToken",
    "TooManyProviderTokenUpdates", "TooManyRequests", "Forbidden", "MissingTopic", "PayloadTooLarge",
    "BadPriority", "BadExpirationDate", "InternalServerError", "ServiceUnavailable", "Shutdown"]);
  for (let attempt = 0; attempt < 6; attempt++) {
    const route = isSend ? "test-notification" : "transport-probe";
    let response;
    try {
      response = await fetchRequest(`${baseURL}/v1/${route}`, {
        method: "POST", headers: { authorization: `Bearer ${auth}` },
        redirect: "error", signal: AbortSignal.any([AbortSignal.timeout(20_000), ...(signal ? [signal] : [])])
      });
    } catch {
      throw new Error(isSend ? "Send interrupted. Delivery is unverified; no retry was attempted. Check the phone before another send."
        : "Transport probe interrupted. No notification was sent.");
    }
    const body = await response.json().catch(() => null);
    // Secret updates may take a short time to reach the serving edge.
    if (attempt < 5 && ((!isSend && body === null) || (response.status === 503 && body?.error === "probe_disabled") ||
        (response.status === 401 && body?.error === "unauthorized"))) {
      await pause(5000, undefined, { signal });
      continue;
    }
    if (isSend && body?.apnsAccepted === false && reasons.has(body.apnsReason)) {
      throw new Error(`APNs rejected the notification: ${body.apnsReason}. No retry was attempted.`);
    }
    const expectedResult = isSend ? body?.apnsAccepted === true && body?.deliveryVerified === false
      : body?.transportReachable === true && body?.notificationDelivered === false;
    if (!response.ok || !expectedResult) {
      const error = errors.has(body?.error) ? body.error : "unexpected_response";
      throw new Error(`APNs ${isSend ? "send" : "transport probe"} failed: ${error} (HTTP ${response.status}). ${isSend ? "Delivery is unverified; no retry was attempted." : "No notification was sent."}`);
    }
    if ((isSend ? body.apnsStatus !== 200 : !reasons.has(body.apnsReason) || ![400, 403].includes(body.apnsStatus)) ||
        !(isSend && body.apnsID === null) && !/^[0-9a-f-]{36}$/i.test(body.apnsID)) throw new Error("Unexpected probe response.");
    if (isSend) return { worker: baseURL, apnsAccepted: true, deliveryVerified: false,
      apnsStatus: 200, apnsID: body.apnsID };
    return { worker: baseURL, transportReachable: true, notificationDelivered: false,
      apnsStatus: body.apnsStatus, apnsReason: body.apnsReason, apnsID: body.apnsID };
  }
}

export async function withProbeCredential(environment, action, { run = runWrangler, appleSecrets = {}, signalSource = process } = {}) {
  const auth = randomBytes(32).toString("hex");
  const expiresAt = Date.now() + 600_000;
  const controller = new AbortController();
  const interrupt = () => controller.abort();
  signalSource.on("SIGINT", interrupt);
  signalSource.on("SIGTERM", interrupt);
  const uploaded = { APNS_PROVIDER_TOKEN: "", APNS_DEVICE_TOKEN: "", ...appleSecrets,
    PUSH_PROBE_AUTH: auth, PUSH_PROBE_EXPIRES_AT: String(expiresAt) };
  const cleared = Object.fromEntries(Object.keys(uploaded).map((key) => [key, ""]));
  cleared.PUSH_PROBE_AUTH = randomBytes(32).toString("hex");
  cleared.PUSH_PROBE_EXPIRES_AT = "0";
  let result;
  let failure;
  let cleanupError;
  try {
    await run(["secret", "bulk"], {
      environment, signal: controller.signal, input: JSON.stringify(uploaded)
    });
    controller.signal.throwIfAborted();
    result = await action(auth, controller.signal);
  } catch (error) {
    failure = error;
  } finally {
    try {
      // Cleanup has its own timeout and must run even after Ctrl-C.
      await run(["secret", "bulk"], { environment, input: JSON.stringify(cleared) });
    } catch {
      cleanupError = `Probe cleanup failed. Endpoint access expires at ${new Date(expiresAt).toISOString()}; JWT and device token may remain stored. Rerun without --send to clear them. Do not repeat the send.`;
    } finally {
      signalSource.off("SIGINT", interrupt);
      signalSource.off("SIGTERM", interrupt);
    }
  }
  if (failure) throw new Error([failure instanceof Error ? failure.message : "Probe interrupted.", cleanupError].filter(Boolean).join("\n"));
  return { result, cleanupError };
}

async function main() {
  const args = process.argv.slice(2);
  const isSend = args.length === 1 && args[0] === "--send";
  if (args.length && !isSend) throw new Error("Run without arguments for transport, or --send for one sandbox notification.");
  const environment = wranglerEnvironment(process.env);
  if (!environment.CLOUDFLARE_API_TOKEN || !environment.CLOUDFLARE_ACCOUNT_ID) {
    throw new Error("Required vault keys: TOASTTY_CLOUDFLARE_API_TOKEN and TOASTTY_CLOUDFLARE_ACCOUNT_ID.");
  }
  const appleSecrets = isSend ? signingConfiguration(process.env) : {};
  console.log("Validating then deploying toastty-push-probe-dev (development only).");
  await runWrangler(["deploy", "--dry-run"], { environment });
  await runWrangler(["deploy"], { environment });
  const { result, cleanupError } = await withProbeCredential(environment,
    (auth, signal) => probe(auth, { isSend, signal }), { appleSecrets });
  console.log(JSON.stringify(result, null, 2));
  if (cleanupError) { console.error(cleanupError); process.exitCode = 1; }
  else console.log("Probe disabled.");
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch((error) => { console.error(error.message); process.exitCode = 1; });
}
