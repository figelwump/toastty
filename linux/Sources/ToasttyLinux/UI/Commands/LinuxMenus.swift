import CGtk
import Foundation

/// The primary (hamburger) menu, mirroring the macOS menu bar's important
/// commands. Labels and accelerators come from `LinuxCommandTable`.
@MainActor
public enum LinuxMenus {
    public typealias Entry = (id: String, label: String?)

    /// Menu layout as (section, [submenu title?, items]) for tests and docs.
    public static let layout: [[(submenu: String?, items: [String])]] = [
        [
            (nil, ["window.create", "workspace.create", "workspace.tab.create"]),
        ],
        [
            ("Workspace", ["workspace.rename", "workspace.close", "workspace.select-previous", "workspace.select-next",
                           "navigation.back", "navigation.forward", "workspace.merge"]),
            ("Tab", ["workspace.tab.rename", "workspace.tab.close", "workspace.tab.select-previous",
                     "workspace.tab.select-next", "workspace.tab.move-left", "workspace.tab.move-right"]),
            ("Panel", ["layout.split.horizontal", "layout.split.vertical", "layout.split.left", "layout.split.up",
                       "panel.focus-mode.toggle", "layout.split.equalize", "panel.close", "panel.reopen-last-closed",
                       "panel.process-watch.create", "panel.focus-next-unread-or-active", "session.later-flag.toggle",
                       "terminal.agent-reads.toggle"]),
            ("Right Panel", ["window.toggle-right-panel", "browser.create", "browser.tab.create", "browser.split.create",
                             "scratchpad.create", "scratchpad.show-current-session", "local-document.open",
                             "local-document.open-tab", "local-document.open-split"]),
            ("View", ["window.toggle-sidebar", "text-size.increase", "text-size.decrease", "text-size.reset",
                      "find.show", "window.fullscreen"]),
            ("Agents", ["agent.profiles.manage", "agent.status-hooks.setup", "agent.toastty-skills.manage",
                        "terminal.profiles.manage"]),
        ],
        [
            (nil, ["command-palette.toggle", "app.preferences", "app.shortcuts", "app.remote-access.open"]),
        ],
        [
            (nil, ["app.config.manage", "app.reload-configuration", "diagnostics.snippet.copy", "app.about", "app.quit"]),
        ],
    ]

    public static func primaryMenu() -> OpaquePointer {
        let menu = g_menu_new()!
        for section in layout {
            let sectionMenu = g_menu_new()!
            for group in section {
                if let submenu = group.submenu {
                    let sub = g_menu_new()!
                    for id in group.items { appendItem(sub, id) }
                    g_menu_append_submenu(sectionMenu, submenu, cast(sub))
                    g_object_unref(UnsafeMutableRawPointer(sub))
                } else {
                    for id in group.items { appendItem(sectionMenu, id) }
                }
            }
            g_menu_append_section(menu, nil, cast(sectionMenu))
            g_object_unref(UnsafeMutableRawPointer(sectionMenu))
        }
        return menu
    }

    private static func appendItem(_ menu: OpaquePointer, _ id: String) {
        guard let binding = LinuxCommandTable.binding(id) else { return }
        let item = g_menu_item_new(binding.title, "win.\(binding.actionName)")!
        if let accelerator = binding.primaryAccelerator {
            g_menu_item_set_attribute_value(item, "accel", g_variant_new_string(accelerator))
        }
        g_menu_append_item(menu, item)
        g_object_unref(UnsafeMutableRawPointer(item))
    }
}
