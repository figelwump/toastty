# Toastty Sparkle Follow-Up Plan

## Goal

Add Sparkle after the DMG release pipeline is already working.

This is a follow-up release plan, not part of the first DMG ship. It should reuse the release foundation from `artifacts/plans/dmg-installer.md` instead of rebuilding it.

Target shape:
- one stable update channel
- Sparkle standard UI
- one menu item: `Check for Updates…`
- no custom update config in `~/.toastty/config`
- no custom appcast tooling unless Sparkle's bundled tools prove insufficient

---

## Preconditions

Do not start this work until all of these are true:
- the DMG release plan is implemented
- `scripts/release/release.sh` can already produce a signed, notarized DMG
- versioning is already driven by `TOASTTY_VERSION` and `TOASTTY_BUILD_NUMBER`
- a real hosting location is chosen for:
  - appcast XML
  - downloadable DMG assets

For a simple first Sparkle release, GitHub Releases + GitHub Pages is a reasonable default.

---

## Non-Goals

Skip these in the first Sparkle pass:
- multiple release channels
- custom updater UI
- `off | check | download` config in `~/.toastty/config`
- update preferences migration work
- separate `build-release.sh` or `update-appcast.py` scripts
- Delta update optimization before the base update path is proven

---

## Implementation Order

### 1. Add Sparkle through Tuist

Create `Tuist/Package.swift` and add Sparkle as an SPM dependency.

Example:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "toastty-dependencies",
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.0"),
    ]
)
```

Then:
- `tuist install`
- add `.external(name: "Sparkle")` to the app dependencies in `Project.swift`
- commit the generated lockfile (`Tuist/Package.resolved` if Tuist writes it there)
- regenerate the project and verify the app still builds

Why this is separate:
- the repo does not currently have `Tuist/Package.swift`
- dependency resolution should be validated before UI or release changes are mixed in

**Files:** `Tuist/Package.swift`, `Project.swift`

---

### 2. Generate and store Sparkle keys

Generate the EdDSA keypair with Sparkle's bundled tool after the dependency is installed.

Store:
- private key in secure local storage and CI secrets
- public key in the app's Info.plist configuration

Important:
- the private key is long-lived release infrastructure
- do not regenerate it once you have shipped public releases

**Files:** none committed yet, aside from the public key added later to `Project.swift`

---

### 3. Extend the app Info.plist configuration

Extend the app target's existing `infoPlist: .extendingDefault(with:)` configuration in `Project.swift`.

Add only the Sparkle keys required for the first pass:

```swift
infoPlist: .extendingDefault(with: [
    "SUPublicEDKey": .string("<public key>"),
    "SUFeedURL": .string("https://example.com/appcast.xml"),
])
```

Notes:
- `SUFeedURL` must be real before release. Do not ship a placeholder.
- the public key is not secret and can live in source control.
- keep bundle versioning aligned with the DMG plan; Sparkle depends on stable version comparison.
- reuse the DMG plan's generated Info.plist setup rather than introducing a second plist strategy here.

**Files:** `Project.swift`

---

### 4. Add minimal app integration

Use Sparkle's standard updater controller. Avoid custom update abstractions unless SwiftUI ownership forces a tiny bridge object.

Preferred first pass:
- hold `SPUStandardUpdaterController` in `ToasttyApp`
- start it during app startup
- add `Check for Updates…` to the existing command group after `.appInfo`

Wire into the existing menu surface in:
- `Sources/App/ToasttyApp.swift`
- `Sources/App/Commands/ToasttyCommandMenus.swift`

Keep the UI scope minimal:
- manual `Check for Updates…`
- Sparkle-managed prompts and standard windows
- no custom settings screen

Do not touch `ToasttyConfigStore` in this pass. The current config file is still effectively a terminal-font preference store, and expanding it creates migration and persistence work that is unnecessary right now. Sparkle should continue to use its own defaults storage rather than piggybacking on Toastty's config file.

**Files:** `Sources/App/ToasttyApp.swift`, `Sources/App/Commands/ToasttyCommandMenus.swift`

---

### 5. Extend the existing release script

Do not create a second release script.

Extend `scripts/release/release.sh` to do Sparkle-specific publish work after the DMG is built:

1. build signed, notarized release artifacts using the existing flow
2. sign the final downloadable artifact with Sparkle's `sign_update` after notarization and stapling are complete
3. generate or update the appcast using Sparkle tooling, including the correct minimum macOS version for the shipped build
4. publish the appcast and DMG to the chosen host

Keep this on the same path as DMG distribution so there is still exactly one release entry point.

**Files:** `scripts/release/release.sh`

---

### 6. Add release-hosting automation

For the first Sparkle-enabled release, keep hosting simple and explicit.

Recommended first pass:
- DMG uploaded to GitHub Releases
- appcast hosted on GitHub Pages or another static URL you control

What matters:
- the `SUFeedURL` is stable
- the DMG URL in the appcast is stable
- publishing can be repeated without manual XML editing

CI can come after the local flow works, but the plan should assume eventual automation through one workflow, not several disconnected scripts.

**Files:** likely future `.github/workflows/...`, not required for the initial local implementation pass

---

## File Changes

### Modified

- `Project.swift`
- `Sources/App/ToasttyApp.swift`
- `Sources/App/Commands/ToasttyCommandMenus.swift`
- `scripts/release/release.sh`

### New

- `Tuist/Package.swift`

---

## Validation

### Dependency and build validation

- `tuist install`
- `tuist generate`
- `ARCH="$(uname -m)"; xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug -destination "platform=macOS,arch=${ARCH}" -derivedDataPath Derived build`
- `./scripts/automation/check.sh`

### Sparkle behavior validation

1. Install the previously released version of Toastty.
2. Publish a newer build to the real appcast host.
3. Launch the older build.
4. Trigger `Check for Updates…`.
5. Confirm Sparkle finds the newer release, downloads it, and completes the install flow successfully.
6. Re-launch and confirm the upgraded app reports the new version.

### Manual regression checks

Because Sparkle is AppKit-heavy and release-signing sensitive, re-check:
- first launch
- command menu wiring
- Ghostty-backed terminal startup
- signed/notarized install behavior from the DMG

---

## Simplifications Worth Preserving

If the plan starts growing, cut back to this:
- standard Sparkle UI
- one feed
- one release script
- one menu item

Do not add config toggles or custom update chrome until there is a real user need.
