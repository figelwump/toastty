# APNs development delivery test

This Worker tests the path from Cloudflare through APNs sandbox to the opt-in
Toastty development receiver on an iPhone. Its default mode sends a fixed request
without Apple credentials to an invalid device token. An Apple error response
proves transport connectivity only. `--send` sends one fixed alert to the
configured development phone. Neither mode proves delivery without a phone check.

There is no production sender or paired-device enrollment. Normal app builds do
not include the development receiver or its push entitlement.

## Local checks

From the repository root:

```sh
npm ci --prefix workers/push --no-audit --no-fund
npm --prefix workers/push run check
```

These commands install dependencies and run tests in a disposable local Workers
runtime. The tests mock Apple responses. They do not deploy or contact APNs.
The runtime requires permission to bind a local loopback socket.

## Deployed development probe

The command below mutates only the development Worker
`toastty-push-probe-dev` in the configured Cloudflare account. It deploys the
Worker, uploads short-lived probe credentials, invokes the probe once, then
disables it. It does not change the diagnostics Worker, a production domain,
or an Apple App ID. The configured account must own the `giantthings.workers.dev`
subdomain.

The vault must contain `TOASTTY_CLOUDFLARE_API_TOKEN` and
`TOASTTY_CLOUDFLARE_ACCOUNT_ID`. The token needs permission to deploy Workers
and update their secrets in that account. Do not paste credentials into commands,
source files, or reports.

```sh
sv exec --key TOASTTY_CLOUDFLARE_API_TOKEN --key TOASTTY_CLOUDFLARE_ACCOUNT_ID -- node workers/push/scripts/probe.mjs
```

The script validates the bundle with `wrangler deploy --dry-run` before deployment.
It sends probe credentials to `wrangler secret bulk` through standard input.
Only Cloudflare credentials and basic process settings reach Wrangler. Probe
credentials never appear in command arguments or output. Wrangler log sanitization
is enabled. Worker observability and Logpush are disabled.

The script prints an allowlisted Apple error reason, status, and APNs request ID.
`transportReachable: true` and `notificationDelivered: false` are the expected
result. The probe always uses `api.sandbox.push.apple.com` and
`com.giantthings.toastty.mobile.dev`; callers cannot supply a destination or content.
Unexpected Apple responses fail the check rather than being treated as success.

The endpoint fails closed before configuration and after cleanup. If the process
is interrupted, the credential expires ten minutes after it was created. A rerun
replaces it. Do not run concurrent probes against the same Worker. The local
clock must be accurate because it sets the expiry and signs provider tokens.

## Prepare the iPhone receiver

Enable Push Notifications for `com.giantthings.toastty.mobile.dev` in the Apple
developer account. Create an [APNs signing key](https://developer.apple.com/help/account/keys/create-a-private-key/)
restricted to **Sandbox** and this topic. An App Store Connect key does not
replace an APNs key. Store the key's PEM `.p8` contents in the secure vault as
`TOASTTY_APNS_PRIVATE_KEY`, its key ID as `TOASTTY_APNS_KEY_ID`, and the Apple
team ID as `TOASTTY_APNS_TEAM_ID`. Never paste values into chat or repository files.

Connect the development iPhone. From the repository root, the following command
builds and validates a signed Debug receiver. It may update Apple's development
provisioning profile. It does not install or launch the app:

```sh
TUIST_TOASTTY_MOBILE_PUSH_PROBE=1 node ios/scripts/toastty-ios.mjs native-device --build-only
```

Remove `--build-only` to build, install, and launch. This **replaces the normal
Toastty Dev app on the selected phone**. Use `--device <identifier>` when more
than one phone is connected. The dispatcher validates `aps-environment=development`
in both the provisioning profile and signed app. It rejects Release, prod-test,
and custom bundle identities. The generated Release configuration excludes the
receiver and entitlement even when the Debug probe flag was enabled at generation.

In the receiver, select **Request permission and register**. Then select
**Copy APNs token** and store it as `TOASTTY_APNS_DEVICE_TOKEN` in the vault.
The token stays in app memory. The clipboard copy expires after two minutes and
supports Universal Clipboard to your Mac when Handoff is enabled. Register again
after each app launch; the token can change after reinstall.

## Send and verify

Run from the repository root with the receiver ready:

```sh
sv exec --key TOASTTY_CLOUDFLARE_API_TOKEN --key TOASTTY_CLOUDFLARE_ACCOUNT_ID \
  --key TOASTTY_APNS_PRIVATE_KEY --key TOASTTY_APNS_KEY_ID \
  --key TOASTTY_APNS_TEAM_ID --key TOASTTY_APNS_DEVICE_TOKEN \
  -- node workers/push/scripts/probe.mjs --send
```

This command deploys the development Worker and sends one sandbox alert. It signs
a provider JWT locally. The private key never reaches Cloudflare. The short-lived
JWT and phone token go to Worker secrets through standard input and are cleared
after the attempt. Ctrl-C and termination signals trigger a cleanup attempt.
Each Wrangler invocation has a two-minute deadline. If cleanup cannot complete,
the endpoint is disabled after its ten-minute credential expiry; rerun **without
`--send`** to clear stored test credentials sooner. Do not repeat an uncertain send.
Cloudflare may retain prior encrypted secret versions. No request values are logged.

The alert title is **Toastty push test**. APNs can retain it for up to five minutes
if the phone is briefly offline. A fixed collapse ID prevents queued test alerts
from accumulating. The script retries only responses that show the Worker rejected
authorization before contacting Apple. It never retries a send with an ambiguous
result or an APNs rejection.

Wait at least 20 minutes between signed runs. Each run creates a new provider JWT;
[Apple limits how often provider tokens change](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns).
`TooManyProviderTokenUpdates` is a failure, not a reason for automatic retries.

`apnsAccepted: true` means Apple accepted the request. `deliveryVerified: false`
remains in the command output because the script cannot observe the phone. Verify:

1. Foreground: a banner appears and the receiver's count increases.
2. Background: with another app open, the notification appears.
3. Locked: the notification appears on the lock screen, subject to the phone's
   notification and Focus settings.

Record the APNs request ID and observed phone result without recording its token.
To restore the normal development app, run `native-device` without the probe flag.

Only after real delivery is verified should work continue on the paired-device
feature: session title plus short status by default, with an option to hide titles.
Production deployment and activation need separate authorization.
