# Linux release packaging

Status: `.deb` and AppImage are built, tested and ready to publish on GitHub
Releases. Snap and Flatpak recipes are drafts, built later.

## Goal

Ship the Linux port on the same GitHub Release as the macOS DMG: a `.deb` and
an AppImage, same version and `v<version>` tag, built from the same commit and
released by the same process. Snap and Flatpak distribution comes later.
Validation is local: offscreen on Broadway, plus a real window for OpenGL
(`.agents/skills/toastty-release/references/linux.md`).

## Release flow

1. macOS: `toastty-release`, then `toastty-publish` creates the tag and the
   release (draft or published).
2. Linux, on a clean checkout of the tagged commit:
   `scripts/automation/check.sh`, `scripts/linux/package.sh`,
   `scripts/linux/test-package.sh` (install, launch, terminal, Claude and
   Codex, screenshots; also `--real-window` and, with the user's `sudo`, a
   real `.deb` install).
3. `scripts/release/publish-linux-release.sh` attaches the `.deb`, AppImage,
   `.zsync` and `SHA256SUMS-linux.txt`; it checks that the tag names the
   packages' source commit.

## Shared shape

`scripts/linux/package.sh` builds the release products once, then stages them
with `scripts/linux/install.sh --prefix /usr --destdir <stage>`. That layout
is already relocatable: binaries use `$ORIGIN` RUNPATHs, the Swift runtime,
`libghostty` and the GTK widget are bundled under `lib/toastty/lib`, and the
app finds its resources relative to the executable. Each format wraps the
same stage:

| Format | Wraps the stage as | System libraries | Confinement |
|---|---|---|---|
| `.deb` | `/usr` tree + `DEBIAN/control` | From the distro (`Depends:` from the binaries' direct links) | None |
| AppImage | `AppDir/usr` + `AppRun` | From the host (GTK 4, libadwaita, WebKitGTK 6.0) | None |
| snap | `dump` of the stage on `core26` | Staged from the Ubuntu 26.04 archive | `classic` |
| Flatpak | Built from source in `org.gnome.Sdk` | GNOME runtime | Sandbox + host spawn |

Artifacts go to `artifacts/release/linux/<version>-<build>/`.

## Decisions and constraints

- **glibc floor.** A host build links against Ubuntu 26.04's glibc 2.43, so
  the `.deb` and AppImage run only on distros at least that new. Widening
  that needs a build on an older base (a container or chroot with Swift 6.4,
  Zig 0.16 and the GTK 4/libadwaita/WebKitGTK 6.0 headers). The snap is not
  affected (core26 is 26.04); the Flatpak builds against its runtime.
- **AppImage does not bundle GTK/WebKit.** WebKitGTK starts helper processes
  (`WebKitWebProcess`, `WebKitNetworkProcess`) from paths fixed at build time,
  which AppImage tools do not relocate reliably. The AppImage bundles
  Toastty, the Swift runtime and Ghostty, and requires GTK 4, libadwaita and
  WebKitGTK 6.0 from the host.
- **A terminal needs host access.** Toastty runs the user's shells and agent
  CLIs and installs agent hooks under `~`. Strict snap confinement would run
  shells inside the snap, so the snap is `classic` (like Ghostty's), which
  needs a Snap Store review and rules out the gnome extension: GTK 4,
  libadwaita and WebKitGTK come in as `stage-packages`. The Flatpak keeps the
  sandbox; Ghostty starts shells on the host through
  `org.freedesktop.Flatpak.Development.HostCommand` (`flatpak-spawn --host`),
  and the manifest grants home access for agent hooks.
- **Flatpak builds from source.** The GNOME runtime's glibc does not match a
  host build, so the manifest builds inside `org.gnome.Sdk` with the
  `org.freedesktop.Sdk.Extension.swift6` extension (published for the 26.08
  branch) and a pinned Zig. Ghostty's Zig package dependencies must be
  vendored as manifest sources, because Flatpak builds have no network.
- **Version.** `package.sh` takes `--version` and `--build-number`, writes them
  to `lib/toastty/share/toastty/version` (read by the About dialog) and adds a
  `<release>` entry to the AppStream metadata.
- **CLI path stability (AppImage).** An AppImage mounts at a new path each
  launch. Agent hooks call `$TOASTTY_CLI_PATH` from the launch environment and
  shim links are rewritten at every launch, so no mounted path is persisted.

## Decisions

- Channels: GitHub Releases for `.deb` and AppImage now; Flathub and the Snap
  Store later.
- Versions follow the macOS release (same version and tag).
- Updates: AppImage update information (`gh-releases-zsync`, latest release)
  serves AppImageUpdate and other updaters; `.deb` users download the new
  release. An in-app update check is not built.
- App ID stays `com.GiantThings.toastty` on Linux. `.deb` and AppImage do not
  need valid AppStream; `appstreamcli validate` rejects the ID
  (`cid-domain-not-lowercase`), which matters only for Flathub. The macOS
  bundle ID is independent of the Linux GApplication/desktop ID, so a Linux
  rename would not affect macOS.

## Open questions

1. Lowering the glibc floor with an older-base build environment.
2. An in-app update check for `.deb` users.
3. The Linux app ID before a Flathub submission.
