import AppKit
import CoreState
import Foundation
#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit
#endif

@MainActor
final class TerminalRuntimeRegistry: ObservableObject {
    private var controllers: [UUID: TerminalSurfaceController] = [:]
    private weak var store: AppStore?
    #if TOASTTY_HAS_GHOSTTY_KIT
    private var panelIDBySurfaceHandle: [UInt: UUID] = [:]
    private var previousSelectedWorkspaceID: UUID?
    private var visibilityPulseTask: Task<Void, Never>?
    #endif

    func bind(store: AppStore) {
        if let existingStore = self.store {
            precondition(existingStore === store, "TerminalRuntimeRegistry cannot be rebound to a different AppStore.")
        }
        self.store = store
        #if TOASTTY_HAS_GHOSTTY_KIT
        GhosttyRuntimeManager.shared.actionHandler = self
        #endif
    }

    func controller(for panelID: UUID) -> TerminalSurfaceController {
        if let existing = controllers[panelID] {
            return existing
        }

        let created = TerminalSurfaceController(panelID: panelID, registry: self)
        controllers[panelID] = created
        return created
    }

    func synchronize(with state: AppState) {
        let livePanelIDs = Set(
            state.workspacesByID.values.flatMap { workspace in
                workspace.panels.compactMap { panelID, panelState in
                    if case .terminal = panelState {
                        return panelID
                    }
                    return nil
                }
            }
        )

        for panelID in controllers.keys where !livePanelIDs.contains(panelID) {
            controllers[panelID]?.invalidate()
            controllers.removeValue(forKey: panelID)
        }

        #if TOASTTY_HAS_GHOSTTY_KIT
        pulseVisibleSurfacesIfWorkspaceSwitched(state: state)
        #endif
    }

    func applyGlobalFontChange(from previousPoints: Double, to nextPoints: Double) {
        #if TOASTTY_HAS_GHOSTTY_KIT
        guard previousPoints != nextPoints else { return }
        for controller in controllers.values {
            controller.applyGhosttyGlobalFontChange(from: previousPoints, to: nextPoints)
        }
        #endif
    }

    func automationSendText(_ text: String, submit: Bool, panelID: UUID) -> Bool {
        guard let controller = controllers[panelID] else {
            return false
        }
        return controller.automationSendText(text, submit: submit)
    }

    func automationReadVisibleText(panelID: UUID) -> String? {
        guard let controller = controllers[panelID] else {
            return nil
        }
        return controller.automationReadVisibleText()
    }

    #if TOASTTY_HAS_GHOSTTY_KIT
    private func selectedWorkspaceID(state: AppState) -> UUID? {
        guard let selectedWindowID = state.selectedWindowID,
              let selectedWindow = state.windows.first(where: { $0.id == selectedWindowID }) else {
            return nil
        }
        return selectedWindow.selectedWorkspaceID ?? selectedWindow.workspaceIDs.first
    }

    private func resolvedActionPanelID(in workspace: WorkspaceState) -> UUID? {
        if let focusedPanelID = workspace.focusedPanelID,
           workspace.panels[focusedPanelID] != nil,
           workspace.paneTree.leafContaining(panelID: focusedPanelID) != nil {
            return focusedPanelID
        }

        for leaf in workspace.paneTree.allLeafInfos {
            guard leaf.tabPanelIDs.isEmpty == false else { continue }
            let selectedIndex = min(max(leaf.selectedIndex, 0), leaf.tabPanelIDs.count - 1)
            let preferredPanelID = leaf.tabPanelIDs[selectedIndex]
            if workspace.panels[preferredPanelID] != nil {
                return preferredPanelID
            }

            if let firstValidPanelID = leaf.tabPanelIDs.first(where: { workspace.panels[$0] != nil }) {
                return firstValidPanelID
            }
        }

        return nil
    }

    fileprivate func register(surface: ghostty_surface_t, for panelID: UUID) {
        panelIDBySurfaceHandle[UInt(bitPattern: surface)] = panelID
    }

    fileprivate func unregister(surface: ghostty_surface_t, for panelID: UUID) {
        let key = UInt(bitPattern: surface)
        if panelIDBySurfaceHandle[key] == panelID {
            panelIDBySurfaceHandle.removeValue(forKey: key)
        }
    }

    private func panelID(for surface: ghostty_surface_t) -> UUID? {
        panelIDBySurfaceHandle[UInt(bitPattern: surface)]
    }

    private func workspaceID(containing panelID: UUID, state: AppState) -> UUID? {
        for window in state.windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = state.workspacesByID[workspaceID] else { continue }
                guard workspace.panels[panelID] != nil else { continue }
                if workspace.paneTree.leafContaining(panelID: panelID) != nil {
                    return workspaceID
                }
            }
        }
        return nil
    }

    private func pulseVisibleSurfacesIfWorkspaceSwitched(state: AppState) {
        let currentSelectedWorkspaceID = selectedWorkspaceID(state: state)
        guard currentSelectedWorkspaceID != previousSelectedWorkspaceID else { return }

        visibilityPulseTask?.cancel()
        visibilityPulseTask = nil

        guard let currentSelectedWorkspaceID else {
            previousSelectedWorkspaceID = nil
            return
        }

        guard state.workspacesByID[currentSelectedWorkspaceID] != nil else {
            // Do not consume the transition until workspace data is available.
            return
        }

        previousSelectedWorkspaceID = currentSelectedWorkspaceID
        scheduleVisibilityPulse(for: currentSelectedWorkspaceID)
    }

    private func scheduleVisibilityPulse(for workspaceID: UUID) {
        ToasttyLog.debug(
            "Scheduling Ghostty visibility refresh pulse after workspace switch",
            category: .ghostty,
            metadata: ["workspace_id": workspaceID.uuidString]
        )

        visibilityPulseTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Defer pulses so SwiftUI/NSViewRepresentable attachment and layout can settle.
            await Task.yield()
            guard Task.isCancelled == false else { return }
            self.pulseVisibleSurfaces(in: workspaceID)

            await Task.yield()
            guard Task.isCancelled == false else { return }
            self.pulseVisibleSurfaces(in: workspaceID)
        }
    }

    private func pulseVisibleSurfaces(in workspaceID: UUID) {
        guard let store else { return }
        let currentState = store.state
        guard selectedWorkspaceID(state: currentState) == workspaceID,
              let workspace = currentState.workspacesByID[workspaceID] else {
            return
        }

        let panelIDs = visibleTerminalPanelIDs(in: workspace)
        guard panelIDs.isEmpty == false else { return }
        pulseSurfaces(panelIDs: panelIDs)
    }

    private func visibleTerminalPanelIDs(in workspace: WorkspaceState) -> Set<UUID> {
        var panelIDs: Set<UUID> = []
        for leaf in workspace.paneTree.allLeafInfos {
            guard leaf.tabPanelIDs.isEmpty == false else { continue }
            let selectedIndex = min(max(leaf.selectedIndex, 0), leaf.tabPanelIDs.count - 1)
            let selectedPanelID = leaf.tabPanelIDs[selectedIndex]
            guard let panelState = workspace.panels[selectedPanelID],
                  case .terminal = panelState else {
                continue
            }
            panelIDs.insert(selectedPanelID)
        }
        return panelIDs
    }

    private func pulseSurfaces(panelIDs: Set<UUID>) {
        for panelID in panelIDs {
            controllers[panelID]?.pulseVisibilityRefresh()
        }
    }
    #endif
}

#if TOASTTY_HAS_GHOSTTY_KIT
extension TerminalRuntimeRegistry: GhosttyRuntimeActionHandling {
    func handleGhosttyRuntimeAction(_ action: GhosttyRuntimeAction) -> Bool {
        guard let store else {
            ToasttyLog.warning(
                "Ghostty action dropped because store is unavailable",
                category: .terminal,
                metadata: ["intent": action.logIntentName]
            )
            return false
        }
        let state = store.state

        let panelID: UUID
        let workspaceIDForAction: UUID
        if let surfaceHandle = action.surfaceHandle {
            guard let resolvedPanelID = panelIDBySurfaceHandle[surfaceHandle],
                  let workspaceIDForSurface = workspaceID(containing: resolvedPanelID, state: state) else {
                ToasttyLog.debug(
                    "Ghostty surface action could not resolve panel/workspace",
                    category: .terminal,
                    metadata: [
                        "intent": action.logIntentName,
                        "surface_handle": String(surfaceHandle),
                    ]
                )
                return false
            }
            panelID = resolvedPanelID
            workspaceIDForAction = workspaceIDForSurface
        } else {
            guard let selectedWorkspaceID = selectedWorkspaceID(state: state),
                  let workspace = state.workspacesByID[selectedWorkspaceID],
                  let resolvedPanelID = resolvedActionPanelID(in: workspace) else {
                ToasttyLog.debug(
                    "Ghostty app action could not resolve active panel",
                    category: .terminal,
                    metadata: ["intent": action.logIntentName]
                )
                return false
            }
            panelID = resolvedPanelID
            workspaceIDForAction = selectedWorkspaceID
        }

        guard store.send(.focusPanel(workspaceID: workspaceIDForAction, panelID: panelID)) else {
            ToasttyLog.warning(
                "Ghostty action failed to focus resolved panel",
                category: .terminal,
                metadata: [
                    "intent": action.logIntentName,
                    "workspace_id": workspaceIDForAction.uuidString,
                    "panel_id": panelID.uuidString,
                ]
            )
            return false
        }

        let handled: Bool
        switch action.intent {
        case .split(let direction):
            handled = store.send(.splitFocusedPaneInDirection(workspaceID: workspaceIDForAction, direction: direction))

        case .focus(let direction):
            handled = store.send(.focusPane(workspaceID: workspaceIDForAction, direction: direction))

        case .resizeSplit(let direction, let amount):
            handled = store.send(
                .resizeFocusedPaneSplit(
                    workspaceID: workspaceIDForAction,
                    direction: direction,
                    amount: amount
                )
            )

        case .equalizeSplits:
            handled = store.send(.equalizePaneSplits(workspaceID: workspaceIDForAction))

        case .toggleFocusedPanelMode:
            handled = store.send(.toggleFocusedPanelMode(workspaceID: workspaceIDForAction))
        }

        if handled {
            ToasttyLog.debug(
                "Handled Ghostty runtime action in registry",
                category: .terminal,
                metadata: [
                    "intent": action.logIntentName,
                    "workspace_id": workspaceIDForAction.uuidString,
                    "panel_id": panelID.uuidString,
                ]
            )
        } else {
            ToasttyLog.debug(
                "Reducer rejected Ghostty runtime action",
                category: .terminal,
                metadata: [
                    "intent": action.logIntentName,
                    "workspace_id": workspaceIDForAction.uuidString,
                    "panel_id": panelID.uuidString,
                ]
            )
        }
        return handled
    }
}
#endif

@MainActor
final class TerminalSurfaceController {
    private let panelID: UUID
    private unowned let registry: TerminalRuntimeRegistry
    private let hostedView: NSView
    private weak var activeSourceContainer: NSView?

    #if TOASTTY_HAS_GHOSTTY_KIT
    private var ghosttySurface: ghostty_surface_t?
    private let ghosttyManager = GhosttyRuntimeManager.shared
    private var usesBackingPixelSurfaceSizing = false
    private var hasDeterminedSurfaceSizingMode = false
    private var lastRenderMetrics: GhosttyRenderMetrics?
    private var lastDisplayID: UInt32?
    private var hasLoggedTinyViewportSuppression = false
    private var surfaceCreationStabilityPasses = 0
    private var lastSurfaceCreationSignature: SurfaceCreationSignature?
    private var lastSurfaceDeferralReason: SurfaceCreationDeferralReason?
    private var diagnostics = SurfaceDiagnostics()

    private let minimumSurfaceHostDimension = 16
    private let requiredStableSurfaceCreationPasses = 2

    private struct GhosttyRenderMetrics: Equatable {
        let viewportWidth: Int
        let viewportHeight: Int
        let scaleThousandths: Int
        let widthPx: Int
        let heightPx: Int
        let columns: Int
        let rows: Int
        let cellWidthPx: Int
        let cellHeightPx: Int
        let pixelSizingEnabled: Bool
    }

    private struct SurfaceCreationSignature: Equatable {
        let windowID: ObjectIdentifier
        let width: Int
        let height: Int
    }

    private enum SurfaceCreationDeferralReason: String {
        case noWindow = "no_window"
        case hiddenHost = "hidden_host"
        case tinyBounds = "tiny_bounds"
        case unstableBounds = "unstable_bounds"
    }

    private struct SurfaceDiagnostics {
        var attachCount = 0
        var updateCount = 0
        var surfaceAttemptCount = 0
        var surfaceSuccessCount = 0
        var surfaceFailureCount = 0
        var surfaceDeferredCount = 0
    }
    #endif

    private let fallbackView = TerminalFallbackView()

    init(panelID: UUID, registry: TerminalRuntimeRegistry) {
        self.panelID = panelID
        self.registry = registry
        #if TOASTTY_HAS_GHOSTTY_KIT
        hostedView = TerminalHostView()
        #else
        hostedView = fallbackView
        #endif
    }

    func attach(into container: NSView) {
        #if TOASTTY_HAS_GHOSTTY_KIT
        diagnostics.attachCount += 1
        #endif
        let sourceContainerChanged = activeSourceContainer !== container
        #if TOASTTY_HAS_GHOSTTY_KIT
        if shouldIgnoreAttach(to: container) {
            ToasttyLog.debug(
                "Ignoring terminal attach from detached container callback",
                category: .ghostty,
                metadata: ["panel_id": panelID.uuidString]
            )
            return
        }
        #endif

        activeSourceContainer = container
        if hostedView.superview !== container {
            hostedView.removeFromSuperview()
            container.addSubview(hostedView)
            hostedView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hostedView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hostedView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                hostedView.topAnchor.constraint(equalTo: container.topAnchor),
                hostedView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        #if TOASTTY_HAS_GHOSTTY_KIT
        if sourceContainerChanged {
            surfaceCreationStabilityPasses = 0
            lastSurfaceCreationSignature = nil
            lastSurfaceDeferralReason = nil
            refreshSurfaceAfterContainerMove(sourceContainer: container)
        }
        #endif
    }

    func update(
        terminalState: TerminalPanelState,
        focused: Bool,
        fontPoints: Double,
        viewportSize: CGSize,
        backingScaleFactor: CGFloat,
        sourceContainer: NSView
    ) {
        #if TOASTTY_HAS_GHOSTTY_KIT
        diagnostics.updateCount += 1
        if activeSourceContainer !== sourceContainer {
            if shouldPromoteSourceContainer(to: sourceContainer) {
                attach(into: sourceContainer)
            } else {
                ToasttyLog.debug(
                    "Skipping terminal update from stale container callback",
                    category: .ghostty,
                    metadata: [
                        "panel_id": panelID.uuidString,
                    ]
                )
                return
            }
        }

        guard hostedView.superview === sourceContainer else {
            ToasttyLog.debug(
                "Skipping terminal update because host view is not attached to source container",
                category: .ghostty,
                metadata: [
                    "panel_id": panelID.uuidString,
                ]
            )
            return
        }

        ensureGhosttySurface(terminalState: terminalState, fontPoints: fontPoints)
        guard let ghosttySurface else {
            // Keep the host visible while retrying Ghostty surface creation.
            hostedView.isHidden = false
            if let hostView = hostedView as? TerminalHostView {
                hostView.setGhosttySurface(nil)
            }
            fallbackView.update(terminalState: terminalState, unavailableReason: "Ghostty surface unavailable")
            swapToFallbackIfNeeded()
            return
        }

        hostedView.isHidden = false
        if let hostView = hostedView as? TerminalHostView {
            hostView.setGhosttySurface(ghosttySurface)
        }
        if fallbackView.superview != nil {
            fallbackView.removeFromSuperview()
        }

        let xScale = max(Double(backingScaleFactor), 1)
        let yScale = max(Double(backingScaleFactor), 1)
        let logicalWidth = max(Int(viewportSize.width.rounded(.down)), 1)
        let logicalHeight = max(Int(viewportSize.height.rounded(.down)), 1)
        if logicalWidth <= tinyViewportSuppressionThreshold || logicalHeight <= tinyViewportSuppressionThreshold {
            if !hasLoggedTinyViewportSuppression {
                ToasttyLog.debug(
                    "Skipping tiny transient terminal viewport update during hierarchy churn",
                    category: .ghostty,
                    metadata: [
                        "panel_id": panelID.uuidString,
                        "viewport_width": String(logicalWidth),
                        "viewport_height": String(logicalHeight),
                    ]
                )
            }
            hasLoggedTinyViewportSuppression = true
            return
        }
        hasLoggedTinyViewportSuppression = false
        updateDisplayIDIfNeeded(surface: ghosttySurface, sourceContainer: sourceContainer)
        ghostty_surface_set_content_scale(ghosttySurface, xScale, yScale)
        let pixelWidth = max(Int((viewportSize.width * backingScaleFactor).rounded()), 1)
        let pixelHeight = max(Int((viewportSize.height * backingScaleFactor).rounded()), 1)
        let hasUsableViewport = logicalWidth > 16 && logicalHeight > 16
        var measuredSizeForLogging: ghostty_surface_size_s?

        if hasDeterminedSurfaceSizingMode == false {
            ghostty_surface_set_size(ghosttySurface, UInt32(logicalWidth), UInt32(logicalHeight))
            let measuredSize = ghostty_surface_size(ghosttySurface)
            measuredSizeForLogging = measuredSize

            if hasUsableViewport {
                hasDeterminedSurfaceSizingMode = true
                usesBackingPixelSurfaceSizing = shouldUseBackingPixelSurfaceSizing(
                    measuredSize: measuredSize,
                    logicalWidth: logicalWidth,
                    logicalHeight: logicalHeight,
                    expectedPixelWidth: pixelWidth,
                    expectedPixelHeight: pixelHeight,
                    scale: xScale
                )

                if usesBackingPixelSurfaceSizing {
                    ghostty_surface_set_size(ghosttySurface, UInt32(pixelWidth), UInt32(pixelHeight))
                    measuredSizeForLogging = ghostty_surface_size(ghosttySurface)
                    ToasttyLog.debug(
                        "Enabled backing-pixel Ghostty surface sizing for high-DPI rendering",
                        category: .ghostty,
                        metadata: [
                            "panel_id": panelID.uuidString,
                            "scale": String(format: "%.3f", xScale),
                            "logical_width": String(logicalWidth),
                            "logical_height": String(logicalHeight),
                            "pixel_width": String(pixelWidth),
                            "pixel_height": String(pixelHeight),
                            "reported_width_px": String(measuredSize.width_px),
                            "reported_height_px": String(measuredSize.height_px),
                        ]
                    )
                }
            }
        } else if usesBackingPixelSurfaceSizing {
            ghostty_surface_set_size(ghosttySurface, UInt32(pixelWidth), UInt32(pixelHeight))
        } else {
            ghostty_surface_set_size(ghosttySurface, UInt32(logicalWidth), UInt32(logicalHeight))
        }

        logRenderMetricsIfNeeded(
            viewportWidth: logicalWidth,
            viewportHeight: logicalHeight,
            scale: xScale,
            measuredSize: measuredSizeForLogging
        )
        ghostty_surface_set_focus(ghosttySurface, focused)
        ensureFirstResponderIfNeeded(focused: focused)
        #else
        fallbackView.update(terminalState: terminalState, unavailableReason: "Ghostty terminal runtime not enabled in this build")
        #endif
    }

    func invalidate() {
        #if TOASTTY_HAS_GHOSTTY_KIT
        if let hostView = hostedView as? TerminalHostView {
            hostView.setGhosttySurface(nil)
        }
        if let ghosttySurface {
            registry.unregister(surface: ghosttySurface, for: panelID)
            ghostty_surface_free(ghosttySurface)
            self.ghosttySurface = nil
        }
        usesBackingPixelSurfaceSizing = false
        hasDeterminedSurfaceSizingMode = false
        lastRenderMetrics = nil
        lastDisplayID = nil
        hasLoggedTinyViewportSuppression = false
        surfaceCreationStabilityPasses = 0
        lastSurfaceCreationSignature = nil
        lastSurfaceDeferralReason = nil
        diagnostics = SurfaceDiagnostics()
        #endif
        activeSourceContainer = nil
        fallbackView.removeFromSuperview()
        hostedView.removeFromSuperview()
    }

    func automationSendText(_ text: String, submit: Bool) -> Bool {
        #if TOASTTY_HAS_GHOSTTY_KIT
        guard let ghosttySurface else {
            return false
        }

        if text.isEmpty == false {
            sendSurfaceText(text, to: ghosttySurface)
        }

        if submit {
            sendSurfaceText("\n", to: ghosttySurface)
        }

        return true
        #else
        return false
        #endif
    }

    func automationReadVisibleText() -> String? {
        #if TOASTTY_HAS_GHOSTTY_KIT
        guard let ghosttySurface else {
            return nil
        }

        var textPayload = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )

        guard ghostty_surface_read_text(ghosttySurface, selection, &textPayload) else {
            return nil
        }
        defer {
            ghostty_surface_free_text(ghosttySurface, &textPayload)
        }
        guard let textPointer = textPayload.text else {
            return nil
        }

        let bytePointer = UnsafeRawPointer(textPointer).assumingMemoryBound(to: UInt8.self)
        let buffer = UnsafeBufferPointer(start: bytePointer, count: Int(textPayload.text_len))
        return String(decoding: buffer, as: UTF8.self)
        #else
        return nil
        #endif
    }

    #if TOASTTY_HAS_GHOSTTY_KIT
    private func sendSurfaceText(_ text: String, to surface: ghostty_surface_t) {
        let cString = text.utf8CString
        cString.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            let byteCount = max(buffer.count - 1, 0) // drop C-string null terminator
            guard byteCount > 0 else { return }
            ghostty_surface_text(surface, baseAddress, uintptr_t(byteCount))
        }
    }

    func applyGhosttyGlobalFontChange(from previousPoints: Double, to nextPoints: Double) {
        guard let ghosttySurface else { return }

        if nextPoints == AppState.defaultTerminalFontPoints {
            _ = invokeGhosttyBindingAction("reset_font_size", on: ghosttySurface)
            return
        }

        let pointDelta = nextPoints - previousPoints
        guard pointDelta != 0 else { return }
        let stepMagnitude = max(
            Int(round(abs(pointDelta) / AppState.terminalFontStepPoints)),
            1
        )
        let action = pointDelta > 0
            ? "increase_font_size:\(stepMagnitude)"
            : "decrease_font_size:\(stepMagnitude)"
        _ = invokeGhosttyBindingAction(action, on: ghosttySurface)
    }

    @discardableResult
    private func invokeGhosttyBindingAction(_ action: String, on surface: ghostty_surface_t) -> Bool {
        let cString = action.utf8CString
        let handled = cString.withUnsafeBufferPointer { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            let byteCount = max(buffer.count - 1, 0)
            guard byteCount > 0 else { return false }
            return ghostty_surface_binding_action(surface, baseAddress, uintptr_t(byteCount))
        }
        if handled == false {
            ToasttyLog.warning(
                "Ghostty binding action not handled",
                category: .ghostty,
                metadata: [
                    "action": action,
                    "panel_id": panelID.uuidString,
                ]
            )
        }
        return handled
    }
    #endif

    #if TOASTTY_HAS_GHOSTTY_KIT
    private func ensureGhosttySurface(terminalState: TerminalPanelState, fontPoints: Double) {
        guard ghosttySurface == nil else { return }

        guard let hostView = hostedView as? TerminalHostView else { return }

        switch evaluateSurfaceCreationReadiness(for: hostView) {
        case .ready:
            break

        case .deferred(let reason, let width, let height):
            diagnostics.surfaceDeferredCount += 1
            let reasonChanged = lastSurfaceDeferralReason != reason
            lastSurfaceDeferralReason = reason
            if reasonChanged || diagnostics.surfaceDeferredCount <= 2 || diagnostics.surfaceDeferredCount.isMultiple(of: 60) {
                logSurfaceDiagnostics(
                    message: "Deferring Ghostty surface creation until host is stable",
                    extra: [
                        "reason": reason.rawValue,
                        "host_width": String(width),
                        "host_height": String(height),
                        "stability_passes": String(surfaceCreationStabilityPasses),
                    ]
                )
            }
            return
        }

        diagnostics.surfaceAttemptCount += 1
        guard let surface = ghosttyManager.makeSurface(
            hostView: hostView,
            workingDirectory: terminalState.cwd,
            fontPoints: fontPoints
        ) else {
            diagnostics.surfaceFailureCount += 1
            if diagnostics.surfaceFailureCount <= 5 || diagnostics.surfaceFailureCount.isMultiple(of: 20) {
                logSurfaceDiagnostics(
                    message: "Ghostty surface creation attempt failed",
                    extra: [
                        "host_has_window": hostView.window == nil ? "false" : "true",
                        "host_hidden": hostView.isHidden ? "true" : "false",
                        "host_hidden_ancestor": hostView.hasHiddenAncestor ? "true" : "false",
                        "host_width": String(format: "%.1f", hostView.bounds.width),
                        "host_height": String(format: "%.1f", hostView.bounds.height),
                    ]
                )
            }
            return
        }
        diagnostics.surfaceSuccessCount += 1
        lastSurfaceDeferralReason = nil
        surfaceCreationStabilityPasses = 0
        lastSurfaceCreationSignature = nil
        logSurfaceDiagnostics(message: "Ghostty surface creation succeeded")
        usesBackingPixelSurfaceSizing = false
        hasDeterminedSurfaceSizingMode = false
        lastRenderMetrics = nil
        lastDisplayID = nil
        hasLoggedTinyViewportSuppression = false
        ghosttySurface = surface
        registry.register(surface: surface, for: panelID)
    }

    private enum SurfaceCreationReadiness {
        case ready
        case deferred(reason: SurfaceCreationDeferralReason, width: Int, height: Int)
    }

    private func evaluateSurfaceCreationReadiness(for hostView: NSView) -> SurfaceCreationReadiness {
        let width = max(Int(hostView.bounds.width.rounded(.down)), 0)
        let height = max(Int(hostView.bounds.height.rounded(.down)), 0)

        guard let window = hostView.window else {
            surfaceCreationStabilityPasses = 0
            lastSurfaceCreationSignature = nil
            return .deferred(reason: .noWindow, width: width, height: height)
        }

        guard hostView.isHidden == false, hostView.hasHiddenAncestor == false else {
            surfaceCreationStabilityPasses = 0
            lastSurfaceCreationSignature = nil
            return .deferred(reason: .hiddenHost, width: width, height: height)
        }

        guard width >= minimumSurfaceHostDimension,
              height >= minimumSurfaceHostDimension else {
            surfaceCreationStabilityPasses = 0
            lastSurfaceCreationSignature = nil
            return .deferred(reason: .tinyBounds, width: width, height: height)
        }

        let signature = SurfaceCreationSignature(
            windowID: ObjectIdentifier(window),
            width: width,
            height: height
        )
        if lastSurfaceCreationSignature == signature {
            surfaceCreationStabilityPasses += 1
        } else {
            lastSurfaceCreationSignature = signature
            surfaceCreationStabilityPasses = 1
        }

        guard surfaceCreationStabilityPasses >= requiredStableSurfaceCreationPasses else {
            return .deferred(reason: .unstableBounds, width: width, height: height)
        }

        return .ready
    }

    private func logSurfaceDiagnostics(message: String, extra: [String: String] = [:]) {
        var metadata: [String: String] = [
            "panel_id": panelID.uuidString,
            "attach_count": String(diagnostics.attachCount),
            "update_count": String(diagnostics.updateCount),
            "surface_attempt_count": String(diagnostics.surfaceAttemptCount),
            "surface_success_count": String(diagnostics.surfaceSuccessCount),
            "surface_failure_count": String(diagnostics.surfaceFailureCount),
            "surface_deferred_count": String(diagnostics.surfaceDeferredCount),
        ]
        for (key, value) in extra {
            metadata[key] = value
        }
        ToasttyLog.debug(message, category: .ghostty, metadata: metadata)
    }

    #endif
}

private extension NSView {
    var hasHiddenAncestor: Bool {
        var ancestor = superview
        while let current = ancestor {
            if current.isHidden {
                return true
            }
            ancestor = current.superview
        }
        return false
    }

}

@MainActor
extension TerminalSurfaceController {
    #if TOASTTY_HAS_GHOSTTY_KIT
    private func shouldIgnoreAttach(to candidate: NSView) -> Bool {
        guard let activeSourceContainer else { return false }
        guard activeSourceContainer !== candidate else { return false }
        guard hostedView.superview != nil else { return false }
        let activeAttached = containerIsAttachedAndVisible(activeSourceContainer)
        let candidateClearlyDetached = candidate.window == nil || candidate.superview == nil
        return activeAttached && candidateClearlyDetached
    }

    private func shouldPromoteSourceContainer(to candidate: NSView) -> Bool {
        guard containerIsAttachedAndVisible(candidate) else {
            return false
        }
        if hostedView.superview === candidate {
            return true
        }
        guard let activeSourceContainer else {
            return true
        }
        if activeSourceContainer === candidate {
            return true
        }
        return !containerIsAttachedAndVisible(activeSourceContainer)
    }

    private func containerIsAttachedAndVisible(_ container: NSView?) -> Bool {
        guard let container else { return false }
        guard container.window != nil else { return false }
        guard container.superview != nil else { return false }
        guard !container.isHidden else { return false }
        guard container.bounds.width > 1, container.bounds.height > 1 else { return false }

        var ancestor = container.superview
        while let view = ancestor {
            if view.isHidden {
                return false
            }
            ancestor = view.superview
        }
        return true
    }

    private func refreshSurfaceAfterContainerMove(sourceContainer: NSView) {
        guard let ghosttySurface else { return }
        updateDisplayIDIfNeeded(surface: ghosttySurface, sourceContainer: sourceContainer)
        ghosttyManager.requestImmediateTick()
        ghostty_surface_refresh(ghosttySurface)
    }

    private func updateDisplayIDIfNeeded(surface: ghostty_surface_t, sourceContainer: NSView) {
        guard let displayID = resolvedDisplayID(sourceContainer: sourceContainer) else {
            return
        }
        guard lastDisplayID != displayID else {
            return
        }
        ghostty_surface_set_display_id(surface, displayID)
        lastDisplayID = displayID
    }

    private func resolvedDisplayID(sourceContainer: NSView) -> UInt32? {
        sourceContainer.window?.screen?.ghosttyDisplayID
    }

    private var tinyViewportSuppressionThreshold: Int { 1 }

    private func shouldUseBackingPixelSurfaceSizing(
        measuredSize: ghostty_surface_size_s,
        logicalWidth: Int,
        logicalHeight: Int,
        expectedPixelWidth: Int,
        expectedPixelHeight: Int,
        scale: Double
    ) -> Bool {
        guard scale > 1.05 else { return false }
        let measuredWidth = Int(measuredSize.width_px)
        let measuredHeight = Int(measuredSize.height_px)
        guard logicalWidth > 0, logicalHeight > 0 else { return false }

        let measuredWidthRatio = Double(measuredWidth) / Double(logicalWidth)
        let measuredHeightRatio = Double(measuredHeight) / Double(logicalHeight)
        let expectedRatio = scale
        let thresholdRatio = expectedRatio * 0.98
        let looksLogicalScale = measuredWidthRatio <= 1.02 && measuredHeightRatio <= 1.02
        let significantlyBelowExpected = measuredWidthRatio < thresholdRatio || measuredHeightRatio < thresholdRatio
        let belowExpectedPixels = measuredWidth < expectedPixelWidth || measuredHeight < expectedPixelHeight
        return looksLogicalScale && significantlyBelowExpected && belowExpectedPixels
    }

    private func logRenderMetricsIfNeeded(
        viewportWidth: Int,
        viewportHeight: Int,
        scale: Double,
        measuredSize: ghostty_surface_size_s?
    ) {
        guard let ghosttySurface else { return }
        let measuredSize = measuredSize ?? ghostty_surface_size(ghosttySurface)
        let metrics = GhosttyRenderMetrics(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            scaleThousandths: Int((scale * 1000).rounded()),
            widthPx: Int(measuredSize.width_px),
            heightPx: Int(measuredSize.height_px),
            columns: Int(measuredSize.columns),
            rows: Int(measuredSize.rows),
            cellWidthPx: Int(measuredSize.cell_width_px),
            cellHeightPx: Int(measuredSize.cell_height_px),
            pixelSizingEnabled: usesBackingPixelSurfaceSizing
        )
        guard metrics != lastRenderMetrics else { return }
        lastRenderMetrics = metrics

        ToasttyLog.debug(
            "Ghostty surface render metrics",
            category: .ghostty,
            metadata: [
                "panel_id": panelID.uuidString,
                "viewport_width": String(metrics.viewportWidth),
                "viewport_height": String(metrics.viewportHeight),
                "scale_thousandths": String(metrics.scaleThousandths),
                "width_px": String(metrics.widthPx),
                "height_px": String(metrics.heightPx),
                "columns": String(metrics.columns),
                "rows": String(metrics.rows),
                "cell_width_px": String(metrics.cellWidthPx),
                "cell_height_px": String(metrics.cellHeightPx),
                "pixel_sizing": metrics.pixelSizingEnabled ? "true" : "false",
            ]
        )
    }

    private func swapToFallbackIfNeeded() {
        guard let container = hostedView.superview else { return }
        if fallbackView.superview !== container {
            fallbackView.removeFromSuperview()
            container.addSubview(fallbackView)
            fallbackView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                fallbackView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                fallbackView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                fallbackView.topAnchor.constraint(equalTo: container.topAnchor),
                fallbackView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
    }

    private func ensureFirstResponderIfNeeded(focused: Bool) {
        guard focused else { return }
        guard let window = hostedView.window else { return }
        guard window.isKeyWindow else { return }
        guard window.firstResponder !== hostedView else { return }
        window.makeFirstResponder(hostedView)
    }

    func pulseVisibilityRefresh() {
        guard let ghosttySurface else { return }
        ghosttyManager.requestImmediateTick()
        ghostty_surface_refresh(ghosttySurface)
    }
    #endif
}

final class TerminalHostView: NSView {
    #if TOASTTY_HAS_GHOSTTY_KIT
    private var ghosttySurface: ghostty_surface_t?
    #endif

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        syncLayerContentsScale()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        syncLayerContentsScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncLayerContentsScale()
    }

    #if TOASTTY_HAS_GHOSTTY_KIT
    func setGhosttySurface(_ surface: ghostty_surface_t?) {
        ghosttySurface = surface
    }

    override func keyDown(with event: NSEvent) {
        guard handleKeyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS) else {
            super.keyDown(with: event)
            return
        }
    }

    override func keyUp(with event: NSEvent) {
        guard handleKeyEvent(event, action: GHOSTTY_ACTION_RELEASE) else {
            super.keyUp(with: event)
            return
        }
    }

    private func handleKeyEvent(_ event: NSEvent, action: ghostty_input_action_e) -> Bool {
        guard let ghosttySurface else {
            ToasttyLog.debug(
                "Dropped key event because Ghostty surface is unavailable",
                category: .input,
                metadata: [
                    "key_code": String(event.keyCode),
                    "action": Self.ghosttyInputActionName(action),
                ]
            )
            return false
        }

        let mods = Self.ghosttyModifierFlags(for: event.modifierFlags)
        var keyEvent = ghostty_input_key_s(
            action: action,
            mods: mods,
            consumed_mods: ghostty_surface_key_translation_mods(ghosttySurface, mods),
            keycode: UInt32(event.keyCode),
            text: nil,
            unshifted_codepoint: 0,
            composing: false
        )

        if let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            keyEvent.unshifted_codepoint = scalar.value
        }

        let text = Self.ghosttyText(for: event)
        let handled: Bool
        if let text, !text.isEmpty {
            handled = text.withCString { pointer in
                keyEvent.text = pointer
                return ghostty_surface_key(ghosttySurface, keyEvent)
            }
        } else {
            handled = ghostty_surface_key(ghosttySurface, keyEvent)
        }

        ToasttyLog.debug(
            "Forwarded key event to Ghostty surface",
            category: .input,
            metadata: [
                "handled": handled ? "true" : "false",
                "key_code": String(event.keyCode),
                "action": Self.ghosttyInputActionName(action),
                "modifiers": Self.modifierDescription(event.modifierFlags),
                "text_length": String(text?.count ?? 0),
            ]
        )

        return handled
    }

    private static func ghosttyModifierFlags(for flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        if flags.contains(.numericPad) { raw |= GHOSTTY_MODS_NUM.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    private static func ghosttyText(for event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }

        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }

            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }

    private static func modifierDescription(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.command) { parts.append("command") }
        if flags.contains(.option) { parts.append("option") }
        if flags.contains(.control) { parts.append("control") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.capsLock) { parts.append("capsLock") }
        if flags.contains(.numericPad) { parts.append("numericPad") }
        return parts.joined(separator: ",")
    }

    private static func ghosttyInputActionName(_ action: ghostty_input_action_e) -> String {
        switch action {
        case GHOSTTY_ACTION_PRESS:
            return "press"
        case GHOSTTY_ACTION_RELEASE:
            return "release"
        case GHOSTTY_ACTION_REPEAT:
            return "repeat"
        default:
            return "unknown(\(action.rawValue))"
        }
    }
    #endif

    private func syncLayerContentsScale() {
        let scale = window?.screen?.backingScaleFactor
            ?? window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        layer?.contentsScale = max(scale, 1)
    }
}

private extension NSScreen {
    var ghosttyDisplayID: UInt32? {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return screenNumber.uint32Value
    }
}

private final class TerminalFallbackView: NSView {
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let reasonLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
        layer?.borderWidth = 0
        layer?.borderColor = NSColor.clear.cgColor

        subtitleLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = NSColor(calibratedWhite: 0.75, alpha: 1)

        reasonLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        reasonLabel.textColor = NSColor(calibratedWhite: 0.65, alpha: 1)

        let stack = NSStackView(views: [subtitleLabel, reasonLabel])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(terminalState: TerminalPanelState, unavailableReason: String) {
        subtitleLabel.stringValue = terminalState.cwd
        reasonLabel.stringValue = unavailableReason
    }
}
