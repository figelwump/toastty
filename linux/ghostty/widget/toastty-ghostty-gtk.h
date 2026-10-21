/* toastty-ghostty-gtk: a GTK4 widget that embeds a Ghostty terminal.
 *
 * This library sits on top of libghostty (ghostty.h) built from Toastty's
 * Ghostty fork with the Linux/OpenGL embedded platform. It provides:
 *
 *  - a runtime helper (toastty_ghostty_app_new) that wires ghostty's
 *    runtime callbacks to the GLib main loop and GdkClipboard, and calls a
 *    host action handler FIRST for every action so the host can claim it;
 *  - ToasttyGhosttySurface, a GtkWidget owning one ghostty_surface_t, with
 *    keyboard (incl. IME), mouse, scroll, focus, resize/scale and
 *    rendering.
 *
 * The host can keep driving ghostty_* directly: every widget exposes its
 * ghostty_surface_t, and the default callbacks are public so a host that
 * builds its own ghostty_runtime_config_s can reuse them.
 *
 * Threading: everything here must be used from the GTK main thread.
 */
#ifndef TOASTTY_GHOSTTY_GTK_H
#define TOASTTY_GHOSTTY_GTK_H

#include <gtk/gtk.h>
#include <ghostty.h>

G_BEGIN_DECLS

/* ---------------------------------------------------------------------- */
/* Library initialization                                                  */

/* Calls ghostty_init() once per process. If GHOSTTY_RESOURCES_DIR is unset,
 * points it at the resources installed next to libghostty (terminfo, shell
 * integration, themes) so spawned shells get TERM=xterm-ghostty and shell
 * integration. Safe to call more than once. Returns FALSE if ghostty_init
 * fails. */
gboolean toastty_ghostty_init (int argc, char **argv);

/* The resources directory in use (GHOSTTY_RESOURCES_DIR after init), or NULL. */
const char *toastty_ghostty_resources_dir (void);

/* ---------------------------------------------------------------------- */
/* Runtime helper                                                          */

/* Host action handler. Invoked first, on the main thread, for every action
 * ghostty performs (app- and surface-targeted). Return TRUE to claim the
 * action; the default handling (see toastty_ghostty_handle_action) then
 * does not run and TRUE is reported to ghostty. */
typedef gboolean (*ToasttyGhosttyActionFunc) (ghostty_app_t app,
                                              ghostty_target_s target,
                                              ghostty_action_s action,
                                              gpointer user_data);

typedef struct
{
  ToasttyGhosttyActionFunc action_func;
  gpointer action_user_data;
  /* Opt in to OSC 7501 program status reports (Toastty sets TRUE). */
  gboolean supports_program_status;
  gpointer reserved[8];
} ToasttyGhosttyRuntimeOptions;

/* Creates a ghostty app whose runtime callbacks are the defaults below.
 * `config` is not consumed (ghostty clones it). `options` may be NULL.
 * The app's userdata (ghostty_app_userdata) is owned by this library. */
ghostty_app_t toastty_ghostty_app_new (ghostty_config_t config,
                                       const ToasttyGhosttyRuntimeOptions *options);

/* Frees an app created with toastty_ghostty_app_new. Free (destroy) all of
 * its surfaces first. */
void toastty_ghostty_app_free (ghostty_app_t app);

/* The action_user_data passed to toastty_ghostty_app_new. */
gpointer toastty_ghostty_app_get_user_data (ghostty_app_t app);

/* Schedules a ghostty_app_tick on the main loop (coalesced). Thread-safe. */
void toastty_ghostty_app_schedule_tick (ghostty_app_t app);

/* Default handling for an action: RENDER (queue redraw), MOUSE_SHAPE,
 * MOUSE_VISIBILITY, and the widget signals below (title, pwd, bell, child
 * exited, command finished, link hover, OSC 7501 program status/reset,
 * renderer health). Returns TRUE if handled. Hosts that install their own
 * action callback should forward unclaimed actions here. */
gboolean toastty_ghostty_handle_action (ghostty_app_t app,
                                        ghostty_target_s target,
                                        ghostty_action_s action);

/* Fills `config` with this library's default callbacks (wakeup, action,
 * clipboard read/confirm/write, close surface). The wakeup callback expects
 * the runtime's own userdata, so hosts that set config->userdata themselves
 * must replace wakeup_cb with one that calls toastty_ghostty_app_schedule_tick.
 * The clipboard and close callbacks expect the surface userdata that
 * ToasttyGhosttySurface installs, so they work for any app. */
void toastty_ghostty_runtime_config_init (ghostty_runtime_config_s *config);

/* The default runtime callbacks, for hosts composing their own config. */
ghostty_clipboard_read_result_e toastty_ghostty_read_clipboard_cb (void *surface_userdata,
                                                                   ghostty_clipboard_e location,
                                                                   void *state,
                                                                   const char *const *mimes,
                                                                   size_t n_mimes,
                                                                   bool list);
void toastty_ghostty_confirm_read_clipboard_cb (void *surface_userdata,
                                                const ghostty_clipboard_confirm_s *confirm,
                                                void *state,
                                                ghostty_clipboard_request_e request);
void toastty_ghostty_write_clipboard_cb (void *surface_userdata,
                                         ghostty_clipboard_e location,
                                         const ghostty_clipboard_content_s *contents,
                                         size_t n_contents,
                                         bool confirm);
void toastty_ghostty_close_surface_cb (void *surface_userdata, bool process_alive);

/* ---------------------------------------------------------------------- */
/* ToasttyGhosttySurface                                                   */

typedef enum
{
  /* GPU path: frames are exported as DMA-BUFs and imported zero-copy with
   * GdkDmabufTextureBuilder (needs a GL-capable GDK display). */
  TOASTTY_GHOSTTY_RENDERER_GL = 0,
  /* Offscreen fallback: frames are read back from the surfaceless EGL
   * framebuffer into CPU memory and presented as GdkMemoryTexture. Used
   * automatically where GDK has no GL (Broadway, some remote sessions) or
   * when DMA-BUF import fails. */
  TOASTTY_GHOSTTY_RENDERER_OFFSCREEN = 1,
} ToasttyGhosttyRenderer;

typedef enum
{
  TOASTTY_GHOSTTY_NAVIGATION_BACK = 0,
  TOASTTY_GHOSTTY_NAVIGATION_FORWARD = 1,
} ToasttyGhosttyNavigation;

#define TOASTTY_GHOSTTY_TYPE_SURFACE (toastty_ghostty_surface_get_type ())
G_DECLARE_FINAL_TYPE (ToasttyGhosttySurface, toastty_ghostty_surface, TOASTTY_GHOSTTY, SURFACE, GtkWidget)

/* Creates the widget and its ghostty surface immediately, so the
 * ghostty_surface_t is valid as soon as this returns.
 *
 * `config` may be NULL (ghostty_surface_config_new defaults) and is copied:
 * working_directory, command, env_vars, initial_input, font_size,
 * wait_after_command, context and scale_factor are honored. platform_tag
 * and platform are overridden with GHOSTTY_PLATFORM_LINUX. config->userdata
 * is stored as the widget's user data (toastty_ghostty_surface_get_user_data);
 * ghostty's own surface userdata is owned by this library.
 *
 * Returns NULL if the surface cannot be created. */
GtkWidget *toastty_ghostty_surface_new (ghostty_app_t app,
                                        const ghostty_surface_config_s *config);

ghostty_surface_t toastty_ghostty_surface_get_surface (ToasttyGhosttySurface *self);
ghostty_app_t toastty_ghostty_surface_get_app (ToasttyGhosttySurface *self);
gpointer toastty_ghostty_surface_get_user_data (ToasttyGhosttySurface *self);

/* Widget owning `surface`, or NULL. Works for any ghostty_surface_t. */
ToasttyGhosttySurface *toastty_ghostty_surface_from_surface (ghostty_surface_t surface);

/* Last title / working directory reported by the terminal, or NULL. */
const char *toastty_ghostty_surface_get_title (ToasttyGhosttySurface *self);
const char *toastty_ghostty_surface_get_pwd (ToasttyGhosttySurface *self);

/* Active presentation path. Chosen automatically; override with the
 * environment variable TOASTTY_GHOSTTY_RENDERER=gl|offscreen. */
ToasttyGhosttyRenderer toastty_ghostty_surface_get_renderer (ToasttyGhosttySurface *self);

/* Key interception. Called for every key press and release BEFORE the
 * input method and ghostty see it. Return TRUE to consume the event (app
 * shortcuts). `pressed` is FALSE for releases. */
typedef gboolean (*ToasttyGhosttyKeyFilterFunc) (ToasttyGhosttySurface *self,
                                                 guint keyval,
                                                 guint keycode,
                                                 GdkModifierType state,
                                                 gboolean pressed,
                                                 gpointer user_data);

void toastty_ghostty_surface_set_key_filter (ToasttyGhosttySurface *self,
                                             ToasttyGhosttyKeyFilterFunc func,
                                             gpointer user_data,
                                             GDestroyNotify destroy);

/* Synthetic input through the same translation path the key controller
 * uses (mods, sided mods, consumed mods via the display keymap, unshifted
 * codepoint, XKB remap, repeat detection). For tests and automation where
 * real GdkEvents cannot be injected. `keycode` may be 0 to look it up from
 * `keyval`; `keyval` may be 0 to translate it from `keycode` + `state`.
 * Returns TRUE if ghostty consumed the key. */
gboolean toastty_ghostty_surface_send_key (ToasttyGhosttySurface *self,
                                           guint keyval,
                                           guint keycode,
                                           GdkModifierType state,
                                           gboolean pressed);

/* Sends `text` as an input-method commit outside a key event (on-screen
 * keyboard / IME path): it is encoded as typed text, not as a paste. */
void toastty_ghostty_surface_commit_text (ToasttyGhosttySurface *self, const char *text);

/* The newest frame as a texture (borrowed), or NULL before the first frame.
 * Pulls a pending frame from the renderer if GTK has not painted it yet.
 * Rows are in OpenGL order (bottom row first); the widget flips them when
 * drawing. */
GdkTexture *toastty_ghostty_surface_get_texture (ToasttyGhosttySurface *self);

/* Signals (all emitted on the main thread):
 *
 *  "title-changed"        (const char *title)
 *  "pwd-changed"          (const char *pwd)
 *  "bell"                 ()
 *  "close-requested"      (gboolean process_alive)   -- emitted from an idle
 *  "child-exited"         (guint exit_code, guint64 runtime_ms)
 *  "command-finished"     (gint exit_code /-1 = unknown/, guint64 duration_ns)
 *  "link-hover"           (const char *url /NULL when cleared/)
 *  "program-status"       (gpointer const ghostty_action_program_status_s *,
 *                          borrowed for the emission only)
 *  "program-status-reset" (gint ghostty_program_status_reset_e)
 *  "renderer-health"      (gboolean healthy)
 *  "mouse-navigation"     (gint ToasttyGhosttyNavigation) -> gboolean handled;
 *                         mouse buttons 8/9. If a handler returns TRUE the
 *                         press/release is not sent to the terminal.
 *  "context-menu"         (gdouble x, gdouble y) right click not consumed by
 *                         the terminal (mouse reporting off).
 *
 * Properties: "title", "pwd" (read-only strings).
 */

G_END_DECLS

#endif /* TOASTTY_GHOSTTY_GTK_H */
