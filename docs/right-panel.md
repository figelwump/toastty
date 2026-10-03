# Right Panel

The right panel is a workspace-side tab strip for supporting material that should stay next to the active terminal instead of taking over the main pane layout. Use it for Scratchpad notes, browser panels, and local documents while the main workspace remains focused on terminals and splits.

## Tabs, visibility, and shortcuts

Each horizontal workspace tab keeps its own right-panel tabs, active tab, width, and visibility in the persisted layout. `Cmd+Shift+B` shows or hides the right panel; when showing it, Toastty focuses the active right-panel tab if one exists. `Cmd+Ctrl+[` and `Cmd+Ctrl+]` cycle through right-panel tabs, `Cmd+Ctrl+B` opens a new browser there, and `Cmd+Ctrl+S` creates a new Scratchpad.

## Recently Opened

Toastty keeps up to 20 local Recently Opened items for browsers, local documents, and Scratchpads. Open the list from the empty right-panel view or the right-panel Add menu to reopen supporting material without navigating back to its original workspace tab.

## Scratchpad binding

`Cmd+Ctrl+S` starts an unbound manual Scratchpad. A live managed session's terminal-header link menu lists the Scratchpads in its workspace tab. Check several titles to bind them to that session, or choose **New Scratchpad** to create another bound document. A Scratchpad can belong to only one session; selecting a row labeled **Move from [session]** transfers its binding to this session. The binding chip in the Scratchpad header also lets you attach it to an active Toastty-managed agent session in the same workspace tab.

Use **Edit Details…** to give each Scratchpad a title and optional purpose. **Make Default** chooses which document receives session-only agent commands; selecting a visible panel does not change that default. Closing a Scratchpad removes its binding while retaining its saved content, and reopening starts it unbound. Supported managed Codex, Claude Code, Cursor, Grok Build, OpenCode, MiMo Code, and Pi sessions receive the `toastty-scratchpad` skill automatically, so you can usually ask the agent for a visual and let it create and bind its own Scratchpad on demand.

## Browser header actions

Browser panel header actions can open the current page in the default browser, copy or save the visible page screenshot, insert a temporary PNG path into an active Toastty-managed agent session in the same workspace tab, or annotate the page with numbered comments and send that visual feedback to an active agent.

## Annotation mode

Browser and Scratchpad panels both offer annotation mode from the pencil button in the panel header. Click to mark a point or drag to mark a region, add a comment, then send the numbered screenshots and comments to an active agent in the same workspace tab. Drag the heading of a comment dialog to move it out of the way. Scratchpad annotations reset when the panel requests a fresh render, including content revisions, theme changes, and binding changes.

## Links and history

Clicked HTTP and HTTPS links in a Scratchpad open a new embedded browser tab in the right panel. Links to sections within the Scratchpad stay in the document.

Right-click or `Control`-click browser and Scratchpad content to use the panel's available **Back** and **Forward** history actions.

## Terminal command-click routing

Terminal command-click integrations use Toastty for common supporting files: supported local documents open as editable local-document tabs, local HTML files open in the browser, directories open terminal splits, and existing unsupported local files open in their macOS default app. The `local-document-opening-*` and `url-opening-*` keys in [Configuration](configuration.md) choose whether local-document and local HTML opens use the right panel or a new tab.

## Related docs

- [README](../README.md)
- [Keyboard Shortcuts](keyboard-shortcuts.md)
- [Configuration](configuration.md)
- [Running Agents](running-agents.md)
