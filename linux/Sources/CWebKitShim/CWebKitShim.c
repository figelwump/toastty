#include "CWebKitShim.h"

GtkWidget *toastty_webkit_web_view_new(WebKitWebContext *context,
                                       WebKitNetworkSession *session,
                                       WebKitUserContentManager *content_manager,
                                       WebKitSettings *settings,
                                       WebKitWebView *related) {
    if (related != NULL) {
        // Related views inherit the opener's context, session and content
        // manager; only settings may be supplied.
        return GTK_WIDGET(g_object_new(WEBKIT_TYPE_WEB_VIEW,
                                       "related-view", related,
                                       "settings", settings != NULL ? settings : webkit_web_view_get_settings(related),
                                       NULL));
    }
    const char *names[4];
    GValue values[4] = {G_VALUE_INIT, G_VALUE_INIT, G_VALUE_INIT, G_VALUE_INIT};
    guint count = 0;
    if (context != NULL) {
        names[count] = "web-context";
        g_value_init(&values[count], WEBKIT_TYPE_WEB_CONTEXT);
        g_value_set_object(&values[count], context);
        count++;
    }
    if (session != NULL) {
        names[count] = "network-session";
        g_value_init(&values[count], WEBKIT_TYPE_NETWORK_SESSION);
        g_value_set_object(&values[count], session);
        count++;
    }
    if (content_manager != NULL) {
        names[count] = "user-content-manager";
        g_value_init(&values[count], WEBKIT_TYPE_USER_CONTENT_MANAGER);
        g_value_set_object(&values[count], content_manager);
        count++;
    }
    if (settings != NULL) {
        names[count] = "settings";
        g_value_init(&values[count], WEBKIT_TYPE_SETTINGS);
        g_value_set_object(&values[count], settings);
        count++;
    }
    GObject *view = g_object_new_with_properties(WEBKIT_TYPE_WEB_VIEW, count, names, values);
    for (guint i = 0; i < count; i++) {
        g_value_unset(&values[i]);
    }
    return GTK_WIDGET(view);
}
