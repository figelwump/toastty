# Toastty Manual Interaction Scripting

Click into the target terminal panel before typing. Activation alone is insufficient.

Before required local GUI scripting or `peekaboo`, run `peekaboo permissions --json`. If Accessibility is missing, stop and ask the user to grant it before continuing locally. If remote validation can cover the check and the user does not want to grant local Accessibility, use the remote validation path instead.

```bash
osascript <<'OSA'
tell application "Toastty" to activate
delay 0.5
tell application "System Events"
  click at {720, 360}
  delay 0.2
  keystroke "ls -l"
  key code 36
end tell
OSA
```

- Coordinates are absolute screen coordinates; adjust per display layout.
- `key code 36` is Return and is layout-independent.
- Clipboard paste is more reliable than `keystroke` for non-US layouts.
- Tune delay values upward if focus races occur.
