# Toastty Release on Linux

Linux packages come from `scripts/linux/package.sh`. Design, constraints and
open decisions: `docs/plans/linux-release.md`. Publishing (GitHub Releases,
Flathub, Snap Store) is not set up yet; stop after the build and hand off.

## Validate first

All Linux validation is local. Never run `gnome-shell --headless`, and never
drive or replace the user's installed Toastty.

1. `scripts/automation/check.sh` (runs `scripts/linux/check.sh` on Linux):
   self-tests, web panel tests, the Ghostty widget test, debug and release
   builds, smoke scripts and the release install end-to-end on private
   Broadway displays, then `scripts/linux/test.sh`.
2. One real-window check of the release build for OpenGL, because Broadway
   always uses the offscreen renderer. Tell the user a window will open, then:
   ```bash
   TOASTTY_DEV_WORKTREE_ROOT="$PWD" linux/.build/release/toastty-linux \
     >artifacts/dev-runs/release-gl.log 2>&1 &
   ```
   Check that a terminal renders and takes input without lag, that a web panel
   renders, and that the log has no GL or WebKit renderer errors. Close it when
   done.

## Build

```bash
scripts/linux/package.sh --version X.Y.Z --build-number N [--format deb|appimage|snap|flatpak]...
```

- Output: `artifacts/release/linux/<version>-<build>/` with the packages and
  `package-metadata.env` (version, source commit, dirty flag, glibc floor,
  artifact paths). Build from a clean tree for a release.
- `.deb`: needs `dpkg-deb` and `fakeroot`. `Depends:` is computed from the
  binaries' direct links. The maintainer comes from `DEBFULLNAME`/`DEBEMAIL`,
  else the git identity.
- AppImage: needs `appimagetool` (`APPIMAGETOOL=…`, on `PATH`, or
  `linux/.deps/tools/appimagetool-x86_64.AppImage`). The script does not
  download it.
- snap and Flatpak: drafts (`linux/packaging/`) that need `snapcraft` or
  `flatpak-builder`, both installed with root. Ask the user before building
  them.
- Check a `.deb` without installing it: extract it with `dpkg-deb -x` and run
  `TOASTTY_LINUX_E2E_BIN=<dir>/usr/lib/toastty/bin scripts/linux/e2e-app-logic.sh`.

Handoff: the package paths (repo-relative), `package-metadata.env`, the
validation results (offscreen and real window), and the glibc floor.
