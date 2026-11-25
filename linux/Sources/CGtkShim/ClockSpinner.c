#include "CGtkShim.h"
#include <math.h>

/* A spinner whose angle follows the clock, not the widget's age.
 *
 * GtkSpinner turns through a CSS animation that starts when its style is
 * applied, so a spinner recreated by a list rebuild starts again at 0°.
 * Toastty rebuilds sidebar and Tasks rows whenever an agent's status
 * changes, and every spinner in them then jumped back: the turning looked
 * like it stuttered. This one draws the theme's process-working icon rotated
 * by the frame clock's time, so a new spinner continues where the old one
 * was, and all spinners turn together.
 *
 * Its CSS node is "spinner" with the class "clock-spinner": the size and
 * color rules written for spinners apply. Adwaita hides a spinner that is
 * not :checked, which Toastty's theme undoes for the class. */

#define CLOCK_SPINNER_PERIOD_US G_USEC_PER_SEC

typedef struct
{
  GtkWidget parent_instance;
  guint tick_id;
  /* The icon for icon_size at icon_scale; looked up once, not per frame. */
  GtkIconPaintable *icon;
  int icon_size;
  int icon_scale;
} ToasttyClockSpinner;

typedef struct
{
  GtkWidgetClass parent_class;
} ToasttyClockSpinnerClass;

G_DEFINE_TYPE (ToasttyClockSpinner, toastty_clock_spinner, GTK_TYPE_WIDGET)

static gboolean
clock_spinner_tick (GtkWidget *widget, GdkFrameClock *clock, gpointer data)
{
  (void) clock;
  (void) data;
  gtk_widget_queue_draw (widget);
  return G_SOURCE_CONTINUE;
}

static gboolean
clock_spinner_animates (GtkWidget *widget)
{
  gboolean enabled = TRUE;
  g_object_get (gtk_widget_get_settings (widget), "gtk-enable-animations", &enabled, NULL);
  return enabled;
}

static void
clock_spinner_map (GtkWidget *widget)
{
  ToasttyClockSpinner *self = (ToasttyClockSpinner *) widget;
  GTK_WIDGET_CLASS (toastty_clock_spinner_parent_class)->map (widget);
  if (self->tick_id == 0 && clock_spinner_animates (widget))
    self->tick_id = gtk_widget_add_tick_callback (widget, clock_spinner_tick, NULL, NULL);
}

static void
clock_spinner_unmap (GtkWidget *widget)
{
  ToasttyClockSpinner *self = (ToasttyClockSpinner *) widget;
  if (self->tick_id != 0)
    {
      gtk_widget_remove_tick_callback (widget, self->tick_id);
      self->tick_id = 0;
    }
  GTK_WIDGET_CLASS (toastty_clock_spinner_parent_class)->unmap (widget);
}

/* Degrees for `widget` now: from the frame clock while it animates, else 0. */
static double
clock_spinner_angle (GtkWidget *widget)
{
  ToasttyClockSpinner *self = (ToasttyClockSpinner *) widget;
  if (self->tick_id == 0)
    return 0;
  GdkFrameClock *clock = gtk_widget_get_frame_clock (widget);
  gint64 now = clock != NULL ? gdk_frame_clock_get_frame_time (clock) : g_get_monotonic_time ();
  return (double) (now % CLOCK_SPINNER_PERIOD_US) / CLOCK_SPINNER_PERIOD_US * 360.0;
}

static void
clock_spinner_snapshot (GtkWidget *widget, GtkSnapshot *snapshot)
{
  int width = gtk_widget_get_width (widget);
  int height = gtk_widget_get_height (widget);
  int size = MIN (width, height);
  if (size <= 0)
    return;

  ToasttyClockSpinner *self = (ToasttyClockSpinner *) widget;
  int scale = gtk_widget_get_scale_factor (widget);
  if (self->icon == NULL || self->icon_size != size || self->icon_scale != scale)
    {
      g_clear_object (&self->icon);
      GtkIconTheme *theme = gtk_icon_theme_get_for_display (gtk_widget_get_display (widget));
      self->icon = gtk_icon_theme_lookup_icon (theme, "process-working-symbolic", NULL, size, scale,
                                               gtk_widget_get_direction (widget), 0);
      self->icon_size = size;
      self->icon_scale = scale;
    }
  if (self->icon == NULL)
    return;
  GdkRGBA color;
  gtk_widget_get_color (widget, &color);

  gtk_snapshot_save (snapshot);
  gtk_snapshot_translate (snapshot, &GRAPHENE_POINT_INIT (width / 2.0f, height / 2.0f));
  gtk_snapshot_rotate (snapshot, (float) clock_spinner_angle (widget));
  gtk_snapshot_translate (snapshot, &GRAPHENE_POINT_INIT (-size / 2.0f, -size / 2.0f));
  gtk_symbolic_paintable_snapshot_symbolic (GTK_SYMBOLIC_PAINTABLE (self->icon), snapshot, size, size, &color, 1);
  gtk_snapshot_restore (snapshot);
}

/* A theme change can change the icon. */
static void
clock_spinner_css_changed (GtkWidget *widget, GtkCssStyleChange *change)
{
  ToasttyClockSpinner *self = (ToasttyClockSpinner *) widget;
  GTK_WIDGET_CLASS (toastty_clock_spinner_parent_class)->css_changed (widget, change);
  g_clear_object (&self->icon);
}

static void
clock_spinner_dispose (GObject *object)
{
  ToasttyClockSpinner *self = (ToasttyClockSpinner *) object;
  g_clear_object (&self->icon);
  G_OBJECT_CLASS (toastty_clock_spinner_parent_class)->dispose (object);
}

static void
toastty_clock_spinner_class_init (ToasttyClockSpinnerClass *klass)
{
  GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);
  G_OBJECT_CLASS (klass)->dispose = clock_spinner_dispose;
  widget_class->css_changed = clock_spinner_css_changed;
  widget_class->map = clock_spinner_map;
  widget_class->unmap = clock_spinner_unmap;
  widget_class->snapshot = clock_spinner_snapshot;
  gtk_widget_class_set_css_name (widget_class, "spinner");
  gtk_widget_class_set_accessible_role (widget_class, GTK_ACCESSIBLE_ROLE_PROGRESS_BAR);
}

static void
toastty_clock_spinner_init (ToasttyClockSpinner *self)
{
  gtk_widget_add_css_class (GTK_WIDGET (self), "clock-spinner");
  gtk_widget_set_can_target (GTK_WIDGET (self), FALSE);
}

GtkWidget *
toastty_clock_spinner_new (void)
{
  return g_object_new (toastty_clock_spinner_get_type (), NULL);
}
