// Small C helpers for GObject/GTK macros that Swift cannot import.
#pragma once
#include <gtk/gtk.h>
#include <adwaita.h>

G_BEGIN_DECLS

// Fundamental GTypes (G_TYPE_* are macros built from G_TYPE_MAKE_FUNDAMENTAL).
GType toastty_g_type_none(void);
GType toastty_g_type_boolean(void);
GType toastty_g_type_int(void);
GType toastty_g_type_uint(void);
GType toastty_g_type_int64(void);
GType toastty_g_type_double(void);
GType toastty_g_type_string(void);
GType toastty_g_type_object(void);

// G_TYPE_CHECK_INSTANCE_TYPE: TRUE when `instance` is a GTypeInstance of `type`
// or a subtype. NULL-safe.
gboolean toastty_instance_is_a(gpointer instance, GType type);

// G_OBJECT_TYPE_NAME for diagnostics. NULL-safe.
const char *toastty_object_type_name(gpointer instance);

// g_signal_connect_data with an untyped handler pointer. `handler` must be a
// C function whose signature matches the signal (G_CALLBACK cast in C).
gulong toastty_signal_connect(gpointer instance,
                              const char *detailed_signal,
                              void *handler,
                              gpointer data,
                              GClosureNotify destroy_data,
                              gboolean after);

// GTK_INVALID_LIST_POSITION.
guint toastty_invalid_list_position(void);

// Runs a measure + allocate pass over a window's content at width x height
// (<= 0 keeps the current size). Headless Broadway with no viewer attached
// never ticks the frame clock after the first frame, so automation lays out
// explicitly before reading geometry or taking screenshots.
void toastty_window_force_layout(GtkWindow *window, int width, int height);

// Snapshots `widget` (for a GtkWindow: its child tree, without CSD shadow)
// over `background` (may be NULL), renders with a Cairo GskRenderer so it
// works under Broadway with no viewer attached, and writes a PNG. Returns
// FALSE and sets `error` when the widget is unmapped/unallocated or the
// write fails.
gboolean toastty_widget_write_png(GtkWidget *widget, const char *path, const GdkRGBA *background, GError **error);

// GdkContentProvider holding a UTF-8 string (gdk_content_provider_new_typed
// is variadic).
GdkContentProvider *toastty_content_provider_new_string(const char *value);

// String payload of a GValue, or NULL when it does not hold a string.
const char *toastty_value_get_string(const GValue *value);

G_END_DECLS
