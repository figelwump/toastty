/* toastty-ghostty-demo: two Ghostty terminals running $SHELL in a GtkPaned.
 *
 *   linux/.deps/ghostty/bin/toastty-ghostty-demo
 *
 * Loads the user's Ghostty config (~/.config/ghostty/config). Ctrl+Shift+Q
 * quits (handled by the key filter, before Ghostty sees the key).
 *
 * TOASTTY_GHOSTTY_DEMO_SCREENSHOT=<file.png> saves the window contents
 * after two seconds and quits (used for headless checks under Broadway).
 */
#include <toastty-ghostty-gtk.h>

static ghostty_app_t app;
static GtkWidget *window;
static int live_terminals;

static gboolean
key_filter (ToasttyGhosttySurface *surface, guint keyval, guint keycode, GdkModifierType state,
            gboolean pressed, gpointer user_data)
{
  GdkModifierType mods = state & (GDK_CONTROL_MASK | GDK_SHIFT_MASK | GDK_ALT_MASK | GDK_SUPER_MASK);
  if (pressed && mods == (GDK_CONTROL_MASK | GDK_SHIFT_MASK) && gdk_keyval_to_lower (keyval) == GDK_KEY_q)
    {
      gtk_window_destroy (GTK_WINDOW (window));
      return TRUE;
    }
  return FALSE;
}

static void
on_title (ToasttyGhosttySurface *surface, const char *title, gpointer user_data)
{
  if (gtk_widget_has_focus (GTK_WIDGET (surface)) && title != NULL)
    gtk_window_set_title (GTK_WINDOW (window), title);
}

static void
on_close (ToasttyGhosttySurface *surface, gboolean process_alive, gpointer user_data)
{
  gtk_widget_set_visible (GTK_WIDGET (surface), FALSE);
  if (--live_terminals <= 0)
    gtk_window_destroy (GTK_WINDOW (window));
}

static gboolean
on_navigation (ToasttyGhosttySurface *surface, int direction, gpointer user_data)
{
  g_print ("mouse navigation: %s\n", direction == TOASTTY_GHOSTTY_NAVIGATION_BACK ? "back" : "forward");
  return TRUE;
}

static GtkWidget *
make_terminal (void)
{
  ghostty_surface_config_s config = ghostty_surface_config_new ();
  GtkWidget *terminal = toastty_ghostty_surface_new (app, &config);
  if (terminal == NULL)
    g_error ("failed to create a Ghostty surface");
  toastty_ghostty_surface_set_key_filter (TOASTTY_GHOSTTY_SURFACE (terminal), key_filter, NULL, NULL);
  g_signal_connect (terminal, "title-changed", G_CALLBACK (on_title), NULL);
  g_signal_connect (terminal, "close-requested", G_CALLBACK (on_close), NULL);
  g_signal_connect (terminal, "mouse-navigation", G_CALLBACK (on_navigation), NULL);
  live_terminals++;
  return terminal;
}

static void
on_window_active (GtkWindow *win, GParamSpec *pspec, gpointer user_data)
{
  ghostty_app_set_focus (app, gtk_window_is_active (win));
}

static gboolean
screenshot_timeout (gpointer user_data)
{
  const char *path = user_data;
  GtkWidget *child = gtk_window_get_child (GTK_WINDOW (window));
  int w = gtk_widget_get_width (child);
  int h = gtk_widget_get_height (child);
  /* Snapshot the widget tree directly (a Broadway display without a
   * browser never paints, so GtkWidgetPaintable would be empty). */
  GtkSnapshot *snapshot = gtk_snapshot_new ();
  GTK_WIDGET_GET_CLASS (child)->snapshot (child, snapshot);
  GskRenderNode *node = gtk_snapshot_free_to_node (snapshot);
  if (node != NULL)
    {
      GskRenderer *renderer = gsk_cairo_renderer_new ();
      gsk_renderer_realize_for_display (renderer, gtk_widget_get_display (child), NULL);
      GdkTexture *texture = gsk_renderer_render_texture (renderer, node, &GRAPHENE_RECT_INIT (0, 0, w, h));
      g_print ("screenshot %s: %s\n", path, gdk_texture_save_to_png (texture, path) ? "saved" : "failed");
      g_object_unref (texture);
      gsk_renderer_unrealize (renderer);
      g_object_unref (renderer);
      gsk_render_node_unref (node);
    }
  gtk_window_destroy (GTK_WINDOW (window));
  return G_SOURCE_REMOVE;
}

static void
activate (GtkApplication *gtk_app, gpointer user_data)
{
  ghostty_config_t config = ghostty_config_new ();
  ghostty_config_load_default_files (config);
  ghostty_config_load_recursive_files (config);
  ghostty_config_finalize (config);
  app = toastty_ghostty_app_new (config, NULL);
  ghostty_config_free (config);
  if (app == NULL)
    g_error ("failed to create the Ghostty app");

  window = gtk_application_window_new (gtk_app);
  gtk_window_set_title (GTK_WINDOW (window), "Toastty Ghostty demo");
  gtk_window_set_default_size (GTK_WINDOW (window), 1100, 650);
  g_signal_connect (window, "notify::is-active", G_CALLBACK (on_window_active), NULL);

  GtkWidget *paned = gtk_paned_new (GTK_ORIENTATION_HORIZONTAL);
  gtk_paned_set_wide_handle (GTK_PANED (paned), TRUE);
  GtkWidget *left = make_terminal ();
  GtkWidget *right = make_terminal ();
  gtk_paned_set_start_child (GTK_PANED (paned), left);
  gtk_paned_set_end_child (GTK_PANED (paned), right);
  gtk_paned_set_position (GTK_PANED (paned), 550);
  gtk_window_set_child (GTK_WINDOW (window), paned);
  gtk_window_present (GTK_WINDOW (window));
  gtk_widget_grab_focus (left);

  const char *shot = g_getenv ("TOASTTY_GHOSTTY_DEMO_SCREENSHOT");
  if (shot != NULL && *shot != '\0')
    g_timeout_add (2000, screenshot_timeout, (gpointer) shot);

  g_print ("renderer: %s\n",
           toastty_ghostty_surface_get_renderer (TOASTTY_GHOSTTY_SURFACE (left)) == TOASTTY_GHOSTTY_RENDERER_GL
               ? "gl (dmabuf)"
               : "offscreen (memory)");
}

int
main (int argc, char **argv)
{
  if (!toastty_ghostty_init (argc, argv))
    {
      g_printerr ("ghostty_init failed\n");
      return 1;
    }
  GtkApplication *gtk_app = gtk_application_new ("dev.toastty.GhosttyDemo", G_APPLICATION_NON_UNIQUE);
  g_signal_connect (gtk_app, "activate", G_CALLBACK (activate), NULL);
  int status = g_application_run (G_APPLICATION (gtk_app), argc, argv);
  g_object_unref (gtk_app);
  if (app != NULL)
    toastty_ghostty_app_free (app);
  return status;
}
