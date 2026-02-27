# Ghostty integration notes

Date: 2026-02-27

## Spike status

Status: blocked pending Ghostty build prerequisites.

Findings:
- `zig` is not installed on this machine.
- no local `GhosttyKit.xcframework` cache was found under `$HOME/.cache`.

Impact:
- full Ghostty spike (phase 0 step 1) cannot be validated yet.
- implementation is currently scaffold-first with a placeholder terminal representation while keeping state/runtime boundaries aligned with the plan.

Next actions:
1. install `zig` and verify version required by Ghostty build scripts.
2. clone Ghostty source and build `GhosttyKit.xcframework`.
3. wire a `GhosttySurfaceController` spike app and document attach/detach/reparent/focus/resize behavior.
