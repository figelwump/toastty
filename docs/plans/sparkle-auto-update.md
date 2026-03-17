# Toastty Sparkle Follow-Up Plan

## Goal

Add Sparkle after the DMG release pipeline is already working.

This remains a follow-up release plan, not part of the first DMG ship. It must
fit Toastty's existing two-phase release workflow instead of collapsing it back
into one script:

- build and provenance capture: `scripts/release/release.sh`
- later publication: `scripts/release/publish-github-release.sh`

The operator workflow for those phases is already encoded in:

- `.agents/skills/toastty-release/SKILL.md`
- `.agents/skills/toastty-publish/SKILL.md`

Target shape:

- one stable update feed
- Sparkle standard UI
- one menu item: `Check for Updates...`
- no custom update config in `~/.toastty/config`
- no separate Sparkle-only release script
- no manual appcast XML editing

---

## Recommended Defaults

Use these defaults unless a better hosting setup is chosen before
implementation:

- `SUFeedURL`: `https://updates.toastty.app/appcast.xml`
- feed hosting: static content behind that vanity URL
- initial feed backing store: GitHub Pages is acceptable
- downloadable artifact hosting: GitHub Releases
- Sparkle private key storage: the secret store injected by `sv exec`
- Sparkle public key storage: committed in source via `Project.swift`

Why this shape:

- the vanity feed URL stays stable even if the backing host changes later
- GitHub Releases is already part of Toastty's release workflow
- the private key stays out of the repo and out of long-lived local shell config

---

## Preconditions

Do not start this work until all of these are true:

- the current DMG release workflow is working end-to-end
- the current GitHub release publish workflow is working end-to-end
- versioning is already driven by `TOASTTY_VERSION` and `TOASTTY_BUILD_NUMBER`
- the final `SUFeedURL` has been chosen
- the Sparkle private key secret location has been chosen

If the recommended default feed URL is accepted as-is, that satisfies the
`SUFeedURL` precondition.

Notes:

- Toastty currently appears to be a direct-distribution macOS app, not an App
  Store build. Keep this work scoped to that model.
- If the app later becomes sandboxed, revisit Sparkle's app sandbox guidance
  before implementation. Do not add sandbox-specific work preemptively in this
  first pass.

---

## Non-Goals

Skip these in the first Sparkle pass:

- multiple release channels
- custom updater UI
- `off | check | download` config in `~/.toastty/config`
- update preferences migration work
- separate `build-release.sh` or `update-appcast.py` scripts
- manual appcast XML editing
- delta update optimization before the base update path is proven

---

## Implementation Order

### 1. Add Sparkle through Tuist

Create `Tuist/Package.swift` and add Sparkle as an SPM dependency.

Do not cargo-cult a stale version example into the repo. At implementation time,
pin the current stable Sparkle release and commit the resulting lockfile.

Then:

- `tuist install`
- add `.external(name: "Sparkle")` to the app dependencies in `Project.swift`
- commit the generated lockfile
- regenerate the workspace and verify the app still builds

Also update any clean-machine flows that currently assume `tuist generate` is
enough. Once Sparkle is added through `Tuist/Package.swift`, dependency
resolution becomes part of the build setup.

At minimum, review:

- `scripts/release/release.sh` for `tuist install` before `tuist generate`
- `scripts/automation/check.sh` for `tuist install` before `tuist generate`

**Files:** `Tuist/Package.swift`, `Project.swift`, likely `scripts/release/release.sh`, likely `scripts/automation/check.sh`

---

### 2. Generate and store Sparkle keys

Generate the EdDSA keypair with Sparkle's bundled tool after the dependency is
installed.

Storage plan:

- private key lives in the secret manager injected by `sv exec`
- public key is committed in source via `Project.swift`

Recommended first-pass secret shape:

- repo secret name such as `TOASTTY_SPARKLE_PRIVATE_KEY`

Important:

- do not commit the private key
- do not store the private key in shell dotfiles
- if Sparkle tooling needs a file path instead of a raw value, materialize a
  temporary file inside the release or publish script and delete it with a trap
- do not regenerate the key once public releases have shipped

**Files:** no committed private-key file; public key added later in `Project.swift`

---

### 3. Extend the app Info.plist configuration

Extend the app target's existing `infoPlist: .extendingDefault(with:)`
configuration in `Project.swift`.

Add only the Sparkle keys required for the first pass:

```swift
infoPlist: .extendingDefault(with: [
    "SUPublicEDKey": .string("<public key>"),
    "SUFeedURL": .string("https://updates.toastty.app/appcast.xml"),
])
```

Notes:

- `SUFeedURL` must be real before release. Do not ship a placeholder.
- the public key is not secret and can live in source control
- keep bundle versioning aligned with the release workflow; Sparkle depends on
  stable version comparison
- reuse the existing `Project.swift`-driven Info.plist setup rather than
  introducing a second plist strategy here

**Files:** `Project.swift`

---

### 4. Add minimal app integration

Use Sparkle's standard updater controller. Avoid custom update abstractions
unless SwiftUI ownership forces a tiny bridge object.

Preferred first pass:

- own the updater controller in `AppLifecycleDelegate`
- start the updater during app startup
- add `Check for Updates...` to the existing command group after `.appInfo`
- wire the menu item's enable or disable state to Sparkle's
  `canCheckForUpdates`

Wire into the existing menu surface in:

- `Sources/App/ToasttyApp.swift`
- `Sources/App/Commands/ToasttyCommandMenus.swift`

Keep the UI scope minimal:

- manual `Check for Updates...`
- Sparkle-managed prompts and standard windows
- no custom settings screen

Do not touch `ToasttyConfigStore` in this pass. The current config file is
still effectively a terminal-font preference store, and expanding it creates
migration and persistence work that is unnecessary right now. Sparkle should
continue to use its own defaults storage rather than piggybacking on Toastty's
config file.

**Files:** `Sources/App/ToasttyApp.swift`, `Sources/App/Commands/ToasttyCommandMenus.swift`

---

### 5. Extend the build and provenance phase

Keep `scripts/release/release.sh` as the build and provenance script. Do not
make it publish GitHub Releases assets or upload the appcast.

Add Sparkle-specific work there only when it depends on the final bytes of the
downloadable artifact:

1. fail fast near the top of the script if `TOASTTY_SPARKLE_PRIVATE_KEY` is not
   available under `sv exec`
2. ensure dependency resolution is handled on clean machines before
   `tuist generate`
3. if Sparkle tooling requires a key file, materialize a temporary file from
   the secret, use it only for the signing step, and delete it with a trap
4. build the signed, notarized, stapled DMG through the existing flow
5. run Sparkle `sign_update` on the final downloadable DMG after stapling and
   final verification
6. validate that the produced signature output is present and well-formed before
   recording metadata
7. record the Sparkle outputs needed later for appcast publication in a
   dedicated `sparkle-metadata.env`

Capture enough metadata in the staged release directory to let the publish phase
build the appcast without re-deriving release facts from the current checkout.

Expected data to capture:

- final DMG path
- final DMG size or enclosure length
- Sparkle signature output
- release version and build number
- minimum supported macOS version for the shipped build

Keep this in a dedicated `sparkle-metadata.env` alongside the existing staged
release metadata. The important part is that the publish phase consumes
recorded metadata from `artifacts/release/<version>-<build>/` instead of
recomputing from `HEAD`.

**Files:** `scripts/release/release.sh`, possibly `docs/environment-and-build-flags.md`

---

### 6. Extend the publish phase

Keep `scripts/release/publish-github-release.sh` as the publication entry point.

This phase should be responsible for:

1. verifying the staged release directory from the earlier build phase
2. creating or updating the GitHub release and uploading the DMG asset
3. deriving the final stable download URL for that DMG
4. fetching the current published appcast, if one already exists
5. generating or updating the appcast using the recorded Sparkle metadata, the
   final download URL, and the existing appcast entries
6. setting `minimumSystemVersion` in the generated appcast entry from the
   recorded build metadata
7. publishing the merged appcast to the configured feed host

Important:

- do not hand-edit the appcast
- preserve prior appcast entries instead of reducing the feed to one release
- keep the current draft-vs-publish semantics for GitHub releases
- keep the feed URL stable even if the backing host changes later

For the first Sparkle-enabled release, GitHub Releases for the DMG plus a
static feed behind `https://updates.toastty.app/appcast.xml` is the recommended
default.

**Files:** `scripts/release/publish-github-release.sh`, likely feed-hosting automation or deployment config

---

### 7. Update operator docs and skills

The release workflow is encoded in repo docs and skills, so the implementation
is not complete until those instructions match the new Sparkle behavior.

Update at least:

- `.agents/skills/toastty-release/SKILL.md`
- `.agents/skills/toastty-publish/SKILL.md`
- `docs/environment-and-build-flags.md`

Document:

- any new `sv exec`-injected Sparkle secret requirement
- new staged release outputs such as `sparkle-metadata.env`
- the fact that appcast publication belongs to the publish phase, not the build
  phase

---

## File Changes

### Modified

- `Project.swift`
- `Sources/App/ToasttyApp.swift`
- `Sources/App/Commands/ToasttyCommandMenus.swift`
- `scripts/release/release.sh`
- `scripts/release/publish-github-release.sh`
- `docs/environment-and-build-flags.md`
- `.agents/skills/toastty-release/SKILL.md`
- `.agents/skills/toastty-publish/SKILL.md`
- likely `scripts/automation/check.sh`

### New

- `Tuist/Package.swift`

---

## Validation

### Dependency and build validation

- `tuist install`
- `tuist generate`
- `ARCH="$(uname -m)"; xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug -destination "platform=macOS,arch=${ARCH}" -derivedDataPath Derived build`
- `./scripts/automation/check.sh`

### Release pipeline validation

1. Run the build phase under `sv exec`.
2. Confirm the staged release directory contains the DMG, `release-metadata.env`,
   and `sparkle-metadata.env`.
3. Run the publish phase in dry-run mode first and confirm the derived GitHub
   release inputs and appcast publication inputs.
4. If possible, validate against a staging feed location before using the
   production feed URL.
5. Verify the built app's `SUFeedURL` matches the intended production feed URL
   before the first public Sparkle release ships.

### Sparkle behavior validation

1. Install the previously released version of Toastty into `/Applications`.
2. Publish a newer build to the real or staging appcast host.
3. Launch the older build.
4. Trigger `Check for Updates...`.
5. Confirm Sparkle finds the newer release, downloads it, and completes the
   install flow successfully.
6. Re-launch and confirm the upgraded app reports the new version.

### Manual regression checks

Because Sparkle is AppKit-heavy and release-signing sensitive, re-check:

- first launch
- command menu wiring
- Ghostty-backed terminal startup
- signed and notarized install behavior from the DMG
- update behavior from an already-installed app bundle

---

## Simplifications Worth Preserving

If the plan starts growing, cut back to this:

- standard Sparkle UI
- one feed
- one build phase plus one publish phase
- one menu item

Do not add config toggles, custom update chrome, or delta updates until there
is a real user need.
