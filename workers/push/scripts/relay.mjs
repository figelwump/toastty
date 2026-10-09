import { createPrivateKey } from "node:crypto";
import { pathToFileURL } from "node:url";
import { setTimeout as delay } from "node:timers/promises";
import { runWrangler, wranglerEnvironment } from "./probe.mjs";

const config = "wrangler.relay.jsonc";
const baseURL = "https://toastty-push-dev.giantthings.workers.dev";

export function relaySecrets(source) {
  for (const name of ["TOASTTY_APNS_PRIVATE_KEY", "TOASTTY_APNS_KEY_ID", "TOASTTY_APNS_TEAM_ID"]) {
    if (!source[name]) throw new Error(`Required vault key: ${name}.`);
  }
  const keyID = source.TOASTTY_APNS_KEY_ID.trim();
  const teamID = source.TOASTTY_APNS_TEAM_ID.trim();
  if (!/^[A-Z0-9]{10}$/.test(keyID) || !/^[A-Z0-9]{10}$/.test(teamID)) throw new Error("Invalid APNs key ID or team ID.");
  const pem = source.TOASTTY_APNS_PRIVATE_KEY.replaceAll("\\n", "\n");
  let key;
  try { key = createPrivateKey(pem); }
  catch { throw new Error("APNs private key must contain the PEM .p8 file contents."); }
  if (key.asymmetricKeyType !== "ec" || key.asymmetricKeyDetails?.namedCurve !== "prime256v1") throw new Error("APNs key must be ES256 P-256.");
  return { APNS_PRIVATE_KEY: key.export({ type: "pkcs8", format: "pem" }), APNS_KEY_ID: keyID, APNS_TEAM_ID: teamID };
}

export async function health(enabled, { fetchRequest = fetch, pause = delay, signal } = {}) {
  for (let attempt = 0; attempt < 6; attempt++) {
    let body;
    try {
      const response = await fetchRequest(`${baseURL}/health`, {
        redirect: "error", signal: AbortSignal.any([AbortSignal.timeout(10_000), ...(signal ? [signal] : [])])
      });
      if (response.ok) body = await response.json();
      else await response.body?.cancel().catch(() => {});
    } catch { signal?.throwIfAborted(); }
    if (body?.service === "toastty-push" && body.version === 1 && body.relayID === "toastty-push-dev-v1" &&
        body.apnsEnvironment === "development" && body.enabled === enabled) return;
    if (attempt < 5) await pause(2000, undefined, { signal });
  }
  throw new Error("Development relay health check failed.");
}

export async function deployRelay(source, { disable = false, run = runWrangler, check = health, signalSource = process, report = message => console.error(message) } = {}) {
  const environment = wranglerEnvironment(source);
  if (!environment.CLOUDFLARE_API_TOKEN || !environment.CLOUDFLARE_ACCOUNT_ID) throw new Error("Required vault keys: TOASTTY_CLOUDFLARE_API_TOKEN and TOASTTY_CLOUDFLARE_ACCOUNT_ID.");
  const secrets = disable ? undefined : relaySecrets(source);
  const controller = new AbortController();
  const cleanupController = new AbortController();
  const interrupt = () => {
    if (controller.signal.aborted) {
      report("Cleanup interrupted. Run relay.mjs --disable before testing.");
      cleanupController.abort();
    } else {
      report("Interrupted. Checking that the development relay is disabled; a second interrupt stops cleanup.");
      controller.abort();
    }
  };
  signalSource.on("SIGINT", interrupt);
  signalSource.on("SIGTERM", interrupt);
  let mutationAttempted = false;
  let step = "bundle validation";
  try {
    const options = { environment, signal: controller.signal };
    await run(["deploy", "--config", config, "--dry-run"], options);
    mutationAttempted = true;
    step = "disabled deployment";
    await run(["deploy", "--config", config], options); // Source config defaults to disabled.
    if (!disable) {
      step = "signing-secret upload";
      await run(["secret", "bulk", "--config", config], { ...options, input: JSON.stringify(secrets) });
      controller.signal.throwIfAborted();
      step = "enabled deployment";
      await run(["deploy", "--config", config, "--var", "PUSH_ENABLED:true"], options);
    }
    step = "health check";
    await check(!disable, { signal: controller.signal });
    return { worker: baseURL, enabled: !disable, notificationSent: false };
  } catch {
    if (mutationAttempted) {
      report(`Failed at ${step}. Disabling the development relay.`);
      try {
        await run(["deploy", "--config", config], { environment, signal: cleanupController.signal });
        await check(false, { signal: cleanupController.signal });
      } catch { throw new Error("Relay deployment failed; disabling could not be verified. Run relay.mjs --disable before testing."); }
      throw new Error(`Relay deployment failed at ${step}. Disabled state verified. No test notification was requested.`);
    }
    throw new Error("Relay bundle validation failed. No changes made; an existing enabled relay can still be running.");
  } finally {
    signalSource.off("SIGINT", interrupt);
    signalSource.off("SIGTERM", interrupt);
  }
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  const args = process.argv.slice(2);
  if (args.length && !(args.length === 1 && args[0] === "--disable")) {
    console.error("Run without arguments to deploy the development relay, or --disable to stop delivery.");
    process.exitCode = 1;
  } else {
    deployRelay(process.env, { disable: args[0] === "--disable" })
      .then(result => console.log(JSON.stringify(result, null, 2)))
      .catch(error => { console.error(error.message); process.exitCode = 1; });
  }
}
