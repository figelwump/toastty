# Toastty Debug on Linux

The workflow in `SKILL.md` applies unchanged: answer first, identify the
target, use `instance.json`, test 2-3 hypotheses, and use scoped
instrumentation. Runtime isolation and `instance.json` are shared code. This
file only replaces paths, process names and repro routing.

## Targets and logs

| Target | Where to look |
|---|---|
| Installed app (`~/.local/lib/toastty/bin/toastty-linux`, launched from the desktop) | Log: `$XDG_STATE_HOME/toastty/toastty.log` (default `~/.local/state/toastty/toastty.log`). Crashes and stderr: `journalctl --user _COMM=toastty-linux` (the installed `swift-backtrace` writes crash backtraces there). |
| Worktree, dev or test run | `instance.json` under `artifacts/dev-runs/worktree-*/runtime-home/` (or the run's `TOASTTY_RUNTIME_HOME`), then its `logFilePath`. Its stderr goes wherever the launch redirected it. |
| Linux test run | `scripts/linux/test.sh` deletes its isolation directory on exit. Rerun with `TOASTTY_LINUX_TEST_KEEP=1` to keep homes, logs and sockets. |

- Sockets: the live app uses `$XDG_RUNTIME_DIR/toastty/events-v1-<pid>.sock`,
  and an isolated run uses `$XDG_RUNTIME_DIR/toastty-runtime-<hash>/events-v1.sock`.
  Prefer the `socketPath` in `instance.json`.
- Processes: `ps -o pid,args -C toastty-linux` lists the app processes (the
  user's installed one included: identify yours by the PID in `instance.json`
  or the `$!` of your launch, never kill by name). Avoid `pgrep -f toastty`
  from an agent shell: the pattern matches the shell's own command line. Then
  `ls -l /proc/<pid>/fd | grep toastty.log` shows the log it writes.
- A worktree-derived runtime home is reused across runs: its log appends and
  `instance.json` names only the latest run. Note the log's line count (or the
  time) before you launch and read only what follows, or launch with a fresh
  `TOASTTY_RUNTIME_HOME` (`toastty-dev-run` `references/linux.md`). stderr only
  gets log lines with `TOASTTY_LOG_STDERR=1`.
- A shell inside Toastty has `TOASTTY_*` variables pointing at the live app.
  Do not let them leak into a repro: use `env -i` or explicit
  `--socket-path`. Read-only queries against the live app (`query run …`)
  are fine; actions, GUI driving and restarts are not.

## Linux-specific evidence

- Terminal: `TOASTTY_LINUX_TERMINAL_DEBUG=1` logs Ghostty actions and bridge
  events, `TOASTTY_GHOSTTY_LATENCY_TRACE=1` prints per-key latency, and
  `TOASTTY_GHOSTTY_RENDERER=gl|offscreen` forces the renderer. Ghostty
  sources with Toastty's patches applied are in `linux/.deps/ghostty-src`
  (the patches are in `linux/ghostty/patches/`).
- Shared versus Linux code: shared `Sources/` files compile on Linux from the
  mirrors in `linux/.generated/`. Read and edit the originals, because the
  mirrors' `#sourceLocation` points errors back at them. Linux-only
  behaviour in shared files sits in `#if os(Linux)` blocks listed in
  `docs/linux.md` under "Shared files with Linux guards".
- Hangs: `gdb -p <pid> -batch -ex 'thread apply all bt'` on a run you
  started. Use `handle SIGPIPE nostop noprint pass` when running under gdb,
  because Ghostty's IO threads see SIGPIPE normally.
- Rendering and GPU: WebKit and GL behaviour differs on the user's NVIDIA
  desktop (see `WebKitRendererSelection.swift`). Broadway always uses the
  offscreen renderer, so reproduce GPU symptoms in a real window.

## Repro routing

Reproduce locally (`references/linux.md` in `toastty-dev-run`): on a private
Broadway display by default, and in a real, runtime-isolated window only for
OpenGL or GPU symptoms. There is no remote GUI or Computer Use path on Linux.
Never run `gnome-shell --headless`. Turn durable repros into Broadway tests
under `linux/Tests/` or into the Ghostty widget test
(`linux/ghostty/test/toastty-ghostty-test.c`).
