# iOS Release CI

Toastty's internal iOS alpha path is GitHub Actions -> App Store Connect ->
TestFlight. The `iOS TestFlight` workflow builds the native `ToasttyMobileApp`
target as `com.giantthings.toastty.mobile`, exports an App Store Connect IPA,
validates it, and uploads only when a manual run explicitly requests upload.

This first slice is internal-only. Do not create an external TestFlight group,
public invitation link, reviewer demo mode, or beta App Review submission.

## Apple setup

Before the first CI run, create or confirm:

- An active Apple Developer Program membership and accepted agreements for the
  Giant Things team.
- Explicit App ID `com.giantthings.toastty.mobile` in Certificates,
  Identifiers & Profiles.
- An iOS App Store Connect app record named Toastty using that bundle ID.
- An App Store Connect API key that can validate and upload builds.
- An Apple Distribution certificate exported as a password-protected `.p12`.
- An App Store distribution provisioning profile for
  `com.giantthings.toastty.mobile` using that certificate.
- An internal TestFlight group scoped to the Toastty app.

The TestFlight app requires iOS 18 or newer. The current Release target does not
use a separate extension or Apple capability profile. If a future release adds
push notifications, associated domains, an extension, or another entitlement,
regenerate the App ID configuration and provisioning profile before upload.

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
```

Also add exactly one private-key secret. Prefer the base64 form because it is
unambiguous in GitHub's multiline secret UI:

```text
APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64
```

Alternatively, set `APP_STORE_CONNECT_API_PRIVATE_KEY` to the raw `.p8`
contents. The release script accepts either form and fails if both or neither
are set.

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

Leave `TOASTTY_IOS_TESTFLIGHT_ON_PUSH` unset for the internal alpha. Push events
never upload, but leaving the variable unset also avoids spending a hosted Mac
run on every release-relevant push.

## First internal build

1. Make sure the exact release commit is on `main` and the normal `Toastty CI`
   workflow is green, and complete the disposable-host validation below.
2. In GitHub Actions, open `iOS TestFlight` and run it from `main` with
   `upload=false` and `run_tests=true`.
3. Inspect the retained release metadata and validation log. Confirm the bundle
   ID, version, build number, signing team, privacy manifest, and encryption
   declaration.
4. Run the workflow again from `main` with `upload=true` and `run_tests=true`.
5. After App Store Connect finishes processing, assign the build to the
   internal group or enable automatic distribution for that group.
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

- the provisioning profile belongs to the configured team and exact production
  bundle ID;
- the profile is App Store distribution rather than Development, Ad Hoc, or
  Enterprise;
- only the app target receives the provisioning profile and temporary keychain
  signing flags;
- the archive contains the expected bundle ID, version, build number, app icon,
  `ITSAppUsesNonExemptEncryption=false`, and privacy manifest;
- App Store Connect accepts the exported IPA during validation.

Before archiving, the workflow runs Debug tests and focused Release app/domain
tests. Release tests enable internal test imports while preserving Release
compilation branches; Debug-only fixture UI launches are excluded. Upload
requests always run both tiers even if `run_tests` is false. The ordinary PR
workflow also runs both configurations and the secret-free release-script suite,
including when the release workflow or script changes.

The workflow retains the signed IPA, compressed Xcode archive (including app
dSYMs), export options, release metadata, and sanitized
generation/archive/export/validation/upload logs for 90 days. Archiving fails if
the app dSYM is missing. Preserve these artifacts elsewhere before expiry if a
build remains supported longer; GitHub retention policy may impose a lower limit.

Release metadata records the actual checked-out source SHA separately from the
CI event SHA, plus the selected Xcode/build version, Swift version, iOS SDK, and
Tuist version. Hosted runners currently supply the selected Xcode toolchain; this
records its identity but does not pin a specific Xcode version. Check these values
when comparing builds or investigating a runner-image change.

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
  --run-label ios-release-live --live-gateway -- \
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
  --run-label ios-release-revoke --live-gateway \
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
  `SP7JP8254U.com.giantthings.toastty.mobile`, then replace the environment
  secret.
- Duplicate build number: start a new workflow run; do not retry with a manual
  reused number.
- Processed build is bad: remove it from the internal group or expire it in
  TestFlight, notify testers, fix the source, and upload a new build.
- Tester cannot pair: confirm both devices use the tester's own tailnet, the
  compatible Mac app is running with Remote Access enabled, and the pairing
  offer is still current.
