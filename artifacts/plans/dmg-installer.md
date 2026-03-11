# Toastty First-Release DMG Plan

## Goal

Ship a manually-invoked release pipeline that produces a signed, notarized DMG with a plain drag-to-install flow.

This plan is intentionally narrow:
- one release script
- local-first execution, CI-friendly later
- minimal entitlements
- no Sparkle yet
- no DMG polish work unless the plain installer is already solid

---

## Non-Goals

Do not include these in the first DMG pass:
- Sparkle or appcast generation
- multiple release scripts
- custom Finder window layout via AppleScript
- background images or custom volume icons
- broad privacy entitlements
- release-channel logic

---

## Implementation Order

### 1. Add release versioning, generated Info.plist keys, and distribution signing to `Project.swift`

Keep the current development-signing and ad-hoc behavior, and add a third path for distribution signing.

Use env vars evaluated at `tuist generate` time:

```swift
let marketingVersion = ProcessInfo.processInfo.environment["TOASTTY_VERSION"] ?? "0.1.0"
let buildNumber = ProcessInfo.processInfo.environment["TOASTTY_BUILD_NUMBER"] ?? "1"
let distributionSigning = ProcessInfo.processInfo.environment["TUIST_DISTRIBUTION_SIGNING"] == "1"
```

Add to the app target settings:

```swift
"MARKETING_VERSION": SettingValue(stringLiteral: marketingVersion),
"CURRENT_PROJECT_VERSION": SettingValue(stringLiteral: buildNumber),
"ENABLE_HARDENED_RUNTIME": "YES",
```

Update the app target to use:

```swift
infoPlist: .extendingDefault(with: [
    "CFBundleShortVersionString": .string("$(MARKETING_VERSION)"),
    "CFBundleVersion": .string("$(CURRENT_PROJECT_VERSION)"),
])
```

Signing behavior:
- `TUIST_DISTRIBUTION_SIGNING=1` + `TUIST_DEVELOPMENT_TEAM` set:
  - `CODE_SIGN_IDENTITY = Developer ID Application`
  - `CODE_SIGN_STYLE = Manual`
  - `DEVELOPMENT_TEAM = ...`
- otherwise preserve the current Apple Development / ad-hoc behavior

Why:
- version metadata needs to be present in the shipped app now
- the same version fields will be reused later by Sparkle
- hardened runtime is required for notarized Developer ID distribution

Also document in the manifest comments that `TUIST_DISTRIBUTION_SIGNING` is a repo-local env toggle consumed by `Project.swift`, not a Tuist built-in.

**Files:** `Project.swift`

---

### 2. Add a minimal entitlements file

Create `Sources/App/Toastty.entitlements` and wire it into the app target in `Project.swift`.

Start with the minimum set only:

```xml
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
```

Notes:
- This entitlement exists only because the app embeds or links externally-built Ghostty artifacts. If local validation shows it is unnecessary, remove it.
- Do not add camera, microphone, contacts, calendars, photos, location, or Apple Events entitlements as part of this plan.
- Hardened runtime is controlled by build settings, not by adding a large entitlement list.

**Files:** `Sources/App/Toastty.entitlements`, `Project.swift`

---

### 3. Create one release script

Add a single script at:

`scripts/release/release.sh`

The script owns the entire first-release pipeline:

1. validate required env vars and required local tools
2. confirm a Ghostty xcframework is available in `Dependencies/`
3. confirm the selected Ghostty artifact has the expected macOS architecture slice for the current release build
4. run `tuist generate` with release version and distribution-signing env vars
5. archive the app with `xcodebuild archive`
6. export the app with `xcodebuild -exportArchive`
7. fail fast if distribution signing inputs are incomplete rather than falling back to ad-hoc signing
8. verify codesigning on the exported `.app`
9. notarize the `.app`
10. staple the `.app` before creating the DMG
11. build a plain DMG with:
   - `Toastty.app`
   - `/Applications` symlink
12. sign the DMG with `codesign`
13. notarize the DMG
14. run final verification checks

Keep the script shell-only and dependency-light:
- use `hdiutil`
- use `xcrun notarytool`
- generate `ExportOptions.plist` inline
- do not depend on Homebrew packages for v1

Recommended env vars:

| Var | Required | Purpose |
|---|---|---|
| `TOASTTY_VERSION` | Yes | `CFBundleShortVersionString`, e.g. `0.1.0` |
| `TOASTTY_BUILD_NUMBER` | Yes | `CFBundleVersion`, monotonically increasing integer |
| `TUIST_DEVELOPMENT_TEAM` | Yes | Apple Developer Team ID |
| `TOASTTY_APPLE_ID` | Yes | Apple ID used for notarization |
| `TOASTTY_NOTARY_PASSWORD` | Yes | app-specific password or notary credential secret |
| `TOASTTY_TEAM_ID` | Yes | Apple team ID for notarization |

Why one script:
- avoids splitting the release pipeline across overlapping docs and commands
- gives Sparkle a single place to extend later
- makes CI adoption straightforward when you add it

**Files:** `scripts/release/release.sh`

---

### 4. Keep the DMG plain

For the first release, the mounted DMG only needs:
- `Toastty.app`
- `Applications` symlink

Skip:
- Finder AppleScript positioning
- custom backgrounds
- custom icons

Those are polish items, not release blockers.

**Files:** none beyond `scripts/release/release.sh`

---

## File Changes

### Modified

- `Project.swift`

### New

- `Sources/App/Toastty.entitlements`
- `scripts/release/release.sh`

---

## Suggested Script Structure

```text
scripts/
  release/
    release.sh
```

The script should write all build outputs into a gitignored artifacts directory, for example:

```text
artifacts/
  release/
    Toastty.app
    Toastty-0.1.0.dmg
    export-options.plist
    notarization/
```

---

## Validation

### Automated checks

Run these from the script:
- `codesign --verify --deep --strict <Toastty.app>`
- `spctl --assess --verbose=4 --type execute <Toastty.app>`
- `xcrun stapler validate <Toastty.app>`
- `codesign --verify --strict <Toastty.dmg>`
- `spctl --assess --verbose=4 --type open <Toastty.dmg>`

### Manual QA

1. Mount the DMG and confirm the app and `/Applications` alias are present.
2. Drag the app into `/Applications`.
3. Launch the installed app from `/Applications` and confirm Gatekeeper does not block it.
4. Launch the same app copy from a non-standard path such as `~/Downloads` to catch path-randomization or missing-staple issues.
5. Open About Toastty and verify the app version matches `TOASTTY_VERSION`.
6. Run the app on a different user account or clean machine if available.
7. Exercise the Ghostty-backed terminal path, since distribution signing and hardened runtime are the highest-risk changes.

### Existing repo validation

After any implementation work for this plan:
- `tuist generate`
- `ARCH="$(uname -m)"; xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug -destination "platform=macOS,arch=${ARCH}" -derivedDataPath Derived build`
- `./scripts/automation/check.sh`

If the release build changes any runtime behavior, also run:
- `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh`
- `./scripts/automation/smoke-ui.sh`

---

## Prerequisites

- Apple Developer Program membership
- Developer ID Application certificate installed locally
- notarization credentials available through `sv exec -- ...`
- a decided build-number policy:
  - local manual release: explicit integer passed in
  - later CI release: CI run number or another monotonic integer

---

## Follow-Up After This Plan

Once the DMG flow is real and repeatable, the next release step is Sparkle:
- add Sparkle as a dependency
- add a real feed URL and EdDSA public key
- extend the same `scripts/release/release.sh`
- add `Check for Updates…`

That follow-up is captured in `artifacts/plans/sparkle-auto-update.md`.
