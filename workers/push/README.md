# iPhone notification relay and development probe

This Worker tests the path from Cloudflare through APNs sandbox to the opt-in
Toastty development receiver on an iPhone. Its default mode sends a fixed request
without Apple credentials to an invalid device token. An Apple error response
proves transport connectivity only. `--send` sends one fixed alert to the
configured development phone. Neither mode proves delivery without a phone check.

The paired-device relay uses `wrangler.relay.jsonc` and a separate Worker,
`toastty-push-dev`. Unconfigured app builds do not expose notifications.
The operator probe remains separate from automatic enrollment.

## Local checks

From the repository root:

```sh
npm ci --prefix workers/push --no-audit --no-fund
npm --prefix workers/push run check
```

These commands install dependencies and run tests in a disposable local Workers
runtime. The tests mock Apple responses. They do not deploy or contact APNs.
The runtime requires permission to bind a local loopback socket.

## Paired-device development relay

The iPhone verifies delivery automatically after notification permission is
allowed. It then gives the paired Mac a credential that can send session alerts
and revoke itself. The phone retains a separate management credential.
The relay holds credential hashes and the APNs device token in one SQLite
Durable Object. It keeps the APNs signing key in a Cloudflare secret and reuses a
cached provider token. Unlike the operator probe below, this service must retain
the signing key so it can send alerts without an operator command.

After local checks and code review, run from the repository root:

```sh
sv exec --key TOASTTY_CLOUDFLARE_API_TOKEN --key TOASTTY_CLOUDFLARE_ACCOUNT_ID \
  --key TOASTTY_APNS_PRIVATE_KEY --key TOASTTY_APNS_KEY_ID \
  --key TOASTTY_APNS_TEAM_ID -- node workers/push/scripts/relay.mjs
```

This mutates only `toastty-push-dev` in the configured Cloudflare account. It
validates the bundle, deploys disabled, uploads the three signing secrets through
stdin, enables the development relay, then checks its fixed `/health` endpoint.
It sends no notification. The account must own `giantthings.workers.dev`. The
script forwards only Cloudflare credentials to Wrangler and suppresses CLI output
that could contain submitted values. If enabling or its health check fails, it
attempts to disable the service and reports if that cannot be verified.

To stop delivery without deleting stored enrollment or signing secrets:

```sh
sv exec --key TOASTTY_CLOUDFLARE_API_TOKEN --key TOASTTY_CLOUDFLARE_ACCOUNT_ID \
  -- node workers/push/scripts/relay.mjs --disable
```

The source config is disabled by default. A plain `wrangler deploy --config
wrangler.relay.jsonc` disables the relay. Use the script for an enabled development
deploy. Run it from a checkout that passes the bundle check; `--disable` also
deploys the current source. Do not run concurrent relay deployments from multiple
terminals or worktrees. Observability and Logpush are disabled. Do not log bodies, authorization
headers, device tokens, nonces, or session titles. Deployment history can retain
prior encrypted secret versions.

Configure the companion Mac graph before generating and building it:

```sh
TUIST_TOASTTY_PUSH_RELAY_URL=https://toastty-push-dev.giantthings.workers.dev \
TUIST_TOASTTY_PUSH_RELAY_ID=toastty-push-dev-v1 \
TUIST_TOASTTY_PUSH_APNS_ENVIRONMENT=development \
  sv exec -- tuist generate --no-open
```

This mutates only the current worktree's generated macOS project. Follow the
[dev-run guide](../../.agents/skills/toastty-dev-run/SKILL.md) to build and run an
isolated host. Enable Remote Access on that host and pair the development phone.
The configuration is compiled into the app; setting variables only at launch is
not sufficient.

For the physical iPhone, set `TOASTTY_IOS_DEVELOPMENT_TEAM` as described below:

```sh
TUIST_TOASTTY_MOBILE_PUSH_RELAY_URL=https://toastty-push-dev.giantthings.workers.dev \
TUIST_TOASTTY_MOBILE_PUSH_ENVIRONMENT=development \
  node ios/scripts/toastty-ios.mjs native-device --build-only
```

This builds and checks a signed Debug app with the fixed development identity.
Remove `--build-only` to install and launch it, replacing Toastty Dev on the selected
phone. Normal enrollment requires a reachable, paired Mac with matching relay ID
and APNs environment. Keep the app open for the first automatic verification.
After Allow, Home remains usable. A later foreground resumes interrupted setup;
a setup failure shows a small Retry message. A verification alert already in
flight can appear if the phone moves to the background.

Validate automatic enrollment, an actual session event, locked-phone delivery,
alert tap routing, Off, and unpairing before release. Local Worker tests use
mocked APNs; a green test suite does not prove physical delivery. The protocol and
failure cases are recorded in [the implementation plan](../../docs/plans/ios-push-notifications.md).

Production activation is separate. It needs its own Worker, Durable Object,
production APNs key/topic, explicit Mac configuration, and explicitly configured
iOS Release build and provisioning profile. This repository does not provide an
operator command that deploys production. Deploy compatible relay changes before
clients that add request fields, because v1 rejects unknown JSON fields.

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

The installed `sv` 0.2.0 reads only one input line. Import the private key with
escaped newlines so it stores the complete file. Replace the example filename
with the downloaded key's filename and run this in your terminal:

```sh
python3 -I -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).read_text().replace("\n", r"\n"))' \
  "$HOME/Downloads/AuthKey_YOUR_KEY_ID.p8" | sv set TOASTTY_APNS_PRIVATE_KEY
```

The sender accepts both normal multiline PEM and this single-line form. The
command sends key contents directly to the vault; it does not print them.
Running `sv set TOASTTY_APNS_PRIVATE_KEY < file.p8` with `sv` 0.2.0 stores only
the first line and produces an invalid key. Store the two IDs with the normal
interactive `sv set TOASTTY_APNS_KEY_ID` and `sv set TOASTTY_APNS_TEAM_ID` prompts.

Connect the development iPhone. Set `TOASTTY_IOS_DEVELOPMENT_TEAM` to your Apple
team ID; the physical-device dispatcher requires it explicitly. From the
repository root, the following command
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

The paired-device feature sends the session title plus Ready or Needs approval.
There is no title-hiding preference. Production deployment and activation need
separate authorization.
