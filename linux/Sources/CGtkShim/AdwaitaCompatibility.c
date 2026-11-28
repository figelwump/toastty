#include "CGtkShim.h"

GtkWidget *toastty_adw_button_row_new(const char *title, const char *icon_name) {
#if ADW_CHECK_VERSION(1, 6, 0)
    GtkWidget *row = adw_button_row_new();
    if (icon_name != NULL)
        adw_button_row_set_start_icon_name(ADW_BUTTON_ROW(row), icon_name);
#else
    GtkWidget *row = adw_action_row_new();
    gtk_list_box_row_set_activatable(GTK_LIST_BOX_ROW(row), TRUE);
    if (icon_name != NULL)
        adw_action_row_add_prefix(ADW_ACTION_ROW(row), gtk_image_new_from_icon_name(icon_name));
#endif
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row), title);
    return row;
}

GtkWidget *toastty_shortcut_label_new(const char *accelerator) {
#if ADW_CHECK_VERSION(1, 8, 0)
    return adw_shortcut_label_new(accelerator);
#else
    return gtk_shortcut_label_new(accelerator);
#endif
}

GtkWidget *toastty_shortcuts_dialog_new(void) {
#if ADW_CHECK_VERSION(1, 8, 0)
    return GTK_WIDGET(adw_shortcuts_dialog_new());
#else
    GtkWidget *window = g_object_new(GTK_TYPE_SHORTCUTS_WINDOW, "modal", TRUE, NULL);
    GtkWidget *section = g_object_new(GTK_TYPE_SHORTCUTS_SECTION, NULL);
    gtk_shortcuts_window_add_section(GTK_SHORTCUTS_WINDOW(window), GTK_SHORTCUTS_SECTION(section));
    g_object_set_data(G_OBJECT(window), "toastty-shortcuts-section", section);
    return window;
#endif
}

gpointer toastty_shortcuts_dialog_add_section(GtkWidget *dialog, const char *title) {
#if ADW_CHECK_VERSION(1, 8, 0)
    AdwShortcutsSection *section = adw_shortcuts_section_new(title);
    adw_shortcuts_dialog_add(ADW_SHORTCUTS_DIALOG(dialog), section);
    return section;
#else
    GtkWidget *group = g_object_new(GTK_TYPE_SHORTCUTS_GROUP, "title", title, NULL);
    GtkShortcutsSection *section = g_object_get_data(G_OBJECT(dialog), "toastty-shortcuts-section");
    gtk_shortcuts_section_add_group(section, GTK_SHORTCUTS_GROUP(group));
    return group;
#endif
}

void toastty_shortcuts_section_add(gpointer section, const char *title, const char *accelerator) {
#if ADW_CHECK_VERSION(1, 8, 0)
    adw_shortcuts_section_add(ADW_SHORTCUTS_SECTION(section), adw_shortcuts_item_new(title, accelerator));
#else
    GtkShortcutsShortcut *shortcut = g_object_new(GTK_TYPE_SHORTCUTS_SHORTCUT,
                                                   "title", title, "accelerator", accelerator, NULL);
    gtk_shortcuts_group_add_shortcut(GTK_SHORTCUTS_GROUP(section), shortcut);
#endif
}

void toastty_shortcuts_dialog_present(GtkWidget *dialog, GtkWidget *parent) {
#if ADW_CHECK_VERSION(1, 8, 0)
    adw_dialog_present(ADW_DIALOG(dialog), parent);
#else
    gtk_window_set_transient_for(GTK_WINDOW(dialog), GTK_WINDOW(parent));
    gtk_window_set_destroy_with_parent(GTK_WINDOW(dialog), TRUE);
    gtk_window_present(GTK_WINDOW(dialog));
#endif
}

const char *toastty_adw_accent_name(void) {
#if ADW_CHECK_VERSION(1, 6, 0)
    switch (adw_style_manager_get_accent_color(adw_style_manager_get_default())) {
        case ADW_ACCENT_COLOR_BLUE: return "blue";
        case ADW_ACCENT_COLOR_TEAL: return "teal";
        case ADW_ACCENT_COLOR_GREEN: return "green";
        case ADW_ACCENT_COLOR_YELLOW: return "yellow";
        case ADW_ACCENT_COLOR_ORANGE: return "orange";
        case ADW_ACCENT_COLOR_RED: return "red";
        case ADW_ACCENT_COLOR_PINK: return "pink";
        case ADW_ACCENT_COLOR_PURPLE: return "purple";
        case ADW_ACCENT_COLOR_SLATE: return "slate";
        default: break;
    }
#endif
    return "unknown";
}
