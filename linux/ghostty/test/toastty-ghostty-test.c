/* toastty-ghostty-test: end-to-end check of libghostty + the GTK widget.
 *
 * Run through linux/ghostty/test/run-tests.sh (GDK Broadway, offscreen
 * renderer). Steps:
 *   1. create a surface running /bin/sh and wait for a rendered frame
 *   2. type `echo ghostty-linux-ok` + Enter through the widget's key path
 *      (and the IME commit path), poll ghostty_surface_read_text for output
 *   3. verify the presented frame is non-uniform, save it as a PNG
 *   4. resize the widget and verify the terminal grid changes
 *   5. clipboard round-trips: OSC 52 write -> GdkClipboard (standard and
 *      primary), GdkClipboard -> paste into the terminal
 *   6. key filter interception
 * Exits non-zero on the first failure.
 */
#include <toastty-ghostty-gtk.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *artifact_dir = NULL;
static int failures = 0;
static int render_actions = 0;

#define CHECK(cond, ...)                                    \
  do                                                        \
    {                                                       \
      if (!(cond))                                          \
        {                                                   \
          fprintf (stderr, "FAIL: " __VA_ARGS__);           \
          fprintf (stderr, "\n");                           \
          failures++;                                       \
          goto done;                                        \
        }                                                   \
      fprintf (stderr, "ok: " __VA_ARGS__);                 \
      fprintf (stderr, "\n");                               \
    }                                                       \
  while (0)

typedef gboolean (*CondFunc) (gpointer data);

static gboolean
spin_until (CondFunc cond, gpointer data, guint timeout_ms)
{
  gint64 deadline = g_get_monotonic_time () + (gint64) timeout_ms * 1000;
  while (!cond (data))
    {
      if (g_get_monotonic_time () > deadline)
        return FALSE;
      g_main_context_iteration (NULL, FALSE);
      g_usleep (2000);
    }
  return TRUE;
}

static void
spin_for (guint ms)
{
  gint64 deadline = g_get_monotonic_time () + (gint64) ms * 1000;
  while (g_get_monotonic_time () < deadline)
    {
      g_main_context_iteration (NULL, FALSE);
      g_usleep (2000);
    }
}

static gboolean
action_func (ghostty_app_t app, ghostty_target_s target, ghostty_action_s action, gpointer user_data)
{
  if (action.tag == GHOSTTY_ACTION_RENDER)
    render_actions++;
  return FALSE; /* never claim: let the default handling run */
}

static char *
screen_text (ToasttyGhosttySurface *term)
{
  ghostty_surface_t s = toastty_ghostty_surface_get_surface (term);
  ghostty_selection_s sel = {
    .top_left = { .tag = GHOSTTY_POINT_SCREEN, .coord = GHOSTTY_POINT_COORD_TOP_LEFT },
    .bottom_right = { .tag = GHOSTTY_POINT_SCREEN, .coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT },
    .rectangle = false,
  };
  ghostty_text_s text;
  if (!ghostty_surface_read_text (s, sel, &text))
    return g_strdup ("");
  char *result = g_strndup (text.text, text.text_len);
  ghostty_surface_free_text (s, &text);
  return result;
}

typedef struct
{
  ToasttyGhosttySurface *term;
  const char *line;
} LineWait;

/* True when some screen line equals `line` exactly (output, not the echo
 * of the command that produced it). */
static gboolean
has_line (gpointer data)
{
  LineWait *w = data;
  g_autofree char *text = screen_text (w->term);
  g_auto (GStrv) lines = g_strsplit (text, "\n", -1);
  for (char **l = lines; *l; l++)
    {
      g_strchomp (*l);
      if (g_str_equal (*l, w->line))
        return TRUE;
    }
  return FALSE;
}

static gboolean
has_texture (gpointer data)
{
  return toastty_ghostty_surface_get_texture (data) != NULL;
}

static gboolean
has_prompt (gpointer data)
{
  g_autofree char *text = screen_text (data);
  return strstr (text, "$ ") != NULL;
}

static void
type_keys (ToasttyGhosttySurface *term, const char *s)
{
  for (const char *p = s; *p; p = g_utf8_next_char (p))
    {
      gunichar c = g_utf8_get_char (p);
      guint keyval = gdk_unicode_to_keyval (c);
      GdkModifierType state = 0;
      if (g_unichar_isupper (c))
        state |= GDK_SHIFT_MASK;
      toastty_ghostty_surface_send_key (term, keyval, 0, state, TRUE);
      toastty_ghostty_surface_send_key (term, keyval, 0, state, FALSE);
    }
}

static void
press_enter (ToasttyGhosttySurface *term)
{
  toastty_ghostty_surface_send_key (term, GDK_KEY_Return, 0, 0, TRUE);
  toastty_ghostty_surface_send_key (term, GDK_KEY_Return, 0, 0, FALSE);
}

static guint
count_colors (const guchar *pixels, gsize stride, int x0, int y0, int x1, int y1)
{
  GHashTable *colors = g_hash_table_new (g_direct_hash, g_direct_equal);
  for (int y = y0; y < y1; y++)
    for (int x = x0; x < x1; x++)
      {
        guint32 px;
        memcpy (&px, pixels + (gsize) y * stride + (gsize) x * 4, 4);
        g_hash_table_add (colors, GUINT_TO_POINTER (px));
      }
  guint n = g_hash_table_size (colors);
  g_hash_table_unref (colors);
  return n;
}

/* Renders the widget through its real snapshot() (texture flip and scale)
 * with GSK's Cairo renderer, checks that the image is non-uniform and
 * upright (the shell's first lines are at the top), and saves a PNG. */
static gboolean
check_frame (ToasttyGhosttySurface *term, const char *name)
{
  GtkWidget *widget = GTK_WIDGET (term);
  if (toastty_ghostty_surface_get_texture (term) == NULL)
    return FALSE;
  int w = gtk_widget_get_width (widget);
  int h = gtk_widget_get_height (widget);
  if (w <= 0 || h <= 0)
    return FALSE;

  /* Call the widget's snapshot vfunc directly: GtkWidgetPaintable only
   * replays what GTK last painted, and a Broadway display without a
   * connected browser does not paint. */
  GtkSnapshot *snapshot = gtk_snapshot_new ();
  GTK_WIDGET_GET_CLASS (widget)->snapshot (widget, snapshot);
  GskRenderNode *node = gtk_snapshot_free_to_node (snapshot);
  if (node == NULL)
    {
      fprintf (stderr, "info: widget produced no render node (mapped=%d realized=%d drawable=%d)\n",
               gtk_widget_get_mapped (widget), gtk_widget_get_realized (widget),
               gtk_widget_is_drawable (widget));
      return FALSE;
    }
  GskRenderer *renderer = gsk_cairo_renderer_new ();
  gsk_renderer_realize_for_display (renderer, gtk_widget_get_display (widget), NULL);
  GdkTexture *image = gsk_renderer_render_texture (renderer, node, &GRAPHENE_RECT_INIT (0, 0, w, h));
  gsk_renderer_unrealize (renderer);
  g_object_unref (renderer);
  gsk_render_node_unref (node);

  int iw = gdk_texture_get_width (image);
  int ih = gdk_texture_get_height (image);
  gsize stride = (gsize) iw * 4;
  guchar *pixels = g_malloc (stride * (gsize) ih);
  gdk_texture_download (image, pixels, stride);
  guint all = count_colors (pixels, stride, 0, 0, iw, ih);
  guint top = count_colors (pixels, stride, 0, 0, iw, MIN (ih, 40));
  guint bottom = count_colors (pixels, stride, 0, MAX (0, ih - 40), iw, ih);
  g_free (pixels);

  g_autofree char *path = g_build_filename (artifact_dir, name, NULL);
  gboolean saved = gdk_texture_save_to_png (image, path);
  g_object_unref (image);
  fprintf (stderr, "info: widget image %dx%d, %u colors (top band %u, bottom band %u), saved=%d %s\n",
           iw, ih, all, top, bottom, saved, path);
  /* Text at the top, empty background at the bottom: non-uniform and upright. */
  return all > 2 && top > 2 && bottom <= 2 && saved;
}

typedef struct
{
  GdkClipboard *clipboard;
  char *text;
  gboolean pending;
} ClipRead;

static void
clip_read_done (GObject *source, GAsyncResult *res, gpointer data)
{
  ClipRead *r = data;
  g_free (r->text);
  r->text = gdk_clipboard_read_text_finish (GDK_CLIPBOARD (source), res, NULL);
  r->pending = FALSE;
}

typedef struct
{
  GdkClipboard *clipboard;
  const char *want;
} ClipWait;

static gboolean
clipboard_has (gpointer data)
{
  ClipWait *w = data;
  ClipRead r = { .clipboard = w->clipboard, .text = NULL, .pending = TRUE };
  gdk_clipboard_read_text_async (w->clipboard, NULL, clip_read_done, &r);
  while (r.pending)
    g_main_context_iteration (NULL, TRUE);
  gboolean ok = r.text != NULL && g_str_equal (r.text, w->want);
  g_free (r.text);
  return ok;
}

typedef struct
{
  ghostty_surface_t surface;
  guint16 cols;
  guint16 rows;
} GridWait;

static gboolean
grid_changed (gpointer data)
{
  GridWait *w = data;
  ghostty_surface_size_s size = ghostty_surface_size (w->surface);
  return size.columns != w->cols && size.rows != w->rows;
}

static int filter_hits = 0;

static gboolean
key_filter (ToasttyGhosttySurface *surface, guint keyval, guint keycode, GdkModifierType state,
            gboolean pressed, gpointer user_data)
{
  if (keyval == GDK_KEY_F12)
    {
      if (pressed)
        filter_hits++;
      return TRUE;
    }
  return FALSE;
}

int
main (int argc, char **argv)
{
  artifact_dir = g_getenv ("TOASTTY_GHOSTTY_ARTIFACTS");
  if (artifact_dir == NULL)
    artifact_dir = "artifacts/manual/ghostty-linux";
  g_mkdir_with_parents (artifact_dir, 0755);

  if (!toastty_ghostty_init (argc, argv))
    {
      fprintf (stderr, "FAIL: ghostty_init\n");
      return 1;
    }
  gtk_init ();
  fprintf (stderr, "info: display=%s resources=%s\n",
           G_OBJECT_TYPE_NAME (gdk_display_get_default ()),
           toastty_ghostty_resources_dir () ? toastty_ghostty_resources_dir () : "(none)");

  ghostty_config_t config = ghostty_config_new ();
  /* Hermetic: no user config files. */
  ghostty_config_finalize (config);
  ToasttyGhosttyRuntimeOptions opts = { .action_func = action_func, .supports_program_status = TRUE };
  ghostty_app_t app = toastty_ghostty_app_new (config, &opts);
  ghostty_config_free (config);
  if (app == NULL)
    {
      fprintf (stderr, "FAIL: toastty_ghostty_app_new\n");
      return 1;
    }

  GtkWidget *window = NULL;
  ToasttyGhosttySurface *term = NULL;
  {
    ghostty_env_var_s env[] = {
      { .key = "PS1", .value = "$ " },
      { .key = "ENV", .value = "" },
    };
    ghostty_surface_config_s sc = ghostty_surface_config_new ();
    sc.command = "/bin/sh";
    sc.env_vars = env;
    sc.env_var_count = G_N_ELEMENTS (env);
    sc.userdata = (void *) 0x1234;
    GtkWidget *widget = toastty_ghostty_surface_new (app, &sc);
    CHECK (widget != NULL, "surface created");
    term = TOASTTY_GHOSTTY_SURFACE (widget);
    CHECK (toastty_ghostty_surface_get_user_data (term) == (void *) 0x1234, "host user data kept");
    CHECK (toastty_ghostty_surface_from_surface (toastty_ghostty_surface_get_surface (term)) == term,
           "widget lookup from ghostty_surface_t");

    window = gtk_window_new ();
    gtk_window_set_default_size (GTK_WINDOW (window), 640, 400);
    gtk_window_set_child (GTK_WINDOW (window), widget);
    gtk_window_present (GTK_WINDOW (window));
    gtk_widget_grab_focus (widget);
  }

  {
    const char *forced = g_getenv ("TOASTTY_GHOSTTY_RENDERER");
    gboolean broadway = g_str_equal (G_OBJECT_TYPE_NAME (gdk_display_get_default ()), "GdkBroadwayDisplay");
    ToasttyGhosttyRenderer want = TOASTTY_GHOSTTY_RENDERER_GL;
    if (g_strcmp0 (forced, "offscreen") == 0 || (broadway && g_strcmp0 (forced, "gl") != 0))
      want = TOASTTY_GHOSTTY_RENDERER_OFFSCREEN;
    CHECK (toastty_ghostty_surface_get_renderer (term) == want, "renderer selection (%s)",
           want == TOASTTY_GHOSTTY_RENDERER_GL ? "gl" : "offscreen");
  }
  CHECK (spin_until (has_texture, term, 15000), "first frame presented (render actions: %d)", render_actions);
  CHECK (spin_until (has_prompt, term, 15000), "shell prompt visible");

  /* Keys for "echo ghostty-", IME commit path for "linux-ok", Enter key. */
  type_keys (term, "echo ghostty-");
  toastty_ghostty_surface_commit_text (term, "linux-ok");
  press_enter (term);
  {
    LineWait w = { term, "ghostty-linux-ok" };
    CHECK (spin_until (has_line, &w, 10000), "terminal output 'ghostty-linux-ok' read back");
  }

  spin_for (300); /* let the renderer present the new contents */
  CHECK (check_frame (term, "ghostty-linux-frame.png"), "rendered frame is non-uniform");

  /* Resize */
  {
    ghostty_surface_size_s before = ghostty_surface_size (toastty_ghostty_surface_get_surface (term));
    GridWait w = { toastty_ghostty_surface_get_surface (term), before.columns, before.rows };
    gtk_widget_set_size_request (GTK_WIDGET (term), 1000, 640);
    gboolean changed = spin_until (grid_changed, &w, 10000);
    ghostty_surface_size_s after = ghostty_surface_size (toastty_ghostty_surface_get_surface (term));
    CHECK (changed && after.columns > before.columns && after.rows > before.rows,
           "resize changes grid %ux%u -> %ux%u", before.columns, before.rows, after.columns, after.rows);
    spin_for (300);
    CHECK (check_frame (term, "ghostty-linux-frame-resized.png"), "resized frame is non-uniform");
    GdkTexture *t = toastty_ghostty_surface_get_texture (term);
    CHECK (t != NULL && (guint) gdk_texture_get_width (t) == after.width_px,
           "presented frame matches new size (%d px wide)", t ? gdk_texture_get_width (t) : -1);
  }

  /* Clipboard: OSC 52 write from the program into GdkClipboard. */
  {
    GdkClipboard *clipboard = gtk_widget_get_clipboard (GTK_WIDGET (term));
    toastty_ghostty_surface_commit_text (
        term, "printf '\\033]52;c;%s\\007' \"$(printf toastty-clip-ok | base64)\"");
    press_enter (term);
    ClipWait w = { clipboard, "toastty-clip-ok" };
    CHECK (spin_until (clipboard_has, &w, 10000), "OSC 52 write reached the standard clipboard");

    GdkClipboard *primary = gtk_widget_get_primary_clipboard (GTK_WIDGET (term));
    toastty_ghostty_surface_commit_text (
        term, "printf '\\033]52;p;%s\\007' \"$(printf toastty-primary-ok | base64)\"");
    press_enter (term);
    ClipWait wp = { primary, "toastty-primary-ok" };
    CHECK (spin_until (clipboard_has, &wp, 10000), "OSC 52 write reached the primary selection");

    /* GdkClipboard -> terminal paste */
    gdk_clipboard_set_text (clipboard, "echo pasted-$((40+2))");
    const char *paste = "paste_from_clipboard";
    CHECK (ghostty_surface_binding_action (toastty_ghostty_surface_get_surface (term), paste, strlen (paste)),
           "paste binding action accepted");
    spin_for (200);
    press_enter (term);
    LineWait lw = { term, "pasted-42" };
    CHECK (spin_until (has_line, &lw, 10000), "clipboard paste reached the shell");
  }

  /* Key filter intercepts before ghostty */
  {
    toastty_ghostty_surface_set_key_filter (term, key_filter, NULL, NULL);
    gboolean consumed = toastty_ghostty_surface_send_key (term, GDK_KEY_F12, 0, 0, TRUE);
    toastty_ghostty_surface_send_key (term, GDK_KEY_F12, 0, 0, FALSE);
    CHECK (consumed && filter_hits == 1, "key filter claimed F12");
    toastty_ghostty_surface_set_key_filter (term, NULL, NULL, NULL);
  }

  /* Exit status reaches the host */
  {
    type_keys (term, "exit");
    press_enter (term);
    spin_for (500);
    CHECK (ghostty_surface_process_exited (toastty_ghostty_surface_get_surface (term)),
           "child exit reported");
  }

  fprintf (stderr, "info: final renderer %s\n",
           toastty_ghostty_surface_get_renderer (term) == TOASTTY_GHOSTTY_RENDERER_GL ? "gl (dmabuf)"
                                                                                      : "offscreen (memory)");

done:
  {
    g_autofree char *text = term ? screen_text (term) : NULL;
    if (failures && text)
      fprintf (stderr, "--- screen ---\n%s\n--------------\n", text);
  }
  if (window != NULL)
    gtk_window_destroy (GTK_WINDOW (window));
  spin_for (100);
  toastty_ghostty_app_free (app);
  fprintf (stderr, "%s (%d failure%s, %d render actions)\n", failures ? "FAILED" : "PASSED", failures,
           failures == 1 ? "" : "s", render_actions);
  return failures ? 1 : 0;
}
