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

`Cmd+W` and `File > Close` both use Toastty's panel-close behavior. The native red close button still asks for confirmation before closing the full window.

## Pane and layout actions

| Shortcut | Action |
|---|---|
| `Cmd+D` | Split horizontally |
| `Cmd+Shift+D` | Split vertically |
| `Cmd+[` | Focus previous pane |
| `Cmd+]` | Focus next pane |
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

## Search

| Shortcut | Action |
|---|---|
| `Cmd+F` | Find in active terminal scrollback |
| `Cmd+G` | Find next match |
| `Cmd+Shift+G` | Find previous match |

## Browser

These shortcuts are available when the focused panel is a browser panel:

| Shortcut | Action |
|---|---|
| `Cmd+L` | Focus the browser location field |
| `Cmd+R` | Reload the current page, or stop while a page is loading |

## Agents and terminal profiles

These shortcuts depend on configured profiles:

| Shortcut | Action |
|---|---|
| `Cmd+Ctrl+<key>` | Launch agent profile when the profile defines `shortcutKey` |
| `Cmd+Ctrl+<key>` | Split right with a terminal profile when the profile defines `shortcutKey` |
| `Cmd+Ctrl+Shift+<key>` | Split down with a terminal profile when the profile defines `shortcutKey` |

For agent setup details, see [running-agents.md](running-agents.md). For terminal profile setup details, see [terminal-profiles.md](terminal-profiles.md).
