import CGtk
import Foundation

/// One tab as state describes it.
public struct TabItem {
    public let id: UUID
    public let title: String
    public let tooltip: String?
    public let needsAttention: Bool
    public let child: WidgetPtr
    /// Favicon / loading spinner (right-panel web tabs).
    public let decoration: PanelTabDecoration?

    public init(id: UUID, title: String, tooltip: String? = nil, needsAttention: Bool = false, child: WidgetPtr, decoration: PanelTabDecoration? = nil) {
        self.id = id
        self.title = title
        self.tooltip = tooltip
        self.needsAttention = needsAttention
        self.child = child
        self.decoration = decoration
    }
}

/// Keeps an `AdwTabView`'s pages in step with state. State is authoritative:
/// user gestures (select, close, drag-reorder) are reported through the
/// callbacks and the page set only changes when state comes back.
@MainActor
public final class TabViewSync {
    public let view: OpaquePointer
    public let widget: WidgetPtr
    private let viewRef: GObjectRef
    private var pageByID: [UUID: OpaquePointer] = [:]
    private var order: [UUID] = []
    private var isSyncing = false

    public var onSelect: ((UUID) -> Void)?
    /// User asked to close a tab (close button, middle click).
    public var onCloseRequest: ((UUID) -> Void)?
    public var onReorder: ((_ id: UUID, _ toIndex: Int) -> Void)?

    public init() {
        let tabView = adw_tab_view_new()!
        view = tabView
        widget = ToasttyLinuxUI.widget(tabView)
        viewRef = GObjectRef(sinking: widget)
        // Toastty's command table owns every tab shortcut.
        adw_tab_view_set_shortcuts(view, ADW_TAB_VIEW_SHORTCUT_NONE)
        Gtk.expand(widget)

        Signal.notify(view, "selected-page") { [weak self] in
            guard let self, self.isSyncing == false,
                  let page = adw_tab_view_get_selected_page(self.view),
                  let id = self.id(for: page) else { return }
            self.onSelect?(id)
        }
        Signal.connectPointerBool(view, "close-page") { [weak self] pagePointer in
            guard let self, let pagePointer else { return false }
            let page = OpaquePointer(pagePointer)
            if self.isSyncing {
                adw_tab_view_close_page_finish(self.view, page, 1)
            } else {
                adw_tab_view_close_page_finish(self.view, page, 0)
                if let id = self.id(for: page) { self.onCloseRequest?(id) }
            }
            return true
        }
        Signal.connectPointerUInt(view, "page-reordered") { [weak self] pagePointer, position in
            guard let self, self.isSyncing == false, let pagePointer,
                  let id = self.id(for: OpaquePointer(pagePointer)) else { return }
            self.onReorder?(id, Int(Int32(bitPattern: position)))
        }
    }

    public var pageIDs: [UUID] { order }

    public func page(for id: UUID) -> OpaquePointer? { pageByID[id] }

    private func id(for page: OpaquePointer) -> UUID? {
        pageByID.first(where: { $0.value == page })?.key
    }

    public func sync(_ items: [TabItem], selectedID: UUID?) {
        isSyncing = true
        defer { isSyncing = false }

        let wanted = Set(items.map(\.id))
        for id in order where wanted.contains(id) == false {
            if let page = pageByID.removeValue(forKey: id) {
                adw_tab_view_close_page(view, page)
            }
        }
        order.removeAll { wanted.contains($0) == false }

        for (index, item) in items.enumerated() {
            let page: OpaquePointer
            if let existing = pageByID[item.id] {
                page = existing
                if adw_tab_page_get_child(page) != item.child {
                    // Content widget replaced: re-add the page in place.
                    adw_tab_view_close_page(view, page)
                    order.removeAll { $0 == item.id }
                    let replacement = adw_tab_view_insert(view, item.child, Int32(min(index, order.count)))!
                    pageByID[item.id] = replacement
                    order.insert(item.id, at: min(index, order.count))
                    configure(replacement, item)
                    continue
                }
            } else {
                Gtk.detachFromParent(item.child)
                page = adw_tab_view_insert(view, item.child, Int32(min(index, order.count)))!
                pageByID[item.id] = page
                order.insert(item.id, at: min(index, order.count))
            }
            if let current = order.firstIndex(of: item.id), current != index {
                adw_tab_view_reorder_page(view, page, Int32(index))
                order.remove(at: current)
                order.insert(item.id, at: index)
            }
            configure(page, item)
        }

        if let selectedID, let page = pageByID[selectedID], adw_tab_view_get_selected_page(view) != page {
            adw_tab_view_set_selected_page(view, page)
        }
    }

    private func configure(_ page: OpaquePointer, _ item: TabItem) {
        if String(cString: adw_tab_page_get_title(page)) != item.title {
            adw_tab_page_set_title(page, item.title)
        }
        adw_tab_page_set_tooltip(page, item.tooltip ?? item.title)
        if adw_tab_page_get_needs_attention(page).bool != item.needsAttention {
            adw_tab_page_set_needs_attention(page, item.needsAttention.gboolean)
        }
        if let decoration = item.decoration {
            applyDecoration(decoration, to: page)
        }
    }

    /// Sets a tab's favicon and loading spinner without a full sync.
    public func applyDecoration(_ decoration: PanelTabDecoration, toTab id: UUID) {
        guard let page = pageByID[id] else { return }
        applyDecoration(decoration, to: page)
    }

    private func applyDecoration(_ decoration: PanelTabDecoration, to page: OpaquePointer) {
        if adw_tab_page_get_loading(page).bool != decoration.isLoading {
            adw_tab_page_set_loading(page, decoration.isLoading.gboolean)
        }
        let current = adw_tab_page_get_icon(page)
        if current != decoration.icon {
            adw_tab_page_set_icon(page, decoration.icon)
        }
    }
}
