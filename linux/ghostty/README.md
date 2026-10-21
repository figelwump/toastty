# Ghostty on Linux (libghostty + GTK4 widget)

This directory builds Toastty's Ghostty terminal for the Linux port:

- `libghostty.so`: Ghostty's embedded runtime (`-Dapp-runtime=none`) from
  Toastty's fork, plus the patches in `patches/` that add a Linux/OpenGL
  embedded platform.
- `libtoastty-ghostty-gtk.so`: a C GTK4 widget (`ToasttyGhosttySurface`)
  and a GLib-main-loop runtime helper for `ghostty_app_t`.
- `GhosttyKit/`: a Clang module map so Swift code keeps `import GhosttyKit`.
- `demo/`: `toastty-ghostty-demo`, two terminals in a `GtkPaned`.
- `test/`: an end-to-end test that runs under a private GDK Broadway display.

Ghostty source: [`figelwump/ghostty`](https://github.com/figelwump/ghostty)
branch `toastty-downstream`, pinned to
`056ffe2a80aab09c478946406dc7ec1b489d4ac3` (the commit
`docs/ghostty-integration.md` pins for macOS), built with Zig 0.16.0. The
downstream embedder APIs Toastty relies on (`ghostty_surface_is_at_prompt`,
the OSC 7501 program-status bridge, link hover with a modifier held) are
unchanged.

## Build

```bash
linux/ghostty/build-libghostty.sh
```

The script is idempotent. It:

1. Installs Zig 0.16.0 into `~/.local/toolchains/zig-x86_64-linux-0.16.0`
   if it is missing (no root needed).
2. Clones the fork into `linux/.deps/ghostty-src` and applies
   `patches/*.patch` with `git am` onto the pinned commit. A stamp in
   `.git/toastty-patches.stamp` skips this when nothing changed. It refuses to
   touch a checkout with uncommitted changes unless `TOASTTY_GHOSTTY_FORCE=1`.
3. Runs `zig build -Dapp-runtime=none -Dsentry=false -Demit-docs=false
   -Doptimize=$TOASTTY_GHOSTTY_OPTIMIZE -Dcpu=$TOASTTY_GHOSTTY_CPU`.
4. Installs into `linux/.deps/ghostty/`:

   | Path | Contents |
   |---|---|
   | `include/ghostty.h` | the patched embedder header (API-compatible with macOS) |
   | `include/toastty-ghostty-gtk.h` | the widget/runtime header |
   | `lib/libghostty.so` | libghostty, shared (SONAME `libghostty.so`; needs `libEGL.so.1`, libc, libm) |
   | `lib/libtoastty-ghostty-gtk.so` | the widget (RUNPATH `$ORIGIN`, finds libghostty next to it) |
   | `lib/pkgconfig/toastty-ghostty.pc` | `Requires: gtk4`, links both libraries |
   | `share/terminfo/` | compiled `xterm-ghostty` / `ghostty` terminfo |
   | `share/ghostty/shell-integration/`, `share/ghostty/themes/` | runtime resources |
   | `bin/toastty-ghostty-demo`, `bin/toastty-ghostty-test` | demo and test binaries |
   | `ghostty-metadata.env` | pinned commit, patched HEAD, build flags, patch list |

5. Generates `keymap-generated.h` from the Ghostty sources
   (`widget/gen-keymap.py`) and builds the widget, demo and test with `cc`.

Environment:

| Variable | Default | Meaning |
|---|---|---|
| `TOASTTY_GHOSTTY_OPTIMIZE` | `ReleaseFast` | Zig optimize mode. Use `Debug` while developing (assertions, faster incremental builds). |
| `TOASTTY_GHOSTTY_CPU` | `baseline` | `-Dcpu`; `baseline` keeps the library portable across x86-64 CPUs, `native` tunes for this machine. |
| `TOASTTY_GHOSTTY_SKIP_LIB` | `0` | `1` rebuilds only the widget, demo and test. |
| `TOASTTY_GHOSTTY_FORCE` | `0` | `1` discards local changes in the checkout when re-applying patches. |

Typical times on a 16-core machine: a ReleaseFast/baseline libghostty
build takes about 3.5 minutes (dependencies cached); a Debug rebuild after a
Zig change takes about 20 seconds; a widget-only rebuild takes a couple of
seconds. The ReleaseFast `libghostty.so` is about 33 MB with symbols.

The library is shipped as a shared object. Zig also emits a static archive
(`ghostty-internal.a`, ~235 MB in Debug, with bundled C++ dependencies), which
the build does not install; linking it would also require `-lEGL -lc++`.

### Changing Ghostty

Edit and commit in `linux/.deps/ghostty-src` (any branch on top of the
pinned commit), then:

```bash
linux/ghostty/export-patches.sh   # git format-patch <pinned>..HEAD -> patches/
linux/ghostty/build-libghostty.sh
```

## Patches

Each patch is a self-contained commit meant to be upstreamed to the fork.

| Patch | Why |
|---|---|
| `0001-build-install-runtime-resources-for-libghostty-on-Li` | With `-Dapp-runtime=none`, Ghostty installs no terminfo, shell integration or themes; embedders on Linux have no app bundle to supply them. |
| `0002-build-link-the-GL-EGL-loader-into-libghostty-on-Linu` | The OpenGL renderer creates its own surfaceless EGL context, but glad (GL + EGL) and libEGL were only linked into executables, leaving `libghostty.so` with undefined `egl*`/`glad*` symbols. libEGL is linked by name rather than pkg-config so the sysroot's include path cannot shadow bundled headers (simdutf). |
| `0003-embedded-add-a-Linux-OpenGL-platform-with-host-prese` | The embedded apprt only accepted macOS/iOS views. Adds `GHOSTTY_PLATFORM_LINUX` and a frame API: `ghostty_surface_take_frame`, `ghostty_frame_release`, `ghostty_surface_set_presentation_health`, `ghostty_surface_set_display_realized`. |
| `0004-embedded-accept-an-explicit-key-for-remapped-key-eve` | GTK's apprt remaps the physical key through the keyval (XKB options like `caps:escape`, keypad navigation keys that have no physical code). The embedded key event only carries a native keycode, so this adds `ghostty_surface_key_ex` / `ghostty_surface_key_is_binding_ex` taking a `ghostty_input_key_e`. |
| `0005-embedded-serve-the-primary-selection-on-Linux` | The embedded apprt hard-coded the primary clipboard as unsupported. On Linux the selection clipboard is the X11/Wayland primary selection, which the GTK apprt also uses for OSC 52 `p`. |
| `0006-embedded-export-ghostty_surface_set_display_id-on-ev` | `ghostty.h` declares `ghostty_surface_set_display_id` for every platform, but it was only exported on Darwin. Toastty's shared Swift terminal code calls it, so it would not link on Linux. It is a no-op off Darwin. Every other `ghostty_*` function Toastty's Swift sources use is exported. |

### Why there is no GtkGLArea

The pinned fork no longer renders in the host's GL context. Upstream commit
`2f0b65346` ("gtk,opengl: free us from the clutches of GtkGLArea") moved the
OpenGL renderer onto its render thread with its own surfaceless EGL context.
It renders into an FBO and exports each finished frame as a DMA-BUF, or as
CPU pixels read back with `glReadPixels` when the host cannot import
DMA-BUFs. Ghostty's GTK app presents those frames from a plain widget's
`snapshot()` (`src/apprt/gtk/class/render_surface.zig`).

The Linux embedded platform exposes exactly that model, so there is no
`ghostty_surface_draw`-from-GLArea path. A host-owned GL context would mean
reverting upstream's renderer architecture. The widget therefore:

- **GL path** (`TOASTTY_GHOSTTY_RENDERER=gl`): imports DMA-BUF frames
  zero-copy with `GdkDmabufTextureBuilder`. It is selected when
  `gdk_display_prepare_gl` succeeds.
- **Offscreen path** (`TOASTTY_GHOSTTY_RENDERER=offscreen`): reports
  `UNHEALTHY` presentation health, so the renderer reads frames back from
  its surfaceless EGL (Mesa or vendor) FBO, and presents a
  `GdkMemoryTexture`. It is selected automatically on Broadway or when GDK
  has no GL. The widget also falls back to it at runtime when a DMA-BUF
  import fails (unsupported modifier, multi-GPU), exactly like Ghostty's GTK
  app.

Frames are bottom-up (OpenGL origin); the widget flips them in `snapshot()`.

## Runtime notes

- Call `toastty_ghostty_init()` once, before anything else. It runs
  `ghostty_init` and, if `GHOSTTY_RESOURCES_DIR` is unset, points it at
  `<prefix>/share/ghostty` next to `libghostty.so`. Ghostty then exports
  `TERM=xterm-ghostty`, `TERMINFO` and shell integration to child processes.
  When packaging, keep `share/terminfo` and `share/ghostty` beside `lib/` or
  set `GHOSTTY_RESOURCES_DIR`.
- Ghostty logs to stderr. Debug builds are verbose.
- Everything runs on the GTK main thread. `wakeup` may fire on any thread;
  the runtime helper coalesces it into one idle `ghostty_app_tick`.

## C API (`toastty-ghostty-gtk.h`)

### Runtime helper

```c
gboolean      toastty_ghostty_init (int argc, char **argv);
const char   *toastty_ghostty_resources_dir (void);

typedef gboolean (*ToasttyGhosttyActionFunc) (ghostty_app_t, ghostty_target_s,
                                              ghostty_action_s, gpointer user_data);
typedef struct {
  ToasttyGhosttyActionFunc action_func;   /* called FIRST for every action; TRUE claims it */
  gpointer action_user_data;
  gboolean supports_program_status;      /* OSC 7501 opt-in (Toastty: TRUE) */
  gpointer reserved[8];
} ToasttyGhosttyRuntimeOptions;

ghostty_app_t toastty_ghostty_app_new (ghostty_config_t, const ToasttyGhosttyRuntimeOptions *);
void          toastty_ghostty_app_free (ghostty_app_t);          /* destroy its widgets first */
gpointer      toastty_ghostty_app_get_user_data (ghostty_app_t);  /* action_user_data */
void          toastty_ghostty_app_schedule_tick (ghostty_app_t);  /* thread-safe */
gboolean      toastty_ghostty_handle_action (ghostty_app_t, ghostty_target_s, ghostty_action_s);
```

The defaults installed by `toastty_ghostty_app_new`:

- wakeup: an idle `ghostty_app_tick` on the default main context, coalesced.
- action: the host `action_func` first. If it returns FALSE,
  `toastty_ghostty_handle_action` runs. That handles `RENDER` (queue a
  redraw), `MOUSE_SHAPE` and `MOUSE_VISIBILITY` (cursor names), and turns
  title, pwd, bell, child exit, command finished, link hover, OSC 7501
  status/reset and renderer health into widget signals. Do not claim
  `RENDER` without forwarding it, or the widget stops redrawing.
- clipboard: `GdkClipboard`. `STANDARD` maps to `gtk_widget_get_clipboard`;
  `SELECTION`/`PRIMARY` map to `gtk_widget_get_primary_clipboard`. Reads
  support `text/plain` and arbitrary MIME types (Kitty clipboard), plus MIME
  listings. Writes publish every MIME given, with text also offered as a
  string. Confirmations (unsafe paste, OSC 52 read/write) emit
  `clipboard-confirm`; if nothing handles it, a `GtkAlertDialog` asks.
- close: emits `close-requested` from an idle.

Hosts that build their own `ghostty_runtime_config_s` can reuse
`toastty_ghostty_runtime_config_init()` and the exported callbacks
`toastty_ghostty_{read,confirm_read,write}_clipboard_cb` and
`toastty_ghostty_close_surface_cb`. Those take the surface userdata the
widget installs, so they work for any app. Such a host must set its own
`wakeup_cb` (e.g. scheduling `ghostty_app_tick` on the main loop) and
forward unclaimed actions to `toastty_ghostty_handle_action`.

### Widget

```c
GtkWidget *toastty_ghostty_surface_new (ghostty_app_t, const ghostty_surface_config_s *config);
```

This creates the widget and its `ghostty_surface_t` immediately. `config`
may be NULL; it is copied. `working_directory`, `command`, `env_vars`,
`initial_input`, `font_size`, `wait_after_command`, `context` and
`scale_factor` apply. `platform_tag`/`platform` are forced to
`GHOSTTY_PLATFORM_LINUX`. `config->userdata` becomes the widget's user data.
Ghostty's own surface userdata belongs to the library.

| Function | Purpose |
|---|---|
| `toastty_ghostty_surface_get_surface` / `_get_app` / `_get_user_data` | underlying handles |
| `toastty_ghostty_surface_from_surface (ghostty_surface_t)` | widget lookup (NULL if none) |
| `toastty_ghostty_surface_get_title` / `_get_pwd` | last reported values (also properties `title`, `pwd`) |
| `toastty_ghostty_surface_get_renderer` | `TOASTTY_GHOSTTY_RENDERER_GL` or `_OFFSCREEN` |
| `toastty_ghostty_surface_set_key_filter (self, func, data, destroy)` | host hook called for every key press/release **before** the IME and Ghostty; return TRUE to consume (app shortcuts) |
| `toastty_ghostty_surface_send_key (self, keyval, keycode, state, pressed)` | synthetic key through the real translation path (tests/automation) |
| `toastty_ghostty_surface_commit_text (self, text)` | IME-commit-style text input (typed, not pasted) |
| `toastty_ghostty_surface_get_texture` | newest frame as a `GdkTexture` (bottom-up rows) |

Signals:

| Signal | Arguments |
|---|---|
| `title-changed` | `const char *title` |
| `pwd-changed` | `const char *pwd` |
| `bell` | none |
| `close-requested` | `gboolean process_alive` (emitted from an idle) |
| `child-exited` | `guint exit_code, guint64 runtime_ms` |
| `command-finished` | `gint exit_code` (-1 unknown), `guint64 duration_ns` |
| `link-hover` | `const char *url` (NULL when cleared) |
| `program-status` | `gpointer` to `const ghostty_action_program_status_s` (borrowed for the emission) |
| `program-status-reset` | `gint` `ghostty_program_status_reset_e` |
| `renderer-health` | `gboolean healthy` |
| `mouse-navigation` | `gint` `ToasttyGhosttyNavigation` (buttons 8/9) → `gboolean handled`; handled presses are not sent to the terminal |
| `context-menu` | `gdouble x, gdouble y` for a right click the terminal did not consume |
| `clipboard-confirm` | `gpointer confirm, gpointer state, gint request` → `gboolean handled`; a handler that returns TRUE must later call `ghostty_surface_complete_clipboard_request` or `ghostty_surface_deny_clipboard_request` with `state` |

Input handling follows Ghostty's GTK apprt (`src/apprt/gtk/class/surface.zig`
and `key.zig`):

- **Keys**: `GtkEventControllerKey`, routed through `GtkIMMulticontext` with
  the same composing/commit state machine. Keycodes are GDK hardware (XKB)
  keycodes. The physical key comes from Ghostty's XKB table, then the XKB
  remap through the keyval. Mods include sided mods taken from the physical
  key and num lock from the device. Consumed mods come from
  `gdk_key_event_get_consumed_modifiers`. The unshifted codepoint is level 0
  of the event's layout. Repeats are detected and sent as
  `GHOSTTY_ACTION_REPEAT`. The IME cursor rectangle comes from
  `ghostty_surface_ime_point`.
- **Mouse**: buttons 1 to 11. A press grabs focus. Middle-click honors
  `gtk-enable-primary-paste`. Motion, enter and leave are handled; leave
  sends -1/-1.
- **Scroll**: vertical scroll is precise (touchpad, ×10) or discrete,
  inverted and scaled like GTK. Horizontal scroll is forwarded.
- **Focus**: delivered to Ghostty from an idle. App-level focus
  (`ghostty_app_set_focus`) is the host's job; the demo ties it to the
  window's `is-active`.
- **Scale**: the content scale is the `GdkSurface` (fractional) scale ×
  `gtk-xft-dpi`/96, like GTK. The size is sent in device pixels. Mouse and
  IME coordinates are corrected for the xft factor. The widget follows
  `notify::scale` and `notify::gtk-xft-dpi`.
- **Visibility**: map/unmap → `ghostty_surface_set_occlusion`;
  realize/unrealize → `ghostty_surface_set_display_realized`.

Lifetime: disposing the widget never frees the Ghostty surface
synchronously. Dispose can run inside a Ghostty callback, for example when a
signal handler destroys the widget. The free happens from an idle, and
`toastty_ghostty_app_free` flushes pending frees.

## Swift (`GhosttyKit`)

`GhosttyKit/module.modulemap` declares `module GhosttyKit [system]` over
`GhosttyKit.h`, which includes `ghostty.h` and `toastty-ghostty-gtk.h` and
links `toastty-ghostty-gtk` and `ghostty`. Add it to `linux/Package.swift`
as a system library (this snippet was verified with a scratch package that
also imports the gtk-shell `CGtk` module):

```swift
// GhosttyKit: libghostty + the Toastty GTK4 widget (linux/ghostty).
// Build first: linux/ghostty/build-libghostty.sh
// PKG_CONFIG_PATH must include linux/.deps/ghostty/lib/pkgconfig.
.systemLibrary(
    name: "GhosttyKit",
    path: "ghostty/GhosttyKit",
    pkgConfig: "toastty-ghostty"
),
// ...and in the consuming target:
.target(
    name: "ToasttyLinuxTerminal",
    dependencies: ["CGtk", "GhosttyKit"],
    linkerSettings: [
        // SwiftPM drops pkg-config's -Wl,-rpath; add it for dev builds.
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "\(linuxRoot)/.deps/ghostty/lib"]),
    ]
),
```

Add `export PKG_CONFIG_PATH="$TOASTTY_LINUX_ROOT/.deps/ghostty/lib/pkgconfig:$PKG_CONFIG_PATH"`
to `linux/env.sh`, or set it in the build script. Owners of `linux/env.sh`
and `linux/Package.swift` wire this up; this directory does not edit them.

Minimal Swift usage (from the interop check):

```swift
import CGtk
import GhosttyKit

_ = toastty_ghostty_init(CommandLine.argc, CommandLine.unsafeArgv)
let config = ghostty_config_new()
ghostty_config_load_default_files(config)
ghostty_config_finalize(config)
var opts = ToasttyGhosttyRuntimeOptions()
opts.supports_program_status = 1
opts.action_func = { app, target, action, userData in
    // Claim what the host handles; return 0 to fall through to the widget.
    return 0
}
let app = toastty_ghostty_app_new(config, &opts)!
ghostty_config_free(config)

var cfg = ghostty_surface_config_new()
let widget = toastty_ghostty_surface_new(app, &cfg)!        // UnsafeMutablePointer<GtkWidget>
let term = OpaquePointer(widget)                            // ToasttyGhosttySurface*
let surface = toastty_ghostty_surface_get_surface(term)     // ghostty_surface_t for shared code
```

Notes from the interop check:

- `GtkWidget` values from `GhosttyKit` and `CGtk` are the same Swift type,
  so `gtk_window_set_child(window, toastty_ghostty_surface_new(app, &cfg))`
  compiles directly.
- `ToasttyGhosttySurface *` imports as `OpaquePointer` (the GObject struct is
  opaque); cast the `GtkWidget` pointer with `OpaquePointer(widget)`.
- `ghostty_action_s` unions, `ghostty_surface_config_s` and
  `ToasttyGhosttyRuntimeOptions` are usable directly. C callbacks can be
  Swift closures that capture nothing; pass context through
  `action_user_data`.
- SwiftPM warns that it drops pkg-config's `-pthread` and `-Wl,-rpath`.
  This is harmless; supply the rpath as shown above.

## Testing

```bash
linux/ghostty/test/run-tests.sh            # builds (incrementally) then tests
linux/ghostty/test/run-tests.sh --no-build
```

The script starts a private `gtk4-broadwayd`. It tries display :47 and
moves up when the port is taken. The test gets an empty
`XDG_RUNTIME_DIR`, no session or accessibility bus, no Wayland or X11, and
in-memory GSettings, so nothing touches the desktop session. It then runs
`toastty-ghostty-test`, which:

1. creates a surface running `/bin/sh` and waits for a presented frame and a
   prompt (offscreen renderer, selected automatically on Broadway);
2. types `echo ghostty-` with synthetic key events through the widget's key
   translation, `linux-ok` through the IME commit path, then Enter, and
   polls `ghostty_surface_read_text` for an output line `ghostty-linux-ok`;
3. renders the widget through its real `snapshot()` with GSK's Cairo
   renderer. It checks that the image is non-uniform and upright (text at
   the top, plain background at the bottom) and saves
   `artifacts/manual/ghostty-linux/ghostty-linux-frame.png`;
4. resizes the widget, waits for the grid to grow (e.g. 63x17 → 99x30),
   checks that the new frame matches the new pixel size, and saves
   `ghostty-linux-frame-resized.png`;
5. runs clipboard round trips. OSC 52 `c` and `p` writes from the shell must
   reach the standard clipboard and the primary selection. Text set on the
   `GdkClipboard` and pasted with `paste_from_clipboard` must reach the
   shell (`echo pasted-$((40+2))` → `pasted-42`);
6. checks that the key filter consumes F12 before Ghostty;
7. checks that `exit` is reported through `ghostty_surface_process_exited`.

It exits non-zero on the first failure and prints the screen contents.

The same binary also passes against a private Xvfb display (`GDK_BACKEND=x11`,
GL through llvmpipe), which covers GL selection and the DMA-BUF import
fallback. Xvfb is not installed system-wide; it was unpacked from the
Ubuntu `xvfb` package (`apt-get download xvfb && dpkg -x`) into
`linux/.deps/ghostty-xvfb/`, and that run is not scripted.

The demo also has a headless screenshot mode:
`TOASTTY_GHOSTTY_DEMO_SCREENSHOT=out.png toastty-ghostty-demo` under
Broadway.

## Known limitations

- **The DMA-BUF (GL) path is verified only manually.** Run against a live
  Ubuntu 26.04 GNOME Wayland session (GdkWaylandDisplay, 1.5x scale) on
  2026-10-20, `TOASTTY_GHOSTTY_RENDERER=gl bin/toastty-ghostty-test` passed
  every check and ended on `gl (dmabuf)` with no fallback. The automated
  `run-tests.sh` covers only Broadway (no GL) and Xvfb, where GDK rejects the
  renderer's tiled DMA-BUFs and the widget switches to offscreen
  presentation. `TOASTTY_GHOSTTY_RENDERER=offscreen` forces the fallback if
  the GL path misbehaves.
- Broadway without a connected browser never paints after the first frame,
  so the test reads frames with `toastty_ghostty_surface_get_texture` and
  renders the widget's `snapshot()` directly, not through GTK's frame clock.
- Synthetic keys (`send_key`) cannot run the input method; they skip
  `gtk_im_context_filter_keypress`. On Broadway, keycodes are ignored
  because Broadway reports keyvals as keycodes, so keys map through the
  keyval only.
- No `ghostty_surface_set_color_scheme` integration: the host should follow
  `AdwStyleManager` and call `ghostty_app_set_color_scheme`.
- The GTK apprt's X11-specific modifier fix-ups (`winproto.eventMods`) and
  its "first click only focuses the split" suppression are not replicated.
- The terminal inspector (`ghostty_inspector_*`) is Metal-only upstream and
  is not available on Linux.
- Ghostty logs go to stderr; there is no hook into GLib logging.
- `toastty_ghostty_runtime_config_init` cannot provide a wakeup callback
  for host-owned userdata. Such hosts must supply their own (see above).
