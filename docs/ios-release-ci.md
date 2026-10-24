# iOS Release CI

Toastty's internal iOS alpha path is GitHub Actions -> App Store Connect ->
TestFlight. The `iOS TestFlight` workflow builds the native `ToasttyMobileApp`
target as `com.giantthings.toastty.mobile`, exports an App Store Connect IPA,
validates it, and uploads only when a manual run explicitly requests upload.

This first slice is internal-only. Do not create an external TestFlight group,
public invitation link, reviewer demo mode, or beta App Review submission.

Signed validation and upload now require production notifications. New TestFlight
artifacts are blocked until the production relay, Apple push capability, and
distribution profile are ready. `upload=false` has the same configuration and
signing requirements as `upload=true`. Static `--dry-run` remains secret-free.

## Apple setup

Before the first CI run, create or confirm:

- An active Apple Developer Program membership and accepted agreements for the
  Giant Things team.
- Explicit App ID `com.giantthings.toastty.mobile` with Push Notifications enabled
  in Certificates, Identifiers & Profiles.
- An iOS App Store Connect app record named Toastty using that bundle ID.
- An App Store Connect API key that can validate and upload builds.
- An Apple Distribution certificate exported as a password-protected `.p12`.
- An App Store distribution provisioning profile for
  `com.giantthings.toastty.mobile` using that certificate and containing
  `aps-environment=production`. Regenerate the profile after enabling Push
  Notifications on the App ID.
- An APNs key that can send production notifications for this App ID. Install it
  only in the separate production relay with the correct key ID and team ID.
- An internal TestFlight group scoped to the Toastty app.

The TestFlight app requires iOS 18 or newer. Before signed validation, activate a
separate production relay with `APNS_ENVIRONMENT=production`,
`APNS_TOPIC=com.giantthings.toastty.mobile`, and `PUSH_ENABLED=true`. Its relay ID
must match the iOS release and compatible Mac configuration. Configure the Mac
with the same production relay URL, ID, and APNs environment. Do not reuse the
development relay, its ID, or a sandbox provisioning profile. See
[relay setup](../workers/push/README.md) and [Remote Access](remote-access.md).

The workflow forwards the three production generation inputs below. It checks
their syntax and the signed artifact. It does not deploy the relay, install APNs
keys, or prove that the service can deliver a notification. Those prerequisites
and a real-device delivery check remain separate release requirements.

## Share extension

The app embeds the **Share to Toastty** extension, `ToasttyShare.appex`, with
bundle ID `com.giantthings.toastty.mobile.share`. The app and the extension
share the App Group `group.com.giantthings.toastty.mobile`. Each has its own
App Store distribution profile. Before the first build with the extension:

1. In Certificates, Identifiers & Profiles, register the App Group
   `group.com.giantthings.toastty.mobile`.
2. Enable **App Groups** on the App ID `com.giantthings.toastty.mobile` and
   assign that group. Regenerate the app's App Store distribution profile and
   replace `IOS_APPSTORE_PROVISIONING_PROFILE_BASE64` with it. The profile must
   still include push notifications.
3. Register the explicit App ID `com.giantthings.toastty.mobile.share` with
   **App Groups** enabled and the same group assigned.
4. Create an App Store distribution profile for that App ID with the same
   distribution certificate. Give it a different name from the app's profile.
   Store it base64-encoded as `IOS_APPSTORE_SHARE_EXTENSION_PROVISIONING_PROFILE_BASE64`.

The script stops before it changes the Keychain if either profile has the
wrong bundle ID or lacks the App Group. Generation without a profile for the
extension fails. To build a release without the extension, generate with
`TUIST_TOASTTY_MOBILE_SHARE_EXTENSION=0`.

## GitHub configuration

Create a GitHub Actions Environment named `testflight` and store these
environment secrets in it:

```text
APP_STORE_CONNECT_API_KEY_ID
APP_STORE_CONNECT_API_ISSUER_ID
TOASTTY_IOS_DEVELOPMENT_TEAM
IOS_DISTRIBUTION_CERTIFICATE_BASE64
IOS_DISTRIBUTION_CERTIFICATE_PASSWORD
IOS_APPSTORE_PROVISIONING_PROFILE_BASE64
IOS_APPSTORE_SHARE_EXTENSION_PROVISIONING_PROFILE_BASE64
```

Also add exactly one private-key secret. Prefer the base64 form because it is
unambiguous in GitHub's multiline secret UI:

```text
APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64
```

Alternatively, set `APP_STORE_CONNECT_API_PRIVATE_KEY` to the raw `.p8`
contents. The release script accepts either form and fails if both or neither
are set.

Set these non-secret variables in the same `testflight` environment:

```text
TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_URL
TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_RELAY_ID
TUIST_TOASTTY_MOBILE_PUSH_PRODUCTION_ENVIRONMENT=production
```

The URL must be an HTTPS origin with a host. It must not contain credentials,
query parameters, a fragment, or a path other than `/`. Only port 443 is allowed.
The relay ID must be nonempty and at most 128 UTF-8 bytes. The script rejects
surrounding whitespace, unresolved build settings, `toastty-push-dev-v1`, and the
known development relay URL. It also rejects trailing-dot hosts and the
configured development relay URL or ID. It passes the same values to Tuist
without trimming or replacing them. The names-only `.secrets` manifest declares these inputs
for separately authorized local release work through `sv exec --`.

The App Store Connect key, development team, distribution certificate, and
certificate password can be reused from another Giant Things app when their
permissions and certificate lifetime are appropriate. The provisioning profile
cannot be reused from another app: it must be generated for Toastty's exact
bundle ID.

`IOS_DISTRIBUTION_CERTIFICATE_BASE64` is the base64 encoding of the `.p12` that
contains the distribution certificate and private key.
`IOS_APPSTORE_PROVISIONING_PROFILE_BASE64` is the base64 encoding of Toastty's
App Store `.mobileprovision` file. Do not commit or paste these values into
logs, issues, or chat.

The workflow runs only by manual dispatch. It does not validate or upload on
push. The former `TOASTTY_IOS_TESTFLIGHT_ON_PUSH` variable has no effect.

## First internal build

1. Complete the Apple and production relay prerequisites above. Make sure the
   exact release commit is on `main`. Manually run `Toastty CI` from `main`, wait
   for every job to pass, and confirm its source SHA matches the release commit.
   Complete the disposable-host validation below.
2. In GitHub Actions, open `iOS TestFlight` and run it from `main` with
   `upload=false`.
3. Inspect the retained release metadata and validation log. Confirm the bundle
   ID, version, build number, signing team, production relay URL and ID,
   production push environment, IPA SHA-256, privacy manifest, and encryption
   declaration.
4. Run the workflow again from `main` with `upload=true`.
5. After App Store Connect finishes processing, limit initial distribution to
   the release test device. Check production notification delivery on that real
   device with the compatible Mac configuration. Then assign the build to the
   remaining internal group or enable automatic distribution for that group.
6. Record the git SHA, GitHub Actions run URL, marketing version, build number,
   and compatible Toastty macOS release.

The workflow defaults the marketing version to `0.1.0`. Its build number is
`GITHUB_RUN_NUMBER.GITHUB_RUN_ATTEMPT`, so a rerun does not reuse a rejected
build number. Do not rename or recreate the workflow while that marketing
version is active.

## Companion Mac requirement

The iOS app connects directly to the tester's own Mac. Every tester needs a
signed and notarized Toastty macOS build containing native Remote Access, plus
Tailscale on their own Mac and iPhone using their own tailnet. Never invite an
alpha tester onto another person's tailnet just to test Toastty.

For setup and pairing, follow [Remote Access](remote-access.md). The release
record must state which macOS build is compatible with each TestFlight build.

## Validation performed by the workflow

The release script fails before upload unless it can prove:

- the app and share extension profiles belong to the configured team and their
  exact bundle IDs, and both include the shared App Group;
- both profiles are App Store distribution rather than Development, Ad Hoc, or
  Enterprise, and the app profile enables `aps-environment=production`, before
  the script changes the signing Keychain;
- all three production push inputs are present and valid for both signed
  validation and upload;
- only the app and share extension targets receive provisioning profiles and
  temporary keychain signing flags, each with its own profile;
- the archive contains the expected bundle ID, version, build number, app icon,
  `ITSAppUsesNonExemptEncryption=false`, and privacy manifest, and embeds
  exactly the share extension with the same version and build number;
- the actual exported IPA contains the exact bundle ID, version, build number,
  and three production push settings supplied to generation;
- the exported app has a valid code signature, signed
  `aps-environment=production`, the App Group, the expected app and team
  identifiers, and `get-task-allow=false`;
- the exported share extension has a valid signature, its own application
  identifier, the App Group, and an App Store embedded profile;
- the exported app's embedded profile has the expected app and team identifiers,
  enables production push, and remains App Store distribution;
- the IPA's SHA-256 is unchanged before validation and upload;
- App Store Connect accepts the exported IPA during validation.

Before archiving, the workflow checks GitHub Actions for a successful full manual
`Toastty CI` run on the exact checked-out release SHA. It accepts only
`workflow_dispatch` runs from `main` in `figelwump/toastty`, with workflow ID
`340799440` and path `.github/workflows/mobile-ios.yml`. PR gates and legacy
push runs do not qualify.

The newest trusted manual run must have a successful current attempt. The helper
also requires one successful result for each of `CI gate`, `Script tests`,
`Web panel tests`, `macOS contract tests`, `iOS tests (Debug)`, and
`iOS tests (Release)`, all from that exact source and attempt. These names are maintained in
`.github/ios-release-ci-jobs.json` and checked against the workflow. A failed or pending
newer manual run blocks an older green result. Missing, skipped, cancelled,
abandoned, failed, pending, incomplete, or unavailable evidence blocks archiving
and upload.

Full manual CI retains app/domain correctness tests in both iOS configurations,
the complete Debug UI suite, and the provisional performance budget. Release
excludes the Debug-only UI bundle. PRs run only the selected Linux checks; they
do not establish native coverage. TestFlight does not repeat simulator tests or
download CI build artifacts.

Run full validation explicitly before signed validation or upload:

```bash
gh workflow run mobile-ios.yml --repo figelwump/toastty --ref main
gh run list --repo figelwump/toastty --workflow mobile-ios.yml --branch main --event workflow_dispatch --limit 5
gh run watch <run-id> --repo figelwump/toastty --exit-status
```

These commands dispatch tests on disposable GitHub runners and read their status;
they do not publish an app. Confirm the selected run's SHA is the intended release
commit. Keep `main` unchanged from full CI dispatch through TestFlight dispatch.
If `main` advances, validate the new release source before TestFlight. After a
failed run, dispatch a fresh full run or use **Re-run all jobs**; a partial rerun
is not sufficient when required jobs belong to an older attempt.
Then dispatch `iOS TestFlight` from `main` with the desired `upload` value.

The archive checkout uses the workflow event SHA. The release script verifies
that source still matches the evidence SHA and has no tracked changes, including
after generation. Neither validation-only runs nor uploads can bypass the full
CI evidence. A branch-only commit without trusted main evidence cannot run signed
workflow validation. Environment approval, when configured, still applies to the
archive job.

`ci-evidence.json` records the trusted CI run URL, ID, attempt, source SHA,
workflow, event, result, and required successful job names. It is retained with the release artifacts for 90 days.
This records evidence at gate time; a later CI rerun does not revoke that record.
Simulator logs retain the 14-day policy. No separate release test
artifacts are produced. The secret-free gate, dispatcher, and release-script
suites run on Linux PR CI when these scripts or workflows change.

The workflow retains the signed IPA, compressed Xcode archive (including app
dSYMs), export options, release metadata, and sanitized
generation/archive/export/validation/upload logs for 90 days. Archiving fails if
the app dSYM is missing. Preserve these artifacts elsewhere before expiry if a
build remains supported longer; GitHub retention policy may impose a lower limit.

Release metadata records the actual checked-out source SHA separately from the
CI event SHA, plus the selected Xcode/build version, Swift version, iOS SDK, and
Tuist version. It also records the verified production push settings and IPA
SHA-256. Both full manual iOS CI and the archive job select and verify the
exact Xcode version/build in `.github/ios-xcode-version` before generation.
Node and Tuist continue to use `.node-version` and `.tool-versions`. To update
Xcode, change the shared pin to a build installed on `macos-26`, pass full manual
main CI with that commit, then release that same commit. An unavailable or
mismatched Xcode build fails instead of falling back to the runner default.

The direct local release script remains available for separately authorized
release work. It does not query main CI outside GitHub Actions; it is not a
substitute for the workflow evidence gate.

## Disposable host validation

Before upload, pair a dedicated test client with a disposable, runtime-isolated
Toastty Mac instance containing the compatible host revision. Follow
[Remote Access](remote-access.md) for pairing and the
[dev-run guide](../.agents/skills/toastty-dev-run/SKILL.md) for host isolation.
Use test conversations only. Provision that instance's canonical HTTPS gateway
URL and dedicated client credential through the existing manifest-scoped
`TOASTTY_MOBILE_LIVE_GATEWAY_URL` and `TOASTTY_MOBILE_LIVE_GATEWAY_CREDENTIAL`
inputs; never paste credentials into commands or logs. The wrapper forwards them
over SSH stdin to a temporary broker rather than xcodebuild command arguments.

```bash
sv exec -- scripts/remote/test.sh --platform ios --scope head \
  --live-gateway -- \
  -only-testing:ToasttyMobileDomainTests/LiveGatewayIntegrationTests/testLiveGatewayContractPagingCloseAndReconnect
```

This builds and tests a disposable remote client, reading sessions and transcript
pages and opening/closing sockets on the configured host. It uses an existing
pairing and does not establish pairing UI or interrupted-send coverage. Record a
separate real client check for initial pairing and an interrupted send against
the same disposable host, including preservation of attempted text and uncertain
delivery without automatic retry.

Finally, revoke only the dedicated test client's credential:

```bash
sv exec -- scripts/remote/test.sh --platform ios --scope head \
  --live-gateway \
  --allow-destructive-live-revocation -- \
  -only-testing:ToasttyMobileDomainTests/LiveGatewayIntegrationTests/testDestructiveRevocationClosesSocketAndRejectsCurrentDevice
```

This last command mutates the configured host by durably revoking the supplied
test credential and checks that its socket closes and subsequent authentication
fails. It requires a fresh dedicated pairing for another run. Neither command
creates the host, and neither should target a user's production Mac. Retain the
host/client revisions and remote test artifacts with the release record; report
missing live inputs as unperformed validation.

## Recovery

- Missing-profile or signing failures: regenerate the App Store profile for
  `SP7JP8254U.com.giantthings.toastty.mobile` after enabling Push Notifications,
  confirm `aps-environment=production`, then replace the environment secret.
- Missing or invalid production push inputs: complete production activation and
  set the three `testflight` variables. Validation-only runs cannot bypass this
  requirement.
- Duplicate build number: start a new workflow run; do not retry with a manual
  reused number.
- Processed build is bad: remove it from the internal group or expire it in
  TestFlight, notify testers, fix the source, and upload a new build.
- Tester cannot pair: confirm both devices use the tester's own tailnet, the
  compatible Mac app is running with Remote Access enabled, and the pairing
  offer is still current.
