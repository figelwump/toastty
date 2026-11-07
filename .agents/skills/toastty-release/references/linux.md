# Toastty Release on Linux

Linux ships a `.deb` and an AppImage on the same GitHub Release as the macOS
DMG: same version, same `v<version>` tag, built from the same commit. Snap and
Flatpak recipes exist (`linux/packaging/`) but are not published yet; build
them only when the user asks. Design and decisions:
`docs/plans/linux-release.md`.

All Linux validation is local. Never run `gnome-shell --headless`, never drive
or replace the user's installed Toastty, and never install a package with
`sudo` yourself: ask the user to run the install command.

## 1. Validate the release commit

Check out the release commit on a clean tree (the commit the macOS release
recorded as `RELEASE_SOURCE_COMMIT`, which the macOS publish tags as
`v<version>`). Then:

1. `scripts/automation/check.sh` (runs `scripts/linux/check.sh` on Linux):
   self-tests, web panel tests, the Ghostty widget test, builds, smoke
   scripts, the release install end-to-end and an agent-free package test on
   private Broadway displays, then `scripts/linux/test.sh`.

## 2. Build the packages

```bash
scripts/linux/fetch-appimagetool.sh        # pinned appimagetool, checksum-verified
scripts/linux/package.sh --version X.Y.Z --build-number N
```

- Output: `artifacts/release/linux/<version>-<build>/` with
  `toastty_<version>-<build>_amd64.deb`, `Toastty-<version>-x86_64.AppImage`,
  its `.zsync`, and `package-metadata.env` (version, source commit, dirty flag,
  glibc floor, artifact paths). `TOASTTY_LINUX_SOURCE_DIRTY` must be `0`;
  publishing refuses a dirty build.
- The `.deb` `Depends:` comes from the binaries' direct links; the maintainer
  from `DEBFULLNAME`/`DEBEMAIL`, else the git identity.
- The AppImage bundles Toastty, the Swift runtime and Ghostty, and uses the
  host's GTK 4, libadwaita and WebKitGTK 6.0. Its update information points
  AppImage updaters at the latest GitHub Release's `.zsync`.
- Both need glibc at least the build host's (`TOASTTY_LINUX_GLIBC`).

## 3. Test the packaged apps

Install and launch each package and check what a user does first. This is
required before publishing.

1. Offscreen, both packages, with agents:
   ```bash
   scripts/linux/test-package.sh --release-dir artifacts/release/linux/<version>-<build>
   ```
   For each package it launches the app (the AppImage from the image file
   itself, as users run it), takes a screenshot, runs a command in a terminal,
   launches Claude Code and Codex as managed agents in the repo root, sends
   each a one-word prompt, checks the answer and the hook-reported session
   status, then quits. The `.deb` is checked with `apt-get install --simulate`
   and run from a `dpkg-deb -x` root. Each instance has its own runtime home and
   socket, so it never touches the user's Toastty. Agent profiles and logins come
   from the user's home. An agent update offer is skipped with Esc and never
   accepted.
2. Real install of the `.deb`: ask the user to run
   `! sudo apt install ./artifacts/release/linux/<version>-<build>/toastty_<version>-<build>_amd64.deb`,
   then `scripts/linux/test-package.sh --deb <that file> --installed-deb`. This
   tests `/usr/lib/toastty` and the installed desktop entry. Skip it when the
   user declines; the extracted-root run above covers the payload.
3. Real window, for OpenGL (Broadway always uses the offscreen renderer). Tell
   the user a window will open, then:
   ```bash
   scripts/linux/test-package.sh --release-dir artifacts/release/linux/<version>-<build> --real-window
   ```
   Its screenshots show the terminal as rendered by the GPU path; check the
   report's log check for GL or WebKit renderer errors.

Read every screenshot under `artifacts/package-tests/<run>/<package>/screenshots/`
(launched, terminal, `<agent>-launched`, `<agent>-answered`), not only
`report.md`. Present `report.md` and the screenshots to the user, for example
in a Scratchpad.

## 4. Publish

After the macOS publish created the tag and the release (draft or published,
see `../toastty-publish/SKILL.md`):

```bash
scripts/release/publish-linux-release.sh --version X.Y.Z --build-number N --dry-run
scripts/release/publish-linux-release.sh --version X.Y.Z --build-number N
```

It uploads the `.deb`, the AppImage, its `.zsync` and `SHA256SUMS-linux.txt`
to the `v<version>` release. It refuses a dirty build, a tag on origin that
names another commit, a missing release, or an asset that is already attached
(`--clobber` replaces). Uploading is outward-facing: run it only when the user
asks to publish. Add a Linux section to the release notes (install with
`sudo apt install ./toastty_….deb`, or `chmod +x` and run the AppImage;
glibc floor).

## Handoff

The package paths and `package-metadata.env` (repo-relative), the glibc floor,
the package test report path with its pass and fail counts, the screenshots
you read, which runs were offscreen and which in a real window, whether the
`.deb` was installed for real, and whether the assets were published.
