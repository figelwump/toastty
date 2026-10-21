# Toastty on Linux

Working notes for the Ubuntu port (branch `feat/linux-port`). The plan and
architecture live in `docs/plans/linux-port.md`; this file covers how to build
and test, and which shared files carry Linux-specific code.

## Toolchain

No root is required. `source linux/env.sh` puts Swift 6.4.1
(`~/.local/toolchains/swift-6.4.1-RELEASE-ubuntu26.04`) on `PATH` and points
`PKG_CONFIG_PATH` at `linux/.sysroot`. The scripts below source it themselves.

## Build

```bash
scripts/linux/build.sh                      # sync mirrors + debug build of everything
scripts/linux/build.sh --release            # release build
scripts/linux/build.sh --product toastty --product toastty-agent-shim
scripts/linux/build.sh --target CoreState   # one module
scripts/linux/build.sh --shared-only        # only the shared-core subset (see below)
```

Every invocation first runs `scripts/linux/sync-shared-sources.py`, which
mirrors the shared files listed in `linux/shared-sources.json` into
`linux/.generated/<Target>/` (see the script's docstring for the manifest
format). Edit the originals under `Sources/` and `Tests/`, never the mirrors.

Products land in `linux/.build/debug/` (or `release/`).

## Test

```bash
scripts/linux/test.sh                        # all test targets
scripts/linux/test.sh CoreStateTests         # swift test --filter
scripts/linux/test.sh --shared-only          # shared-core tests only
```

`test.sh` builds with your normal environment, then runs `swift test
--skip-build` with an isolated environment under a fresh
`$XDG_RUNTIME_DIR/toastty-tests.XXXXXX` (falling back to `~/.cache`):
`HOME`, `CFFIXED_USER_HOME` (Linux Foundation's `NSHomeDirectory()` ignores
`$HOME`), `TMPDIR`, and all `XDG_*` directories point inside it, and
inherited `TOASTTY_*`, `CODEX_*`, and `CLAUDE*` variables are removed. The
temp directory deliberately avoids `/tmp` (a stray `/tmp/.git` breaks the
repository-root tests) and any git checkout, and is short enough for 108-byte
`AF_UNIX` socket paths. `TOASTTY_LINUX_TEST_KEEP=1` keeps it for inspection.
Without a FILTER each test target runs as its own `swift test --filter
'^<Target>\.'` with a fresh isolation directory (SwiftPM links every target
into one test runner, so one home would be shared across workstreams'
suites). The test processes' `PATH` drops `~/.local/bin` and `~/bin`, so
installed agent CLIs (`codex`, `claude`) do not change what launch tests plan;
tests that need a real agent CLI skip. Swift Testing runs serially
(`--no-parallel`; `TOASTTY_LINUX_TEST_PARALLEL=1` restores the default): the
App-layer suites share process-wide state (UserDefaults, environment,
`NotificationCenter`, platform services) and race in parallel.

`--shared-only` (both scripts) uses `linux/.shared-only/`, a generated package
holding only the block between `// MARK: shared-core` and
`// MARK: end shared-core` in `linux/Package.swift` (written by
`scripts/linux/shared-only-package.py`). Use it when frontend targets in the
full package do not compile yet.

`--app-logic` (both scripts) builds `linux/.app-logic-only/`: the
shared-core and app-logic blocks without the GTK targets, so
`scripts/linux/test.sh --app-logic ToasttyAppLogicTests` works while a
frontend is mid-change. Tests run with `umask 022` (macOS default):
Toastty's ownership checks reject group-writable directories, which Ubuntu's
default user umask creates.

`ToasttyAppLogicTests` mirrors the portable `Tests/App` files (the manifest
`include` list) plus `linux/Tests/ToasttyAppLogicTests`:
`LinuxAppLogicIntegrationTests` (bootstraps `LinuxAppLogic` in automation
mode; the Linux `toastty` CLI runs `query list`, `action list`,
`action run workspace.create`, `query run workspace.list` against the real
socket; `session start` + `session ingest-agent-event --source claude-hooks`
moves the panel's session to working, then ready; the terminal seam carries
the launch environment and `terminal.send-text` / `terminal.visible-text`
reach a recording surface; terminal link clicks follow the macOS
command-click rules (Markdown → local-document panel, https → browser panel,
`mailto:` → the platform opener), a browser popup to a local HTML file opens
a browser panel, `performAppCommand("scratchpad.create")` opens a
Scratchpad, and an OSC 9 desktop notification from a background workspace is
delivered through the platform services and its click-through
(`LinuxPlatform.handleNotificationActivation`) focuses the terminal again;
Remote Access pairs a fake native client over the
gateway — QR offer, `/v1/native-pairing/exchange`, `/api/sessions` with the
Bearer credential, `/api/subscribe` WebSocket session list),
`LinuxGatewayWebSocketTests` (device revoke and disconnect-all close sockets
with 1008, with an RFC 6455 client of our own), and `LinuxShimTests` (QR
symbols decoded back by an independent reader — format BCH, unmasking, RS
syndromes, byte segment — plus version selection; PNG output; Network shim
echo and EADDRINUSE mapping; inotify file observation; CombineLatest; alert,
URL, clipboard, notification, window and screen shims; RelativeDateTimeFormatter).

Shared test targets: `CoreStateTests` (`Tests/Core`, which also holds the
RemoteProtocol golden-fixture tests), `ToasttyCLITests` (`Tests/CLI`,
including the Claude/Codex/Cursor/Grok/OpenCode/MimoCode/Pi hook parsers),
`CodexReconciliationTests` (`Tests/CodexReconciliation`). Fixtures are read in
place through `#filePath`, which `#sourceLocation` points at the original tree.

## Runtime paths on Linux

User configuration stays in `~/.toastty` exactly as on macOS: `config`,
`agents.toml`, terminal profiles, hooks, skills, history, scratchpad
documents, remote-access state, and the agent shim `bin/`. Runtime isolation
(`TOASTTY_RUNTIME_HOME`, `TOASTTY_DEV_WORKTREE_ROOT`, `TOASTTY_RUNTIME_LABEL`)
behaves the same: an isolated runtime home owns its config, `logs/`, and
`instance.json`.

| macOS | Linux |
|---|---|
| `~/Library/Logs/Toastty/toastty.log` | `$XDG_STATE_HOME/toastty/toastty.log` (default `~/.local/state/...`) |
| `$TMPDIR/toastty-<uid>/events-v1-<pid>.sock` | `$XDG_RUNTIME_DIR/toastty/events-v1-<pid>.sock` |
| `$TMPDIR/toastty-runtime-<hash>/events-v1.sock` (isolated runtime) | `$XDG_RUNTIME_DIR/toastty-runtime-<hash>/events-v1.sock` |
| UserDefaults suite `com.GiantThings.toastty.runtime.<hash>` | same suite name; swift-corelibs stores it as `$XDG_CONFIG_HOME/<suite>.plist` |

If `$XDG_RUNTIME_DIR` is unset, relative, or missing, socket paths fall back
to the macOS layout under `$TMPDIR` (or `/tmp`). Callers that pass an explicit
environment without `XDG_RUNTIME_DIR` (most tests) therefore keep the macOS
`TMPDIR` behavior. A relative `XDG_STATE_HOME` is ignored per the XDG spec.
Note `UserDefaults.standard` on Linux uses the executable name as its domain
(`$XDG_CONFIG_HOME/<executable>.plist`, e.g. `toastty-linux.plist`).
swift-corelibs-foundation writes that plist only on `synchronize()` (no
background flush, nothing at exit), so `ToasttyAppDefaults` on Linux writes
every change through; anything that bypasses `ToasttyAppDefaults.current`
must call `synchronize()` itself.

Nothing in the shared modules uses Application Support or Caches, so no XDG
data/cache mapping is needed there yet.

## Linux shims

`linux/Sources/Shims/ToasttyFoundationShim` is implicitly imported into every
mirrored shared target (`implicitImports` in `linux/shared-sources.json`). It
provides only what swift-corelibs-foundation and Glibc lack, under the Darwin
spelling shared code already uses:

- `AttributedString(markdown:)`: built with swift-markdown (cmark-gfm), with
  the same `link` runs Apple's parser produces (code spans/blocks and images
  carry no link). Used by `RemotePreviewLinkReference`.
- `stat.st_mtimespec` / `st_ctimespec` / `st_atimespec`, `MAXPATHLEN`.
- `F_FULLFSYNC`: an invalid fcntl command, so shared code falls back to
  `fsync(2)`, which already flushes the device cache on Linux.
- `socket(_:_:_:)` overload accepting Glibc's `__socket_type`
  (`SOCK_STREAM`), `__darwin_suseconds_t`.
- `posix_spawn` overload with Darwin's optional `argv`/`envp` pointers.
- `stderr`/`stdout` as constants (Glibc's mutable globals fail Swift 6
  concurrency checking).
- `_NSGetExecutablePath`, backed by `/proc/self/exe`.

`ToasttyCLIKit` and its tests also import `FoundationNetworking` (URLSession,
URLRequest) implicitly.

## App logic (`ToasttyAppLogic`)

`ToasttyAppLogic` (block `// MARK: app-logic` in `linux/Package.swift`) is the
UI-free part of `Sources/App` compiled for Linux: `AppStore`, the automation
socket server and command executor, AppControl, managed agents (catalog,
launch planner/service, command shims, helper staging, skills managers,
Codex integration and log watcher), hook dispatch, `SessionRuntimeStore`,
workspace merge, layout persistence, notifications, preferences/config,
routing, terminal profiles, the shared `TerminalRuntimeRegistry` (without
GhosttyKit), `WebPanelRuntimeRegistry`, Scratchpad documents, and the Remote
Access backend (gateway, service, Tailscale Serve, push relay, previews,
transcripts, session starter, pairing QR). Everything in `Sources/App` stays
module-internal; the frontend uses the public facade `LinuxAppLogic`.

```
ToasttyFoundationShim   (shared-core) Foundation/Glibc gaps
ToasttyAppKitShim       AppKit, UserNotifications, CoreGraphics session,
                        UniformTypeIdentifiers, the few SwiftUI value types
                        (KeyEquivalent, EventModifiers, Font.Weight, Text.TruncationMode,
                        UnitPoint, FocusedValues), Combine gaps (CombineLatest),
                        Foundation gaps (RelativeDateTimeFormatter,
                        NSString.stringEncoding/abbreviatingWithTildeInPath,
                        AttributedString markdown options, URLSession.bytes(for:),
                        inotify-backed DispatchSource.makeFileSystemObjectSource,
                        Darwin libc spellings), LinuxPlatformServices
ToasttyNetworkShim      NWListener/NWConnection/NWParameters/NWError over POSIX sockets
ToasttyAppLogic         mirrored Sources/App subset + linux/Sources/ToasttyAppLogic
ToasttyAppLogicTests    mirrored Tests/App subset + linux/Tests/ToasttyAppLogicTests
```

Mirroring (see `scripts/linux/sync-shared-sources.py`): the App targets use
`exclude` (views, Ghostty host, WebKit runtimes), `extraSources` (Linux-only
directories that must share the module, plus two `Tests/Core` fixtures),
`importRewrites` (`SwiftUI` → `ToasttyAppKitShim`; tests'
`@testable import ToasttyApp` → `ToasttyAppLogic`), and `darwinQualifier`
(`Darwin.` → `ToasttyAppKitShim.`, which re-exports Glibc and adds
Darwin-only calls), and `textRewrites` (`.st_mtimespec` → `.st_mtim` and
friends: fresh SwiftPM builds intermittently missed ToasttyFoundationShim's
`stat` extension members in this target; `.receive(on: RunLoop.main)` and
`scheduler: RunLoop.main)` → `DispatchQueue.main` in `RemoteAccessService`:
both are the main thread in the app, but only the main queue runs where
nothing spins `RunLoop.main`, such as Swift Testing's `dispatchMain`). Implicit imports: ToasttyFoundationShim,
FoundationNetworking, OpenCombine(+Foundation, Dispatch), ToasttyAppKitShim.

Build/test only these targets while other frontends are mid-change:

```bash
cd linux && source env.sh
swift build --target ToasttyAppLogic           # library
scripts/linux/test.sh --app-logic              # app-logic tests only (see Test)
```

### Bootstrap and facade (`LinuxAppLogic`)

`LinuxAppLogic(options:)` (`linux/Sources/ToasttyAppLogic/Bootstrap/`)
builds the app in the order of `ToasttyApp.init`: runtime environment →
setup templates → config/settings → layout restore (`AppBootstrap.make`) →
socket path + `instance.json` → `AppStore` → agent/terminal-profile catalogs →
terminal and web runtime registries → helper staging (`toastty`,
`toastty-agent-shim` next to the executable unless `Options` overrides) +
agent command shims → terminal launch environment → hook dispatcher →
`SessionRuntimeStore` → merge coordinator, annotations, notification routing →
config state → skills managers + `AgentLaunchService` → `RemoteAccessService`
(starts the gateway when Remote Access was left on) → layout persistence →
automation socket → Codex hook maintenance. It reads this process's arguments
and environment exactly like macOS (`--automation`/`TOASTTY_AUTOMATION`,
`TOASTTY_RUNTIME_HOME`, `TOASTTY_SOCKET_PATH`, ...). SIGPIPE is ignored
process-wide. Resources: `Options.appResourcesPath`, else
`$TOASTTY_APP_RESOURCES_PATH`, `<exe>/../share/toastty/Resources`,
`<exe>/Resources`, or the checkout's `Sources/App/Resources`; the resolved
path is exported as `TOASTTY_APP_RESOURCES_PATH`.

Facade (all `@MainActor`):

| Area | API |
|---|---|
| Lifecycle | `markAutomationReady()` (after the first window shows), `shutdown(reason:)` (flushes layout, stops servers), `flushPersistedLayout(reason:)`, `reloadConfiguration()`, `socketPath`, `cliExecutablePath`, `agentShimExecutablePath`, `appResourcesPath`, `automationStartupError`, `isAutomationMode`, `runtimeHomePath` |
| State | `state: AppState`, `send(_:source:) -> Bool` (through `AppStore.send`), `statePublisher: AnyPublisher<AppState, Never>`, `observeState(_:) -> LinuxAppLogicSubscription` (fires now and after each change), `window(id:)` |
| Commands | `navigateBack()`, `navigateForward()`, `focusNextUnreadOrActivePanel(windowID:)`, `closeFocusedPanel(workspaceID:)`, `closePanel(panelID:)` (macOS confirmation rules via `NSAlert` → platform alerts), `watchRunningCommand(windowID:)` |
| Sessions | `sessionStatuses(workspaceID:)`, `sessionStatus(panelID:)`, `isLaterFlagged(sessionID:)`, `setLaterFlag(sessionID:isFlagged:)`, `observeSessions(_:)`, `sessionsWillChangePublisher` |
| Agents | `agentProfiles: [LinuxAgentProfileSummary]`, `launchAgent(profileID:workspaceID:panelID:) throws -> sessionID`, `agentCatalog`, `agentProfilesFilePath`, `observeAgentCatalog(_:)`, `canLaunchAgent(profileID:windowID:)`, `launchAgentFromUI(profileID:windowID:)` (the macOS `AgentLaunchUI` path: Codex status-hook preflight, async launch, failure alert) |
| Terminal seam | see below |
| Web panels | see below |
| Remote Access | `isRemoteAccessAvailable`, `remoteAccessStatus: LinuxRemoteAccessStatus?` (indicator/title/detail as on macOS, port, origin, devices, open offer's fallback code/expiry, `canIssuePairingOffer`), `remoteAccessWillChangePublisher`, `setRemoteAccessEnabled(_:)` (settings switch: listener + Tailscale Serve), `setRemoteAccessTailnetOrigin(_:)`, `retryRemoteAccessTailnetSetup()`, `issueRemoteAccessPairingOffer()`, `remoteAccessPairingQRCodePNG: Data?`, `cancelRemoteAccessPairingOffer()`, `revokeRemoteAccessDevice(_:)`, `revokeAllRemoteAccessDevices()` |

Agent launching in the GTK UI: `runWithAppLogic` hands the agent catalog and
an `AppLogicAgentLauncher` to `TerminalProfileShortcuts`, which turns each
profile into an `agent.run.<id>` command (macOS palette ids): a header button
per profile (macOS top bar; "Get Started…" when `agents.toml` has none, hidden
when `showsTopBarButtons = false`), a "Run Agent: <name>" palette entry, and a
`Ctrl+Alt+<shortcutKey>` launch (macOS Cmd+Opt). `ProfileShortcutRegistry`
resolves collisions with terminal-profile splits; windows rebuild their
shortcut matcher and buttons when either catalog reloads.

Window geometry: the window stores its unmaximized size
(`default-width`/`-height`, debounced) with `updateWindowFrame`; Wayland gives
no position, so `frame.x/y` keep their previous values. The sidebar and right
panel have drag handles (`SplitViewResizeHandle`) that send `setSidebarWidth`
(Linux default 248 pt, override clamped 160–480) and `setRightAuxPanelWidth`
(40% of the window until resized, then the stored width capped at 80%). All
three persist with the layout.

The GTK frontend runs on this layer (`TOASTTY_LINUX_APP_LOGIC`, defined for
`ToasttyLinuxUI`, which depends on `ToasttyAppLogic`):
`ToasttyLinuxMain.run` calls `runWithAppLogic`
(`linux/Sources/ToasttyLinux/UI/App/AppLogicStoreBinding.swift`), which
installs the main-loop integration, builds `LinuxAppLogic`, wraps it in
`AppLogicStoreBinding` (the `LinuxStoreBinding`: `state` = `displayState`,
`send` → `AppStore.send`, sessions → `SessionRuntimeStore`, app commands →
`performAppCommand`), installs `GtkPlatformServices`, attaches the WebKitGTK
panels (`webPanelHost.attach(logic:)`), installs Ghostty terminals with
`AppLogicTerminalRuntimeBridge` and the Remote Access UI, marks automation
ready after activation, quits on SIGTERM/SIGINT through the Quit path, and
calls `logic.shutdown()` on exit. Scripted UI runs (`TOASTTY_LINUX_SMOKE_SCRIPT`)
run as automation sessions with an isolated runtime home.
`TOASTTY_LINUX_REDUCER_STORE=1` keeps the old reducer-only binding.

App commands from `LinuxCommandTable` that need app-logic services go
through `logic.performAppCommand(_:windowID:)`: `app.reload-configuration`,
`navigation.back`/`forward`, `panel.focus-next-unread-or-active`,
`panel.process-watch.create`, `scratchpad.create`,
`scratchpad.show-current-session`, `app.config.manage`,
`terminal.profiles.manage`, `agent.profiles.manage` (open in a
local-document panel, like macOS), `agent.status-hooks.setup`,
`diagnostics.snippet.copy`.

End-to-end check on a private Broadway display:
`scripts/linux/e2e-app-logic.sh` (workspace creation over the socket + CLI,
`terminal.send-text`/`terminal.visible-text` through Ghostty, a fake managed
agent whose `session ingest-agent-event` makes its session working, layout
persistence across a SIGTERM restart, a scripted UI run whose
`scratchpad.create` window action reaches `performAppCommand` and opens a
Scratchpad panel, the Claude launch staging the shipped Toastty skills and
`toastty setup guide --topic workflows` naming an existing examples
directory, and background browser loading: after a restart, browser panels
in an unselected workspace load through `panel.browser.state` /
`panel.browser.reload` and report `finished`, or `failed` with WebKit's
error). `scripts/linux/e2e-install.sh` installs into a throwaway prefix,
checks the bundled skills, workflow examples and web panels, and runs the
same checks against the installed binaries (`TOASTTY_LINUX_E2E_BIN`).
`scripts/linux/socket-request.py` sends single raw socket requests (e.g.
`automation.dump_state`).

### Main loop integration (required)

`@MainActor` tasks, `DispatchQueue.main`, and `RunLoop.main` timers
(`debounce`, `Timer`) only run when something drains libdispatch's main
queue and runs CFRunLoop; `g_application_run` does neither. The frontend must
install, once, on the main thread:

```swift
if let fd = LinuxMainLoopIntegration.mainQueueFileDescriptor {
    g_unix_fd_add(fd, G_IO_IN) { LinuxMainLoopIntegration.drainMainQueue(); return true }
}
// Re-arm a GLib timeout for the returned date after every call:
let next = LinuxMainLoopIntegration.serviceRunLoop()
```

Without this the automation socket accepts connections but never answers
(its command executor hops to the main actor). `AppLogicMainLoop` in
`AppLogicStoreBinding.swift` installs exactly this (GIOChannel watch on the
eventfd, plus a ≤50 ms re-armed timeout for RunLoop timers). `Task { @MainActor }`
jobs are main-queue jobs, so the same watch runs them (the Broadway tests
exercise the coalesced-title tasks; a standalone check confirmed
`DispatchQueue.main.async`, `Task { @MainActor }` and `Timer` all fire). Swift
Testing parks the main thread in `dispatchMain()`, where the handle is
unavailable; the frontend must never call `dispatchMain()` or use an async
`main`.

Edits app-logic made in other workstreams' files for the wiring:
`linux/Package.swift` gtk-shell block (`ToasttyLinuxUI` depends on
`ToasttyAppLogic`, defines `TOASTTY_LINUX_APP_LOGIC`),
`UI/App/ToasttyLinuxMain.swift` (app-logic path), new
`UI/App/AppLogicStoreBinding.swift`, `UI/Terminal/AppLogicTerminalRuntimeBridge.swift`
(runtime events and links through the facade), `UI/Desktop/DesktopNotifications.swift`
(drops notifications when the application has no session bus, which would
otherwise trip GIO CRITICALs in DBus-less test runs).

### Platform services (`LinuxPlatformServices`)

`linux/Sources/Shims/ToasttyAppKitShim/LinuxPlatformServices.swift`. Shared
code keeps calling AppKit/UserNotifications names; the shims forward to
`LinuxPlatform.services` (install with `LinuxPlatform.install(_:)` or
`LinuxAppLogic.Options.platformServices`, before bootstrap):

| Requirement | Used for (AppKit call it replaces) | GTK implementation |
|---|---|---|
| `isApplicationActive` | `NSApp.isActive` (notification suppression, focus restore) | any window `is-active` |
| `activateApplication()` | `NSApp.activate` | present the last active window |
| `openURL(_:) -> Bool` | `NSWorkspace.open` (links, config files, folders) | `gtk_uri_launcher_launch` / `g_app_info_launch_default_for_uri` |
| `runModalAlert(_:) -> Int` | `NSAlert.runModal()`; returns the 0-based button index, OR `LinuxAlertResponse.suppressionFlag` if the suppression checkbox was checked | `AdwAlertDialog` + nested main loop |
| `presentAlert(_:windowID:completion:)` | `NSAlert.beginSheetModal` | `AdwAlertDialog` on that window |
| `writeClipboardString` / `readClipboardString` | `NSPasteboard.general` | `GdkClipboard` (read may return the last known value) |
| `setApplicationBadgeCount(_:)` | dock badge | `com.canonical.Unity.LauncherEntry` `count`/`count-visible` |
| `windowSnapshots()` | `NSApp.windows`, `keyWindow`, `mainWindow` (window IDs are Toastty window UUIDs; `hasTextInputFocus` stops focus restoration stealing from text entries) | your windows |
| `presentWindow(id:makeKey:)` | `makeKeyAndOrderFront`/`orderFront` | `gtk_window_present` |
| `screenSnapshots()` | `NSScreen.screens` (layout profile selection) | `GdkMonitor`s; post `LinuxPlatform.postScreenParametersChanged()` on change |
| `captureWindowPNG(id:)` | automation screenshots | `gtk_widget_snapshot` → texture → PNG |
| `userIdleSeconds()`, `isScreenLocked()` | Remote Access push gating | default queries Mutter IdleMonitor (gdbus) and logind `LockedHint` |
| `notificationAuthorization()`, `requestNotificationAuthorization()`, `deliverNotification(_:)`, `removeNotifications(identifiers:)` | `UNUserNotificationCenter` | `GNotification` (`g_application_send_notification`, id = `identifier`) |

Callbacks into the app: `LinuxPlatform.handleNotificationActivation(identifier:userInfo:)`
when a notification is clicked (routes to the panel exactly like macOS),
`LinuxPlatform.postApplicationActivationChange(isActive:)`,
`postScreenParametersChanged()`, `postApplicationWillTerminate()`.

Dock badge: nothing calls `setApplicationBadgeCount` (macOS shows no Dock
badge). The number Ubuntu Dock shows is its own count of Toastty's
notifications in GNOME's message tray, which outlive the app. So the GTK
frontend withdraws a notification once its panel (or workspace) is no
longer unread, withdraws all of them at quit, and at startup withdraws
whatever a crashed run left (`UI/Desktop/UnreadAttention.swift`; the ledger
is `linux-desktop-notifications.json` in the runtime's config directory).
`SeenUnreadClearScheduler` there ports macOS `WorkspaceView`'s seen-unread
clear (the focused unread panel of a shown workspace is marked read 300 ms
after it is on screen while Toastty is active); `WorkspaceView.swift` is
not part of the Linux build.

`HeadlessLinuxPlatformServices` is the default: `xdg-open`, alerts answered
with their cancel button (`LinuxAlertRequest.safeDefaultButtonIndex`) and
logged to stderr, notifications recorded and logged, a process-local
clipboard. Tests use its `alertResponder`, `urlOpener`, `deliveredNotifications`.

### Terminal runtime seam

Shared terminal logic compiles on Linux without `TOASTTY_HAS_GHOSTTY_KIT`:
`TerminalRuntimeRegistry`, `TerminalWindowRuntimeStore`,
`TerminalWorkspaceRuntime`, `TerminalControllerStore`,
`TerminalWindowRuntime(Context)`, `PanelHostLifecycle`, the focus
coordinator, live-title and read-activity stores. Everything that needs an
AppKit view or `ghostty_surface_t` is excluded: `TerminalSurfaceController`,
`TerminalHostView`, `TerminalHostGhosttySupport`, `TerminalSurfaceScrollView`,
`GhosttyRuntimeManager`, `GhosttySurfaceSemanticState`,
`GhosttyClipboardBridge`, `TerminalSurfaceDiagnostics` (the Ghostty-only
`TerminalMetadataService`, `TerminalActionRouter`,
`TerminalStoreActionCoordinator`, `TerminalWorkspaceMaintenanceService`
compile to nothing).

`linux/Sources/ToasttyAppLogic/Terminal/LinuxTerminalSurface.swift` replaces
`TerminalSurfaceController` with the same registry-facing API and forwards to
a frontend object:

```swift
@MainActor public protocol LinuxTerminalSurface: AnyObject {
    var isReadyForInput: Bool { get }            // realized, mapped, surface exists
    func sendText(_ text: String)                // ghostty_surface_text (paste-style)
    func sendReturn() -> Bool                    // real Return key press
    func sendEscape() -> Bool                    // real Escape key press (agent interrupt)
    func readText(includeScrollback: Bool) -> String?   // viewport or whole screen
    func performBindingAction(_ action: String) -> Bool // "start_search", "search:<needle>",
                                                        // "navigate_search:next|previous", "end_search"
    func grabFocus() -> Bool
    var promptState: LinuxTerminalPromptState { get }   // .unavailable/.exited/.idleAtPrompt/.busy
    var needsCloseConfirmation: Bool? { get }    // ghostty_surface_needs_confirm_quit
    func invalidate()                            // panel removed; free the surface
}
```

Flow for each terminal panel the UI shows:

1. `logic.terminalLaunchConfiguration(panelID:)` → environment (Toastty
   socket, panel ID, CLI path, agent-shim `PATH`, pane journal, profile
   variables), working directory, `initialInput` (profile startup command or
   restored agent resume command), font size. Pass them to
   `ghostty_surface_config_s` (`env_vars`, `working_directory`,
   `initial_input`, `font_size`).
2. `logic.attachTerminalSurface(surface, panelID:)` once the widget is live,
   `logic.detachTerminalSurface(panelID:)` when it is destroyed or moved.
3. `logic.terminalSurfaceDidLaunch(panelID:)` after the shell spawns
   (restored managed agents submit their resume command after this).
4. Input reporting: `terminalDidReceiveLocalInput(panelID:isPaste:)` for every
   key/paste (closes remote-send drafts), `terminalDidReceiveInterruptKey(panelID:isEscape:)`.
5. Runtime actions: `logic.handleTerminalRuntimeEvent(panelID:event:)` with
   `LinuxTerminalRuntimeEvent` — `.title` (OSC 0/2), `.workingDirectory`
   (OSC 7), `.commandFinished(exitCode:durationNanoseconds:)`,
   `.childExited(exitCode:runtimeMilliseconds:)`, `.programStatus` (OSC 7501
   report/prompt/reset/exit), `.desktopNotification(title:body:)` (OSC 9/777),
   `.bell`. These run the macOS path: `TerminalMetadataService` (compiled on
   Linux; title coalescing and startup-command suppression into the live
   title store, cwd normalization, command-finished session lifecycle and
   pane journal, notification routing with unread marking and managed-session
   suppression through `SystemNotificationSender`), `SessionRuntimeStore`
   program status (sidebar rows), and exit state (close confirmation and prompt
   state). `.bell` is unhandled, as on macOS. `reportTerminalMetadata` is a
   shorthand for title/cwd.
6. Links: `logic.openTerminalLink(panelID:url:alternate:)` is macOS's
   `openCommandClickLink` (local documents and directories by routing
   preferences, local HTML in the browser panel, other URLs per URL routing).
7. Titles: live titles are display state (not persisted), as on macOS. Read
   `logic.terminalDisplayTitle(panelID:)`, or `logic.displayState` /
   `observeDisplayState(_:)`, which fold live titles into each terminal
   panel's `title` (the GTK store binding does this). Process-cwd fallback for
   shells without OSC 7 uses `/proc` (`linux/Sources/ToasttyAppLogic/Terminal/LinuxTerminalProcessWorkingDirectoryResolver.swift`),
   bound in `terminalLaunchConfiguration` / `terminalSurfaceDidLaunch`.
   `setGhosttyConfiguredFontPoints(_:)` after loading Ghostty config.
   Window font size: `AppState.effectiveTerminalFontPoints(for:)`.

The registry then provides, unchanged from macOS: `sendText`, managed-agent
command delivery, remote send/interrupt, `readVisibleText`, search state,
focus restore, file drops, close confirmation, and prompt state (two
`#elseif os(Linux)` branches in `TerminalRuntimeRegistry.swift` read the
surface's prompt and close state). The Ghostty host itself (keyboard/IME,
mouse, rendering, clipboard, search UI) is the GTK frontend's
`linux/Sources/ToasttyLinux/UI/Terminal` (`AppLogicTerminalRuntimeBridge`
implements `LinuxTerminalSurface` and forwards runtime events); the macOS
AppKit host files stay excluded.

### Web panel seam

`WebPanelRuntimeRegistry` is shared; `linux/Sources/ToasttyAppLogic/WebPanels/LinuxWebPanelRuntimes.swift`
replaces the three WKWebView runtimes with the same registry-facing API.
The pure models were split out of the macOS runtime files
(`BrowserPanelModels.swift`, `LocalDocumentPanelModels.swift`,
`ScratchpadPanelModels.swift`). Hosts the panels frontend implements:
`LinuxBrowserPanelHost` (load/back/forward/reload, location focus,
favicon PNG, screenshot PNG), `LinuxLocalDocumentPanelHost` (edit/save/cancel,
close confirmation, reveal line, search), `LinuxScratchpadPanelHost` (focus,
reload document). Attach with `logic.attachBrowserHost(_:panelID:)`,
`attachLocalDocumentHost`, `attachScratchpadHost` (and `detach…`); report
browser metadata with `browserDidUpdate(panelID:title:url:)`,
`browserDidRequestFocus`, `browserRequestsSecondaryOpen`.
`browserRequestsSecondaryOpen` follows `AppURLRouter` (URL routing
preferences, local documents with line numbers, external apps) except for
`file://` HTML pages and `toastty://` pages: macOS hands those to
`NSWorkspace`, which reopens them in a browser or in Toastty, while
`xdg-open` has no route back, so Linux opens them in a Toastty browser panel
(the same rule as a terminal click on a local HTML file). A browser panel
that was never shown (another workspace or tab, or restored unselected) has
no host: `panel.browser.state` and `panel.browser.reload` then have the
frontend build its `BrowserPanelController` off screen
(`LinuxAppLogic.setBrowserHostMaterializer`, `LinuxAppController.materializeWebPanel`),
so it loads in the background as macOS's runtime-owned WKWebView does; it
reports `detached` until it is in a window, and is reused when mounted and
closed with its panel. The host reports main-frame results with
`browserNavigationDidChange(panelID:event:)` (WebKitGTK `load-changed` /
`load-failed` / `web-process-terminated`; internal start, invalid-URL and
WebKit error pages and superseded loads are not results), which back
`navigationState` and `navigationError`; `observedURL`, `title` and
`runtimePageZoom` come from the web view. Without a host, other commands
return "not handled".
The local-document runtime does not yet load files, compute
`LocalDocumentPanelBootstrap`, or watch files itself (macOS does that inside
the WKWebView runtime); that logic belongs in the panels port.

### Remote Access on Linux

The gateway listens on 127.0.0.1 through `ToasttyNetworkShim`; WebSocket and
HTTP framing are the shared code. Tailscale Serve setup and tailnet origin
detection use the `tailscale` CLI from `/usr/bin`, `/usr/local/bin`,
`/usr/sbin`, or `/snap/bin` (`TOASTTY_TAILSCALE_CLI_PATH` in debug builds).
`tailscale serve` needs `tailscale set --operator=$USER` once on Linux.
Pairing QR codes come from a pure-Swift encoder
(`linux/Sources/ToasttyAppLogic/RemoteAccess/RemoteAccessPairingQRCode.swift`:
byte mode, ECC M, smallest version, 8 px modules, 4-module quiet zone) as an
RGBA bitmap/PNG. Push relay configuration comes from
`TOASTTY_PUSH_RELAY_URL`, `TOASTTY_PUSH_RELAY_ID`,
`TOASTTY_PUSH_APNS_ENVIRONMENT` (macOS reads Info.plist); unset disables push.

### App files not compiled on Linux

- SwiftUI views and scene plumbing (45 files incl. `ToasttyApp.swift`,
  `SidebarView`, `WorkspaceView`, `AppWindow*`, `Theme`, settings views):
  rewritten in GTK. `ToasttyApp`'s static helpers are ported in
  `LinuxAppConfiguration` (and forwarded by a Linux `enum ToasttyApp` so the
  shared tests check the Linux port).
- Ghostty host files (see terminal seam), WebKit runtimes and views
  (`BrowserPanelRuntime`, `LocalDocumentPanelRuntime`, `ScratchpadPanelRuntime`,
  `WebPanelContainerView`, `ToasttyPageSchemeHandler`, `BrowserLinkRoutingRules`,
  and the AppKit/SwiftUI annotation views plus the CoreGraphics
  `BrowserAnnotatedScreenshotRenderer`; the annotation model, geometry,
  session, payload builder, screenshot writer and send flow compile, see
  "Browser annotation mode").
- AppKit input/menu/window plumbing: `DisplayShortcutInterceptor`,
  `DisplayShortcutConfig`, `NavigationMouseInterceptor`,
  `WindowCommandController`, `CommandPalettePanel`, `WindowMovementSuppression`,
  `TextInputResponderPolicy`, `ToasttyApplicationIconPolicy`,
  `LocalDocumentOpenPanel`, `DiagnosticsPresenter`.
- Command palette catalog/view model/action handler (bound to the macOS
  menu controllers in `ToasttyCommandMenus`); gtk-shell has `LinuxCommandTable`.
  The fuzzy scorer, file search engine, file-open provider, usage tracker, and
  context compile.
- Sparkle updates; `RemoteAccessPairingQRCode` (Linux replacement).
- Tiny pieces of excluded files that included logic needs are restated in
  `linux/Sources/ToasttyAppLogic/Compat/ExcludedViewStubs.swift`
  (`CursorDiagnostics`, `SessionStatusIndicatorState`, `ToastyTheme` metrics,
  `DisplayShortcutConfig` counts); keep them in step with macOS.

## Terminal integration (Ghostty)

Every terminal panel in `toastty-linux` is a real Ghostty terminal
(`ToasttyGhosttySurface` from `linux/ghostty`). Code:
`linux/Sources/ToasttyLinux/UI/Terminal/` (inside `ToasttyLinuxUI`, which
depends on the `GhosttyKit` system library from the
`// MARK: terminal-integration` block of `linux/Package.swift`). Binaries
find `libghostty.so` through an absolute rpath to `linux/.deps/ghostty/lib`
and `$ORIGIN/../lib` for an installed layout.

| Piece | File | Notes |
|---|---|---|
| One Ghostty app per process | `GhosttyRuntime.swift` | macOS config precedence (`TOASTTY_GHOSTTY_PARSE_CLI_ARGS`, `TOASTTY_GHOSTTY_CONFIG_PATH`, `$XDG_CONFIG_HOME/ghostty/config[.ghostty]`, `~/.config/ghostty/…`, Ghostty defaults), `TOASTTY_DEBUG_LOGIN_SHELL`, config diagnostics to stderr, `font-size` → `setConfiguredTerminalFont`, OSC 7501 enabled, `ghostty_app_set_color_scheme` follows `AdwStyleManager:dark`, app focus = any Toastty window active, panel-frame colors from Ghostty `background`/`foreground`, unfocused-split overlay from `unfocused-split-opacity`/`-fill`, `reload_config` |
| Terminal host | `GhosttyTerminalHost.swift` | `TerminalPanelHosting`; one surface per panel inside a `GtkOverlay` (search bar, unfocused dim, link-hover label), kept alive across re-layouts, tab and workspace switches |
| Surface operations | `GhosttyTerminalSurface.swift` | send text/keys, read viewport/scrollback, binding actions, prompt state (`ghostty_surface_is_at_prompt`), close confirmation (`ghostty_surface_needs_confirm_quit`); API matches app-logic's `LinuxTerminalSurface` |
| App seam | `TerminalRuntimeBridge.swift`, `AppLogicTerminalRuntimeBridge.swift` | see below |
| Find | `TerminalSearchBar.swift` | Ghostty `start_search`/`search:`/`navigate_search`/`end_search` and the `SEARCH_TOTAL`/`SEARCH_SELECTED` actions; "3 of 12" like macOS; needles under 3 characters wait 300 ms |
| Terminal profiles | `TerminalProfileShortcuts.swift` | Core `TerminalProfilesFile` + `ProfileShortcutRegistry` with Ctrl+Alt (split right) / Ctrl+Alt+Shift (split down); reserved keys are reported, not bound; palette entries "Split Right/Down with <profile>"; command IDs `terminal-profile.split-right.<id>` / `split-down.<id>` |
| Automation | `TerminalAutomation.swift` | smoke-script `terminal-*` commands and summary keys (see the file header) |

Behavior:

- **Keyboard.** Toastty shortcuts are matched by the window's capture-phase
  controller before the terminal sees the key, so Ghostty's default Linux
  bindings for the same chords (Ctrl+Shift+T/N/W/O/E/F, Ctrl+±/0, …) never
  fire twice. Keys Ghostty binds that Toastty does not (Ctrl+Alt+arrows
  `goto_split`, Ctrl+Shift+Enter `toggle_split_zoom`, `new_tab`, `goto_tab`,
  `close_window`, user keybinds …) arrive as Ghostty actions and run the
  matching Toastty command after focusing the source panel, like macOS
  `TerminalActionRouter`. Ctrl+Shift+C/V are Ghostty's own bindings;
  Shift+Insert pastes the clipboard (Toastty table). Every key reports local
  input / Ctrl+C / Escape interrupts to the bridge.
- **Font size.** Text-size commands change `AppState`'s per-window points;
  the host applies `set_font_size:<points>` to that window's terminals and
  creates new surfaces at that size.
- **Close.** `panel.close`, the frame's close button and closing a one-panel
  tab go through `PanelHostRegistry.requestClose`; a terminal whose process
  is still running asks first ("Close this terminal?", with the detected
  command from `/proc/<pid>/cmdline`). `exit` or Ctrl+D in the shell closes
  the pane without asking. As on macOS, Enter in the close, close-tab,
  close-workspace and quit prompts picks Close/Quit (Escape cancels).
- **Links.** Ghostty `open_url` (Ctrl+click): http(s) opens in the right
  panel browser; Shift held or other URLs go to the desktop handler
  (`g_app_info_launch_default_for_uri`).
- **Drops.** File lists insert shell-escaped paths
  (`TerminalDropPayloadBuilder`); dropped images without a file are saved as
  PNG under `$XDG_CACHE_HOME/toastty/dropped-images/` and inserted as a path;
  `text/uri-list` strings of file URLs become paths, other text is pasted.
- **Attention.** Bell, OSC 9/777 desktop notifications and OSC 7501
  `done`/`blocked`/`error` in a panel that is not focused mark it unread
  (`recordDesktopNotification`). macOS does not mark bells; this is a Linux
  addition.
- **Focus.** First click into a pane while focus is in another terminal of
  the active window only focuses it (macOS `mouseDown` behavior). Mouse
  back/forward buttons run `navigation.back`/`forward`.
- **Context menu.** Copy, Paste, Select All, Split Right/Down, Find, Clear,
  Close Panel.
- **Keystroke latency.** libghostty patch `0007` stops a keystroke from
  rendering a frame identical to the previous one before the echo arrives
  (termio redrew after every pty write, and `keyCallback` queued a render);
  that frame was painted first and delayed every echoed character by one
  paint. Measure with `TOASTTY_GHOSTTY_LATENCY_TRACE=1` (see
  `linux/ghostty/README.md`).
- `TOASTTY_LINUX_TERMINAL=placeholder` keeps the placeholder host;
  `TOASTTY_LINUX_TERMINAL_DEBUG=1` logs Ghostty actions and bridge events.

### Bridge to the application layer

`TerminalRuntimeBridge` is what the host needs: launch spec (environment,
cwd, initial input, font), surface attach/detach/launch, runtime events
(title, cwd, bell, command finished, child exited, program status, desktop
notification), local input, configured font, link opening, panel close.

- `StandaloneTerminalRuntimeBridge` (default today, `ReducerStoreBinding`):
  applies title/cwd with `updateTerminalPanelMetadata`, sets
  `TOASTTY_PANEL_ID`, `TOASTTY_TERMINAL_PROFILE_ID`, `TOASTTY_LAUNCH_REASON`
  and the profile startup command, marks background attention unread. No
  automation socket or managed agents.
- `AppLogicTerminalRuntimeBridge` (`#if TOASTTY_LINUX_APP_LOGIC`) implements
  the app-logic terminal seam above: `terminalLaunchConfiguration`,
  `attach/detachTerminalSurface` with a `LinuxTerminalSurface` adapter,
  `terminalSurfaceDidLaunch`, `reportTerminalMetadata`,
  `terminalDidReceiveLocalInput`/`InterruptKey`,
  `setGhosttyConfiguredFontPoints`. To switch: make `ToasttyLinuxUI` depend
  on `ToasttyAppLogic`, add `swiftSettings: [.define("TOASTTY_LINUX_APP_LOGIC")]`,
  and call `app.installTerminals { app in AppLogicTerminalRuntimeBridge(logic: logic, store: app.store) }`
  instead of `app.installTerminals()`. It typechecks against the current
  `ToasttyAppLogic`; it has not run end to end yet.
- Still missing from the facade (the adapter falls back to reducer-level
  behavior for these): routing bell / OSC 9 desktop notifications / OSC 7501
  program status / command finished / child exited through
  `TerminalMetadataService` and `SessionRuntimeStore` (session rows, system
  notifications), and `TerminalRuntimeRegistry.openCommandClickLink` for
  local-document/directory link routing. A
  `handleTerminalRuntimeEvent(panelID:event:)` and
  `openTerminalLink(panelID:url:alternate:)` on `LinuxAppLogic` would close
  both gaps.

### Tests

- `linux/Tests/ToasttyLinuxTests/TerminalIntegrationTests.swift`: profile
  commands and accelerator collisions, search labels, standalone bridge
  (launch spec, metadata, unread, links), helpers.
- `linux/Tests/ToasttyLinuxTests/TerminalBroadwayTests.swift`: launches
  `toastty-linux` on a private Broadway display with an isolated HOME and
  bash; types into real shells and reads the screen back, splits, title/cwd
  in state and header, font size, find, Ghostty keybind routing, bell/OSC 9
  unread, close confirmation (answered through the dialog's real buttons,
  `dialog-click`), Ctrl+D and `exit`, profile split + environment, file drop,
  context menu, and quitting through the window's close button.
  Screenshots: `artifacts/manual/linux-terminal/`.
- The gtk-shell `BroadwaySmokeTests` now run with Ghostty terminals.

## Right panel, desktop integration, Remote Access UI (panels-remote)

Code: `linux/Sources/ToasttyLinux/UI/RightPanel/` (WebKitGTK panels),
`UI/Desktop/` (notifications, dock badge, `LinuxPlatformServices`),
`UI/RemoteAccess/` (Remote Access window and Preferences page),
`linux/Sources/CWebKitGtk` (system module, pkg-config `webkitgtk-6.0`),
`linux/Sources/CWebKitShim` (construct-only `WebKitWebView` properties),
`linux/data/` (desktop file, metainfo, hicolor icons), `scripts/linux/install.sh`, tests in
`linux/Tests/ToasttyLinuxPanelsTests`.

### Web panels (WebKitGTK 6.0)

`WebPanelHost` (installed by `LinuxAppController.installWebPanels()`, called
from `ToasttyLinuxMain`) is both `hosts.rightPanel` and `hosts.web`, so web
panels work in the right panel and in splits/tabs. One controller per panel
ID keeps its widget across re-parenting.

- Browser (`BrowserPanelController`): location entry (Ctrl+L), back /
  forward / reload-stop (Ctrl+R, F5), progress bar, find (Ctrl+Shift+F, F3),
  page zoom from `WebPanelState.browserPageZoom` (Ctrl+plus/minus/0 route to
  the focused browser, including in the right panel), title + URL persisted
  through `updateWebPanelMetadata` (restores on relaunch), favicon and
  loading spinner on the right-panel tab, page menu (open in default
  browser, copy link, inspector). Link routing is the macOS
  `BrowserLinkRoutingRules` with Ctrl in Cmd's role: Ctrl/middle click and
  `target=_blank` open a new right-panel browser tab, non-http(s)/toastty
  links leave the browser, `window.open(about:blank)` popups are captured
  offscreen until they navigate. Unsupported MIME responses download to the
  XDG Downloads directory (unique names, toast when done). Cookies/storage
  persist in `$XDG_DATA_HOME/toastty/webkit` (an isolated runtime home uses
  `<runtime>/webkit`; `TOASTTY_LINUX_EPHEMERAL_BROWSER=1` for none).
  Annotation mode (Ctrl+Shift+A, see below). Mouse back/forward buttons
  (8/9) run Toastty's `navigation.back`/`forward` history, like macOS's
  `NavigationMouseInterceptor` (which intercepts them app-wide, browser
  included) and the Linux terminal; a capture-phase `GtkGestureClick` claims
  the press so WebKit never sees it. The page's own history stays on the
  toolbar arrows.
- `toastty://` URI scheme (registered on the default `WebKitWebContext`,
  secure + CORS-enabled) serves the generated bundles from
  `Sources/App/Resources/WebPanels`: `getting-started`, `local-document`,
  `scratchpad` (port of `ToasttyPageSchemeRouter`, traversal-safe, adds
  `application/wasm`). Bundles are found via `TOASTTY_APP_RESOURCES_PATH`,
  `<exe>/../share/toastty/Resources`, or the checkout.
- Getting Started: command `help.getting-started` (palette "Get Started")
  opens/reuses `toastty://getting-started/` in a right-panel browser;
  `toastty://action/<name>` links from that page only run
  `agent.profiles.manage`, `agent.toastty-skills.manage`, `app.shortcuts`.
- Local document (`LocalDocumentPanelController`): ports the macOS native
  side of contract 7: `LocalDocumentEditingSession`, bootstrap delivery on
  `bridgeReady`, `toasttyLocalDocumentPanel` messages (enterEdit, save,
  cancelEdit, draftDidChange, overwriteAfterConflict, copyFullPath,
  openInDefaultApp, renderReady, diagnostics), Ctrl+E / Ctrl+S / Escape,
  find bar (Ctrl+Shift+F) driving the page's search controller, window
  Markdown text scale (Ctrl+plus/minus/0 when a document has focus), light/
  dark from `AdwStyleManager`, GFileMonitor reload (debounced 150 ms; a
  dirty draft becomes an external conflict), close confirmation for dirty
  drafts on the right-panel tab close button, relative links resolved next
  to the document. "Open Local File" (`local-document.open`, `-tab`,
  `-split`) is a `GtkFileDialog` filtered by `LocalDocumentClassifier`;
  opened files go to GTK's recent files.
- Scratchpad (`ScratchpadPanelController`): `toasttyScratchpadPanel`
  bridge, a new `scratchpad.revision` in state reloads; trusted http(s) link
  clicks post to `toasttyScratchpadExternalLink` registered in an isolated
  script world (`toastty-scratchpad-links`) and open a browser tab;
  navigation is limited to the bundle and `about:`. Documents are read from
  `<config>/scratchpad` (the `ScratchpadDocumentStore` files).

### Browser annotation mode

macOS behavior (`docs/right-panel.md`, "Annotation mode"), ported for the
browser panel. Scratchpad annotation is not ported yet.

- Enter/leave with the pencil button in the browser toolbar (count badge;
  Send and Clear buttons appear while drafts exist outside the mode — while
  annotating the pill carries them, so the toolbar never widens the right
  panel and changes the viewport mid-annotation), **Ctrl+Shift+A** while
  the browser has focus (`browser.annotate.toggle`, panel-scoped so it never
  takes Ghostty's Ctrl+Shift+A from a terminal; palette "Annotate Browser
  Page"; macOS has no shortcut, only the header button), or the palette.
  Escape cancels a drag, then an open comment, then leaves the mode.
- While on: an accent frame, a crosshair cursor, and a floating pill at the
  top of the page ("Annotating" + count, Send to Agent, Clear, Done Esc;
  under 470 px wide it drops the two text labels). A
  `GtkDrawingArea` over the `WebKitWebView` (same `GtkOverlay`) takes all
  pointer input, so the page sees no clicks (the AppKit overlay's hit test);
  wheel/touchpad scrolling still scrolls the page (`window.scrollBy`, about
  40 px per wheel step) and marks follow.
- Click marks a point, drag marks a region. A `GtkPopover` anchored to the
  mark takes the comment (Enter saves, Shift+Enter newline, Esc cancels);
  the page snapshot is taken right after the gesture while the comment is
  typed. Clicking an existing mark opens its comment with Edit / Delete
  (deleting renumbers). An outside click on an open comment commits a
  non-empty comment and drops an empty one (macOS click-away rules; GTK's
  autohide popover consumes that click). macOS lets the comment popover be
  dragged away; GTK popovers cannot be moved.
- Send to Agent lists live managed sessions visible in the browser's
  workspace tab (blocked ones disabled with the reason: awaiting approval,
  error, unavailable). Sending renders one annotated PNG per scroll position
  into `$TMPDIR/toastty-browser-annotations/`, types the macOS payload
  (preamble, screenshot path, page title, URL, viewport, numbered comments)
  into that agent's terminal, submits it, focuses the agent panel, clears
  the drafts and leaves the mode; the outcome shows as an `AdwToast`.
  Navigating to another page (commit, or a same-document URL change) clears
  drafts like macOS.

Code: the shared files `BrowserAnnotationModel.swift`,
`BrowserAnnotationDisplayGeometry.swift`, `WebPanelAnnotationSession.swift`,
`BrowserAnnotationPayloadBuilder.swift`, `BrowserAnnotationSendFlow.swift`,
`BrowserPanelScreenshotWriter.swift`, `ScratchpadAgentBindCandidates.swift`
compile into `ToasttyAppLogic`; the Linux `BrowserPanelRuntime` conforms to
`WebPanelAnnotationRuntime` (`LinuxWebPanelRuntimes.swift`; the host adds
`pageZoom`, `viewportSize`, `pageScrollOffset()`).
`linux/Sources/ToasttyAppLogic/WebPanels/LinuxWebPanelAnnotation.swift` holds
`LinuxWebPanelAnnotationController` (the AppKit overlay's state machine:
gestures, pending draft and capture, popover purposes and click-away rules,
hover, scroll tracking) and a stand-in `BrowserAnnotatedScreenshotRenderer`
that calls the renderer the frontend installs
(`LinuxAppLogic.installAnnotationScreenshotRenderer`). The facade
(`LinuxAppLogic+BrowserAnnotations.swift`) adds
`browserAnnotationController(panelID:)`, `browserDidCommitNavigation`,
`browserDidObserveURL`, and the `WorkspaceView` send closures (candidates,
send gate, `terminalRuntimeRegistry.sendText(submit: true)` + focus). GTK:
`UI/RightPanel/BrowserAnnotationOverlay.swift` (overlay, pill, toolbar
buttons, popovers, clear confirmation), `BrowserAnnotationPainter.swift`
(cairo + Pango marks shared by the overlay and the screenshot renderer, so
sent PNGs match the overlay), `BrowserAnnotationAutomation.swift`.

Tests: the shared `Tests/App/BrowserAnnotationModelTests.swift` (19 XCTest
cases) run on Linux; `linux/Tests/ToasttyAppLogicTests/LinuxBrowserAnnotationTests.swift`
covers the controller (click/drag, click-away, detail edit/delete and
renumbering, Escape ladder, scroll tracking, page-change clearing, capture
failure, send success/blocked/failed/no renderer) with a fake host, plus the
facade end to end (session candidate → payload typed into a recording
terminal surface → agent panel focused);
`linux/Tests/ToasttyLinuxPanelsTests/BrowserAnnotationTests.swift` checks the
cairo renderer's pixels and scale, the mouse-button mapping and the
shortcut scope, and runs a Broadway session (bash terminal registers a
managed session and runs `cat > handoff.txt`; the browser annotates a point
and a region through the popover, opens a detail popover, and sends; the
test reads the handoff file, the annotated PNG and a mark pixel).
Screenshots: `artifacts/manual/linux-annotation/`.

Entry points for other workstreams:

- `app.webPanelHost?.openURL(url, windowID:)`: open a link the Toastty way
  (web → right-panel browser tab, supported local file → local-document
  panel, else the desktop handler). Terminal link clicks should call this
  when the app-logic `AppURLRouter` is not used.
  `openURLInRightPanelBrowser(_:workspaceID:)` forces a browser tab;
  `openLocalDocument(path:windowID:placement:)` opens a document.
- `webPanelHost.attach(logic:)` (`#if TOASTTY_LINUX_APP_LOGIC`): registers the
  live panels as `LinuxBrowserPanelHost` / `LinuxLocalDocumentPanelHost` /
  `LinuxScratchpadPanelHost`, routes browser metadata and secondary opens
  through `LinuxAppLogic` (AppURLRouter). Call after constructing the logic.
- `GtkPlatformServices(app:)` (`#if TOASTTY_LINUX_APP_LOGIC`): the
  `LinuxPlatformServices` implementation (AdwAlertDialog alerts incl. a
  blocking `runModal`, launchers, GDK clipboard, window/screen snapshots,
  GNotification notifications whose click routes through
  `LinuxPlatform.handleNotificationActivation`, Ubuntu Dock badge). Pass it as
  `LinuxAppLogic.Options.platformServices`.
- `app.installRemoteAccessUI(logic:)` (`#if TOASTTY_LINUX_APP_LOGIC`):
  `app.remote-access.open` opens the Remote Access window; Preferences gets
  the real Remote Access page (`PreferencesDialog.remoteAccessPage`).

Automation (`TOASTTY_LINUX_SMOKE_SCRIPT`) gains `browser-open`, `doc-open`,
`scratchpad-open`, `web-wait ready|text …`, `web-eval`, `web-expect <js> =>
<json>`, `web-command`, `web-snapshot`, `doc-search`, `file-write`, and
summary keys `webKind`, `webURI`, `webTitle`, `webBridgeReady`, `webEditing`,
`webDirty`, `webSearchMatches`, `webZoom` (see `WebPanelAutomation.swift`),
and for annotation mode `annotate-mode on|off`, `annotate-click x y`,
`annotate-drag x1 y1 x2 y2` (through the overlay's gesture handlers),
`annotate-comment <text>` / `annotate-save` (the popover's real text view and
button), `annotate-escape`, `annotate-wait`, `annotate-send first|<session>`,
`annotate-copy-screenshot`, `annotate-popover-screenshot` (window
screenshots do not include popovers), `annotate-expect-pixel x y r g b`,
`annotate-expect-payload <text>`, with summary keys `annotationMode`,
`annotationDrafts`, `annotationComments`, `annotationPopover`,
`annotationModeBar`, `annotationNotice`, `annotationSentTo`,
`annotationSentScreenshots`, `annotationCandidates`
(`BrowserAnnotationAutomation.swift`).
Script lines cannot contain `#` (comment character).

Note: GLib's main loop does not drain the libdispatch main queue, so panel
code hops back to the main thread with `MainLoop.dispatch` (g_idle_add), not
`Task { @MainActor }` / `DispatchQueue.main`.

### Desktop integration

- `DesktopNotifications`: `GNotification` via `g_application_send_notification`
  with default action and a "Show" button targeting
  `app.notification-activate` (identifier + userInfo JSON).
  `NotificationRoute.actions(userInfo:state:)` focuses the notification's
  workspace/panel when app-logic routing is not attached. GNOME shows
  notifications only for apps with an installed desktop file.
- `LauncherBadge`: `com.canonical.Unity.LauncherEntry.Update` on the session
  bus for `application://com.GiantThings.toastty.desktop` (`count`,
  `count-visible`), shown by the Ubuntu Dock.
- `scripts/linux/install.sh [--prefix ~/.local] [--debug] [--no-build]
  [--build-dir DIR] [--uninstall] [--dry-run]`: installs under
  `PREFIX/lib/toastty/{bin,lib,share}` (Ghostty libs + the Swift runtime in
  `lib`, `Resources` incl. WebPanels, the Toastty agent skills as
  `ToasttyAgentPluginBundle/{.agents/plugins/marketplace.json,plugins/toastty}`
  and `WorkflowExamples/skills` laid out as on macOS, Ghostty
  `share/{ghostty,terminfo}`),
  symlinks `PREFIX/bin/{toastty-linux,toastty}`, installs the desktop file
  (absolute Exec), metainfo and hicolor icons, and refreshes the desktop
  database / icon cache. No root needed.

- App icon: `scripts/linux/render-app-icon.py` renders `linux/data/icons/hicolor`
  (scalable SVG + 16–512 PNGs) from macOS's
  `Assets.xcassets/AppIcon.appiconset/terminal-toast-1024.svg`. macOS clips
  that full-bleed artwork to its icon shape; GNOME does not, so the script
  clips it to GNOME's square app-icon shape (768px rounded square, radius
  128, on the 1024 canvas) with transparent surroundings. Rerun it when the
  macOS icon changes; `--check` (run by `e2e-app-logic.sh`) fails when the
  SVG is stale. `AppIcon.install()` (startup) adds `linux/data/icons` (checkout)
  or `<prefix>/lib/toastty/share/icons` (install) to the icon theme and sets
  it as the default window icon; the About dialog uses it. GNOME's dock and
  Alt+Tab icon on Wayland come from the installed desktop file, matched by
  the application ID.

### Remote Access UI

`RemoteAccessDialog` mirrors `RemoteAccessSettingsView` on
`LinuxAppLogic.remoteAccessStatus`: enable switch, status row (indicator,
title, detail), connected clients and port, tailnet origin entry, "Set Up
Tailscale Serve" retry, pairing (QR from `remoteAccessPairingQRCodePNG` in a
`GtkPicture`, selectable fallback code, expiry countdown, copy / cancel),
paired devices with Revoke and Revoke All, and a push relay row
(`isPushRelayConfigured`). It polls the status every 500 ms while open and
rebuilds only on change; `RemoteAccessDialog.current` holds the open dialog
strongly so the poll keeps running.

Scripted runs (`TOASTTY_LINUX_SMOKE_SCRIPT`) can drive pairing without the
real tailnet: `TOASTTY_LINUX_FAKE_TAILNET_ORIGIN` replaces the Tailscale
Serve step with that origin (`LinuxAppLogic.Options.simulateTailnet`) and
`TOASTTY_LINUX_FAKE_TAILNET_PORT` picks the gateway port. Script commands
`remote-access enable|pair`, and through the open window's widgets
`remote-access switch on|off` and `remote-access origin <origin>`; summary
keys `remoteAccess`, `remotePairing`, `remoteQRCode`, `remoteEnabled`,
`remoteOrigin`. `scripts/linux/e2e-app-logic.sh` runs this path;
`RemoteAccessPersistenceTests` (panels tests) checks that the enable switch
and tailnet origin survive a window-close / Quit restart.

### gtk-shell files edited by panels-remote

`Panels/PanelHosting.swift` (`RightPanelContentHosting` tab decorations and
close confirmation, `WindowCommandHandling`, `PanelHostRegistry.windowCommandHandlers`),
`Window/RightPanelController.swift` (decorations, close confirmation),
`Window/TabViewSync.swift` (`TabItem.decoration`, `adw_tab_page_set_loading/icon`),
`Window/LinuxWindowController.swift` (window command handlers run first),
`Commands/CommandRouter.swift` (panel commands and text size target the
focused right-panel tab; local documents use Markdown text scale),
`Commands/LinuxCommandTable.swift` (`help.getting-started`),
`Debug/AutomationScript.swift` (`extensionCommands`, `summaryContributors`),
`App/ToasttyLinuxMain.swift` (`app.installWebPanels()`),
`Dialogs/PreferencesDialog.swift` (`remoteAccessPage` provider),
`linux/Package.swift` (`CWebKitGtk`/`CWebKitShim` deps of `ToasttyLinuxUI`,
the `panels-remote` block). No shared macOS sources were changed.

## Shared files with Linux guards

macOS cannot be built from Linux hosts. Each file below has `#if os(Linux)`
code (macOS branches unchanged); run a macOS build
(`./scripts/automation/check.sh`) before merging.

| File | Reason |
|---|---|
| `Sources/Core/Runtime/ToasttyRuntimePaths.swift` | XDG state dir for the user-home log; `$XDG_RUNTIME_DIR` socket base (`socketBaseDirectoryPath`, `linuxXDGRuntimeDirectoryPath`) |
| `Sources/Core/Automation/AutomationSocketLocator.swift` | `socketDirectoryURL` uses `$XDG_RUNTIME_DIR/toastty`; made `public` for the CLI probe and tests |
| `Sources/CLIKit/DiagnosticsSocketProbe.swift` | socket directory comes from `AutomationSocketLocator` on Linux |
| `Sources/Core/RemoteAccess/RemotePreviewFileReader.swift` | no `/private` aliases for `/tmp`, `/var`, `/etc`; descriptor path via `/proc/self/fd` instead of `F_GETPATH` |
| `Sources/Core/RemoteAccess/RemoteMessageAttachmentStore.swift` | `discard` compares paths: corelibs URL equality is trailing-slash sensitive |
| `Sources/Core/Diagnostics/DiagnosticsChecks.swift` | parent PID from `/proc/<pid>/stat` instead of `proc_pidinfo` |
| `Sources/Core/Diagnostics/DiagnosticsCollector.swift` | hardware model from DMI/device tree instead of `sysctlbyname("hw.model")` |
| `Tests/Core/ToasttyLogConfigurationTests.swift` | Linux default log path expectation |
| `Tests/Core/ToasttyRuntimePathsTests.swift` | Linux default log path expectation; Linux-only XDG path test |
| `Tests/Core/ManagedAgentPathResolverTests.swift` | (unguarded, platform-neutral) expectation accounts for merged-/usr systems where `/bin` -> `/usr/bin` |
| `Sources/App/Terminal/TerminalRuntimeRegistry.swift` | `#elseif os(Linux)` prompt state and close confirmation read the Linux surface; `#if TOASTTY_HAS_GHOSTTY_KIT \|\| os(Linux)` exposes `workspaceID(containing:)` and the launch-configuration / restored-launch logic (`surfaceLaunchConfiguration`, `markInitialSurfaceLaunchCompleted`) without GhosttyKit |
| `Sources/App/Terminal/Runtime/TerminalMetadataService.swift` | compiled on Linux (`#if TOASTTY_HAS_GHOSTTY_KIT \|\| os(Linux)`); a Linux-only `handleDesktopNotification(title:body:workspaceID:panelID:state:)` entry routes notifications by panel instead of Ghostty surface handle |
| `Sources/App/Terminal/GhosttyRuntimeAction.swift` | mechanical split of the `GhosttyRuntimeAction` value type out of `GhosttyRuntimeManager.swift`, compiled for `TOASTTY_HAS_GHOSTTY_KIT \|\| os(Linux)` |
| `Sources/App/Persistence/WorkspaceLayoutPersistence.swift` | no `#selector` on Linux: the display-change observer uses a block observer (no target queue, see `SystemNotificationSender.swift`) |
| `Sources/App/Notifications/SystemNotificationSender.swift` | the notification-guidance `didBecomeActive` observer has no target queue on Linux: corelibs `NotificationCenter` enqueues a queue-targeted observer and waits for it, which deadlocks a main-actor poster that is not `OperationQueue.current` (Swift Testing's main actor under `dispatchMain`); the handler already hops to the main actor |
| `Sources/App/RemoteAccess/TailscaleTailnetOriginDetector.swift` | Linux `tailscale` CLI locations |
| `Sources/App/Preferences/ToasttyAppDefaults.swift` | the app defaults are a `LinuxWriteThroughUserDefaults` that calls `synchronize()` after every `set`/`removeObject`: corelibs only writes the plist on `synchronize()`, so every preference was lost on restart |
| `Sources/App/Routing/LocalFileLinkResolver.swift` | `isPackageDirectory` is false on Linux (corelibs reports any directory with an extension as a package) |
| Mechanical splits (no behavior change; new files need `tuist generate` on macOS) | `TerminalAutomationInputDelivery.swift` (from `TerminalSurfaceController.swift`), `WebPanels/BrowserPanelModels.swift`, `LocalDocumentPanelModels.swift`, `ScratchpadPanelModels.swift` (from the three WebKit runtimes), `HoverTipModels.swift` (from `HoverTipPresenter.swift`; the SwiftUI `color` mapping stays there as an extension), `Agents/ToasttySkillsManagementModels.swift` (from `ToasttySkillsManagementSheet.swift`), `DiagnosticsSkillHandoffGenerator.swift` (from `DiagnosticsPresenter.swift`), `RemoteAccess/RemoteAccessConnectionStatusPresentation.swift` (from `RemoteAccessSettingsView.swift`), `WebPanels/BrowserAnnotationPayloadBuilder.swift` (`BrowserAnnotationRenderedSection`, `BrowserAnnotationPayloadBuilder`, `BrowserAnnotationScreenshotWriter` from `BrowserAnnotatedScreenshotRenderer.swift`), `WebPanels/BrowserAnnotationSendFlow.swift` (`BrowserAnnotationSendAvailability`, `BrowserAnnotationSendGate`, `BrowserAnnotationCopy`, `BrowserAnnotationSendFlow` from `BrowserAnnotationModeToolbar.swift`), `WebPanels/ScratchpadAgentBindCandidates.swift` (`ScratchpadAgentBindCandidate` + `ScratchpadAgentBindCandidateBuilder` from `WorkspaceView.swift`; adds `import RemoteProtocol` for `AgentKind`), `Tests/App/BrowserAnnotationModelTests.swift` (send gate, draft state, display geometry, coordinate mapper, annotation session, payload builder test classes from `BrowserAnnotationTests.swift`; `BrowserAnnotationTestImage` stays there on macOS, Linux defines its own) |
| `Tests/App/CodexManagedLaunchIntegrationResolverTests.swift`, `CodexPluginCLIClientTests.swift`, `AgentShimExecutableTests.swift` | (unguarded, platform-neutral) merged-/usr PATH expectations |
| `Tests/App/ProfileShellIntegrationInstallerTests.swift` | (unguarded) skips shell tests whose shell is not installed (`/bin/zsh` is absent on stock Ubuntu) |
| `Tests/App/WorkspaceMergeEndToEndTests.swift` | Linux CLI path next to the test runner; the pull-request script comes from the resolved app resources (the test runner has no bundle resources) |
| `Tests/App/SystemNotificationSenderTests.swift` | `tearDown` hops onto the main actor explicitly under corelibs XCTest |
| `Sources/App/Agents/ToasttyAgentPluginBundle.swift` | `bundleRootURL(bundle:)` (macOS value unchanged: `<resources>/ToasttyAgentPluginBundle`) backs `bundledPluginURL`; on Linux, for `Bundle.main`, `linuxBundleRootURL` looks in `TOASTTY_APP_RESOURCES_PATH` (install) and then the checkout root (same layout) |
| `Sources/App/Agents/CodexSkillsManager.swift` | (unguarded, same path on macOS) the default marketplace source is `ToasttyAgentPluginBundle.bundleRootURL()` instead of a restated `Bundle.main.resourceURL` path |
| `Sources/CLIKit/SetupResourceResolver.swift` | Linux checkout builds fall back to `<checkout>/examples/skills` when the resources have no `WorkflowExamples/skills` |
| `plugins/toastty/skills/toastty-read-terminal/SKILL.md` | (text, ships on macOS too) the pane-by-number example says "pane 3" (Option+Shift+3; Alt+Shift+3 on Linux) instead of "⌘3", which switches tabs on macOS |
| `WebPanels/LocalDocumentApp/src/{LocalDocumentPanelApp.tsx,styles.css}` + regenerated `Sources/App/Resources/WebPanels/local-document-panel/*` | Edit button shows `Ctrl+E` outside Apple platforms; editor text uses `--pre-text` (light theme previously drew dark text on the dark editor background, macOS included). `npm test` in `WebPanels/LocalDocumentApp` passes (71) |

## Tests guarded off on Linux

Shared-core: none; all shared tests run on Linux.

App layer (`ToasttyAppLogicTests`). Test files for code that is not compiled
on Linux are not mirrored (SwiftUI views and scenes, Ghostty host views and
Ghostty-only terminal services, WebKit runtimes, AppKit input/menu plumbing,
the command palette catalog/view model, Sparkle; see the manifest `include`
list). Inside mirrored files, these are guarded (`#if os(macOS)` or
`.disabled(if:)` with the reason next to them):

| Test | Why |
|---|---|
| `AppStoreUnreadNavigation{SpatialOrder,StateChange}Tests` (3 assertions), `ProcessWatchCommandControllerTests` (1 assertion), `SessionRuntimeStoreCodexSubagentCorrelationTests` (hover-tip assertion), `SidebarSubspacePresentationTests.testWorkspaceMoveIndicesSkipSubspacesInTheWindowOrder`, `SidebarSessionPresentationTests.testDurationTextStaysWithinTheReservedElapsedTemplate`, 7 banner/sheet-copy tests in `CodexSkillsManagementSheetTests` | call into SwiftUI view types (`ToasttyCommandMenus`, `AppWindowView`, `SidebarView`, the skills sheet) |
| `ToasttyAppDefaultsTests` (3), `ToasttySettingsStoreTests` (1), `GettingStartedEligibilityTests` (1) | `AppKitDefaultPreferences` (AppKit tooltip/window-restoration defaults) |
| `TerminalCommandClickTargetResolverTests` app-bundle tests (2) | macOS app bundles; Linux has no package directories |
| `SidebarSessionPresentationTests` (2 assertions) | swift-foundation `AttributedString` has no presentation intents |
| `ProfileShellIntegrationInstallerTests` HISTCMD assertion; zsh tests skip without `/bin/zsh` | macOS `/bin/bash` 3.2 quirk; zsh is not installed on stock Ubuntu |
| `AgentHookDispatcherTests.realProcessHonoringSIGTERMReportsTimeoutWithoutForceKill` | corelibs `Process` reports exit only after every inheritor of its monitor descriptor exits (the orphaned `sleep` hides it) |
| `RemotePushRelayClientTests` redirect section | corelibs traps when a custom `URLProtocol` reports a redirect |
| `RemoteAccessGatewayServerTests`: `webSocketSubscribeReceivesBroadcasts`, `disconnectingDeviceSweepsAllMatchingSocketsAndIsolatesOtherDevice`, `disconnectAllSweepsEveryDeviceSocket`, `sendScopeDowngradeKeepsReadSocketAliveAndRejectsSendImmediately` | corelibs `URLSessionWebSocketTask.receive()` never completes after a server close; covered by `LinuxGatewayWebSocketTests` and the Remote Access integration test instead |
| `ManagedAgentNativeSessionObserverTests.observerCapturesCodexSessionFromShellSnapshot` | backdates a file's mtime; Linux birth times cannot move earlier |
| `AgentLaunchServiceTests.launchQuotesDirectLaunchEnvironmentAndArgv` | disabled only when the host has `/tmp/.git` (its fixture path is a literal `/tmp` path) |
| `AutomationSocketServerBrowserPanelTargetingTests` (2), `AutomationSocketServerLocalDocumentPanelTests` (4) | pending the WebKitGTK panel runtimes (need a live browser host / local-document loading) |

## Known issues

- App layer, swift-testing: run `ToasttyAppLogicTests` through `test.sh`
  (isolated defaults); tests in one process share `UserDefaults`, and a test
  that leaves Remote Access preferences behind changes later suites.
- corelibs `NotificationCenter.addObserver(forName:object:queue: .main)`
  blocks the poster until the main queue runs the observer. In the app every
  post comes from the main thread (no wait); a post from a background thread
  waits for the main loop, and one from main-actor code running off the main
  thread (Swift Testing) deadlocks, which is why the two Linux-compiled
  observers use no target queue.
- `RemoteAccessGatewayServerTests.stopAndRestartKeepsExistingCredentialValid`
  can fail when other gateway tests run concurrently: corelibs
  `URLSession.shared` merges its cookie jar (keyed by host, not port) into
  the explicit `Cookie` header.
- The WebKitGTK local-document panel loads, renders, edits and watches
  files itself; the app-logic `LocalDocumentPanelRuntime` only forwards
  commands to it, so `panel.localDocument.state` over the socket reports file
  and format from the panel state, and the 6 socket tests listed above stay
  disabled.
- `automation.capture_screenshot` forces a layout pass before snapshotting
  (Broadway without a viewer never ticks the frame clock, so a window whose
  state just changed had no allocation). Under Broadway the Ghostty texture
  in the capture can lag the terminal contents; on a real display it is
  current. `scripts/linux/e2e-app-logic.sh` checks that a PNG is written.
- The command palette catalog and `CommandPaletteActionHandler` are not
  compiled; gtk-shell's `LinuxCommandTable` drives the palette.

- `toastty diagnostics collect` with very large logs is slow on Linux
  (`diagnosticsCollectFitsOversizedLogsWithinSubmissionLimit` takes ~30 s):
  corelibs `NSRegularExpression` redaction over ~20 MB is much slower than on
  macOS.
- `SetupResourceResolver` looks for resources at `<executable>/../Resources`
  (the macOS bundle layout). Linux packaging must either install them there or
  set `TOASTTY_APP_RESOURCES_PATH` (e.g. `Sources/App/Resources` in a
  checkout); `toastty setup guide` fails without one of them.
- `main.swift` mirrors keep their name (SwiftPM requires it), so the CLI and
  agent shim targets each print one `#fileID` conflict warning.
