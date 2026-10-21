import CGtk
import CoreState
import Foundation

/// Renders a `SplitLayoutPlan` as nested `GtkPaned`s inside one `AdwBin`.
///
/// - Same shape as last render: widgets stay; only divider positions move.
/// - Different shape: a new paned tree is built and the existing panel
///   frames are moved into it (frames are cached and retained elsewhere, so
///   terminal surfaces are never recreated by a split).
/// - Divider positions follow state ratios on every resize; a user drag is
///   debounced and reported once through `onRatioChanged`.
@MainActor
public final class SplitLayoutRenderer {
    private final class PanedState {
        let nodeID: UUID
        let paned: OpaquePointer
        var desiredRatio: Double
        var appliedMaxPosition: Int32 = -1
        var isApplying = false
        var dragTimer: guint = 0

        init(nodeID: UUID, paned: OpaquePointer, ratio: Double) {
            self.nodeID = nodeID
            self.paned = paned
            self.desiredRatio = ratio
        }
    }

    public let root: WidgetPtr
    private let rootRef: GObjectRef
    private var shape: SplitLayoutShape?
    private var paneds: [UUID: PanedState] = [:]

    public var onRatioChanged: ((UUID, Double) -> Void)?

    /// Number of full rebuilds, for tests: ratio-only updates must not rebuild.
    public private(set) var rebuildCount = 0

    public init() {
        root = adw_bin_new()
        rootRef = GObjectRef(sinking: root)
        Gtk.addClasses(root, ["split-root"])
        Gtk.expand(root)
    }

    deinit {
        MainActor.assumeIsolated {
            for state in paneds.values { MainLoop.cancel(state.dragTimer) }
        }
    }

    public func render(_ plan: SplitLayoutPlan, frame: (UUID) -> WidgetPtr) {
        let newShape = plan.root.shape
        if newShape == shape {
            for (nodeID, ratio) in plan.root.ratios {
                guard let state = paneds[nodeID] else { continue }
                if abs(state.desiredRatio - ratio) > LayoutNode.splitRatioChangeEpsilon {
                    state.desiredRatio = ratio
                    state.appliedMaxPosition = -1
                    apply(state)
                }
            }
            return
        }

        rebuildCount += 1
        for state in paneds.values { MainLoop.cancel(state.dragTimer) }
        paneds.removeAll()
        let tree = build(plan.root, frame: frame)
        adw_bin_set_child(cast(root), tree)
        shape = newShape
    }

    /// Paned for a split node, for tests and screenshots.
    public func paned(for nodeID: UUID) -> OpaquePointer? { paneds[nodeID]?.paned }

    public var splitNodeIDs: Set<UUID> { Set(paneds.keys) }

    private func build(_ node: SplitLayoutNode, frame: (UUID) -> WidgetPtr) -> WidgetPtr {
        switch node {
        case .panel(let panelID, _):
            let widget = frame(panelID)
            Gtk.detachFromParent(widget)
            return widget

        case .split(let nodeID, let axis, let ratio, let first, let second):
            let orientation = axis == .sideBySide ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL
            let panedWidget = gtk_paned_new(orientation)!
            let paned: OpaquePointer = cast(panedWidget)
            Gtk.addClasses(panedWidget, ["toastty-split"])
            Gtk.expand(panedWidget)
            gtk_paned_set_wide_handle(paned, 0)
            gtk_paned_set_resize_start_child(paned, 1)
            gtk_paned_set_resize_end_child(paned, 1)
            gtk_paned_set_shrink_start_child(paned, 0)
            gtk_paned_set_shrink_end_child(paned, 0)

            let firstWidget = build(first, frame: frame)
            let secondWidget = build(second, frame: frame)
            gtk_paned_set_start_child(paned, firstWidget)
            gtk_paned_set_end_child(paned, secondWidget)

            let state = PanedState(nodeID: nodeID, paned: paned, ratio: ratio)
            paneds[nodeID] = state
            Signal.notify(paned, "max-position") { [weak self, weak state] in
                guard let self, let state else { return }
                self.apply(state)
            }
            Signal.notify(paned, "position") { [weak self, weak state] in
                guard let self, let state else { return }
                self.positionChanged(state)
            }
            return panedWidget
        }
    }

    private func apply(_ state: PanedState) {
        let maxPosition = GProperty.int(state.paned, "max-position")
        guard maxPosition > 0 else { return }
        state.appliedMaxPosition = maxPosition
        let target = SplitLayoutPlan.position(forRatio: state.desiredRatio, maxPosition: maxPosition)
        guard gtk_paned_get_position(state.paned) != target else { return }
        state.isApplying = true
        gtk_paned_set_position(state.paned, target)
        state.isApplying = false
    }

    private func positionChanged(_ state: PanedState) {
        guard state.isApplying == false else { return }
        let maxPosition = GProperty.int(state.paned, "max-position")
        guard maxPosition > 0 else { return }
        if maxPosition != state.appliedMaxPosition {
            // Allocation changed (window resize): ratios come from state.
            apply(state)
            return
        }
        let position = gtk_paned_get_position(state.paned)
        guard let ratio = SplitLayoutPlan.ratio(forPosition: position, maxPosition: maxPosition),
              SplitLayoutPlan.isMeaningfulDrag(from: state.desiredRatio, to: ratio, maxPosition: maxPosition) else {
            return
        }
        // User drag: report once the divider settles.
        MainLoop.cancel(state.dragTimer)
        state.dragTimer = MainLoop.timeout(milliseconds: 120) { [weak self, weak state] in
            guard let self, let state else { return false }
            state.dragTimer = 0
            let settled = gtk_paned_get_position(state.paned)
            let currentMax = GProperty.int(state.paned, "max-position")
            if let ratio = SplitLayoutPlan.ratio(forPosition: settled, maxPosition: currentMax) {
                state.desiredRatio = ratio
                self.onRatioChanged?(state.nodeID, ratio)
            }
            return false
        }
    }
}
