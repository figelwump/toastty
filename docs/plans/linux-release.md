# Linux release packaging

Status: in progress. The `.deb` builds and passes the end-to-end checks from
its extracted tree. The AppImage step is written but unbuilt: it needs an
`appimagetool` binary supplied by the operator. The Flatpak and snap recipes
are drafts until `flatpak-builder` and `snapcraft` are installed (both need
root to install).

## Goal

Ship the Linux port as `.deb`, AppImage, Flatpak and snap from one release
build, with the same validation for all four. Validation is local: offscreen
on Broadway, plus one real-window check for OpenGL (see
`.agents/skills/toastty-release/SKILL.md` and
`.agents/skills/toastty-verify/references/linux.md`).

## Shared shape

`scripts/linux/package.sh` builds the release products once, then stages them
with `scripts/linux/install.sh --prefix /usr --destdir <stage>`. That layout
is already relocatable: binaries use `$ORIGIN` RUNPATHs, the Swift runtime,
`libghostty` and the GTK widget are bundled under `lib/toastty/lib`, and the
app finds its resources relative to the executable. Each format wraps the
same stage:

| Format | Wraps the stage as | System libraries | Confinement |
|---|---|---|---|
| `.deb` | `/usr` tree + `DEBIAN/control` | From the distro (`Depends:` computed from `ldd`) | None |
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
  launch. Agent hooks must not record the mounted CLI path. Verify how the
  hooks reference the CLI before shipping the AppImage.

## Open questions for the user

1. Distribution channels: GitHub Releases for `.deb`/AppImage, Flathub, Snap
   Store (classic review), or a subset.
2. Version coupling with the macOS release (same version and tag, or a
   separate Linux track).
3. Updates: AppImage update information (zsync), store updates for
   Flatpak/snap, an apt repository for `.deb`, or a GitHub-release check in the
   app.
4. Whether to set up an older-base build environment to lower the glibc floor.
5. The app ID. `appstreamcli validate` rejects `com.GiantThings.toastty`
   (`cid-domain-not-lowercase`), and Flathub requires a valid AppStream file.
   Renaming it (for example `com.giantthings.Toastty`) also changes the
   GApplication ID, the desktop file name and the notification and badge
   identities, so existing installs would need a migration.
