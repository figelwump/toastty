# Keyboard Shortcuts

Toastty keeps the high-frequency workspace, pane, and agent actions on the keyboard. This reference groups the built-in shortcuts by task.

## Core window and workspace actions

| Shortcut | Action |
|---|---|
| `Cmd+N` | New window |
| `Cmd+T` | New tab |
| `Cmd+B` | Show or hide the sidebar |
| `Cmd+Shift+N` | New workspace |
| `Cmd+Shift+E` | Rename workspace |
| `Option+Shift+E` | Rename tab |
| `Cmd+Shift+W` | Close workspace |
| `Cmd+W` | Close focused panel |

`Cmd+W` and `File > Close` both use Toastty's panel-close behavior. Dirty local-document drafts ask before discard, panels with a local-document save in progress refuse destructive close, and the native red close button still asks for confirmation before closing the full window.

`Cmd+Q` follows `Toastty > Ask Before Quitting`; when enabled, Toastty warns before quitting if terminal work may still be running or local-document drafts would be discarded, and it refuses destructive quit while a local-document save is still in progress. Choosing `Always quit without asking` in that alert turns the setting off.

## Pane and layout actions

| Shortcut | Action |
|---|---|
| `Cmd+D` | Split horizontally |
| `Cmd+Shift+D` | Split vertically |
| `Cmd+Ctrl+B` | New browser in the current tab layout |
| `Cmd+Ctrl+Shift+B` | New browser tab |
| `Cmd+[` | Focus previous pane |
| `Cmd+]` | Focus next pane |
| `Cmd+Opt+Left Arrow` | Focus pane to the left |
| `Cmd+Opt+Right Arrow` | Focus pane to the right |
| `Cmd+Opt+Up Arrow` | Focus pane above |
| `Cmd+Opt+Down Arrow` | Focus pane below |
| `Cmd+Shift+F` | Toggle focused panel (zoom) |
| `Cmd+Shift+A` | Jump to the next unread panel, then panels needing approval or errors, then working panels |
| `Cmd+Ctrl+Left Arrow` | Resize split left |
| `Cmd+Ctrl+Right Arrow` | Resize split right |
| `Cmd+Ctrl+Up Arrow` | Resize split up |
| `Cmd+Ctrl+Down Arrow` | Resize split down |
| `Cmd+Ctrl+=` | Equalize splits |

## Tab and workspace selection

| Shortcut | Action |
|---|---|
| `Option+1`–`Option+9` | Switch workspace |
| `Cmd+1`–`Cmd+9` | Switch tab |
| `Cmd+Shift+[` | Previous tab |
| `Cmd+Shift+]` | Next tab |
| `Option+Shift+[` | Previous tab (wrapping, terminal-proof) |
| `Option+Shift+]` | Next tab (wrapping, terminal-proof) |
| `Option+Shift+1`–`Option+Shift+0` | Focus pane by position |

## Command palette

| Shortcut | Action |
|---|---|
| `Cmd+Shift+P` | Open the command palette |

## Search

| Shortcut | Action |
|---|---|
| `Cmd+F` | Find in active terminal scrollback |
| `Cmd+G` | Find next match |
| `Cmd+Shift+G` | Find previous match |

## Text size and zoom

These shortcuts target the focused panel type:

- focused terminal: adjust the window's terminal font size
- focused local document panel: adjust the window's local-document text size
- focused browser panel: zoom the current browser panel

| Shortcut | Action |
|---|---|
| `Cmd+=` / `Cmd+Shift+=` | Increase text size or zoom |
| `Cmd+-` | Decrease text size or zoom |
| `Cmd+0` | Reset text size or zoom |

When a browser is focused, the `View` menu shows `Zoom In`, `Zoom Out`, and `Actual Size` instead of the text-size labels used for terminals and local documents.

## Browser

These shortcuts are available when the focused panel is a browser panel:

| Shortcut | Action |
|---|---|
| `Cmd+L` | Focus the browser location field |
| `Cmd+R` | Reload the current page, or stop while a page is loading |

## Local documents

These shortcuts are available when the focused panel is a local document in edit mode. Supported local documents currently include Markdown, YAML, TOML, JSON, JSON Lines, config/property files, CSV/TSV, XML, and shell scripts.

| Shortcut | Action |
|---|---|
| `Cmd+S` | Save the current draft |
| `Escape` | Cancel edit mode and discard the current draft |

## Agents and terminal profiles

These shortcuts depend on configured profiles:

| Shortcut | Action |
|---|---|
| `Cmd+Opt+<key>` | Launch agent profile when the profile defines `shortcutKey` |
| `Cmd+Opt+<key>` | Split right with a terminal profile when the profile defines `shortcutKey` |
| `Cmd+Opt+Shift+<key>` | Split down with a terminal profile when the profile defines `shortcutKey` |

Configured agent profiles also appear in the command palette as `Run Agent: <Display Name>`. Configured terminal profiles appear there as `Split Right With <Display Name>` and `Split Down With <Display Name>` when the focused pane can split.

For agent setup details, see [running-agents.md](running-agents.md). For terminal profile setup details, see [terminal-profiles.md](terminal-profiles.md).
