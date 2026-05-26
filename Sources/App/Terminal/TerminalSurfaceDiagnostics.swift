#if TOASTTY_HAS_GHOSTTY_KIT
import AppKit
import CoreState
import Foundation

@MainActor
enum TerminalSurfaceDiagnostics {
    static let snapshotEnvironmentKey = "TOASTTY_GHOSTTY_SURFACE_DIAGNOSTICS"
    static let deferBackgroundSurfaceCreationEnvironmentKey = "TOASTTY_GHOSTTY_DEFER_BACKGROUND_SURFACE_CREATION"

    static var snapshotLoggingEnabled: Bool {
        isEnabledFlag(ProcessInfo.processInfo.environment[snapshotEnvironmentKey])
    }

    static var deferBackgroundSurfaceCreationEnabled: Bool {
        isEnabledFlag(ProcessInfo.processInfo.environment[deferBackgroundSurfaceCreationEnvironmentKey])
    }

    static func isEnabledFlag(_ rawValue: String?) -> Bool {
        guard let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        switch normalized {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    static func shouldDeferSurfaceCreationForPresentationVisibility(
        hostView: NSView,
        deferBackgroundSurfaceCreation: Bool = deferBackgroundSurfaceCreationEnabled
    ) -> Bool {
        guard deferBackgroundSurfaceCreation,
              let terminalHostView = hostView as? TerminalHostView else {
            return false
        }

        let snapshot = terminalHostView.visibilityTraceSnapshot()
        return snapshot.isMountedAndTransparent
    }

    static func presentationVisibilityMetadata(hostView: NSView) -> [String: String] {
        guard let terminalHostView = hostView as? TerminalHostView else {
            return [:]
        }

        let snapshot = terminalHostView.visibilityTraceSnapshot()
        return [
            "presentation_has_window": snapshot.hasWindow ? "true" : "false",
            "presentation_hidden": snapshot.isHidden ? "true" : "false",
            "presentation_hidden_ancestor": snapshot.hasHiddenAncestor ? "true" : "false",
            "presentation_window_visible": snapshot.windowVisible ? "true" : "false",
            "presentation_self_alpha_thousandths": String(snapshot.selfAlphaThousandths),
            "presentation_min_ancestor_alpha_thousandths": String(snapshot.minAncestorAlphaThousandths),
            "presentation_min_chain_alpha_thousandths": String(snapshot.minChainAlphaThousandths),
            "presentation_transparent": snapshot.visuallyTransparent ? "true" : "false",
            "presentation_resolved_visible": snapshot.resolvedVisible ? "true" : "false",
        ]
    }

    static func logSnapshot(
        event: String,
        state: AppState,
        livePanelIDs: Set<UUID>,
        removedPanelIDs: Set<UUID>,
        controllerForPanelID: (UUID) -> TerminalSurfaceController?
    ) {
        guard snapshotLoggingEnabled else { return }

        let layoutCounts = layoutCounts(state: state)
        let controllerCounts = controllerCounts(
            terminalPanelIDs: layoutCounts.terminalPanelIDs,
            controllerForPanelID: controllerForPanelID
        )
        let selectedWorkspace = state.selectedWorkspaceSelection()

        ToasttyLog.info(
            "Ghostty surface diagnostic snapshot",
            category: .ghostty,
            metadata: [
                "event": event,
                "selected_window_id": selectedWorkspace?.windowID.uuidString ?? "none",
                "selected_workspace_id": selectedWorkspace?.workspaceID.uuidString ?? "none",
                "selected_workspace_title": selectedWorkspace?.workspace.title ?? "none",
                "selected_tab_id": selectedWorkspace?.workspace.resolvedSelectedTabID?.uuidString ?? "none",
                "total_terminal_panel_count": String(layoutCounts.terminalPanelIDs.count),
                "selected_primary_terminal_panel_count": String(layoutCounts.selectedPrimaryTerminalPanelIDs.count),
                "right_aux_panel_count": String(layoutCounts.rightAuxPanelCount),
                "selected_mounted_right_aux_panel_count": String(layoutCounts.selectedMountedRightAuxPanelCount),
                "live_terminal_panel_count": String(livePanelIDs.count),
                "removed_terminal_panel_count": String(removedPanelIDs.count),
                "terminal_controller_count": String(controllerCounts.controllerCount),
                "ghostty_surface_count": String(controllerCounts.surfaceCount),
                "ghostty_surface_presentation_visible_count": String(controllerCounts.presentationVisibleSurfaceCount),
                "ghostty_surface_logically_visible_count": String(controllerCounts.logicallyVisibleSurfaceCount),
                "ghostty_surface_transparent_count": String(controllerCounts.transparentSurfaceCount),
                "ghostty_surface_no_window_count": String(controllerCounts.noWindowSurfaceCount),
                "ghostty_surface_defer_background_enabled": deferBackgroundSurfaceCreationEnabled ? "true" : "false",
            ]
        )
    }

    private struct LayoutCounts {
        var terminalPanelIDs: Set<UUID> = []
        var selectedPrimaryTerminalPanelIDs: Set<UUID> = []
        var rightAuxPanelCount = 0
        var selectedMountedRightAuxPanelCount = 0
    }

    private struct ControllerCounts {
        var controllerCount = 0
        var surfaceCount = 0
        var presentationVisibleSurfaceCount = 0
        var logicallyVisibleSurfaceCount = 0
        var transparentSurfaceCount = 0
        var noWindowSurfaceCount = 0
    }

    private static func layoutCounts(state: AppState) -> LayoutCounts {
        var counts = LayoutCounts()
        for workspace in state.workspacesByID.values {
            counts.terminalPanelIDs.formUnion(workspace.allTerminalPanelIDs)
            for tab in workspace.orderedTabs {
                counts.rightAuxPanelCount += tab.rightAuxPanel.panelIDs.count
            }
        }

        guard let selectedWorkspace = state.selectedWorkspaceSelection(),
              let selectedTab = selectedWorkspace.workspace.selectedTab else {
            return counts
        }

        counts.selectedPrimaryTerminalPanelIDs = primaryTerminalPanelIDs(in: selectedTab)
        if selectedTab.rightAuxPanel.isVisible,
           selectedTab.focusedPanelModeActive == false,
           selectedTab.rightAuxPanel.activePanelID != nil {
            counts.selectedMountedRightAuxPanelCount = 1
        }
        return counts
    }

    private static func primaryTerminalPanelIDs(in tab: WorkspaceTabState) -> Set<UUID> {
        tab.layoutTree.allSlotInfos.reduce(into: Set<UUID>()) { result, slot in
            guard case .terminal = tab.panels[slot.panelID] else {
                return
            }
            result.insert(slot.panelID)
        }
    }

    private static func controllerCounts(
        terminalPanelIDs: Set<UUID>,
        controllerForPanelID: (UUID) -> TerminalSurfaceController?
    ) -> ControllerCounts {
        var counts = ControllerCounts()
        for panelID in terminalPanelIDs {
            guard let controller = controllerForPanelID(panelID) else {
                continue
            }
            counts.controllerCount += 1
            guard controller.currentGhosttySurface() != nil else {
                continue
            }
            counts.surfaceCount += 1

            let snapshot = controller.hostVisibilityTraceSnapshot()
            if snapshot.resolvedVisible {
                counts.presentationVisibleSurfaceCount += 1
            }
            if snapshot.logicallyVisibleIgnoringTransparency {
                counts.logicallyVisibleSurfaceCount += 1
            }
            if snapshot.visuallyTransparent {
                counts.transparentSurfaceCount += 1
            }
            if snapshot.hasWindow == false {
                counts.noWindowSurfaceCount += 1
            }
        }
        return counts
    }
}
#endif
