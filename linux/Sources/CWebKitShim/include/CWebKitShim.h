// Small C helpers for WebKitGTK calls Swift cannot make directly
// (variadic g_object_new construct-only properties).
#pragma once
#include <webkit/webkit.h>

G_BEGIN_DECLS

// A WebKitWebView with construct-only properties set. Any argument may be
// NULL (WebKit's default context / session / a fresh content manager /
// default settings). `related` makes the new view share `related`'s web
// process and session (popup capture views must be related to the opener).
GtkWidget *toastty_webkit_web_view_new(WebKitWebContext *context,
                                       WebKitNetworkSession *session,
                                       WebKitUserContentManager *content_manager,
                                       WebKitSettings *settings,
                                       WebKitWebView *related);

G_END_DECLS
