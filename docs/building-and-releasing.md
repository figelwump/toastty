# Building and Releasing

This guide covers building Toastty from source, running validation, and producing signed release DMGs.

## Requirements

- macOS 14.0+
- [Mise](https://mise.jdx.dev/) (installs the Tuist version pinned in `.tool-versions`)
- Xcode 16+ with Swift 6.0
- An iOS 18+ Simulator runtime (for the native iOS client)
- [sv](https://github.com/figelwump/sv) (secret vault for development credentials)
- Node.js/npm (web-panel tests and release-notice checks)
- `jq` and ripgrep (required by the full validation gate)
- Ghostty XCFramework (optional — Toastty can build in fallback mode without it)

## Clone and generate

```bash
git clone https://github.com/figelwump/toastty.git
cd toastty
./scripts/dev/bootstrap-worktree.sh
```

Toastty has two independent Tuist graphs. Root `Project.swift` is the source of
truth for the macOS app; `ios/Project.swift` and `ios/Workspace.swift` are the
source of truth for the native iOS client. Run Tuist from the graph's own
directory and never edit either graph's generated project or workspace files.

`./scripts/dev/bootstrap-worktree.sh` prepares the macOS graph by running
`tuist install` and `tuist generate --no-open`; in a fresh linked worktree it
also reuses local Ghostty xcframeworks from another Toastty worktree when
available. The generated `toastty.xcworkspace` is not committed, so rerun the
bootstrap script or `tuist generate` after manifest or file-layout changes.
Re-run `tuist install` whenever `Tuist/Package.swift` or
`Tuist/Package.resolved` changes.

Mac generation requires push relay settings so an Xcode build cannot silently
lose iPhone alerts. Use `sv exec -- tuist generate --no-open` to load stored
settings. For an intentional build without push, use
`TUIST_TOASTTY_DISABLE_PUSH=1 ./scripts/dev/bootstrap-worktree.sh`.
See [generation flags](environment-and-build-flags.md#build-and-generate)
for the settings and opt-out rules.

## Install sv

[sv](https://github.com/figelwump/sv) is a lightweight macOS secret vault that stores API keys and credentials in the native Keychain and injects them into processes at runtime. Automation scripts in this repo use `sv exec --` to run commands that need secrets without exposing values in shell history or environment dumps.

```bash
curl -fsSL https://raw.githubusercontent.com/figelwump/sv/main/install.sh | bash
```

After installing, store any required secrets with `sv set <KEY>`. To run a command with secrets injected:

```bash
sv exec -- <command>
```

## Install Ghostty XCFramework (optional)

Toastty's full Ghostty integration requires the internal
`ghostty_surface_is_at_prompt` API carried by the maintained
[`toastty-downstream`](https://github.com/figelwump/ghostty/tree/toastty-downstream)
branch. Clone that branch as a sibling of the Toastty checkout, then build its
XCFramework using the command in [Ghostty Integration](ghostty-integration.md):

```bash
git clone --branch toastty-downstream \
  https://github.com/figelwump/ghostty.git \
  ../ghostty
```

After building the XCFramework, install it into Toastty:

```bash
GHOSTTY_BUILD_FLAGS="-Demit-macos-app=false -Demit-xcframework=true -Dxcframework-target=universal -Dsentry=false" \
GHOSTTY_XCFRAMEWORK_SOURCE=../ghostty/macos/GhosttyKit.xcframework \
  ./scripts/ghostty/install-local-xcframework.sh
```

Set `GHOSTTY_XCFRAMEWORK_VARIANT=release|debug` to control the destination artifact path. The installer also auto-detects a sibling `../ghostty/macos/GhosttyKit.xcframework` checkout when present.
When the source path lives inside a Ghostty git checkout, the installer also records the Ghostty commit and source cleanliness in an ignored sidecar metadata file next to the installed xcframework.

For the recommended Ghostty build command, downstream branch policy, and release
note guidance, see [Ghostty Integration](ghostty-integration.md).

After installing, regenerate:

```bash
./scripts/dev/bootstrap-worktree.sh
```

To build without Ghostty:

```bash
TUIST_DISABLE_GHOSTTY=1 ./scripts/dev/bootstrap-worktree.sh
```

## Build the macOS app

```bash
ARCH="${ARCH:-$(if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" == "1" ]]; then echo arm64; else uname -m; fi)}"
xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp \
  -configuration Debug \
  -destination "platform=macOS,arch=${ARCH}" \
  -derivedDataPath Derived build
```

Or open `toastty.xcworkspace` in Xcode and hit Run.

## Build the native iOS app

The iOS client is a separate Tuist graph under `ios/`. Its generated Xcode
project and workspace are gitignored, so generate them in each fresh checkout
or worktree:

```bash
node ios/scripts/toastty-ios.mjs generate
open ios/ToasttyMobile.xcworkspace
```

The dispatcher runs `tuist install` and `tuist generate --no-open` from the
`ios/` graph. Generated projects use the Toastty development team
`SP7JP8254U` with automatic signing by default, so regenerating the workspace
preserves the Xcode signing selection. Set `TOASTTY_IOS_DEVELOPMENT_TEAM` when
generating to override that team. In Xcode, use the `ToasttyMobileApp` scheme
with an iOS 18 or newer Simulator. To generate and build or run all app tests
from the command line, use:

```bash
node ios/scripts/toastty-ios.mjs build
node ios/scripts/toastty-ios.mjs test
```

Both commands select a compatible iPhone Simulator automatically. Pass
`--dry-run` to any dispatcher command to inspect its plan without invoking
Tuist or Xcode.

For App Store Connect signing, validation, upload, and internal TestFlight
distribution, see [iOS Release CI](ios-release-ci.md).

For session notifications in the normal development iPhone app, see the
[push relay setup](../workers/push/README.md). Both the paired Mac and the fixed
development Debug app need matching explicit relay configuration. The same
runbook also covers the separate operator probe, which replaces the normal
development app. Unconfigured builds keep session push disabled.

## Validate

```bash
# Full gate: generate, self-tests, web-panel tests, build, smoke, and app tests
./scripts/automation/check.sh

# Smoke UI automation
./scripts/automation/smoke-ui.sh

# Shortcut hint screenshot smoke
./scripts/automation/shortcut-hints-smoke.sh

# Workspace tabs screenshot smoke
./scripts/automation/workspace-tabs-smoke.sh

# Workspace-scope CLI/socket smoke
./scripts/automation/workspace-scope-smoke.sh

# Keyboard shortcut tracing
./scripts/automation/shortcut-trace.sh

# Remote xcodebuild test for AppKit-presenting or focus-stealing XCTest runs
TOASTTY_REMOTE_GUI_HOST=mac-mini.local \
./scripts/remote/test.sh \
  --scope working-tree \
  -- \
  -workspace toastty.xcworkspace \
  -scheme ToasttyApp \
  -configuration Debug \
  -destination "platform=macOS,arch=arm64" \
  -only-testing:ToasttyAppTests/CommandPaletteControllerTests

# Remote smoke validation
TOASTTY_REMOTE_GUI_HOST=mac-mini.local \
./scripts/remote/validate.sh \
  --smoke-test smoke-ui \
  --scope working-tree

# Require the remote host instead of falling back locally
TOASTTY_REMOTE_GUI_HOST=mac-mini.local \
./scripts/remote/validate.sh \
  --smoke-test workspace-tabs \
  --scope head \
  --require-remote

# Remote workspace-scope CLI/socket smoke
TOASTTY_REMOTE_GUI_HOST=mac-mini.local \
./scripts/remote/validate.sh \
  --smoke-test workspace-scope \
  --scope working-tree

# Remote shortcut-hints screenshot smoke
TOASTTY_REMOTE_GUI_HOST=mac-mini.local \
./scripts/remote/validate.sh \
  --smoke-test shortcut-hints \
  --scope working-tree

# Remote keyboard shortcut tracing
TOASTTY_REMOTE_GUI_HOST=mac-mini.local \
CLICK_X=760 CLICK_Y=420 \
./scripts/remote/validate.sh \
  --smoke-test shortcut-trace \
  --scope head \
  --require-remote

# Note: SSH-based remote shortcut tracing skips the Workspace > Close Panel
# menu-equivalence subcheck because System Events menu-item dispatch is not
# reliable in that context. The remote trace still validates the action path
# and Cmd+W path.

# Foreground-capable remote validation escape hatch
TOASTTY_REMOTE_GUI_HOST=mac-mini.local \
./scripts/remote/validate.sh \
  --scope working-tree \
  --validation-command 'peekaboo menu list --pid "$TOASTTY_PID" --json | tee "$TOASTTY_ARTIFACTS_DIR/peekaboo-menu.json"'
```

`scripts/remote/test.sh` is the preferred remote path for XCTest runs that may present real AppKit windows or panels on the host machine. It creates a disposable remote worktree, runs `xcodebuild test` there, and copies logs plus the `.xcresult` bundle back into `artifacts/remote-tests/<run-label>/`. Unlike `validate.sh`, it does not fall back to a local run.

## Dev and test runs

When developing or testing locally, Toastty can isolate all mutable state — config, workspace layouts, Scratchpad documents, terminal profiles, logs, and `UserDefaults` — inside a per-worktree or per-run runtime home so parallel instances never collide.

Set `TOASTTY_DEV_WORKTREE_ROOT` to derive a stable sandbox from the current worktree, or set `TOASTTY_RUNTIME_HOME` for an explicit one-off sandbox. The Tuist-generated Xcode Run schemes already set `TOASTTY_DEV_WORKTREE_ROOT=$(SRCROOT)`.

For fresh linked worktrees, run `./scripts/dev/bootstrap-worktree.sh` once to symlink Ghostty artifacts from another Toastty checkout before building.

For the full runtime-home model, `instance.json` fields, and cleanup conventions, see [Runtime Sandboxing](runtime-sandboxing.md).

### Use personal runtime configuration with the local Release scheme

The generated `ToasttyApp-Release` Run scheme keeps normal worktree runtime
isolation, but bootstrap can opt specific non-secret runtime settings into that
scheme from `sv`. The allowlist lives in `Project.swift`; values outside that
list are never copied into the app's launch environment.

For example, configure the shared terminal-profile catalog once:

```bash
sv set TUIST_TOASTTY_TERMINAL_PROFILES_PATH
```

Enter an absolute path or a `~/`-prefixed path such as
`~/.toastty/terminal-profiles.toml`. Do not use `$HOME` or another shell
variable because Xcode expands `$` expressions in generated scheme values.
Then regenerate and open the workspace:

```bash
./scripts/dev/bootstrap-worktree.sh
open toastty.xcworkspace
```

Select `ToasttyApp-Release` in Xcode and use Build and Run normally. Repeat
bootstrap after changing the stored value, creating a fresh worktree, or
regenerating the project. The resolved value is written in plaintext to the
generated, gitignored Xcode scheme, so this mechanism is only for non-secret
configuration. Never add tokens, passwords, signing credentials, or other
secrets to the Release runtime allowlist. The override applies only to Xcode's
`ToasttyApp-Release` Run action; Debug, Finder, `open`, and direct executable
launches do not receive it.

## Release order

A Toastty release has four parts that reach users separately: the iPhone
notification relay (a Cloudflare Worker), the iPhone app (TestFlight), the Mac
app (GitHub Releases and the Sparkle update feed), and the website. Each part
must find the parts it talks to already updated. Do the steps in this order:

1. **Record the version.** Choose the marketing version and a build number
   greater than the highest `sparkle:version` in
   `https://updates.toastty.dev/appcast.xml`. Write both in the release
   checklist or pull request. The release of the task system is `0.10.0` with
   build `40` or higher, because `0.9.2` is build `39`.
2. **Prepare the release commit on `main`.** Build the Ghostty release artifact
   at the commit that [Ghostty Integration](ghostty-integration.md) pins, and
   check it with `scripts/release/check-ghostty-pin.sh`. Run the full build and
   tests on the release commit, and a manual `Toastty CI` run from `main`. Keep
   the website change out of `main` until step 6, because a website change goes
   live when it reaches `main`; see [When the website goes live](#when-the-website-goes-live).
3. **Deploy the production push relay** from the release commit. The
   repository owner does this by hand, because the repository has no
   production deploy command; see
   [Production relay release step](../workers/push/README.md#production-relay-release-step).
   Reason: a relay without task alerts answers a task alert with HTTP 400. The
   Mac then sends only the session alerts that the task alert replaced, so a
   task alert that replaced none, such as a stopped merge, sends nothing.
4. **Make the iPhone build available** through TestFlight, as
   [iOS Release CI](ios-release-ci.md#first-internal-build) describes. This
   step is required before the Mac release goes live; the protocol has no other
   protection for an older phone. For the real-device check, use a Mac build
   from step 5's `scripts/release/release.sh` before you publish it. Reason: a
   phone build without task alerts cannot decode alerts with `kind: "task"`.
   The alert's text shows, but a tap only opens the app, and while the app is
   open no banner shows.
5. **Release the Mac app.** Build the DMG with `scripts/release/release.sh`,
   write the release notes with a `## Highlights` section, and publish with
   `scripts/release/publish-github-release.sh`. Only `--publish` changes the
   update feed, so existing users get the update at that point. Right before
   `--publish`, the release agent asks the repository owner "publish now?"
   and publishes only after a plain yes to that question, also when the
   release approval already covers publication; see
   [Publish now?](../.agents/skills/toastty-publish/SKILL.md#publish-now).
6. **Publish the website change.** Merge its pull request into `main` after the
   Mac release is live, then confirm on toastty.dev that the change shows. For
   `0.10.0` the website change is two stacked pull requests that land together:
   the website text change (#392), and the new "Tasks and the Coordinator"
   section stacked on it. #392 targets `feat/task-system-coordinator` today;
   retarget it to `main` after step 2, so that it does not merge with the
   release branch. The coordinator tracks this step until the site shows the
   new page.

Do not change the order when only some parts change. A step for a part that did
not change is a no-op.

### When the website goes live

toastty.dev is a Render static site behind Cloudflare (`www.toastty.dev` is a
CNAME for `toastty-dev.onrender.com`). Its deploy settings are in the Render
dashboard, not in this repository. The site most likely publishes `website/` on
each push to `main`: after pull request #125 merged at 23:23:10 UTC on
2026-10-10, the live page's `Last-Modified` was 23:23:24 UTC. Steps 2 to 5 need
the release commit on `main`, so a website change that is on the release branch
goes live at step 2. The site then describes features that the download does not
have yet, for as long as steps 3 to 5 take. Choose one way to prevent that:

- **Keep the website change in its own pull request into `main`, and merge it at
  step 6.** Nothing to change in Render. The website pull request must not be
  part of the release branch. Chosen for `0.10.0` on 2026-11-16. Cost: from step 2 to step 6 the old
  page stays live, and its links to the worktree handoff examples in
  `tree/main/examples/skills` find a folder that holds only the `toastty-tasks`
  skill.
- **Merge to `main` and publish the Mac release close together.** No extra pull
  request, but the site is ahead of the download for hours or more: the relay
  deploy, the TestFlight build, and the real-device check all come between.
- **Turn off automatic deploys in Render before step 2, and deploy by hand at
  step 6.** The website change can stay on the release branch, but the repository
  owner must change the Render settings and turn them back on afterwards. The
  old page and its stale links to `tree/main/examples/skills` stay live from
  step 2 to step 6, as in the first option.

## Build a signed release DMG

The release script expects:
- a clean Toastty git working tree
- a release Ghostty artifact at `Dependencies/GhosttyKit.Release.xcframework`
- Ghostty provenance metadata at `Dependencies/GhosttyKit.Release.metadata.env`
- access to the clean Ghostty source checkout containing the recorded release commit
- a Ghostty artifact built from the commit pinned in [Ghostty Integration](ghostty-integration.md): the `git -C ../ghostty checkout <commit>` line. `scripts/release/check-ghostty-pin.sh` compares the two, and the release script stops when they differ, because a stale artifact still builds
- a local `Developer ID Application` certificate
- notarization credentials injected at runtime
- a Sparkle private key injected at runtime as `TOASTTY_SPARKLE_PRIVATE_KEY`
- the configured Toastty Mac mini, with its validation desktop unlocked, Accessibility available, and the Claude CLI signed in
- `gh` signed in, to download the previous release's DMG for the candidate check

Before building a release artifact, run the full automated gate on the release candidate:

```bash
./scripts/automation/check.sh
```

Use an explicit marketing version plus a monotonically increasing build number:

```bash
sv exec -- env \
  TOASTTY_VERSION=0.1.0 \
  TOASTTY_BUILD_NUMBER=1 \
  TUIST_DEVELOPMENT_TEAM=<TEAM_ID> \
  ./scripts/release/release.sh
```

The script archives the app, exports a signed bundle, creates a plain drag-to-install DMG, notarizes it, staples it, and writes outputs under `artifacts/release/`.
Before reporting the candidate ready, it runs the candidate check: one check
of the signed app as a user meets it. A release that fails it does not go to
the user. The check sends the finished DMG, and the DMG of the previous
release (`RELEASE_PREVIOUS_TAG`, downloaded from its GitHub release), to the
Toastty validation Mac mini, and holds the mini's desktop through the remote
admission queue. It copies each app from a read-only mount into disposable
folders. Every stage has its own runtime home and user home; the mini's
installed Toastty is not touched. The stages:

| Stage | What it does with the candidate |
| --- | --- |
| `firstLaunch` | Starts with no saved state. The What's New sheet must show, **Not Now** must close it, and the app must answer a query after that. A crash or an AppKit startup exception fails it. |
| `update` | The previous release saves a layout with two workspaces. The candidate replaces the app at the same path, restores the layout, and shows the What's New sheet over it. **Start Coordinator** opens the coordinator, and the first message gets its answer. |
| `sessions` | The previous release saves a coordinator conversation and two task agents, and quits from its menu. The candidate replaces it. Each new shell takes three seconds to its first prompt. The coordinator answers in its saved conversation, and each task agent starts once, with its saved conversation. |
| `restart` | The coordinator's agent ends and a chat message waits. **Restart Coordinator** in the chat's notice starts a new agent, which gets the message once. |
| `compact` | Claude Code's real "We recommend compacting earlier" offer: **Show Terminal**, arrow keys, the scroll wheel, Escape, and the waiting message delivered once. |

The coordinator is the real Claude CLI with the mini's Claude account; a
task's agent is a script that records each start. A run takes about four
minutes after the queue, and uses about eight short Claude turns plus one turn
with about 230k input tokens. The receipt,
`artifacts/release/<version>-<build>/candidate-check/remote/result.json`,
records each stage, the mini's macOS version, the Claude CLI version, and the
SHA-256 of both DMGs.

The check does not cover: a macOS version or display setup other than the
mini's (it records its version, and has one display); the user's own shell
startup files, plugins, agents and saved state; installation through a
Sparkle update or a Gatekeeper prompt for a downloaded file; an Intel Mac; and
the iPhone.

To check an existing candidate separately, use the full source commit from
the candidate build, the previous release's tag, and a new evidence
directory. Set `TOASTTY_PREVIOUS_DMG` to a local DMG of that release to skip
the download:

```bash
sv exec -- ./scripts/release/verify-candidate.sh \
  artifacts/release/<version>-<build>/Toastty-<version>.dmg \
  <full-source-commit> <previous-release-tag> <new-evidence-directory>
```

The release build keeps the evidence at
`artifacts/release/<version>-<build>/candidate-check/`: the receipt, the
desktop admission record, the app logs, Claude's transcripts, and frames of
each stage under `remote/use/`. If the desktop or connection was unavailable,
move any failed evidence directory aside and rerun the check with
`candidate-check/` as the destination inside that same release directory.
The staged DMG and release metadata remain available for the retry.
If macOS displays a crash alert for the failed candidate, dismiss it on the
validation desktop before retrying.
`sv exec` must provide `TUIST_TOASTTY_DIAGNOSTICS_ENDPOINT` and `TUIST_TOASTTY_DIAGNOSTICS_UPLOAD_KEY`; release builds fail if the generated project would embed empty diagnostics submit endpoint or upload-key settings.
`sv exec` must also provide the production session push relay: `TUIST_TOASTTY_PUSH_RELAY_URL`, `TUIST_TOASTTY_PUSH_RELAY_ID`, and `TUIST_TOASTTY_PUSH_APNS_ENVIRONMENT=production`. The release fails before building when they are missing or not production, and after export when the app's `Info.plist` does not contain them. Without these values, the Mac sends no iPhone session alerts.
Before the archive is built, the release workflow verifies the generated
third-party notices against the pinned production web-panel dependencies,
Ghostty, Sparkle, and the checked-in Toastty license. The verified notices are
bundled at `Contents/Resources/ThirdPartyNotices.txt` in the app.
Each production web-panel package must ship a license or notice file. A package
that ships none needs an entry for its exact `name@version` in
`scripts/release/third-party-license-overrides.json`: the license, the license
text under `scripts/release/third-party-licenses/`, its source, and the reason.
The check stops when an entry is missing, when the package ships a license file
after all, or when no installed package uses the entry, for example after a
version change. `format@0.2.2` has such an entry: the npm package ships no
license file, and the text is the MIT `License.md` its author added upstream.
It also snapshots release provenance into the release directory:
- `release-metadata.env` with the exact Toastty commit that was built
- `ghostty-metadata.env` with the embedded Ghostty commit and build flags
- `sparkle-metadata.env` with the feed URL, public key, DMG signature, SHA-256, and enclosure metadata needed for appcast publication

The script also records the canonical `artifacts/release/<version>-<build>/release-notes.md` path in `release-metadata.env`, but it does not generate the file for you. The repo-local `toastty-release` skill covers the build step and drafting `release-notes.md` from the recorded release diff so it can be reviewed before publish; the repo-local `toastty-publish` skill covers publishing those drafted notes later.

## Publish a draft GitHub Release

After the DMG exists locally, publish it to GitHub Releases with the helper script. The script defaults to a draft release; pass `--publish` only when you want the release to go live immediately and update the Sparkle appcast at `https://updates.toastty.dev/appcast.xml`.

`--publish` makes the release visible to users: the latest GitHub release, which the website's Download links open, and the Sparkle update feed. Without `--dry-run`, the script refuses `--publish` unless `--confirm-publish` is also given. Pass `--confirm-publish` only after the repository owner answered a plain yes to "publish now?" for this version and build. A draft release and `--publish --dry-run` need no confirmation.

Prerequisites:
- `gh` is installed and authenticated for the target repo
- the recorded release commit is available in the current checkout
- the `candidate-check/remote/` receipt records a successful desktop check,
  with every stage passed, for the recorded source commit and the SHA-256 of
  the DMG being uploaded. This also applies to draft releases and dry runs.
- the upload matches the SHA-256 and file size recorded alongside the
  Sparkle signature

Author `artifacts/release/<version>-<build>/release-notes.md` before publishing. Ground it in the recorded Toastty release diff and include the embedded Ghostty commit plus build flags; the publisher verifies those exact provenance lines before creating the release. Every release needs a `## Highlights` section with content. With `--publish`, the publisher writes that section, as HTML, into the update feed item's `description`, followed by a "Full release notes on GitHub" link. The Sparkle update prompt shows it in its release notes box, so it is the first thing an updating user reads. The item has no `sparkle:releaseNotesLink`, because Sparkle then shows the linked page instead of the `description`; its `sparkle:fullReleaseNotesLink` points to the GitHub releases list for the Version History button. The section can use `- ` bullets, `### ` subheadings, paragraphs, `` `code` ``, `**bold**`, and `[text](https://...)` links. The publisher stops when the section is missing, repeated, or empty, uses other Markdown, or when a `{{placeholder}}` from the template remains. A `--publish --dry-run` writes the updated feed to `artifacts/release/<version>-<build>/appcast-dry-run.xml` without changing anything.

```bash
sv exec -- env \
  TOASTTY_VERSION=0.1.0 \
  TOASTTY_BUILD_NUMBER=1 \
  ./scripts/release/publish-github-release.sh \
  --create-tag
```

Add `--dry-run` to print the exact `git tag`, `git push`, and `gh release create ...` commands without creating anything. If `origin` is not a parseable GitHub remote, pass `--repo <owner/repo>` explicitly. Pass `--notes-file` only when you want to override the default notes path.

## Website and README images

The landing page in `website/` is static HTML with no build step. Its hero is an HTML recreation of the app driven by one timeline in `website/hero.js`; when the UI it imitates changes, update that markup and timeline. The README hero, the README workflow images, and the social preview card are all rendered from that page, so they stay consistent with it:

```bash
node scripts/website/render-hero-video.mjs --social \
  --stills 'workflow-1=0@.qe-desk,workflow-2=15.9,workflow-3=17.6'
```

The script uses local Google Chrome (or `CHROME_PATH`) and `ffmpeg`, reads only local files, and writes to `artifacts/website-hero/`: `toastty-tour.mp4`, `poster.png`, one PNG per still, and `social-preview.png`. Copy `poster.png` to `docs/assets/toastty-hero.png`, `social-preview.png` to `website/assets/social-preview.png`, and the `workflow-2` and `workflow-3` stills, downscaled to 1600px wide, to `docs/assets/readme/`. The `workflow-1` still is the quick entry card of the page's Tasks section; pad it to the shape of the other stills with the page color: `sips --padToHeightWidth 635 1000 --padColor F5EEE2 artifacts/website-hero/workflow-1.png --out docs/assets/readme/workflow-1.png`.

The Toastty Mobile section of the page is a second recreation, an iPhone driven by `website/mobile.js`; its colors mirror `ios/Sources/ToasttyMobileApp/ToasttyDesignTokens.swift`, so update both when the native client's look changes. `--target mobile` renders it the same way, to a portrait MP4 for social posts plus a poster, stills, and a 1200x630 card with the phone beside the Toastty Mobile tagline:

```bash
node scripts/website/render-hero-video.mjs --target mobile --social --stills 'ready=1.2'
```

This writes `toastty-mobile.mp4`, `mobile-poster.png`, `mobile-<name>.png`, and `mobile-social.png` into the same directory. The site keeps using the desktop card as its share image; the mobile card is for posts about the iPhone app. The README's Toastty Mobile image is the phone cropped out of the `ready` still (Home on Needs you) with transparent corners: `scripts/website/crop-mobile-phone.sh artifacts/website-hero/mobile-ready.png docs/assets/readme/mobile.png`.

The README's sidebar, right panel, and window images, and the screenshots of quick entry, the Tasks view, and the coordinator chat, are screenshots of the real app. `scripts/website/capture-demo-screenshots.sh` launches an isolated Debug build in automation mode, with its own runtime home, home folder, shell, and Ghostty config, and builds a made-up `lumen` demo through the `toastty` CLI: real tasks whose agents are fake `claude` scripts that print a canned transcript, a fake coordinator whose chat shows a seeded conversation, and a fake `gh` that reports PR #128 as open with passing checks. No real agent or GitHub account is used. The app draws each capture itself (`automation.capture_screenshot`), so the script needs no Screen Recording permission. It opens menus, presses buttons, and types through Accessibility (`scripts/automation/ax-drive.swift`), so it needs Accessibility permission for your terminal and an unlocked screen, and it brings the demo window to the front for about two minutes. The demo app gets its own home folder and temporary directory, so it never reads or changes your Toastty settings, `~/.toastty`, Codex hooks, or the socket discovery record your CLI uses:

```bash
scripts/website/capture-demo-screenshots.sh --build --out artifacts/website-capture/latest
```

On a Mac whose display is not Retina, such as the remote Mac mini, add `--hidpi-display 1600x1000`: the script adds a temporary 2x display for the run, so the captures are 2x. macOS makes that display the main display while it exists, so run it only while no other GUI check uses the Mac. On the mini, through the remote wrapper, which builds the app and holds the mini's desktop for the run:

```bash
sv exec -- scripts/remote/validate.sh --require-remote --scope working-tree --validation-command \
  'scripts/website/capture-demo-screenshots.sh --app "$TOASTTY_APP_BUNDLE" --hidpi-display 1600x1000 --out "$TOASTTY_ARTIFACTS_DIR/demo"'
```

The images land in `demo/` under the run's artifacts. Copy `sidebar.png` and `right-panel.png` to `docs/assets/readme/`, and `window.png`, `quick-entry.png`, `tasks-view.png`, and `coordinator-dock.png`, each downscaled to 1600px wide at most, to `docs/assets/readme/` too. The GitHub repository's own social preview is set separately under the repository's Settings.

## Related docs

- [Environment and Launch Flags](environment-and-build-flags.md)
- [Ghostty Integration](ghostty-integration.md)
- [Runtime Sandboxing](runtime-sandboxing.md)
