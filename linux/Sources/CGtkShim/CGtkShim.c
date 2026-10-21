#include "CGtkShim.h"

GType toastty_g_type_none(void) { return G_TYPE_NONE; }
GType toastty_g_type_boolean(void) { return G_TYPE_BOOLEAN; }
GType toastty_g_type_int(void) { return G_TYPE_INT; }
GType toastty_g_type_uint(void) { return G_TYPE_UINT; }
GType toastty_g_type_int64(void) { return G_TYPE_INT64; }
GType toastty_g_type_double(void) { return G_TYPE_DOUBLE; }
GType toastty_g_type_string(void) { return G_TYPE_STRING; }
GType toastty_g_type_object(void) { return G_TYPE_OBJECT; }

gboolean toastty_instance_is_a(gpointer instance, GType type) {
    if (instance == NULL) {
        return FALSE;
    }
    return G_TYPE_CHECK_INSTANCE_TYPE(instance, type);
}

const char *toastty_object_type_name(gpointer instance) {
    if (instance == NULL || !G_IS_OBJECT(instance)) {
        return "(null)";
    }
    return G_OBJECT_TYPE_NAME(instance);
}

gulong toastty_signal_connect(gpointer instance,
                              const char *detailed_signal,
                              void *handler,
                              gpointer data,
                              GClosureNotify destroy_data,
                              gboolean after) {
    return g_signal_connect_data(instance,
                                 detailed_signal,
                                 G_CALLBACK(handler),
                                 data,
                                 destroy_data,
                                 after ? G_CONNECT_AFTER : (GConnectFlags)0);
}

guint toastty_invalid_list_position(void) { return GTK_INVALID_LIST_POSITION; }

gboolean toastty_widget_write_png(GtkWidget *widget, const char *path, const GdkRGBA *background, GError **error) {
    g_return_val_if_fail(GTK_IS_WIDGET(widget), FALSE);

    // Render the toplevel's child tree directly with gtk_widget_snapshot_child
    // instead of GtkWidgetPaintable: the paintable reuses the last painted
    // frame, and Broadway without a connected viewer never paints.
    GtkWidget *parent = widget;
    GtkWidget *child = widget;
    if (GTK_IS_WINDOW(widget)) {
        child = gtk_window_get_child(GTK_WINDOW(widget));
    } else {
        parent = gtk_widget_get_parent(widget);
    }
    if (child == NULL || parent == NULL) {
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "nothing to render");
        return FALSE;
    }
    if (!gtk_widget_get_mapped(child)) {
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "widget %s is not mapped", G_OBJECT_TYPE_NAME(child));
        return FALSE;
    }

    int width = gtk_widget_get_width(child);
    int height = gtk_widget_get_height(child);
    if (width <= 0 || height <= 0) {
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                    "widget %s has no allocation yet (%dx%d)",
                    G_OBJECT_TYPE_NAME(child), width, height);
        return FALSE;
    }

    GtkSnapshot *snapshot = gtk_snapshot_new();
    graphene_point_t origin = GRAPHENE_POINT_INIT(0, 0);
    graphene_point_t offset = GRAPHENE_POINT_INIT(0, 0);
    if (gtk_widget_compute_point(child, parent, &origin, &offset)) {
        gtk_snapshot_translate(snapshot, &GRAPHENE_POINT_INIT(-offset.x, -offset.y));
    }
    if (background != NULL) {
        gtk_snapshot_append_color(snapshot, background,
                                  &GRAPHENE_RECT_INIT(offset.x, offset.y, (float)width, (float)height));
    }
    gtk_widget_snapshot_child(parent, child, snapshot);
    GskRenderNode *node = gtk_snapshot_free_to_node(snapshot);
    if (node == NULL) {
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "widget produced no render node");
        return FALSE;
    }

    GskRenderer *renderer = gsk_cairo_renderer_new();
    if (!gsk_renderer_realize_for_display(renderer, gtk_widget_get_display(widget), error)) {
        g_object_unref(renderer);
        gsk_render_node_unref(node);
        return FALSE;
    }

    graphene_rect_t viewport = GRAPHENE_RECT_INIT(0, 0, (float)width, (float)height);
    GdkTexture *texture = gsk_renderer_render_texture(renderer, node, &viewport);
    gsk_renderer_unrealize(renderer);
    g_object_unref(renderer);
    gsk_render_node_unref(node);

    if (texture == NULL) {
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "renderer produced no texture");
        return FALSE;
    }
    gboolean ok = gdk_texture_save_to_png(texture, path);
    g_object_unref(texture);
    if (!ok) {
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "could not write %s", path);
    }
    return ok;
}
GdkContentProvider *toastty_content_provider_new_string(const char *value) {
    return gdk_content_provider_new_typed(G_TYPE_STRING, value);
}

const char *toastty_value_get_string(const GValue *value) {
    if (value == NULL || !G_VALUE_HOLDS_STRING(value)) {
        return NULL;
    }
    return g_value_get_string(value);
}

void toastty_window_force_layout(GtkWindow *window, int width, int height) {
    g_return_if_fail(GTK_IS_WINDOW(window));
    GtkWidget *child = gtk_window_get_child(window);
    if (child == NULL || !gtk_widget_get_visible(child)) {
        return;
    }
    if (width <= 0) {
        width = gtk_widget_get_width(child);
    }
    if (height <= 0) {
        height = gtk_widget_get_height(child);
    }
    if (width <= 0 || height <= 0) {
        gtk_window_get_default_size(window, &width, &height);
    }
    int minimum = 0, natural = 0;
    gtk_widget_measure(child, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, NULL, NULL);
    width = MAX(width, minimum);
    gtk_widget_measure(child, GTK_ORIENTATION_VERTICAL, width, &minimum, &natural, NULL, NULL);
    height = MAX(height, minimum);
    gtk_widget_allocate(child, width, height, -1, NULL);
}
