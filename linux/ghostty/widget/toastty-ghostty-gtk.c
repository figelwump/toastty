/* toastty-ghostty-gtk: GTK4 widget embedding a Ghostty terminal.
 *
 * Input translation mirrors Ghostty's own GTK apprt
 * (src/apprt/gtk/class/surface.zig keyEvent and the ec and im handlers,
 * src/apprt/gtk/key.zig)
 * and presentation mirrors its RenderSurface (render_surface.zig): the
 * OpenGL renderer renders on its own thread into a surfaceless EGL
 * framebuffer and exports frames; we pull them in snapshot() and present
 * them as GdkDmabufTexture (GPU path) or GdkMemoryTexture (offscreen path).
 */
#define _GNU_SOURCE
#define G_LOG_DOMAIN "toastty-ghostty"

#include "toastty-ghostty-gtk.h"

#include <dlfcn.h>
#include <math.h>
#include <string.h>

#include "keymap-generated.h"

/* ====================================================================== */
/* Latency trace (TOASTTY_GHOSTTY_LATENCY_TRACE=1)                        */

/* Off by default. When set, every key press is followed through the
 * pipeline and one line per key is written to stderr:
 *   key->(ghostty_surface_key returned) ->first wakeup ->tick ->RENDER
 *   ->snapshot (changed frame pulled) ->after-paint
 * all in milliseconds since the key event reached the widget, plus main
 * loop iterations that were busy (not polling) for >= 8 ms. Typing is
 * serial, so one in-flight record is enough. */
typedef struct
{
  gint64 key;        /* key event reached the widget */
  gint64 key_done;   /* ghostty_surface_key returned */
  gint64 wakeup;     /* first wakeup_cb after the key (any thread) */
  gint64 tick;       /* first ghostty_app_tick after that wakeup */
  gint64 render;     /* first RENDER action */
  gint64 snapshot;   /* first snapshot that pulled a changed frame */
  gint64 paint;      /* frame clock after-paint following that snapshot */
  guint keyval;
  guint32 key_hash;  /* CPU frames: hash of the frame on screen at the key */
  int unchanged;     /* CPU frames identical to key_hash pulled meanwhile */
} LatencyRecord;

static int latency_trace = -1;
static LatencyRecord trace_rec;
static guint32 trace_last_hash;   /* hash of the last CPU frame pulled */
static gboolean trace_frame_unchanged;
static gpointer trace_wakeup_atomic; /* gintptr time; written from any thread */
static gint trace_armed;            /* atomic: a key is in flight */

static gboolean
latency_tracing (void)
{
  if (G_UNLIKELY (latency_trace < 0))
    {
      const char *env = g_getenv ("TOASTTY_GHOSTTY_LATENCY_TRACE");
      latency_trace = env != NULL && *env != '\0' && g_strcmp0 (env, "0") != 0;
    }
  return latency_trace;
}

static double
trace_ms (gint64 t)
{
  return t > 0 && trace_rec.key > 0 ? (double) (t - trace_rec.key) / 1000.0 : -1.0;
}

static void
latency_trace_flush (void)
{
  if (trace_rec.key == 0)
    return;
  gint64 wakeup = (gint64) (gintptr) g_atomic_pointer_get (&trace_wakeup_atomic);
  g_printerr ("toastty-ghostty latency: keyval=0x%x key_handled=%.2f wakeup=%.2f tick=%.2f "
              "render=%.2f snapshot=%.2f paint=%.2f unchanged_frames=%d\n",
              trace_rec.keyval, trace_ms (trace_rec.key_done), trace_ms (wakeup),
              trace_ms (trace_rec.tick), trace_ms (trace_rec.render),
              trace_ms (trace_rec.snapshot), trace_ms (trace_rec.paint), trace_rec.unchanged);
  memset (&trace_rec, 0, sizeof trace_rec);
  g_atomic_int_set (&trace_armed, 0);
  g_atomic_pointer_set (&trace_wakeup_atomic, NULL);
}

static void
latency_trace_key (guint keyval)
{
  latency_trace_flush ();
  trace_rec.key = g_get_monotonic_time ();
  trace_rec.keyval = keyval;
  trace_rec.key_hash = trace_last_hash;
  g_atomic_int_set (&trace_armed, 1);
}

static void
latency_trace_wakeup (void)
{
  if (!g_atomic_int_get (&trace_armed))
    return;
  gintptr now = (gintptr) g_get_monotonic_time ();
  g_atomic_pointer_compare_and_exchange (&trace_wakeup_atomic, NULL, (gpointer) now);
}

static void
latency_trace_mark (gint64 *slot)
{
  if (trace_rec.key != 0 && *slot == 0)
    *slot = g_get_monotonic_time ();
}

/* CPU (offscreen) frames are hashed so that `snapshot`/`paint` mark the
 * first frame whose contents differ from what was on screen at the key.
 * DMA-BUF frames cannot be compared cheaply: the first frame counts. */
static void
latency_trace_frame (const ghostty_frame_s *frame)
{
  trace_frame_unchanged = FALSE;
  if (frame->kind != GHOSTTY_FRAME_MEMORY || frame->pixels == NULL)
    return;
  guint32 h = 2166136261u;
  const guint32 *px = (const guint32 *) frame->pixels;
  for (size_t i = 0; i < frame->pixels_len / 4; i++)
    h = (h ^ px[i]) * 16777619u;
  trace_frame_unchanged = trace_rec.key != 0 && h == trace_rec.key_hash;
  if (trace_frame_unchanged)
    trace_rec.unchanged++;
  trace_last_hash = h;
}

/* Main-loop busy detector: time spent between two polls. */
static GPollFunc trace_default_poll = NULL;
static gint64 trace_poll_returned = 0;

static gint
latency_trace_poll (GPollFD *ufds, guint nfds, gint timeout)
{
  gint64 start = g_get_monotonic_time ();
  if (trace_poll_returned != 0 && start - trace_poll_returned >= 8000)
    g_printerr ("toastty-ghostty latency: main loop busy %.2f ms\n",
                (double) (start - trace_poll_returned) / 1000.0);
  gint ret = trace_default_poll (ufds, nfds, timeout);
  trace_poll_returned = g_get_monotonic_time ();
  return ret;
}

static void
latency_trace_install_poll (void)
{
  if (!latency_tracing () || trace_default_poll != NULL)
    return;
  GMainContext *ctx = g_main_context_default ();
  trace_default_poll = g_main_context_get_poll_func (ctx);
  g_main_context_set_poll_func (ctx, latency_trace_poll);
}

/* ====================================================================== */
/* Library init                                                           */

static char *resources_dir = NULL;

static char *
default_resources_dir (void)
{
  /* libghostty.so lives in <prefix>/lib; resources in <prefix>/share/ghostty
   * with terminfo in <prefix>/share/terminfo (Ghostty's own layout). */
  Dl_info info;
  if (dladdr ((void *) ghostty_init, &info) == 0 || info.dli_fname == NULL)
    return NULL;
  g_autofree char *real = realpath (info.dli_fname, NULL);
  g_autofree char *libdir = g_path_get_dirname (real ? real : info.dli_fname);
  g_autofree char *prefix = g_path_get_dirname (libdir);
  char *dir = g_build_filename (prefix, "share", "ghostty", NULL);
  g_autofree char *sentinel = g_build_filename (prefix, "share", "terminfo", "x", "xterm-ghostty", NULL);
  if (g_file_test (sentinel, G_FILE_TEST_EXISTS))
    return dir;
  g_free (dir);
  return NULL;
}

gboolean
toastty_ghostty_init (int argc, char **argv)
{
  static gsize once = 0;
  static gboolean ok = FALSE;
  if (g_once_init_enter (&once))
    {
      const char *env = g_getenv ("GHOSTTY_RESOURCES_DIR");
      if (env == NULL || *env == '\0')
        {
          char *dir = default_resources_dir ();
          if (dir != NULL)
            g_setenv ("GHOSTTY_RESOURCES_DIR", dir, TRUE);
          g_free (dir);
        }
      resources_dir = g_strdup (g_getenv ("GHOSTTY_RESOURCES_DIR"));

      char *fallback_argv[] = { (char *) "toastty", NULL };
      if (argv == NULL)
        {
          argc = 1;
          argv = fallback_argv;
        }
      ok = ghostty_init ((uintptr_t) argc, argv) == GHOSTTY_SUCCESS;
      g_once_init_leave (&once, 1);
    }
  return ok;
}

const char *
toastty_ghostty_resources_dir (void)
{
  return resources_dir;
}

/* ====================================================================== */
/* Runtime                                                                */

typedef struct
{
  ghostty_app_t app;
  ToasttyGhosttyActionFunc action_func;
  gpointer action_user_data;
  gint tick_scheduled; /* atomic */
  gboolean freed;      /* main thread only */
} Runtime;

/* Surface handle: ghostty's surface userdata. Outlives the widget so that
 * late callbacks and in-flight clipboard reads stay safe, and so that
 * ghostty_surface_free never runs inside a ghostty callback. */
typedef struct
{
  ToasttyGhosttySurface *widget; /* NULL once the widget is disposed */
  ghostty_surface_t surface;     /* NULL once freed */
  ghostty_app_t app;
} SurfaceHandle;

static GMutex runtimes_lock;
static GHashTable *runtimes = NULL;        /* ghostty_app_t -> Runtime* */
static GHashTable *surface_handles = NULL; /* ghostty_surface_t -> SurfaceHandle* (live widgets) */
static GList *pending_frees = NULL;        /* SurfaceHandle* awaiting ghostty_surface_free */

static Runtime *
runtime_lookup (ghostty_app_t app)
{
  Runtime *rt = NULL;
  g_mutex_lock (&runtimes_lock);
  if (runtimes != NULL)
    rt = g_hash_table_lookup (runtimes, app);
  g_mutex_unlock (&runtimes_lock);
  return rt;
}

static gboolean
runtime_tick_idle (gpointer data)
{
  Runtime *rt = data;
  g_atomic_int_set (&rt->tick_scheduled, 0);
  if (G_UNLIKELY (latency_trace > 0) && g_atomic_pointer_get (&trace_wakeup_atomic) != NULL)
    latency_trace_mark (&trace_rec.tick);
  if (!rt->freed && rt->app != NULL)
    ghostty_app_tick (rt->app);
  return G_SOURCE_REMOVE;
}

static void
runtime_unref (gpointer data)
{
  g_atomic_rc_box_release (data);
}

static void
runtime_schedule_tick (Runtime *rt)
{
  if (!g_atomic_int_compare_and_exchange (&rt->tick_scheduled, 0, 1))
    return;
  g_idle_add_full (G_PRIORITY_DEFAULT, runtime_tick_idle,
                   g_atomic_rc_box_acquire (rt), runtime_unref);
}

static void
runtime_wakeup_cb (void *userdata)
{
  if (G_UNLIKELY (latency_trace > 0))
    latency_trace_wakeup ();
  if (userdata != NULL)
    runtime_schedule_tick (userdata);
}

void
toastty_ghostty_app_schedule_tick (ghostty_app_t app)
{
  Runtime *rt = runtime_lookup (app);
  if (rt != NULL)
    runtime_schedule_tick (rt);
}

static bool
runtime_action_cb (ghostty_app_t app, ghostty_target_s target, ghostty_action_s action)
{
  Runtime *rt = runtime_lookup (app);
  if (rt != NULL && rt->action_func != NULL &&
      rt->action_func (app, target, action, rt->action_user_data))
    return true;
  return toastty_ghostty_handle_action (app, target, action);
}

void
toastty_ghostty_runtime_config_init (ghostty_runtime_config_s *config)
{
  memset (config, 0, sizeof *config);
  config->userdata = NULL;
  config->supports_selection_clipboard = true;
  config->wakeup_cb = runtime_wakeup_cb;
  config->action_cb = runtime_action_cb;
  config->read_clipboard_cb = toastty_ghostty_read_clipboard_cb;
  config->confirm_read_clipboard_cb = toastty_ghostty_confirm_read_clipboard_cb;
  config->write_clipboard_cb = toastty_ghostty_write_clipboard_cb;
  config->close_surface_cb = toastty_ghostty_close_surface_cb;
  config->supports_program_status = false;
}

ghostty_app_t
toastty_ghostty_app_new (ghostty_config_t config, const ToasttyGhosttyRuntimeOptions *options)
{
  latency_trace_install_poll ();
  Runtime *rt = g_atomic_rc_box_new0 (Runtime);
  if (options != NULL)
    {
      rt->action_func = options->action_func;
      rt->action_user_data = options->action_user_data;
    }

  ghostty_runtime_config_s rc;
  toastty_ghostty_runtime_config_init (&rc);
  rc.userdata = rt;
  rc.supports_program_status = options != NULL && options->supports_program_status;

  ghostty_app_t app = ghostty_app_new (&rc, config);
  if (app == NULL)
    {
      g_atomic_rc_box_release (rt);
      return NULL;
    }
  rt->app = app;

  g_mutex_lock (&runtimes_lock);
  if (runtimes == NULL)
    runtimes = g_hash_table_new (g_direct_hash, g_direct_equal);
  g_hash_table_insert (runtimes, app, rt);
  g_mutex_unlock (&runtimes_lock);
  return app;
}

static void surface_handle_free_now (SurfaceHandle *h);

void
toastty_ghostty_app_free (ghostty_app_t app)
{
  if (app == NULL)
    return;

  /* Free surfaces whose widgets were disposed but whose deferred free has
   * not run yet: they must go before the app. */
  for (GList *l = pending_frees; l != NULL;)
    {
      GList *next = l->next;
      SurfaceHandle *h = l->data;
      if (h->app == app)
        {
          pending_frees = g_list_delete_link (pending_frees, l);
          surface_handle_free_now (h);
        }
      l = next;
    }

  Runtime *rt = NULL;
  g_mutex_lock (&runtimes_lock);
  if (runtimes != NULL)
    {
      rt = g_hash_table_lookup (runtimes, app);
      g_hash_table_remove (runtimes, app);
    }
  g_mutex_unlock (&runtimes_lock);

  ghostty_app_free (app);
  if (rt != NULL)
    {
      rt->freed = TRUE;
      rt->app = NULL;
      g_atomic_rc_box_release (rt);
    }
}

gpointer
toastty_ghostty_app_get_user_data (ghostty_app_t app)
{
  Runtime *rt = runtime_lookup (app);
  return rt != NULL ? rt->action_user_data : NULL;
}

/* ====================================================================== */
/* Widget                                                                 */

typedef enum
{
  IN_KEYEVENT_FALSE,
  IN_KEYEVENT_NOT_COMPOSING,
  IN_KEYEVENT_COMPOSING,
} InKeyEvent;

struct _ToasttyGhosttySurface
{
  GtkWidget parent_instance;

  ghostty_app_t app;
  ghostty_surface_t surface;
  SurfaceHandle *handle;
  gpointer user_data;

  char *title;
  char *pwd;

  /* Presentation */
  ToasttyGhosttyRenderer renderer;
  gboolean renderer_forced;
  GdkTexture *texture;

  /* Size and scale */
  double scale;    /* GdkSurface scale (fractional) */
  double xft;      /* gtk-xft-dpi / 96 */
  guint dev_width; /* device pixels sent to ghostty */
  guint dev_height;
  GdkSurface *scale_surface;
  gulong scale_notify_id;
  gulong xft_notify_id;

  /* Keyboard */
  GtkIMContext *im;
  gboolean im_composing;
  InKeyEvent in_keyevent;
  char im_buf[128];
  gsize im_len;
  GHashTable *held_keycodes;
  ToasttyGhosttyKeyFilterFunc key_filter;
  gpointer key_filter_data;
  GDestroyNotify key_filter_destroy;

  /* Mouse */
  ghostty_action_mouse_shape_e mouse_shape;
  gboolean mouse_hidden;
  double cursor_x;
  double cursor_y;
  gboolean precision_scroll;
  guint suppressed_buttons; /* bitmask of buttons whose release we drop */

  gboolean focused;

  GdkFrameClock *trace_clock; /* latency trace only */
  gulong trace_paint_id;
};

G_DEFINE_FINAL_TYPE (ToasttyGhosttySurface, toastty_ghostty_surface, GTK_TYPE_WIDGET)

enum
{
  PROP_0,
  PROP_TITLE,
  PROP_PWD,
  N_PROPS,
};
static GParamSpec *props[N_PROPS];

enum
{
  SIG_TITLE_CHANGED,
  SIG_PWD_CHANGED,
  SIG_BELL,
  SIG_CLOSE_REQUESTED,
  SIG_CHILD_EXITED,
  SIG_COMMAND_FINISHED,
  SIG_LINK_HOVER,
  SIG_PROGRAM_STATUS,
  SIG_PROGRAM_STATUS_RESET,
  SIG_RENDERER_HEALTH,
  SIG_MOUSE_NAVIGATION,
  SIG_CONTEXT_MENU,
  SIG_CLIPBOARD_CONFIRM,
  N_SIGNALS,
};
static guint signals[N_SIGNALS];

static gboolean
display_is_broadway (GdkDisplay *display)
{
  return display != NULL && g_str_equal (G_OBJECT_TYPE_NAME (display), "GdkBroadwayDisplay");
}

/* ---------------------------------------------------------------------- */
/* Surface handles                                                        */

static void
surface_handle_free_now (SurfaceHandle *h)
{
  if (h->surface != NULL)
    ghostty_surface_free (h->surface);
  h->surface = NULL;
  g_atomic_rc_box_release (h);
}

static gboolean
surface_handle_free_idle (gpointer data)
{
  SurfaceHandle *h = data;
  GList *link = g_list_find (pending_frees, h);
  if (link == NULL)
    return G_SOURCE_REMOVE; /* already freed (toastty_ghostty_app_free or
                             * toastty_ghostty_free_all_surfaces) */
  pending_frees = g_list_delete_link (pending_frees, link);
  surface_handle_free_now (h);
  return G_SOURCE_REMOVE;
}

void
toastty_ghostty_free_all_surfaces (void)
{
  if (surface_handles != NULL)
    {
      GHashTableIter iter;
      gpointer value;
      g_hash_table_iter_init (&iter, surface_handles);
      while (g_hash_table_iter_next (&iter, NULL, &value))
        {
          SurfaceHandle *h = value;
          if (h->widget != NULL)
            {
              h->widget->handle = NULL;
              h->widget->surface = NULL;
              h->widget = NULL;
            }
          g_hash_table_iter_remove (&iter);
          pending_frees = g_list_prepend (pending_frees, h);
        }
    }
  while (pending_frees != NULL)
    {
      SurfaceHandle *h = pending_frees->data;
      pending_frees = g_list_delete_link (pending_frees, pending_frees);
      surface_handle_free_now (h);
    }
}

ToasttyGhosttySurface *
toastty_ghostty_surface_from_surface (ghostty_surface_t surface)
{
  if (surface == NULL || surface_handles == NULL)
    return NULL;
  SurfaceHandle *h = g_hash_table_lookup (surface_handles, surface);
  return h != NULL ? h->widget : NULL;
}

static ToasttyGhosttySurface *
widget_for_target (ghostty_target_s target)
{
  if (target.tag != GHOSTTY_TARGET_SURFACE)
    return NULL;
  return toastty_ghostty_surface_from_surface (target.target.surface);
}

/* ---------------------------------------------------------------------- */
/* Rendering                                                              */

typedef struct
{
  ghostty_frame_s frame;
} FrameHolder;

static void
frame_holder_free (gpointer data)
{
  FrameHolder *holder = data;
  ghostty_frame_release (&holder->frame);
  g_free (holder);
}

static void
set_renderer (ToasttyGhosttySurface *self, ToasttyGhosttyRenderer renderer)
{
  if (self->surface == NULL)
    return;
  self->renderer = renderer;
  ghostty_surface_set_presentation_health (
      self->surface,
      renderer == TOASTTY_GHOSTTY_RENDERER_GL ? GHOSTTY_RENDERER_HEALTH_HEALTHY
                                              : GHOSTTY_RENDERER_HEALTH_UNHEALTHY);
}

static GdkTexture *
texture_from_frame (ToasttyGhosttySurface *self, ghostty_frame_s *frame, GError **error)
{
  FrameHolder *holder = g_new0 (FrameHolder, 1);
  holder->frame = *frame;
  memset (frame, 0, sizeof *frame);

  if (holder->frame.kind == GHOSTTY_FRAME_MEMORY)
    {
      GBytes *bytes = g_bytes_new_with_free_func (holder->frame.pixels,
                                                  holder->frame.pixels_len,
                                                  frame_holder_free, holder);
      GdkTexture *texture = gdk_memory_texture_new (
          (int) holder->frame.width, (int) holder->frame.height,
          holder->frame.premultiplied ? GDK_MEMORY_R8G8B8A8_PREMULTIPLIED : GDK_MEMORY_R8G8B8A8,
          bytes, holder->frame.stride);
      g_bytes_unref (bytes);
      return texture;
    }

  if (holder->frame.kind == GHOSTTY_FRAME_DMABUF)
    {
      GdkDmabufTextureBuilder *builder = gdk_dmabuf_texture_builder_new ();
      gdk_dmabuf_texture_builder_set_display (builder, gtk_widget_get_display (GTK_WIDGET (self)));
      gdk_dmabuf_texture_builder_set_width (builder, holder->frame.width);
      gdk_dmabuf_texture_builder_set_height (builder, holder->frame.height);
      gdk_dmabuf_texture_builder_set_fourcc (builder, holder->frame.fourcc);
      gdk_dmabuf_texture_builder_set_modifier (builder, holder->frame.modifier);
      gdk_dmabuf_texture_builder_set_premultiplied (builder, holder->frame.premultiplied);
      gdk_dmabuf_texture_builder_set_n_planes (builder, holder->frame.n_planes);
      for (guint i = 0; i < holder->frame.n_planes && i < 4; i++)
        {
          gdk_dmabuf_texture_builder_set_fd (builder, i, holder->frame.fds[i]);
          gdk_dmabuf_texture_builder_set_offset (builder, i, holder->frame.offsets[i]);
          gdk_dmabuf_texture_builder_set_stride (builder, i, holder->frame.strides[i]);
        }
      GdkTexture *texture = gdk_dmabuf_texture_builder_build (builder, frame_holder_free, holder, error);
      g_object_unref (builder);
      if (texture == NULL)
        frame_holder_free (holder);
      return texture;
    }

  frame_holder_free (holder);
  g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "unknown frame kind");
  return NULL;
}

static void
pull_frame (ToasttyGhosttySurface *self)
{
  if (self->surface == NULL)
    return;

  ghostty_frame_s frame;
  if (!ghostty_surface_take_frame (self->surface, &frame))
    return;

  if (G_UNLIKELY (latency_trace > 0))
    latency_trace_frame (&frame);
  g_autoptr (GError) error = NULL;
  gboolean was_dmabuf = frame.kind == GHOSTTY_FRAME_DMABUF;
  GdkTexture *texture = texture_from_frame (self, &frame, &error);
  if (texture == NULL)
    {
      if (was_dmabuf)
        {
          /* GTK cannot import our DMA-BUFs (no GL, incompatible modifier,
           * multi-GPU, ...): switch to CPU readback, like the GTK apprt. */
          g_message ("DMA-BUF import failed (%s); using offscreen presentation",
                     error ? error->message : "unknown");
          set_renderer (self, TOASTTY_GHOSTTY_RENDERER_OFFSCREEN);
        }
      else
        g_warning ("failed to build texture: %s", error ? error->message : "unknown");
      return;
    }

  g_clear_object (&self->texture);
  self->texture = texture;
  if (G_UNLIKELY (latency_trace > 0) && trace_rec.render != 0 && !trace_frame_unchanged)
    latency_trace_mark (&trace_rec.snapshot);
}

static void
toastty_ghostty_surface_snapshot (GtkWidget *widget, GtkSnapshot *snapshot)
{
  ToasttyGhosttySurface *self = TOASTTY_GHOSTTY_SURFACE (widget);
  pull_frame (self);
  if (self->texture == NULL)
    return;

  int width = gtk_widget_get_width (widget);
  int height = gtk_widget_get_height (widget);
  if (width <= 0 || height <= 0)
    return;

  /* Map one texel to one device pixel. */
  double scale = self->scale > 0 ? self->scale : 1.0;
  float css_w = (float) (gdk_texture_get_width (self->texture) / scale);
  float css_h = (float) (gdk_texture_get_height (self->texture) / scale);

  gtk_snapshot_push_clip (snapshot, &GRAPHENE_RECT_INIT (0, 0, width, height));
  gtk_snapshot_save (snapshot);
  /* OpenGL frames are bottom-up. */
  gtk_snapshot_translate (snapshot, &GRAPHENE_POINT_INIT (0, css_h));
  gtk_snapshot_scale (snapshot, 1, -1);
  gtk_snapshot_append_texture (snapshot, self->texture, &GRAPHENE_RECT_INIT (0, 0, css_w, css_h));
  gtk_snapshot_restore (snapshot);
  gtk_snapshot_pop (snapshot);
}

/* ---------------------------------------------------------------------- */
/* Size and scale                                                         */

static double
read_xft_scale (void)
{
  GtkSettings *settings = gtk_settings_get_default ();
  if (settings == NULL)
    return 1.0;
  int dpi = -1;
  g_object_get (settings, "gtk-xft-dpi", &dpi, NULL);
  if (dpi <= 0)
    return 1.0;
  return ((double) dpi / 1024.0) / 96.0;
}

static double
widget_surface_scale (GtkWidget *widget)
{
  GtkNative *native = gtk_widget_get_native (widget);
  if (native != NULL)
    {
      GdkSurface *surface = gtk_native_get_surface (native);
      if (surface != NULL)
        {
          double scale = gdk_surface_get_scale (surface);
          if (scale > 0)
            return scale;
        }
    }
  int factor = gtk_widget_get_scale_factor (widget);
  return factor > 0 ? factor : 1.0;
}

static void
update_size (ToasttyGhosttySurface *self, int css_width, int css_height)
{
  if (self->surface == NULL)
    return;

  self->scale = widget_surface_scale (GTK_WIDGET (self));
  double content = self->scale * self->xft;
  ghostty_surface_set_content_scale (self->surface, content, content);

  if (css_width <= 0 || css_height <= 0)
    return;
  guint w = (guint) lround (css_width * self->scale);
  guint h = (guint) lround (css_height * self->scale);
  if (w == 0 || h == 0)
    return;
  self->dev_width = w;
  self->dev_height = h;
  ghostty_surface_set_size (self->surface, w, h);
}

static void
on_scale_notify (GdkSurface *surface, GParamSpec *pspec, ToasttyGhosttySurface *self)
{
  GtkWidget *widget = GTK_WIDGET (self);
  update_size (self, gtk_widget_get_width (widget), gtk_widget_get_height (widget));
  gtk_widget_queue_draw (widget);
}

static void
on_xft_notify (GtkSettings *settings, GParamSpec *pspec, ToasttyGhosttySurface *self)
{
  GtkWidget *widget = GTK_WIDGET (self);
  self->xft = read_xft_scale ();
  update_size (self, gtk_widget_get_width (widget), gtk_widget_get_height (widget));
}

static void
connect_scale_notify (ToasttyGhosttySurface *self)
{
  GtkNative *native = gtk_widget_get_native (GTK_WIDGET (self));
  GdkSurface *surface = native ? gtk_native_get_surface (native) : NULL;
  if (surface == self->scale_surface)
    return;
  if (self->scale_surface != NULL)
    {
      g_signal_handler_disconnect (self->scale_surface, self->scale_notify_id);
      g_clear_object (&self->scale_surface);
      self->scale_notify_id = 0;
    }
  if (surface != NULL)
    {
      self->scale_surface = g_object_ref (surface);
      self->scale_notify_id = g_signal_connect (surface, "notify::scale",
                                                G_CALLBACK (on_scale_notify), self);
    }
}

static void
toastty_ghostty_surface_size_allocate (GtkWidget *widget, int width, int height, int baseline)
{
  ToasttyGhosttySurface *self = TOASTTY_GHOSTTY_SURFACE (widget);
  connect_scale_notify (self);
  update_size (self, width, height);
  GTK_WIDGET_CLASS (toastty_ghostty_surface_parent_class)->size_allocate (widget, width, height, baseline);
}

static void
toastty_ghostty_surface_measure (GtkWidget *widget, GtkOrientation orientation, int for_size,
                                 int *minimum, int *natural, int *minimum_baseline, int *natural_baseline)
{
  *minimum = 1;
  *natural = orientation == GTK_ORIENTATION_HORIZONTAL ? 640 : 400;
}

/* Mouse positions: ghostty multiplies by the content scale (surface scale *
 * xft), while device pixels are CSS * surface scale, so divide out xft. */
static void
css_to_ghostty (ToasttyGhosttySurface *self, double *x, double *y)
{
  double xft = self->xft > 0 ? self->xft : 1.0;
  *x /= xft;
  *y /= xft;
}

/* ---------------------------------------------------------------------- */
/* Realize / map                                                          */

static void
on_trace_after_paint (GdkFrameClock *clock, ToasttyGhosttySurface *self)
{
  if (trace_rec.snapshot != 0 && trace_rec.paint == 0)
    {
      latency_trace_mark (&trace_rec.paint);
      latency_trace_flush ();
    }
}

static void
toastty_ghostty_surface_realize (GtkWidget *widget)
{
  ToasttyGhosttySurface *self = TOASTTY_GHOSTTY_SURFACE (widget);
  GTK_WIDGET_CLASS (toastty_ghostty_surface_parent_class)->realize (widget);
  connect_scale_notify (self);
  if (latency_tracing ())
    {
      self->trace_clock = g_object_ref (gtk_widget_get_frame_clock (widget));
      self->trace_paint_id = g_signal_connect (self->trace_clock, "after-paint",
                                               G_CALLBACK (on_trace_after_paint), self);
    }
  if (self->surface != NULL)
    ghostty_surface_set_display_realized (self->surface, true);
  gtk_im_context_set_client_widget (self->im, widget);
  gtk_widget_queue_draw (widget);
}

static void
toastty_ghostty_surface_unrealize (GtkWidget *widget)
{
  ToasttyGhosttySurface *self = TOASTTY_GHOSTTY_SURFACE (widget);
  if (self->scale_surface != NULL)
    {
      g_signal_handler_disconnect (self->scale_surface, self->scale_notify_id);
      g_clear_object (&self->scale_surface);
      self->scale_notify_id = 0;
    }
  g_clear_object (&self->texture);
  if (self->trace_clock != NULL)
    {
      g_signal_handler_disconnect (self->trace_clock, self->trace_paint_id);
      g_clear_object (&self->trace_clock);
      self->trace_paint_id = 0;
    }
  if (self->surface != NULL)
    ghostty_surface_set_display_realized (self->surface, false);
  gtk_im_context_set_client_widget (self->im, NULL);
  GTK_WIDGET_CLASS (toastty_ghostty_surface_parent_class)->unrealize (widget);
}

static void
toastty_ghostty_surface_map (GtkWidget *widget)
{
  ToasttyGhosttySurface *self = TOASTTY_GHOSTTY_SURFACE (widget);
  GTK_WIDGET_CLASS (toastty_ghostty_surface_parent_class)->map (widget);
  if (self->surface != NULL)
    ghostty_surface_set_occlusion (self->surface, true);
}

static void
toastty_ghostty_surface_unmap (GtkWidget *widget)
{
  ToasttyGhosttySurface *self = TOASTTY_GHOSTTY_SURFACE (widget);
  if (self->surface != NULL)
    ghostty_surface_set_occlusion (self->surface, false);
  GTK_WIDGET_CLASS (toastty_ghostty_surface_parent_class)->unmap (widget);
}

/* ---------------------------------------------------------------------- */
/* Keyboard                                                               */

static ghostty_input_mods_e
translate_mods (GdkModifierType state)
{
  int mods = GHOSTTY_MODS_NONE;
  if (state & GDK_SHIFT_MASK)
    mods |= GHOSTTY_MODS_SHIFT;
  if (state & GDK_CONTROL_MASK)
    mods |= GHOSTTY_MODS_CTRL;
  if (state & GDK_ALT_MASK)
    mods |= GHOSTTY_MODS_ALT;
  if (state & GDK_SUPER_MASK)
    mods |= GHOSTTY_MODS_SUPER;
  /* Lock depends on X settings; assume caps lock like Ghostty does. */
  if (state & GDK_LOCK_MASK)
    mods |= GHOSTTY_MODS_CAPS;
  return (ghostty_input_mods_e) mods;
}

static gboolean
is_modifier_keyval (guint keyval)
{
  switch (keyval)
    {
    case GDK_KEY_Shift_L:
    case GDK_KEY_Shift_R:
    case GDK_KEY_Shift_Lock:
    case GDK_KEY_Control_L:
    case GDK_KEY_Control_R:
    case GDK_KEY_Caps_Lock:
    case GDK_KEY_Meta_L:
    case GDK_KEY_Meta_R:
    case GDK_KEY_Alt_L:
    case GDK_KEY_Alt_R:
    case GDK_KEY_Super_L:
    case GDK_KEY_Super_R:
    case GDK_KEY_Hyper_L:
    case GDK_KEY_Hyper_R:
    case GDK_KEY_Num_Lock:
    case GDK_KEY_Mode_switch:
    case GDK_KEY_ISO_Lock:
    case GDK_KEY_ISO_Level2_Latch:
    case GDK_KEY_ISO_Level3_Shift:
    case GDK_KEY_ISO_Level3_Latch:
    case GDK_KEY_ISO_Level3_Lock:
    case GDK_KEY_ISO_Level5_Shift:
    case GDK_KEY_ISO_Level5_Latch:
    case GDK_KEY_ISO_Level5_Lock:
    case GDK_KEY_ISO_Group_Latch:
    case GDK_KEY_ISO_Group_Lock:
      return TRUE;
    default:
      return FALSE;
    }
}

static ghostty_input_key_e
physical_key_for_keycode (guint keycode)
{
  for (gsize i = 0; i < G_N_ELEMENTS (tg_xkb_map); i++)
    if (tg_xkb_map[i].xkb == keycode)
      return tg_xkb_map[i].key;
  return GHOSTTY_KEY_UNIDENTIFIED;
}

static gboolean
key_for_keyval (guint keyval, ghostty_input_key_e *out)
{
  for (gsize i = 0; i < G_N_ELEMENTS (tg_keyval_map); i++)
    if (tg_keyval_map[i].keyval == keyval)
      {
        *out = tg_keyval_map[i].key;
        return TRUE;
      }
  return FALSE;
}

/* src/apprt/gtk/key.zig remapKey */
static ghostty_input_key_e
remap_key (ghostty_input_key_e physical, guint keyval, gboolean is_modifier)
{
  ghostty_input_key_e remapped;
  if (key_for_keyval (keyval, &remapped))
    {
      if (!tg_key_is_writing_system (physical) || !tg_key_is_writing_system (remapped))
        return remapped;
    }
  if (is_modifier || is_modifier_keyval (keyval))
    return GHOSTTY_KEY_UNIDENTIFIED;
  return physical;
}

/* src/apprt/gtk/key.zig keyvalUnicodeUnshifted */
static guint32
unshifted_codepoint (GdkDisplay *display, guint keycode, guint layout, guint keyval)
{
  if (keycode != 0 && !display_is_broadway (display))
    {
      GdkKeymapKey *keys = NULL;
      guint *keyvals = NULL;
      int n = 0;
      guint32 result = 0;
      if (gdk_display_map_keycode (display, keycode, &keys, &keyvals, &n))
        {
          for (int i = 0; i < n; i++)
            if ((guint) keys[i].group == layout && keys[i].level == 0)
              {
                result = gdk_keyval_to_unicode (keyvals[i]);
                break;
              }
          g_free (keys);
          g_free (keyvals);
        }
      return result;
    }
  /* Broadway has no real keymap: approximate with the lowercase keyval. */
  return gdk_keyval_to_unicode (gdk_keyval_to_lower (keyval));
}

static void
set_bell_ringing (ToasttyGhosttySurface *self, gboolean ringing)
{
  (void) self;
  (void) ringing;
}

static void
update_ime_cursor (ToasttyGhosttySurface *self)
{
  if (self->surface == NULL)
    return;
  double x = 0, y = 0, w = 0, h = 0;
  ghostty_surface_ime_point (self->surface, &x, &y, &w, &h);
  double xft = self->xft > 0 ? self->xft : 1.0;
  GdkRectangle rect = {
    .x = (int) (x * xft),
    .y = (int) (y * xft),
    .width = 1,
    .height = 1,
  };
  gtk_im_context_set_cursor_location (self->im, &rect);
}

/* The heart of keyboard input: src/apprt/gtk/class/surface.zig keyEvent.
 * `event` is NULL for synthetic input. */
static gboolean
process_key (ToasttyGhosttySurface *self,
             gboolean pressed,
             GdkEvent *event,
             guint keyval,
             guint keycode,
             GdkModifierType state,
             GdkModifierType consumed_state,
             guint layout,
             gboolean event_is_modifier,
             gboolean num_lock)
{
  if (G_UNLIKELY (latency_trace > 0) && pressed)
    latency_trace_key (keyval);

  if (self->key_filter != NULL &&
      self->key_filter (self, keyval, keycode, state, pressed, self->key_filter_data))
    return TRUE;

  if (self->surface == NULL)
    return FALSE;

  /* Repeat detection: GTK reports repeats as further presses. */
  ghostty_input_action_e action;
  if (pressed)
    {
      gpointer key = GUINT_TO_POINTER (keycode ? keycode : keyval | 0x80000000u);
      action = g_hash_table_contains (self->held_keycodes, key) ? GHOSTTY_ACTION_REPEAT
                                                                 : GHOSTTY_ACTION_PRESS;
      g_hash_table_add (self->held_keycodes, key);
    }
  else
    {
      g_hash_table_remove (self->held_keycodes,
                           GUINT_TO_POINTER (keycode ? keycode : keyval | 0x80000000u));
      action = GHOSTTY_ACTION_RELEASE;
    }

  if (event != NULL)
    {
      update_ime_cursor (self);

      self->in_keyevent = self->im_composing ? IN_KEYEVENT_COMPOSING : IN_KEYEVENT_NOT_COMPOSING;
      gboolean im_handled = gtk_im_context_filter_keypress (self->im, event);
      InKeyEvent in_keyevent = self->in_keyevent;
      self->in_keyevent = IN_KEYEVENT_FALSE;

      if (im_handled)
        {
          /* Preedit (e.g. a dead key): don't encode. */
          if (self->im_composing)
            return TRUE;
          /* Composition committed by this key: don't encode it too. */
          if (in_keyevent == IN_KEYEVENT_COMPOSING)
            return TRUE;
          /* Handled without text (e.g. IME switched modes). */
          if (self->im_len == 0)
            return TRUE;
        }
    }

  GdkDisplay *display = gtk_widget_get_display (GTK_WIDGET (self));
  gboolean broadway = display_is_broadway (display);

  guint32 keyval_unicode = gdk_keyval_to_unicode (keyval);
  guint32 unshifted = unshifted_codepoint (display, keycode, layout, keyval);

  /* Physical key from the hardware (XKB) keycode, remapped through the
   * keyval for non-writing-system keys. Broadway reports keyvals as
   * keycodes, so only trust the keyval there. */
  ghostty_input_key_e physical =
      broadway ? GHOSTTY_KEY_UNIDENTIFIED : physical_key_for_keycode (keycode);
  ghostty_input_key_e key = remap_key (physical, keyval, event_is_modifier);

  int mods = translate_mods (state);
  if (num_lock)
    mods |= GHOSTTY_MODS_NUM;
  gboolean down = action != GHOSTTY_ACTION_RELEASE;
  switch (key)
    {
    case GHOSTTY_KEY_SHIFT_LEFT:
      mods = down ? (mods | GHOSTTY_MODS_SHIFT) : (mods & ~GHOSTTY_MODS_SHIFT);
      break;
    case GHOSTTY_KEY_SHIFT_RIGHT:
      mods = (down ? (mods | GHOSTTY_MODS_SHIFT) : (mods & ~GHOSTTY_MODS_SHIFT)) | GHOSTTY_MODS_SHIFT_RIGHT;
      break;
    case GHOSTTY_KEY_CONTROL_LEFT:
      mods = down ? (mods | GHOSTTY_MODS_CTRL) : (mods & ~GHOSTTY_MODS_CTRL);
      break;
    case GHOSTTY_KEY_CONTROL_RIGHT:
      mods = (down ? (mods | GHOSTTY_MODS_CTRL) : (mods & ~GHOSTTY_MODS_CTRL)) | GHOSTTY_MODS_CTRL_RIGHT;
      break;
    case GHOSTTY_KEY_ALT_LEFT:
      mods = down ? (mods | GHOSTTY_MODS_ALT) : (mods & ~GHOSTTY_MODS_ALT);
      break;
    case GHOSTTY_KEY_ALT_RIGHT:
      mods = (down ? (mods | GHOSTTY_MODS_ALT) : (mods & ~GHOSTTY_MODS_ALT)) | GHOSTTY_MODS_ALT_RIGHT;
      break;
    case GHOSTTY_KEY_META_LEFT:
      mods = down ? (mods | GHOSTTY_MODS_SUPER) : (mods & ~GHOSTTY_MODS_SUPER);
      break;
    case GHOSTTY_KEY_META_RIGHT:
      mods = (down ? (mods | GHOSTTY_MODS_SUPER) : (mods & ~GHOSTTY_MODS_SUPER)) | GHOSTTY_MODS_SUPER_RIGHT;
      break;
    default:
      break;
    }

  ghostty_input_mods_e consumed = translate_mods (consumed_state & GDK_MODIFIER_MASK);

  /* No IME text: derive it from the keyval (GTK yields no text for e.g.
   * ctrl+shift+1 but the keyval is right). Control characters are left
   * to the encoder. */
  if (self->im_len == 0 && keyval_unicode >= 0x20)
    {
      gint len = g_unichar_to_utf8 (keyval_unicode, self->im_buf);
      self->im_len = (gsize) len;
    }
  self->im_buf[self->im_len] = '\0';

  ghostty_input_key_s ev = {
    .action = action,
    .mods = (ghostty_input_mods_e) mods,
    .consumed_mods = consumed,
    .keycode = broadway ? 0 : keycode,
    .text = self->im_len > 0 ? self->im_buf : NULL,
    .unshifted_codepoint = unshifted,
    .composing = self->im_composing,
  };

  gboolean was_composing = self->im_composing;
  gboolean consumed_by_ghostty = ghostty_surface_key_ex (self->surface, ev, key);
  self->im_len = 0;
  if (G_UNLIKELY (latency_trace > 0) && pressed)
    latency_trace_mark (&trace_rec.key_done);

  if (consumed_by_ghostty && action != GHOSTTY_ACTION_RELEASE)
    {
      if (was_composing)
        {
          gtk_im_context_reset (self->im);
          if (self->surface != NULL)
            ghostty_surface_preedit (self->surface, NULL, 0);
        }
      set_bell_ringing (self, FALSE);
    }
  return consumed_by_ghostty;
}

static gboolean
on_key_pressed (GtkEventControllerKey *ec, guint keyval, guint keycode, GdkModifierType state,
                ToasttyGhosttySurface *self)
{
  GdkEvent *event = gtk_event_controller_get_current_event (GTK_EVENT_CONTROLLER (ec));
  if (event == NULL || gdk_event_get_event_type (event) != GDK_KEY_PRESS)
    return FALSE;
  GdkDevice *device = gdk_event_get_device (event);
  return process_key (self, TRUE, event, keyval, keycode, state,
                      gdk_key_event_get_consumed_modifiers (event),
                      gdk_key_event_get_layout (event),
                      gdk_key_event_is_modifier (event),
                      device != NULL && gdk_device_get_num_lock_state (device));
}

static void
on_key_released (GtkEventControllerKey *ec, guint keyval, guint keycode, GdkModifierType state,
                 ToasttyGhosttySurface *self)
{
  GdkEvent *event = gtk_event_controller_get_current_event (GTK_EVENT_CONTROLLER (ec));
  if (event == NULL || gdk_event_get_event_type (event) != GDK_KEY_RELEASE)
    return;
  GdkDevice *device = gdk_event_get_device (event);
  process_key (self, FALSE, event, keyval, keycode, state,
               gdk_key_event_get_consumed_modifiers (event),
               gdk_key_event_get_layout (event),
               gdk_key_event_is_modifier (event),
               device != NULL && gdk_device_get_num_lock_state (device));
}

gboolean
toastty_ghostty_surface_send_key (ToasttyGhosttySurface *self, guint keyval, guint keycode,
                                  GdkModifierType state, gboolean pressed)
{
  g_return_val_if_fail (TOASTTY_GHOSTTY_IS_SURFACE (self), FALSE);
  GdkDisplay *display = gtk_widget_get_display (GTK_WIDGET (self));
  gboolean broadway = display_is_broadway (display);
  GdkModifierType consumed = 0;
  guint layout = 0;

  if (keycode == 0 && keyval != 0 && !broadway)
    {
      GdkKeymapKey *keys = NULL;
      int n = 0;
      if (gdk_display_map_keyval (display, keyval, &keys, &n) && n > 0)
        {
          keycode = keys[0].keycode;
          layout = (guint) keys[0].group;
          if (keys[0].level > 0)
            state |= GDK_SHIFT_MASK;
        }
      g_free (keys);
    }

  if (keycode != 0 && !broadway)
    {
      guint translated = 0;
      int effective_group = 0, level = 0;
      if (gdk_display_translate_key (display, keycode, state, (int) layout, &translated,
                                     &effective_group, &level, &consumed))
        {
          if (keyval == 0)
            keyval = translated;
          layout = (guint) effective_group;
        }
    }
  else if (broadway && (state & GDK_SHIFT_MASK) && gdk_keyval_to_lower (keyval) != keyval)
    consumed |= GDK_SHIFT_MASK;

  return process_key (self, pressed, NULL, keyval, keycode, state, consumed, layout,
                      is_modifier_keyval (keyval), FALSE);
}

void
toastty_ghostty_surface_commit_text (ToasttyGhosttySurface *self, const char *text)
{
  g_return_if_fail (TOASTTY_GHOSTTY_IS_SURFACE (self));
  if (self->surface == NULL || text == NULL || *text == '\0')
    return;
  ghostty_surface_preedit (self->surface, NULL, 0);
  ghostty_input_key_s ev = {
    .action = GHOSTTY_ACTION_PRESS,
    .mods = GHOSTTY_MODS_NONE,
    .consumed_mods = GHOSTTY_MODS_NONE,
    .keycode = 0,
    .text = text,
    .unshifted_codepoint = 0,
    .composing = false,
  };
  ghostty_surface_key_ex (self->surface, ev, GHOSTTY_KEY_UNIDENTIFIED);
}

/* IME (src/apprt/gtk/class/surface.zig im*) */

static void
on_im_preedit_start (GtkIMContext *ctx, ToasttyGhosttySurface *self)
{
  self->im_composing = TRUE;
  self->im_len = 0;
}

static void
on_im_preedit_changed (GtkIMContext *ctx, ToasttyGhosttySurface *self)
{
  self->im_composing = TRUE;
  if (self->surface == NULL)
    return;
  char *str = NULL;
  gtk_im_context_get_preedit_string (ctx, &str, NULL, NULL);
  ghostty_surface_preedit (self->surface, str, str ? strlen (str) : 0);
  g_free (str);
}

static void
on_im_preedit_end (GtkIMContext *ctx, ToasttyGhosttySurface *self)
{
  self->im_composing = FALSE;
  if (self->surface != NULL)
    ghostty_surface_preedit (self->surface, NULL, 0);
}

static void
on_im_commit (GtkIMContext *ctx, const char *str, ToasttyGhosttySurface *self)
{
  gsize len = strlen (str);
  switch (self->in_keyevent)
    {
    case IN_KEYEVENT_NOT_COMPOSING:
      /* Plain key translation: associate the text with the key event. */
      if (len >= sizeof self->im_buf)
        {
          g_warning ("not enough buffer space for input method commit");
          return;
        }
      memcpy (self->im_buf, str, len);
      self->im_len = len;
      return;
    case IN_KEYEVENT_COMPOSING:
    case IN_KEYEVENT_FALSE:
      break;
    }

  /* Composition result or text from a non-keyboard source. */
  self->im_composing = FALSE;
  toastty_ghostty_surface_commit_text (self, str);
}

/* ---------------------------------------------------------------------- */
/* Focus                                                                  */

static gboolean
focus_idle (gpointer data)
{
  ToasttyGhosttySurface *self = data;
  if (self->surface != NULL)
    ghostty_surface_set_focus (self->surface, self->focused);
  return G_SOURCE_REMOVE;
}

static void
update_focus (ToasttyGhosttySurface *self, gboolean focused)
{
  self->focused = focused;
  if (focused)
    gtk_im_context_focus_in (self->im);
  else
    {
      gtk_im_context_focus_out (self->im);
      /* Releases for keys held while focus leaves never reach us. */
      g_hash_table_remove_all (self->held_keycodes);
    }
  /* Like the GTK apprt, deliver focus from an idle: ghostty callbacks that
   * run during focus changes can otherwise deadlock. */
  g_idle_add_full (G_PRIORITY_DEFAULT, focus_idle, g_object_ref (self), g_object_unref);
  if (focused)
    set_bell_ringing (self, FALSE);
}

static void
on_focus_enter (GtkEventControllerFocus *ec, ToasttyGhosttySurface *self)
{
  update_focus (self, TRUE);
}

static void
on_focus_leave (GtkEventControllerFocus *ec, ToasttyGhosttySurface *self)
{
  update_focus (self, FALSE);
}

/* ---------------------------------------------------------------------- */
/* Mouse                                                                  */

static ghostty_input_mouse_button_e
translate_button (guint button)
{
  switch (button)
    {
    case 1: return GHOSTTY_MOUSE_LEFT;
    case 2: return GHOSTTY_MOUSE_MIDDLE;
    case 3: return GHOSTTY_MOUSE_RIGHT;
    case 4: return GHOSTTY_MOUSE_FOUR;
    case 5: return GHOSTTY_MOUSE_FIVE;
    case 6: return GHOSTTY_MOUSE_SIX;
    case 7: return GHOSTTY_MOUSE_SEVEN;
    case 8: return GHOSTTY_MOUSE_EIGHT;
    case 9: return GHOSTTY_MOUSE_NINE;
    case 10: return GHOSTTY_MOUSE_TEN;
    case 11: return GHOSTTY_MOUSE_ELEVEN;
    default: return GHOSTTY_MOUSE_UNKNOWN;
    }
}

static gboolean
primary_paste_enabled (void)
{
  GtkSettings *settings = gtk_settings_get_default ();
  gboolean enabled = TRUE;
  if (settings != NULL)
    g_object_get (settings, "gtk-enable-primary-paste", &enabled, NULL);
  return enabled;
}

static void
on_click_pressed (GtkGestureClick *gesture, int n_press, double x, double y, ToasttyGhosttySurface *self)
{
  GtkWidget *widget = GTK_WIDGET (self);
  guint button = gtk_gesture_single_get_current_button (GTK_GESTURE_SINGLE (gesture));
  GdkModifierType state = gtk_event_controller_get_current_event_state (GTK_EVENT_CONTROLLER (gesture));

  set_bell_ringing (self, FALSE);
  if (!gtk_widget_has_focus (widget))
    gtk_widget_grab_focus (widget);

  if (button == 8 || button == 9)
    {
      gboolean handled = FALSE;
      g_signal_emit (self, signals[SIG_MOUSE_NAVIGATION], 0,
                     button == 8 ? TOASTTY_GHOSTTY_NAVIGATION_BACK : TOASTTY_GHOSTTY_NAVIGATION_FORWARD,
                     &handled);
      if (handled)
        {
          self->suppressed_buttons |= 1u << button;
          return;
        }
    }

  if (self->surface == NULL)
    return;

  ghostty_input_mouse_button_e gbutton = translate_button (button);
  if (gbutton == GHOSTTY_MOUSE_MIDDLE && !primary_paste_enabled () &&
      !ghostty_surface_mouse_captured (self->surface))
    return;

  gboolean consumed = ghostty_surface_mouse_button (self->surface, GHOSTTY_MOUSE_PRESS, gbutton,
                                                    translate_mods (state));
  if (!consumed && gbutton == GHOSTTY_MOUSE_RIGHT)
    g_signal_emit (self, signals[SIG_CONTEXT_MENU], 0, x, y);
}

static void
on_click_released (GtkGestureClick *gesture, int n_press, double x, double y, ToasttyGhosttySurface *self)
{
  guint button = gtk_gesture_single_get_current_button (GTK_GESTURE_SINGLE (gesture));
  GdkModifierType state = gtk_event_controller_get_current_event_state (GTK_EVENT_CONTROLLER (gesture));

  if (button < 32 && (self->suppressed_buttons & (1u << button)))
    {
      self->suppressed_buttons &= ~(1u << button);
      return;
    }
  if (self->surface == NULL)
    return;

  ghostty_input_mouse_button_e gbutton = translate_button (button);
  if (gbutton == GHOSTTY_MOUSE_MIDDLE && !primary_paste_enabled () &&
      !ghostty_surface_mouse_captured (self->surface))
    return;
  ghostty_surface_mouse_button (self->surface, GHOSTTY_MOUSE_RELEASE, gbutton, translate_mods (state));
}

static void
on_motion (GtkEventControllerMotion *ec, double x, double y, ToasttyGhosttySurface *self)
{
  /* GTK can report motion without movement (resizes, title updates); only
   * act on real movement, like the GTK apprt. */
  if (fabs (self->cursor_x - x) < 1 && fabs (self->cursor_y - y) < 1)
    return;
  self->cursor_x = x;
  self->cursor_y = y;
  if (self->surface == NULL)
    return;
  GdkModifierType state = gtk_event_controller_get_current_event_state (GTK_EVENT_CONTROLLER (ec));
  double gx = x, gy = y;
  css_to_ghostty (self, &gx, &gy);
  ghostty_surface_mouse_pos (self->surface, gx, gy, translate_mods (state));
}

static void
on_enter (GtkEventControllerMotion *ec, double x, double y, ToasttyGhosttySurface *self)
{
  on_motion (ec, x, y, self);
}

static void
on_leave (GtkEventControllerMotion *ec, ToasttyGhosttySurface *self)
{
  self->cursor_x = -1;
  self->cursor_y = -1;
  if (self->surface == NULL)
    return;
  GdkModifierType state = gtk_event_controller_get_current_event_state (GTK_EVENT_CONTROLLER (ec));
  ghostty_surface_mouse_pos (self->surface, -1, -1, translate_mods (state));
}

static void
on_scroll_begin (GtkEventControllerScroll *ec, ToasttyGhosttySurface *self)
{
  self->precision_scroll = TRUE;
}

static void
on_scroll_end (GtkEventControllerScroll *ec, ToasttyGhosttySurface *self)
{
  self->precision_scroll = FALSE;
}

static gboolean
on_scroll_vertical (GtkEventControllerScroll *ec, double dx, double dy, ToasttyGhosttySurface *self)
{
  if (self->surface == NULL)
    return FALSE;
  gboolean precision = self->precision_scroll ||
                       gtk_event_controller_scroll_get_unit (ec) == GDK_SCROLL_UNIT_SURFACE;
  /* Precision (touchpad) scrolls are multiplied by 10 for a better feel,
   * deltas are scaled to device pixels and inverted (natural scrolling),
   * exactly like the GTK apprt. */
  double multiplier = precision ? 10.0 : 1.0;
  double scale = self->scale > 0 ? self->scale : 1.0;
  ghostty_input_scroll_mods_t mods = precision ? 1 : 0;
  ghostty_surface_mouse_scroll (self->surface, dx * scale * -1 * multiplier,
                                dy * scale * -1 * multiplier, mods);
  return TRUE;
}

static gboolean
on_scroll_horizontal (GtkEventControllerScroll *ec, double dx, double dy, ToasttyGhosttySurface *self)
{
  if (self->surface == NULL)
    return FALSE;
  double scale = self->scale > 0 ? self->scale : 1.0;
  ghostty_surface_mouse_scroll (self->surface, dx * scale * -1, 0, 0);
  return TRUE;
}

static const char *
cursor_name (ghostty_action_mouse_shape_e shape)
{
  switch (shape)
    {
    case GHOSTTY_MOUSE_SHAPE_DEFAULT: return "default";
    case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: return "context-menu";
    case GHOSTTY_MOUSE_SHAPE_HELP: return "help";
    case GHOSTTY_MOUSE_SHAPE_POINTER: return "pointer";
    case GHOSTTY_MOUSE_SHAPE_PROGRESS: return "progress";
    case GHOSTTY_MOUSE_SHAPE_WAIT: return "wait";
    case GHOSTTY_MOUSE_SHAPE_CELL: return "cell";
    case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: return "crosshair";
    case GHOSTTY_MOUSE_SHAPE_TEXT: return "text";
    case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return "vertical-text";
    case GHOSTTY_MOUSE_SHAPE_ALIAS: return "alias";
    case GHOSTTY_MOUSE_SHAPE_COPY: return "copy";
    case GHOSTTY_MOUSE_SHAPE_MOVE: return "move";
    case GHOSTTY_MOUSE_SHAPE_NO_DROP: return "no-drop";
    case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: return "not-allowed";
    case GHOSTTY_MOUSE_SHAPE_GRAB: return "grab";
    case GHOSTTY_MOUSE_SHAPE_GRABBING: return "grabbing";
    case GHOSTTY_MOUSE_SHAPE_ALL_SCROLL: return "all-scroll";
    case GHOSTTY_MOUSE_SHAPE_COL_RESIZE: return "col-resize";
    case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: return "row-resize";
    case GHOSTTY_MOUSE_SHAPE_N_RESIZE: return "n-resize";
    case GHOSTTY_MOUSE_SHAPE_E_RESIZE: return "e-resize";
    case GHOSTTY_MOUSE_SHAPE_S_RESIZE: return "s-resize";
    case GHOSTTY_MOUSE_SHAPE_W_RESIZE: return "w-resize";
    case GHOSTTY_MOUSE_SHAPE_NE_RESIZE: return "ne-resize";
    case GHOSTTY_MOUSE_SHAPE_NW_RESIZE: return "nw-resize";
    case GHOSTTY_MOUSE_SHAPE_SE_RESIZE: return "se-resize";
    case GHOSTTY_MOUSE_SHAPE_SW_RESIZE: return "sw-resize";
    case GHOSTTY_MOUSE_SHAPE_EW_RESIZE: return "ew-resize";
    case GHOSTTY_MOUSE_SHAPE_NS_RESIZE: return "ns-resize";
    case GHOSTTY_MOUSE_SHAPE_NESW_RESIZE: return "nesw-resize";
    case GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE: return "nwse-resize";
    case GHOSTTY_MOUSE_SHAPE_ZOOM_IN: return "zoom-in";
    case GHOSTTY_MOUSE_SHAPE_ZOOM_OUT: return "zoom-out";
    default: return "default";
    }
}

static void
apply_cursor (ToasttyGhosttySurface *self)
{
  gtk_widget_set_cursor_from_name (GTK_WIDGET (self),
                                   self->mouse_hidden ? "none" : cursor_name (self->mouse_shape));
}

/* ---------------------------------------------------------------------- */
/* Default action handling                                                */

static char *
dup_len (const char *s, size_t len)
{
  return s != NULL && len > 0 ? g_strndup (s, len) : NULL;
}

gboolean
toastty_ghostty_handle_action (ghostty_app_t app, ghostty_target_s target, ghostty_action_s action)
{
  ToasttyGhosttySurface *self = widget_for_target (target);
  if (self == NULL)
    return FALSE;

  switch (action.tag)
    {
    case GHOSTTY_ACTION_RENDER:
      if (G_UNLIKELY (latency_trace > 0))
        latency_trace_mark (&trace_rec.render);
      gtk_widget_queue_draw (GTK_WIDGET (self));
      return TRUE;

    case GHOSTTY_ACTION_MOUSE_SHAPE:
      self->mouse_shape = action.action.mouse_shape;
      apply_cursor (self);
      return TRUE;

    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
      self->mouse_hidden = action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN;
      apply_cursor (self);
      return TRUE;

    case GHOSTTY_ACTION_SET_TITLE:
      {
        const char *title = action.action.set_title.title;
        if (g_strcmp0 (title, self->title) != 0)
          {
            g_free (self->title);
            self->title = g_strdup (title);
            g_object_notify_by_pspec (G_OBJECT (self), props[PROP_TITLE]);
          }
        g_signal_emit (self, signals[SIG_TITLE_CHANGED], 0, self->title);
        return TRUE;
      }

    case GHOSTTY_ACTION_PWD:
      {
        const char *pwd = action.action.pwd.pwd;
        if (g_strcmp0 (pwd, self->pwd) != 0)
          {
            g_free (self->pwd);
            self->pwd = g_strdup (pwd);
            g_object_notify_by_pspec (G_OBJECT (self), props[PROP_PWD]);
          }
        g_signal_emit (self, signals[SIG_PWD_CHANGED], 0, self->pwd);
        return TRUE;
      }

    case GHOSTTY_ACTION_RING_BELL:
      g_signal_emit (self, signals[SIG_BELL], 0);
      return TRUE;

    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
      g_signal_emit (self, signals[SIG_CHILD_EXITED], 0,
                     (guint) action.action.child_exited.exit_code,
                     (guint64) action.action.child_exited.timetime_ms);
      return TRUE;

    case GHOSTTY_ACTION_COMMAND_FINISHED:
      g_signal_emit (self, signals[SIG_COMMAND_FINISHED], 0,
                     (gint) action.action.command_finished.exit_code,
                     (guint64) action.action.command_finished.duration);
      return TRUE;

    case GHOSTTY_ACTION_MOUSE_OVER_LINK:
      {
        g_autofree char *url = dup_len (action.action.mouse_over_link.url,
                                        action.action.mouse_over_link.len);
        g_signal_emit (self, signals[SIG_LINK_HOVER], 0, url);
        return TRUE;
      }

    case GHOSTTY_ACTION_PROGRAM_STATUS:
      g_signal_emit (self, signals[SIG_PROGRAM_STATUS], 0, (gpointer) action.action.program_status);
      return TRUE;

    case GHOSTTY_ACTION_PROGRAM_STATUS_RESET:
      g_signal_emit (self, signals[SIG_PROGRAM_STATUS_RESET], 0, (gint) action.action.program_status_reset);
      return TRUE;

    case GHOSTTY_ACTION_RENDERER_HEALTH:
      g_signal_emit (self, signals[SIG_RENDERER_HEALTH], 0,
                     action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_HEALTHY);
      return TRUE;

    default:
      return FALSE;
    }
}

/* ---------------------------------------------------------------------- */
/* Close                                                                  */

typedef struct
{
  ToasttyGhosttySurface *self;
  gboolean process_alive;
} CloseData;

static gboolean
close_idle (gpointer data)
{
  CloseData *cd = data;
  g_signal_emit (cd->self, signals[SIG_CLOSE_REQUESTED], 0, cd->process_alive);
  g_object_unref (cd->self);
  g_free (cd);
  return G_SOURCE_REMOVE;
}

void
toastty_ghostty_close_surface_cb (void *surface_userdata, bool process_alive)
{
  SurfaceHandle *h = surface_userdata;
  if (h == NULL || h->widget == NULL)
    return;
  CloseData *cd = g_new0 (CloseData, 1);
  cd->self = g_object_ref (h->widget);
  cd->process_alive = process_alive;
  g_idle_add (close_idle, cd);
}

/* ---------------------------------------------------------------------- */
/* Clipboard                                                              */

static GdkClipboard *
clipboard_for (GtkWidget *widget, ghostty_clipboard_e location)
{
  switch (location)
    {
    case GHOSTTY_CLIPBOARD_STANDARD:
      return gtk_widget_get_clipboard (widget);
    case GHOSTTY_CLIPBOARD_SELECTION:
    case GHOSTTY_CLIPBOARD_PRIMARY:
      return gtk_widget_get_primary_clipboard (widget);
    default:
      return NULL;
    }
}

typedef struct
{
  SurfaceHandle *handle;
  void *state;
  GdkClipboard *clipboard;
  GStrv mimes;
  guint next;
  gboolean list;
  GPtrArray *content_mimes; /* char* */
  GPtrArray *content_data;  /* GBytes* */
} ReadOp;

static void
read_op_free (ReadOp *op)
{
  g_atomic_rc_box_release (op->handle);
  g_clear_object (&op->clipboard);
  g_strfreev (op->mimes);
  g_ptr_array_unref (op->content_mimes);
  g_ptr_array_unref (op->content_data);
  g_free (op);
}

static void read_op_next (ReadOp *op);

static void
read_op_finish (ReadOp *op)
{
  ghostty_surface_t surface = op->handle->surface;
  if (surface == NULL)
    {
      read_op_free (op);
      return;
    }

  gsize n = op->content_mimes->len;
  ghostty_clipboard_content_s *contents = g_new0 (ghostty_clipboard_content_s, MAX (n, 1));
  for (gsize i = 0; i < n; i++)
    {
      gsize len = 0;
      contents[i].mime = g_ptr_array_index (op->content_mimes, i);
      contents[i].data = g_bytes_get_data (g_ptr_array_index (op->content_data, i), &len);
      contents[i].len = len;
    }

  const char **available = NULL;
  gsize n_available = 0;
  if (op->list)
    {
      GdkContentFormats *formats = gdk_clipboard_get_formats (op->clipboard);
      const char *const *types = gdk_content_formats_get_mime_types (formats, &n_available);
      GPtrArray *arr = g_ptr_array_new ();
      gboolean has_text = FALSE;
      for (gsize i = 0; i < n_available; i++)
        {
          if (g_str_has_prefix (types[i], "text/plain"))
            {
              if (has_text)
                continue;
              has_text = TRUE;
              g_ptr_array_add (arr, (gpointer) "text/plain");
              continue;
            }
          g_ptr_array_add (arr, (gpointer) types[i]);
        }
      if (!has_text && gdk_content_formats_contain_gtype (formats, G_TYPE_STRING))
        g_ptr_array_add (arr, (gpointer) "text/plain");
      n_available = arr->len;
      available = (const char **) g_ptr_array_free (arr, FALSE);
    }

  if (n == 0 && !op->list && g_strv_length (op->mimes) > 0)
    {
      /* Nothing could be read. */
      ghostty_surface_deny_clipboard_request (surface, op->state);
    }
  else
    {
      ghostty_clipboard_complete_s complete = {
        .contents = contents,
        .contents_len = n,
        .available = available,
        .available_len = n_available,
        .confirmed = false,
        .remember = false,
      };
      ghostty_surface_complete_clipboard_request (surface, &complete, op->state);
    }

  g_free (available);
  g_free (contents);
  read_op_free (op);
}

static void
read_text_done (GObject *source, GAsyncResult *res, gpointer data)
{
  ReadOp *op = data;
  g_autoptr (GError) error = NULL;
  char *text = gdk_clipboard_read_text_finish (GDK_CLIPBOARD (source), res, &error);
  if (text != NULL)
    {
      g_ptr_array_add (op->content_mimes, g_strdup ("text/plain"));
      g_ptr_array_add (op->content_data, g_bytes_new_take (text, strlen (text)));
    }
  read_op_next (op);
}

static void
read_splice_done (GObject *source, GAsyncResult *res, gpointer data)
{
  ReadOp *op = data;
  g_autoptr (GError) error = NULL;
  GOutputStream *out = G_OUTPUT_STREAM (source);
  if (g_output_stream_splice_finish (out, res, &error) >= 0)
    {
      g_ptr_array_add (op->content_mimes, g_strdup (op->mimes[op->next - 1]));
      g_ptr_array_add (op->content_data,
                       g_memory_output_stream_steal_as_bytes (G_MEMORY_OUTPUT_STREAM (out)));
    }
  g_object_unref (out);
  read_op_next (op);
}

static void
read_stream_done (GObject *source, GAsyncResult *res, gpointer data)
{
  ReadOp *op = data;
  g_autoptr (GError) error = NULL;
  GInputStream *in = gdk_clipboard_read_finish (GDK_CLIPBOARD (source), res, NULL, &error);
  if (in == NULL)
    {
      read_op_next (op);
      return;
    }
  GOutputStream *out = g_memory_output_stream_new_resizable ();
  g_output_stream_splice_async (out, in,
                                G_OUTPUT_STREAM_SPLICE_CLOSE_SOURCE | G_OUTPUT_STREAM_SPLICE_CLOSE_TARGET,
                                G_PRIORITY_DEFAULT, NULL, read_splice_done, op);
  g_object_unref (in);
}

static void
read_op_next (ReadOp *op)
{
  if (op->mimes[op->next] == NULL)
    {
      read_op_finish (op);
      return;
    }
  const char *mime = op->mimes[op->next++];
  if (g_str_equal (mime, "text/plain"))
    gdk_clipboard_read_text_async (op->clipboard, NULL, read_text_done, op);
  else
    {
      const char *types[] = { mime, NULL };
      gdk_clipboard_read_async (op->clipboard, types, G_PRIORITY_DEFAULT, NULL, read_stream_done, op);
    }
}

ghostty_clipboard_read_result_e
toastty_ghostty_read_clipboard_cb (void *surface_userdata, ghostty_clipboard_e location, void *state,
                                   const char *const *mimes, size_t n_mimes, bool list)
{
  SurfaceHandle *h = surface_userdata;
  if (h == NULL || h->widget == NULL)
    return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED;
  GdkClipboard *clipboard = clipboard_for (GTK_WIDGET (h->widget), location);
  if (clipboard == NULL)
    return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED;

  GdkContentFormats *formats = gdk_clipboard_get_formats (clipboard);
  gsize n_types = 0;
  gdk_content_formats_get_mime_types (formats, &n_types);
  gsize n_gtypes = 0;
  gdk_content_formats_get_gtypes (formats, &n_gtypes);
  if (n_types == 0 && n_gtypes == 0)
    return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;

  ReadOp *op = g_new0 (ReadOp, 1);
  op->handle = g_atomic_rc_box_acquire (h);
  op->state = state;
  op->clipboard = g_object_ref (clipboard);
  op->mimes = g_new0 (char *, n_mimes + 1);
  for (size_t i = 0; i < n_mimes; i++)
    op->mimes[i] = g_strdup (mimes[i]);
  op->list = list;
  op->content_mimes = g_ptr_array_new_with_free_func (g_free);
  op->content_data = g_ptr_array_new_with_free_func ((GDestroyNotify) g_bytes_unref);
  read_op_next (op);
  return GHOSTTY_CLIPBOARD_READ_STARTED;
}

/* Confirmation (unsafe paste, OSC 52 read, Kitty clipboard) */

typedef struct
{
  SurfaceHandle *handle;
  void *state;
  GPtrArray *mimes;       /* char* */
  GPtrArray *data;        /* GBytes* */
  GPtrArray *available;   /* char* */
} ConfirmOp;

static void
confirm_op_free (ConfirmOp *op)
{
  g_atomic_rc_box_release (op->handle);
  g_ptr_array_unref (op->mimes);
  g_ptr_array_unref (op->data);
  g_ptr_array_unref (op->available);
  g_free (op);
}

static void
confirm_done (GObject *source, GAsyncResult *res, gpointer data)
{
  ConfirmOp *op = data;
  int choice = gtk_alert_dialog_choose_finish (GTK_ALERT_DIALOG (source), res, NULL);
  ghostty_surface_t surface = op->handle->surface;
  if (surface != NULL)
    {
      if (choice == 1)
        {
          gsize n = op->mimes->len;
          ghostty_clipboard_content_s *contents = g_new0 (ghostty_clipboard_content_s, MAX (n, 1));
          for (gsize i = 0; i < n; i++)
            {
              gsize len = 0;
              contents[i].mime = g_ptr_array_index (op->mimes, i);
              contents[i].data = g_bytes_get_data (g_ptr_array_index (op->data, i), &len);
              contents[i].len = len;
            }
          ghostty_clipboard_complete_s complete = {
            .contents = contents,
            .contents_len = n,
            .available = (const char *const *) op->available->pdata,
            .available_len = op->available->len,
            .confirmed = true,
            .remember = false,
          };
          ghostty_surface_complete_clipboard_request (surface, &complete, op->state);
          g_free (contents);
        }
      else
        ghostty_surface_deny_clipboard_request (surface, op->state);
    }
  confirm_op_free (op);
}

void
toastty_ghostty_confirm_read_clipboard_cb (void *surface_userdata, const ghostty_clipboard_confirm_s *confirm,
                                           void *state, ghostty_clipboard_request_e request)
{
  SurfaceHandle *h = surface_userdata;
  if (h == NULL || h->widget == NULL || h->surface == NULL)
    return;

  gboolean handled = FALSE;
  g_signal_emit (h->widget, signals[SIG_CLIPBOARD_CONFIRM], 0, (gpointer) confirm, state,
                 (gint) request, &handled);
  if (handled)
    return;

  ConfirmOp *op = g_new0 (ConfirmOp, 1);
  op->handle = g_atomic_rc_box_acquire (h);
  op->state = state;
  op->mimes = g_ptr_array_new_with_free_func (g_free);
  op->data = g_ptr_array_new_with_free_func ((GDestroyNotify) g_bytes_unref);
  op->available = g_ptr_array_new_null_terminated (0, g_free, TRUE);
  GString *preview = g_string_new (NULL);
  for (size_t i = 0; i < confirm->contents_len; i++)
    {
      const ghostty_clipboard_content_s *c = &confirm->contents[i];
      g_ptr_array_add (op->mimes, g_strdup (c->mime));
      g_ptr_array_add (op->data, g_bytes_new (c->data, c->len));
      if (preview->len == 0 && c->mime != NULL && g_str_has_prefix (c->mime, "text/"))
        g_string_append_len (preview, c->data, (gssize) MIN (c->len, (size_t) 512));
    }
  for (size_t i = 0; i < confirm->available_len; i++)
    g_ptr_array_add (op->available, g_strdup (confirm->available[i]));

  const char *message;
  const char *button;
  switch (request)
    {
    case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
      message = "Paste potentially unsafe text?";
      button = "Paste";
      break;
    case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
    case GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE:
      message = "Allow the program to change the clipboard?";
      button = "Allow";
      break;
    default:
      message = "Allow the program to read the clipboard?";
      button = "Allow";
      break;
    }
  GtkAlertDialog *dialog = gtk_alert_dialog_new ("%s", message);
  if (preview->len > 0)
    gtk_alert_dialog_set_detail (dialog, preview->str);
  const char *buttons[] = { "Cancel", button, NULL };
  gtk_alert_dialog_set_buttons (dialog, buttons);
  gtk_alert_dialog_set_cancel_button (dialog, 0);
  gtk_alert_dialog_set_default_button (dialog, 0);
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (h->widget));
  gtk_alert_dialog_choose (dialog, GTK_IS_WINDOW (root) ? GTK_WINDOW (root) : NULL, NULL, confirm_done, op);
  g_object_unref (dialog);
  g_string_free (preview, TRUE);
}

/* Writes */

static GdkContentProvider *
provider_for_contents (const ghostty_clipboard_content_s *contents, size_t n)
{
  GPtrArray *providers = g_ptr_array_new ();
  for (size_t i = 0; i < n; i++)
    {
      const ghostty_clipboard_content_s *c = &contents[i];
      if (c->mime == NULL)
        continue;
      GBytes *bytes = g_bytes_new (c->data, c->len);
      if (g_str_equal (c->mime, "text/plain"))
        {
          g_autofree char *text = g_strndup (c->data, c->len);
          g_ptr_array_add (providers, gdk_content_provider_new_typed (G_TYPE_STRING, text));
          g_ptr_array_add (providers, gdk_content_provider_new_for_bytes ("text/plain;charset=utf-8", bytes));
        }
      g_ptr_array_add (providers, gdk_content_provider_new_for_bytes (c->mime, bytes));
      g_bytes_unref (bytes);
    }
  GdkContentProvider *union_provider =
      gdk_content_provider_new_union ((GdkContentProvider **) providers->pdata, providers->len);
  g_ptr_array_free (providers, TRUE);
  return union_provider;
}

typedef struct
{
  SurfaceHandle *handle;
  ghostty_clipboard_e location;
  GdkContentProvider *provider;
} WriteOp;

static void
write_op_apply (WriteOp *op)
{
  if (op->handle->widget != NULL)
    {
      GdkClipboard *clipboard = clipboard_for (GTK_WIDGET (op->handle->widget), op->location);
      if (clipboard != NULL)
        gdk_clipboard_set_content (clipboard, op->provider);
    }
}

static void
write_op_free (WriteOp *op)
{
  g_atomic_rc_box_release (op->handle);
  g_clear_object (&op->provider);
  g_free (op);
}

static void
write_confirm_done (GObject *source, GAsyncResult *res, gpointer data)
{
  WriteOp *op = data;
  if (gtk_alert_dialog_choose_finish (GTK_ALERT_DIALOG (source), res, NULL) == 1)
    write_op_apply (op);
  write_op_free (op);
}

void
toastty_ghostty_write_clipboard_cb (void *surface_userdata, ghostty_clipboard_e location,
                                    const ghostty_clipboard_content_s *contents, size_t n_contents,
                                    bool confirm)
{
  SurfaceHandle *h = surface_userdata;
  if (h == NULL || h->widget == NULL || n_contents == 0)
    return;
  WriteOp *op = g_new0 (WriteOp, 1);
  op->handle = g_atomic_rc_box_acquire (h);
  op->location = location;
  op->provider = provider_for_contents (contents, n_contents);
  if (!confirm)
    {
      write_op_apply (op);
      write_op_free (op);
      return;
    }
  GtkAlertDialog *dialog = gtk_alert_dialog_new ("Allow the program to change the clipboard?");
  const char *buttons[] = { "Cancel", "Allow", NULL };
  gtk_alert_dialog_set_buttons (dialog, buttons);
  gtk_alert_dialog_set_cancel_button (dialog, 0);
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (h->widget));
  gtk_alert_dialog_choose (dialog, GTK_IS_WINDOW (root) ? GTK_WINDOW (root) : NULL, NULL,
                           write_confirm_done, op);
  g_object_unref (dialog);
}

/* ---------------------------------------------------------------------- */
/* GObject boilerplate                                                    */

static void
toastty_ghostty_surface_get_property (GObject *object, guint prop_id, GValue *value, GParamSpec *pspec)
{
  ToasttyGhosttySurface *self = TOASTTY_GHOSTTY_SURFACE (object);
  switch (prop_id)
    {
    case PROP_TITLE:
      g_value_set_string (value, self->title);
      break;
    case PROP_PWD:
      g_value_set_string (value, self->pwd);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
    }
}

static void
toastty_ghostty_surface_dispose (GObject *object)
{
  ToasttyGhosttySurface *self = TOASTTY_GHOSTTY_SURFACE (object);

  if (self->handle != NULL)
    {
      SurfaceHandle *h = self->handle;
      self->handle = NULL;
      h->widget = NULL;
      if (surface_handles != NULL)
        g_hash_table_remove (surface_handles, h->surface);
      /* Never free a ghostty surface synchronously: dispose can run inside
       * a ghostty callback (e.g. a signal handler destroying the widget). */
      pending_frees = g_list_prepend (pending_frees, h);
      g_idle_add (surface_handle_free_idle, h);
    }
  self->surface = NULL;

  if (self->xft_notify_id != 0)
    {
      g_signal_handler_disconnect (gtk_settings_get_default (), self->xft_notify_id);
      self->xft_notify_id = 0;
    }
  if (self->key_filter_destroy != NULL)
    self->key_filter_destroy (self->key_filter_data);
  self->key_filter = NULL;
  self->key_filter_destroy = NULL;
  g_clear_object (&self->texture);
  g_clear_object (&self->im);

  G_OBJECT_CLASS (toastty_ghostty_surface_parent_class)->dispose (object);
}

static void
toastty_ghostty_surface_finalize (GObject *object)
{
  ToasttyGhosttySurface *self = TOASTTY_GHOSTTY_SURFACE (object);
  g_free (self->title);
  g_free (self->pwd);
  g_clear_pointer (&self->held_keycodes, g_hash_table_unref);
  G_OBJECT_CLASS (toastty_ghostty_surface_parent_class)->finalize (object);
}

static gboolean
accumulator_true_handled (GSignalInvocationHint *ihint, GValue *return_accu,
                          const GValue *handler_return, gpointer data)
{
  gboolean handled = g_value_get_boolean (handler_return);
  g_value_set_boolean (return_accu, handled);
  return !handled;
}

static void
toastty_ghostty_surface_class_init (ToasttyGhosttySurfaceClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);
  GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);

  object_class->get_property = toastty_ghostty_surface_get_property;
  object_class->dispose = toastty_ghostty_surface_dispose;
  object_class->finalize = toastty_ghostty_surface_finalize;

  widget_class->snapshot = toastty_ghostty_surface_snapshot;
  widget_class->size_allocate = toastty_ghostty_surface_size_allocate;
  widget_class->measure = toastty_ghostty_surface_measure;
  widget_class->realize = toastty_ghostty_surface_realize;
  widget_class->unrealize = toastty_ghostty_surface_unrealize;
  widget_class->map = toastty_ghostty_surface_map;
  widget_class->unmap = toastty_ghostty_surface_unmap;

  props[PROP_TITLE] = g_param_spec_string ("title", NULL, NULL, NULL,
                                           G_PARAM_READABLE | G_PARAM_STATIC_STRINGS);
  props[PROP_PWD] = g_param_spec_string ("pwd", NULL, NULL, NULL,
                                         G_PARAM_READABLE | G_PARAM_STATIC_STRINGS);
  g_object_class_install_properties (object_class, N_PROPS, props);

  GType type = G_TYPE_FROM_CLASS (klass);
  signals[SIG_TITLE_CHANGED] = g_signal_new ("title-changed", type, G_SIGNAL_RUN_LAST, 0, NULL, NULL,
                                             NULL, G_TYPE_NONE, 1, G_TYPE_STRING);
  signals[SIG_PWD_CHANGED] = g_signal_new ("pwd-changed", type, G_SIGNAL_RUN_LAST, 0, NULL, NULL,
                                           NULL, G_TYPE_NONE, 1, G_TYPE_STRING);
  signals[SIG_BELL] = g_signal_new ("bell", type, G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL,
                                    G_TYPE_NONE, 0);
  signals[SIG_CLOSE_REQUESTED] = g_signal_new ("close-requested", type, G_SIGNAL_RUN_LAST, 0, NULL,
                                               NULL, NULL, G_TYPE_NONE, 1, G_TYPE_BOOLEAN);
  signals[SIG_CHILD_EXITED] = g_signal_new ("child-exited", type, G_SIGNAL_RUN_LAST, 0, NULL, NULL,
                                            NULL, G_TYPE_NONE, 2, G_TYPE_UINT, G_TYPE_UINT64);
  signals[SIG_COMMAND_FINISHED] = g_signal_new ("command-finished", type, G_SIGNAL_RUN_LAST, 0, NULL,
                                                NULL, NULL, G_TYPE_NONE, 2, G_TYPE_INT, G_TYPE_UINT64);
  signals[SIG_LINK_HOVER] = g_signal_new ("link-hover", type, G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL,
                                          G_TYPE_NONE, 1, G_TYPE_STRING);
  signals[SIG_PROGRAM_STATUS] = g_signal_new ("program-status", type, G_SIGNAL_RUN_LAST, 0, NULL, NULL,
                                              NULL, G_TYPE_NONE, 1, G_TYPE_POINTER);
  signals[SIG_PROGRAM_STATUS_RESET] = g_signal_new ("program-status-reset", type, G_SIGNAL_RUN_LAST, 0,
                                                    NULL, NULL, NULL, G_TYPE_NONE, 1, G_TYPE_INT);
  signals[SIG_RENDERER_HEALTH] = g_signal_new ("renderer-health", type, G_SIGNAL_RUN_LAST, 0, NULL,
                                               NULL, NULL, G_TYPE_NONE, 1, G_TYPE_BOOLEAN);
  signals[SIG_MOUSE_NAVIGATION] = g_signal_new ("mouse-navigation", type, G_SIGNAL_RUN_LAST, 0,
                                                accumulator_true_handled, NULL, NULL, G_TYPE_BOOLEAN,
                                                1, G_TYPE_INT);
  signals[SIG_CONTEXT_MENU] = g_signal_new ("context-menu", type, G_SIGNAL_RUN_LAST, 0, NULL, NULL,
                                            NULL, G_TYPE_NONE, 2, G_TYPE_DOUBLE, G_TYPE_DOUBLE);
  /* (confirm: const ghostty_clipboard_confirm_s*, state: gpointer,
   *  request: ghostty_clipboard_request_e) -> handled. A handler that
   * returns TRUE must later call ghostty_surface_complete_clipboard_request
   * or ghostty_surface_deny_clipboard_request with `state`; `confirm` is
   * borrowed for the emission only. */
  signals[SIG_CLIPBOARD_CONFIRM] = g_signal_new ("clipboard-confirm", type, G_SIGNAL_RUN_LAST, 0,
                                                 accumulator_true_handled, NULL, NULL, G_TYPE_BOOLEAN,
                                                 3, G_TYPE_POINTER, G_TYPE_POINTER, G_TYPE_INT);

  gtk_widget_class_set_css_name (widget_class, "toastty-ghostty-surface");
}

static void
toastty_ghostty_surface_init (ToasttyGhosttySurface *self)
{
  GtkWidget *widget = GTK_WIDGET (self);
  gtk_widget_set_focusable (widget, TRUE);
  gtk_widget_set_focus_on_click (widget, TRUE);
  gtk_widget_set_hexpand (widget, TRUE);
  gtk_widget_set_vexpand (widget, TRUE);

  self->scale = 1.0;
  self->xft = read_xft_scale ();
  self->cursor_x = -1;
  self->cursor_y = -1;
  self->held_keycodes = g_hash_table_new (g_direct_hash, g_direct_equal);

  GtkEventController *key = gtk_event_controller_key_new ();
  g_signal_connect (key, "key-pressed", G_CALLBACK (on_key_pressed), self);
  g_signal_connect (key, "key-released", G_CALLBACK (on_key_released), self);
  gtk_widget_add_controller (widget, key);

  GtkEventController *focus = gtk_event_controller_focus_new ();
  g_signal_connect (focus, "enter", G_CALLBACK (on_focus_enter), self);
  g_signal_connect (focus, "leave", G_CALLBACK (on_focus_leave), self);
  gtk_widget_add_controller (widget, focus);

  GtkGesture *click = gtk_gesture_click_new ();
  gtk_gesture_single_set_button (GTK_GESTURE_SINGLE (click), 0);
  g_signal_connect (click, "pressed", G_CALLBACK (on_click_pressed), self);
  g_signal_connect (click, "released", G_CALLBACK (on_click_released), self);
  gtk_widget_add_controller (widget, GTK_EVENT_CONTROLLER (click));

  GtkEventController *motion = gtk_event_controller_motion_new ();
  g_signal_connect (motion, "motion", G_CALLBACK (on_motion), self);
  g_signal_connect (motion, "enter", G_CALLBACK (on_enter), self);
  g_signal_connect (motion, "leave", G_CALLBACK (on_leave), self);
  gtk_widget_add_controller (widget, motion);

  GtkEventController *vscroll = gtk_event_controller_scroll_new (GTK_EVENT_CONTROLLER_SCROLL_VERTICAL);
  g_signal_connect (vscroll, "scroll-begin", G_CALLBACK (on_scroll_begin), self);
  g_signal_connect (vscroll, "scroll-end", G_CALLBACK (on_scroll_end), self);
  g_signal_connect (vscroll, "scroll", G_CALLBACK (on_scroll_vertical), self);
  gtk_widget_add_controller (widget, vscroll);

  GtkEventController *hscroll = gtk_event_controller_scroll_new (GTK_EVENT_CONTROLLER_SCROLL_HORIZONTAL);
  g_signal_connect (hscroll, "scroll", G_CALLBACK (on_scroll_horizontal), self);
  gtk_widget_add_controller (widget, hscroll);

  self->im = gtk_im_multicontext_new ();
  gtk_im_context_set_use_preedit (self->im, TRUE);
  g_signal_connect (self->im, "preedit-start", G_CALLBACK (on_im_preedit_start), self);
  g_signal_connect (self->im, "preedit-changed", G_CALLBACK (on_im_preedit_changed), self);
  g_signal_connect (self->im, "preedit-end", G_CALLBACK (on_im_preedit_end), self);
  g_signal_connect (self->im, "commit", G_CALLBACK (on_im_commit), self);

  GtkSettings *settings = gtk_settings_get_default ();
  if (settings != NULL)
    self->xft_notify_id = g_signal_connect (settings, "notify::gtk-xft-dpi",
                                            G_CALLBACK (on_xft_notify), self);
}

static ToasttyGhosttyRenderer
choose_renderer (gboolean *forced)
{
  const char *env = g_getenv ("TOASTTY_GHOSTTY_RENDERER");
  *forced = FALSE;
  if (env != NULL)
    {
      if (g_ascii_strcasecmp (env, "offscreen") == 0)
        {
          *forced = TRUE;
          return TOASTTY_GHOSTTY_RENDERER_OFFSCREEN;
        }
      if (g_ascii_strcasecmp (env, "gl") == 0)
        {
          *forced = TRUE;
          return TOASTTY_GHOSTTY_RENDERER_GL;
        }
      if (*env != '\0' && g_ascii_strcasecmp (env, "auto") != 0)
        g_warning ("unknown TOASTTY_GHOSTTY_RENDERER=%s (expected gl|offscreen)", env);
    }

  /* DMA-BUF textures need a GL-capable GDK display. */
  GdkDisplay *display = gdk_display_get_default ();
  if (display == NULL || display_is_broadway (display))
    return TOASTTY_GHOSTTY_RENDERER_OFFSCREEN;
  g_autoptr (GError) error = NULL;
  if (!gdk_display_prepare_gl (display, &error))
    {
      g_message ("GDK has no GL (%s); using offscreen presentation",
                 error ? error->message : "unknown");
      return TOASTTY_GHOSTTY_RENDERER_OFFSCREEN;
    }
  return TOASTTY_GHOSTTY_RENDERER_GL;
}

GtkWidget *
toastty_ghostty_surface_new (ghostty_app_t app, const ghostty_surface_config_s *config)
{
  g_return_val_if_fail (app != NULL, NULL);
  toastty_ghostty_init (0, NULL);

  ToasttyGhosttySurface *self = g_object_ref_sink (g_object_new (TOASTTY_GHOSTTY_TYPE_SURFACE, NULL));
  self->app = app;

  ghostty_surface_config_s cfg = config != NULL ? *config : ghostty_surface_config_new ();
  self->user_data = cfg.userdata;

  SurfaceHandle *h = g_atomic_rc_box_new0 (SurfaceHandle);
  h->widget = self;
  h->app = app;

  cfg.platform_tag = GHOSTTY_PLATFORM_LINUX;
  memset (&cfg.platform, 0, sizeof cfg.platform);
  cfg.userdata = h;
  if (cfg.scale_factor <= 0)
    {
      GdkDisplay *display = gdk_display_get_default ();
      GListModel *monitors = display ? gdk_display_get_monitors (display) : NULL;
      GdkMonitor *monitor = monitors && g_list_model_get_n_items (monitors) > 0
                                ? g_list_model_get_item (monitors, 0)
                                : NULL;
      cfg.scale_factor = monitor ? gdk_monitor_get_scale (monitor) : 1.0;
      g_clear_object (&monitor);
      if (cfg.scale_factor <= 0)
        cfg.scale_factor = 1.0;
    }
  self->scale = cfg.scale_factor;

  ghostty_surface_t surface = ghostty_surface_new (app, &cfg);
  if (surface == NULL)
    {
      g_atomic_rc_box_release (h);
      h = NULL;
      g_object_unref (self);
      return NULL;
    }
  h->surface = surface;
  self->surface = surface;
  self->handle = h;

  if (surface_handles == NULL)
    surface_handles = g_hash_table_new (g_direct_hash, g_direct_equal);
  g_hash_table_insert (surface_handles, surface, h);

  ghostty_surface_set_content_scale (surface, self->scale * self->xft, self->scale * self->xft);
  set_renderer (self, choose_renderer (&self->renderer_forced));

  /* Floating reference semantics like any other widget constructor. */
  g_object_force_floating (G_OBJECT (self));
  return GTK_WIDGET (self);
}

ghostty_surface_t
toastty_ghostty_surface_get_surface (ToasttyGhosttySurface *self)
{
  g_return_val_if_fail (TOASTTY_GHOSTTY_IS_SURFACE (self), NULL);
  return self->surface;
}

ghostty_app_t
toastty_ghostty_surface_get_app (ToasttyGhosttySurface *self)
{
  g_return_val_if_fail (TOASTTY_GHOSTTY_IS_SURFACE (self), NULL);
  return self->app;
}

gpointer
toastty_ghostty_surface_get_user_data (ToasttyGhosttySurface *self)
{
  g_return_val_if_fail (TOASTTY_GHOSTTY_IS_SURFACE (self), NULL);
  return self->user_data;
}

const char *
toastty_ghostty_surface_get_title (ToasttyGhosttySurface *self)
{
  g_return_val_if_fail (TOASTTY_GHOSTTY_IS_SURFACE (self), NULL);
  return self->title;
}

const char *
toastty_ghostty_surface_get_pwd (ToasttyGhosttySurface *self)
{
  g_return_val_if_fail (TOASTTY_GHOSTTY_IS_SURFACE (self), NULL);
  return self->pwd;
}

ToasttyGhosttyRenderer
toastty_ghostty_surface_get_renderer (ToasttyGhosttySurface *self)
{
  g_return_val_if_fail (TOASTTY_GHOSTTY_IS_SURFACE (self), TOASTTY_GHOSTTY_RENDERER_OFFSCREEN);
  return self->renderer;
}

GdkTexture *
toastty_ghostty_surface_get_texture (ToasttyGhosttySurface *self)
{
  g_return_val_if_fail (TOASTTY_GHOSTTY_IS_SURFACE (self), NULL);
  /* Take any frame the renderer finished since the last paint so callers
   * see the newest contents even if GTK has not painted yet. */
  pull_frame (self);
  return self->texture;
}

void
toastty_ghostty_surface_set_key_filter (ToasttyGhosttySurface *self, ToasttyGhosttyKeyFilterFunc func,
                                        gpointer user_data, GDestroyNotify destroy)
{
  g_return_if_fail (TOASTTY_GHOSTTY_IS_SURFACE (self));
  if (self->key_filter_destroy != NULL)
    self->key_filter_destroy (self->key_filter_data);
  self->key_filter = func;
  self->key_filter_data = user_data;
  self->key_filter_destroy = destroy;
}
